"""Exercise source-only checks and retirement before any production side effect."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('source_contract', ROOT / 'scripts/verify-source-contract.py')
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class SourceInstallationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-source-check-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in source.REQUIRED:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            # Use actual source templates; no fixture can silently drift from them.
            shutil.copyfile(ROOT / name, target)
            target.chmod(0o700 if name.endswith('.sh') else 0o600)
        for name in source.DIRECTORIES:
            (self.root / name).mkdir(parents=True, exist_ok=True)
        (self.root / 'Sources/ShadowSyncCore/Neutral.swift').write_text('import Foundation\n')

    def test_standalone_check_needs_no_capability_metadata_or_git_checkout(self):
        self.assertFalse((self.root / '.git').exists())
        self.assertFalse((self.root / 'meta.yml').exists())
        self.assertFalse((self.root / 'tool.yml').exists())
        self.assertEqual(source.verify(self.root), ['source-layout', 'swift-package-boundary',
            'release-template', 'manual-launch-agent', 'core-ui-boundary'])

    def test_coordinator_product_cannot_be_missing_or_redirected(self):
        path = self.root / 'Package.swift'
        original = path.read_text()
        declaration = '.executable(name: "ShadowSyncLifecycleCoordinator", targets: ["ShadowSyncLifecycleCoordinator"]),'
        for changed in (original.replace(declaration, ''),
                        original.replace(declaration, declaration.replace('["ShadowSyncLifecycleCoordinator"]', '["ShadowSyncApp"]'))):
            path.write_text(changed)
            with self.assertRaises(ValueError): source.verify(self.root)
        path.write_text(original)
        (self.root / 'Sources/ShadowSyncLifecycleCoordinator/main.swift').unlink()
        with self.assertRaises(OSError): source.verify(self.root)

    def test_all_production_routes_refuse_without_a_source_tree(self):
        isolated = self.root / 'empty-source'
        isolated.mkdir()
        script = isolated / 'install.sh'
        shutil.copyfile(ROOT / 'install.sh', script)
        for args in ([], ['--apply'], ['--repair'], ['--uninstall'], ['--source-identity'],
                     ['--build-release-check'], ['--doctor'], ['--doctor', '--home', '/']):
            with self.subTest(args=args):
                result = subprocess.run(['/bin/bash', str(script), *args], cwd=isolated,
                    env={'PATH': '/usr/bin:/bin', 'HOME': str(isolated)}, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 64)
                self.assertIn(b'retired', result.stderr)
                self.assertEqual(sorted(p.name for p in isolated.iterdir()), ['install.sh'])

        for name in ('verify-m6.sh', 'installer-scratch-cleanup-tests.sh'):
            retired = isolated / name
            shutil.copyfile(ROOT / 'scripts' / name, retired)
            before = sorted(p.name for p in isolated.iterdir())
            for args in ([], ['--reuse-current-foundation-evidence'], ['--live']):
                with self.subTest(retired_verifier=name, args=args):
                    result = subprocess.run(['/bin/bash', str(retired), *args], cwd=isolated,
                        env={'PATH': '/usr/bin:/bin', 'HOME': str(isolated)}, capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 64)
                    self.assertIn(b'retired entrypoint', result.stderr)
                    self.assertEqual(sorted(p.name for p in isolated.iterdir()), before)

    def test_invalid_or_extra_arguments_cannot_select_an_old_mutation_path(self):
        for args in (['--check', '--apply'], ['--help', '--apply'], ['--unknown'],
                     ['--m1-stage'], ['--doctor', '--test-root']):
            result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), *args],
                env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)

    def test_fixture_root_rejects_live_namespace_and_lexical_escapes(self):
        for path in ('/', 'relative', '/dev/null', '/private/tmp/../outside',
                     '/private/tmp/./fixture', '/private/tmp//fixture', '/private/tmp/fixture\n'):
            result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), '--doctor', '--test-root', path],
                env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)

    def test_required_file_missing_linked_hardlinked_or_nonregular_refuses(self):
        path = self.root / 'Resources/Info.plist'
        data = path.read_bytes()
        path.unlink()
        with self.assertRaises((ValueError, OSError)): source.verify(self.root)
        other = self.root / 'original'; other.write_bytes(data)
        path.symlink_to(other)
        with self.assertRaises((ValueError, OSError)): source.verify(self.root)
        path.unlink(); os.link(other, path)
        with self.assertRaises((ValueError, OSError)): source.verify(self.root)
        path.unlink(); os.mkfifo(path)
        with self.assertRaises((ValueError, OSError)): source.verify(self.root)

    def test_source_directory_alias_and_swift_build_residue_refuse(self):
        for name in ('.build', '.swiftpm', 'payload'):
            path = self.root / name; path.mkdir()
            with self.assertRaises(ValueError): source.verify(self.root)
            path.rmdir()
        core = self.root / 'Sources/ShadowSyncCore'
        core.rename(self.root / 'original-core'); core.symlink_to(self.root / 'original-core')
        with self.assertRaises(ValueError): source.verify(self.root)

    def test_changed_platform_toolchain_dependency_or_core_ui_boundary_refuses(self):
        path = self.root / 'Package.swift'; original = path.read_text()
        for changed in (original.replace('6.2', '6.1'), original.replace('26.0', '15.0'),
                        original.replace('[.v6]', '[.v5]'), original + '\n.package(url: "fixture", from: "1.0.0")\n'):
            path.write_text(changed)
            with self.assertRaises(ValueError): source.verify(self.root)
        path.write_text(original)
        for declaration in ('import AppKit', 'import class AppKit.NSView', 'import struct AppKit.NSRect',
                            '@preconcurrency import AppKit', 'import func AppKit.NSBeep'):
            (self.root / 'Sources/ShadowSyncCore/Neutral.swift').write_text(declaration + '\n')
            with self.assertRaises(ValueError): source.verify(self.root)

    def test_fixture_doctor_rejects_descendant_alias_before_stub_execution(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-doctor-', dir='/private/tmp') as temporary:
            root = Path(temporary); root.chmod(0o700)
            external = root / 'unrelated'; external.mkdir(mode=0o700)
            (root / 'launchctl-stub').write_text('#!/bin/sh\nexit 99\n')
            (root / 'launchctl-stub').chmod(0o700)
            for relative in ('home', 'home/Applications', 'home/Library', 'home/Library/LaunchAgents',
                             'home/.local', 'home/.local/state', 'home/.local/state/shadow-sync'):
                path = root / relative; path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.symlink_to(external)
                for script, args in [('install.sh', ['--doctor', '--test-root', str(root)]),
                        ('scripts/source-doctor.sh', ['--home', str(root / 'home'), '--launchctl', str(root / 'launchctl-stub')])]:
                    result = subprocess.run(['/bin/bash', str(ROOT / script), *args],
                        env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(b'Development fixture root is unsafe', result.stderr)
                    self.assertEqual(result.stdout, b'')
                path.unlink()

    def test_absent_fixture_doctor_and_direct_live_refusal(self):
        def check(operation, script, args, expected, absent=False):
            detail = {'operation': operation, 'phase': 'run', 'exit_code': None}
            try:
                result = subprocess.run(['/bin/bash', str(ROOT / script), *args],
                    env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=5)
                detail.update(phase='returncode', exit_code=result.returncode)
                self.assertEqual(result.returncode, expected)
                if absent:
                    detail['phase'] = 'output'
                    self.assertIn(b'product is absent', result.stdout)
            except (AssertionError, subprocess.TimeoutExpired, OSError) as error:
                # These fixed fields are the only diagnostics admitted by the runner.
                error.shadow_sync_diagnostic = detail
                raise

        with tempfile.TemporaryDirectory(prefix='shadow-sync-doctor-', dir='/private/tmp') as temporary:
            root = Path(temporary); root.chmod(0o700)
            stub = root / 'launchctl-stub'
            stub.write_text('#!/bin/sh\nprintf "Could not find service\\n" >&2\nexit 113\n'); stub.chmod(0o700)
            for operation, script, args in [
                    ('fixture-install', 'install.sh', ['--doctor', '--test-root', str(root)]),
                    ('fixture-direct', 'scripts/source-doctor.sh',
                     ['--home', str(root / 'home'), '--launchctl', str(stub)])]:
                check(operation, script, args, 0, absent=True)
            for operation, home in [('live-home-refusal', '/'),
                                    ('live-launchctl-refusal', str(root / 'home'))]:
                check(operation, 'scripts/source-doctor.sh',
                      ['--home', home, '--launchctl', '/bin/launchctl'], 64)

    def test_staged_bundle_aliases_refuse_before_diagnostic_tools(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-doctor-', dir='/private/tmp') as temporary:
            root = Path(temporary); root.chmod(0o700)
            external = root / 'unrelated'; external.mkdir(mode=0o700)
            app = root / 'home/Applications/ShadowSync.app'
            app.mkdir(mode=0o700, parents=True)
            (root / 'home').chmod(0o700); (root / 'home/Applications').chmod(0o700)
            for name in ('Contents', 'Contents/MacOS', 'Contents/MacOS/ShadowSync', 'Contents/Info.plist', 'Contents/Resources'):
                path = app / name; path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                path.symlink_to(external)
                result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), '--doctor', '--test-root', str(root)],
                    env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Development fixture root is unsafe', result.stderr)
                self.assertEqual(result.stdout, b'')
                path.unlink()

    def test_release_template_cannot_claim_stamped_source_or_wrong_identity(self):
        path = self.root / 'Resources/Info.plist'; original = plistlib.loads(path.read_bytes())
        for field, value in [('CFBundleIdentifier', 'example.wrong'), ('CFBundleVersion', '014'),
                ('CFBundleVersion', '14'), ('CFBundleVersion', '2147483648'),
                ('CFBundleShortVersionString', '01.0.0'), ('LSMinimumSystemVersion', '15.0'),
                ('ShadowSyncArchitecture', 'x86_64'), ('ShadowSyncBuildMode', 'testing'),
                ('ShadowSyncSourceRevision', 'a' * 40)]:
            with self.subTest(field=field, value=value):
                changed = dict(original); changed[field] = value
                path.write_bytes(plistlib.dumps(changed))
                with self.assertRaises(ValueError): source.verify(self.root)

    def test_launch_agent_startup_extra_arguments_or_boolean_substitution_refuse(self):
        path = self.root / 'Resources/com.kleinperkins.shadow-sync.plist.template'
        original = plistlib.loads(path.read_bytes())
        for field, value in [('RunAtLoad', True), ('KeepAlive', True), ('RunAtLoad', 0),
                ('ProgramArguments', ['__EXECUTABLE_PATH__', '--managed-host', '--extra']),
                ('Label', 'example.wrong')]:
            changed = dict(original); changed[field] = value; path.write_bytes(plistlib.dumps(changed))
            with self.assertRaises(ValueError): source.verify(self.root)

    def test_release_contract_duplicates_and_unknown_fields_refuse(self):
        path = self.root / 'Resources/release-contract.json'; data = path.read_bytes().rstrip()
        for suffix in (b',"unexpected":true}', b',"schema":"shadow-sync-release-contract/v1"}'):
            path.write_bytes(data[:-1] + suffix)
            with self.assertRaises(ValueError): source.verify(self.root)


if __name__ == '__main__':
    unittest.main()
