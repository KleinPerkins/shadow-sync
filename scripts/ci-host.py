#!/usr/bin/env python3
"""GitHub Actions entrypoints for exact-head planning, execution, and aggregation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
# Hyphenated source entrypoints are loaded without changing their public CLIs.
import importlib.util


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ci = load('ci-shards')


def base_registration(revision):
    ci.require(ci.coverage.matches(ci.coverage.REVISION, revision) and revision != '0' * 40)
    def git(*argv):
        return subprocess.run(['/usr/bin/git', '--no-replace-objects', '-C', str(ROOT), *argv],
                              check=True, capture_output=True, timeout=30).stdout
    ci.require(git('rev-parse', revision + '^{commit}').decode().strip() == revision)
    listing = git('ls-tree', '-z', revision, '--', 'config/ci-suites.json')
    if not listing:
        return None
    ci.require(listing.endswith(b'\0') and listing.count(b'\0') == 1)
    header, path = listing[:-1].split(b'\t')
    mode, kind, oid = header.decode().split()
    ci.require(mode == '100644' and kind == 'blob' and path == b'config/ci-suites.json')
    data = git('cat-file', 'blob', oid)
    ci.registration(data)
    return data


def normalize_artifact_directories(root, plan):
    """Keep attempts distinct on GitHub and refuse duplicate extraction inputs."""
    expected = {'coverage-' + unit['id'] + '-attempt-' + plan['run_attempt']: unit['id']
                for unit in plan['units']}
    ci.require(root.resolve(strict=True) == root and set(os.listdir(root)) == set(expected))
    for name in expected:
        info = (root / name).lstat()
        ci.require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode))
    for name, unit_id in expected.items():
        ci.require(not os.path.lexists(root / unit_id))
        (root / name).rename(root / unit_id)


def inputs():
    identity = dict(revision=os.environ['CI_REVISION'], run_id=os.environ['GITHUB_RUN_ID'],
                    run_attempt=os.environ['GITHUB_RUN_ATTEMPT'])
    identity['source_sha256'] = ci.git_source_digest(ROOT, identity['revision'])
    head = ci.coverage.read_regular(ROOT / 'config/ci-suites.json')
    base = base_registration(os.environ['CI_BASE_REVISION'])
    plan = ci.make_plan(head, base, **identity)
    return head, base, identity, plan


def output(name, value):
    ci.require('\n' not in value and '\r' not in value)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(name + '=' + value + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('plan', 'unit', 'aggregate'))
    parser.add_argument('--unit')
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    try:
        head, base, identity, plan = inputs()
        if args.operation == 'plan':
            load('ci-build').toolchain()
            load('ci-registration').verify()
            output('plan', ci.encode(plan).decode())
            for job in ci.coverage.JOBS:
                output(job, ci.encode({'include': [{'id': unit['id'], 'runner': unit['runner']}
                    for unit in plan['units'] if unit['job'] == job]}).decode())
            print(json.dumps({'mode': plan['mode'], 'units': len(plan['units']), **identity}))
        elif args.operation == 'unit':
            load('ci-build').toolchain()
            ci.require(ci.coverage.decode(os.environ['CI_PLAN']) == plan)
            root = Path(tempfile.mkdtemp(prefix='shadow-sync-ci.', dir='/private/tmp'))
            for folder in ('receipts', 'diagnostics'):
                (root / folder).mkdir(mode=0o700)
            with open(os.environ['GITHUB_ENV'], 'a') as stream:
                stream.write('CI_WORK_ROOT=' + str(root) + '\n')
            passed = load('ci-execute').execute_unit(ROOT, head, base, ci.encode(plan), args.unit,
                root / 'receipts', root / 'diagnostics', identity=identity)
            return 0 if passed else 1
        else:
            ci.require(args.artifacts is not None)
            normalize_artifact_directories(args.artifacts.resolve(strict=True), plan)
            result = ci.aggregate(head, base, os.environ['CI_PLAN'].encode(),
                os.environ['CI_NEEDS_JSON'].encode(), args.artifacts, **identity)
            print(ci.encode(result).decode())
        return 0
    except (ci.InvalidEvidence, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('Mandatory hosted CI refused: ' + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
