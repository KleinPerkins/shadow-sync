#!/usr/bin/env python3
"""Build/assemble the separately identified signed disposable fixture package.

No production release factory accepts this profile. Build and assemble are
explicit native actions, never performed by discovery or offline unit tests.
This tool does not fetch, install, publish, notarize, launch a fixture, unlock a
keychain, or change production command-graph enrollment. Failed outputs remain.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILE = 'signed-installation/v1'
FIXTURE_RESOURCES = ('signed-installation-fixture.json', 'signed-installation-graph.json')


class Refusal(Exception):
    pass


def require(value, stage):
    if not value:
        raise Refusal(stage)


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def decode(raw):
    def pairs(rows):
        value = {}
        for key, item in rows:
            require(key not in value, 'duplicate-json-key')
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=pairs)


def regular_bytes(path, maximum=128 * 1024 * 1024):
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.getuid()
            and before.st_size <= maximum, 'unsafe-input-file')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(identity(os.fstat(fd)) == identity(before), 'input-replaced')
        chunks = []; total = 0
        while True:
            data = os.read(fd, 65536)
            if not data:
                break
            chunks.append(data); total += len(data)
            require(total <= maximum, 'input-size')
        result = b''.join(chunks)
        require(len(result) == before.st_size and identity(os.fstat(fd)) == identity(before)
                and identity(path.lstat()) == identity(before), 'input-changed')
        return result
    finally:
        os.close(fd)


def digest(path):
    return hashlib.sha256(regular_bytes(path)).hexdigest()


def source_inventory(root):
    require(root.is_absolute() and root.resolve(strict=True) == root and not (root / '.git').exists(), 'private-source-export-required')
    result = {}
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(parent) / name
            info = path.lstat()
            require(info.st_uid == os.getuid() and not stat.S_ISLNK(info.st_mode), 'source-node')
            relative = path.relative_to(root).as_posix()
            require(not any(ord(c) < 32 for c in relative) and '\\' not in relative, 'source-path')
            if stat.S_ISDIR(info.st_mode):
                continue
            data = regular_bytes(path)
            result[relative] = {'mode': stat.S_IMODE(info.st_mode), 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    require(0 < len(result) <= 8192, 'source-count')
    return result


def source_binding(path, expected, revision, root=ROOT):
    require(re.fullmatch('[0-9a-f]{64}', expected) and expected != '0' * 64
            and re.fullmatch('[0-9a-f]{40}', revision) and revision != '0' * 40, 'source-binding-format')
    raw = regular_bytes(path)
    require(hashlib.sha256(raw).hexdigest() == expected, 'source-map-digest')
    rows = decode(raw)
    require(type(rows) is dict and rows == source_inventory(root), 'source-map-inventory')
    # The supplied revision is explicitly a declaration. Exact export bytes are
    # independently bound; this tool never manufactures Git provenance.
    return rows


def required_case_ids():
    """Accepted matrix requirements; availability never removes a required row."""
    failures = ['afterReceipt', 'beforeControl', 'receiptBeforeSwap', 'receiptAfterSwap', 'receiptAfterDirectorySync',
                'controlBeforeSwap', 'controlAfterSwap', 'controlAfterDirectorySync', 'controlAfterPreimageUnlink']
    ids = ['source-preflight', 'startup-stop', 'stop-store-uncertain', 'stop-completion-uncertain',
           'stop-held-completion', 'cleanup-positive', 'terminal-positive']
    ids += ['start-adapter-join/' + n for n in ['in-budget', 'expired-complete', 'expired-pending']]
    ids += ['start-adapter-join/' + n for n in ['fault-before-bind', 'fault-after-ack', 'fault-before-join', 'fault-after-refusal', 'h-expiry']]
    ids += ['cleanup-endpoint/' + n for n in ['beforeUnlink', 'unlinkFailure', 'afterUnlink', 'parentSyncFailure', 'afterParentSync', 'beforeAncestorClose']]
    ids += ['cleanup-publication/' + n for n in failures]
    ids += ['cleanup/' + n for n in ['wrong-owner', 'reader-alias', 'queue-join', 'listener-close', 'accepted-close',
        'extra-peer-close', 'ancestor-close', 'control-replacement', 'named-missing', 'named-substituted']]
    ids += ['cleanup-named-cut/' + n for n in ['afterParking', 'afterReplacementOpen', 'afterReplacementIdentity', 'afterReplacementClose', 'beforeRestore']]
    ids += ['terminal-publication/' + action + '/' + status + '/' + failure
        for action in ['cleanupBackups', 'cleanupIncoming', 'finish'] for status in ['intent', 'complete'] for failure in failures]
    ids += ['terminal-close/' + n for n in ['temporaryStore', 'stagedSlots', 'stagedParents', 'bootstrapParents', 'metadata', 'admission', 'state', 'operation']]
    ids += ['terminal-sync/' + n for n in ['beforeParentSync', 'parentSyncFailure', 'afterParentSync', 'beforeRetirement']]
    ids += ['terminal-successful-operation-close-deadline']
    ids += ['negative/' + n for n in ['wrong-live-peer', 'wrong-same-publisher-candidate', 'reflected-message',
        'reordered-message', 'replayed-message', 'eof-before-commit', 'eof-after-consumed-commit', 'coordinator-loss',
        'caller-loss', 'host-loss-before-normal-started', 'host-loss-after-normal-started', 'pending-command-retirement',
        'delayed-appkit-initialization', 'failed-application-drain']]
    ids += ['deadline/' + n for n in ['reserve', 'exclusive-preparation', 'staged-transfer', 'journal', 'readiness-opening',
        'bootstrap', 'kickstart', 'candidate-ready', 'readiness-commit', 'normal-started', 'stop', 'cleanup', 'finish']]
    ids += ['control/' + n for n in ['own-root', 'foreign-root', 'real-home-denial', 'network-denial', 'arbitrary-exec-denial',
        'wrong-role', 'adhoc-signature', 'wrong-team', 'wrong-identifier', 'wrong-cdhash', 'testing-profile-misuse',
        'missing-seal', 'missing-layout', 'missing-policy', 'stale-policy', 'policy-digest-mismatch']]
    ids += ['fresh-driver/positive', 'fresh-driver/cancel-ready', 'fresh-driver/cancel-normal', 'fresh-driver/cleanup-after-unlink', 'fresh-driver/close/temporaryStore', 'fresh-driver/close/stagedSlots', 'fresh-driver/close/stagedParents', 'fresh-driver/close/bootstrapParents', 'fresh-driver/close/metadata', 'fresh-driver/close/admission', 'fresh-driver/close/state', 'fresh-driver/close/operation']
    ids += ['fresh-driver/ready/claimed', 'fresh-driver/ready/intentRetained', 'fresh-driver/ready/contextRetained', 'fresh-driver/ready/commandRetained', 'fresh-driver/ready/submitted', 'fresh-driver/ready/retirementReceived', 'fresh-driver/ready/aliasesReleased', 'fresh-driver/ready/retired', 'fresh-driver/ready/completed', 'fresh-driver/commit/claimed', 'fresh-driver/commit/published', 'fresh-driver/commit/delivered', 'fresh-driver/publication/candidateIntent/afterReceipt', 'fresh-driver/publication/candidateIntent/beforeControl', 'fresh-driver/publication/candidateIntent/receiptBeforeSwap', 'fresh-driver/publication/candidateIntent/receiptAfterSwap', 'fresh-driver/publication/candidateIntent/receiptAfterDirectorySync', 'fresh-driver/publication/candidateIntent/controlBeforeSwap', 'fresh-driver/publication/candidateIntent/controlAfterSwap', 'fresh-driver/publication/candidateIntent/controlAfterDirectorySync', 'fresh-driver/publication/candidateIntent/controlAfterPreimageUnlink', 'fresh-driver/publication/candidateComplete/afterReceipt', 'fresh-driver/publication/candidateComplete/beforeControl', 'fresh-driver/publication/candidateComplete/receiptBeforeSwap', 'fresh-driver/publication/candidateComplete/receiptAfterSwap', 'fresh-driver/publication/candidateComplete/receiptAfterDirectorySync', 'fresh-driver/publication/candidateComplete/controlBeforeSwap', 'fresh-driver/publication/candidateComplete/controlAfterSwap', 'fresh-driver/publication/candidateComplete/controlAfterDirectorySync', 'fresh-driver/publication/candidateComplete/controlAfterPreimageUnlink', 'fresh-driver/publication/commitIntent/afterReceipt', 'fresh-driver/publication/commitIntent/beforeControl', 'fresh-driver/publication/commitIntent/receiptBeforeSwap', 'fresh-driver/publication/commitIntent/receiptAfterSwap', 'fresh-driver/publication/commitIntent/receiptAfterDirectorySync', 'fresh-driver/publication/commitIntent/controlBeforeSwap', 'fresh-driver/publication/commitIntent/controlAfterSwap', 'fresh-driver/publication/commitIntent/controlAfterDirectorySync', 'fresh-driver/publication/commitIntent/controlAfterPreimageUnlink', 'fresh-driver/publication/commitComplete/afterReceipt', 'fresh-driver/publication/commitComplete/beforeControl', 'fresh-driver/publication/commitComplete/receiptBeforeSwap', 'fresh-driver/publication/commitComplete/receiptAfterSwap', 'fresh-driver/publication/commitComplete/receiptAfterDirectorySync', 'fresh-driver/publication/commitComplete/controlBeforeSwap', 'fresh-driver/publication/commitComplete/controlAfterSwap', 'fresh-driver/publication/commitComplete/controlAfterDirectorySync', 'fresh-driver/publication/commitComplete/controlAfterPreimageUnlink', 'fresh-driver/delivery/afterReadback', 'fresh-driver/delivery/afterSendReservation', 'fresh-driver/lost-normal-started', 'fresh-driver/late-normal-started']
    return {'signed-installation/' + case for case in ids}


def registration(root=ROOT):
    value = decode(regular_bytes(root / 'config/signed-installation-fixtures.json'))
    require(set(value) == {'schema', 'build_profile', 'qualification', 'cases', 'required_binary_markers',
        'inherited_roles', 'root_disposition', 'native_qualification_required', 'unavailable_requirements'}, 'registration-fields')
    require(value['schema'] == 'shadow-sync-signed-installation-fixtures/v1' and value['build_profile'] == PROFILE
            and value['qualification'] == 'signed-adapter-only'
            and value['root_disposition'] == 'creator-after-coordinator-reap', 'registration-profile')
    case_source = regular_bytes(root / 'Sources/ShadowSyncCore/SignedInstallationFixtureCase.swift').decode()
    require(case_source.startswith('#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE\n'), 'case-build-fence')
    declared = re.findall(r'^    case [A-Za-z0-9]+ = "(signed-installation/[^"\n]+)"$', case_source, re.MULTILINE)
    require(0 < len(declared) <= 2048 and len(declared) == len(set(declared)), 'closed-source-case-roster')
    positive = {'signed-installation/startup-stop', 'signed-installation/cleanup-positive', 'signed-installation/terminal-positive', 'signed-installation/fresh-driver/positive'}
    # This additional positive proves command retirement only, not full startup.
    positive.add('signed-installation/start-adapter-join/in-budget')
    require(positive.issubset(declared), 'required-positive-cases')
    expected_cases = [{'id': 'signed-installation/source-preflight', 'suite': 'signed-installation-source',
        'argument': '--verify-signed-installation-fixture-source', 'kind': 'source-preflight'}]
    expected_cases += [{'id': case, 'suite': 'signed-installation-adapter', 'argument': '--verify-signed-installation-fixture',
        'kind': 'installation-positive' if case in positive else 'installation-cut'} for case in declared]
    require(value['cases'] == expected_cases, 'closed-case-roster')
    require(value['inherited_roles'] == {'coordinator': [0, 1, 2, 207, 208, 209],
            'host': [0, 1, 2, 213], 'adapter': [0, 1, 2, 198, 212]}, 'closed-descriptor-roster')
    join_markers = {'signed-installation/start-adapter-join/' + n for n in ('in-budget', 'expired-complete', 'expired-pending')}
    join_markers.add('SignedInstallationFixtureJoinController')
    require(join_markers.issubset(value['required_binary_markers'].get('Contents/Helpers/ShadowSyncLifecycleCoordinator', [])),
            'join-required-binary-markers')
    control_markers = {'SignedInstallationFixtureJoinControlOwner', 'signed-installation/start-adapter-join/fault-before-join', 'SignedInstallationFixtureJoinControlFixtures', 'signed-installation/start-adapter-join/fault-after-ack', 'signed-installation/start-adapter-join/fault-after-refusal', 'SIGNED_JOIN_CONTROL_V1', 'signed-installation/start-adapter-join/fault-before-bind', 'signed-installation/start-adapter-join/h-expiry'}
    require(control_markers.issubset(value['required_binary_markers'].get('Contents/Helpers/ShadowSyncLifecycleCoordinator', [])),
            'control-required-binary-markers')
    # These initial driver routes are compiled only in the separate signed
    # fixture. Ordinary testing must exclude them just like production; their
    # positive controls must be checked against the actual signed helper bytes.
    fresh_markers = {'SignedFreshInstallationDriverFixture'}
    fresh_markers.update('signed-installation/fresh-driver/' + suffix for suffix in (
        'positive', 'cancel-normal', 'cancel-ready', 'cleanup-after-unlink',
        'close/temporaryStore', 'close/stagedSlots', 'close/stagedParents',
        'close/bootstrapParents', 'close/metadata', 'close/admission', 'close/state', 'close/operation'))
    ordinary = decode(regular_bytes(root / 'Tests/Fixtures/production-test-markers.json'))
    signed = decode(regular_bytes(root / 'Tests/Fixtures/signed-installation-source-markers.json'))
    require(fresh_markers.isdisjoint(ordinary['markers']) and fresh_markers.issubset(signed['markers']),
            'fresh-driver-build-classification')
    require(fresh_markers.issubset(value['required_binary_markers'].get('Contents/Helpers/ShadowSyncLifecycleCoordinator', [])),
            'fresh-driver-required-binary-markers')
    required = value['unavailable_requirements']
    require(type(required) is list and bool(required) and all(set(row) == {'id', 'status', 'reason'}
        and row['status'] == 'required-unavailable' and row['reason'] == 'source-route-or-reviewed-caller-pending'
        and row['id'].startswith('signed-installation/') for row in required), 'unavailable-coverage-contract')
    all_ids = [row['id'] for row in value['cases'] + required]
    require(len(all_ids) == len(set(all_ids)), 'duplicate-required-coverage')
    require(set(all_ids) == required_case_ids(), 'missing-required-coverage')
    return value


def build_markers(app, contract):
    for relative, markers in contract['required_binary_markers'].items():
        require(relative in ('Contents/MacOS/ShadowSync', 'Contents/Helpers/ShadowSyncLifecycleCoordinator'), 'binary-role')
        raw = regular_bytes(app / relative)
        require(markers and all(type(marker) is str and marker.encode() in raw for marker in markers), 'missing-reachable-binary-route')


def fixture_info(app, revision, source_digest, root=ROOT):
    info = plistlib.loads(regular_bytes(app / 'Contents/Info.plist'))
    template = plistlib.loads(regular_bytes(root / 'Resources/Info.plist'))
    expected = dict(template, ShadowSyncBuildMode='testing', ShadowSyncSourceRevision=revision,
        ShadowSyncSourceInputSHA256=source_digest, ShadowSyncReleaseContractSHA256=digest(root / 'Resources/release-contract.json'),
        ShadowSyncSignedFixtureProfile=PROFILE)
    require(info == expected, 'testing-fixture-info-binding')
    return info


def fresh_output(path):
    require(path.is_absolute() and path.parent.resolve(strict=True) == path.parent and not os.path.lexists(path), 'fresh-output')
    info = path.parent.stat()
    require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
            and str(path).startswith('/private/tmp/'), 'private-output-parent')
    path.mkdir(mode=0o700)


def write(path, value):
    with path.open('xb') as stream:
        stream.write(encode(value)); stream.flush(); os.fsync(stream.fileno())


def policy_documents(contract):
    """Closed empty fixture topology; the actual module is supplied separately."""
    require(set(contract) == {'schema', 'status', 'release_revision', 'module_sha256'}
        and contract['schema'] == 'shadow-sync-awa-contract/v1' and contract['status'] == 'qualified'
        and re.fullmatch('[0-9a-f]{40}', contract['release_revision'])
        and re.fullmatch('[0-9a-f]{64}', contract['module_sha256']), 'qualified-policy-contract')
    policy = b'version: 1\nhard_no_touch_paths:\n  roots: []\n'
    overlay = b'{"fixture":true}\n'
    dispatcher = b'#!/bin/sh\nexit 0\n'
    def payload(path, data):
        return {'path': path, 'sha256': hashlib.sha256(data).hexdigest()}
    projection = {
        'schema': 'shadow-sync-host-policy-projection/v1',
        'source_inputs': {'worktree_policy': payload('owner/policy.yml', policy),
            'host_overlay': payload('owner/overlay.json', overlay), 'hook_dispatcher': payload('owner/dispatcher', dispatcher)},
        'governed_root': {'components': ['workspace'], 'display_label': '~/workspace', 'repository_id': 'fixture-owner/root'},
        'shelves': [['products']],
        'path_policy': {'excluded': ['.'], 'read_only': [], 'artifacts': [], 'writable': ['.']},
        'permanent_no_touch_repository_ids': ['fixture-owner/protected'], 'managed_locations': [],
        'hooks': {'foreign_markers': ['fixture-hook'], 'dispatcher_base64': base64.b64encode(dispatcher).decode(),
                  'dispatcher_sha256': hashlib.sha256(dispatcher).hexdigest()}, 'awa_evidence': None}
    projection_bytes = encode(projection)
    binding = {'schema': 'shadow-sync-host-policy-binding/v1', 'policy': payload('owner/policy.yml', policy),
        'projection': payload('owner/projection.json', projection_bytes),
        'awa': {'module_path': 'runtime/policy.py', 'module_sha256': contract['module_sha256'],
                'release_revision': contract['release_revision']}}
    return {'Library/Application Support/ShadowSync/host-policy-binding.json': encode(binding),
        'owner/policy.yml': policy, 'owner/overlay.json': overlay,
        'owner/dispatcher': dispatcher, 'owner/projection.json': projection_bytes}


def policy_payload(module, contract):
    require(hashlib.sha256(module).hexdigest() == contract['module_sha256'], 'qualified-policy-module-unavailable')
    return dict(policy_documents(contract), **{'runtime/policy.py': module})


def write_policy_payload(output, module, contract):
    # Output is a newly owned package root. No live home lookup or fallback.
    root = output / 'isolated-policy'; root.mkdir(mode=0o700)
    for relative, data in policy_payload(module, contract).items():
        path = root / relative
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for parent in path.parents:
            if parent == output:
                break
            parent.chmod(0o700)
        with path.open('xb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        path.chmod(0o600)
    return source_inventory(root)


def build_fixture(args):
    rows = source_binding(Path(args.source_map), args.source_map_sha256, args.source_revision)
    contract = registration()
    # Reuse only the exact owner toolchain gate; no Git-dependent CI verifier.
    build = load('ci-build')
    toolchain = build.toolchain()
    output = Path(args.output); fresh_output(output)
    command = ['/bin/bash', str(ROOT / 'scripts/build-app.sh'), '--signed-installation-fixture',
        '--scratch-path', str(output / 'scratch'), '--output-dir', str(output / 'package'),
        '--source-revision', args.source_revision, '--source-input-sha256', args.source_map_sha256]
    build.run(command, timeout=1800)
    app = output / 'package/ShadowSync.app'
    fixture_info(app, args.source_revision, args.source_map_sha256)
    build_markers(app, contract)
    assembly = load('assemble-release-bundle')
    actual = assembly.tree(app)
    require({p for p, row in actual.items() if row['kind'] == 'file'} == assembly.RAW_FILES
            and {p for p, row in actual.items() if row['kind'] == 'directory'} == assembly.RAW_DIRECTORIES
            and all(row['kind'] != 'symlink' for row in actual.values()), 'raw-fixture-layout')
    require(source_binding(Path(args.source_map), args.source_map_sha256, args.source_revision) == rows, 'source-changed-during-build')
    receipt = {'schema': 'shadow-sync-signed-fixture-build/v1', 'profile': PROFILE,
        'declared_revision': args.source_revision, 'source_map_sha256': args.source_map_sha256,
        'builder_sha256': digest(Path(__file__)), 'build_script_sha256': digest(ROOT / 'scripts/build-app.sh'),
        'registration_sha256': digest(ROOT / 'config/signed-installation-fixtures.json'),
        'isolation_generator_sha256': digest(ROOT / 'scripts/signed-fixture-isolation.py'), 'toolchain': toolchain,
        'app_entries': actual, 'build_mode': 'testing', 'signature_mode': 'ad-hoc-development-only',
        'native_qualified': False, 'installed': False}
    write(output / 'signed-fixture-build.json', receipt)
    return receipt


def sign_fixture(path, identifier, identity, keychain, assembly):
    # codesign creates sealed CodeResources. A child-local umask keeps those
    # resources readable by the exact publisher layout without mutating the
    # process-wide umask or rewriting any bytes after the outer seal.
    process = subprocess.Popen(['/usr/bin/codesign', '--force', '--sign', identity,
        '--keychain', str(keychain), '--options', 'runtime', '--timestamp', '--identifier', identifier, str(path)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        cwd=ROOT, env=assembly.execution.child_environment(os.environ), start_new_session=True, umask=0o022)
    try:
        process.communicate(timeout=120)
        require(process.returncode == 0, 'fixture-signature')
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise


def code_hash(assembly, path, team, identifier):
    assembly.verify_code(path, team, identifier)
    details = assembly.command('fixture-code-directory', '/usr/bin/codesign', '-d', '--verbose=4', path).stderr
    matches = re.findall(r'^CDHash=([0-9a-f]{40})$', details, re.MULTILINE)
    require(len(matches) == 1, 'code-directory-digest')
    return matches[0]


def canonical_bundle(app, rows):
    records = ['d\0.\0' + str(stat.S_IMODE(app.stat().st_mode)) + '\x000\0-']
    for path, row in rows.items():
        mode = str(row['mode'])
        if row['kind'] == 'directory':
            records.append('d\0' + path + '\0' + mode + '\x000\0-')
        elif row['kind'] == 'file':
            records.append('f\0' + path + '\0' + mode + '\0' + str(row['bytes']) + '\0' + row['sha256'])
        else:
            require(row['kind'] == 'symlink' and path.startswith('Contents/Frameworks/Python.framework/'), 'bundle-link')
            data = row['target'].encode()
            records.append('l\0' + path + '\0' + mode + '\0' + str(len(data)) + '\0' + hashlib.sha256(data).hexdigest())
    return hashlib.sha256(('\0'.join(sorted(records)) + '\0').encode()).hexdigest()


def assemble_fixture(args):
    require(sys.platform == 'darwin' and os.getuid() != 0, 'macos-user-required')
    source = source_binding(Path(args.source_map), args.source_map_sha256, args.source_revision)
    contract = registration()
    assembly = load('assemble-release-bundle')
    record_path = Path(args.build_record)
    assembly.private_parent(record_path)
    require(record_path.name == 'signed-fixture-build.json', 'fixture-build-record-name')
    record_bytes = regular_bytes(record_path); record = decode(record_bytes)
    require(type(record) is dict and set(record) == {'schema', 'profile', 'declared_revision', 'source_map_sha256',
        'builder_sha256', 'build_script_sha256', 'registration_sha256', 'isolation_generator_sha256', 'toolchain', 'app_entries', 'build_mode',
        'signature_mode', 'native_qualified', 'installed'} and record['native_qualified'] is False
        and record['installed'] is False, 'closed-build-record')
    require(record['schema'] == 'shadow-sync-signed-fixture-build/v1' and record['profile'] == PROFILE
        and record['declared_revision'] == args.source_revision and record['source_map_sha256'] == args.source_map_sha256
        and record['builder_sha256'] == digest(Path(__file__)) and record['build_script_sha256'] == digest(ROOT / 'scripts/build-app.sh')
        and record['registration_sha256'] == digest(ROOT / 'config/signed-installation-fixtures.json')
        and record['isolation_generator_sha256'] == digest(ROOT / 'scripts/signed-fixture-isolation.py')
        and record['build_mode'] == 'testing' and record['signature_mode'] == 'ad-hoc-development-only'
        and record['toolchain'] == load('ci-build').toolchain(), 'fixture-build-handoff')
    original = record_path.parent / 'package/ShadowSync.app'
    info = fixture_info(original, args.source_revision, args.source_map_sha256)
    build_markers(original, contract)
    raw = assembly.tree(original)
    require(raw == record['app_entries'] and {p for p, row in raw.items() if row['kind'] == 'file'} == assembly.RAW_FILES
            and {p for p, row in raw.items() if row['kind'] == 'directory'} == assembly.RAW_DIRECTORIES
            and all(row['kind'] != 'symlink' for row in raw.values()), 'raw-fixture-inventory')
    for destination, source_path in assembly.SOURCE_RESOURCES.items():
        require(raw[destination]['sha256'] == digest(ROOT / source_path), 'raw-source-resource')
    policy_module = regular_bytes(Path(args.policy_module), maximum=1_048_576)
    policy_contract = decode(regular_bytes(ROOT / 'Resources/awa-contract.json'))
    require(policy_contract['status'] == 'qualified' and hashlib.sha256(policy_module).hexdigest() == policy_contract['module_sha256'], 'qualified-policy-module-unavailable')
    runtime = Path(args.runtime_output)
    runtime_rows, runtime_receipt = assembly.runtime_bundle(runtime, args.publisher_team)
    assembly.signing_configuration(args.signing_identity, Path(args.keychain), args.publisher_team)
    output = Path(args.output); fresh_output(output)
    staged = output / 'ShadowSync.app'
    shutil.copytree(original, staged, symlinks=False)
    require(assembly.tree(staged) == raw, 'copied-raw-binding')
    staged.chmod(0o755)
    for path, row in raw.items():
        (staged / path).chmod(0o755 if row['kind'] == 'directory' or path in assembly.EXECUTABLES else 0o644)
    for name in assembly.ADDED_RESOURCES:
        target = staged / 'Contents/Resources' / name
        with target.open('xb') as stream:
            stream.write(regular_bytes(ROOT / 'Resources' / name))
        target.chmod(0o644)
    frameworks = staged / 'Contents/Frameworks'; frameworks.mkdir(mode=0o755); frameworks.chmod(0o755)
    shutil.copytree(runtime / 'Python.framework', frameworks / 'Python.framework', symlinks=True)
    require(assembly.tree(frameworks / 'Python.framework') == runtime_rows, 'copied-runtime')
    helper = staged / 'Contents/Helpers/ShadowSyncLifecycleCoordinator'
    def sign(path, identifier):
        sign_fixture(path, identifier, args.signing_identity, Path(args.keychain), assembly)
        return code_hash(assembly, path, args.publisher_team, identifier)
    helper_hash = sign(helper, assembly.HELPER_ID)
    package_contract = {'schema': 'shadow-sync-signed-installation-package/v1', 'source': args.source_map_sha256,
                        'cases': [row['id'] for row in contract['cases']]}
    graph = {'schema': 'shadow-sync-signed-installation-graph/v1', 'source': args.source_map_sha256,
        'identifier': assembly.HELPER_ID, 'cdhash': helper_hash, 'behavior': 'single-image-no-descendants',
        'roles': ['service-read', 'service-mutation', 'signature-check']}
    for name, value in zip(FIXTURE_RESOURCES, (package_contract, graph)):
        path = staged / 'Contents/Resources' / name; write(path, value); path.chmod(0o644)
    app_hash = sign(staged, assembly.APP_ID)
    require(helper_hash == code_hash(assembly, helper, args.publisher_team, assembly.HELPER_ID), 'helper-changed-after-outer-seal')
    actual = assembly.tree(staged)
    require(assembly.tree(original) == raw and assembly.tree(runtime / 'Python.framework') == runtime_rows
        and regular_bytes(record_path) == record_bytes and source_binding(Path(args.source_map), args.source_map_sha256, args.source_revision) == source,
        'preserved-inputs')
    fixture_info(staged, args.source_revision, args.source_map_sha256)
    build_markers(staged, contract)
    policy_entries = write_policy_payload(output, policy_module, policy_contract)
    receipt = {'schema': 'shadow-sync-signed-fixture-package/v1', 'profile': PROFILE, 'build_mode': 'testing',
        'declared_revision': args.source_revision, 'source_map_sha256': args.source_map_sha256,
        'producer_sha256': digest(Path(__file__)), 'build_record_sha256': hashlib.sha256(record_bytes).hexdigest(),
        'registration_sha256': digest(ROOT / 'config/signed-installation-fixtures.json'),
        'isolation_generator_sha256': digest(ROOT / 'scripts/signed-fixture-isolation.py'),
        'runtime_receipt_sha256': runtime_receipt, 'policy_module_sha256': policy_contract['module_sha256'],
        'isolated_policy_entries': policy_entries,
        'app_cdhash': app_hash, 'helper_cdhash': helper_hash, 'bundle_sha256': canonical_bundle(staged, actual),
        'app_sha256': digest(staged / 'Contents/MacOS/ShadowSync'), 'helper_sha256': digest(helper),
        'release': {'schema': info['ShadowSyncReleaseSchema'], 'version': info['CFBundleShortVersionString'],
            'buildNumber': info['CFBundleVersion'], 'sourceRevision': args.source_revision, 'sourceInputSHA256': args.source_map_sha256,
            'releaseContractSHA256': digest(ROOT / 'Resources/release-contract.json'), 'architecture': 'arm64',
            'minimumSystemVersion': '26.0', 'buildMode': 'testing'},
        'entries': actual, 'signature_mode': 'Developer-ID', 'native_qualified': False, 'graph_qualified': False,
        'installed': False, 'published': False, 'notarized': False}
    write(output / 'signed-fixture-package.json', receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('list-cases')
    for action in ('build', 'assemble'):
        child = sub.add_parser(action)
        for name in ('source-map', 'source-map-sha256', 'source-revision', 'output'):
            child.add_argument('--' + name, required=True)
        if action == 'assemble':
            for name in ('build-record', 'runtime-output', 'policy-module', 'signing-identity', 'keychain', 'publisher-team'):
                child.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        if args.action == 'list-cases':
            print(json.dumps({'cases': registration()['cases'], 'unavailable_requirements': registration()['unavailable_requirements'],
                'native_qualified': False}, sort_keys=True))
        else:
            value = build_fixture(args) if args.action == 'build' else assemble_fixture(args)
            print(json.dumps({'schema': value['schema'], 'native_qualified': False, 'installed': False}, sort_keys=True))
    except Exception:
        print('Signed fixture package unavailable; failed outputs are retained.', file=sys.stderr)
        return 78
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
