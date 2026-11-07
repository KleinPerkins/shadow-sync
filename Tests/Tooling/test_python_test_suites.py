"""Actual framework callbacks, including negative and incomplete executions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/python-test-suites.py'
SPEC = importlib.util.spec_from_file_location('python_suites', SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class PythonSuiteTests(unittest.TestCase):
    def exercise(self, source, *arguments):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-unittest-contract-') as directory:
            directory = str(Path(directory).resolve())
            (Path(directory) / 'test_fixture.py').write_text(source)
            return subprocess.run([sys.executable, '-B', str(SCRIPT), '--test-directory', directory,
                                   *arguments], capture_output=True, text=True, timeout=15)

    def test_framework_discovery_lists_cases_without_running_them(self):
        result = self.exercise('import unittest\nclass Cases(unittest.TestCase):\n'
                               ' def test_one(self): raise RuntimeError("must not execute")\n', '--list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['suites'],
                         [{'id': 'test_fixture', 'cases': ['test_fixture.Cases.test_one']}])

    def test_success_reports_exact_actual_case_ids(self):
        result = self.exercise('import unittest\nclass Cases(unittest.TestCase):\n'
                              ' def test_one(self): self.assertEqual(1 + 1, 2)\n'
                              ' def test_two(self): self.assertTrue(True)\n', '--all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ['PASS test_fixture.Cases.test_one', 'PASS test_fixture.Cases.test_two'])

    def test_failure_continues_later_cases_and_remains_failure(self):
        result = self.exercise('import unittest\nclass Cases(unittest.TestCase):\n'
                              ' def test_a(self): self.fail("fixture")\n'
                              ' def test_z(self): pass\n', '--suite', 'test_fixture')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(),
                         ['FAIL test_fixture.Cases.test_a',
                          'DIAGNOSTIC ' + json.dumps({
                              'schema': 'shadow-sync-python-failure/v1',
                              'case': 'test_fixture.Cases.test_a', 'cause': 'assertion',
                              'operation': 'unspecified', 'phase': 'unspecified', 'exit_code': None},
                              sort_keys=True, separators=(',', ':')),
                          'PASS test_fixture.Cases.test_z'])

    def test_diagnostics_keep_only_closed_failure_fields(self):
        for cause, expression in [
                ('timeout', 'subprocess.TimeoutExpired(["private-command"], 5, output="private-output")'),
                ('assertion', 'AssertionError("private-message")'),
                ('os-error', 'OSError("private-path")'),
                ('other', 'RuntimeError("private-environment")')]:
            with self.subTest(cause=cause):
                result = self.exercise('import unittest, subprocess\nclass Cases(unittest.TestCase):\n'
                    ' def test_one(self):\n'
                    '  error = ' + expression + '\n'
                    '  error.shadow_sync_diagnostic = {"operation":"fixture-install", '
                    '"phase":"run", "exit_code":None, "extra":"private-extra"}\n'
                    '  raise error\n', '--all')
                self.assertEqual(result.returncode, 1)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[0], 'FAIL test_fixture.Cases.test_one')
                self.assertEqual(json.loads(lines[1].removeprefix('DIAGNOSTIC ')), {
                    'schema': 'shadow-sync-python-failure/v1', 'case': 'test_fixture.Cases.test_one',
                    'cause': cause, 'operation': 'fixture-install', 'phase': 'run', 'exit_code': None})
                self.assertEqual(len(lines), 2)
                self.assertNotIn('private-', result.stdout + result.stderr)

    def test_diagnostics_reject_arbitrary_metadata_and_bound_exit_status(self):
        for detail in ({'operation': 'private-path', 'phase': ['private-value'], 'exit_code': True},
                       {'operation': {}, 'phase': 'private-command', 'exit_code': 256},
                       {'exit_code': -256}, ['private-output']):
            with self.subTest(detail=detail):
                error = AssertionError('private-message')
                error.shadow_sync_diagnostic = detail
                diagnostic = runner.failure_diagnostic(self, (type(error), error, None))
                self.assertEqual(diagnostic['operation'], 'unspecified')
                self.assertEqual(diagnostic['phase'], 'unspecified')
                self.assertIsNone(diagnostic['exit_code'])
                self.assertNotIn('private-', json.dumps(diagnostic))
        for exit_code in (-255, -9, 0, 64, 255):
            error = AssertionError('private-message')
            error.shadow_sync_diagnostic = {'exit_code': exit_code}
            self.assertEqual(runner.failure_diagnostic(self, (type(error), error, None))['exit_code'], exit_code)

    def test_skip_expected_failure_unexpected_success_and_setup_errors_refuse(self):
        bodies = [
            ' @unittest.skip("fixture")\n def test_one(self): pass\n',
            ' @unittest.expectedFailure\n def test_one(self): self.fail("fixture")\n',
            ' @unittest.expectedFailure\n def test_one(self): pass\n',
            ' def setUp(self): raise RuntimeError("fixture")\n def test_one(self): pass\n',
            ' @classmethod\n def setUpClass(cls): raise RuntimeError("fixture")\n def test_one(self): pass\n',
            ' def test_one(self):\n  with self.subTest(case=1): self.fail("fixture")\n',
        ]
        for body in bodies:
            with self.subTest(body=body):
                result = self.exercise('import unittest\nclass Cases(unittest.TestCase):\n' + body, '--all')
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn('PASS ', result.stdout)

    def test_empty_broken_and_unknown_registration_refuse(self):
        for source in ('import unittest\n', 'raise RuntimeError("import failure")\n'):
            with self.subTest(source=source):
                result = self.exercise(source, '--list')
                self.assertEqual(result.returncode, 1)
                self.assertNotIn('PASS ', result.stdout)
        result = self.exercise('import unittest\nclass Cases(unittest.TestCase):\n'
                              ' def test_one(self): pass\n', '--suite', 'unknown')
        self.assertEqual(result.returncode, 1)

    def test_completion_requires_started_stopped_and_passed_rosters(self):
        result = runner.CompletionResult(lambda _: None)
        expected = ['test_fixture.Cases.test_one']
        for field in ('started', 'stopped', 'passed'):
            setattr(result, field, list(expected))
        result.testsRun = 1
        self.assertTrue(result.complete(expected))
        for field in ('started', 'stopped', 'passed'):
            setattr(result, field, [])
            self.assertFalse(result.complete(expected))
            setattr(result, field, list(expected))
        self.assertFalse(result.complete([]))

    def test_custom_discovery_cannot_hide_a_case(self):
        result = self.exercise('import unittest\nclass Cases(unittest.TestCase):\n'
                              ' def test_one(self): pass\n def test_hidden(self): pass\n'
                              'def load_tests(loader, tests, pattern):\n'
                              ' return unittest.TestSuite([Cases("test_one")])\n', '--list')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')

    def test_linked_module_and_linked_ancestor_refuse(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-unittest-links-') as temporary:
            root = Path(temporary).resolve()
            directory = root / 'Tooling'; directory.mkdir()
            source = root / 'original.py'
            source.write_text('import unittest\nclass Cases(unittest.TestCase):\n'
                              ' def test_one(self): pass\n')
            target = directory / 'test_fixture.py'
            os.link(source, target)
            result = subprocess.run([sys.executable, '-B', str(SCRIPT),
                                     '--test-directory', str(directory), '--list'],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1)
            target.unlink(); target.write_bytes(source.read_bytes())
            linked = root / 'linked-parent'; linked.symlink_to(root, target_is_directory=True)
            result = subprocess.run([sys.executable, '-B', str(SCRIPT),
                                     '--test-directory', str(linked / 'Tooling'), '--list'],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1)


if __name__ == '__main__':
    unittest.main()
