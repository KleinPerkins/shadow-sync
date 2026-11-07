#!/usr/bin/env python3
"""Thin canonical suite entrypoints used by the mandatory CI registration."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def package_contract(build, work, record):
    for mode in ('testing', 'production'):
        app = work / mode / 'package/ShadowSync.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        build.require(info['CFBundleIdentifier'] == 'com.kleinperkins.shadow-sync'
            and info['CFBundleExecutable'] == 'ShadowSync' and info['ShadowSyncBuildMode'] == mode
            and info['ShadowSyncSourceRevision'] == record['revision']
            and info['ShadowSyncSourceInputSHA256'] == record['source_sha256']
            and info['LSMinimumSystemVersion'] == '26.0', 'Release metadata mismatch')
        for relative in ('Contents/MacOS/ShadowSync', 'Contents/Helpers/ShadowSyncLifecycleCoordinator'):
            path = app / relative
            build.require(build.run(['/usr/bin/lipo', '-archs', str(path)]).strip() == 'arm64', 'Wrong architecture')
            commands = build.run(['/usr/bin/otool', '-l', str(path)])
            build.require(re.search(r'\bminos 26[.]0\b', commands) is not None, 'Wrong deployment target')
            build.run(['/usr/bin/codesign', '--verify', '--strict', str(path)])
        build.run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
        for name in ('ShadowSync.icns', 'release-contract.json'):
            build.require(build.sha(app / 'Contents/Resources' / name) == build.sha(ROOT / 'Resources' / name),
                          'Bundled resource differs')
        build.require(build.sha(app / 'Contents/Resources/THIRD_PARTY_NOTICES.md') ==
                      build.sha(ROOT / 'THIRD_PARTY_NOTICES.md'), 'Missing source-bound notices')
    for name in ('identity', 'architecture', 'deployment-target', 'nested-signatures', 'resources'):
        print('PASS package/' + name, flush=True)
    markers = json.loads((ROOT / 'Tests/Fixtures/production-test-markers.json').read_bytes())
    build.require(markers['schema'] == 'shadow-sync-production-test-markers/v1'
                  and len(markers['markers']) == len(set(markers['markers'])) and bool(markers['markers']),
                  'Invalid production exclusion roster')
    testing = Path(record['builds']['testing']['products']) / 'ShadowSyncSelfTest'
    raw = testing.read_bytes()
    missing = [value for value in markers['markers'] if value.encode() not in raw]
    build.require(not missing, 'Testing positive control missing '
                  f'({len(missing)}/{len(markers["markers"])}): ' + json.dumps(missing, ensure_ascii=True))
    demangler = build.run(['/usr/bin/xcrun', '--find', 'swift-demangle']).strip()
    pattern = re.compile(r'\bShadowSyncCore\.PolicyAuthorityFile\.\(Revalidation in _[A-F0-9]+\)\.afterRead :')
    def fields(path):
        names = subprocess.run(['/usr/bin/nm', '-j', str(path)], check=True, capture_output=True, timeout=30).stdout
        build.require(len(names) <= 16_777_216, 'Symbol limit exceeded')
        values = subprocess.run([demangler], input=names, check=True, capture_output=True, timeout=30).stdout
        build.require(len(values) <= 33_554_432, 'Demangled symbol limit exceeded')
        return values.decode().splitlines()
    positive = fields(testing)
    build.require(any(pattern.search(line) for line in positive)
        and any('.writeFixtureAtomically(to:' in line for line in positive), 'Missing positive seam controls')
    for name in build.PRODUCTS:
        path = Path(record['builds']['production']['products']) / name
        data = path.read_bytes()
        build.require(not any(value.encode() in data for value in markers['markers']), 'Testing string in production')
        build.require(not any(pattern.search(line) or '.writeFixtureAtomically(to:' in line for line in fields(path)),
                      'Testing implementation in production')
    print('PASS package/production-seam-exclusion', flush=True)
    build.require('Sparkle' not in (ROOT / 'Package.swift').read_text()
        and not any('Sparkle' in name for item in record['builds'].values() for name in item['package']),
        'MVP updater must remain disabled')
    print('PASS package/updater-disabled', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=('source', 'tooling', 'compile', 'runtime', 'native', 'package'))
    parser.add_argument('--suite')
    args = parser.parse_args()
    cleanup = False
    passed = False
    try:
        context = json.loads(os.environ['SHADOW_SYNC_CI_CONTEXT'])
        evidence = Path(os.environ['SHADOW_SYNC_CI_EVIDENCE'])
        if args.kind == 'source':
            contract = load('verify-source-contract')
            for case in contract.verify(ROOT):
                print('PASS source-contract/' + case, flush=True)
            contract.verify_export(ROOT); print('PASS source-contract/export-payload', flush=True)
            subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'scripts/verify-technical-identity.py'),
                            '--root', str(ROOT)], check=True, capture_output=True, timeout=60)
            print('PASS source-contract/technical-identity', flush=True)
            load('ci-registration').verify()
            print('PASS source-contract/registered-coverage', flush=True)
            passed = cleanup = True
        elif args.kind == 'tooling':
            tests = load('python-test-suites')
            passed = tests.execute(tests.discover(ROOT / 'Tests/Tooling'), [args.suite],
                                   lambda line: print(line, flush=True))
            # A tearDown/doCleanups failure does not establish safe admission.
            cleanup = passed
        else:
            build = load('ci-build')
            work = Path(os.environ['SHADOW_SYNC_CI_WORK'])
            job = {'compile': 'compile-package', 'runtime': 'runtime-safety',
                   'native': 'native-and-lifecycle', 'package': 'package-contract'}[args.kind]
            record = build.prepare(work, context, job)
            if args.kind == 'runtime':
                passed, cleanup = load('ci-runtime').run_suite(args.suite, evidence / 'runtime', work, record, context)
            elif args.kind == 'native':
                native = load('run-native-appkit')
                old, manifest, rows = native.catalog()
                selected = [row for row in rows if row['id'] == args.suite]
                build.require(len(selected) == 1, 'Unknown native suite')
                binary = Path(record['builds']['testing']['products']) / 'ShadowSync'
                previous = {number: signal.signal(number, native.record_interrupt)
                            for number in (signal.SIGINT, signal.SIGTERM)}
                try:
                    native.execute(selected[0], binary, build.sha(binary), evidence, old, manifest)
                    passed = cleanup = not native.INTERRUPTED
                finally:
                    for number, handler in previous.items():
                        signal.signal(number, handler)
            elif args.kind == 'compile':
                for mode in ('testing', 'production'):
                    build.require(set(record['builds'][mode]['binaries']) == set(build.PRODUCTS), 'Incomplete products')
                    print('PASS compile/' + mode, flush=True)
                    build.require(mode in record['compile_targets'], 'Missing compile-only test target')
                    print('PASS compile/test-target-' + mode, flush=True)
                passed = cleanup = True
            else:
                package_contract(build, work, record)
                passed = cleanup = True
            build.verify(record, work, context)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Suite failed: ' + type(error).__name__ + ': ' + str(error), file=sys.stderr)
        passed = False
    finally:
        load('ci-execute').command_completed(cleanup)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
