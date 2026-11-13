#!/usr/bin/env -S python3 -I
"""Read-only development-source checks; no installed or publisher qualification."""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import sys

MAX_FILE = 16 * 1024 * 1024
REQUIRED = ('Package.swift', 'Resources/Info.plist', 'Resources/release-contract.json', 'Resources/command-graphs.json',
            'Sources/ShadowSyncCore/ReleaseIdentity.swift',
            'Sources/ShadowSyncCore/LifecycleCoordinatorMain.swift',
            'Sources/ShadowSyncCore/ProductionInstallationDriver.swift',
            'Sources/ShadowSyncLifecycleCoordinator/main.swift',
            'Resources/com.kleinperkins.shadow-sync.plist.template', 'Resources/ShadowSync.icns',
            'THIRD_PARTY_NOTICES.md', 'scripts/build-app.sh', 'scripts/source-doctor.sh',
            'scripts/verify-fixture-root.py', 'install.sh')
DIRECTORIES = ('Sources/ShadowSyncCatalog', 'Sources/ShadowSyncCore',
               'Sources/ShadowSyncApp', 'Sources/ShadowSyncLifecycleCoordinator', 'Tests/ShadowSyncSelfTests')


def require(condition):
    if not condition:
        raise ValueError('standalone development source contract is invalid')


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result


def physical_directory(root, relative):
    current = root
    require(not current.is_symlink() and current.is_dir())
    for part in Path(relative).parts:
        require(part not in ('', '.', '..') and '/' not in part)
        current /= part
        require(stat.S_ISDIR(current.lstat().st_mode))
    return current


