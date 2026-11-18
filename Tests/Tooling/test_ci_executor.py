"""Disposable command execution and negative coverage/cleanup qualification."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ci_executor', ROOT / 'scripts/ci-execute.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
ci = runner.ci


class CIExecutorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shadow-sync-ci-executor-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.artifacts = self.root / 'artifacts'; self.artifacts.mkdir(mode=0o700)
        self.diagnostics = self.root / 'diagnostics'; self.diagnostics.mkdir(mode=0o700)
        self.worker = self.root / 'worker.py'
        self.worker.write_text('''import json, os, sys, signal, time
context = json.loads(os.environ['SHADOW_SYNC_CI_CONTEXT'])
mode = sys.argv[1]
if mode == 'timeout':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(3))
    while True: time.sleep(.01)
if mode == 'deadline-cleanup':
    cancelled = False
    def cancel(*_):
        global cancelled
        cancelled = True
    signal.signal(signal.SIGTERM, cancel)
    while not cancelled: time.sleep(.01)
if mode != 'missing':
    if mode == 'stale': context['nonce'] = '0' * 32
    receipt = {'schema':'shadow-sync-ci-command-completion/v1', **context,
               'cleanup_complete':1 if mode == 'numeric-cleanup' else mode != 'cleanup-failed'}
    with open(os.environ['SHADOW_SYNC_CI_COMPLETION'], 'x') as f: json.dump(receipt, f)
name = context['suite']
print('PASS ' + name + '/one', flush=True)
if mode != 'partial': print('PASS ' + name + '/two', flush=True)
if mode == 'duplicate': print('PASS ' + name + '/one', flush=True)
if mode == 'extra': print('PASS unknown/case', flush=True)
if mode == 'failed': print('FAIL ' + name + '/one', flush=True)
if mode == 'skipped': print('SKIP ' + name + '/one', flush=True)
if mode == 'exit': sys.exit(2)
if mode == 'deadline-cleanup': sys.exit(3)
''')
        self.contract = {'schema': 'shadow-sync-test-shards/v1', 'coverage': {
            'schema': 'shadow-sync-ci-coverage/v1', 'jobs': {}, 'suites': {}},
            'shards': {}, 'commands': {}}
        for job, kind in ci.coverage.JOBS.items():
            names = [job + '-first', job + '-second']
            self.contract['coverage']['jobs'][job] = names
            self.contract['shards'][job] = 1
            for name in names:
                self.contract['coverage']['suites'][name] = {'kind': kind,
                    'cases': [name + '/one', name + '/two']}
                self.contract['commands'][name] = {
                    'argv': [sys.executable, '-I', '-B', str(self.worker), 'pass'],
                    'timeout_seconds': 5}
        self.identity = dict(revision='a' * 40, source_sha256='b' * 64, run_id='12', run_attempt='1')
        self.source_calls = 0
        self.source_changed = False
        self.unit_id = 'runtime-safety-0'
        self.first = 'runtime-safety-first'

    def source(self, root, revision):
        self.assertEqual((root, revision), (self.root, self.identity['revision']))
        self.source_calls += 1
        return ('c' if self.source_changed and self.source_calls > 1 else 'b') * 64

    def run_unit(self, *, mode='pass', base='same', alter_plan=None, observe=runner.observe_command,
                 stop_after_failure=False):
        self.contract['commands'][self.first]['argv'][-1] = mode
        head = ci.encode(self.contract)
        base_bytes = head if base == 'same' else None
        plan = ci.make_plan(head, base_bytes, **self.identity)
        if alter_plan:
            alter_plan(plan)
        return runner.execute_unit(self.root, head, base_bytes, ci.encode(plan), self.unit_id,
            self.artifacts, self.diagnostics, identity=self.identity,
            environment={'PATH': os.defpath}, source=self.source, observe=observe,
            stop_after_failure=stop_after_failure)

    def receipt(self, name=None):
        return json.loads((self.artifacts / self.unit_id / ((name or self.first) + '.json')).read_bytes())

    def test_actual_commands_and_exact_receipts_pass_existing_gate(self):
        self.assertTrue(self.run_unit())
        self.assertEqual(self.source_calls, 2)
        self.assertEqual(self.receipt()['passed_cases'], [self.first + '/one', self.first + '/two'])
        self.assertTrue(self.receipt()['cleanup_complete'])
        self.artifacts = self.root / 'early-pass-artifacts'; self.artifacts.mkdir()
        self.diagnostics = self.root / 'early-pass-diagnostics'; self.diagnostics.mkdir()
        self.assertTrue(self.run_unit(stop_after_failure=True))
        unit = json.loads((self.artifacts / self.unit_id / 'unit.json').read_bytes())
        self.assertEqual(unit['status'], 'complete')
        self.assertEqual(unit['suites'], ['runtime-safety-first', 'runtime-safety-second'])
        self.assertEqual(self.receipt('runtime-safety-second')['passed_cases'],
                         ['runtime-safety-second/one', 'runtime-safety-second/two'])

    def test_actual_command_nonzero_continues_independent_drained_suite(self):
        self.assertFalse(self.run_unit(mode='exit'))
        self.assertEqual(self.receipt()['exit_code'], 2)
        self.assertEqual(self.receipt('runtime-safety-second')['status'], 'complete')
        self.assertEqual(json.loads((self.artifacts / self.unit_id / 'unit.json').read_bytes())['status'], 'failed')
        self.artifacts = self.root / 'early-fail-artifacts'; self.artifacts.mkdir()
        self.diagnostics = self.root / 'early-fail-diagnostics'; self.diagnostics.mkdir()
        self.assertFalse(self.run_unit(mode='exit', stop_after_failure=True))
        self.assertEqual(self.receipt()['exit_code'], 2)
        self.assertTrue(self.receipt()['cleanup_complete'])
        observer = json.loads((self.diagnostics / self.unit_id / self.first / 'observer.json').read_bytes())
        self.assertTrue(observer['original_reaped'])
        self.assertFalse((self.artifacts / self.unit_id / 'runtime-safety-second.json').exists())
        head = ci.encode(self.contract); plan = ci.make_plan(head, head, **self.identity)
        unit = next(row for row in plan['units'] if row['id'] == self.unit_id)
        self.assertEqual(json.loads((self.artifacts / self.unit_id / 'unit.json').read_bytes())['status'], 'failed')
        with self.assertRaises(ci.InvalidEvidence):
            ci.verify_unit(ci.registration(head), plan, unit, self.artifacts / self.unit_id)
        # Every other actual unit may pass; this partial failed runtime unit
        # must still prevent ci-required, even if job outcomes claim success.
        for other in plan['units']:
            if other['id'] != self.unit_id:
                self.assertTrue(runner.execute_unit(self.root, head, head, ci.encode(plan), other['id'],
                    self.artifacts, self.diagnostics, identity=self.identity,
                    environment={'PATH': os.defpath}, source=self.source))
        needs = {job: {'result': 'success', 'outputs': {}} for job in ('plan', *ci.coverage.JOBS)}
        with self.assertRaises(ci.InvalidEvidence):
            ci.aggregate(head, head, ci.encode(plan), ci.encode(needs), self.artifacts, **self.identity)

    def test_reaped_cleanup_after_suite_deadline_continues_failed_unit(self):
        self.contract['commands'][self.first]['timeout_seconds'] = 1
        self.assertFalse(self.run_unit(mode='deadline-cleanup'))
        self.assertTrue(self.receipt()['cleanup_complete'])
        self.assertEqual(self.receipt()['exit_code'], 3)
        observer = json.loads((self.diagnostics / self.unit_id / self.first / 'observer.json').read_bytes())
        self.assertEqual(observer['errors'], ['deadline'])
        self.assertTrue(observer['original_reaped'])
        self.assertEqual(self.receipt('runtime-safety-second')['status'], 'complete')
        self.assertEqual(json.loads((self.artifacts / self.unit_id / 'unit.json').read_bytes())['status'], 'failed')

    def test_suite_cleanup_marker_cannot_replace_original_reap(self):
        def observe(*args, **kwargs):
            result = runner.observe_command(*args, **kwargs)
            result['original_reaped'] = False
            return result
        self.assertFalse(self.run_unit(observe=observe))
        self.assertFalse(self.receipt()['cleanup_complete'])
        self.assertFalse((self.artifacts / self.unit_id / 'runtime-safety-second.json').exists())

    def test_suite_cleanup_marker_cannot_override_observer_integrity_errors(self):
        for error in ('output-limit', 'descendants', 'unknown-observer-error'):
            with self.subTest(error=error):
                self.artifacts = self.root / ('artifacts-' + error); self.artifacts.mkdir()
                self.diagnostics = self.root / ('diagnostics-' + error); self.diagnostics.mkdir()
                def observe(*args, **kwargs):
                    result = runner.observe_command(*args, **kwargs)
                    result['errors'] = ['deadline', error]
                    return result
                self.assertFalse(self.run_unit(observe=observe))
                self.assertFalse(self.receipt()['cleanup_complete'])
                self.assertFalse((self.artifacts / self.unit_id / 'runtime-safety-second.json').exists())

    def test_assertion_failure_preserved_and_independent_suite_continues(self):
        self.assertFalse(self.run_unit(mode='failed'))
        self.assertEqual(self.receipt()['failed_cases'], [self.first + '/one'])
        self.assertEqual(self.receipt('runtime-safety-second')['status'], 'complete')

    def test_skip_fails_coverage(self):
        self.assertFalse(self.run_unit(mode='skipped'))
        self.assertEqual(self.receipt()['skipped_cases'], [self.first + '/one'])

    def test_duplicate_success_fails_coverage(self):
        self.assertFalse(self.run_unit(mode='duplicate'))
        self.assertEqual(len(self.receipt()['passed_cases']), 3)

    def test_partial_success_fails_coverage(self):
        self.assertFalse(self.run_unit(mode='partial'))
        self.assertEqual(len(self.receipt()['passed_cases']), 1)
        self.artifacts = self.root / 'early-partial-artifacts'; self.artifacts.mkdir()
        self.diagnostics = self.root / 'early-partial-diagnostics'; self.diagnostics.mkdir()
        self.assertFalse(self.run_unit(mode='partial', stop_after_failure=True))
        self.assertTrue(self.receipt()['cleanup_complete'])
        self.assertEqual(self.receipt()['passed_cases'], [self.first + '/one'])
        self.assertFalse((self.artifacts / self.unit_id / 'runtime-safety-second.json').exists())
        self.assertEqual(json.loads((self.artifacts / self.unit_id / 'unit.json').read_bytes())['status'], 'failed')

    def test_unregistered_success_fails_coverage(self):
        self.assertFalse(self.run_unit(mode='extra'))

    def test_missing_cleanup_stops_admission(self):
        self.assertFalse(self.run_unit(mode='missing'))
        self.assertFalse(self.receipt()['cleanup_complete'])
        self.assertFalse((self.artifacts / self.unit_id / 'runtime-safety-second.json').exists())

    def test_numeric_cleanup_is_not_boolean_confirmation(self):
        self.assertFalse(self.run_unit(mode='numeric-cleanup'))
        self.assertFalse(self.receipt()['cleanup_complete'])

    def test_failed_cleanup_stops_admission(self):
        self.assertFalse(self.run_unit(mode='cleanup-failed'))
        self.assertFalse((self.artifacts / self.unit_id / 'runtime-safety-second.json').exists())

    def test_stale_cleanup_cannot_qualify_new_execution(self):
        self.assertFalse(self.run_unit(mode='stale'))
        self.assertFalse(self.receipt()['cleanup_complete'])

    def test_source_changes_cannot_complete_unit(self):
        self.source_changed = True
        self.assertFalse(self.run_unit())
        self.assertIn({'error': 'source-binding-changed'}, json.loads(
            (self.diagnostics / self.unit_id / 'errors.json').read_bytes()))

    def test_wrong_plan_refused_before_command_execution(self):
        with self.assertRaises(ci.InvalidEvidence):
            self.run_unit(alter_plan=lambda p: p.update(run_attempt='2'))
        self.assertEqual(list(self.artifacts.iterdir()), [])

    def test_unknown_unit_refused_before_command_execution(self):
        self.unit_id = 'unknown-0'
        with self.assertRaises(ci.InvalidEvidence): self.run_unit()
        self.assertEqual(list(self.artifacts.iterdir()), [])

    def test_transition_requires_separate_full_execution(self):
        self.unit_id = 'runtime-safety-full'
        self.assertTrue(self.run_unit(base='initial'))
        result = json.loads((self.artifacts / self.unit_id / 'unit.json').read_bytes())
        self.assertEqual(result['unit']['mode'], 'full')
        self.assertEqual(result['suites'], ['runtime-safety-first', 'runtime-safety-second'])

    def test_existing_evidence_is_never_overwritten(self):
        self.assertTrue(self.run_unit())
        before = (self.artifacts / self.unit_id / 'unit.json').read_bytes()
        with self.assertRaises(FileExistsError): self.run_unit()
        self.assertEqual((self.artifacts / self.unit_id / 'unit.json').read_bytes(), before)

    def test_deadline_cooperatively_stops_and_reaps_original(self):
        env = {'PATH': os.defpath, 'SHADOW_SYNC_CI_CONTEXT': '{}'}
        result = runner.observe_command([sys.executable, '-I', '-B', str(self.worker), 'timeout'],
            cwd=self.root, environment=env, log=self.root / 'timeout.log', timeout_seconds=.2)
        self.assertEqual(result['errors'], ['deadline'])
        self.assertEqual(result['exit_code'], 3)
        self.assertTrue(result['original_reaped'])

    def test_deadline_drains_owned_descendant_after_leader_exit(self):
        child=self.root/'descendant.py'
        child.write_text("""import pathlib, signal, sys, time
