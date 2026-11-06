#!/usr/bin/env -S python3 -I
"""Native coordinator argument/ad-hoc refusal checks. No installation or signing."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess


def require(ok, message):
    if not ok:
        raise ValueError(message)


def contained(root, path):
    require(path.is_absolute() and '..' not in path.parts and path.is_relative_to(root), 'binary outside fixture root')
    current = root
    for part in path.relative_to(root).parts:
        current /= part
        node = current.lstat()
        require(not stat.S_ISLNK(node.st_mode) and node.st_uid == os.getuid(), 'unsafe fixture node')
    require(path.resolve() == path and path.is_file() and path.stat().st_nlink == 1
            and os.access(path, os.X_OK), 'invalid fixture binary')


def verify(root, testing, bundle):
    require(str(root).startswith('/private/tmp/') and root.resolve() == root, 'unsafe fixture root')
    node = root.lstat()
    require(stat.S_ISDIR(node.st_mode) and node.st_uid == os.getuid()
            and stat.S_IMODE(node.st_mode) == 0o700, 'fixture root must be private')
    production = bundle / 'Contents/Helpers/ShadowSyncLifecycleCoordinator'
    contained(root, testing)
    contained(root, production)
    require(bundle.name == 'ShadowSync.app', 'unexpected fixture bundle')
    metadata = subprocess.run(['/usr/bin/codesign', '-dvv', str(production)], capture_output=True, timeout=10)
    require(metadata.returncode == 0 and b'Signature=adhoc' in metadata.stderr
            and b'Identifier=com.kleinperkins.shadow-sync.lifecycle-coordinator' in metadata.stderr.splitlines(),
            'negative fixture must be the ad-hoc coordinator')
    cases = [([], 64), (['--unknown'], 64), (['--verify-distribution', '--extra'], 64),
             (['--help', '--extra'], 64), (['--initialize-fresh-state'], 64), (['--help'], 0),
             (['--shadow-sync-command-custodian'], 70), (['--shadow-sync-command-custodian', '--extra'], 64)]
    passed = []
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'HOME': str(root)}
    for label, binary, verify_status in [('testing', testing, 78), ('adhoc', production, 1)]:
        for index, (args, expected) in enumerate(cases + [(['--verify-distribution'], verify_status)], 1):
            result = subprocess.run([str(binary), *args], cwd=root, env=env, capture_output=True, timeout=10)
            require(result.returncode == expected, 'coordinator route returned wrong status')
            if '--shadow-sync-command-custodian' in args:
                require(result.stdout == b'' and result.stderr == b'', 'custodian refusal leaked detail')
            elif expected == 64:
                require(result.stdout == b'' and result.stderr == b'ShadowSync lifecycle coordinator arguments are invalid.\n', 'argument error leaked detail')
            elif expected == 78:
                require(result.stdout == b'' and result.stderr == b'Testing coordinators cannot verify production distributions.\n', 'testing authority boundary changed')
            elif expected == 1:
                require(result.stdout == b'' and result.stderr == b'ShadowSync distribution verification failed.\n', 'ad-hoc publisher was accepted or leaked detail')
            else:
                require(result.stdout == b'ShadowSyncLifecycleCoordinator --verify-distribution\n' and result.stderr == b'', 'help entered verification')
            case = f'coordinator-entry/{label}-{index:02}'
            print('PASS ' + case, flush=True); passed.append(case)
    return {'schema': 'shadow-sync-coordinator-entry-tests/v1', 'cases': passed, 'count': len(passed),
            'scope': 'Native argument dispatch and testing/ad-hoc refusal only. Signed-positive, installer, migration, update and native UAT remain open.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixture-root', type=Path, required=True)
    parser.add_argument('--testing-binary', type=Path, required=True)
    parser.add_argument('--production-bundle', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.fixture_root, args.testing_binary, args.production_bundle), sort_keys=True))
