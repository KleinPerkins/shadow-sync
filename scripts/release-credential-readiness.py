#!/usr/bin/env python3
"""Protected credential qualification, without product submission or publication.

Preparation resolves pinned tools before secret exposure. Qualification signs a
disposable probe and authenticates to Apple. Cleanup is checked in finally and
again in an always-run workflow step; hard runner loss cannot qualify readiness.
Only fixed stage names escape errors. Credentials never enter receipts or logs.
"""
import base64
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = 'KleinPerkins/shadow-sync'
REPO_ID = '1442961455'
ARCHIVE_URL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz'
ARCHIVE_SHA256 = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
SIGNER_SHA256 = '43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b'
PUBLIC_KEY_SHA256 = 'b12a76de38777d310c58e59e995eef402fe4fde941b4ebfb927381df6a3ca446'
CONFIG = ('APPLE_CERTIFICATE', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_SIGNING_IDENTITY',
          'APPLE_ID', 'APPLE_PASSWORD', 'APPLE_TEAM_ID', 'SPARKLE_PRIVATE_ED_KEY', 'SPARKLE_PUBLIC_ED_KEY')


class Refusal(Exception):
    pass


def require(ok, stage):
    if not ok:
        raise Refusal(stage)


def context(env):
    require(env.get('GITHUB_ACTIONS') == 'true' and env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
            and env.get('GITHUB_REPOSITORY') == REPO and env.get('GITHUB_REPOSITORY_ID') == REPO_ID
            and env.get('GITHUB_REF') == 'refs/heads/main' and env.get('RUNNER_OS') == 'macOS', 'untrusted-context')
    sha = env.get('TRUSTED_WORKFLOW_SHA', '')
    require(re.fullmatch('[0-9a-f]{40}', sha) and sha != '0' * 40 and sha == env.get('GITHUB_SHA'), 'workflow-revision')
    require(re.fullmatch('[1-9][0-9]{0,19}', env.get('GITHUB_RUN_ID', ''))
            and re.fullmatch('[1-9][0-9]{0,5}', env.get('GITHUB_RUN_ATTEMPT', '')), 'run-identity')
    return sha


def child_environment(env):
    # Children receive only their explicit arguments/input, never all eight values.
    return {key: env[key] for key in ('HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL') if key in env}


def command(stage, *args, input=None, allowed=(0,), timeout=120):
    process = None
    try:
        process = subprocess.Popen([str(x) for x in args], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   cwd=ROOT, env=child_environment(os.environ), start_new_session=True)
        stdout, stderr = process.communicate(input=input, timeout=timeout)
        require(process.returncode in allowed, stage)
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    except BaseException:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise Refusal(stage) from None


def work_directory(env):
    context(env)
    parent = Path(env.get('RUNNER_TEMP', ''))
    require(parent.is_absolute() and parent.is_dir(), 'runner-temporary-directory')
    return parent.resolve() / ('shadow-sync-readiness-' + env['GITHUB_RUN_ID'] + '-' + env['GITHUB_RUN_ATTEMPT'])


