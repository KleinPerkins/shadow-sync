#!/usr/bin/env python3
"""Package one source-bound signed MVP app as a notarized, stapled DMG.

Uses a caller-owned isolated keychain/profile; never reads credential values,
launches the app, installs, publishes or promotes. Retries retain submission IDs.
An upload whose ID was not recorded requires reconciliation; it is not resubmitted.
Apple workflow: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
"""
import argparse
import fcntl
import shutil
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release_assembly', ROOT / 'scripts/assemble-release-bundle.py')
assembly = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(assembly)
require, Refusal, sha = assembly.require, assembly.Refusal, assembly.sha
command = assembly.command
write_json = assembly.execution.write_json
TICKET = 'Contents/CodeResources'


def regular(path, maximum=None):
    s = path.lstat()
    require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_uid == os.getuid()
            and not s.st_mode & 0o022 and (maximum is None or s.st_size <= maximum), 'unsafe-release-file')
    return s


def read_record(path):
    regular(path, 8_388_608)
    return assembly.json_file(path)


def record(path, value):
    if path.exists():
        require(read_record(path) == value, 'conflicting-release-record')
    else:
        require(not os.path.lexists(path), 'aliased-release-record')
        write_json(path, value)
    # The containing private directory is durable before any external effect.
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def handoff(args):
    assembly.verify_source(args.source_revision, args.source_sha256)
    root = Path(args.assembly)
    assembly.private_parent(root)
    require(root.is_dir() and root.stat().st_uid == os.getuid()
            and stat.S_IMODE(root.stat().st_mode) == 0o700, 'assembly-directory')
    receipt = read_record(root / 'release-assembly.json')
    team = assembly.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier']
    require(receipt['schema'] == 'shadow-sync-release-assembly/v1'
            and receipt['revision'] == args.source_revision and receipt['source_sha256'] == args.source_sha256
            and receipt['assembler_sha256'] == sha(ROOT / 'scripts/assemble-release-bundle.py')
            and receipt['release_contract_sha256'] == sha(ROOT / 'Resources/release-contract.json')
            and receipt['publisher_team'] == team and receipt['architecture'] == 'arm64'
            and all(receipt[k] is False for k in ('notarized', 'published', 'installed', 'product_accepted')),
            'assembly-binding')
    app = root / 'ShadowSync.app'
    require(app.stat().st_mode & 0o7777 == 0o755 and app_tree(app) == receipt['output_entries'], 'assembly-bytes')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    expected.update(ShadowSyncSourceRevision=args.source_revision, ShadowSyncSourceInputSHA256=args.source_sha256,
                    ShadowSyncReleaseContractSHA256=receipt['release_contract_sha256'])
    require(info == expected and info['ShadowSyncBuildMode'] == 'production'
            and receipt['version'] == info['CFBundleShortVersionString'] and receipt['build'] == info['CFBundleVersion']
            and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', receipt['version'])
            and re.fullmatch(r'[1-9][0-9]*', receipt['build']), 'release-metadata')
    assembly.verify_code(app, team, assembly.APP_ID)
    assembly.verify_code(app / 'Contents/Helpers/ShadowSyncLifecycleCoordinator', team, assembly.HELPER_ID)
    return receipt, sha(root / 'release-assembly.json')


def credentials(args, team):
    require(re.fullmatch(r'[A-Za-z0-9._-]{1,80}', args.notary_profile), 'notary-profile')
    assembly.signing_configuration(args.signing_identity, Path(args.keychain), team)
    return ['--keychain-profile', args.notary_profile, '--keychain', args.keychain]


