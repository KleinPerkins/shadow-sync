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
    def test_runner_environment_enables_only_registered_diagnostic_consumers(self):
        root = Path('/fixture/work')
        with patch.dict(runtime.os.environ, {'SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS': 'costs',
                'SHADOW_SYNC_TEST_M6_DIAGNOSTICS': 'foreign', 'UNRELATED_HOST_VALUE': 'private'}):
            for suite in ('retention-custody', 'discovery-caller', 'm6', 'body3',
                          'beta-v07', 'fixture-unknown'):
                with self.subTest(suite=suite):
                    env = runtime.fixture_environment(suite, root, 'a' * 32,
                        Path('/fixture/python'), Path('/fixture/build'),
                        Path('/fixture/framework'), Path('/fixture/policy.json'))
                    self.assertEqual(env.get('SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS'),
                        '1' if suite in ('retention-custody', 'discovery-caller', 'body3') else None)
                    self.assertEqual(env.get('SHADOW_SYNC_TEST_M6_DIAGNOSTICS'),
                        '1' if suite == 'm6' else None)
                    self.assertNotIn('UNRELATED_HOST_VALUE', env)
                    self.assertEqual(env['HOME'], '/fixture/work/home')
                    self.assertEqual(env['TMPDIR'], '/fixture/work/tmp')
                    self.assertEqual(env['SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE'], 'a' * 32)
                    self.assertEqual(env['GIT_CONFIG_NOSYSTEM'], '1')
                    self.assertEqual(env['GIT_CONFIG_GLOBAL'], '/dev/null')
                    self.assertEqual(env['GIT_CONFIG_SYSTEM'], '/dev/null')

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
        self.assertEqual(len(grants), 3)
        for prefix, line in zip(('shadow-sync-m4[.]', 'shadow-sync-self-tests[.]'), grants[:2]):
            self.assertIn('^/private/tmp/' + prefix + nonce + '[.]', line)
            self.assertIn('/(host[.]sock|agent[.]sock)$', line)
            self.assertNotIn('ip)', line)
            self.assertNotIn('unix-socket)', line)

        patterns = [line.split('regex #"', 1)[1].split('"', 1)[0] for line in grants]
        own = '/private/tmp/shadow-sync-ic.' + nonce + '.case/state/shadow-sync/'
        self.assertIsNotNone(re.fullmatch(patterns[2], own + 'installation.sock'))
        self.assertTrue(all(re.fullmatch(pattern, own + 'installation.sock') is None
                            for pattern in patterns[:2]))
        for path in (own.replace(nonce, 'b' * 32) + 'installation.sock',
                     own.replace('shadow-sync-ic.', 'shadow-sync-self-tests.') + 'installation.sock',
                     own.replace('/state/shadow-sync/', '/state/other/') + 'installation.sock',
                     own + 'nested/installation.sock', own + 'host.sock',
                     own + 'installation.sock.extra', own + 'other.sock',
                     '127.0.0.1:443', 'example.invalid:443'):
            self.assertTrue(all(re.fullmatch(pattern, path) is None for pattern in patterns), path)


class RetentionCleanupCostOptionTests(unittest.TestCase):
    def environment(self, suite, **options):
        return runtime.fixture_environment(suite, Path('/fixture/work'), 'a' * 32,
            Path('/fixture/python'), Path('/fixture/build'),
            Path('/fixture/framework'), Path('/fixture/policy.json'), **options)

    def test_default_and_explicit_false_do_not_inherit_host_cleanup_cost_flag(self):
        key = 'SHADOW_SYNC_TEST_RETENTION_CLEANUP_COSTS'
        with patch.dict(runtime.os.environ, {key: '1'}):
            for suite in ('body3', 'retention-custody', 'discovery-caller', 'm6',
                          'beta-v07', 'fixture-unknown'):
                with self.subTest(suite=suite):
                    implicit = self.environment(suite)
                    explicit = self.environment(suite, retention_cleanup_costs=False)
                    self.assertEqual(implicit, explicit)
                    self.assertNotIn(key, implicit)
                    self.assertEqual(implicit.get('SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS'),
                        '1' if suite in ('body3', 'retention-custody', 'discovery-caller') else None)

    def test_explicit_body3_cost_opt_in_adds_only_the_closed_marker(self):
        key = 'SHADOW_SYNC_TEST_RETENTION_CLEANUP_COSTS'
        for inherited in ('0', '1', 'foreign'):
            with self.subTest(inherited=inherited), patch.dict(runtime.os.environ, {key: inherited}):
                normal = self.environment('body3')
                diagnostic = self.environment('body3', retention_cleanup_costs=True)
                self.assertEqual(diagnostic, {**normal, key: '1'})
                self.assertEqual(diagnostic['SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS'], '1')

    def test_environment_cost_option_rejects_non_boolean_values(self):
        for value in (None, 0, 1, '1', 'true', [], {}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.environment('body3', retention_cleanup_costs=value)

    def test_environment_cost_opt_in_rejects_every_other_suite(self):
        for suite in ('retention-custody', 'discovery-caller', 'm6', 'beta-v07',
                      'fixture-unknown', 'Body3'):
            with self.subTest(suite=suite), self.assertRaises(ValueError):
                self.environment(suite, retention_cleanup_costs=True)

    def test_run_suite_rejects_invalid_options_before_inventory_or_root_creation(self):
        invalid = [('body3', value) for value in (None, 0, 1, '1', [], {})]
        invalid += [(suite, True) for suite in ('retention-custody', 'discovery-caller',
                                               'm6', 'beta-v07', 'fixture-unknown')]
        with patch.object(runtime, 'load') as load, patch.object(Path, 'mkdir') as mkdir:
            for suite, value in invalid:
                with self.subTest(suite=suite, value=value), self.assertRaises(ValueError):
                    runtime.run_suite(suite, Path('/fixture/work'), Path('/fixture/build'),
                        {}, {}, retention_cleanup_costs=value)
            load.assert_not_called()
            mkdir.assert_not_called()

    def test_existing_positional_runner_call_and_explicit_valid_modes_reach_inventory(self):
        # Stop at the first external dependency: this control creates no roots,
        # inspects no tools and runs no native commands.
        for suite, options in (('body3', {}), ('body3', {'retention_cleanup_costs': False}),
                               ('body3', {'retention_cleanup_costs': True}), ('m6', {})):
            with self.subTest(suite=suite, options=options), \
                 patch.object(runtime, 'load', side_effect=RuntimeError('fixture inventory boundary')) as load, \
                 patch.object(Path, 'mkdir') as mkdir:
                with self.assertRaisesRegex(RuntimeError, '^fixture inventory boundary$'):
                    runtime.run_suite(suite, Path('/fixture/work'), Path('/fixture/build'), {}, {}, **options)
                load.assert_called_once_with('runtime-suite-inventory')
                mkdir.assert_not_called()

    def test_new_diagnostic_option_is_keyword_only(self):
        with self.assertRaises(TypeError):
            runtime.fixture_environment('body3', Path('/fixture/work'), 'a' * 32,
                Path('/fixture/python'), Path('/fixture/build'), Path('/fixture/framework'),
                Path('/fixture/policy.json'), True)
        with patch.object(runtime, 'load') as load, self.assertRaises(TypeError):
            runtime.run_suite('body3', Path('/fixture/work'), Path('/fixture/build'), {}, {}, True)
        load.assert_not_called()


if __name__ == '__main__':
    unittest.main()
