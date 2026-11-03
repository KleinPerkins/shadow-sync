"""Failure-path checks for native reports; no AppKit or host state is used."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_contract', ROOT / 'scripts/native-appkit-contract.py')
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode()


class NativeAppKitContractTests(unittest.TestCase):
    def setUp(self):
        self.value = native.contract((ROOT / 'Tests/Fixtures/native-appkit-contract.json').read_bytes())

    def report(self, name):
        p = next(p for p in self.value['probes'] if p['id'] == name)
        if name == 'm5-latency':
            return {'schema': p['schema'], 'trial': 1, 'rowCount': 100, 'durationSeconds': 60,
                    'eventIntervalMilliseconds': 25, 'expectedEventCount': 2400,
                    'renderedEventCount': 2400, 'firstSequence': 2, 'lastSequence': 2401,
                    'monotonic': True, 'noDroppedEvents': True, 'p95Milliseconds': 20.0,
                    'maximumMilliseconds': 20.0, 'samplesMilliseconds': [20.0] * 2400}
        value = {'schema': p['schema'], **{k: True for k in p['fields']}}
        if name == 'm5-ui':
            value['coreTests'] = list(native.CORE)
        return value

    def test_all_existing_boolean_and_core_assertions_have_distinct_ids(self):
        counts = {'m5-ui': 25, 'm5-practical-ui': 16, 'm5-status-item-guidance': 12,
                  'm5-confirmation-close': 14, 'm5-foreground': 56, 'm5-operation-contention': 1}
        actual = []
        for name, count in counts.items():
            result = native.validate_report(self.value, name, encoded(self.report(name)))
            self.assertEqual(len(result), count)
            actual += result
        self.assertEqual(len(actual), len(set(actual)))
        self.assertEqual(len(actual), 124)

    def test_each_required_boolean_rejects_false_integer_null_or_string(self):
        for p in self.value['probes']:
            for field, kind in p['fields'].items():
                if kind != 'Bool' or field in p['diagnostic_only']:
                    continue
                for bad in (False, 1, 0, None, 'true'):
                    value = self.report(p['id']); value[field] = bad
                    with self.subTest(probe=p['id'], field=field, value=bad), self.assertRaises(ValueError):
                        native.validate_report(self.value, p['id'], encoded(value),
                                               1 if p['id'] == 'm5-latency' else None)

    def test_existing_accessibility_diagnostic_is_bool_not_a_uat_pass(self):
        for diagnostic in (True, False):
            value = self.report('m5-ui'); value['accessibilitySemantics'] = diagnostic
            self.assertIn('m5-ui/accessibility-diagnostic-type',
                          native.validate_report(self.value, 'm5-ui', encoded(value)))
        for bad in (None, 0, 1, 'false'):
            value['accessibilitySemantics'] = bad
            with self.assertRaises(ValueError): native.validate_report(self.value, 'm5-ui', encoded(value))

    def test_core_case_order_missing_extra_and_duplicate_refuse(self):
        for names in (list(reversed(native.CORE)), list(native.CORE[:-1]),
                      list(native.CORE) + ['unregistered'], list(native.CORE) + [native.CORE[0]]):
            value = self.report('m5-ui'); value['coreTests'] = names
            with self.assertRaises(ValueError): native.validate_report(self.value, 'm5-ui', encoded(value))

    def test_wrong_schema_missing_unknown_and_duplicate_fields_refuse(self):
        for name in native.PROBES:
            original = self.report(name)
            for key in list(original):
                value = copy.deepcopy(original); del value[key]
                with self.assertRaises(ValueError):
                    native.validate_report(self.value, name, encoded(value), 1 if name == 'm5-latency' else None)
            for key, extra in (('schema', 'other'), ('unexpected', True)):
                value = copy.deepcopy(original); value[key] = extra
                with self.assertRaises(ValueError):
                    native.validate_report(self.value, name, encoded(value), 1 if name == 'm5-latency' else None)
            duplicate = encoded(original)[:-1] + b',"schema":"duplicate"}'
            with self.assertRaises(ValueError):
                native.validate_report(self.value, name, duplicate, 1 if name == 'm5-latency' else None)

    def test_latency_requires_all_three_separate_trials(self):
        for trial in (1, 2, 3):
            value = self.report('m5-latency'); value['trial'] = trial
            self.assertEqual(native.validate_report(self.value, 'm5-latency', encoded(value), trial),
                             [f'm5-latency-{trial}/complete-protocol'])
        for trial in (None, 0, 4, True, '1'):
            with self.assertRaises(ValueError): native.cases(self.value, 'm5-latency', trial)
        with self.assertRaises(ValueError):
            native.validate_report(self.value, 'm5-latency', encoded(self.report('m5-latency')), 2)

    def test_latency_rejects_changed_protocol_or_lost_events(self):
        original = self.report('m5-latency')
        for name in ('rowCount', 'durationSeconds', 'eventIntervalMilliseconds',
                     'expectedEventCount', 'renderedEventCount', 'firstSequence', 'lastSequence'):
            for bad in (original[name] + 1, float(original[name]), True, None):
                value = copy.deepcopy(original); value[name] = bad
                with self.subTest(field=name, bad=bad), self.assertRaises(ValueError):
                    native.validate_report(self.value, 'm5-latency', encoded(value), 1)

    def test_latency_recomputes_nearest_rank_p95_and_maximum(self):
        value = self.report('m5-latency')
        value['samplesMilliseconds'] = [10] * 2279 + [250] + [300] * 120
        value['p95Milliseconds'] = 250; value['maximumMilliseconds'] = 300
        self.assertEqual(len(native.validate_report(self.value, 'm5-latency', encoded(value), 1)), 1)
        for field in ('p95Milliseconds', 'maximumMilliseconds'):
            bad = copy.deepcopy(value); bad[field] -= .01
            with self.assertRaises(ValueError): native.validate_report(self.value, 'm5-latency', encoded(bad), 1)
        value['samplesMilliseconds'][2279] = 250.01; value['p95Milliseconds'] = 250.01
        with self.assertRaises(ValueError): native.validate_report(self.value, 'm5-latency', encoded(value), 1)

    def test_latency_rejects_invalid_samples_and_measurements(self):
        for bad in (-1, None, True, '20', math.nan, math.inf):
            for field in ('samplesMilliseconds', 'p95Milliseconds', 'maximumMilliseconds'):
                value = self.report('m5-latency')
                if field == 'samplesMilliseconds': value[field][0] = bad
                else: value[field] = bad
                with self.assertRaises(ValueError): native.validate_report(self.value, 'm5-latency', encoded(value), 1)
        for length in (0, 2399, 2401):
            value = self.report('m5-latency'); value['samplesMilliseconds'] = [20] * length
            with self.assertRaises(ValueError): native.validate_report(self.value, 'm5-latency', encoded(value), 1)

    def source(self):
        rows = ['#if SHADOW_SYNC_TESTING']
        for p in self.value['probes']:
            rows += ['private struct ' + p['declaration'] + ': Encodable {',
                     '    let schema = ' + json.dumps(p['schema'])]
            rows += ['    let ' + name + ': ' + kind for name, kind in p['fields'].items()]
            rows += ['}', '']
        return '\n'.join(rows) + '#endif\n'

    def test_source_inventory_rejects_new_missing_renamed_or_changed_fields(self):
        source = self.source()
        native.source_consistent(self.value, source)
        changes = [source.replace('    let exactCopySnapshots: Bool\n', ''),
                   source.replace('exactCopySnapshots', 'unregisteredCase'),
                   source.replace('    let exactCopySnapshots: Bool', '    let exactCopySnapshots: Int'),
                   source.replace('    let exactCopySnapshots: Bool', '    let exactCopySnapshots: Bool\n    let newCase: Bool'),
                   source.replace('private struct M5UIResponse', 'private struct M5NewResponse'),
                   source.replace('#endif', source.split('#if SHADOW_SYNC_TESTING\n')[1]),
                   source.replace('#if SHADOW_SYNC_TESTING\n', '')]
        for modified in changes:
            with self.assertRaises(ValueError): native.source_consistent(self.value, modified)

    def test_contract_rejects_missing_extra_duplicate_and_diagnostic_drift(self):
        for edit in ('missing', 'extra', 'duplicate', 'diagnostic', 'owner', 'core'):
            value = copy.deepcopy(self.value)
            if edit == 'missing': value['probes'].pop()
            elif edit == 'extra': value['unexpected'] = True
            elif edit == 'duplicate': value['probes'][-1] = value['probes'][0]
            elif edit == 'diagnostic': value['probes'][0]['diagnostic_only'].append('exactCopySnapshots')
            elif edit == 'owner': value['probes'][0]['owner'] = 'unknown'
            elif edit == 'core': value['core_tests'].pop()
            with self.assertRaises(ValueError): native.contract(encoded(value))

    def test_unknown_probe_and_nonlatency_trial_refuse(self):
        with self.assertRaises(ValueError): native.cases(self.value, 'unknown')
        with self.assertRaises(ValueError): native.cases(self.value, 'm5-ui', 1)

    def test_malformed_trailing_or_oversized_json_refuses(self):
        for data in (b'', b'{}{}', b'{', b'\xff', b' ' * (native.MAX_JSON + 1)):
            with self.assertRaises((ValueError, UnicodeError)): native.decode(data)

    def test_read_regular_rejects_links_empty_and_large_files(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-native-contract-') as directory:
            root = Path(directory); file = root / 'report.json'; file.write_bytes(b'{}')
            self.assertEqual(native.read_regular(file), b'{}')
            link = root / 'link'; link.symlink_to(file)
            with self.assertRaises((ValueError, OSError)): native.read_regular(link)
            hardlink = root / 'hardlink'; hardlink.hardlink_to(file)
            with self.assertRaises(ValueError): native.read_regular(file)
            hardlink.unlink()
            for data in (b'', b' ' * (native.MAX_JSON + 1)):
                file.write_bytes(data)
                with self.assertRaises(ValueError): native.read_regular(file)