def notarize(path, directory, label, auth):
    """Resume only the recorded submission for these exact bytes."""
    regular(path)
    binding = {'filename': path.name, 'sha256': sha(path)}
    intent, submitted, accepted = [directory / (label + '-' + p + '.json') for p in ('intent', 'submitted', 'accepted')]
    if not intent.exists():
        require(not submitted.exists() and not accepted.exists(), 'orphaned-notary-record')
        record(intent, binding)
        result = command('notary-submit', '/usr/bin/xcrun', 'notarytool', 'submit', path,
                         *auth, '--no-wait', '--output-format', 'json', timeout=300)
        response = json.loads(result.stdout)
        identifier = response['id']
        require(str(uuid.UUID(identifier)) == identifier.lower(), 'notary-submission-id')
        record(submitted, dict(binding, id=identifier.lower()))
    require(read_record(intent) == binding, 'notary-input-changed')
    # A process interruption after upload but before recording the ID cannot
    # authorize a second upload. Keep the intent for explicit reconciliation.
    require(submitted.exists(), 'notary-submission-id-unrecorded')
    submission = read_record(submitted)
    require(set(submission) == {'filename', 'sha256', 'id'} and
            {k: submission[k] for k in binding} == binding
            and str(uuid.UUID(submission['id'])) == submission['id'], 'notary-submission-binding')
    identifier = submission['id']
    log_path = directory / (label + '-notary-log.json')
    if not accepted.exists():
        result = command('notary-wait', '/usr/bin/xcrun', 'notarytool', 'wait', identifier,
                         *auth, '--timeout', '20m', '--output-format', 'json', timeout=1230)
        response = json.loads(result.stdout)
        require(response.get('id') == identifier, 'notary-result-id')
        if not log_path.exists():
            require(not os.path.lexists(log_path), 'aliased-notary-log')
            command('notary-log', '/usr/bin/xcrun', 'notarytool', 'log', identifier, *auth, log_path)
        log = read_record(log_path)
        require(response.get('status') == 'Accepted' and log.get('status') == 'Accepted'
                and log.get('statusCode') == 0 and log.get('jobId') == identifier
                and log.get('sha256') == binding['sha256']
                and log.get('archiveFilename') == path.name and not log.get('issues'), 'notary-not-cleanly-accepted')
        require(sha(path) == binding['sha256'], 'submitted-bytes-changed')
        record(accepted, dict(submission, status='Accepted', log_sha256=sha(log_path)))
    result = read_record(accepted)
    require(result == dict(submission, status='Accepted', log_sha256=sha(log_path)), 'accepted-notary-binding')
    return result


def accepted_record(directory, label, expected):
    submission = read_record(directory / (label + '-submitted.json'))
    require(set(submission) == {'filename', 'sha256', 'id'}
            and {k: submission[k] for k in expected} == expected
            and str(uuid.UUID(submission['id'])) == submission['id'], 'accepted-submission-binding')
    log_path = directory / (label + '-notary-log.json')
    log = read_record(log_path)
    require(log.get('jobId') == submission['id'] and log.get('sha256') == expected['sha256']
            and log.get('archiveFilename') == expected['filename'] and log.get('status') == 'Accepted'
            and log.get('statusCode') == 0 and not log.get('issues'), 'accepted-log-binding')
    result = dict(submission, status='Accepted', log_sha256=sha(log_path))
    require(read_record(directory / (label + '-accepted.json')) == result, 'accepted-record-binding')
    return result


def app_tree(app):
    def check():
        value = app.lstat()
        require(stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid()
                and stat.S_IMODE(value.st_mode) == 0o755, 'payload-root-mode')
    check()
    rows = assembly.tree(app)
    check()
    return rows


def ticket_inventory(app, before):
    after = app_tree(app)
    require(set(after) == set(before) | {TICKET} and TICKET not in before
            and all(after[name] == row for name, row in before.items()), 'staple-payload-changed')
    ticket = after[TICKET]
    require(ticket['kind'] == 'file' and ticket['mode'] == 0o644 and 0 < ticket['bytes'] <= 1_048_576,
            'notarization-ticket-layout')
    return after


def package(args):
    require(sys.platform == 'darwin' and os.getuid() != 0, 'macos-user-required')
    before, assembly_digest = handoff(args)
    auth = credentials(args, before['publisher_team'])
    output = Path(args.output)
    assembly.private_parent(output)
    existed = os.path.lexists(output)
    require(not existed or args.resume, 'explicit-resume-required')
    if not existed:
        require(not args.resume, 'missing-resume-output')
        output.mkdir(mode=0o700)
    require(output.is_dir() and not output.is_symlink() and output.stat().st_uid == os.getuid()
            and stat.S_IMODE(output.stat().st_mode) == 0o700, 'attempt-directory')
    lock = output / 'attempt.lock'
    flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    descriptor = os.open(lock, flags if existed else flags | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_size == 0 and stat.S_IMODE(info.st_mode) == 0o600, 'attempt-lock')
        try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise Refusal('attempt-busy') from None
        return locked_package(args, output, existed, before, assembly_digest, auth)
    finally:
        os.close(descriptor)


