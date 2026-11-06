"""Inject executor faults with actual pipes and a retained simulated handle.

No application or child process is launched. Native original-child qualification
is separate and cannot be inferred from these observer/resource failure tests.
"""
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('guardian_protocol', ROOT / 'scripts/guardian_protocol.py')
protocol = importlib.util.module_from_spec(spec); spec.loader.exec_module(protocol)
spec = importlib.util.spec_from_file_location('guardian_executor', ROOT / 'scripts/runtime_guardian_executor.py')
runner = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'guardian_protocol': protocol}): spec.loader.exec_module(runner)


class GuardianExecutorTests(unittest.TestCase):
    def exercise(self, stage=None, ordinal=1):
        real_pipe, real_dup, real_close = os.pipe, os.dup, os.close
        real_dup2, real_block, real_fsync = os.dup2, os.set_blocking, os.fsync
        real_select, real_read = runner.select.select, os.read
        real_open = Path.open
        owned, handles, streams = [], [], []
        calls, injected = {}, []
        def fail(point):
            calls[point] = calls.get(point, 0) + 1
            if stage == point and calls[point] == ordinal:
                injected.append(point); raise OSError(errno.EIO, 'injected ' + point)
        def pipe():
            fail('pipe'); result = real_pipe(); owned.extend(result); return result
        def dup2(old, new, **kw):
            fail('dup2'); result = real_dup2(old, new, **kw); owned.append(new); return result
        def close(fd):
            if fd in (207, 208): fail('close-fixed')
            return real_close(fd)
        def blocking(fd, value): fail('nonblocking'); return real_block(fd, value)
        def fsync(fd): fail('fsync'); return real_fsync(fd)
        def select(*args): fail('select'); return real_select(*args)
        def read(*args): fail('read'); return real_read(*args)
        def opened(path, *args, **kw):
            stream = real_open(path, *args, **kw); streams.append(stream); return stream
        class Handle:
            def __init__(self, command, **kw):
                fail('spawn')
                self.pid = 999_999; self.exit = None
                cr, sw = real_dup(207), real_dup(208)
                out_r, out_w = real_pipe(); err_r, err_w = real_pipe()
                owned.extend((cr, sw, out_r, out_w, err_r, err_w))
                self.stdout, self.stderr = os.fdopen(out_r, 'rb'), os.fdopen(err_r, 'rb')
                streams.extend((self.stdout, self.stderr))
                def simulate():
                    common = dict(schema=protocol.GuardianProtocol.SCHEMA, suite='runtime-guardian', nonce='a' * 32)
                    def emit(sequence, event, **fields):
                        os.write(sw, json.dumps(dict(common, sequence=sequence, event=event, **fields)).encode() + b'\n')
                    try:
                        emit(0, 'ready', expected_cases=1, probe='none', source_sha256='b' * 64,
                             executable_sha256=digest, app_sha256=digest)
                        control = real_read(cr, 1)
                        reason = 'cancelled' if control == b'C' else 'callerLost'
                        emit(1, 'cancelled', reason=reason)
                        emit(2, 'terminal', outcome='failed', reason=reason, expected_cases=1,
                             begun_cases=0, passed_cases=0, spawned=0, reaped=0, failed_spawns=0,
                             reservations=0, children=0, callbacks=0)
                    finally:
                        for fd in (cr, sw, out_w, err_w): real_close(fd)
                        self.exit = 1
                self.thread = threading.Thread(target=simulate)
                handles.append(self); self.thread.start()
            def poll(self): return self.exit
            def kill(self): raise AssertionError('guardian kill forbidden')
            def terminate(self): raise AssertionError('guardian termination forbidden')
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            executable = root / 'fixture'; executable.write_bytes(b'bound fake executable')
            digest = hashlib.sha256(executable.read_bytes()).hexdigest()
            profile = root / 'fixture.sb'; profile.write_text('unused by simulated handle')
            with patch.object(runner.os, 'pipe', pipe), patch.object(runner.os, 'dup2', dup2), \
                 patch.object(runner.os, 'close', close), patch.object(runner.os, 'set_blocking', blocking), \
                 patch.object(runner.os, 'fsync', fsync), patch.object(runner.select, 'select', select), \
                 patch.object(runner.os, 'read', read), patch.object(runner.subprocess, 'Popen', Handle), \
                 patch.object(Path, 'open', opened):
                record = runner.execute(executable=executable, app=executable,
                    suite='runtime-guardian', cases=['one'], nonce='a' * 32, source_sha256='b' * 64,
                    executable_sha256=digest, app_sha256=digest, profile=profile,
                    environment={'SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE': 'a' * 32},
                    evidence=root / 'evidence', seconds=2, behavior='lost-before-run')
            for handle in handles:
                handle.thread.join(1); self.assertFalse(handle.thread.is_alive())
            self.assertTrue(all(stream.closed for stream in streams))
            for fd in set(owned):
                with self.assertRaises(OSError) as failure: os.fstat(fd)
                self.assertEqual(failure.exception.errno, errno.EBADF)
            if stage is not None:
                self.assertEqual(injected, [stage]); self.assertTrue(record['errors'])
            self.assertFalse(record['passed'])
            self.assertEqual(record['original_reaped'], bool(handles))
            return record

    def test_normal_caller_loss_keeps_original_handle(self):
        record = self.exercise()
        self.assertTrue(record['protocol_complete']); self.assertFalse(record['errors'])
        self.assertEqual(record['terminal']['reason'], 'callerLost')

    def test_each_pipe_allocation_failure_closes_prior_pair(self):
        for ordinal in [1, 2]:
            with self.subTest(ordinal=ordinal): self.exercise('pipe', ordinal)

    def test_each_fixed_descriptor_allocation_failure(self):
        for ordinal in [1, 2]:
            with self.subTest(ordinal=ordinal): self.exercise('dup2', ordinal)

    def test_failed_spawn_closes_all_pipes(self): self.exercise('spawn')

    def test_each_nonblocking_boundary_retains_drainage(self):
        for ordinal in [1, 2, 3, 4]:
            with self.subTest(ordinal=ordinal): self.exercise('nonblocking', ordinal)

    def test_duplicate_close_failures_are_retried_with_handle_retained(self):
        for ordinal in [1, 2]:
            with self.subTest(ordinal=ordinal): self.exercise('close-fixed', ordinal)

    def test_observer_failures_cancel_and_continue_drainage(self):
        for stage in ['select', 'read']:
            with self.subTest(stage=stage): self.exercise(stage)

    def test_each_fsync_failure_still_closes_evidence(self):
        for ordinal in [1, 2, 3, 4]:
            with self.subTest(ordinal=ordinal): self.exercise('fsync', ordinal)


if __name__ == '__main__': unittest.main()
