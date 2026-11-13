"""Required focused custody coverage remains independent of the full M6 gate."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def registered():
    return load('ci-shards').registration((ROOT / 'config/ci-suites.json').read_bytes())


class CustodyCaptureSuiteTests(unittest.TestCase):
    def test_capture_and_full_m6_are_required_in_distinct_default_shards(self):
        value = registered(); ci = load('ci-shards')
        inventory = load('runtime-suite-inventory').inspect(ROOT)
        self.assertEqual(value['coverage']['jobs']['runtime-safety'],
                         ['runtime-' + row['id'] for row in inventory['suites']])
        for row in inventory['suites']:
            self.assertEqual(value['coverage']['suites']['runtime-' + row['id']]['cases'], row['cases'])
        names = ('runtime-m6', 'runtime-m6-custody-capture', 'runtime-m6-staged-reconciliation')
        self.assertEqual(value['shards']['runtime-safety'], 4)
        self.assertEqual([value['commands'][name]['timeout_seconds'] for name in names], [3600, 3600, 3600])
        plan = ci.make_plan(ci.encode(value), ci.encode(value), revision='a' * 40,
                            source_sha256='b' * 64, run_id='12', run_attempt='1')
        units = {name: [u['id'] for u in plan['units'] if name in u['suites']] for name in names}
        self.assertTrue(all(len(rows) == 1 for rows in units.values()))
        self.assertNotEqual(units[names[0]], units[names[1]])
        self.assertEqual(value['commands'][names[1]]['argv'],
            ['python3', '-I', '-B', 'scripts/ci-suite.py', 'runtime', '--suite', 'm6-custody-capture'])

    def test_aggregate_requires_full_m6_and_all_focused_cases(self):
        # Source-level evidence fixtures only. A focused PASS cannot replace full
        # M6, and full M6 cannot cover a missing/failed/skipped focused receipt.
        ci = load('ci-shards'); value = registered(); data = ci.encode(value)
        identity = dict(revision='a' * 40, source_sha256='b' * 64, run_id='12', run_attempt='1')
        plan = ci.make_plan(data, data, **identity)
        plan_hash = ci.digest(ci.encode(plan))
        needs = {j: {'result': 'success', 'outputs': {}} for j in ('plan', *ci.coverage.JOBS)}
        with tempfile.TemporaryDirectory(prefix='shadow-sync-focused-evidence-') as tmp:
            root = Path(tmp); receipts = {}
            for unit in plan['units']:
                directory = root / unit['id']; directory.mkdir()
                (directory / 'unit.json').write_bytes(ci.encode({
                    'schema': 'shadow-sync-ci-shard-result/v1', 'plan_sha256': plan_hash,
                    'unit': unit, **identity, 'status': 'complete', 'seconds': 1, 'suites': unit['suites']}))
                for name in unit['suites']:
                    expected = value['coverage']['suites'][name]
                    log = ''.join('PASS ' + case + '\n' for case in expected['cases']).encode()
                    (directory / (name + '.log')).write_bytes(log)
                    receipt = {'schema': 'shadow-sync-ci-sharded-suite-result/v1', 'suite': name,
                        'unit_id': unit['id'], 'plan_sha256': plan_hash, **identity,
                        'kind': expected['kind'], 'manifest_sha256': ci.digest(ci.encode(value['coverage'])),
                        'status': 'complete', 'exit_code': 0, 'expected_cases': expected['cases'],
                        'passed_cases': expected['cases'], 'failed_cases': [], 'skipped_cases': [],
                        'cleanup_complete': True, 'command_sha256': ci.digest(ci.encode(value['commands'][name])),
                        'log_sha256': ci.digest(log)}
                    path = directory / (name + '.json'); path.write_bytes(ci.encode(receipt))
                    receipts[name] = (path, receipt)
            def verify():
                return ci.aggregate(data, data, ci.encode(plan), ci.encode(needs), root, **identity)
            verify()
            for name in ('runtime-m6', 'runtime-m6-custody-capture', 'runtime-m6-staged-reconciliation'):
                path, receipt = receipts[name]; original = path.read_bytes()
                path.unlink()
                with self.subTest(name=name, defect='missing'), self.assertRaises(ci.InvalidEvidence): verify()
                path.write_bytes(original)
                missing_cases = (receipt['expected_cases'] if name != 'runtime-m6'
                                 else receipt['expected_cases'][:1])
                for missing in missing_cases:
                    kept = [case for case in receipt['passed_cases'] if case != missing]
                    path.write_bytes(ci.encode({**receipt, 'passed_cases': kept}))
                    with self.subTest(name=name, missing=missing), self.assertRaises(ci.InvalidEvidence): verify()
                    path.write_bytes(original)
                for field, replacement in (('passed_cases', receipt['passed_cases'][:-1]),
                        ('failed_cases', receipt['expected_cases'][:1]),
                        ('skipped_cases', receipt['expected_cases'][:1]), ('exit_code', 1)):
                    path.write_bytes(ci.encode({**receipt, field: replacement}))
                    with self.subTest(name=name, defect=field), self.assertRaises(ci.InvalidEvidence): verify()
                    path.write_bytes(original)
            verify()


if __name__ == '__main__':
    unittest.main()
