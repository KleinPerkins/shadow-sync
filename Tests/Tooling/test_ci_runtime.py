"""Regression checks for hosted runtime resource, IPC and coverage boundaries."""
import importlib.util
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ci_runtime', ROOT / 'scripts/ci-runtime.py')
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class CIRuntimeTests(unittest.TestCase):
    def test_complete_roster_allows_actual_composite_execution_order(self):
        result = runtime.canonical_output('beta-v07', ['sources', 'body'],
            b'PASS beta-v07/body\nPASS beta-v07/sources\n', complete=True)
        self.assertEqual(result, b'PASS body\nPASS sources\n')

    def test_complete_roster_still_rejects_missing_cases(self):
        with self.assertRaises(ValueError):
            runtime.canonical_output('fixture', ['one', 'two'], b'PASS fixture/one\n', complete=True)

    def test_duplicate_and_foreign_cases_remain_failures(self):
        for value in (b'PASS fixture/one\nPASS fixture/one\n',
                      b'PASS foreign/one\n', b'PASS fixture/unknown\n'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                runtime.canonical_output('fixture', ['one'], value, complete=True)

    def test_incomplete_attempt_preserves_only_observed_cases(self):
        self.assertEqual(runtime.canonical_output('fixture', ['one', 'two'],
            b'PASS fixture/one\n', complete=False), b'PASS one\n')

    def test_fixture_stages_exact_policy_pin_outside_checkout(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-ci-resource-') as name:
            root = Path(name).resolve()
            checkout = root / 'checkout'; (checkout / 'Resources').mkdir(parents=True)
            pin = checkout / 'Resources/policy-runtime-source.json'
            pin.write_bytes(b'{"fixture":"preserve exact bytes"}\n')
            work = root / 'work'; work.mkdir(mode=0o700)
            with patch.object(runtime, 'ROOT', checkout):
                staged = runtime.stage_policy_source(work)
            self.assertEqual(staged.parent, work)
            self.assertEqual(staged.read_bytes(), pin.read_bytes())
            self.assertEqual(staged.stat().st_mode & 0o777, 0o600)

    def test_fixture_never_overwrites_existing_resource(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-ci-resource-') as name:
            root = Path(name).resolve()
            target = root / 'policy-runtime-source.json'; target.write_bytes(b'preserve')
            with self.assertRaises(FileExistsError): runtime.stage_policy_source(root)
            self.assertEqual(target.read_bytes(), b'preserve')

    def test_private_staging_preserves_build_bytes_and_required_publisher_mode(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-ci-binary-') as name:
            root = Path(name).resolve()
            source = root / 'original'; source.write_bytes(b'fixture bytes')
            source.chmod(0o700)
            target = runtime.stage_runtime_executable(root, source)
            self.assertEqual(source.stat().st_mode & 0o777, 0o700)
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            self.assertEqual(source.read_bytes(), target.read_bytes())
            with self.assertRaises(FileExistsError): runtime.stage_runtime_executable(root, source)

    def test_var_alias_fixture_is_explicit_nonce_bound_and_cleanup_registered(self):
        self.assertEqual([row for row in runtime.FIXTURE_LOCATIONS if row[0] != '/private/tmp'],
                         [('/private/var/tmp', 'shadow-sync-m2.')])
        nonce = 'b' * 32
        profile = runtime.profile(Path('/private/tmp/shadow-sync-ci.fixture'), nonce,
                                  '/fixture/tests', '/fixture/app', '/fixture/python')
        lines = [line for line in profile.splitlines() if '/private/var/tmp' in line]
        self.assertEqual(lines, [
            '(deny file-read* file-write* (regex #"^/private/var/tmp/shadow-sync-m2[.]"))',
            '(allow file-read* file-write* (regex #"^/private/var/tmp/shadow-sync-m2[.]' + nonce
                + '[.][A-Za-z0-9-]+(/.*)?$"))'])

    def test_unsafe_mode_fixture_grant_cannot_reach_other_files(self):
        nonce = 'c' * 32
        profile = runtime.profile(Path('/private/tmp/shadow-sync-ci.fixture'), nonce,
                                  '/fixture/tests', '/fixture/app', '/fixture/python')
        grants = [line for line in profile.splitlines() if line.startswith('(allow file-write-setugid')]
        self.assertEqual(len(grants), 1)
        pattern = re.search(r'regex #"([^"\n]+)"', grants[0]).group(1)
        own = '/private/tmp/shadow-sync-state-admission.' + nonce + '.case/state/shadow-sync'
        for suffix in ('', '/latest.log', '/preserved.log', '/lifecycle.lock', '/operation.lock', '/run.lock', '/launcher.lock'):
            self.assertIsNotNone(re.fullmatch(pattern, own + suffix))
        for path in (own + '/helper', own + '/nested/latest.log', own + '/operation.lock.extra',
                     own.replace(nonce, 'd' * 32), own.replace('state-admission', 'self-tests')):
            self.assertIsNone(re.fullmatch(pattern, path))

    def test_fsmonitor_execution_grant_is_exact_and_nonce_bound(self):
        nonce = 'c' * 32
        profile = runtime.profile(Path('/private/tmp/shadow-sync-ci.fixture'), nonce,
                                  '/fixture/tests', '/fixture/app', '/fixture/python')
        grants = [line for line in profile.splitlines() if '-fsmonitor' in line]
        self.assertEqual(len(grants), 1)
        pattern = re.search(r'regex #"([^"\n]+)"', grants[0]).group(1)
        own = '/private/tmp/shadow-sync-self-tests.' + nonce + '.case/'
        self.assertIsNotNone(re.fullmatch(pattern, own + 'hostile-fsmonitor.sh'))
        self.assertIsNotNone(re.fullmatch(pattern, own + 'blocking-fsmonitor.sh'))
        for path in (own + 'unlisted.sh', own + 'nested/hostile-fsmonitor.sh',
                     own.replace(nonce, 'd' * 32) + 'hostile-fsmonitor.sh',
                     own + 'hostile-fsmonitor.sh.extra'):
            self.assertIsNone(re.fullmatch(pattern, path))

    def test_local_ipc_permission_is_namespace_and_socket_name_bound(self):
        nonce = 'a' * 32
        profile = runtime.profile(Path('/private/tmp/shadow-sync-ci.fixture'), nonce,
                                  '/fixture/tests', '/fixture/app', '/fixture/python')
        self.assertIn('(deny network*)', profile)
        grants = [line for line in profile.splitlines() if line.startswith('(allow network')]
        self.assertEqual(len(grants), 2)
        for prefix, line in zip(('shadow-sync-m4[.]', 'shadow-sync-self-tests[.]'), grants):
            self.assertIn('^/private/tmp/' + prefix + nonce + '[.]', line)
            self.assertIn('/(host[.]sock|agent[.]sock)$', line)
            self.assertNotIn('ip)', line)
            self.assertNotIn('unix-socket)', line)


if __name__ == '__main__':
    unittest.main()