def write_json(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def prepare(env):
    sha = context(env)
    require(not any(env.get(k) for k in CONFIG), 'credentials-present-during-preparation')
    require(env.get('DEVELOPER_DIR') == '/Applications/Xcode_26.6.app/Contents/Developer', 'toolchain-selection')
    require(command('architecture', '/usr/bin/uname', '-m').stdout.strip() == 'arm64', 'architecture')
    os_version = command('os-version', '/usr/bin/sw_vers', '-productVersion').stdout.strip()
    require(re.fullmatch(r'26\.\d+(?:\.\d+)?', os_version), 'macos-version')
    xcode = command('xcode-version', '/usr/bin/xcodebuild', '-version').stdout.strip()
    require(xcode == 'Xcode 26.6\nBuild version 17F113', 'xcode-version')
    swift = command('swift-version', '/usr/bin/xcrun', 'swift', '--version').stdout.strip()
    sdk = command('sdk-version', '/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version').stdout.strip()
    work = work_directory(env)
    work.mkdir(mode=0o700)
    with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as response:
        archive = response.read(64 * 1024 * 1024 + 1)
    require(len(archive) <= 64 * 1024 * 1024 and hashlib.sha256(archive).hexdigest() == ARCHIVE_SHA256, 'sparkle-archive-integrity')
    with tarfile.open(fileobj=io.BytesIO(archive)) as package:
        member = package.getmember('./bin/sign_update')
        require(member.isfile() and 0 < member.size < 10_000_000, 'sparkle-tool-layout')
        signer = package.extractfile(member).read()
    require(hashlib.sha256(signer).hexdigest() == SIGNER_SHA256, 'sparkle-tool-integrity')
    (work / 'sign_update').write_bytes(signer)
    (work / 'sign_update').chmod(0o700)
    command('sparkle-tool-signature', '/usr/bin/codesign', '--verify', '--strict', work / 'sign_update')
    (work / 'probe.c').write_text('int main(void) { return 0; }\n')
    command('compile-probe', '/usr/bin/xcrun', 'clang', '-target', 'arm64-apple-macos26.0', work / 'probe.c', '-o', work / 'probe')
    command('compile-public-verifier', '/usr/bin/xcrun', 'swiftc', '-parse-as-library',
            ROOT / 'scripts/verify-update-signature.swift', '-target', 'arm64-apple-macos26.0',
            '-module-cache-path', work / 'module-cache', '-o', work / 'verify-update')
    hashes = {name: hashlib.sha256((work / name).read_bytes()).hexdigest() for name in ('sign_update', 'probe', 'verify-update')}
    write_json(work / 'prepared.json', {'revision': sha, 'files': hashes, 'os_version': os_version,
                                      'xcode': xcode, 'swift': swift, 'sdk': sdk,
                                      'runner_image': env.get('ImageVersion', 'unreported')})


def configuration(env):
    require(all(isinstance(env.get(k), str) and env[k] for k in CONFIG), 'missing-release-configuration')
    require(all(len(env[k]) <= (1_048_576 if k == 'APPLE_CERTIFICATE' else 4096) for k in CONFIG), 'configuration-size')
    team = env['APPLE_TEAM_ID']
    require(re.fullmatch('[A-Z0-9]{10}', team)
            and re.fullmatch(r'Developer ID Application: [^\r\n]+ \(' + re.escape(team) + r'\)', env['APPLE_SIGNING_IDENTITY']), 'signing-identity-team')
    try:
        certificate = base64.b64decode(env['APPLE_CERTIFICATE'], validate=True)
        private = base64.b64decode(env['SPARKLE_PRIVATE_ED_KEY'], validate=True)
        public = base64.b64decode(env['SPARKLE_PUBLIC_ED_KEY'], validate=True)
    except (ValueError, TypeError):
        raise Refusal('configuration-encoding') from None
    require(certificate and len(private) == len(public) == 32, 'configuration-encoding')
    require(hashlib.sha256(public).hexdigest() == PUBLIC_KEY_SHA256, 'shadow-sync-update-key')
    return certificate


def search_list():
    values = shlex.split(command('read-keychain-search-list', '/usr/bin/security', 'list-keychains', '-d', 'user').stdout)
    require(all(Path(x).is_absolute() and not any(ord(c) < 32 for c in x) for x in values), 'keychain-search-list')
    return values


def cleanup(work):
    require(work.is_dir() and not work.is_symlink() and work.stat().st_uid == os.getuid()
            and stat.S_IMODE(work.stat().st_mode) == 0o700, 'cleanup-directory')
    journal = work / 'keychain-cleanup.json'
    if not journal.exists():
        require(not (work / 'readiness.keychain-db').exists() and not (work / 'certificate.p12').exists(), 'missing-cleanup-journal')
        return
    require(not journal.is_symlink(), 'cleanup-journal')
    record = json.loads(journal.read_text())
    old = record['search_list']
    require(isinstance(old, list) and all(isinstance(x, str) and Path(x).is_absolute()
            and not any(ord(c) < 32 for c in x) for x in old), 'cleanup-search-list')
    failed = False
    try:
        command('restore-keychain-search-list', '/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *old)
    except Refusal:
        failed = True
    keychain = work / 'readiness.keychain-db'
    try:
        if keychain.exists():
            command('delete-temporary-keychain', '/usr/bin/security', 'delete-keychain', keychain)
    except Refusal:
        failed = True
    finally:
        (work / 'certificate.p12').unlink(missing_ok=True)
    require(not failed and not keychain.exists() and not (work / 'certificate.p12').exists()
            and search_list() == old, 'temporary-credential-cleanup')


@contextmanager
def signing_keychain(work, certificate, env):
    require(not (work / 'keychain-cleanup.json').exists(), 'duplicate-signing-transaction')
    write_json(work / 'keychain-cleanup.json', {'search_list': search_list()})
    keychain, p12 = work / 'readiness.keychain-db', work / 'certificate.p12'
    password = secrets.token_urlsafe(32)
    try:
        with p12.open('xb') as stream:
            stream.write(certificate)
        p12.chmod(0o600)
        command('create-keychain', '/usr/bin/security', 'create-keychain', '-p', password, keychain)
        command('configure-keychain', '/usr/bin/security', 'set-keychain-settings', '-lut', '600', keychain)
        command('unlock-keychain', '/usr/bin/security', 'unlock-keychain', '-p', password, keychain)
        command('import-certificate', '/usr/bin/security', 'import', p12, '-k', keychain,
                '-P', env['APPLE_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
        p12.unlink()
        command('signing-access', '/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain)
        # The probe explicitly selects this keychain; no login identity is used.
        old = json.loads((work / 'keychain-cleanup.json').read_text())['search_list']
        command('select-keychain', '/usr/bin/security', 'list-keychains', '-d', 'user', '-s', keychain, *old)
        yield keychain
    finally:
        cleanup(work)


def qualify(env):
    sha = context(env)
    work = work_directory(env)
    require(work.is_dir() and not work.is_symlink() and stat.S_IMODE(work.stat().st_mode) == 0o700, 'prepared-directory')
    prepared = json.loads((work / 'prepared.json').read_text())
    require(prepared['revision'] == sha and set(prepared['files']) == {'sign_update', 'probe', 'verify-update'}, 'prepared-revision')
    for name, digest in prepared['files'].items():
        require(not (work / name).is_symlink() and hashlib.sha256((work / name).read_bytes()).hexdigest() == digest, 'prepared-tool-integrity')
    require(prepared['files']['sign_update'] == SIGNER_SHA256, 'prepared-tool-integrity')
    certificate = configuration(env)
    identity, team = env['APPLE_SIGNING_IDENTITY'], env['APPLE_TEAM_ID']
    with signing_keychain(work, certificate, env) as keychain:
        identities = command('certificate-trust', '/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain).stdout
        require(identity in re.findall(r'"([^"]+)"', identities), 'certificate-trust')
        command('developer-id-signing', '/usr/bin/codesign', '--force', '--sign', identity, '--keychain', keychain,
                '--options', 'runtime', '--timestamp', work / 'probe')
        command('verify-code-signature', '/usr/bin/codesign', '--verify', '--strict', work / 'probe')
        details = command('inspect-code-signature', '/usr/bin/codesign', '-d', '--verbose=4', work / 'probe').stderr
        lines = details.splitlines()
        require('TeamIdentifier=' + team in lines and 'Authority=' + identity in lines
                and any(x.startswith('Timestamp=') for x in lines) and '(runtime)' in details, 'publisher-signature-properties')
        command('notarization-authentication', '/usr/bin/xcrun', 'notarytool', 'store-credentials',
                'shadow-sync-readiness', '--keychain', keychain, '--apple-id', env['APPLE_ID'],
                '--password', env['APPLE_PASSWORD'], '--team-id', team, '--validate')
        command('notarization-history', '/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile',
                'shadow-sync-readiness', '--keychain', keychain, '--output-format', 'json')
    payload = work / 'update-probe.bin'
    payload.write_bytes(b'ShadowSync credential-readiness probe\n')
    signature = command('sparkle-signature', work / 'sign_update', '--ed-key-file', '-', '-p', payload,
                        input=env['SPARKLE_PRIVATE_ED_KEY'] + '\n').stdout.strip()
    command('sparkle-key-match', work / 'verify-update', env['SPARKLE_PUBLIC_ED_KEY'], signature, payload)
    payload.write_bytes(b'Tampered credential probe\n')
    rejected = command('tamper-rejection', work / 'verify-update', env['SPARKLE_PUBLIC_ED_KEY'], signature, payload, allowed=(0, 1))
    require(rejected.returncode == 1, 'tamper-rejection')
    cleanup(work)
    receipt = {'schema': 'shadow-sync-release-credential-readiness/v1', 'revision': sha,
               'developer_id_signing': True, 'hardened_runtime': True, 'secure_timestamp': True,
               'notarization_authentication': True, 'sparkle_key_pair': True, 'tampered_update_rejected': True,
               'temporary_credentials_removed': True, 'toolchain': {k: prepared[k] for k in ('os_version', 'xcode', 'swift', 'sdk', 'runner_image')},
               'sparkle_archive_sha256': ARCHIVE_SHA256, 'sparkle_public_key_sha256': PUBLIC_KEY_SHA256,
               'product_notarized': False, 'release_published': False, 'installed_update_verified': False}
    (ROOT / 'outputs').mkdir(mode=0o700, exist_ok=True)
    write_json(ROOT / 'outputs/release-credential-readiness.json', receipt)


def main():
    os.umask(0o077)
    try:
        context(os.environ)
        require(len(sys.argv) == 2 and sys.argv[1] in ('prepare', 'qualify', 'cleanup'), 'mode')
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(Refusal('interrupted')))
        if sys.argv[1] == 'prepare':
            prepare(os.environ)
        elif sys.argv[1] == 'qualify':
            qualify(os.environ)
        else:
            cleanup(work_directory(os.environ))
        print('Release credential readiness stage completed; no product submitted or published.')
        return 0
    except Refusal as error:
        print('Release credential readiness refused: ' + str(error), file=sys.stderr)
    except Exception:
        print('Release credential readiness refused: diagnostic-failed', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
