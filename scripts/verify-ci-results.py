#!/usr/bin/env python3
"""Fail closed unless every mandatory job and exact suite roster completed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

JOBS = {'quality': 'static', 'compile-package': 'compile', 'runtime-safety': 'runtime',
        'native-and-lifecycle': 'native', 'package-contract': 'package'}
IDENTIFIER = re.compile(r'[a-z0-9][a-z0-9-]{0,95}')
CASE_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,159}')
TIMING_SUFFIX = re.compile(r' \[[0-9]{1,20} ms\]$')
SHA256 = re.compile(r'[0-9a-f]{64}')
REVISION = re.compile(r'[0-9a-f]{40}')
RUN_ID = re.compile(r'[1-9][0-9]{0,19}')
MAX_JSON = 1_048_576
MAX_LOG = 16_777_216


class InvalidEvidence(Exception):
    pass


def require(condition):
    if not condition:
        raise InvalidEvidence('mandatory CI evidence is incomplete or invalid')


def matches(pattern, value):
    return type(value) is str and pattern.fullmatch(value) is not None


def closed(value, keys):
    require(type(value) is dict and set(value) == set(keys))
    return value


def pairs(values):
    result = {}
    for key, value in values:
        require(key not in result)
        result[key] = value
    return result


def decode(data):
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda _: require(False))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise InvalidEvidence('CI evidence is not strict JSON') from error


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def read_regular(path, limit=MAX_JSON, *, parent=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                         dir_fd=parent)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and 0 < before.st_size <= limit)
        output = bytearray()
        while len(output) <= limit:
            chunk = os.read(descriptor, min(65_536, limit + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
        require(len(output) == before.st_size and identity(before) == identity(os.fstat(descriptor)))
        require(identity(before) == identity(os.stat(path, dir_fd=parent, follow_symlinks=False)))
        return bytes(output)
    finally:
        os.close(descriptor)


def unique_ids(value, *, nonempty=True, pattern=CASE_ID):
    require(type(value) is list and (bool(value) or not nonempty) and len(value) <= 4096)
    require(all(matches(pattern, item) and item == item.strip() for item in value))
    require(len(value) == len(set(value)))
    return value


def validate_manifest(data):
    manifest = closed(decode(data), ('schema', 'jobs', 'suites'))
    require(manifest['schema'] == 'shadow-sync-ci-coverage/v1')
    jobs = closed(manifest['jobs'], JOBS)
    require(type(manifest['suites']) is dict and 0 < len(manifest['suites']) <= 256)
    assigned = []
    for job, kind in JOBS.items():
        for suite_id in unique_ids(jobs[job], pattern=IDENTIFIER):
            require(suite_id in manifest['suites'])
            suite = closed(manifest['suites'][suite_id], ('kind', 'cases'))
            require(suite['kind'] == kind)
            unique_ids(suite['cases'])
            assigned.append(suite_id)
    require(len(assigned) == len(set(assigned)) and set(assigned) == set(manifest['suites']))
    return manifest


def verify(manifest_bytes, needs_bytes, receipts_path, *, revision, run_id, run_attempt):
    require(matches(REVISION, revision) and revision != '0' * 40
            and matches(RUN_ID, run_id) and matches(RUN_ID, run_attempt))
    manifest = validate_manifest(manifest_bytes)
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    needs = closed(decode(needs_bytes), JOBS)
    for job in JOBS:
        item = closed(needs[job], ('result', 'outputs'))
        require(item['result'] == 'success' and type(item['outputs']) is dict)
    directory = os.open(receipts_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        required_files = {name + extension for name in manifest['suites'] for extension in ('.json', '.log')}
        require(set(os.listdir(directory)) == required_files)
        count = 0
        for name, expected in manifest['suites'].items():
            receipt = closed(decode(read_regular(name + '.json', parent=directory)), (
                'schema', 'suite', 'kind', 'revision', 'run_id', 'run_attempt', 'manifest_sha256',
                'status', 'exit_code', 'expected_cases', 'passed_cases', 'failed_cases',
                'skipped_cases', 'cleanup_complete', 'command_sha256', 'log_sha256'))
            require(receipt['schema'] == 'shadow-sync-ci-suite-result/v1')
            require(receipt['suite'] == name and receipt['kind'] == expected['kind'])
            require(receipt['revision'] == revision and receipt['run_id'] == run_id
                    and receipt['run_attempt'] == run_attempt and receipt['manifest_sha256'] == manifest_sha)
            require(receipt['status'] == 'complete' and type(receipt['exit_code']) is int
                    and receipt['exit_code'] == 0 and receipt['cleanup_complete'] is True)
            require(unique_ids(receipt['expected_cases']) == expected['cases'])
            require(set(unique_ids(receipt['passed_cases'])) == set(expected['cases']))
            require(unique_ids(receipt['failed_cases'], nonempty=False) == [])
            require(unique_ids(receipt['skipped_cases'], nonempty=False) == [])
            require(matches(SHA256, receipt['command_sha256']) and receipt['command_sha256'] != '0' * 64)
            require(matches(SHA256, receipt['log_sha256']))
            log = read_regular(name + '.log', MAX_LOG, parent=directory)
            require(hashlib.sha256(log).hexdigest() == receipt['log_sha256'])
            # Runtime/native suites must emit the independently counted canonical
            # PASS roster. Compile-only output can never satisfy these kinds.
            if expected['kind'] in ('runtime', 'native'):
                lines = log.decode('utf-8', errors='strict').splitlines()
                observed = [TIMING_SUFFIX.sub('', line[5:]) for line in lines if line.startswith('PASS ')]
                require(set(unique_ids(observed)) == set(expected['cases']))
                require(not any(line.startswith(('FAIL ', 'SKIP ')) for line in lines))
            count += len(expected['cases'])
        require(set(os.listdir(directory)) == required_files)
        return {'schema': 'shadow-sync-ci-required-result/v1', 'revision': revision,
                'run_id': run_id, 'run_attempt': run_attempt, 'manifest_sha256': manifest_sha, 'jobs': len(JOBS),
                'suites': len(manifest['suites']), 'cases': count, 'status': 'complete'}
    finally:
        os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--needs', required=True, type=Path)
    parser.add_argument('--receipts', required=True, type=Path)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--run-attempt', required=True)
    args = parser.parse_args()
    try:
        result = verify(read_regular(args.manifest), read_regular(args.needs), args.receipts,
                        revision=args.revision, run_id=args.run_id, run_attempt=args.run_attempt)
    except (InvalidEvidence, OSError, UnicodeError):
        sys.stderr.write('Required CI coverage is incomplete or invalid.\n')
        return 1
    print(json.dumps(result, sort_keys=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