root=pathlib.Path(sys.argv[1])
def cancel(*_):
    (root/'drained').write_text('TERM received')
    print('descendant drained',flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM,cancel)
(root/'ready').write_text('ready')
time.sleep(2)
""")
        parent=self.root/'parent.py'
        parent.write_text("""import os, pathlib, subprocess, sys, time
root=pathlib.Path(sys.argv[2])
subprocess.Popen([sys.executable,'-I','-B',sys.argv[1],str(root)])
while not (root/'ready').exists(): time.sleep(.01)
if sys.argv[3]=='exit': os._exit(0)
time.sleep(3)
""")
        for mode in ('exit','wait'):
            root=self.root/mode;root.mkdir()
            with self.subTest(mode=mode):
                result=runner.observe_command([sys.executable,'-I','-B',str(parent),str(child),str(root),mode],
                    cwd=self.root,environment={'PATH':os.defpath},log=root/'observed.log',timeout_seconds=.4)
                self.assertEqual(result['errors'],['deadline'])
                self.assertTrue(result['original_reaped'])
                self.assertEqual((root/'drained').read_text(),'TERM received')
                self.assertIn('descendant drained',(root/'observed.log').read_text())
    def test_completion_helper_requires_exact_closed_context_and_no_overwrite(self):
        path = self.root / 'terminal.json'
        context = dict(nonce='d' * 32, suite='fixture', unit_id='runtime-safety-0',
                       plan_sha256='e' * 64, **self.identity)
        env = dict(SHADOW_SYNC_CI_COMPLETION=str(path), SHADOW_SYNC_CI_CONTEXT=json.dumps(context))
        runner.command_completed(True, environment=env)
        self.assertEqual(json.loads(path.read_bytes())['cleanup_complete'], True)
        with self.assertRaises(FileExistsError): runner.command_completed(True, environment=env)
        context['unknown'] = True
        env['SHADOW_SYNC_CI_CONTEXT'] = json.dumps(context)
        with self.assertRaises(ci.InvalidEvidence): runner.command_completed(True, environment=env)

    def test_completion_helper_never_coerces_truthy_cleanup(self):
        with self.assertRaises(ci.InvalidEvidence):
            runner.command_completed('true', environment={})


if __name__ == '__main__':
    unittest.main()