def image_code(path, team):
    requirement = assembly.runtime.developer_id_requirement(team) + ' and identifier "' + assembly.APP_ID + '.distribution"'
    command('verify-disk-image-signature', '/usr/bin/codesign', '--verify', '--strict', '-R', requirement, path)
    value = command('disk-image-code-directory', '/usr/bin/codesign', '-d', '--verbose=4', path).stderr
    matches = re.findall(r'^CDHash=([0-9a-f]{40})$', value, re.MULTILINE)
    require(len(matches) == 1, 'disk-image-code-directory')
    return matches[0]


def locked_package(args, output, existed, before, assembly_digest, auth):
    binding = {'schema': 'shadow-sync-notarization-preparation/v1', 'revision': args.source_revision,
               'source_sha256': args.source_sha256, 'assembly_sha256': assembly_digest,
               'packager_sha256': sha(Path(__file__)), 'publisher_team': before['publisher_team']}
    app = output / 'payload/ShadowSync.app'
    prepared = output / 'prepared.json'
    if not existed:
        (output / 'payload').mkdir(mode=0o700)
        command('copy-signed-app', '/usr/bin/ditto', '--rsrc', '--extattr', Path(args.assembly) / 'ShadowSync.app', app)
        require(app_tree(app) == before['output_entries'], 'copied-app-binding')
        record(prepared, binding)
    else:
        require(args.resume and output.is_dir() and not output.is_symlink()
                and output.stat().st_uid == os.getuid() and stat.S_IMODE(output.stat().st_mode) == 0o700
                and read_record(prepared) == binding, 'resume-binding')
    require((output / 'payload').resolve(strict=True) == output / 'payload'
            and {p.name for p in (output / 'payload').iterdir()} == {'ShadowSync.app'}, 'payload-layout')
    stapled = output / 'app-stapled.json'
    if not stapled.exists():
        if os.path.lexists(app / TICKET):
            ticket_inventory(app, before['output_entries'])
            require((output / 'app-accepted.json').is_file(), 'unqualified-existing-ticket')
        else:
            require(app_tree(app) == before['output_entries'], 'unstapled-app-binding')
        archive = output / 'submission.zip'
        archive_record = output / 'app-archive.json'
        if not archive_record.exists():
            require(not os.path.lexists(archive), 'partial-app-archive')
            command('archive-app', '/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
            regular(archive)
            record(archive_record, {'sha256': sha(archive)})
        require(read_record(archive_record) == {'sha256': sha(archive)}, 'app-archive-binding')
        accepted = notarize(archive, output, 'app', auth)
        command('staple-app', '/usr/bin/xcrun', 'stapler', 'staple', app)
        command('validate-app-ticket', '/usr/bin/xcrun', 'stapler', 'validate', app)
        after = ticket_inventory(app, before['output_entries'])
        assembly.verify_code(app, before['publisher_team'], assembly.APP_ID)
        command('gatekeeper-app', '/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', app)
        record(stapled, {'entries': after, 'notary_id': accepted['id']})
    app_record = read_record(stapled)
    require(app_tree(app) == app_record['entries']
            and app_record['notary_id'] == read_record(output / 'app-accepted.json')['id'], 'stapled-app-binding')
    ticket_inventory(app, before['output_entries'])
    app_accepted = accepted_record(output, 'app', {'filename': 'submission.zip', 'sha256': sha(output / 'submission.zip')})
    require(app_record['notary_id'] == app_accepted['id'], 'app-notary-binding')
    basename = 'ShadowSync-' + before['version'] + '-build' + before['build'] + '-macos-arm64'
    dmg = output / (basename + '.dmg')
    submitted_image = output / 'submission.dmg'
    image_record = output / 'image-signed.json'
    if not image_record.exists():
        require(not os.path.lexists(submitted_image) and not os.path.lexists(dmg), 'partial-disk-image')
        command('create-disk-image', '/usr/bin/hdiutil', 'create', '-srcfolder', output / 'payload',
                '-volname', 'ShadowSync', '-format', 'UDZO', '-fs', 'HFS+', '-o', submitted_image, timeout=300)
        command('sign-disk-image', '/usr/bin/codesign', '--sign', args.signing_identity, '--keychain', args.keychain,
                '--timestamp', '--identifier', assembly.APP_ID + '.distribution', submitted_image)
        regular(submitted_image)
        record(image_record, {'sha256': sha(submitted_image), 'cdhash': image_code(submitted_image, before['publisher_team'])})
    image = read_record(image_record)
    require(image == {'sha256': sha(submitted_image), 'cdhash': image_code(submitted_image, before['publisher_team'])},
            'signed-disk-image-binding')
    final = output / 'release-package.json'
    if not final.exists():
        accepted = notarize(submitted_image, output, 'dmg', auth)
        # Keep the exact submitted bytes intact. A retry can safely revalidate
        # and staple the distribution copy after any later failure.
        if not os.path.lexists(dmg):
            with submitted_image.open('rb') as src, dmg.open('xb') as dst:
                shutil.copyfileobj(src, dst)
                dst.flush(); os.fsync(dst.fileno())
            dmg.chmod(0o644)
            require(sha(dmg) == image['sha256'], 'copied-disk-image-binding')
        regular(dmg)
        require(image_code(dmg, before['publisher_team']) == image['cdhash'], 'distribution-code-binding')
        command('staple-disk-image', '/usr/bin/xcrun', 'stapler', 'staple', dmg)
        command('validate-disk-image-ticket', '/usr/bin/xcrun', 'stapler', 'validate', dmg)
        command('gatekeeper-disk-image', '/usr/sbin/spctl', '--assess', '--type', 'open',
                '--context', 'context:primary-signature', '--verbose=2', dmg)
        command('verify-final-image', '/usr/bin/hdiutil', 'verify', dmg)
        assembly.verify_code(app, before['publisher_team'], assembly.APP_ID)
        require(app_tree(app) == app_record['entries'] and handoff(args) == (before, assembly_digest),
                'preserved-inputs-and-payload')
        regular(dmg)
        require(image_code(dmg, before['publisher_team']) == image['cdhash'], 'stapled-code-binding')
        receipt = dict(binding, schema='shadow-sync-release-package/v1', version=before['version'], build=before['build'],
                       artifact={'name': dmg.name, 'bytes': dmg.stat().st_size, 'sha256': sha(dmg)},
                       architecture='arm64', app_notary_id=app_record['notary_id'], dmg_notary_id=accepted['id'],
                       notarized=True, stapled=True, gatekeeper=True, published=False, installed=False, product_accepted=False)
        record(final, receipt)
    result = read_record(final)
    dmg_accepted = accepted_record(output, 'dmg', {'filename': submitted_image.name, 'sha256': image['sha256']})
    expected = dict(binding, schema='shadow-sync-release-package/v1', version=before['version'], build=before['build'],
                    artifact={'name': dmg.name, 'bytes': regular(dmg).st_size, 'sha256': sha(dmg)},
                    architecture='arm64', app_notary_id=app_accepted['id'], dmg_notary_id=dmg_accepted['id'],
                    notarized=True, stapled=True, gatekeeper=True, published=False, installed=False, product_accepted=False)
    require(result == expected, 'completed-artifact-binding')
    assembly.verify_code(app, before['publisher_team'], assembly.APP_ID)
    command('validate-app-ticket', '/usr/bin/xcrun', 'stapler', 'validate', app)
    require(image_code(dmg, before['publisher_team']) == image['cdhash'], 'completed-code-binding')
    command('validate-disk-image-ticket', '/usr/bin/xcrun', 'stapler', 'validate', dmg)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('assembly', 'output', 'keychain', 'notary-profile', 'signing-identity', 'source-revision', 'source-sha256'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--resume', action='store_true')
    os.umask(0o077)
    try:
        result = package(parser.parse_args())
    except (Refusal, assembly.runtime.BuildRefused, OSError, ValueError, KeyError, TypeError):
        print('Release packaging refused; preserve this attempt for diagnosis or explicit resume.', file=sys.stderr)
        return 1
    print(json.dumps({k: result[k] for k in ('schema', 'revision', 'version', 'build', 'artifact', 'notarized', 'published', 'installed', 'product_accepted')}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
