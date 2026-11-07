#!/usr/bin/env python3
"""Canonical mandatory-suite partitioning and exact-run shard evidence gate.

The registration contains the existing coverage contract plus direct argv for
each suite. Partition whole executable suites: a compile check is never a runtime
test. All mandatory suites run on every change. A registration change additionally
requires the full unsharded transition run. No path-based omission is authorized.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys

_spec = importlib.util.spec_from_file_location(
    'shadow_sync_ci_results', Path(__file__).with_name('verify-ci-results.py'))
coverage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(coverage)
require = coverage.require
closed = coverage.closed
InvalidEvidence = coverage.InvalidEvidence
MAX_FILES = 8192
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_SOURCE_BYTES = 256 * 1024 * 1024
# Tooling includes native executable/custody fixtures; every job is macOS arm64.
RUNNERS = {job: 'macos-26' for job in coverage.JOBS}


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=True, allow_nan=False).encode('ascii')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def registration(data):
    value = closed(coverage.decode(data), ('schema', 'coverage', 'shards', 'commands'))
    require(value['schema'] == 'shadow-sync-test-shards/v1')
    contract = coverage.validate_manifest(encode(value['coverage']))
    closed(value['shards'], coverage.JOBS)
    closed(value['commands'], contract['suites'])
    for job, suites in contract['jobs'].items():
        count = value['shards'][job]
        require(type(count) is int and 1 <= count <= min(8, len(suites)))
        # Refuse an empty hash partition rather than silently reducing coverage.
        require(all(partition(suites, index, count) for index in range(count)))
    for name, command in value['commands'].items():
        closed(command, ('argv', 'timeout_seconds'))
        argv = command['argv']
        require(type(argv) is list and 0 < len(argv) <= 128)
        require(all(type(arg) is str and 0 < len(arg.encode('utf-8')) <= 4096
                    and not any(ord(c) < 32 or ord(c) == 127 for c in arg)
                    for arg in argv))
        require(sum(len(arg.encode('utf-8')) + 1 for arg in argv) <= 32768)
        require(type(command['timeout_seconds']) is int
                and 1 <= command['timeout_seconds'] <= 5400)
    return value


def partition(suites, index, count):
    require(type(count) is int and 1 <= count <= 8
            and type(index) is int and 0 <= index < count)
    # Preserve manifest order within a unit; no interpreter-dependent hash().
    return [name for name in suites if
            int.from_bytes(hashlib.sha256(name.encode('utf-8')).digest()[:8], 'big')
            % count == index]


def source_identities(root_fd, paths):
    """Reopen each path from the pinned root; retain ancestor and file identities."""
    identities = {'': coverage.identity(os.fstat(root_fd))}
    for name in paths:
        parent = os.dup(root_fd)
        try:
            parts = name.split('/')
            for index, part in enumerate(parts[:-1]):
                info = os.stat(part, dir_fd=parent, follow_symlinks=False)
                require(stat.S_ISDIR(info.st_mode))
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY
                                | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
                try:
                    require(coverage.identity(info) == coverage.identity(os.fstat(child)))
                except BaseException:
                    os.close(child)
                    raise
                os.close(parent)
                parent = child
                key = '/'.join(parts[:index + 1])
                current = coverage.identity(info)
                require(key not in identities or identities[key] == current)
                identities[key] = current
            info = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
            identities[name] = coverage.identity(info)
        finally:
            os.close(parent)
    require(identities[''] == coverage.identity(os.fstat(root_fd)))
    return identities


def source_digest(root, paths, *, expected_git=None):
    """Bind every tracked byte, path and executable bit; reject links/special files.

    Callers must obtain paths from Git's NUL-delimited tracked-file inventory.
    This function also supports a supplied disposable inventory in unit tests.
    """
    require(type(paths) is list and 0 < len(paths) <= MAX_FILES
            and all(type(name) is str for name in paths)
            and len(paths) == len(set(paths)))
    if expected_git is not None:
        require(type(expected_git) is dict and set(expected_git) == set(paths))
    for name in paths:
        require(0 < len(name.encode('utf-8')) <= 4096
                and not name.startswith('/') and '\\' not in name
                and not any(ord(c) < 32 or ord(c) == 127 for c in name)
                and all(part not in ('', '.', '..') for part in name.split('/')))
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    total = 0
    result = hashlib.sha256(b'shadow-sync-ci-source/v1\0')
    try:
        before = source_identities(root_fd, paths)
        for name in sorted(paths):
            require(type(name) is str and 0 < len(name.encode('utf-8')) <= 4096
                    and not name.startswith('/') and '\\' not in name
                and not any(ord(c) < 32 or ord(c) == 127 for c in name)
                    and all(part not in ('', '.', '..') for part in name.split('/')))
            parent = os.dup(root_fd)
            try:
                parts = name.split('/')
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY
                                    | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
                    os.close(parent)
                    parent = child
                info = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                        and info.st_size <= MAX_FILE_BYTES
                        and coverage.identity(info) == before[name])
                # Empty tracked files are valid and still identity checked.
                fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW
                             | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
                try:
                    require(coverage.identity(info) == coverage.identity(os.fstat(fd)))
                    data = bytearray()
                    while len(data) <= MAX_FILE_BYTES:
                        chunk = os.read(fd, min(65536, MAX_FILE_BYTES + 1 - len(data)))
                        if not chunk:
                            break
                        data.extend(chunk)
                    require(len(data) == info.st_size
                            and coverage.identity(info) == coverage.identity(os.fstat(fd))
                            and coverage.identity(info) == coverage.identity(os.stat(
                                parts[-1], dir_fd=parent, follow_symlinks=False)))
                finally:
                    os.close(fd)
                total += len(data)
                require(total <= MAX_SOURCE_BYTES)
                if expected_git is not None:
                    mode, object_id = expected_git[name]
                    # Read bytes directly; assume-unchanged, stat caches, index
                    # entries and text conversion cannot substitute for HEAD.
                    actual_id = hashlib.sha1(
                        b'blob ' + str(len(data)).encode('ascii') + b'\0' + data
                    ).hexdigest()
                    require(actual_id == object_id
                            and bool(info.st_mode & 0o111) == (mode == '100755'))
                result.update(encode([name, bool(info.st_mode & 0o111), digest(data)]))
                result.update(b'\0')
            finally:
                os.close(parent)
        require(before == source_identities(root_fd, paths)
                and before[''] == coverage.identity(os.stat(root, follow_symlinks=False)))
    finally:
        os.close(root_fd)
    return result.hexdigest()


def git_source_digest(root, revision):
    """Require HEAD, index membership and actual source bytes to agree.

    GitHub revision identities use SHA-1. Raw tree objects are authoritative;
    neither a clean-status claim nor an index stat cache proves checkout bytes.
    """
    require(coverage.matches(coverage.REVISION, revision) and revision != '0' * 40)
    environment = {'PATH': os.defpath, 'LANG': 'C', 'LC_ALL': 'C',
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                   'GIT_CONFIG_SYSTEM': '/dev/null', 'GIT_NO_REPLACE_OBJECTS': '1'}
    def git(*args):
        return subprocess.run(['/usr/bin/git', '--no-replace-objects',
                               '-c', 'core.fsmonitor=false', '-C', str(root), *args],
                              env=environment, check=True, capture_output=True,
                              timeout=30).stdout
    def head():
        require(git('rev-parse', 'HEAD^{commit}').decode('ascii').strip() == revision)
    require(git('rev-parse', '--show-object-format').strip() == b'sha1')
    head()
    tree = git('ls-tree', '-rz', '--full-tree', revision)
    require(tree.endswith(b'\0') and len(tree) <= MAX_FILES * 4224)
    expected = {}
    for entry in tree[:-1].split(b'\0'):
        fields, name = entry.split(b'\t', 1)
        mode, kind, object_id = fields.decode('ascii').split(' ')
        path = name.decode('utf-8')
        require(mode in ('100644', '100755') and kind == 'blob'
                and coverage.matches(coverage.REVISION, object_id)
                and path not in expected)
        expected[path] = (mode, object_id)
    require(0 < len(expected) <= MAX_FILES)
    index = git('ls-files', '--stage', '-z')
    require(index.endswith(b'\0') and len(index) <= MAX_FILES * 4224)
    indexed = {}
    for entry in index[:-1].split(b'\0'):
        fields, name = entry.split(b'\t', 1)
        mode, object_id, stage = fields.decode('ascii').split(' ')
        path = name.decode('utf-8')
        require(stage == '0' and path not in indexed)
        indexed[path] = (mode, object_id)
    require(indexed == expected)
    result = source_digest(root, list(expected), expected_git=expected)
    head()
    require(git('ls-files', '--stage', '-z') == index
            and git('ls-tree', '-rz', '--full-tree', revision) == tree)
    return result


def make_plan(head_bytes, base_bytes, *, revision, run_id, run_attempt, source_sha256):
    head = registration(head_bytes)
    if base_bytes is not None:
        registration(base_bytes)  # Unknown/broken base is not routine-mode evidence.
    require(coverage.matches(coverage.REVISION, revision) and revision != '0' * 40)
    require(coverage.matches(coverage.RUN_ID, run_id)
            and coverage.matches(coverage.RUN_ID, run_attempt))
    require(coverage.matches(coverage.SHA256, source_sha256) and source_sha256 != '0' * 64)
    mode = 'routine' if base_bytes == head_bytes else 'transition'
    units = []
    for job, suites in head['coverage']['jobs'].items():
        count = head['shards'][job]
        for index in range(count):
            units.append({'id': f'{job}-{index}', 'job': job, 'runner': RUNNERS[job],
                          'architecture': 'arm64',
                          'index': index, 'count': count, 'mode': 'shard',
                          'suites': partition(suites, index, count)})
        if mode == 'transition':
            units.append({'id': f'{job}-full', 'job': job, 'runner': RUNNERS[job],
                          'architecture': 'arm64',
                          'index': 0, 'count': 1, 'mode': 'full', 'suites': suites})
    return {'schema': 'shadow-sync-ci-shard-plan/v1', 'mode': mode,
            'revision': revision, 'run_id': run_id, 'run_attempt': run_attempt,
            'source_sha256': source_sha256, 'head_sha256': digest(head_bytes),
            'base_sha256': None if base_bytes is None else digest(base_bytes),
            'units': units}


def verify_unit(contract, plan, unit, directory, *, parent=None):
    """A separate unit directory prevents artifact extraction from hiding duplicates."""
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                 dir_fd=parent)
    try:
        expected = {'unit.json'} | {name + ext for name in unit['suites']
                                   for ext in ('.json', '.log')}
        require(set(os.listdir(fd)) == expected)
        receipt = closed(coverage.decode(coverage.read_regular('unit.json', parent=fd)), (
            'schema', 'plan_sha256', 'unit', 'revision', 'run_id', 'run_attempt',
            'source_sha256', 'status', 'seconds', 'suites'))
        require(receipt['schema'] == 'shadow-sync-ci-shard-result/v1'
                and receipt['plan_sha256'] == digest(encode(plan))
                and receipt['unit'] == unit and receipt['status'] == 'complete')
        for key in ('revision', 'run_id', 'run_attempt', 'source_sha256'):
            require(receipt[key] == plan[key])
        require(type(receipt['seconds']) in (int, float)
                and math.isfinite(receipt['seconds']) and receipt['seconds'] >= 0)
        require(receipt['suites'] == unit['suites'])
        for name in unit['suites']:
            expected_suite = contract['coverage']['suites'][name]
            suite = closed(coverage.decode(coverage.read_regular(name + '.json', parent=fd)), (
                'schema', 'suite', 'kind', 'revision', 'run_id', 'run_attempt',
                'unit_id', 'plan_sha256', 'source_sha256',
                'manifest_sha256', 'status', 'exit_code', 'expected_cases', 'passed_cases',
                'failed_cases', 'skipped_cases', 'cleanup_complete', 'command_sha256', 'log_sha256'))
            require(suite['schema'] == 'shadow-sync-ci-sharded-suite-result/v1'
                    and suite['suite'] == name and suite['kind'] == expected_suite['kind']
                    and suite['unit_id'] == unit['id']
                    and suite['plan_sha256'] == digest(encode(plan))
                    and suite['source_sha256'] == plan['source_sha256'])
            for key in ('revision', 'run_id', 'run_attempt'):
                require(suite[key] == plan[key])
            require(suite['manifest_sha256'] == digest(encode(contract['coverage'])))
            require(suite['status'] == 'complete' and type(suite['exit_code']) is int
                    and suite['exit_code'] == 0 and suite['cleanup_complete'] is True)
            require(coverage.unique_ids(suite['expected_cases']) == expected_suite['cases'])
            require(set(coverage.unique_ids(suite['passed_cases'])) == set(expected_suite['cases']))
            require(coverage.unique_ids(suite['failed_cases'], nonempty=False) == []
                    and coverage.unique_ids(suite['skipped_cases'], nonempty=False) == [])
            require(suite['command_sha256'] == digest(encode(contract['commands'][name])))
            log = coverage.read_regular(name + '.log', coverage.MAX_LOG, parent=fd)
            require(suite['log_sha256'] == digest(log))
            # Every kind has a real case-level report. Static and compile runners
            # must report their actual assertions too; prose/build output cannot pass.
            lines = log.decode('utf-8', errors='strict').splitlines()
            observed = [coverage.TIMING_SUFFIX.sub('', line[5:])
                        for line in lines if line.startswith('PASS ')]
            require(set(coverage.unique_ids(observed)) == set(expected_suite['cases']))
            require(not any(line.startswith(('FAIL ', 'SKIP ')) for line in lines))
        require(set(os.listdir(fd)) == expected)
        return receipt['seconds']
    finally:
        os.close(fd)


def artifact_identities(root_fd, plan):
    """Snapshot every expected file, including already-verified earlier units."""
    result = {'': coverage.identity(os.fstat(root_fd))}
    require(set(os.listdir(root_fd)) == {unit['id'] for unit in plan['units']})
    for unit in plan['units']:
        name = unit['id']
        before = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        require(stat.S_ISDIR(before.st_mode))
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                     | os.O_CLOEXEC, dir_fd=root_fd)
        try:
            result[name] = coverage.identity(before)
            require(result[name] == coverage.identity(os.fstat(fd)))
            files = {'unit.json'} | {suite + suffix for suite in unit['suites']
                                    for suffix in ('.json', '.log')}
            require(set(os.listdir(fd)) == files)
            for file in sorted(files):
                info = os.stat(file, dir_fd=fd, follow_symlinks=False)
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
                result[name + '/' + file] = coverage.identity(info)
            require(result[name] == coverage.identity(os.fstat(fd))
                    and result[name] == coverage.identity(os.stat(
                        name, dir_fd=root_fd, follow_symlinks=False)))
        finally:
            os.close(fd)
    require(result[''] == coverage.identity(os.fstat(root_fd)))
    return result


def aggregate(head_bytes, base_bytes, plan_bytes, needs_bytes, artifacts, **identity):
    # Recompute from checked-out registration and exact trusted-base bytes; never
    # accept the planner's claimed mode, matrix, scope or inventory as authority.
    plan = make_plan(head_bytes, base_bytes, **identity)
    require(coverage.decode(plan_bytes) == plan)
    needs = closed(coverage.decode(needs_bytes), ('plan', *coverage.JOBS))
    for name in needs:
        item = closed(needs[name], ('result', 'outputs'))
        require(item['result'] == 'success' and type(item['outputs']) is dict)
    contract = registration(head_bytes)
    expected = {unit['id'] for unit in plan['units']}
    fd = os.open(artifacts, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        require(set(os.listdir(fd)) == expected)
        # Use descriptor-relative read-only roots so a renamed ancestor cannot
        # redirect a unit after its inventory has been checked.
        root_before = coverage.identity(os.fstat(fd))
        files_before = artifact_identities(fd, plan)
        times = {}
        for unit in plan['units']:
            info = os.stat(unit['id'], dir_fd=fd, follow_symlinks=False)
            require(stat.S_ISDIR(info.st_mode))
            times[unit['id']] = verify_unit(contract, plan, unit, unit['id'], parent=fd)
            require(coverage.identity(info) == coverage.identity(os.stat(
                unit['id'], dir_fd=fd, follow_symlinks=False)))
        require(set(os.listdir(fd)) == expected
                and files_before == artifact_identities(fd, plan)
                and root_before == coverage.identity(os.fstat(fd))
                and root_before == coverage.identity(os.stat(artifacts, follow_symlinks=False)))
    finally:
        os.close(fd)
    return {'schema': 'shadow-sync-ci-shards-required/v1', 'status': 'complete',
            'revision': plan['revision'], 'run_id': plan['run_id'],
            'run_attempt': plan['run_attempt'], 'mode': plan['mode'],
            'plan_sha256': digest(encode(plan)), 'units': len(plan['units']),
            'unique_suites': len(contract['coverage']['suites']),
            'unique_cases': sum(len(suite['cases']) for suite in contract['coverage']['suites'].values()),
            'seconds_by_unit': times}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('plan', 'aggregate'))
    parser.add_argument('--registration', required=True, type=Path)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--base-registration', type=Path)
    group.add_argument('--initial-registration', action='store_true')
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--run-attempt', required=True)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--needs', type=Path)
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    try:
        head = coverage.read_regular(args.registration)
        base = None if args.initial_registration else coverage.read_regular(args.base_registration)
        identity = dict(revision=args.revision, run_id=args.run_id, run_attempt=args.run_attempt,
                        source_sha256=git_source_digest(args.root, args.revision))
        if args.operation == 'plan':
            require(args.plan is None and args.needs is None and args.artifacts is None)
            result = make_plan(head, base, **identity)
        else:
            require(args.plan is not None and args.needs is not None and args.artifacts is not None)
            result = aggregate(head, base, coverage.read_regular(args.plan),
                               coverage.read_regular(args.needs), args.artifacts, **identity)
        print(encode(result).decode('ascii'))
        return 0
    except (InvalidEvidence, OSError, UnicodeError, ValueError, subprocess.SubprocessError):
        sys.stderr.write('Mandatory shard planning or evidence validation failed.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
