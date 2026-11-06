"""Isolated native suite coverage must fail closed on incomplete execution."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_ui_suites', ROOT / 'scripts/native-ui-suites.py')
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode()


class NativeUISuiteTests(unittest.TestCase):
    def setUp(self):
        self.old = native.legacy.contract((ROOT / 'Tests/Fixtures/native-appkit-contract.json').read_bytes())
        self.manifest = native.contract((ROOT / 'Tests/Fixtures/native-ui-suites.json').read_bytes(), self.old)
        self.reports = [{'schema': 'shadow-sync-native-ui-suite-result/v1', 'suite': row['id'],
                         'checks': {k: True for k in row['checks']}, 'coreTests': row['core_tests']}
                        for row in self.manifest['suites']]

    def test_complete_execution_preserves_legacy_and_lifecycle_coverage(self):
        value = native.aggregate(self.manifest, self.old, [encoded(x) for x in self.reports])
        self.assertEqual(len(value['cases']), 50)
        self.assertEqual(len(set(value['cases'])), 50)
        self.assertEqual(len(value['legacy_cases']), 27)
        self.assertEqual(value['legacy_report']['coreTests'], list(native.legacy.CORE))
        for case in native.LIFECYCLE:
            self.assertTrue(any(x.endswith('/' + case) for x in value['cases']))

    def test_missing_duplicate_unknown_and_extra_suite_refuse(self):
        unknown = copy.deepcopy(self.reports[0]); unknown['suite'] = 'unknown'
        for rows in ([], self.reports[:-1], self.reports + [self.reports[0]],
                     self.reports[1:] + [self.reports[1]], self.reports[1:] + [unknown]):
            with self.subTest(rows=len(rows)), self.assertRaises(ValueError):
                native.aggregate(self.manifest, self.old, [encoded(x) for x in rows])

    def test_each_required_check_rejects_false_and_wrong_types(self):
        for row, original in zip(self.manifest['suites'], self.reports):
            for name in row['checks']:
                for bad in [None, 0, 1, 'true'] + ([] if name in row['diagnostic_only'] else [False]):
                    item = copy.deepcopy(original); item['checks'][name] = bad
                    with self.subTest(suite=row['id'], check=name, value=bad), self.assertRaises(ValueError):
                        native.report(self.manifest, row['id'], encoded(item))

    def test_only_existing_accessibility_fields_remain_diagnostic(self):
        for item in self.reports:
            row = next(row for row in self.manifest['suites'] if row['id'] == item['suite'])
            for key in row['diagnostic_only']: item['checks'][key] = False
        value = native.aggregate(self.manifest, self.old, [encoded(x) for x in self.reports])
        self.assertIs(value['legacy_report']['accessibilitySemantics'], False)
        self.assertTrue(all(result for key, result in value['legacy_report'].items()
                            if key not in ('schema', 'coreTests', 'accessibilitySemantics')))

    def test_missing_extra_and_duplicate_response_keys_refuse(self):
        for original in self.reports:
            for key in original:
                item = copy.deepcopy(original); del item[key]
                with self.assertRaises(ValueError): native.report(self.manifest, original['suite'], encoded(item))
            item = copy.deepcopy(original); item['unknown'] = True
            with self.assertRaises(ValueError): native.report(self.manifest, original['suite'], encoded(item))
            duplicate = encoded(original)[:-1] + b',"suite":"duplicate"}'
            with self.assertRaises(ValueError): native.report(self.manifest, original['suite'], duplicate)

    def test_check_roster_missing_extra_and_wrong_schema_refuse(self):
        original = next(x for x in self.reports if x['checks'])
        for key in original['checks']:
            item = copy.deepcopy(original); del item['checks'][key]
            with self.assertRaises(ValueError): native.report(self.manifest, original['suite'], encoded(item))
        for change in ('extra', 'schema'):
            item = copy.deepcopy(original)
            if change == 'extra': item['checks']['extra'] = True
            else: item['schema'] = 'other'
            with self.assertRaises(ValueError): native.report(self.manifest, original['suite'], encoded(item))

    def test_core_cases_must_execute_once_in_original_order(self):
        original = next(x for x in self.reports if x['coreTests'])
        for cases in ([], original['coreTests'][:-1], list(reversed(original['coreTests'])),
                      original['coreTests'] + [original['coreTests'][0]]):
            item = copy.deepcopy(original); item['coreTests'] = cases
            with self.assertRaises(ValueError): native.report(self.manifest, original['suite'], encoded(item))

    def test_compiled_discovery_requires_exact_manifest(self):
        native.inventory(self.manifest, encoded(self.manifest))
        for key in self.manifest:
            item = copy.deepcopy(self.manifest); del item[key]
            with self.assertRaises(ValueError): native.inventory(self.manifest, encoded(item))
        item = copy.deepcopy(self.manifest); item['suites'].reverse()
        with self.assertRaises(ValueError): native.inventory(self.manifest, encoded(item))

    def test_manifest_cannot_hide_unmapped_or_duplicate_checks(self):
        for change in ('unmapped', 'duplicate', 'empty', 'lifecycle', 'diagnostic'):
            item = copy.deepcopy(self.manifest)
            if change == 'unmapped': item['suites'][1]['checks'].append('unmapped')
            elif change == 'duplicate': item['suites'].append(item['suites'][1])
            elif change == 'empty': item['suites'][1]['checks'] = []
            elif change == 'lifecycle': item['lifecycle_checks'] = []
            else: item['suites'][1]['diagnostic_only'] = item['suites'][1]['checks'][:]
            with self.subTest(change=change), self.assertRaises(ValueError):
                native.contract(encoded(item), self.old)

    def test_legacy_composite_requirements_have_no_default_true(self):
        mapping = self.manifest['legacy_assertions']
        self.assertEqual(mapping['focusAndAlertSafety'], ['exactCopySnapshots', 'selectionFocus', 'nativeRowsFocus'])
        self.assertEqual(mapping['adaptiveSemanticLayout'], ['selectionAdaptive', 'nativeRowsAdaptive'])
        self.assertEqual(len(mapping['routeStateMatrix']), 16)
        self.assertIn('dismissedFailureReportsAndReconciles', mapping['routeStateMatrix'])
        for component in mapping['routeStateMatrix'] + mapping['focusAndAlertSafety'] + mapping['adaptiveSemanticLayout']:
            rows = copy.deepcopy(self.reports)
            next(x for x in rows if component in x['checks'])['checks'][component] = False
            with self.subTest(component=component), self.assertRaises(ValueError):
                native.aggregate(self.manifest, self.old, [encoded(x) for x in rows])


if __name__ == '__main__':
    unittest.main()
