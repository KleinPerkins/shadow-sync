"""Current-source CI discovery, hosted contracts and runtime evidence boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location('wiring_' + name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CIWiringTests(unittest.TestCase):
    def test_registration_matches_actual_framework_runtime_and_native_discovery(self):
        registration = load('ci-registration')
        registration.verify()
        value = registration.generate()
        suites = value['coverage']['suites']
        runtime = load('runtime-suite-inventory').inspect(ROOT)['suites']
        for row in runtime:
            self.assertEqual(suites['runtime-' + row['id']]['cases'], row['cases'])
        for row in load('run-native-appkit').catalog()[2]:
            self.assertEqual(suites['native-' + row['id']]['cases'], row['cases'])
        for name, cases in load('python-test-suites').discover(ROOT / 'Tests/Tooling').items():
            self.assertEqual(suites['tooling-' + name.replace('_', '-')]['cases'], [case.id() for case in cases])

    def test_initial_and_routine_plans_keep_all_five_nonempty_groups(self):
        ci = load('ci-shards')
        raw = (ROOT / 'config/ci-suites.json').read_bytes()
        identity = dict(revision='a' * 40, source_sha256='b' * 64, run_id='123', run_attempt='1')
        for base, count in ((None, 10), (raw, 5)):
            plan = ci.make_plan(raw, base, **identity)
            self.assertEqual(len(plan['units']), count)
            self.assertEqual({unit['job'] for unit in plan['units']}, set(ci.coverage.JOBS))
            self.assertTrue(all(unit['suites'] and unit['runner'] == 'macos-26'
                                and unit['architecture'] == 'arm64' for unit in plan['units']))
            if base is None:
                self.assertEqual(sum(unit['mode'] == 'full' for unit in plan['units']), 5)

    def test_registered_commands_are_direct_canonical_entrypoints(self):
        ci = load('ci-shards')
        value = ci.registration((ROOT / 'config/ci-suites.json').read_bytes())
        for item in value['commands'].values():
            self.assertEqual(item['argv'][:4], ['python3', '-I', '-B', 'scripts/ci-suite.py'])
            self.assertTrue(0 < item['timeout_seconds'] <= 5400)

    def test_runtime_prefixes_equal_current_main_closed_fixture_roster(self):
        runtime = load('ci-runtime')
        source = (ROOT / 'Sources/ShadowSyncCore/RuntimeFixtureSession.swift').read_text()
        roster = source.split('guard [', 1)[1].split('].contains(name)', 1)[0]
        self.assertEqual(set(runtime.PREFIXES), set(re.findall(r'"([^"]+)"', roster)))
        self.assertEqual(len(runtime.PREFIXES), len(set(runtime.PREFIXES)))
        self.assertEqual([row for row in runtime.FIXTURE_LOCATIONS if row[0] != '/private/tmp'],
                         [('/private/var/tmp', 'shadow-sync-m2.')])

    def test_runtime_complete_reports_require_observed_exact_cases(self):
        runtime = load('ci-runtime')
        self.assertEqual(runtime.canonical_output('fixture', ['one', 'two'],
            b'PASS fixture/two\nPASS fixture/one\n', complete=True), b'PASS two\nPASS one\n')
        for raw in (b'PASS fixture/one\n', b'PASS fixture/one\nPASS fixture/one\n',
                    b'PASS foreign/one\n', b'PASS fixture/unknown\n'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                runtime.canonical_output('fixture', ['one', 'two'], raw, complete=True)

    def test_incomplete_runtime_attempt_never_fills_missing_cases(self):
        runtime = load('ci-runtime')
        self.assertEqual(runtime.canonical_output('fixture', ['one', 'two'],
            b'PASS fixture/one\n', complete=False), b'PASS one\n')

    def test_runtime_environment_excludes_host_flags_and_user_git(self):
        runtime = load('ci-runtime')
        root = Path('/fixture/work')
        with patch.dict(os.environ, {'PRIVATE_HOST_VALUE': 'private',
                'SHADOW_SYNC_TEST_RETENTION_CLEANUP_COSTS': '1', 'GIT_CONFIG_GLOBAL': '/fixture/foreign'}):
            env = runtime.fixture_environment('m6', root, 'a' * 32, Path('/fixture/python'),
                Path('/fixture/build'), Path('/fixture/framework'), Path('/fixture/policy.json'))
        self.assertNotIn('PRIVATE_HOST_VALUE', env)
        self.assertNotIn('SHADOW_SYNC_TEST_RETENTION_CLEANUP_COSTS', env)
        self.assertEqual(env['HOME'], '/fixture/work/home')
        self.assertEqual(env['GIT_CONFIG_GLOBAL'], '/dev/null')
        self.assertEqual(env['GIT_CONFIG_SYSTEM'], '/dev/null')
        self.assertEqual(env['GIT_CONFIG_NOSYSTEM'], '1')

    def test_runtime_isolation_keeps_network_exec_and_foreign_namespace_denials(self):
        runtime = load('ci-runtime')
        nonce = 'c' * 32
        profile = runtime.profile(Path('/private/tmp/fixture'), nonce, '/fixture/tests', '/fixture/app', '/fixture/python')
        self.assertIn('(deny network*)', profile)
        self.assertIn('(deny process-exec)', profile)
        for parent, prefix in runtime.FIXTURE_LOCATIONS:
            escaped = prefix.replace('.', '[.]')
            self.assertIn('^' + parent + '/' + escaped + nonce + '[.]', profile)
        grants = [line for line in profile.splitlines() if line.startswith('(allow network')]
        self.assertEqual(len(grants), 2)
        self.assertTrue(all('/(host[.]sock|agent[.]sock)$' in line and nonce in line for line in grants))

    def test_policy_pin_staging_is_exact_and_never_overwrites(self):
        runtime = load('ci-runtime')
        with tempfile.TemporaryDirectory(prefix='shadow-sync-ci-resource-') as name:
            root = Path(name).resolve()
            target = runtime.stage_policy_source(root)
            self.assertEqual(target.read_bytes(), (ROOT / 'Resources/policy-runtime-source.json').read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): runtime.stage_policy_source(root)

    def test_partial_build_is_refused_before_toolchain_or_execution(self):
        build = load('ci-build')
        with tempfile.TemporaryDirectory(prefix='shadow-sync-ci-partial-', dir='/private/tmp') as name:
            root = Path(name)
            with patch.object(build, 'toolchain') as toolchain, self.assertRaises(ValueError):
                build.prepare(root, {}, 'runtime-safety')
            toolchain.assert_not_called()

    def test_unqualified_platform_refuses_before_build_commands(self):
        build = load('ci-build')
        with patch.object(build.platform, 'system', return_value='Linux'), patch.object(build, 'run') as run:
            with self.assertRaises(ValueError): build.toolchain()
            run.assert_not_called()

    def test_artifacts_keep_exact_attempt_and_unit_directories(self):
        host = load('ci-host')
        plan = {'run_attempt': '2', 'units': [{'id': 'quality-0'}, {'id': 'quality-full'}]}
        with tempfile.TemporaryDirectory(prefix='shadow-sync-ci-artifacts-') as name:
            root = Path(name).resolve()
            for unit in plan['units']:
                (root / ('coverage-' + unit['id'] + '-attempt-2')).mkdir()
            host.normalize_artifact_directories(root, plan)
            self.assertEqual(set(os.listdir(root)), {'quality-0', 'quality-full'})

    def test_missing_extra_stale_and_linked_artifact_directories_refuse(self):
        host = load('ci-host')
        plan = {'run_attempt': '2', 'units': [{'id': 'quality-0'}]}
        for mode in ('missing', 'extra', 'stale', 'linked'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='shadow-sync-ci-artifacts-') as name:
                root = Path(name).resolve()
                target = root / 'coverage-quality-0-attempt-2'
                if mode == 'linked': target.symlink_to(root, target_is_directory=True)
                elif mode == 'stale': (root / 'coverage-quality-0-attempt-1').mkdir()
                elif mode == 'extra':
                    target.mkdir(); (root / 'unexpected').mkdir()
                with self.assertRaises((host.ci.InvalidEvidence, OSError)):
                    host.normalize_artifact_directories(root, plan)

    def test_workflow_has_no_omission_or_privileged_source_execution(self):
        text = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('permissions:\n  contents: read\n', text)
        self.assertNotRegex(text, r'(?m)^\s*(paths|paths-ignore|pull_request_target|secrets):')
        self.assertNotIn('self-hosted', text)
        self.assertNotIn('write', text)
        self.assertIn('  schedule:', text)
        for action in re.findall(r'uses: ([^\s#]+)', text):
            self.assertRegex(action, r'^actions/[a-z-]+@[a-f0-9]{40}$')
        self.assertIn('ci-required:\n    if: always()', text)
        self.assertIn('merge-multiple: false', text)
        self.assertIn('pattern: coverage-*-attempt-${{ github.run_attempt }}', text)
        self.assertEqual(text.count('fail-fast: false'), 5)
        self.assertEqual(text.count('retention-days: 14'), 10)
        jobs = set(load('ci-shards').coverage.JOBS)
        for job in jobs:
            self.assertIn('  ' + job + ':\n', text)
        self.assertIn('needs: [plan, quality, compile-package, runtime-safety, native-and-lifecycle, package-contract]', text)
