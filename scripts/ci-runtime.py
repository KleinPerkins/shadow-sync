#!/usr/bin/env python3
"""Run one registered safety suite with the qualified guardian/isolation contract."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import stat
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from runtime_guardian_executor import execute
from ci_crash_diagnostic import capture as capture_crash


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


build = load('ci-build')
require = build.require
PREFIXES = ('shadow-sync-m2.', 'shadow-sync-m4.', 'shadow-sync-self-tests.',
    'shadow-sync-custody-anchor-', 'shadow-sync-m6-self.', 'shadow-sync-custody-leases.',
    'shadow-sync-custody-catalog.', 'shadow-sync-ic.', 'shadow-sync-fresh-state.', 'shadow-sync-registry.',
    'shadow-sync-state-admission.', 'shadow-sync-policy-input-', 'shadow-sync-policy-transport-',
    'shadow-sync-policy-authority-', 'shadow-sync-catalog-admission-', 'shadow-sync-publisher-policy-',
    'shadow-sync-discovery-spawn.', 'shadow-sync-fixture-config.', 'shadow-sync-v3-preferences.',
    'shadow-sync-v3-preferences-pre-rename.', 'shadow-sync-v3-preferences-post-rename.',
    'shadow-sync-v3-catalog.', 'shadow-sync-dm4-preflight.')
# M2 also exercises the /var alias using this one explicit private fixture root.
FIXTURE_LOCATIONS = tuple(('/private/tmp', prefix) for prefix in PREFIXES) + (
    ('/private/var/tmp', 'shadow-sync-m2.'),)
TOOLS = ('/bin/bash', '/bin/sleep', '/bin/sh', '/bin/chmod', '/bin/cat', '/bin/echo',
    '/usr/bin/printf', '/usr/bin/grep', '/usr/bin/env', '/usr/bin/git', '/usr/bin/xcrun',
    '/Library/Developer/CommandLineTools/usr/bin/git',
    '/Library/Developer/CommandLineTools/usr/libexec/git-core/git',
    '/Library/Developer/CommandLineTools/usr/libexec/git-core/git-upload-pack',
    '/Library/Developer/CommandLineTools/usr/bin/clang', '/Library/Developer/CommandLineTools/usr/bin/ld')


def profile(root, nonce, executable, app, python):
    quote = lambda value: json.dumps(str(value), ensure_ascii=True)
    result = '(version 1)\n(allow default)\n(deny network*)\n'
    # Do not enumerate any real repository or installed state to test this denial.
    for home in sorted({'/Users', pwd.getpwuid(os.getuid()).pw_dir}):
        result += '(deny file-read* file-write* (subpath ' + quote(home) + '))\n'
    result += '(allow file-read* (subpath ' + quote(ROOT) + '))\n(deny file-write*)\n'
    result += '(allow file-write* (subpath ' + quote(root) + '))\n'
    result += '(allow file-write* (literal "/dev/null"))\n(deny process-exec)\n'
    for path in (executable, app, python, *TOOLS):
        result += '(allow process-exec (literal ' + quote(path) + '))\n'
    for parent, prefix in FIXTURE_LOCATIONS:
        escaped = prefix.replace('.', '[.]')
        result += '(deny file-read* file-write* (regex #"^' + parent + '/' + escaped + '"))\n'
        result += '(allow file-read* file-write* (regex #"^' + parent + '/' + escaped + nonce + '[.][A-Za-z0-9-]+(/.*)?$"))\n'
    # Exact non-executable state fixtures must retain intentionally unsafe mode
    # bits so strict admission tests exercise refusal, not a normalized fixture.
    # The same scoped operation permits the preserved.log hardlink input.
    result += '(allow file-write-setugid (regex #"^/private/tmp/shadow-sync-state-admission[.]' + nonce + '[.][A-Za-z0-9-]+/state/shadow-sync(/(latest[.]log|preserved[.]log|lifecycle[.]lock|operation[.]lock|run[.]lock|launcher[.]lock))?$"))\n'
    suffixes = (r'/[^/]+(/[A-Za-z0-9-]+)*/[.]git/hooks/(post-merge|pre-merge-commit|pre-commit|reference-transaction)',
        r'/[^/]+(/[A-Za-z0-9-]+)*/[.]githooks/reference-transaction',
        r'/home/dev/_ops/bin/(dev-worktree[.]sh|install-identity-guard[.]sh)',
        r'/(fake-gh|sleep-gh|large-gh|failure-gh)',
        r'/(hostile|blocking)-fsmonitor[.]sh')
    for suffix in suffixes:
        result += '(allow process-exec (regex #"^/private/tmp/shadow-sync-self-tests[.]' + nonce + '[.][A-Za-z0-9-]+' + suffix + '$"))\n'
    # Local test IPC only; Internet and unrelated local sockets remain denied.
    for prefix in ('shadow-sync-m4.', 'shadow-sync-self-tests.'):
        escaped = prefix.replace('.', '[.]')
        result += '(allow network-bind network-inbound network-outbound (regex #"^/private/tmp/' + escaped + nonce + '[.][A-Za-z0-9-]+(/[^/]+)*/(host[.]sock|agent[.]sock)$"))\n'
    # Installation fixtures create this one endpoint in the fixed state layout.
    # Keep it separate from ordinary host IPC and from arbitrary local sockets.
    result += '(allow network-bind network-inbound network-outbound (regex #"^/private/tmp/shadow-sync-ic[.]' + nonce + '[.][A-Za-z0-9-]+/state/shadow-sync/installation[.]sock$"))\n'
    return result + '(allow process-exec (regex #"^/private/tmp/shadow-sync-publisher-policy-' + nonce + '[.][A-Za-z0-9-]+/executable$"))\n'


def canonical_output(suite, cases, data, *, complete):
    """Adapt the actual guardian stdout namespace; never synthesize case passes."""
    lines = data.decode('utf-8', errors='strict').splitlines()
    prefix = 'PASS ' + suite + '/'
    seen, output = [], []
    for line in lines:
        if line.startswith('PASS '):
            require(line.startswith(prefix), 'Foreign runtime PASS namespace')
            case = line[len(prefix):]
            require(case in cases and case not in seen, 'Unknown or duplicate runtime case')
            seen.append(case)
            output.append('PASS ' + case)
        else:
            output.append(line)
    if complete:
        require(set(seen) == set(cases), 'Runtime stdout lacks the complete actual case roster')
    return ('\n'.join(output) + '\n').encode('utf-8')


def stage_policy_source(root):
    # The self-tests deliberately accept resource inputs only from private fixture
    # roots. Hosted checkouts live under /Users, so stage these exact pinned bytes.
    source = ROOT / 'Resources/policy-runtime-source.json'
    target = root / 'policy-runtime-source.json'
    data = source.read_bytes()
    with target.open('xb') as stream:
        stream.write(data)
    target.chmod(0o600)
    require(target.read_bytes() == data == source.read_bytes(), 'Policy source staging changed')
    return target


def stage_runtime_executable(root, source):
    # Keep the original build immutable. The fixture publisher contract requires
    # 0755 executable files beneath an owner-private parent directory.
    target = root / 'ShadowSyncSelfTest'
    native = load('run-native-appkit')
    native.stage_binary(source, target, build.sha(source))
    target.chmod(0o755)
    native.binary_identity(target, build.sha(source))
    return target


def validate_retention_cleanup_costs(suite, retention_cleanup_costs):
    require(type(retention_cleanup_costs) is bool, "Retention cleanup costs must be a boolean")
    require(not retention_cleanup_costs or suite == "body3",
            "Retention cleanup costs are supported only for Body3")


def fixture_environment(suite, root, nonce, python, build_root, framework, policy_source,
                        *, retention_cleanup_costs=False):
    validate_retention_cleanup_costs(suite, retention_cleanup_costs)
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), TMPDIR=str(root / 'tmp'),
        SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE=nonce, LANG='C', LC_ALL='C',
        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null',
        SHADOW_SYNC_TEST_POLICY_PYTHON=str(python),
        SHADOW_SYNC_TEST_PUBLISHER_EXECUTABLE=str(build_root / 'publisher-executable'),
        SHADOW_SYNC_TEST_POLICY_FRAMEWORK=str(framework),
        SHADOW_SYNC_TEST_POLICY_SOURCE=str(policy_source))
    if suite == 'm6':
        # Closed test-only markers preserve the failing planner path and result.
        env['SHADOW_SYNC_TEST_M6_DIAGNOSTICS'] = '1'
    if suite in ('discovery-caller', 'retention-custody', 'body3'):
        # Caller suites and Body 3 consume the bounded testing-only trace.
        # Keep the opt-in explicit; unrelated suites do not inherit host flags.
        env['SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS'] = '1'
    if retention_cleanup_costs:
        # Deliberate Body3 diagnostic only; never inherit a host opt-in.
        env['SHADOW_SYNC_TEST_RETENTION_CLEANUP_COSTS'] = '1'
    return env


def run_suite(suite, root, build_root, record, context, *, retention_cleanup_costs=False):
    validate_retention_cleanup_costs(suite, retention_cleanup_costs)
    inventory = load('runtime-suite-inventory')
    catalog = inventory.inspect(ROOT)
    rows = [row for row in catalog['suites'] if row['id'] == suite]
    require(len(rows) == 1, 'Unknown mandatory runtime suite')
    cases = rows[0]['cases']
    products = Path(record['builds']['testing']['products'])
    source_executable = products / 'ShadowSyncSelfTest'
    app = build_root / 'testing/package/ShadowSync.app/Contents/MacOS/ShadowSync'
    framework = build_root / 'policy/Python.framework'
    python = framework / 'Versions/3.14/Resources/Python.app/Contents/MacOS/Python'
    git_paths = (Path('/usr/bin/git'), Path('/Library/Developer/CommandLineTools/usr/bin/git'))
    git_identity = {}
    for path in git_paths:
        info = path.lstat()
        require(path.resolve(strict=True) == path and stat.S_ISREG(info.st_mode)
                and info.st_uid == 0 and not info.st_mode & 0o022, 'Untrusted Apple Git fixture')
        build.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple', str(path)])
        git_identity[str(path)] = build.sha(path)
    nonce = uuid.uuid4().hex
    root.mkdir(mode=0o700)
    (root / 'home').mkdir(mode=0o700); (root / 'tmp').mkdir(mode=0o700)
    executable = stage_runtime_executable(root, source_executable)
    policy_source = stage_policy_source(root)
    isolation = root / 'fixture.sb'
    isolation.write_text(profile(root, nonce, executable, app, python))
    env = fixture_environment(suite, root, nonce, python, build_root, framework, policy_source,
                              retention_cleanup_costs=retention_cleanup_costs)
    native = load('run-native-appkit')
    def plain(name, binary, args):
        value = native.child(['/usr/bin/sandbox-exec', '-f', str(isolation), str(binary), *args],
                             cwd=root, env=env, timeout=20)
        for stream in ('stdout', 'stderr'):
            (root / (name + '.' + stream)).write_bytes(value[stream])
        require(native.succeeded(value), 'Isolation/discovery command failed: ' + name)
        return value['stdout']
    require(json.loads(plain('isolation', app, ['--shadow-sync-native-fixture-isolation'])) ==
        dict(home_denied=True, network_denied=True, outside_writes_denied=True, exec_denied=True),
        'Isolation canary failed')
    inventory.validate_discovery(catalog, plain('discovery', executable, ['--list-ci-suites']))
    # Prove all closed fixture prefixes permit only this attempt. These are new
    # synthetic directories, never protected/user repository paths.
    for index, (parent, prefix) in enumerate(FIXTURE_LOCATIONS):
        for label, token, allowed in (('own', nonce, True), ('foreign', uuid.uuid4().hex, False)):
            canary = Path(parent) / (prefix + token + '.canary')
            canary.mkdir(mode=0o700); identity = (canary.stat().st_dev, canary.stat().st_ino)
            marker = canary / 'marker'; marker.write_bytes(b'preserve')
            try:
                for kind, text in (('read', 'read -r value < "$1"; test "$value" = preserve'),
                                   ('write', 'printf preserve > "$1"')):
                    value = native.child(['/usr/bin/sandbox-exec', '-f', str(isolation), '/bin/bash',
                        '-c', text, 'fixture', str(marker)], cwd=root, env=env, timeout=10)
                    require(value['direct_child_reaped'] and value['process_group_absent']
                            and value['failure'] is None and (value['exit'] == 0) == allowed,
                            'Fixture namespace isolation failed')
                    if not allowed:
                        require(b'Operation not permitted' in value['stderr'], 'Wrong refusal')
                    (root / f'canary-{index}-{label}-{kind}.log').write_bytes(value['stdout'] + value['stderr'])
                    require(marker.read_bytes() == b'preserve', 'Canary changed')
            finally:
                require((canary.stat().st_dev, canary.stat().st_ino) == identity, 'Canary identity changed')
                marker.unlink(); canary.rmdir()
    cleanup = False
    passed = False
    attempts = []
    try:
        for behavior in ('cancel-before-run', 'lost-before-run', 'run'):
            evidence = root / behavior
            started = time.time()
            result = execute(executable=executable, app=app, suite=suite, cases=cases, nonce=nonce,
                source_sha256=context['source_sha256'], executable_sha256=build.sha(executable),
                app_sha256=build.sha(app), profile=isolation, environment=env, evidence=evidence,
                seconds=900, behavior=behavior, source_root=ROOT)
            capture_crash(result, executable=executable, evidence=evidence, started=started,
                          source_sha256=context['source_sha256'])
            attempts.append(result)
            terminal = result.get('terminal', {})
            require(result['original_reaped'] and result['protocol_complete']
                    and not result['errors'] and not result['interrupts']
                    and terminal['reservations'] == terminal['children'] == terminal['callbacks'] == 0
                    and terminal['spawned'] == terminal['reaped'], 'Runtime ownership did not drain')
            require(not [p for parent, prefix in FIXTURE_LOCATIONS for p in Path(parent).glob(prefix + nonce + '.*')],
                    'Runtime fixture roots remain')
            require(not list((root / 'tmp').glob('shadow-sync-runtime-owner-*'))
                    and not list((root / 'tmp').glob('shadow-sync-closed-runner-*')), 'Owner records remain')
            if behavior == 'run':
                sys.stdout.buffer.write(canonical_output(suite, cases,
                    (evidence / 'stdout.raw').read_bytes(), complete=result['passed'])); sys.stdout.flush()
                cleanup = True
                passed = result['passed'] and terminal['passed_cases'] == len(cases)
            else:
                require(not result['passed'] and terminal['begun_cases'] == terminal['passed_cases']
                        == terminal['spawned'] == 0
                        and terminal['reason'] == ('cancelled' if behavior == 'cancel-before-run' else 'callerLost'),
                        'Pre-admission cancellation failed')
        require(policy_source.read_bytes() == (ROOT / 'Resources/policy-runtime-source.json').read_bytes(),
                'Policy source fixture changed')
        native.binary_identity(executable, build.sha(source_executable))
        require(stat.S_IMODE(executable.stat().st_mode) == 0o755, 'Runtime fixture mode changed')
        build.verify(record, build_root, context)
        require(all(build.sha(Path(path)) == digest for path, digest in git_identity.items()), 'Git fixture changed')
    finally:
        (root / 'result.json').write_text(json.dumps(dict(passed=passed, cleanup_complete=cleanup,
            namespace=nonce, profile_sha256=build.sha(isolation), attempts=len(attempts),
            retention_cleanup_costs=retention_cleanup_costs), sort_keys=True) + '\n')
    return passed, cleanup
