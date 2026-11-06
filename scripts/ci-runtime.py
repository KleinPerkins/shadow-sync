#!/usr/bin/env python3
"""Run one registered safety suite with the qualified guardian/isolation contract."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import stat
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from runtime_guardian_executor import execute


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


build = load('ci-build')
require = build.require
PREFIXES = ('shadow-sync-m2.', 'shadow-sync-m4.', 'shadow-sync-self-tests.',
    'shadow-sync-custody-anchor-', 'shadow-sync-m6-self.', 'shadow-sync-custody-leases.',
    'shadow-sync-custody-catalog.', 'shadow-sync-fresh-state.', 'shadow-sync-registry.',
    'shadow-sync-state-admission.', 'shadow-sync-policy-input-', 'shadow-sync-policy-transport-',
    'shadow-sync-policy-authority-', 'shadow-sync-catalog-admission-', 'shadow-sync-publisher-policy-',
    'shadow-sync-discovery-spawn.', 'shadow-sync-fixture-config.', 'shadow-sync-v3-preferences.',
    'shadow-sync-v3-preferences-pre-rename.', 'shadow-sync-v3-preferences-post-rename.',
    'shadow-sync-v3-catalog.', 'shadow-sync-dm4-preflight.')
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
    for prefix in PREFIXES:
        escaped = prefix.replace('.', '[.]')
        result += '(deny file-read* file-write* (regex #"^/private/tmp/' + escaped + '"))\n'
        result += '(allow file-read* file-write* (regex #"^/private/tmp/' + escaped + nonce + '[.][A-Za-z0-9-]+(/.*)?$"))\n'
    suffixes = (r'/[^/]+(/[A-Za-z0-9-]+)*/[.]git/hooks/(post-merge|pre-merge-commit|pre-commit|reference-transaction)',
        r'/[^/]+(/[A-Za-z0-9-]+)*/[.]githooks/reference-transaction',
        r'/home/dev/_ops/bin/(dev-worktree[.]sh|install-identity-guard[.]sh)',
        r'/(fake-gh|sleep-gh|large-gh|failure-gh)')
    for suffix in suffixes:
        result += '(allow process-exec (regex #"^/private/tmp/shadow-sync-self-tests[.]' + nonce + '[.][A-Za-z0-9-]+' + suffix + '$"))\n'
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
        require(seen == cases, 'Runtime stdout lacks the complete actual case roster')
    return ('\n'.join(output) + '\n').encode('utf-8')


def run_suite(suite, root, build_root, record, context):
    inventory = load('runtime-suite-inventory')
    catalog = inventory.inspect(ROOT)
    rows = [row for row in catalog['suites'] if row['id'] == suite]
    require(len(rows) == 1, 'Unknown mandatory runtime suite')
    cases = rows[0]['cases']
    products = Path(record['builds']['testing']['products'])
    executable = products / 'ShadowSyncSelfTest'
    app = build_root / 'testing/package/ShadowSync.app/Contents/MacOS/ShadowSync'
    framework = build_root / 'policy/Python.framework'
    python = framework / 'Versions/3.14/Resources/Python.app/Contents/MacOS/Python'
    git_paths = (Path('/usr/bin/git'), Path('/Library/Developer/CommandLineTools/usr/bin/git'))
    git_identity = {}
    for path in git_paths:
        info = path.lstat()
        require(path.resolve(strict=True) == path and stat.S_ISREG(info.st_mode)
                and info.st_uid == 0 and not info.st_mode & 0o022, 'Untrusted Apple Git fixture')
        build.run(['/usr/bin/codesign', '--verify', '--strict', '-R', 'anchor apple', str(path)])
        git_identity[str(path)] = build.sha(path)
    nonce = uuid.uuid4().hex
    root.mkdir(mode=0o700)
    (root / 'home').mkdir(mode=0o700); (root / 'tmp').mkdir(mode=0o700)
    isolation = root / 'fixture.sb'
    isolation.write_text(profile(root, nonce, executable, app, python))
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), TMPDIR=str(root / 'tmp'),
        SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE=nonce, LANG='C', LC_ALL='C',
        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null',
        SHADOW_SYNC_TEST_POLICY_PYTHON=str(python),
        SHADOW_SYNC_TEST_PUBLISHER_EXECUTABLE=str(build_root / 'publisher-executable'),
        SHADOW_SYNC_TEST_POLICY_FRAMEWORK=str(framework),
        SHADOW_SYNC_TEST_POLICY_SOURCE=str(ROOT / 'Resources/policy-runtime-source.json'))
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
    for index, prefix in enumerate(PREFIXES):
        for label, token, allowed in (('own', nonce, True), ('foreign', uuid.uuid4().hex, False)):
            canary = Path('/private/tmp') / (prefix + token + '.canary')
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
            result = execute(executable=executable, app=app, suite=suite, cases=cases, nonce=nonce,
                source_sha256=context['source_sha256'], executable_sha256=build.sha(executable),
                app_sha256=build.sha(app), profile=isolation, environment=env, evidence=evidence,
                seconds=900, behavior=behavior, source_root=ROOT)
            attempts.append(result)
            terminal = result.get('terminal', {})
            require(result['original_reaped'] and result['protocol_complete']
                    and not result['errors'] and not result['interrupts']
                    and terminal['reservations'] == terminal['children'] == terminal['callbacks'] == 0
                    and terminal['spawned'] == terminal['reaped'], 'Runtime ownership did not drain')
            require(not [p for prefix in PREFIXES for p in Path('/private/tmp').glob(prefix + nonce + '.*')],
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
        build.verify(record, build_root, context)
        require(all(build.sha(Path(path)) == digest for path, digest in git_identity.items()), 'Git fixture changed')
    finally:
        (root / 'result.json').write_text(json.dumps(dict(passed=passed, cleanup_complete=cleanup,
            namespace=nonce, profile_sha256=build.sha(isolation), attempts=len(attempts)), sort_keys=True) + '\n')
    return passed, cleanup
