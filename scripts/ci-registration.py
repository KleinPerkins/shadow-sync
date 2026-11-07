#!/usr/bin/env python3
"""Generate/check the sole mandatory CI registration from canonical discovery."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / 'config/ci-suites.json'


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def generate():
    ci = load('ci-shards')
    value = dict(schema='shadow-sync-test-shards/v1', coverage={
        'schema': 'shadow-sync-ci-coverage/v1', 'jobs': {job: [] for job in ci.coverage.JOBS}, 'suites': {}},
        shards={'quality': 2, 'compile-package': 1, 'runtime-safety': 4,
                'native-and-lifecycle': 2, 'package-contract': 1}, commands={})
    def add(job, name, cases, kind, selector=None, seconds=300):
        ci.require(name not in value['commands'])
        value['coverage']['jobs'][job].append(name)
        value['coverage']['suites'][name] = {'kind': ci.coverage.JOBS[job], 'cases': cases}
        argv = ['python3', '-I', '-B', 'scripts/ci-suite.py', kind]
        if selector is not None:
            argv += ['--suite', selector]
        value['commands'][name] = {'argv': argv, 'timeout_seconds': seconds}
    add('quality', 'source-contract', ['source-contract/' + case for case in (
        'source-layout', 'swift-package-boundary', 'release-template', 'manual-launch-agent',
        'core-ui-boundary', 'export-payload', 'technical-identity', 'registered-coverage')], 'source')
    for module, cases in load('python-test-suites').discover(ROOT / 'Tests/Tooling').items():
        add('quality', 'tooling-' + module.replace('_', '-'), [case.id() for case in cases], 'tooling', module)
    add('compile-package', 'application-builds', ['compile/testing', 'compile/test-target-testing', 'compile/production', 'compile/test-target-production'], 'compile', seconds=2400)
    for row in load('runtime-suite-inventory').inspect(ROOT)['suites']:
        add('runtime-safety', 'runtime-' + row['id'], row['cases'], 'runtime', row['id'], seconds=3600)
    for row in load('run-native-appkit').catalog()[2]:
        add('native-and-lifecycle', 'native-' + row['id'], row['cases'], 'native', row['id'], seconds=1800)
    add('package-contract', 'application-package', ['package/' + name for name in (
        'identity', 'architecture', 'deployment-target', 'nested-signatures', 'resources',
        'production-seam-exclusion', 'updater-disabled')], 'package', seconds=2400)
    ci.registration(ci.encode(value))
    return value


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def verify():
    if PATH.read_bytes() != encoded(generate()):
        raise ValueError('CI registration differs from canonical suite discovery')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    value = generate()
    if args.write:
        PATH.write_bytes(encoded(value))
    else:
        verify()
    print(json.dumps({'suites': len(value['commands']),
        'cases': sum(len(suite['cases']) for suite in value['coverage']['suites'].values()),
        'jobs': {job: len(suites) for job, suites in value['coverage']['jobs'].items()}}))


if __name__ == '__main__':
    main()
