#!/usr/bin/env python3
"""Validate isolated native UI discovery/results and preserve legacy coverage.

Validation does not execute the app or establish physical-input/animation UAT.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('native_appkit', HERE / 'native-appkit-contract.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
require, decode, read_regular = legacy.require, legacy.decode, legacy.read_regular
LIFECYCLE = ['m4ThreeRowProgress', 'm4StopLifecycle', 'm4ControllerStopRaces',
             'm4WorkerStopSingleFlight', 'm4TakeoverTransition']


def contract(data, legacy_contract):
    value = decode(data)
    require(type(value) is dict and set(value) == {
        'schema', 'suites', 'legacy_assertions', 'lifecycle_checks', 'core_tests'})
    require(value['schema'] == 'shadow-sync-native-ui-suites/v1'
            and value['lifecycle_checks'] == LIFECYCLE
            and value['core_tests'] == list(legacy.CORE))
    rows = value['suites']
    require(type(rows) is list and 0 < len(rows) <= 128)
    ids, fields, diagnostic, core = [], [], [], []
    for row in rows:
        require(type(row) is dict and set(row) == {'id', 'checks', 'diagnostic_only', 'core_tests'})
        require(type(row['id']) is str and re.fullmatch(r'[a-z][a-z0-9-]{0,63}', row['id']))
        for key in ('checks', 'diagnostic_only', 'core_tests'):
            require(type(row[key]) is list and all(type(x) is str for x in row[key])
                    and len(row[key]) == len(set(row[key])))
        require(row['checks'] or row['core_tests'])
        require(all(re.fullmatch(r'[a-z][A-Za-z0-9]*', x) for x in row['checks']))
        require(set(row['diagnostic_only']) <= set(row['checks']))
        ids.append(row['id']); fields += row['checks']; diagnostic += row['diagnostic_only']; core += row['core_tests']
    require(len(ids) == len(set(ids)) and len(fields) == len(set(fields)) and core == list(legacy.CORE))
    probe = next(p for p in legacy_contract['probes'] if p['id'] == 'm5-ui')
    expected = {k for k, kind in probe['fields'].items() if kind == 'Bool'}
    mapping = value['legacy_assertions']
    require(type(mapping) is dict and set(mapping) == expected)
    for values in mapping.values():
        require(type(values) is list and bool(values) and all(type(x) is str for x in values)
                and len(values) == len(set(values)) and set(values) <= set(fields))
    require(set(fields) == set(LIFECYCLE).union(*(set(x) for x in mapping.values())))
    require(set(diagnostic) == set(mapping['accessibilitySemantics']))
    require(all(not set(values).intersection(diagnostic)
                for key, values in mapping.items() if key != 'accessibilitySemantics'))
    return value


def inventory(value, data):
    require(decode(data) == value)


def report(value, suite, data):
    row = next((row for row in value['suites'] if row['id'] == suite), None)
    require(row is not None)
    item = decode(data)
    require(type(item) is dict and set(item) == {'schema', 'suite', 'checks', 'coreTests'})
    require(item['schema'] == 'shadow-sync-native-ui-suite-result/v1'
            and item['suite'] == suite and type(item['checks']) is dict
            and set(item['checks']) == set(row['checks']) and item['coreTests'] == row['core_tests'])
    for key, result in item['checks'].items():
        require(type(result) is bool and (result is True or key in row['diagnostic_only']))
    return item


def aggregate(value, legacy_contract, inputs):
    require(type(inputs) is list and len(inputs) == len(value['suites']))
    results = {}
    for data in inputs:
        item = decode(data)
        require(type(item) is dict and type(item.get('suite')) is str and item['suite'] not in results)
        results[item['suite']] = report(value, item['suite'], data)
    require(set(results) == {row['id'] for row in value['suites']})
    checks, core, cases = {}, [], []
    for row in value['suites']:
        item = results[row['id']]
        checks.update(item['checks']); core += item['coreTests']
        cases += ['native-ui/' + row['id'] + '/' + key for key in row['checks'] + row['core_tests']]
    require(len(cases) == len(set(cases)) and all(checks[x] is True for x in LIFECYCLE))
    combined = {'schema': 'shadow-sync-m5-ui-result/v1', 'coreTests': core,
                **{key: all(checks[x] for x in names) for key, names in value['legacy_assertions'].items()}}
    legacy_cases = legacy.validate_report(legacy_contract, 'm5-ui', json.dumps(combined).encode())
    return {'schema': 'shadow-sync-native-ui-aggregation/v1', 'cases': cases,
            'legacy_cases': legacy_cases, 'legacy_report': combined}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--legacy-contract', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--discovery', type=Path)
    mode.add_argument('--suite')
    mode.add_argument('--aggregate', nargs='+', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        old = legacy.contract(read_regular(args.legacy_contract))
        value = contract(read_regular(args.manifest), old)
        if args.discovery is not None:
            require(args.report is None); inventory(value, read_regular(args.discovery))
            print('PASS native-ui/compiled-inventory')
        elif args.suite is not None:
            require(args.report is not None); report(value, args.suite, read_regular(args.report))
            print('PASS native-ui/' + args.suite)
        else:
            require(args.report is None)
            print(json.dumps(aggregate(value, old, [read_regular(p) for p in args.aggregate]), sort_keys=True))
        return 0
    except (ValueError, TypeError, KeyError, StopIteration, OSError, UnicodeError, RecursionError):
        sys.stderr.write('Native UI suite validation failed.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
