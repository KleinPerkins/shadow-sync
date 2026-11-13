#!/usr/bin/env python3
"""Run registered AppKit suites in separate processes and disposable fixtures.

This runner never installs or invokes the ordinary app route. A passing receipt
does not qualify physical input, a supported OS, signing, migration or updates.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_ui', ROOT / 'scripts/native-ui-suites.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
spec = importlib.util.spec_from_file_location('native_fixture', ROOT / 'scripts/native-fixture-contract.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
INTERRUPTED = False
MAX_LOG = 8 * 1024 * 1024
MAX_RESPONSE = 1024 * 1024
SOURCE_CONTRACTS = {'AppDelegate.swift': 'Sources/ShadowSyncApp/AppDelegate.swift',
                    'native-acceptance.md': 'docs/runbooks/native-acceptance.md'}
HELPERS = {'ui-m4-worker-stop': ('worker-stop', 9), 'ui-m4-takeover': ('takeover', 15),
           'ui-worker-owner-ordering': ('owner-ordering', 0),
           'ui-worker-owner-refusal': ('owner-custody-loss', 0)}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data)


def private_directory(path):
    info = path.lstat()
    require(path.is_absolute() and path.resolve() == path and stat.S_ISDIR(info.st_mode)
            and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
            'Expected an existing physical owner-private directory')
    return info.st_dev, info.st_ino, info.st_uid


def binary_identity(path, expected):
    require(len(expected) == 64 and all(c in '0123456789abcdef' for c in expected), 'Invalid binary digest')
    require(path.is_absolute() and path.resolve() == path, 'Binary path is not physical')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_nlink == 1 and 0 < before.st_size <= 128 * 1024 * 1024
                and before.st_mode & 0o111 and not before.st_mode & 0o6022,
                'Unsafe testing binary')
        digest = hashlib.sha256()
        with os.fdopen(os.dup(fd), 'rb') as stream:
            for block in iter(lambda: stream.read(65536), b''):
                digest.update(block)
        identity = lambda i: (i.st_dev, i.st_ino, i.st_mode, i.st_nlink, i.st_size,
                              i.st_mtime_ns, i.st_ctime_ns)
        require(identity(before) == identity(os.fstat(fd))
                == identity(path.lstat()) and digest.hexdigest() == expected, 'Testing binary changed')
        return identity(before)
    finally:
        os.close(fd)


def stage_binary(source, target, expected):
    before = binary_identity(source, expected)
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'rb') as stream:
        data = stream.read(128 * 1024 * 1024 + 1)
    require(len(data) <= 128 * 1024 * 1024 and sha(data) == expected, 'Binary staging input changed')
    write_new(target, data)
    target.chmod(0o700)
    binary_identity(target, expected)
    require(binary_identity(source, expected) == before, 'Binary changed during staging')


def catalog():
    old = native.legacy.contract(native.read_regular(ROOT / 'Tests/Fixtures/native-appkit-contract.json'))
    manifest = native.contract(native.read_regular(ROOT / 'Tests/Fixtures/native-ui-suites.json'), old)
    native.legacy.source_consistent(old, native.read_regular(
        ROOT / 'Sources/ShadowSyncApp/M5Harness.swift').decode())
    rows = [{'id': 'ui-' + r['id'], 'cases': ['native-ui/' + r['id'] + '/' + k
             for k in r['checks'] + r['core_tests']], 'timeout_seconds': 30}
            for r in manifest['suites']]
    for probe in native.legacy.PROBES:
        if probe in ('m5-ui', 'm5-latency'):
            continue
        rows.append({'id': probe, 'cases': native.legacy.cases(old, probe), 'timeout_seconds': 60})
    rows += [{'id': 'm5-latency-' + str(trial), 'cases': native.legacy.cases(old, 'm5-latency', trial),
              'timeout_seconds': 90} for trial in (1, 2, 3)]
    return old, manifest, rows


def request_for(suite, root):
    if suite.startswith('ui-'):
        return '--shadow-sync-native-ui-suite-channel', {
            'schema': 'shadow-sync-native-ui-suite/v1', 'testRoot': str(root), 'suite': suite[3:]}
    trial = int(suite[-1]) if suite.startswith('m5-latency-') else None
    probe = 'm5-latency' if trial else suite
    request = {'schema': 'shadow-sync-' + probe + '/v1', 'testRoot': str(root)}
    if trial:
        request.update(trial=trial, rowCount=100, durationSeconds=60, eventIntervalMilliseconds=25)
    return '--shadow-sync-' + probe + '-channel', request


def validate_helpers(raw, suite, binary):
    expected = HELPERS.get(suite)
    identities = fixture.parse(b'' if raw is None else raw,
                               [] if expected is None else [expected[0]], str(binary), os.getuid())
    if expected is not None:
        require(native.decode(raw.splitlines()[-1])['status'] == expected[1], 'Wrong helper terminal status')
    return identities


def observe_helpers(identities, timeout=2):
    """Never signal journal identities; a denied query or zombie is not absence."""
    deadline = time.monotonic() + timeout
    while True:
        absent = [fixture.original_absent(identity) for identity in identities]
        if all(absent):
            return {'identities': identities, 'originals_absent': True}
        require(time.monotonic() < deadline, 'Native helper remains present')
        time.sleep(.05)


def wait_unknown_helpers(identities=()):
    # A child may have spawned before its journal record was written. Waiting its
    # maximum lifetime bounds recovery, but does not establish verified absence.
    started = time.monotonic()
    observations = [{'identity': identity, 'status': 'unobserved'} for identity in identities]
    while True:
        for row in observations:
            if row['status'] in ('absent', 'unavailable'):
                continue
            try:
                row['status'] = 'absent' if fixture.original_absent(row['identity']) else 'present'
            except (OSError, ValueError) as error:
                row.update(status='unavailable', error=type(error).__name__ + ': ' + str(error))
        remaining = started + 31 - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(.1, remaining))
    return {'maximum_lifetime_wait_seconds': round(time.monotonic() - started, 3),
            'known_helper_observations': observations, 'cleanup_verified': False}


def isolation_passed(raw):
    value = native.decode(raw)
    return (type(value) is dict and set(value) == {
        'home_denied', 'network_denied', 'outside_writes_denied', 'exec_denied'}
        and all(item is True for item in value.values()))


def record_interrupt(_signal, _frame):
    global INTERRUPTED
    INTERRUPTED = True


def group_members(proc):
    require(proc.returncode is None, 'Group observation requires retained direct-child ownership')
    result = subprocess.run(['/usr/bin/pgrep', '-g', str(proc.pid)],
                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C'},
                            capture_output=True, timeout=1)
    require(result.returncode in (0, 1) and not result.stderr and len(result.stdout) <= 16384,
            'Owned group observation failed')
    lines = result.stdout.decode('ascii').splitlines()
    require(all(line.isdecimal() and int(line) > 1 for line in lines)
            and len(lines) == len(set(lines)), 'Invalid owned group observation')
    require((result.returncode == 1) == (not lines), 'Inconsistent group observation')
    return {int(line) for line in lines}


def terminal_without_reaping(proc):
    require(proc.returncode is None, 'Child was already reaped')
    observed = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if observed is None:
        return None
    require(observed.si_pid == proc.pid and observed.si_code in
            (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED), 'Unexpected child wait status')
    return observed.si_status if observed.si_code == os.CLD_EXITED else -observed.si_status


def signal_group(proc, sig):
    require(proc.returncode is None, 'Cannot signal a group after releasing its anchor')
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass


def child(argv, *, cwd, env, timeout, request=None):
    """One owner retains the direct child until all signaling is complete."""
    parent = other = proc = None
    streams = {'stdout': bytearray(), 'stderr': bytearray(), 'response': bytearray()}
    failed = None
    started = time.monotonic()
    try:
        require(not INTERRUPTED, 'Native execution interrupted')
        if request is not None:
            parent, other = socket.socketpair()
            argv = [*argv, str(other.fileno())]
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                pass_fds=() if other is None else (other.fileno(),), start_new_session=True)
        if other is not None:
            other.close()
            parent.settimeout(min(5, timeout))
            parent.sendall(encoded(request))
        with selectors.DefaultSelector() as selector:
            for stream, name in [(proc.stdout, 'stdout'), (proc.stderr, 'stderr'), (parent, 'response')]:
                if stream is not None:
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, name)
            while selector.get_map():
                remaining = started + timeout - time.monotonic()
                require(not INTERRUPTED, 'Native execution interrupted')
                require(remaining > 0, 'Native child exceeded its absolute deadline')
                for key, _ in selector.select(min(.25, remaining)):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    streams[key.data].extend(data)
                    require(len(streams['response']) <= MAX_RESPONSE
                            and len(streams['stdout']) + len(streams['stderr']) <= MAX_LOG,
                            'Native child exceeded its output limit')
        while True:
            require(not INTERRUPTED, 'Native execution interrupted')
            require(time.monotonic() < started + timeout, 'Native child exceeded its exit deadline')
            terminal = terminal_without_reaping(proc)
            if terminal is not None:
                require(not group_members(proc) - {proc.pid}, 'Native child left group descendants')
                require(proc.wait(timeout=1) == terminal, 'Reaped status differs from retained terminal status')
                break
            time.sleep(.02)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        failed = type(error).__name__ + ': ' + str(error)
    finally:
        for stream in (parent, other):
            if stream is not None:
                stream.close()
        if proc is not None and proc.returncode is None:
            # Keep the leader unreaped through the entire group drain, including
            # when it exited before a TERM-ignoring descendant. Interrupt handlers
            # only record a flag; neither another signal nor a wait can steal this
            # anchor during the bounded escalation.
            drained = False
            terminal = None
            for sig, seconds in ((signal.SIGTERM, 3), (signal.SIGKILL, 5)):
                try:
                    signal_group(proc, sig)
                except OSError as error:
                    failed = failed or type(error).__name__ + ': ' + str(error)
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    try:
                        terminal = terminal_without_reaping(proc)
                        drained = terminal is not None and not group_members(proc) - {proc.pid}
                    except (OSError, ValueError, subprocess.SubprocessError) as error:
                        failed = failed or type(error).__name__ + ': ' + str(error)
                        break
                    if drained:
                        break
                    time.sleep(.02)
                if drained:
                    break
            if not drained:
                failed = failed or 'Owned group drainage could not be verified'
            try:
                actual = proc.wait(timeout=5)
                if terminal is None or actual != terminal:
                    failed = failed or 'Terminal status was not verified before reaping'
            except subprocess.TimeoutExpired:
                failed = failed or 'Direct child could not be reaped after bounded termination' 
        if proc is not None:
            proc.stdout.close()
            proc.stderr.close()
    if INTERRUPTED:
        failed = failed or 'Native execution interrupted'
    absent = False
    if proc is not None and proc.returncode is not None:
        try:
            os.killpg(proc.pid, 0)  # Observation only; never signal a reaped/borrowed identity.
        except ProcessLookupError:
            absent = True
        except PermissionError:
            pass
    return {'exit': None if proc is None else proc.returncode, 'failure': failed,
            'direct_child_reaped': proc is not None and proc.returncode is not None,
            'process_group_absent': absent, 'seconds': round(time.monotonic() - started, 3),
            **{k: bytes(v) for k, v in streams.items()}}


def succeeded(result):
    return result['exit'] == 0 and result['failure'] is None and result['direct_child_reaped'] and result['process_group_absent']


def sandbox_profile(home, binary, root):
    quote = lambda p: json.dumps(str(p), ensure_ascii=True)
    require(home.is_absolute() and home != Path('/') and not root.is_relative_to(home)
            and not home.is_relative_to(root) and root.is_absolute()
            and binary == root / 'ShadowSync', 'Invalid isolation paths')
    return ('(version 1)\n(allow default)\n'
            '(deny network*)\n(deny process-exec)\n'
            '(allow process-exec (literal ' + quote(binary) + ') (literal "/usr/bin/sandbox-exec"))\n'
            '(deny file-read* file-write* (subpath ' + quote(home) + '))\n'
            '(deny file-write*)\n(allow file-write* (subpath ' + quote(root) + '))\n').encode()


def stage_source_contracts(root, expected):
    """Only the two source assertions needed by the isolated native fixture."""
    private_directory(root)
    directory = root / 'source'
    directory.mkdir(mode=0o700)
    for name, source in SOURCE_CONTRACTS.items():
        data = native.read_regular(ROOT / source)
        require(sha(data) == expected[source], 'Source contract changed before staging')
        write_new(directory / name, data)
    verify_source_contracts(root, expected)


def verify_source_contracts(root, expected):
    directory = root / 'source'
    private_directory(directory)
    require(set(os.listdir(directory)) == set(SOURCE_CONTRACTS), 'Unexpected source contract entry')
    for name, source in SOURCE_CONTRACTS.items():
        require(sha(native.read_regular(directory / name)) == expected[source],
                'Staged source contract changed')


def execute(row, binary, expected, evidence, old, manifest):
    before = binary_identity(binary, expected)
    inputs = {name: sha(native.read_regular(ROOT / name)) for name in (
        'scripts/run-native-appkit.py', 'scripts/native-ui-suites.py',
        'scripts/native-appkit-contract.py', 'scripts/native-fixture-contract.py',
        'Tests/Fixtures/native-ui-suites.json',
        'Tests/Fixtures/native-appkit-contract.json', 'Sources/ShadowSyncApp/M5Harness.swift',
        *SOURCE_CONTRACTS.values())}
    suite = row['id']
    directory = evidence / suite
    directory.mkdir(mode=0o700)
    root = Path(tempfile.mkdtemp(prefix='shadow-sync-m5.', dir='/private/tmp'))
    initial = private_directory(root)
    staged = root / 'ShadowSync'
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    profile = sandbox_profile(home, staged, root)
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(root),
           'HOME': str(root), 'LANG': 'en_US.UTF-8', 'LC_ALL': 'C'}
    prefix = ['/usr/bin/sandbox-exec', '-f', str(root / 'profile.sb')]
    receipt = {'schema': 'shadow-sync-native-appkit-execution/v1', 'suite': suite,
               'binary_sha256': expected, 'profile_sha256': sha(profile),
               'runner_contract_sha256': inputs,
               'expected_cases': row['cases'], 'passed_cases': [], 'cleanup_complete': False,
               'failure': None, 'files': {}}
    def retain(name, data):
        write_new(directory / name, data)
        receipt['files'][name] = sha(data)
    native_started = False
    try:
        retain('fixture.json', encoded({'root': str(root), 'identity': initial}))
        stage_binary(binary, staged, expected)
        stage_source_contracts(root, inputs)
        write_new(root / 'profile.sb', profile)
        canary = child(prefix + [str(staged), '--shadow-sync-native-fixture-isolation'],
                       cwd=root, env=env, timeout=15)
        receipt['canary_process'] = {k: v for k, v in canary.items() if k not in ('stdout', 'stderr', 'response')}
        retain('canary.log', canary['stdout'] + canary['stderr'])
        require(succeeded(canary) and isolation_passed(canary['stdout']), 'Isolation canary failed')
        discovery = child(prefix + [str(staged), '--shadow-sync-list-native-ui-suites'],
                          cwd=root, env=env, timeout=15)
        retain('discovery.json', discovery['stdout'])
        retain('discovery.log', discovery['stderr'])
        require(succeeded(discovery) and not discovery['stderr'], 'Compiled native inventory failed')
        native.inventory(manifest, discovery['stdout'])
        route, request = request_for(suite, root)
        native_started = True
        result = child(prefix + [str(staged), route], cwd=root, env=env,
                       timeout=row['timeout_seconds'], request=request)
        receipt['process'] = {k: v for k, v in result.items() if k not in ('stdout', 'stderr', 'response')}
        retain('native.log', result['stdout'] + result['stderr'])
        retain('response.json', result['response'])
        raw = fixture.read(root)
        if raw:
            retain('helper-journal.jsonl', raw)
        identities = validate_helpers(raw, suite, staged)
        receipt['helper_observation'] = observe_helpers(identities)
        require(succeeded(result), 'Native probe did not complete and drain')
        if suite.startswith('ui-'):
            native.report(manifest, suite[3:], result['response'])
        else:
            trial = int(suite[-1]) if suite.startswith('m5-latency-') else None
            native.legacy.validate_report(old, 'm5-latency' if trial else suite, result['response'], trial)
        binary_identity(staged, expected)
        require(binary_identity(binary, expected) == before, 'Testing binary identity changed')
        require(all(sha(native.read_regular(ROOT / name)) == digest for name, digest in inputs.items()),
                'Native runner or contract changed')
        verify_source_contracts(root, inputs)
        require(private_directory(root) == initial and shutil.rmtree.avoids_symlink_attacks,
                'Fixture identity changed or safe cleanup unavailable')
        shutil.rmtree(root)
        require(not root.exists(), 'Fixture cleanup incomplete')
        receipt.update(passed_cases=row['cases'], cleanup_complete=True)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        if native_started:
            known = {'known_identities': [], 'journal_error': None}
            try:
                raw = fixture.read(root)
                retain('recovery-helper-journal.jsonl', raw)
                expected_helper = HELPERS.get(suite)
                known = fixture.recovery_identities(raw,
                    [] if expected_helper is None else [expected_helper[0]], str(staged), os.getuid())
            except (OSError, ValueError, TypeError, KeyError) as recovery_error:
                known['journal_error'] = type(recovery_error).__name__ + ': ' + str(recovery_error)
            receipt['failed_native_recovery'] = {
                **known, **wait_unknown_helpers(known['known_identities'])}
        # Failed fixtures and every captured response remain available for review.
        receipt['retained_fixture'] = str(root)
    retain('receipt.json', encoded(receipt))
    require(receipt['failure'] is None and receipt['cleanup_complete'], 'Native suite failed: ' + suite)
    for case in row['cases']:
        print('PASS ' + case, flush=True)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--list', action='store_true')
    selection.add_argument('--all', action='store_true')
    selection.add_argument('--suite')
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--binary-sha256')
    parser.add_argument('--evidence-root', type=Path)
    args = parser.parse_args()
    try:
        old, manifest, rows = catalog()
        if args.list:
            require(args.binary is None and args.binary_sha256 is None and args.evidence_root is None,
                    'Discovery does not accept execution inputs')
            print(encoded({'schema': 'shadow-sync-native-appkit-suites/v1', 'suites': rows}).decode(), end='')
            return 0
        require(args.binary is not None and args.binary_sha256 is not None and args.evidence_root is not None,
                'Execution requires binary identity and private evidence root')
        selected = rows if args.all else [r for r in rows if r['id'] == args.suite]
        require(bool(selected), 'Unknown native suite')
        require(sys.platform == 'darwin', 'Native AppKit requires macOS')
        private_directory(args.evidence_root)
        if args.all:
            require(not list(args.evidence_root.iterdir()), 'Full execution requires an empty evidence directory')
        signal.signal(signal.SIGINT, record_interrupt)
        signal.signal(signal.SIGTERM, record_interrupt)
        for row in selected:
            execute(row, args.binary, args.binary_sha256, args.evidence_root, old, manifest)
        require(not INTERRUPTED, 'Native execution interrupted')
        if args.all:
            combined = native.aggregate(manifest, old, [native.read_regular(
                args.evidence_root / ('ui-' + row['id']) / 'response.json') for row in manifest['suites']])
            write_new(args.evidence_root / 'complete.json', encoded({
                'schema': 'shadow-sync-native-appkit-complete/v1',
                'binary_sha256': args.binary_sha256, 'suites': [row['id'] for row in rows],
                'cases': [case for row in rows for case in row['cases']],
                'legacy_ui': combined,
                'receipts': {row['id']: sha(native.read_regular(args.evidence_root / row['id'] / 'receipt.json'))
                             for row in rows}}))
        return 0
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        print('FAIL native-appkit: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
