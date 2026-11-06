#!/usr/bin/env python3
"""Check compiled suite registration against every public self-test entrypoint.

This is a source-contract check. Native CI must additionally compare executable
--list-ci-suites output with this projection and execute its complete case roster.
"""
import argparse
import json
from pathlib import Path
import re
import sys

# Exact compatibility entrypoints, not directory-wide exclusions. These retain
# developer selectors and composite historical regressions without creating an
# unregistered CI execution path. The native M5 probe owns its AppKit-bound suite.
CLASSIFICATIONS = {
    'DM4PreflightSelfTestRunner.runFocused': ('alias', ['v4-preflight']),
    'M2SelfTestRunner.runCoalescedValidation': ('alias', ['m2']),
    'M2SelfTestRunner.runPerformance': ('alias', ['m2']),
    'M5SelfTestRunner.runAll': ('native-probe', ['scripts/verify-m5.sh']),
    'V2Body1SelfTestRunner.runBetaV06': ('composite', ['beta-v06']),
    'V2Body1SelfTestRunner.runBetaV08': ('composite', ['beta-v08', 'beta-v09']),
    'V2Body2SelfTestRunner.runFocused': ('alias', ['body2']),
    'V2Body3SelfTestRunner.runBetaV06': ('composite', ['beta-v06']),
    'V2Body3SelfTestRunner.runBetaV07': ('composite', ['beta-v07', 'beta-v08', 'beta-v09']),
    'V2Body3SelfTestRunner.runFocused': ('alias', ['body3']),
    'V2Body4SelfTestRunner.runFocused': ('alias', ['body4']),
    'V3PreflightSelfTestRunner.runFocused': ('alias', ['v3-preflight']),
}


def require(condition):
    if not condition:
        raise ValueError('runtime suite inventory is incomplete or inconsistent')


def inspect(root):
    catalog_path = root / 'Tests/ShadowSyncSelfTests/CISuites.swift'
    catalog = catalog_path.read_text()
    require(catalog.startswith('#if SHADOW_SYNC_TESTING\n') and catalog.rstrip().endswith('#endif'))
    rows = re.findall(r'Entry\(id: "([a-z0-9-]+)", run: \{[^\n]*?\b(\w+SelfTestRunner)\.(run\w+)\(', catalog)
    require(rows and len(rows) == catalog.count('Entry(id:'))
    ids = [row[0] for row in rows]
    require(len(ids) == len(set(ids)))
    methods = [runner + '.' + method for _, runner, method in rows]
    require(len(methods) == len(set(methods)))
    case_rows = re.findall(r'^            "([a-z0-9-]+)": (\[[^\n]+\]),$', catalog, re.M)
    require(len(case_rows) == len(ids) and len(set(name for name, _ in case_rows)) == len(ids))
    cases = {name: json.loads(value) for name, value in case_rows}
    require(set(cases) == set(ids))
    for values in cases.values():
        require(type(values) is list and values and len(values) == len(set(values)))
        require(all(type(value) is str and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,159}', value)
                    for value in values))
    discovered = {}
    # Scan all Core source names so renaming a new runner's file cannot hide it.
    files = sorted((root / 'Sources/ShadowSyncCore').rglob('*.swift'))
    require(files)
    for path in files:
        text = path.read_text()
        # Discover runner extensions and non-enum types too. A new file name or
        # declaration kind must never create an invisible public run entrypoint.
        runners = re.findall(r'\b(?:enum|struct|class|actor|protocol|extension)\s+'
                             r'(?:\w+\.)*(\w+SelfTestRunner)\b', text)
        if not runners and not path.name.endswith('SelfTests.swift'):
            continue
        require(text.startswith('#if SHADOW_SYNC_TESTING\n') and text.rstrip().endswith('#endif'))
        require(len(runners) == 1)
        declared_methods = re.findall(r'\bpublic\s+static\s+func\s+(run\w+)\s*\(', text)
        public_runs = re.findall(r'\b(?:public|open)\s+(?:\w+\s+)*func\s+(run\w+)\b', text)
        # This deliberately supports one closed declaration convention. Implicit
        # extension access, extra modifiers and generic signatures require an
        # explicit scanner update instead of silently omitting public tests.
        require(declared_methods and public_runs == declared_methods
                and not re.search(r'\bpublic\s+extension\b', text))
        for method in declared_methods:
            key = runners[0] + '.' + method
            require(key not in discovered)
            discovered[key] = str(path.relative_to(root))
    require(set(methods).isdisjoint(CLASSIFICATIONS))
    require(set(discovered) == set(methods) | set(CLASSIFICATIONS))
    for entry, (kind, owners) in CLASSIFICATIONS.items():
        require(owners)
        if kind == 'native-probe':
            require(owners == ['scripts/verify-m5.sh'])
            harness = (root / 'Sources/ShadowSyncApp/M5Harness.swift').read_text()
            probe = (root / owners[0]).read_text()
            require('M5SelfTestRunner.runAll(testRoot: root)' in harness
                    and 'result["coreTests"] == [' in probe
                    and '"m5-secure-log-open-success"' in probe
                    and '"m5-secure-log-open-default-app-failure"' in probe)
        else:
            require(kind in ('alias', 'composite') and all(owner in ids for owner in owners))
    # M6 uses one closed literal run(...) body per mandatory case. Check both
    # sides so a newly added body cannot disappear behind a stale CI roster.
    m6 = (root / 'Sources/ShadowSyncCore/M6SelfTests.swift').read_text()
    m6_bodies = re.findall(r'\btry\s+run\s*\(\s*"([^"\n]+)"', m6)
    require(len(m6_bodies) == len(re.findall(r'\btry\s+run\s*\(', m6)))
    require(len(m6_bodies) == len(set(m6_bodies)) and set(m6_bodies) == set(cases['m6']))
    return {'schema': 'shadow-sync-runtime-suite-inventory/v1',
            'owner': 'application-engineer',
            'suites': [{'id': name, 'cases': cases[name],
                        'entrypoint': runner + '.' + method,
                        'source': discovered[runner + '.' + method]}
                       for name, runner, method in rows],
            'other_entrypoints': [{'entrypoint': name, 'kind': kind, 'covered_by': owners,
                                   'source': discovered[name], 'owner': 'application-engineer'}
                                  for name, (kind, owners) in sorted(CLASSIFICATIONS.items())],
            'case_count': sum(len(value) for value in cases.values()),
            'runtime_executed': False}


def validate_discovery(inventory, data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result)
            result[key] = value
        return result
    require(type(data) is bytes and 0 < len(data) <= 262144)
    actual = json.loads(data, object_pairs_hook=pairs,
                        parse_constant=lambda _: require(False))
    require(type(actual) is dict and set(actual) == {'schema', 'suites'})
    require(actual['schema'] == 'shadow-sync-runtime-suite-discovery/v1')
    require(actual['suites'] == [{'id': s['id'], 'cases': s['cases']} for s in inventory['suites']])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--discovery', type=Path)
    args = parser.parse_args()
    try:
        inventory = inspect(args.root)
        if args.discovery is not None:
            validate_discovery(inventory, args.discovery.read_bytes())
        print(json.dumps(inventory, sort_keys=True, separators=(',', ':')))
        return 0
    except (ValueError, OSError, UnicodeError, RecursionError):
        sys.stderr.write('Runtime suite discovery/registration is incomplete or invalid.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
