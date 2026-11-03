"""Disposable evidence fixtures exercise false-green and stale-evidence failures."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ci_results', ROOT / 'scripts/verify-ci-results.py')
ci = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(ci)


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


class CIResultsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shadow-sync-ci-evidence-')
        self.root = Path(self.temporary.name)
        self.revision = 'a' * 40
        self.run_id = '12345'
        self.run_attempt = '1'
        self.manifest = {'schema': 'shadow-sync-ci-coverage/v1', 'jobs': {}, 'suites': {}}
        for job, kind in ci.JOBS.items():
            self.manifest['jobs'][job] = [job + '-suite']
            self.manifest['suites'][job + '-suite'] = {'kind': kind, 'cases': [job + '-case']}
        self.manifest_bytes = encode(self.manifest)
        self.needs = {job: {'result': 'success', 'outputs': {}} for job in ci.JOBS}
        self.receipts = {}
        for name, suite in self.manifest['suites'].items():
            log = ('PASS ' + suite['cases'][0] + '\n').encode()
            (self.root / (name + '.log')).write_bytes(log)
            self.receipts[name] = {'schema': 'shadow-sync-ci-suite-result/v1', 'suite': name,
                'kind': suite['kind'], 'revision': self.revision, 'run_id': self.run_id, 'run_attempt': self.run_attempt,
                'manifest_sha256': hashlib.sha256(self.manifest_bytes).hexdigest(),
                'status': 'complete', 'exit_code': 0, 'expected_cases': suite['cases'],
                'passed_cases': suite['cases'], 'failed_cases': [], 'skipped_cases': [],
                'cleanup_complete': True, 'command_sha256': 'b' * 64,
                'log_sha256': hashlib.sha256(log).hexdigest()}
        self.save()

    def tearDown(self):
        self.temporary.cleanup()

    def save(self):
        for name, receipt in self.receipts.items():
            (self.root / (name + '.json')).write_bytes(encode(receipt))

    def verify(self):
        return ci.verify(self.manifest_bytes, encode(self.needs), self.root,
                         revision=self.revision, run_id=self.run_id, run_attempt=self.run_attempt)

    def test_complete_exact_run_and_rosters_pass(self):
        result = self.verify()
        self.assertEqual((result['jobs'], result['suites'], result['cases']), (5, 5, 5))

    def test_existing_uppercase_descriptive_and_timed_case_labels_pass(self):
        name = 'runtime-safety-suite'; cases = ['DM2-T01 identity-authority', 'DM2-T05 Body 1 hooks']
        self.manifest['suites'][name]['cases'] = cases
        self.manifest_bytes = encode(self.manifest)
        for receipt in self.receipts.values():
            receipt['manifest_sha256'] = hashlib.sha256(self.manifest_bytes).hexdigest()
        self.receipts[name]['expected_cases'] = cases
        self.receipts[name]['passed_cases'] = cases
        log = b'PASS DM2-T01 identity-authority [123 ms]\nPASS DM2-T05 Body 1 hooks [0 ms]\n'
        (self.root / (name + '.log')).write_bytes(log)
        self.receipts[name]['log_sha256'] = hashlib.sha256(log).hexdigest(); self.save()
        self.assertEqual(self.verify()['cases'], 6)

    def test_malformed_timing_and_unexpected_whitespace_do_not_hide_missing_cases(self):
        name = 'runtime-safety-suite'
        for suffix in (' [nan ms]', ' [-1 ms]', ' [1.2 ms]', ' ', '\t', ' [1 ms] trailing'):
            log = ('PASS runtime-safety-case' + suffix + '\n').encode()
            (self.root / (name + '.log')).write_bytes(log)
            self.receipts[name]['log_sha256'] = hashlib.sha256(log).hexdigest(); self.save()
            with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_missing_and_extra_jobs_refuse(self):
        saved = copy.deepcopy(self.needs)
        for name in ci.JOBS:
            self.needs = copy.deepcopy(saved); del self.needs[name]
            with self.subTest(name=name), self.assertRaises(ci.InvalidEvidence): self.verify()
        self.needs = saved; self.needs['unknown'] = {'result': 'success', 'outputs': {}}
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_skipped_failed_cancelled_and_incomplete_jobs_refuse(self):
        for status in ('skipped', 'failure', 'cancelled', 'in_progress', None):
            self.needs['runtime-safety']['result'] = status
            with self.subTest(status=status), self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_missing_receipt_or_log_refuses(self):
        for suffix in ('.json', '.log'):
            path = self.root / ('runtime-safety-suite' + suffix)
            data = path.read_bytes(); path.unlink()
            with self.assertRaises(ci.InvalidEvidence): self.verify()
            path.write_bytes(data)

    def test_stale_revision_run_manifest_or_identity_refuses(self):
        name = 'runtime-safety-suite'; original = copy.deepcopy(self.receipts[name])
        for key, value in [('revision', 'c' * 40), ('run_id', '12344'), ('run_attempt', '2'), ('manifest_sha256', 'd' * 64),
                           ('suite', 'different'), ('kind', 'compile'), ('schema', 'future/v2')]:
            self.receipts[name] = dict(original); self.receipts[name][key] = value; self.save()
            with self.subTest(key=key), self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_zero_missing_duplicate_or_extra_executed_cases_refuse(self):
        name = 'runtime-safety-suite'; cases = self.receipts[name]['passed_cases']
        for value in ([], cases + cases, cases + ['extra-case'], ['different-case']):
            self.receipts[name]['passed_cases'] = value; self.save()
            with self.subTest(value=value), self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_failed_skipped_incomplete_or_unclean_receipt_refuses(self):
        name = 'runtime-safety-suite'; original = copy.deepcopy(self.receipts[name])
        for key, value in [('failed_cases', ['failed-case']), ('skipped_cases', ['skipped-case']),
                           ('status', 'running'), ('cleanup_complete', False), ('cleanup_complete', 1),
                           ('exit_code', 1), ('exit_code', False), ('exit_code', '0')]:
            self.receipts[name] = dict(original); self.receipts[name][key] = value; self.save()
            with self.subTest(key=key, value=value), self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_compile_only_or_tampered_log_cannot_satisfy_runtime(self):
        name = 'runtime-safety-suite'
        for log in (b'Build complete!\n', b'PASS different-case\n', b'PASS runtime-safety-case\nSKIP hidden-case\n',
                    b'PASS runtime-safety-case\nPASS runtime-safety-case\n'):
            (self.root / (name + '.log')).write_bytes(log)
            self.receipts[name]['log_sha256'] = hashlib.sha256(log).hexdigest(); self.save()
            with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_log_hash_mismatch_refuses(self):
        (self.root / 'runtime-safety-suite.log').write_bytes(b'changed\n')
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_unknown_files_and_symlinks_and_hardlinks_refuse(self):
        extra = self.root / 'extra.json'; extra.write_bytes(b'{}')
        with self.assertRaises(ci.InvalidEvidence): self.verify()
        extra.unlink()
        path = self.root / 'runtime-safety-suite.json'; data = path.read_bytes(); path.unlink()
        path.symlink_to(self.root / 'quality-suite.json')
        with self.assertRaises(OSError): self.verify()
        path.unlink(); os.link(self.root / 'quality-suite.json', path)
        with self.assertRaises(ci.InvalidEvidence): self.verify()
        path.unlink(); path.write_bytes(data)
        self.verify()

    def test_manifest_requires_all_job_kinds_and_nonempty_unique_rosters(self):
        original = copy.deepcopy(self.manifest)
        cases = []
        for field in ('jobs', 'suites'):
            value = copy.deepcopy(original); value[field] = {}; cases.append(value)
        for key, value in [('cases', []), ('cases', ['same', 'same']), ('kind', 'compile')]:
            changed = copy.deepcopy(original); changed['suites']['runtime-safety-suite'][key] = value; cases.append(changed)
        for value in cases:
            with self.assertRaises(ci.InvalidEvidence): ci.validate_manifest(encode(value))

    def test_duplicate_json_fields_and_nonfinite_values_refuse(self):
        for data in (b'{"jobs":{},"jobs":{}}', b'NaN', b'Infinity', b'{'):
            with self.assertRaises(ci.InvalidEvidence): ci.decode(data)

    def test_unknown_receipt_fields_refuse(self):
        self.receipts['runtime-safety-suite']['allowed_failure'] = True; self.save()
        with self.assertRaises(ci.InvalidEvidence): self.verify()

    def test_bad_revision_or_run_id_refuse(self):
        for revision, run_id in [('0' * 40, '1'), ('short', '1'), ('a' * 40, '0'), ('a' * 40, 'run-1')]:
            with self.assertRaises(ci.InvalidEvidence):
                ci.verify(self.manifest_bytes, encode(self.needs), self.root, revision=revision, run_id=run_id, run_attempt=self.run_attempt)


if __name__ == '__main__': unittest.main()
