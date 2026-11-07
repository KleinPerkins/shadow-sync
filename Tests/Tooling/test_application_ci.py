"""Registration and trusted-base negatives for the actual application workflow."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


registration = load('ci-registration')
host = load('ci-host')


class ApplicationCIRegistrationTests(unittest.TestCase):
    def test_current_manifest_equals_complete_discovery(self):
        registration.verify()

    def test_all_current_runtime_and_native_cases_are_registered(self):
        value = registration.generate()
        for source, job, prefix in ((load('runtime-suite-inventory').inspect(ROOT)['suites'], 'runtime-safety', 'runtime-'),
                                    (load('run-native-appkit').catalog()[2], 'native-and-lifecycle', 'native-')):
            self.assertEqual(value['coverage']['jobs'][job], [prefix + row['id'] for row in source])
            for row in source:
                self.assertEqual(value['coverage']['suites'][prefix + row['id']]['cases'], row['cases'])
        self.assertEqual(len(value['coverage']['jobs']['runtime-safety']), 41)
        self.assertEqual(sum(len(value['coverage']['suites'][name]['cases'])
                             for name in value['coverage']['jobs']['runtime-safety']), 948)
        self.assertEqual(len(value['coverage']['jobs']['native-and-lifecycle']), 35)

    def test_missing_case_or_unregistered_command_refuses_current_manifest(self):
        value = registration.generate()
        with tempfile.TemporaryDirectory(prefix='shadow-sync-registration-') as directory:
            path = Path(directory) / 'registration.json'
            for defect in ('case', 'command'):
                changed = copy.deepcopy(value)
                name = changed['coverage']['jobs']['runtime-safety'][0]
                if defect == 'case': changed['coverage']['suites'][name]['cases'].pop()
                else: changed['commands'][name]['argv'] = ['true']
                path.write_bytes(registration.encoded(changed))
                with mock.patch.object(registration, 'PATH', path), self.assertRaises(ValueError):
                    registration.verify()

    def test_actual_partitions_are_nonempty_disjoint_and_complete(self):
        value = registration.generate(); ci = load('ci-shards')
        plan = ci.make_plan(ci.encode(value), None, revision='a' * 40, source_sha256='b' * 64,
                            run_id='12', run_attempt='1')
        for job, expected in value['coverage']['jobs'].items():
            partitions = [u for u in plan['units'] if u['job'] == job and u['mode'] == 'shard']
            self.assertTrue(all(u['suites'] for u in partitions))
            observed = [name for u in partitions for name in u['suites']]
            self.assertEqual(len(observed), len(set(observed)))
            self.assertEqual(set(observed), set(expected))
            full = [u for u in plan['units'] if u['job'] == job and u['mode'] == 'full']
            self.assertEqual([u['suites'] for u in full], [expected])
            self.assertTrue(all(u['runner'] == 'macos-26' and u['architecture'] == 'arm64' for u in partitions + full))


class PublisherFixtureTests(unittest.TestCase):
    def test_failed_fixture_compilation_retains_diagnostics_and_never_signs(self):
        build = load('ci-build')
        with tempfile.TemporaryDirectory(prefix='shadow-sync-publisher-build-') as directory:
            root = Path(directory).resolve()
            result = subprocess.CompletedProcess([], 1, b'compiler output', b'fixture compile failure')
            with mock.patch.object(build.subprocess, 'run', return_value=result), \
                    mock.patch.object(build, 'run') as sign, self.assertRaisesRegex(ValueError, 'publisher-build.log'):
                build.publisher_fixture(root)
            sign.assert_not_called()
            self.assertEqual((root / 'publisher-build.log').read_bytes(), b'compiler outputfixture compile failure')
            self.assertFalse((root / 'publisher-executable').exists())


class RuntimeOutputTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load('ci-runtime')

    def test_actual_guardian_prefix_maps_without_synthesized_passes(self):
        actual = b'PASS fixture/first\nMETRIC fixture=1\nPASS fixture/second\n'
        self.assertEqual(self.runtime.canonical_output('fixture', ['first', 'second'], actual, complete=True),
                         b'PASS first\nMETRIC fixture=1\nPASS second\n')

    def test_missing_or_empty_actual_output_cannot_complete(self):
        for value in (b'', b'PASS fixture/first\n'):
            with self.assertRaises(ValueError):
                self.runtime.canonical_output('fixture', ['first', 'second'], value, complete=True)

    def test_wrong_suite_unknown_case_and_duplicates_refuse(self):
        for value in (b'PASS foreign/first\n', b'PASS fixture/unknown\n',
                      b'PASS fixture/first\nPASS fixture/first\n'):
            with self.assertRaises(ValueError):
                self.runtime.canonical_output('fixture', ['first'], value, complete=True)

    def test_failed_partial_execution_preserves_only_observed_passes(self):
        self.assertEqual(self.runtime.canonical_output('fixture', ['first', 'second'],
            b'PASS fixture/first\nFAIL fixture/second\n', complete=False),
            b'PASS first\nFAIL fixture/second\n')


class ArtifactAttemptTests(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='shadow-sync-attempt-')
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name).resolve(), {'run_attempt': '2', 'units': [{'id': 'runtime-safety-0'}]}

    def test_only_exact_attempt_and_unit_is_accepted(self):
        root, plan = self.fixture()
        (root / 'coverage-runtime-safety-0-attempt-2').mkdir()
        host.normalize_artifact_directories(root, plan)
        self.assertEqual([p.name for p in root.iterdir()], ['runtime-safety-0'])

    def test_stale_or_duplicate_attempt_preserved_and_refused(self):
        root, plan = self.fixture()
        for name in ('coverage-runtime-safety-0-attempt-1', 'coverage-runtime-safety-0-attempt-2'):
            (root / name).mkdir()
        before = set(os.listdir(root))
        with self.assertRaises(host.ci.InvalidEvidence): host.normalize_artifact_directories(root, plan)
        self.assertEqual(set(os.listdir(root)), before)

    def test_linked_unit_directory_refused(self):
        root, plan = self.fixture()
        (root / 'coverage-runtime-safety-0-attempt-2').symlink_to(root, target_is_directory=True)
        with self.assertRaises(host.ci.InvalidEvidence): host.normalize_artifact_directories(root, plan)


class TrustedBaseRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shadow-sync-base-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.environment = dict(PATH=os.defpath, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
            GIT_CONFIG_SYSTEM='/dev/null', GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
            GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.git('init', '-q')
        (self.root / 'fixture').write_text('disposable\n')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['/usr/bin/git', '-C', str(self.root), *args], env=self.environment,
                                       stderr=subprocess.PIPE, timeout=15)

    def commit(self):
        self.git('add', '--all'); self.git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD').decode().strip()

    def test_absent_predecessor_is_initial_not_broken_base(self):
        with mock.patch.object(host, 'ROOT', self.root):
            self.assertIsNone(host.base_registration(self.git('rev-parse', 'HEAD').decode().strip()))
            with self.assertRaises(subprocess.CalledProcessError): host.base_registration('e' * 40)

    def test_exact_base_blob_is_used_despite_different_worktree(self):
        (self.root / 'config').mkdir(); path = self.root / 'config/ci-suites.json'
        data = registration.encoded(registration.generate()); path.write_bytes(data)
        revision = self.commit(); path.write_text('uncommitted drift')
        with mock.patch.object(host, 'ROOT', self.root):
            self.assertEqual(host.base_registration(revision), data)

    def test_malformed_base_never_falls_back_to_routine_or_initial(self):
        (self.root / 'config').mkdir(); (self.root / 'config/ci-suites.json').write_text('{}')
        revision = self.commit()
        with mock.patch.object(host, 'ROOT', self.root), self.assertRaises(host.ci.InvalidEvidence):
            host.base_registration(revision)

    def test_symlink_base_refused_without_following_target(self):
        (self.root / 'config').mkdir(); (self.root / 'config/ci-suites.json').symlink_to('../fixture')
        revision = self.commit()
        with mock.patch.object(host, 'ROOT', self.root), self.assertRaises(host.ci.InvalidEvidence):
            host.base_registration(revision)

    def test_zero_or_noncommit_base_refuses(self):
        with mock.patch.object(host, 'ROOT', self.root):
            for revision in ('0' * 40, 'main', '../fixture', ''):
                with self.subTest(revision=revision), self.assertRaises(host.ci.InvalidEvidence):
                    host.base_registration(revision)


if __name__ == '__main__':
    unittest.main()
