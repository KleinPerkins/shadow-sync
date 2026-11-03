"""Fixture-only failures in the static shard coverage gate."""
import copy
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('shards', ROOT / 'scripts/ci-shards.py')
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class ShardGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-shard-contract-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.contract = {'schema': 'shadow-sync-test-shards/v1', 'coverage': {
            'schema': 'shadow-sync-ci-coverage/v1', 'jobs': {}, 'suites': {}},
            'commands': {}, 'shards': {}}
        for job, kind in ci.coverage.JOBS.items():
            names = [job + '-' + str(i) for i in range(12)]
            self.contract['coverage']['jobs'][job] = names
            self.contract['shards'][job] = 2
            for name in names:
                self.contract['coverage']['suites'][name] = {'kind': kind, 'cases': [name + '-case']}
                self.contract['commands'][name] = {'argv': ['fixture-runner', name], 'timeout_seconds': 60}
        self.head = ci.encode(self.contract)
        self.base = self.head
        self.identity = dict(revision='a' * 40, run_id='123', run_attempt='1', source_sha256='b' * 64)
        self.needs = {j: {'result': 'success', 'outputs': {}} for j in ('plan', *ci.coverage.JOBS)}
        self.artifacts = self.root / 'artifacts'
        self.populate()

    def populate(self):
        self.plan = ci.make_plan(self.head, self.base, **self.identity)
        self.artifacts.mkdir()
        for unit in self.plan['units']:
            directory = self.artifacts / unit['id']
            directory.mkdir()
            receipt = {'schema': 'shadow-sync-ci-shard-result/v1',
                       'plan_sha256': ci.digest(ci.encode(self.plan)), 'unit': unit,
                       **self.identity, 'status': 'complete', 'seconds': 1,
                       'suites': unit['suites']}
            (directory / 'unit.json').write_bytes(ci.encode(receipt))
            for name in unit['suites']:
                expected = self.contract['coverage']['suites'][name]
                log = ('PASS ' + expected['cases'][0] + '\n').encode()
                (directory / (name + '.log')).write_bytes(log)
                suite = {'schema': 'shadow-sync-ci-sharded-suite-result/v1', 'suite': name,
                         'unit_id': unit['id'], 'plan_sha256': ci.digest(ci.encode(self.plan)),
                         'source_sha256': self.identity['source_sha256'],
                         'kind': expected['kind'], 'revision': self.identity['revision'],
                         'run_id': '123', 'run_attempt': '1',
                         'manifest_sha256': ci.digest(ci.encode(self.contract['coverage'])),
                         'status': 'complete', 'exit_code': 0, 'expected_cases': expected['cases'],
                         'passed_cases': expected['cases'], 'failed_cases': [], 'skipped_cases': [],
                         'cleanup_complete': True,
                         'command_sha256': ci.digest(ci.encode(self.contract['commands'][name])),
                         'log_sha256': ci.digest(log)}
                (directory / (name + '.json')).write_bytes(ci.encode(suite))

    def verify(self):
        return ci.aggregate(self.head, self.base, ci.encode(self.plan), ci.encode(self.needs),
                            self.artifacts, **self.identity)

    def mutate(self, path, field, value):
        old = path.read_bytes()
        obj = ci.coverage.decode(old)
        obj[field] = value
        path.write_bytes(ci.encode(obj))
        return old

    def test_all_units_exact_complete_coverage(self):
        result = self.verify()
        self.assertEqual((result['units'], result['unique_suites'], result['unique_cases']), (10, 60, 60))

    def test_stable_disjoint_partitions_preserve_registered_order(self):
        suites = [f'suite-{i}' for i in range(400)]
        for count in range(1, 9):
            units = [ci.partition(suites, i, count) for i in range(count)]
            self.assertEqual(sorted(sum(units, [])), sorted(suites))
            self.assertTrue(all(units))
            self.assertEqual(len(sum(units, [])), len(set(sum(units, []))))
            for i, unit in enumerate(units):
                self.assertEqual(unit, ci.partition(suites, i, count))
                self.assertEqual([suites.index(x) for x in unit], sorted(suites.index(x) for x in unit))
        self.assertEqual(ci.partition(['suite-0', 'suite-1', 'suite-2'], 0, 2), ['suite-0', 'suite-1', 'suite-2'])

    def test_initial_and_changed_registration_require_independent_full_runs(self):
        for base in (None, self.head + b'\n'):
            plan = ci.make_plan(self.head, base, **self.identity)
            self.assertEqual(plan['mode'], 'transition')
            self.assertEqual(len(plan['units']), 15)
            for unit in plan['units']:
                if unit['mode'] == 'full':
                    self.assertEqual(unit['suites'], self.contract['coverage']['jobs'][unit['job']])
            with self.assertRaises(ci.InvalidEvidence):
                ci.aggregate(self.head, base, ci.encode(plan), ci.encode(self.needs),
                             self.artifacts, **self.identity)

    def test_complete_transition_evidence_passes(self):
        self.base = None
        self.artifacts = self.root / 'transition-artifacts'
        self.populate()
        self.assertEqual(self.verify()['units'], 15)
        (self.artifacts / 'runtime-safety-full' / 'unit.json').unlink()
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_transition_full_run_cannot_copy_shard_suite_evidence(self):
        self.base = None
        self.artifacts = self.root / 'transition-copy-artifacts'
        self.populate()
        for unit in self.plan['units']:
            if unit['mode'] != 'full':
                continue
            for name in unit['suites']:
                shard = next(u for u in self.plan['units']
                             if u['job'] == unit['job'] and u['mode'] == 'shard'
                             and name in u['suites'])
                for suffix in ('.json', '.log'):
                    (self.artifacts / unit['id'] / (name + suffix)).write_bytes(
                        (self.artifacts / shard['id'] / (name + suffix)).read_bytes())
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_mutation_of_previously_read_artifact_refuses(self):
        first = self.plan['units'][0]
        earlier = self.artifacts / first['id'] / (first['suites'][0] + '.log')
        last = self.plan['units'][-1]['suites'][-1] + '.log'
        read = ci.coverage.read_regular
        def mutate_after_read(path, *args, **kwargs):
            result = read(path, *args, **kwargs)
            if str(path) == last:
                earlier.write_bytes(b'changed after validation\n')
            return result
        with mock.patch.object(ci.coverage, 'read_regular', side_effect=mutate_after_read):
            with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_source_change_after_earlier_file_is_hashed_refuses(self):
        root = self.root / 'source-race'; root.mkdir()
        earlier = root / 'a'; earlier.write_bytes(b'first'); (root / 'z').write_bytes(b'last')
        digest = ci.digest
        def mutate_after_read(data):
            if data == b'last': earlier.write_bytes(b'other')
            return digest(data)
        with mock.patch.object(ci, 'digest', side_effect=mutate_after_read):
            with self.assertRaises(ci.InvalidEvidence): ci.source_digest(root, ['a', 'z'])

    def test_source_ancestor_replacement_during_hashing_refuses(self):
        root = self.root / 'ancestor-race'; root.mkdir(); ancestor = root / 'parent'; ancestor.mkdir()
        (ancestor / 'a').write_bytes(b'first')
        digest = ci.digest
        def replace_ancestor(data):
            if data == b'first':
                ancestor.rename(root / 'old-parent'); ancestor.mkdir()
                (ancestor / 'a').write_bytes(b'first')
            return digest(data)
        with mock.patch.object(ci, 'digest', side_effect=replace_ancestor):
            with self.assertRaises(ci.InvalidEvidence): ci.source_digest(root, ['parent/a'])

    def test_forged_mode_and_matrix_refuse(self):
        for key, value in [('mode', 'transition'), ('units', self.plan['units'][:-1]),
                           ('units', self.plan['units'] + self.plan['units'][:1])]:
            old = self.plan[key]
            self.plan[key] = value
            with self.subTest(key=key), self.assertRaises(ci.InvalidEvidence): self.verify()
            self.plan[key] = old

    def test_missing_extra_and_symlink_unit_refuse(self):
        unit = self.artifacts / self.plan['units'][0]['id']
        moved = self.root / 'retained-unit'
        unit.rename(moved)
        with self.assertRaises(ci.InvalidEvidence): self.verify()
        unit.symlink_to(moved, target_is_directory=True)
        with self.assertRaises((ci.InvalidEvidence, OSError)): self.verify()
        unit.unlink()
        moved.rename(unit)
        extra = self.artifacts / 'extra-unit'; extra.mkdir()
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_stale_source_revision_attempt_plan_and_index_refuse(self):
        unit = self.plan['units'][0]
        path = self.artifacts / unit['id'] / 'unit.json'
        for field, value in [('source_sha256', 'c' * 64), ('revision', 'd' * 40),
                             ('run_id', '122'), ('run_attempt', '2'), ('plan_sha256', 'e' * 64),
                             ('unit', {**unit, 'index': 99}), ('status', 'running'),
                             ('suites', list(reversed(unit['suites']))), ('seconds', -1),
                             ('seconds', True)]:
            old = self.mutate(path, field, value)
            with self.subTest(field=field), self.assertRaises(ci.InvalidEvidence): self.verify()
            path.write_bytes(old)

    def test_failed_skipped_cancelled_missing_or_extra_job_refuse(self):
        original = copy.deepcopy(self.needs)
        for status in ('failure', 'cancelled', 'skipped', None):
            self.needs['runtime-safety']['result'] = status
            with self.assertRaises(ci.InvalidEvidence): self.verify()
        self.needs = copy.deepcopy(original); del self.needs['plan']
        with self.assertRaises(ci.InvalidEvidence): self.verify()
        self.needs = original; self.needs['unknown'] = {'result': 'success', 'outputs': {}}
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_wrong_command_cleanup_kind_roster_and_tampered_logs_refuse(self):
        unit = next(u for u in self.plan['units'] if u['job'] == 'runtime-safety')
        name = unit['suites'][0]; directory = self.artifacts / unit['id']; path = directory / (name + '.json')
        for field, value in [('command_sha256', 'c' * 64), ('cleanup_complete', False),
                             ('unit_id', 'runtime-safety-full'), ('plan_sha256', 'e' * 64),
                             ('source_sha256', 'f' * 64),
                             ('schema', 'shadow-sync-ci-suite-result/v1'),
                             ('kind', 'compile'), ('passed_cases', []), ('failed_cases', ['case']),
                             ('skipped_cases', ['case']), ('exit_code', False)]:
            old = self.mutate(path, field, value)
            with self.subTest(field=field), self.assertRaises(ci.InvalidEvidence): self.verify()
            path.write_bytes(old)
        logpath = directory / (name + '.log')
        for log in (b'Build complete\n', b'PASS extra\n',
                    ('PASS '+name+'-case\nPASS '+name+'-case\n').encode(),
                    ('PASS '+name+'-case\nSKIP hidden\n').encode()):
            logpath.write_bytes(log); self.mutate(path, 'log_sha256', ci.digest(log))
            with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_closed_registration_and_empty_partition_refuse(self):
        for mutate in (lambda x: x.update(extra=True),
                       lambda x: x['shards'].update(quality=True),
                       lambda x: x['shards'].update(quality=9),
                       lambda x: x['commands'].pop('quality-0'),
                       lambda x: x['commands']['quality-0'].update(argv=['bad\ncommand']),
                       lambda x: x['commands']['quality-0'].update(timeout_seconds=False)):
            bad = copy.deepcopy(self.contract); mutate(bad)
            with self.assertRaises(ci.InvalidEvidence): ci.registration(ci.encode(bad))
        bad = copy.deepcopy(self.contract)
        names = [n for n in bad['coverage']['jobs']['quality'] if n in ci.partition(
            bad['coverage']['jobs']['quality'], 0, 2)]
        for n in set(bad['coverage']['jobs']['quality']) - set(names):
            del bad['commands'][n]; del bad['coverage']['suites'][n]
        bad['coverage']['jobs']['quality'] = names
        with self.assertRaises(ci.InvalidEvidence): ci.registration(ci.encode(bad))

    def test_source_digest_binds_path_bytes_mode_and_empty_files(self):
        root = self.root / 'source'; root.mkdir(); a = root/'a'; a.write_bytes(b'alpha'); (root/'empty').touch()
        initial = ci.source_digest(root, ['a', 'empty'])
        self.assertEqual(initial, ci.source_digest(root, ['empty', 'a']))
        a.write_bytes(b'beta'); self.assertNotEqual(initial, ci.source_digest(root, ['a', 'empty']))
        a.write_bytes(b'alpha'); a.chmod(0o700)
        self.assertNotEqual(initial, ci.source_digest(root, ['a', 'empty']))
        for paths in ([], ['a', 'a'], ['../escape'], ['/absolute'], ['./a'], ['a//x']):
            with self.assertRaises(ci.InvalidEvidence): ci.source_digest(root, paths)

    def test_source_links_hardlinks_special_files_and_ancestor_links_refuse(self):
        root = self.root / 'source'; root.mkdir(); a = root/'a'; a.write_bytes(b'alpha')
        (root/'link').symlink_to(a)
        with self.assertRaises((ci.InvalidEvidence, OSError)): ci.source_digest(root, ['link'])
        os.link(a, root/'hard')
        with self.assertRaises(ci.InvalidEvidence): ci.source_digest(root, ['hard'])
        (root/'hard').unlink(); os.mkfifo(root/'pipe')
        with self.assertRaises(ci.InvalidEvidence): ci.source_digest(root, ['pipe'])
        (root/'parent').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((ci.InvalidEvidence, OSError)): ci.source_digest(root, ['parent/source/a'])


if __name__ == '__main__':
    unittest.main()
