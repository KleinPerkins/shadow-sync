#!/usr/bin/env python3
"""Assemble and Developer ID sign the MVP bundle from exact prepared inputs.

The caller supplies an already unlocked isolated signing keychain. This tool
never fetches dependencies, reads secrets, publishes, installs, or launches the
app. Notarization and product qualification are separate release gates. Failed
outputs are retained in their newly created private directory for diagnosis.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = load('build-policy-runtime')
execution = load('release-credential-readiness')
build = load('ci-build')
Refusal = execution.Refusal
require = execution.require
sha = runtime.sha
command = execution.command

APP_ID = 'com.kleinperkins.shadow-sync'
HELPER_ID = APP_ID + '.lifecycle-coordinator'
RUNTIME_ID = APP_ID + '.python-runtime'
EXECUTABLES = {'Contents/MacOS/ShadowSync', 'Contents/Helpers/ShadowSyncLifecycleCoordinator'}
SOURCE_RESOURCES = {
    'Contents/Resources/release-contract.json': 'Resources/release-contract.json',
    'Contents/Resources/command-graphs.json': 'Resources/command-graphs.json',
    'Contents/Resources/com.kleinperkins.shadow-sync.plist.template': 'Resources/com.kleinperkins.shadow-sync.plist.template',
    'Contents/Resources/ShadowSync.icns': 'Resources/ShadowSync.icns',
    'Contents/Resources/THIRD_PARTY_NOTICES.md': 'THIRD_PARTY_NOTICES.md',
}
ADDED_RESOURCES = ('PolicyAdapter.py', 'awa-contract.json', 'policy-runtime-source.json')
RAW_FILES = EXECUTABLES | set(SOURCE_RESOURCES) | {'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources'}
RAW_DIRECTORIES = {'Contents', 'Contents/MacOS', 'Contents/Helpers', 'Contents/Resources', 'Contents/_CodeSignature'}


def json_file(path):
    def pairs(rows):
        result = {}
        for key, value in rows:
            require(key not in result, 'duplicate-json-key')
            result[key] = value
        return result
    return json.loads(path.read_bytes(), object_pairs_hook=pairs)


def private_parent(path):
    require(path.is_absolute() and path.parent.resolve(strict=True) == path.parent, 'input-parent')
    info = path.parent.stat()
    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'private-input-parent')
    require(not path.is_symlink(), 'aliased-input')


def tree(path):
    require(path.is_dir() and not path.is_symlink(), 'input-directory')
    require(path.stat().st_uid == os.getuid(), 'foreign-root-owner')
    rows = runtime.inventory(path)
    for name in rows:
        require((path / name).lstat().st_uid == os.getuid(), 'foreign-input-owner')
    return rows


def build_handoff(path, app, revision, source_digest):
    # Only the controlled CI/release preparation path produces this handoff.
    # It is local evidence, not a substitute for the exact-revision Actions gate.
    private_parent(path)
    require(path.name == 'build.json' and path.is_file() and path.stat().st_nlink == 1
            and path.stat().st_uid == os.getuid()
            and app == path.parent / 'production/package/ShadowSync.app', 'build-handoff-path')
    try:
        receipt = json_file(path)
        require('production' in receipt['builds'], 'production-build-missing')
        build.verify(receipt, path.parent, {'revision': revision, 'source_sha256': source_digest})
    except Exception:
        raise Refusal('build-handoff-binding') from None
    return sha(path), receipt['builds']['production']['package']


def raw_bundle(app, revision, source_digest):
    private_parent(app)
    require(app.name == 'ShadowSync.app', 'application-name')
    rows = tree(app)
    require({n for n, r in rows.items() if r['kind'] == 'file'} == RAW_FILES
            and {n for n, r in rows.items() if r['kind'] == 'directory'} == RAW_DIRECTORIES
            and all(r['kind'] != 'symlink' for r in rows.values()), 'raw-bundle-layout')
    for name, source in SOURCE_RESOURCES.items():
        require(rows[name]['sha256'] == sha(ROOT / source), 'raw-resource-binding')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    template = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    expected = dict(template, ShadowSyncSourceRevision=revision, ShadowSyncSourceInputSHA256=source_digest,
                    ShadowSyncReleaseContractSHA256=sha(ROOT / 'Resources/release-contract.json'))
    require(info == expected and info['ShadowSyncBuildMode'] == 'production'
            and info['CFBundleIdentifier'] == APP_ID and info['ShadowSyncArchitecture'] == 'arm64'
            and info['LSMinimumSystemVersion'] == '26.0', 'production-release-binding')
    command('raw-app-signature', '/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    for executable in sorted(EXECUTABLES):
        require(command('application-architecture', '/usr/bin/lipo', '-archs',
                        app / executable).stdout.strip() == 'arm64', 'application-architecture')
    return rows, info


def runtime_bundle(directory, team):
    private_parent(directory)
    require(directory.is_dir() and stat.S_IMODE(directory.stat().st_mode) == 0o700, 'runtime-output-directory')
    receipt_path = directory / 'runtime-build.json'
    require(receipt_path.is_file() and not receipt_path.is_symlink()
            and receipt_path.stat().st_nlink == 1, 'runtime-build-receipt')
    receipt = json_file(receipt_path)
    require(receipt['schema'] == 'shadow-sync-policy-runtime-build/v1'
            and receipt['signature_mode'] == 'Developer-ID' and receipt['publisher_team'] == team
            and receipt['architecture'] == 'arm64' and receipt['source'] == runtime.load_pin()
            and receipt['builder_sha256'] == sha(ROOT / 'scripts/build-policy-runtime.py')
            and receipt['source_pin_sha256'] == sha(ROOT / 'Resources/policy-runtime-source.json')
            and receipt['stdlib_archive']['driver_sha256'] == sha(ROOT / 'scripts/compile-runtime-bytecode.py')
            and receipt['third_party_notice_qualification'] == 'source-bound-content-verified'
            and receipt['notices_manifest_sha256'] == receipt['source']['notices_manifest_sha256'],
            'runtime-producer-binding')
    framework = directory / 'Python.framework'
    require(framework.stat().st_mode & 0o7777 == 0o755, 'runtime-root-mode')
    rows = tree(framework)
    require(rows == receipt['output_entries'], 'runtime-output-binding')
    manifest = framework / 'Versions/3.14/Resources/ShadowSyncRuntimeLayout.json'
    require(sha(manifest) == receipt['layout_sha256'], 'runtime-layout-binding')
    layout = json_file(manifest)
    require(layout['schema'] == 'shadow-sync-policy-runtime-layout/v1' and layout['source'] == receipt['source']
            and layout['entries'] == {name: {key: val for key, val in row.items()
                                            if key in ('kind', 'mode', 'target')} for name, row in rows.items()},
            'runtime-layout-binding')
    verify_code(framework, team, RUNTIME_ID)
    machos = []
    for name, row in rows.items():
        if row['kind'] != 'file':
            continue
        with (framework / name).open('rb') as stream:
            if stream.read(4) not in runtime.MACHO_MAGIC:
                continue
        machos.append(name)
        require(command('runtime-architecture', '/usr/bin/lipo', '-archs',
                        framework / name).stdout.strip() == 'arm64', 'runtime-architecture')
        verify_code(framework / name, team)
    require(machos and set(machos) == {row['path'] for row in receipt['transformations']}, 'runtime-code-inventory')
    return rows, sha(receipt_path)


def verify_code(path, team, identifier=None):
    requirement = runtime.developer_id_requirement(team)
    if identifier:
        requirement += ' and identifier "' + identifier + '"'
    command('publisher-signature', '/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', requirement, path)
    details = command('publisher-properties', '/usr/bin/codesign', '-d', '--verbose=4', path).stderr
    lines = details.splitlines()
    require('TeamIdentifier=' + team in lines and '(runtime)' in details
            and any(line.startswith('Timestamp=') for line in lines)
            and (identifier is None or 'Identifier=' + identifier in lines), 'publisher-properties')
    entitlements = command('publisher-entitlements', '/usr/bin/codesign', '-d', '--entitlements', ':-', path)
    # codesign emits no payload or an XML empty dictionary for empty entitlements.
    payload = (entitlements.stdout + entitlements.stderr).strip()
    if '<?xml' in payload:
        payload = payload[payload.index('<?xml'):payload.index('</plist>') + len('</plist>')]
        require(plistlib.loads(payload.encode()) == {}, 'unexpected-entitlements')
    else:
        require('<key>' not in payload and 'bplist' not in payload, 'unexpected-entitlements')


def signing_configuration(fingerprint, keychain, team):
    require(re.fullmatch(r'[A-Fa-f0-9]{40}', fingerprint) is not None, 'certificate-fingerprint')
    expected = json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier']
    require(team == expected, 'publisher-team')
    private_parent(keychain)
    require(keychain.is_file() and keychain.stat().st_nlink == 1
            and keychain.stat().st_uid == os.getuid(), 'isolated-keychain')
    identities = command('signing-identity', '/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain).stdout
    matches = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"\s*$', identities, re.MULTILINE)
    require(any(digest.upper() == fingerprint.upper() and name.startswith('Developer ID Application: ')
                and name.endswith(' (' + team + ')') for digest, name in matches), 'signing-identity')


def verify_source(revision, source_digest):
    try:
        require(load('ci-shards').git_source_digest(ROOT, revision) == source_digest, 'checkout-source-binding')
    except Exception:
        raise Refusal('checkout-source-binding') from None


def assemble(args):
    require(sys.platform == 'darwin' and os.getuid() != 0, 'macos-user-required')
    require(re.fullmatch('[0-9a-f]{40}', args.source_revision) and args.source_revision != '0' * 40
            and re.fullmatch('[0-9a-f]{64}', args.source_sha256) and args.source_sha256 != '0' * 64,
            'source-binding')
    verify_source(args.source_revision, args.source_sha256)
    app, runtime_output, output = Path(args.app), Path(args.runtime_output), Path(args.output)
    keychain = Path(args.keychain)
    signing_configuration(args.signing_identity, keychain, args.publisher_team)
    private_parent(output)
    require(not os.path.lexists(output), 'existing-output')
    build_record = Path(args.build_record)
    build_digest, built_package = build_handoff(build_record, app, args.source_revision, args.source_sha256)
    app_rows, info = raw_bundle(app, args.source_revision, args.source_sha256)
    require({'ShadowSync.app/' + name: {'sha256': row['sha256'], 'mode': row['mode']}
             for name, row in app_rows.items() if row['kind'] == 'file'} == built_package,
            'raw-capture-producer-binding')
    runtime_rows, runtime_receipt = runtime_bundle(runtime_output, args.publisher_team)
    additions = {name: (ROOT / 'Resources' / name).read_bytes() for name in ADDED_RESOURCES}
    output.mkdir(mode=0o700)
    staged = output / 'ShadowSync.app'
    shutil.copytree(app, staged, symlinks=True)
    require(tree(staged) == app_rows and tree(app) == app_rows, 'copied-app-binding')
    # Development artifacts are private; distributed code has the exact publisher
    # modes enforced by the application. Input bundles are never modified.
    staged.chmod(0o755)
    for name, row in app_rows.items():
        (staged / name).chmod(0o755 if row['kind'] == 'directory' or name in EXECUTABLES else 0o644)
    for name, data in additions.items():
        path = staged / 'Contents/Resources' / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o644)
    frameworks = staged / 'Contents/Frameworks'
    frameworks.mkdir(mode=0o755)
    frameworks.chmod(0o755)
    framework = frameworks / 'Python.framework'
    shutil.copytree(runtime_output / 'Python.framework', framework, symlinks=True)
    require(framework.stat().st_mode & 0o7777 == 0o755
            and tree(framework) == runtime_rows and tree(runtime_output / 'Python.framework') == runtime_rows,
            'copied-runtime-binding')
    for target, identifier in ((staged / 'Contents/Helpers/ShadowSyncLifecycleCoordinator', HELPER_ID),
                               (staged, APP_ID)):
        command('sign-bundle', '/usr/bin/codesign', '--force', '--sign', args.signing_identity,
                '--keychain', keychain, '--options', 'runtime', '--timestamp', '--identifier', identifier, target)
        verify_code(target, args.publisher_team, identifier)
    require(tree(app) == app_rows and tree(runtime_output / 'Python.framework') == runtime_rows
            and sha(runtime_output / 'runtime-build.json') == runtime_receipt
            and tree(framework) == runtime_rows
            and framework.stat().st_mode & 0o7777 == 0o755
            and (runtime_output / 'Python.framework').stat().st_mode & 0o7777 == 0o755
            and sha(build_record) == build_digest, 'preserved-inputs-and-runtime')
    # No execution of the app/coordinator here: runtime and migration qualification
    # must use the separately governed, isolated procedures.
    require(build_handoff(build_record, app, args.source_revision, args.source_sha256)
            == (build_digest, built_package), 'final-build-handoff-binding')
    verify_source(args.source_revision, args.source_sha256)
    receipt = dict(schema='shadow-sync-release-assembly/v1',
                   revision=args.source_revision, source_sha256=args.source_sha256,
                   assembler_sha256=sha(Path(__file__)), build_receipt_sha256=build_digest,
                   runtime_receipt_sha256=runtime_receipt,
                   version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                   publisher_team=args.publisher_team, architecture='arm64',
                   release_contract_sha256=sha(ROOT / 'Resources/release-contract.json'),
                   output_entries=tree(staged), notarized=False, published=False,
                   installed=False, product_accepted=False)
    execution.write_json(output / 'release-assembly.json', receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'build-record', 'runtime-output', 'output', 'signing-identity', 'keychain',
                 'publisher-team', 'source-revision', 'source-sha256'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        receipt = assemble(args)
    except (Refusal, runtime.BuildRefused, OSError, ValueError, KeyError, TypeError):
        print('Release assembly refused; no artifact is qualified.', file=sys.stderr)
        return 1
    print(json.dumps({key: receipt[key] for key in ('schema', 'revision', 'version', 'build',
                      'publisher_team', 'notarized', 'published', 'installed', 'product_accepted')}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