def read(root, relative):
    path = Path(relative)
    parent = physical_directory(root, str(path.parent)) if str(path.parent) != '.' else root
    fd = os.open(parent / path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= MAX_FILE)
        data = bytearray()
        while len(data) <= MAX_FILE:
            chunk = os.read(fd, min(65536, MAX_FILE + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(len(data) == before.st_size and identity(before) == identity(os.fstat(fd))
                and identity(before) == identity((parent / path.name).lstat()))
        return bytes(data)
    finally:
        os.close(fd)


def verify(root):
    root = Path(root)
    require(root.is_absolute() and root.is_dir() and not root.is_symlink())
    require(not any(os.path.lexists(root / name) for name in ('.build', '.swiftpm', 'payload')))
    files = {name: read(root, name) for name in REQUIRED}
    for name in DIRECTORIES:
        physical_directory(root, name)
    for name in ('install.sh', 'scripts/build-app.sh', 'scripts/source-doctor.sh'):
        require((root / name).stat().st_mode & 0o111 != 0)
    package = files['Package.swift'].decode()
    require(package.startswith('// swift-tools-version: 6.2\n')
            and '.macOS("26.0")' in package and 'swiftLanguageModes: [.v6]' in package
            and not re.search(r'\.package\s*\(', package)
            and re.findall(r'\.executable\(name: "([^"]+)", targets: \["([^"]+)"\]\)', package)
                == [('ShadowSync', 'ShadowSyncApp'), ('ShadowSyncLifecycleCoordinator', 'ShadowSyncLifecycleCoordinator')]
            and len(re.findall(r'\.executable\(name:', package)) == 2)
    info = plistlib.loads(files['Resources/Info.plist'])
    expected = {'CFBundleDisplayName': 'ShadowSync', 'CFBundleName': 'ShadowSync',
                'CFBundleExecutable': 'ShadowSync', 'CFBundleIdentifier': 'com.kleinperkins.shadow-sync',
                'CFBundleIconFile': 'ShadowSync.icns', 'CFBundlePackageType': 'APPL',
                'LSMinimumSystemVersion': '26.0', 'ShadowSyncArchitecture': 'arm64',
                'ShadowSyncBuildMode': 'production', 'ShadowSyncReleaseSchema': 'shadow-sync-release/v2'}
    require(type(info) is dict and all(type(info.get(k)) is str and info[k] == v for k, v in expected.items()))
    require(type(info.get('CFBundleShortVersionString')) is str
            and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', info['CFBundleShortVersionString']))
    build = info.get('CFBundleVersion')
    require(type(build) is str and re.fullmatch(r'[1-9][0-9]*', build) and 15 <= int(build) <= 2147483647)
    for key, length in [('ShadowSyncSourceRevision', 40), ('ShadowSyncSourceInputSHA256', 64),
                        ('ShadowSyncReleaseContractSHA256', 64)]:
        require(info.get(key) == '0' * length)  # Release tooling stamps staged artifacts, never source templates.
    compiled_team = re.findall(r'public static let publisherTeamIdentifier = "([A-Z0-9]{10})"',
                               files['Sources/ShadowSyncCore/ReleaseIdentity.swift'].decode())
    require(len(compiled_team) == 1)
    contract = json.loads(files['Resources/release-contract.json'], object_pairs_hook=pairs)
    require(contract == {'schema': 'shadow-sync-release-contract/v1', 'metadata_schema': 'shadow-sync-release/v2',
        'repository': 'KleinPerkins/shadow-sync', 'bundle_identifier': 'com.kleinperkins.shadow-sync',
        'executable': 'ShadowSync', 'product': 'ShadowSync', 'architectures': ['arm64'],
        'minimum_system_version': '26.0', 'version_format': 'three-canonical-unsigned-integers',
        'build_format': 'canonical-integer-15-through-2147483647', 'normal_update_authority': 'Sparkle',
        'publisher_verification': 'Developer-ID-Application-hardened-runtime-secure-timestamp-notarization',
        'lifecycle_authority': 'ShadowSyncLifecycleCoordinator', 'publisher_team_identifier': compiled_team[0],
        'command_graphs_sha256': hashlib.sha256(files['Resources/command-graphs.json']).hexdigest()})
    agent = plistlib.loads(files['Resources/com.kleinperkins.shadow-sync.plist.template'])
    require(agent == {'Label': 'com.kleinperkins.shadow-sync',
        'ProgramArguments': ['__EXECUTABLE_PATH__', '--managed-host'], 'RunAtLoad': False, 'KeepAlive': False,
        'ProcessType': 'Interactive', 'LimitLoadToSessionType': 'Aqua'}
        and type(agent['RunAtLoad']) is bool and type(agent['KeepAlive']) is bool)
    core = physical_directory(root, 'Sources/ShadowSyncCore')
    for current, directories, names in os.walk(core, followlinks=False):
        require(all(stat.S_ISDIR((Path(current) / name).lstat().st_mode) for name in directories))
        for name in names:
            if name.endswith('.swift'):
                body = read(root, str((Path(current) / name).relative_to(root))).decode()
                require(not re.search(r'\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?AppKit\b', body))
    return ['source-layout', 'swift-package-boundary', 'release-template', 'manual-launch-agent', 'core-ui-boundary']



def verify_export(root):
    """Check every imported payload byte and Git executable mode."""
    root = Path(root)
    manifest = json.loads(read(root, 'Resources/source-export.json'), object_pairs_hook=pairs)
    require(type(manifest) is dict and manifest.get('schema') == 'shadow-sync-source-export/v1'
            and manifest.get('repository') == 'KleinPerkins/shadow-sync')
    entries = manifest.get('files')
    require(type(entries) is list and 0 < len(entries) <= 8192)
    observed = set()
    for entry in entries:
        require(type(entry) is dict and set(entry) == {'path', 'mode', 'sha256'})
        name = entry['path']
        require(type(name) is str and 0 < len(name) <= 4096 and name not in observed
                and not name.startswith('/') and '\\' not in name
                and all(part not in ('', '.', '..') for part in name.split('/'))
                and not any(ord(c) < 32 or ord(c) == 127 for c in name)
                and name != 'Resources/source-export.json')
        require(entry['mode'] in ('100644', '100755')
                and type(entry['sha256']) is str
                and re.fullmatch(r'[a-f0-9]{64}', entry['sha256']) is not None)
        data = read(root, name)
        require(hashlib.sha256(data).hexdigest() == entry['sha256']
                and bool((root / name).stat().st_mode & 0o111) == (entry['mode'] == '100755'))
        observed.add(name)
    return len(observed)


def main():
    if not sys.flags.isolated or len(sys.argv) != 1:
        sys.stderr.write('Run verify-source-contract.py with isolated Python and no arguments.\n')
        return 2
    try:
        for case in verify(Path(__file__).resolve().parent.parent):
            print('PASS source-contract/' + case)
        verify_export(Path(__file__).resolve().parent.parent)
        print('PASS source-contract/export-payload')
        print('Development source check only; no installation, native runtime, signing or release qualification.')
        return 0
    except (ValueError, OSError, UnicodeError, TypeError, KeyError, OverflowError, plistlib.InvalidFileException):
        sys.stderr.write('Standalone development source check failed.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
