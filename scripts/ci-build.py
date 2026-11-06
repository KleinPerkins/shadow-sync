#!/usr/bin/env python3
"""Build each compatible CI job once in a private disposable directory.

No credentials, installation, source cache, shared test state or release claims.
All reuse within this unit is bound to the current source and exact output bytes.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ('ShadowSync', 'ShadowSyncSelfTest', 'ShadowSyncLifecycleCoordinator')


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(argv, *, timeout=600):
    return subprocess.run(argv, cwd=ROOT, check=True, capture_output=True,
                          timeout=timeout).stdout.decode('utf-8')


def publisher_fixture(root):
    fixture = ROOT / 'Tests/Fixtures/PublisherExecutionFixture.c'
    result = subprocess.run(['/usr/bin/xcrun', 'clang', '-arch', 'arm64', '-Os',
        '-DSHADOW_SYNC_TESTING', '-o', str(root / 'publisher-executable'), str(fixture)],
        cwd=ROOT, capture_output=True, timeout=120)
    (root / 'publisher-build.log').write_bytes(result.stdout + result.stderr)
    require(result.returncode == 0, 'Publisher fixture build failed; see publisher-build.log')
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(root / 'publisher-executable')])
    return dict(sha256=sha(root / 'publisher-executable'), source_sha256=sha(fixture))


def regular_inventory(root):
    entries = {}
    for path in sorted(root.rglob('*')):
        info = path.lstat()
        require(not stat.S_ISLNK(info.st_mode), 'Unexpected product symlink')
        if stat.S_ISDIR(info.st_mode):
            continue
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'Unsafe product entry')
        entries[path.relative_to(root).as_posix()] = {'sha256': sha(path), 'mode': stat.S_IMODE(info.st_mode)}
    require(bool(entries), 'Empty build')
    return entries


def toolchain():
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Requires macOS arm64')
    require(run(['/usr/bin/sw_vers', '-productVersion']).strip().split('.')[0] == '26', 'Requires macOS 26')
    require(os.environ.get('DEVELOPER_DIR') == '/Applications/Xcode_26.6.app/Contents/Developer',
            'Explicit qualified Xcode selection required')
    xcode = run(['/usr/bin/xcodebuild', '-version']).strip()
    require(xcode == 'Xcode 26.6\nBuild version 17F113', 'Xcode identity drift')
    return dict(xcode=xcode, swift=run(['/usr/bin/xcrun', 'swift', '--version']).strip(),
                sdk=run(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version']).strip(),
                os=run(['/usr/bin/sw_vers', '-productVersion']).strip(), architecture='arm64',
                image_os=os.environ.get('ImageOS', ''), image_version=os.environ.get('ImageVersion', ''))


def verify(record, root, context):
    require(record['schema'] == 'shadow-sync-ci-build/v1'
            and record['source_sha256'] == context['source_sha256']
            and record['revision'] == context['revision'], 'Build source binding mismatch')
    require(load('ci-shards').git_source_digest(ROOT, context['revision']) == context['source_sha256'],
            'Build source changed')
    require(record['toolchain'] == toolchain(), 'Build toolchain changed')
    for mode, item in record['builds'].items():
        require(regular_inventory(root / mode / 'package') == item['package'], 'Package changed')
        require(all(sha(Path(item['products']) / name) == digest for name, digest in item['binaries'].items()),
                'Build output changed')
    if 'compile_targets' in record:
        require(set(record['compile_targets']) == {'testing', 'production'}, 'Compile target coverage missing')
        for mode, item in record['compile_targets'].items():
            require(item['source_sha256'] == sha(ROOT / 'Tests/ShadowSyncCompileTests/CompileGate.swift')
                    and item['log_sha256'] == sha(root / ('compile-' + mode + '.log')),
                    'Compile target evidence changed')
    if 'policy' in record:
        builder = load('build-policy-runtime')
        receipt = json.loads((root / 'policy/runtime-build.json').read_bytes())
        require(sha(root / 'policy/runtime-build.json') == record['policy']['receipt_sha256']
                and receipt['builder_sha256'] == sha(ROOT / 'scripts/build-policy-runtime.py')
                and receipt['source_pin_sha256'] == sha(ROOT / 'Resources/policy-runtime-source.json')
                and receipt['stdlib_archive']['driver_sha256'] == sha(ROOT / 'scripts/compile-runtime-bytecode.py')
                and builder.inventory(root / 'policy/Python.framework') == receipt['output_entries'],
                'Policy fixture changed')
        require(sha(root / 'publisher-executable') == record['publisher']['sha256']
                and sha(ROOT / 'Tests/Fixtures/PublisherExecutionFixture.c') == record['publisher']['source_sha256'],
                'Publisher fixture changed')
    return record


def prepare(root, context, job):
    root = Path(root)
    require(root.is_absolute() and root.resolve() == root and str(root).startswith('/private/tmp/'),
            'Build root must be a private physical temporary path')
    receipt = root / 'build.json'
    if receipt.exists():
        return verify(json.loads(receipt.read_bytes()), root, context)
    require(not root.exists(), 'Partial build retained; use a new execution, never overwrite')
    root.mkdir(mode=0o700)
    started = time.monotonic()
    record = dict(schema='shadow-sync-ci-build/v1', source_sha256=context['source_sha256'],
                  revision=context['revision'], toolchain=toolchain(), builds={})
    modes = ('testing', 'production') if job in ('compile-package', 'package-contract') else ('testing',)
    for mode in modes:
        parent = root / mode; parent.mkdir(mode=0o700)
        command = ['/bin/bash', str(ROOT / 'scripts/build-app.sh'),
            '--scratch-path', str(parent / 'scratch'), '--output-dir', str(parent / 'package'),
            '--source-revision', context['revision'], '--source-input-sha256', context['source_sha256']]
        if mode == 'testing':
            command.append('--testing')
        result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=1500)
        (parent / 'build.log').write_bytes(result.stdout + result.stderr)
        require(result.returncode == 0, 'Application compilation/packaging failed')
        products = run(['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(ROOT),
            '--scratch-path', str(parent / 'scratch'), '--configuration', 'release', '--show-bin-path']).strip()
        require(Path(products).is_absolute(), 'Missing product directory')
        record['builds'][mode] = dict(products=products,
            binaries={name: sha(Path(products) / name) for name in PRODUCTS},
            package=regular_inventory(parent / 'package'))
    if job == 'compile-package':
        record['compile_targets'] = {}
        for mode in ('testing', 'production'):
            # @testable imports require a separate compile-only configuration.
            # It cannot substitute for the real production application build.
            command = ['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(ROOT),
                '--scratch-path', str(root / ('compile-' + mode)), '--configuration', 'release',
                '--target', 'ShadowSyncCompileTests', '-Xswiftc', '-enable-testing']
            if mode == 'testing':
                command += ['-Xswiftc', '-DSHADOW_SYNC_TESTING']
            result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=1200)
            log = root / ('compile-' + mode + '.log')
            log.write_bytes(result.stdout + result.stderr)
            require(result.returncode == 0, 'Compile-only test target failed')
            record['compile_targets'][mode] = dict(command=command, log_sha256=sha(log),
                source_sha256=sha(ROOT / 'Tests/ShadowSyncCompileTests/CompileGate.swift'))
    if job == 'runtime-safety':
        pin = json.loads((ROOT / 'Resources/policy-runtime-source.json').read_bytes())
        package = root / 'python.pkg'
        require(pin['package_url'].startswith('https://www.python.org/ftp/python/'), 'Unexpected dependency origin')
        run(['/usr/bin/curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
             '--connect-timeout', '30', '--max-time', '300', '--output', str(package), pin['package_url']], timeout=330)
        require(package.stat().st_size == pin['package_bytes'] and sha(package) == pin['package_sha256'],
                'Dependency bytes differ from reviewed pin')
        result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'scripts/build-policy-runtime.py'),
            '--package', str(package), '--output', str(root / 'policy'),
            '--signing-identity', '-', '--allow-ad-hoc-fixture'], cwd=ROOT, capture_output=True, timeout=1200)
        (root / 'policy-build.log').write_bytes(result.stdout + result.stderr)
        require(result.returncode == 0, 'Policy fixture build failed')
        record['policy'] = dict(receipt_sha256=sha(root / 'policy/runtime-build.json'))
        record['publisher'] = publisher_fixture(root)
    record['build_seconds'] = round(time.monotonic() - started, 6)
    verify(record, root, context)
    with receipt.open('x') as stream:
        json.dump(record, stream, sort_keys=True, indent=2); stream.write('\n')
    return record
