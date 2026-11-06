"""Native executor failure paths use disposable data and direct child processes."""
import copy
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_appkit_runner', ROOT / 'scripts/run-native-appkit.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class NativeExecutorTests(unittest.TestCase):
    def child(self, code, timeout=3, request=None):
        with tempfile.TemporaryDirectory() as root:
            return runner.child([sys.executable, '-I', '-S', '-c', code], cwd=root,
                                env={'PATH': os.defpath}, timeout=timeout, request=request)

    def test_catalog_preserves_all_native_ui_and_legacy_probes(self):
        old, manifest, rows = runner.catalog()
        self.assertEqual(len(rows), 35)
        self.assertEqual(len({r['id'] for r in rows}), 35)
        self.assertEqual(len(rows[:27]), len(manifest['suites']))
        for trial in (1, 2, 3):
            row = next(r for r in rows if r['id'] == 'm5-latency-' + str(trial))
            self.assertEqual(row['cases'], runner.native.legacy.cases(old, 'm5-latency', trial))
            self.assertEqual(row['timeout_seconds'], 90)
        cases = [c for row in rows for c in row['cases']]
        self.assertEqual(len(cases), len(set(cases)))
        self.assertTrue(all(row['cases'] for row in rows))

    def test_request_protocol_keeps_latency_and_ui_contracts(self):
        root = Path('/private/tmp/fixture')
        flag, request = runner.request_for('ui-worker-owner-ordering', root)
        self.assertEqual(flag, '--shadow-sync-native-ui-suite-channel')
        self.assertEqual(request, {'schema': 'shadow-sync-native-ui-suite/v1',
                                   'testRoot': str(root), 'suite': 'worker-owner-ordering'})
        for trial in (1, 2, 3):
            flag, request = runner.request_for('m5-latency-' + str(trial), root)
            self.assertEqual(flag, '--shadow-sync-m5-latency-channel')
            self.assertEqual(request, {'schema': 'shadow-sync-m5-latency/v1', 'testRoot': str(root),
                'trial': trial, 'rowCount': 100, 'durationSeconds': 60, 'eventIntervalMilliseconds': 25})

    def test_direct_child_success_and_error_status_are_distinct(self):
        result = self.child("print('done')")
        self.assertTrue(runner.succeeded(result))
        self.assertEqual(result['stdout'], b'done\n')
        failed = self.child('raise SystemExit(7)')
        self.assertFalse(runner.succeeded(failed))
        self.assertEqual(failed['exit'], 7)
        self.assertTrue(failed['direct_child_reaped'] and failed['process_group_absent'])

    def test_channel_request_and_response_are_bounded_and_preserved(self):
        code = "import json,socket,sys\ns=socket.socket(fileno=int(sys.argv[1]));r=json.loads(s.recv(1024));s.sendall(json.dumps(r).encode()+b'\\n');s.close()"
        result = self.child(code, request={'test': True})
        self.assertTrue(runner.succeeded(result))
        self.assertEqual(json.loads(result['response']), {'test': True})

    def test_log_and_response_overflow_fail_and_drain(self):
        with patch.object(runner, 'MAX_LOG', 128):
            result = self.child("import os,time;os.write(1,b'x'*129);time.sleep(10)")
        self.assertIn('output limit', result['failure'])
        self.assertTrue(result['direct_child_reaped'] and result['process_group_absent'])
        code = "import os,socket,sys,time\ns=socket.socket(fileno=int(sys.argv[1]));s.recv(1024);s.sendall(b'x'*129);time.sleep(10)"
        with patch.object(runner, 'MAX_RESPONSE', 128):
            result = self.child(code, request={'test': True})
        self.assertIn('output limit', result['failure'])
        self.assertTrue(result['direct_child_reaped'] and result['process_group_absent'])

    def test_ignored_term_reaches_kill_with_the_child_still_owned(self):
        result = self.child("import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(30)", timeout=1)
        self.assertEqual(result['stdout'], b'ready\n')
        self.assertEqual(result['exit'], -signal.SIGKILL)
        self.assertIn('deadline', result['failure'])
        self.assertTrue(result['direct_child_reaped'] and result['process_group_absent'])
        self.assertLess(result['seconds'], 10)

    def test_spawn_failure_cannot_claim_cleanup_or_success(self):
        with tempfile.TemporaryDirectory() as root:
            result = runner.child(['/nonexistent/native-fixture'], cwd=root, env={}, timeout=1)
        self.assertIsNone(result['exit'])
        self.assertFalse(result['direct_child_reaped'])
        self.assertFalse(runner.succeeded(result))

    def test_exited_leader_keeps_anchor_until_ignoring_descendant_is_drained(self):
        code = '''import os,signal,time
read,write=os.pipe()
pid=os.fork()
if pid==0:
 os.close(read);signal.signal(signal.SIGTERM,signal.SIG_IGN)
 os.write(write,b'ready');os.close(write)
 for fd in (0,1,2): os.close(fd)
 deadline=time.monotonic()+20
 while time.monotonic()<deadline: time.sleep(.05)
 os._exit(0)
os.close(write);assert os.read(read,5)==b'ready';os.close(read)
print(pid,flush=True)
os._exit(0)
'''
        result = self.child(code)
        self.assertEqual(result['exit'], 0)
        self.assertIn('left group descendants', result['failure'])
        self.assertTrue(result['direct_child_reaped'] and result['process_group_absent'])
        self.assertFalse(runner.succeeded(result))
        pid = int(result['stdout'])
        with self.assertRaises(ProcessLookupError): os.kill(pid, 0)

    def test_interrupt_during_cleanup_is_latched_until_reap_and_blocks_next_spawn(self):
        previous = signal.signal(signal.SIGTERM, runner.record_interrupt)
        original = runner.signal_group
        delivered = []
        def interrupt_after_signal(proc, sig):
            original(proc, sig)
            if not delivered:
                delivered.append(True)
                os.kill(os.getpid(), signal.SIGTERM)
        try:
            with patch.object(runner, 'MAX_LOG', 128), patch.object(runner, 'signal_group', interrupt_after_signal):
                result = self.child("import os,time;os.write(1,b'x'*129);time.sleep(30)")
            self.assertTrue(delivered and runner.INTERRUPTED)
            self.assertTrue(result['direct_child_reaped'] and result['process_group_absent'])
            self.assertFalse(runner.succeeded(result))
            refused = self.child("raise SystemExit(99)")
            self.assertIsNone(refused['exit'])
            self.assertIn('interrupted', refused['failure'])
            self.assertFalse(refused['direct_child_reaped'])
        finally:
            signal.signal(signal.SIGTERM, previous)
            runner.INTERRUPTED = False

    def test_group_observer_failure_is_not_treated_as_absence(self):
        with patch.object(runner, 'group_members', side_effect=ValueError('observer unavailable')):
            result = self.child('raise SystemExit(0)')
        self.assertIn('observer unavailable', result['failure'])
        self.assertTrue(result['direct_child_reaped'] and result['process_group_absent'])
        self.assertFalse(runner.succeeded(result))

    def test_binary_binding_rejects_changed_bytes_links_and_write_permissions(self):
        with tempfile.TemporaryDirectory() as root:
            binary = Path(root).resolve() / 'binary'
            binary.write_bytes(b'fixture'); binary.chmod(0o700)
            digest = runner.sha(b'fixture')
            runner.binary_identity(binary, digest)
            binary.write_bytes(b'changed')
            with self.assertRaises(ValueError): runner.binary_identity(binary, digest)
            binary.write_bytes(b'fixture'); binary.chmod(0o722)
            with self.assertRaises(ValueError): runner.binary_identity(binary, digest)
            binary.chmod(0o700); link = binary.parent / 'link'; link.symlink_to(binary)
            with self.assertRaises(ValueError): runner.binary_identity(link, digest)
            link.unlink(); os.link(binary, link)
            with self.assertRaises(ValueError): runner.binary_identity(binary, digest)

    def test_evidence_is_exclusive_and_private(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'receipt.json'
            runner.write_new(path, b'first')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): runner.write_new(path, b'second')
            self.assertEqual(path.read_bytes(), b'first')

    def test_execution_copy_is_exact_private_exclusive_and_does_not_move_source(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root).resolve() / 'source'
            staged = source.with_name('staged')
            source.write_bytes(b'fixture'); source.chmod(0o700)
            before = runner.binary_identity(source, runner.sha(b'fixture'))
            runner.stage_binary(source, staged, runner.sha(b'fixture'))
            self.assertEqual(staged.read_bytes(), source.read_bytes())
            self.assertEqual(staged.stat().st_mode & 0o777, 0o700)
            self.assertEqual(runner.binary_identity(source, runner.sha(b'fixture')), before)
            with self.assertRaises(FileExistsError): runner.stage_binary(source, staged, runner.sha(b'fixture'))

    def test_profile_restricts_home_network_outside_writes_and_unrelated_exec(self):
        value = runner.sandbox_profile(Path('/fixture/account'),
                Path('/private/tmp/fixture/ShadowSync'), Path('/private/tmp/fixture')).decode()
        self.assertIn('(deny file-read* file-write* (subpath "/fixture/account"))', value)
        self.assertNotIn('(allow file-read', value)
        self.assertIn('(deny network*)', value)
        self.assertNotIn('(allow network', value)
        self.assertIn('(deny file-write*)', value)
        self.assertIn('(allow file-write* (subpath "/private/tmp/fixture"))', value)
        self.assertIn('(deny process-exec)', value)
        self.assertIn('(allow process-exec (literal "/private/tmp/fixture/ShadowSync") (literal "/usr/bin/sandbox-exec"))', value)
        for root, binary in [('/fixture/account/test', '/fixture/account/test/ShadowSync'),
                             ('/fixture', '/fixture/ShadowSync'),
                             ('/private/tmp/fixture', '/arbitrary/program')]:
            with self.assertRaises(ValueError):
                runner.sandbox_profile(Path('/fixture/account'), Path(binary), Path(root))

    def test_helper_journal_no_follow_permissions_link_count_and_stable_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = root / 'native-fixture.jsonl'
            self.assertEqual(runner.fixture.read(root), b'')
            runner.write_new(journal, b'recorded\n')
            self.assertEqual(runner.fixture.read(root), b'recorded\n')
            journal.chmod(0o644)
            with self.assertRaises(ValueError): runner.fixture.read(root)
            journal.chmod(0o600)
            link = root / 'copy'; os.link(journal, link)
            with self.assertRaises(ValueError): runner.fixture.read(root)
            link.unlink()
            journal.rename(link); journal.symlink_to(link)
            with self.assertRaises(OSError): runner.fixture.read(root)
            journal.unlink(); journal.write_bytes(b'x' * 32769); journal.chmod(0o600)
            with self.assertRaises(ValueError): runner.fixture.read(root)
            journal.write_bytes(b'recorded\n')
            original = os.read
            def mutate_after_read(fd, count):
                value = original(fd, count); journal.write_bytes(b'replaced\n'); return value
            with patch.object(runner.fixture.os, 'read', mutate_after_read), self.assertRaises(ValueError):
                runner.fixture.read(root)

    def test_process_absence_rejects_denial_and_zombies_and_accepts_changed_start(self):
        identity = {'processID': 1234, 'startSeconds': 100, 'startMicroseconds': 20}
        class Function:
            def __init__(self, size, error, seconds=100, pid=1234):
                self.size, self.error, self.seconds, self.pid = size, error, seconds, pid
            def __call__(self, pid, flavor, arg, pointer, size):
                info = ctypes.cast(pointer, ctypes.POINTER(runner.fixture.BSDInfo)).contents
                info.pid = self.pid; info.status = 5  # Zombie remains the same identity.
                info.startSeconds = self.seconds; info.startMicroseconds = 20
                ctypes.set_errno(self.error)
                return self.size
        class Library: pass
        def observed(size, error=0, seconds=100, pid=1234):
            library = Library(); library.proc_pidinfo = Function(size, error, seconds, pid)
            with patch.object(runner.fixture.ctypes, 'CDLL', return_value=library):
                return runner.fixture.original_absent(identity)
        self.assertTrue(observed(0, errno.ESRCH))
        self.assertFalse(observed(ctypes.sizeof(runner.fixture.BSDInfo)))
        self.assertTrue(observed(ctypes.sizeof(runner.fixture.BSDInfo), seconds=101))
        for size, error, pid in [(0, errno.EPERM, 1234), (0, 0, 1234),
                                 (1, 0, 1234), (ctypes.sizeof(runner.fixture.BSDInfo), 0, 1235)]:
            with self.assertRaises(ValueError): observed(size, error, pid=pid)

    def test_cleanup_observation_waits_for_absence_and_preserves_unknown(self):
        identity = {'processID': 1234}
        with patch.object(runner.fixture, 'original_absent', side_effect=[False, True]), \
             patch.object(runner.time, 'sleep'):
            self.assertEqual(runner.observe_helpers([identity]),
                             {'identities': [identity], 'originals_absent': True})
        with patch.object(runner.fixture, 'original_absent', return_value=False), self.assertRaises(ValueError):
            runner.observe_helpers([identity], timeout=0)
        with patch.object(runner.fixture, 'original_absent', side_effect=ValueError('denied')), self.assertRaises(ValueError):
            runner.observe_helpers([identity])
        clock = [0.0]
        def wait(seconds): clock[0] += seconds
        with patch.object(runner.time, 'monotonic', lambda: clock[0]), patch.object(runner.time, 'sleep', wait):
            recovery = runner.wait_unknown_helpers()
        self.assertGreaterEqual(recovery['maximum_lifetime_wait_seconds'], 31)
        self.assertIs(recovery['cleanup_verified'], False)

    def test_isolation_response_requires_exact_boolean_denials(self):
        value = {name: True for name in ('home_denied', 'network_denied', 'outside_writes_denied', 'exec_denied')}
        self.assertTrue(runner.isolation_passed(runner.encoded(value)))
        for bad in ({**value, 'extra': True}, {**value, 'exec_denied': 1},
                    {**value, 'home_denied': False}, []):
            self.assertFalse(runner.isolation_passed(runner.encoded(bad)))

    def test_spawn_only_crash_observes_known_identity_but_keeps_failed_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            outer = Path(directory).resolve()
            root = outer / 'fixture'; root.mkdir(mode=0o700)
            evidence = outer / 'evidence'; evidence.mkdir(mode=0o700)
            binary = outer / 'testing'; binary.write_bytes(b'fixture'); binary.chmod(0o700)
            old, manifest, rows = runner.catalog()
            row = next(row for row in rows if row['id'] == 'ui-m4-worker-stop')
            identity = {'processID': 1234, 'processGroupID': 1234, 'userID': os.getuid(),
                'startSeconds': 123456, 'startMicroseconds': 123,
                'executablePath': str(root / 'ShadowSync'),
                'generation': '935ab63c-dd2e-4bc5-a372-f8ad17ff7aa7'}
            spawn = {'schema': 'shadow-sync-native-fixture/v1', 'event': 'spawn',
                     'role': 'worker-stop', 'identity': identity}
            def child(argv, **kwargs):
                result = {'exit': 0, 'failure': None, 'direct_child_reaped': True,
                          'process_group_absent': True, 'seconds': .1,
                          'stdout': b'', 'stderr': b'', 'response': b''}
                if '--shadow-sync-native-fixture-isolation' in argv:
                    result['stdout'] = runner.encoded({name: True for name in (
                        'home_denied', 'network_denied', 'outside_writes_denied', 'exec_denied')})
                elif '--shadow-sync-native-ui-suite-channel' in argv:
                    runner.write_new(root / 'native-fixture.jsonl', runner.encoded(spawn))
                    result.update(exit=-9, failure='application crashed')
                return result
            with patch.object(runner.tempfile, 'mkdtemp', return_value=str(root)), \
                 patch.object(runner, 'child', child), patch.object(runner.native, 'inventory'), \
                 patch.object(runner, 'wait_unknown_helpers', return_value={
                     'maximum_lifetime_wait_seconds': 31, 'cleanup_verified': False}) as recovery:
                with self.assertRaises(ValueError):
                    runner.execute(row, binary, runner.sha(b'fixture'), evidence, old, manifest)
            recovery.assert_called_once_with([identity])
            receipt = json.loads((evidence / row['id'] / 'receipt.json').read_bytes())
            self.assertTrue(root.is_dir())
            self.assertFalse(receipt['cleanup_complete'])
            self.assertEqual(receipt['passed_cases'], [])
            self.assertEqual(receipt['failed_native_recovery']['known_identities'], [identity])
            self.assertIn('incomplete helper coverage', receipt['failed_native_recovery']['journal_error'])
            self.assertEqual((evidence / row['id'] / 'recovery-helper-journal.jsonl').read_bytes(),
                             runner.encoded(spawn))

    def test_recovery_observes_present_absent_and_denied_without_signaling(self):
        identities = [{'processID': 1}, {'processID': 2}, {'processID': 3}]
        def absent(identity):
            if identity['processID'] == 3: raise ValueError('denied')
            return identity['processID'] == 2
        clock = [0.0]
        def wait(seconds): clock[0] += seconds
        with patch.object(runner.time, 'monotonic', lambda: clock[0]), \
             patch.object(runner.time, 'sleep', wait), \
             patch.object(runner.fixture, 'original_absent', absent), \
             patch.object(runner.os, 'kill') as kill, patch.object(runner.os, 'killpg') as killpg:
            result = runner.wait_unknown_helpers(identities)
        self.assertEqual([row['status'] for row in result['known_helper_observations']],
                         ['present', 'absent', 'unavailable'])
        self.assertFalse(result['cleanup_verified'])
        kill.assert_not_called(); killpg.assert_not_called()

    def test_helper_evidence_rejects_missing_foreign_duplicate_and_unreaped(self):
        binary = Path('/private/tmp/fixture/ShadowSync')
        identity = {'processID': 1234, 'processGroupID': 1234, 'userID': os.getuid(),
            'startSeconds': 123456, 'startMicroseconds': 123, 'executablePath': str(binary),
            'generation': '935ab63c-dd2e-4bc5-a372-f8ad17ff7aa7'}
        spawn = {'schema': 'shadow-sync-native-fixture/v1', 'event': 'spawn',
                 'role': 'worker-stop', 'identity': identity}
        reap = {**spawn, 'event': 'reap', 'status': 9}
        encode = lambda rows: b''.join(runner.encoded(r) for r in rows)
        good = encode([spawn, reap])
        runner.validate_helpers(good, 'ui-m4-worker-stop', binary)
        runner.validate_helpers(None, 'ui-routing', binary)
        for suffix in (b'', b'{"broken":', encode([{**reap, 'status': True}])):
            recovered = runner.fixture.recovery_identities(encode([spawn]) + suffix,
                ['worker-stop'], str(binary), os.getuid())
            self.assertEqual(recovered['known_identities'], [identity])
            self.assertIsNotNone(recovered['journal_error'])
        wrong = {**spawn, 'identity': {**identity, 'userID': os.getuid() + 1}}
        recovered = runner.fixture.recovery_identities(encode([wrong]), ['worker-stop'], str(binary), os.getuid())
        self.assertEqual(recovered['known_identities'], [])
        bad = [None, b'', encode([spawn]), encode([reap, spawn]), encode([spawn, spawn, reap]),
               encode([spawn, {**reap, 'status': True}]), encode([spawn, {**reap, 'extra': True}])]
        for field, value in [('userID', os.getuid()+1), ('processGroupID', 99),
                             ('generation', 'invalid'), ('executablePath', '/wrong/binary'),
                             ('processID', True), ('startMicroseconds', 1000000)]:
            foreign = copy.deepcopy(identity); foreign[field] = value
            bad.append(encode([{**spawn, 'identity': foreign}, {**reap, 'identity': foreign}]))
        for raw in bad:
            with self.subTest(raw=raw), self.assertRaises((ValueError, KeyError, TypeError)):
                runner.validate_helpers(raw, 'ui-m4-worker-stop', binary)
        with self.assertRaises(ValueError): runner.validate_helpers(good, 'ui-routing', binary)


if __name__ == '__main__':
    unittest.main()
