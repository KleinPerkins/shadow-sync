#!/usr/bin/env python3
"""Validate M5 AppKit completion reports; this does not execute native probes.

The reviewed contract preserves every existing boolean assertion, secure-log
case and three-trial latency protocol. Diagnostic accessibility metadata keeps
its existing nonblocking meaning. Desktop and physical-input UAT remain separate.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import sys

MAX_JSON = 1_048_576
PROBES = ('m5-ui', 'm5-practical-ui', 'm5-status-item-guidance',
          'm5-confirmation-close', 'm5-foreground', 'm5-operation-contention',
          'm5-latency')
CORE = ('m5-secure-log-open-success', 'm5-secure-log-open-refusals',
        'm5-secure-log-open-identity-change', 'm5-secure-log-open-default-app-failure')


def require(condition):
    if not condition:
        raise ValueError('native AppKit contract or completion report is invalid')


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result


def decode(data):
    require(type(data) is bytes and 0 < len(data) <= MAX_JSON)
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False))


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and 0 < before.st_size <= MAX_JSON)
        data = bytearray()
        while len(data) <= MAX_JSON:
            part = os.read(fd, min(65536, MAX_JSON + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
                                 info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        require(len(data) == before.st_size
                and identity(before) == identity(os.fstat(fd))
                and identity(before) == identity(os.stat(path, follow_symlinks=False)))
        return bytes(data)
    finally:
        os.close(fd)


def contract(data):
    value = decode(data)
    require(type(value) is dict and set(value) == {'schema', 'source', 'probes', 'core_tests'})
    require(value['schema'] == 'shadow-sync-native-appkit-contract/v1'
            and value['source'] == 'Sources/ShadowSyncApp/M5Harness.swift'
            and value['core_tests'] == list(CORE))
    require(type(value['probes']) is list and len(value['probes']) == len(PROBES))
    require([p.get('id') for p in value['probes'] if type(p) is dict] == list(PROBES))
    declarations = set()
    for probe in value['probes']:
        require(set(probe) == {'id', 'declaration', 'schema', 'fields', 'diagnostic_only', 'owner'})
        require(type(probe['declaration']) is str
                and re.fullmatch(r'M5[A-Za-z]+Response', probe['declaration']) is not None
                and probe['declaration'] not in declarations)
        declarations.add(probe['declaration'])
        require(probe['schema'] == 'shadow-sync-' + probe['id'] + '-result/v1'
                and probe['owner'] == 'application-engineer')
        fields = probe['fields']
        require(type(fields) is dict and 0 < len(fields) <= 128
                and all(type(k) is str and re.fullmatch(r'[a-z][A-Za-z0-9]*', k)
                        and v in ('Bool', 'Int', 'Double', '[Double]', '[String]')
                        for k, v in fields.items()))
        require(probe['diagnostic_only'] == (['accessibilitySemantics'] if probe['id'] == 'm5-ui' else []))
        if probe['id'] == 'm5-ui':
            require(fields.get('coreTests') == '[String]' and fields.get('accessibilitySemantics') == 'Bool')
            require(all(v == 'Bool' for k, v in fields.items() if k != 'coreTests'))
        elif probe['id'] != 'm5-latency':
            require(all(v == 'Bool' for v in fields.values()))
        else:
            require(fields == {'trial': 'Int', 'rowCount': 'Int', 'durationSeconds': 'Int',
                    'eventIntervalMilliseconds': 'Int', 'expectedEventCount': 'Int',
                    'renderedEventCount': 'Int', 'firstSequence': 'Int', 'lastSequence': 'Int',
                    'monotonic': 'Bool', 'noDroppedEvents': 'Bool', 'p95Milliseconds': 'Double',
                    'maximumMilliseconds': 'Double', 'samplesMilliseconds': '[Double]'})
    return value


def source_consistent(value, source):
    """New/renamed response fields require a reviewed contract update."""
    require(type(source) is str and source.startswith('#if SHADOW_SYNC_TESTING\n')
            and source.rstrip().endswith('#endif'))
    rows = re.findall(r'private struct (M5\w+Response): Encodable \{\n(.*?)\n\}', source, re.S)
    require(len(rows) == len(value['probes']) and len({name for name, _ in rows}) == len(rows))
    observed = {}
    for name, body in rows:
        lines = body.splitlines()
        schema_rows = re.findall(r'^    let schema = "([^"]+)"$', body, re.M)
        fields = re.findall(r'^    let ([a-z][A-Za-z0-9]*): (.+)$', body, re.M)
        require(len(schema_rows) == 1 and len(fields) == len({k for k, _ in fields})
                and len(lines) == len(fields) + 1)
        observed[name] = (schema_rows[0], dict(fields))
    require(observed == {p['declaration']: (p['schema'], p['fields']) for p in value['probes']})


def cases(value, probe_id, trial=None):
    probe = next((p for p in value['probes'] if p['id'] == probe_id), None)
    require(probe is not None)
    if probe_id == 'm5-latency':
        require(type(trial) is int and trial in (1, 2, 3))
        return [f'm5-latency-{trial}/complete-protocol']
    require(trial is None)
    result = [probe_id + '/' + k for k, v in probe['fields'].items()
              if v == 'Bool' and k not in probe['diagnostic_only']]
    if probe_id == 'm5-ui':
        result += [probe_id + '/accessibility-diagnostic-type']
        result += [probe_id + '/' + name for name in CORE]
    return result


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def validate_report(value, probe_id, data, trial=None):
    expected = cases(value, probe_id, trial)
    probe = next(p for p in value['probes'] if p['id'] == probe_id)
    report = decode(data)
    require(type(report) is dict and set(report) == {'schema', *probe['fields']}
            and report['schema'] == probe['schema'])
    for name, kind in probe['fields'].items():
        if kind == 'Bool':
            require(type(report[name]) is bool)
            if name not in probe['diagnostic_only']:
                require(report[name] is True)
    if probe_id == 'm5-ui':
        require(report['coreTests'] == list(CORE))
    if probe_id == 'm5-latency':
        fixed = {'trial': trial, 'rowCount': 100, 'durationSeconds': 60,
                 'eventIntervalMilliseconds': 25, 'expectedEventCount': 2400,
                 'renderedEventCount': 2400, 'firstSequence': 2, 'lastSequence': 2401}
        require(all(type(report[k]) is int and report[k] == v for k, v in fixed.items()))
        samples = report['samplesMilliseconds']
        require(type(samples) is list and len(samples) == 2400 and all(number(x) for x in samples))
        require(number(report['p95Milliseconds']) and number(report['maximumMilliseconds']))
        ordered = sorted(samples)
        require(report['p95Milliseconds'] == ordered[math.ceil(len(ordered) * .95) - 1]
                and report['p95Milliseconds'] <= 250
                and report['maximumMilliseconds'] == ordered[-1])
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--source', type=Path)
    mode.add_argument('--probe', choices=PROBES)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--trial', type=int)
    args = parser.parse_args()
    try:
        value = contract(read_regular(args.contract))
        if args.source is not None:
            require(args.report is None and args.trial is None)
            source_consistent(value, read_regular(args.source).decode('utf-8'))
            print('PASS native-appkit/registered-response-contracts')
        else:
            require(args.report is not None)
            observed = validate_report(value, args.probe, read_regular(args.report), args.trial)
            for name in observed:
                print('PASS ' + name)
        return 0
    except (ValueError, TypeError, KeyError, OSError, UnicodeError, RecursionError):
        sys.stderr.write('Native AppKit report validation failed.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
