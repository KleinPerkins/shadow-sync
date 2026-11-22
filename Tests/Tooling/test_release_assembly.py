"""Production release assembly failures use disposable inputs and a fake signer."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_assembly', ROOT / 'scripts/assemble-release-bundle.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
REVISION = '1' * 40
DIGEST = '2' * 64
FINGERPRINT = '3' * 40


class ReleaseAssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shadow-sync-assembly-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.build_root = self.root / 'build'
        (self.build_root / 'production/package').mkdir(parents=True)
        for path in (self.build_root, self.build_root / 'production', self.build_root / 'production/package'):
            path.chmod(0o700)
        self.app = self.build_root / 'production/package/ShadowSync.app'
        self.app.mkdir()
        for name in sorted(module.RAW_DIRECTORIES, key=lambda n: (n.count('/'), n)):
            (self.app / name).mkdir()
        for name in module.RAW_FILES:
            path = self.app / name
            path.write_bytes(b'\xcf\xfa\xed\xfe fixture' if name in module.EXECUTABLES else b'fixture')
        for name, source in module.SOURCE_RESOURCES.items():
            (self.app / name).write_bytes((ROOT / source).read_bytes())
        self.info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        self.info.update(ShadowSyncSourceRevision=REVISION, ShadowSyncSourceInputSHA256=DIGEST,
                         ShadowSyncReleaseContractSHA256=module.sha(ROOT / 'Resources/release-contract.json'))
        self.write_info()
        self.products = self.build_root / 'production/products'; self.products.mkdir()
        for name in module.build.PRODUCTS:
            (self.products / name).write_bytes(b'fake compiler output')
        self.build_receipt = dict(schema='shadow-sync-ci-build/v1', revision=REVISION, source_sha256=DIGEST,
            toolchain={'xcode':'fixture'}, builds={'production': dict(products=str(self.products),
                binaries={name: module.sha(self.products / name) for name in module.build.PRODUCTS},
                package=module.build.regular_inventory(self.app.parent))})
        self.build_record = self.build_root / 'build.json'
        self.build_record.write_text(json.dumps(self.build_receipt))
        self.team = module.json_file(ROOT / 'Resources/release-contract.json')['publisher_team_identifier']
        self.keychain = self.root / 'isolated.keychain-db'
        self.keychain.write_bytes(b'not a real keychain')
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.framework = self.runtime / 'Python.framework'
        resources = self.framework / 'Versions/3.14/Resources'
        resources.mkdir(parents=True)
        self.framework.chmod(0o755)
        binary = self.framework / 'Versions/3.14/Python'
        binary.write_bytes(b'\xcf\xfa\xed\xfe fake runtime')
        binary.chmod(0o755)
        (self.framework / 'Versions/Current').symlink_to('3.14')
        (self.framework / 'Python').symlink_to('Versions/Current/Python')
        manifest = resources / 'ShadowSyncRuntimeLayout.json'
        manifest.write_text('{}')
        rows = module.tree(self.framework)
        layout = {'schema': 'shadow-sync-policy-runtime-layout/v1', 'source': module.runtime.load_pin(),
                  'entries': {name: {key: val for key, val in row.items() if key in ('kind', 'mode', 'target')}
                              for name, row in rows.items()}}
        manifest.write_text(json.dumps(layout))
        self.receipt = dict(schema='shadow-sync-policy-runtime-build/v1', source=module.runtime.load_pin(),
                            signature_mode='Developer-ID', publisher_team=self.team, architecture='arm64',
                            builder_sha256=module.sha(ROOT / 'scripts/build-policy-runtime.py'),
                            source_pin_sha256=module.sha(ROOT / 'Resources/policy-runtime-source.json'),
                            output_entries=module.tree(self.framework), layout_sha256=module.sha(manifest),
                            transformations=[{'path': 'Versions/3.14/Python'}],
                            stdlib_archive={'driver_sha256': module.sha(ROOT / 'scripts/compile-runtime-bytecode.py')},
                            third_party_notice_qualification='source-bound-content-verified',
                            notices_manifest_sha256=module.runtime.load_pin()['notices_manifest_sha256'])
        self.write_receipt()
        self.args = SimpleNamespace(app=str(self.app), build_record=str(self.build_record), runtime_output=str(self.runtime),
                                    output=str(self.root / 'output'), keychain=str(self.keychain),
                                    signing_identity=FINGERPRINT, publisher_team=self.team,
                                    source_revision=REVISION, source_sha256=DIGEST)
        self.calls = []
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(module.build, 'toolchain', return_value={'xcode':'fixture'}).start()
        mock.patch.object(module.build, 'load', return_value=SimpleNamespace(git_source_digest=lambda *a: DIGEST)).start()
        mock.patch.object(module, 'verify_source').start()
        mock.patch.object(module, 'command', side_effect=self.command).start()
        mock.patch.object(module.sys, 'platform', 'darwin').start()

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def write_receipt(self):
        (self.runtime / 'runtime-build.json').write_text(json.dumps(self.receipt))

    def command(self, stage, *argv, **kwargs):
        self.calls.append((stage, argv))
        out, err = '', ''
        if stage.endswith('architecture'):
            out = 'arm64\n'
        elif stage == 'signing-identity':
            out = '  1) ' + FINGERPRINT + ' "Developer ID Application: Fixture (' + self.team + ')"\n'
        elif stage == 'publisher-properties':
            identifier = (module.APP_ID if Path(argv[-1]).name == 'ShadowSync.app' else
                          module.HELPER_ID if Path(argv[-1]).name == 'ShadowSyncLifecycleCoordinator' else module.RUNTIME_ID)
            err = 'TeamIdentifier=' + self.team + '\nIdentifier=' + identifier + '\nflags=0x10000(runtime)\nTimestamp=fixture\n'
        return subprocess.CompletedProcess(argv, 0, out, err)

    def test_assembly_preserves_inputs_and_emits_explicit_unqualified_milestones(self):
        before_app, before_runtime = module.tree(self.app), module.tree(self.framework)
        receipt = module.assemble(self.args)
        staged = Path(self.args.output) / 'ShadowSync.app'
        self.assertEqual(module.tree(self.app), before_app)
        self.assertEqual(module.tree(self.framework), before_runtime)
        self.assertEqual(module.tree(staged / 'Contents/Frameworks/Python.framework'), before_runtime)
        self.assertEqual((staged / 'Contents/Frameworks').stat().st_mode & 0o777, 0o755)
        for name in module.EXECUTABLES:
            self.assertEqual((staged / name).stat().st_mode & 0o777, 0o755)
        for name in module.ADDED_RESOURCES:
            self.assertEqual((staged / 'Contents/Resources' / name).read_bytes(),
                             (ROOT / 'Resources' / name).read_bytes())
        self.assertFalse(any(receipt[key] for key in ('notarized', 'published', 'installed', 'product_accepted')))
        signed = [args[-1] for stage, args in self.calls if stage == 'sign-bundle']
        self.assertEqual(signed, [staged / 'Contents/Helpers/ShadowSyncLifecycleCoordinator', staged])
        self.assertTrue((Path(self.args.output) / 'release-assembly.json').is_file())

    def test_testing_or_wrong_source_metadata_refuses_before_output(self):
        for key, value in [('ShadowSyncBuildMode', 'testing'), ('ShadowSyncSourceRevision', '4' * 40),
                           ('ShadowSyncSourceInputSHA256', '5' * 64)]:
            old = self.info[key]; self.info[key] = value; self.write_info()
            with self.assertRaises(module.Refusal): module.assemble(self.args)
            self.assertFalse(Path(self.args.output).exists())
            self.info[key] = old; self.write_info()

    def test_extra_or_aliased_bundle_nodes_refuse(self):
        extra = self.app / 'Contents/extra'
        extra.write_bytes(b'unknown payload')
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        extra.unlink()
        extra.symlink_to('Info.plist')
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse(Path(self.args.output).exists())

    def test_stale_application_resource_refuses(self):
        (self.app / 'Contents/Resources/release-contract.json').write_text('{}')
        with self.assertRaises(module.Refusal): module.assemble(self.args)

    def test_ad_hoc_or_wrong_producer_runtime_refuses(self):
        for key, value in [('signature_mode', 'ad-hoc-fixture'), ('publisher_team', 'A' * 10),
                           ('builder_sha256', '0' * 64), ('source_pin_sha256', '0' * 64),
                           ('architecture', 'x86_64')]:
            old = self.receipt[key]; self.receipt[key] = value; self.write_receipt()
            with self.assertRaises(module.Refusal): module.assemble(self.args)
            self.assertFalse(Path(self.args.output).exists())
            self.receipt[key] = old; self.write_receipt()

    def test_changed_runtime_bytes_or_escaping_links_refuse(self):
        binary = self.framework / 'Versions/3.14/Python'
        binary.write_bytes(b'changed')
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        (self.framework / 'escape').symlink_to(self.root)
        with self.assertRaises(module.runtime.BuildRefused): module.assemble(self.args)

    def test_wrong_publisher_and_ambiguous_signer_refuse(self):
        self.args.publisher_team = 'A' * 10
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.args.publisher_team = self.team
        self.args.signing_identity = 'Developer ID Application: Fixture'
        with self.assertRaises(module.Refusal): module.assemble(self.args)

    def test_existing_output_is_preserved(self):
        output = Path(self.args.output); output.mkdir()
        (output / 'preserve').write_bytes(b'previous')
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertEqual((output / 'preserve').read_bytes(), b'previous')

    def test_entitlements_are_rejected(self):
        with mock.patch.object(module, 'command', side_effect=lambda stage, *a, **k:
                               subprocess.CompletedProcess(a, 0, plistlib.dumps({'get-task-allow': True}).decode(), '')
                               if stage == 'publisher-entitlements' else self.command(stage, *a, **k)):
            with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse(Path(self.args.output).exists())

    def test_signing_failure_retains_partial_output_without_success_receipt(self):
        def fail(stage, *a, **k):
            if stage == 'sign-bundle': raise module.Refusal('simulated-signature-failure')
            return self.command(stage, *a, **k)
        with mock.patch.object(module, 'command', side_effect=fail):
            with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertTrue(Path(self.args.output).is_dir())
        self.assertFalse((Path(self.args.output) / 'release-assembly.json').exists())

    def test_runtime_change_during_copy_refuses(self):
        original = shutil.copytree
        def copy(source, destination, **kwargs):
            result = original(source, destination, **kwargs)
            if Path(source) == self.framework:
                (self.framework / 'Versions/3.14/Python').write_bytes(b'changed during copy')
            return result
        # Recursive copytree calls itself through shutil; patch only the top-level
        # assembly call by retaining real recursion for the duration of each copy.
        def guarded(source, destination, **kwargs):
            with mock.patch.object(module.shutil, 'copytree', original):
                return copy(source, destination, **kwargs)
        with mock.patch.object(module.shutil, 'copytree', side_effect=guarded):
            with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse((Path(self.args.output) / 'release-assembly.json').exists())


    def test_changed_checkout_prevents_assembly(self):
        with mock.patch.object(module, 'verify_source', side_effect=module.Refusal('checkout-source-binding')):
            with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse(Path(self.args.output).exists())

    def test_substituted_executable_with_unchanged_metadata_refuses(self):
        (self.app / 'Contents/MacOS/ShadowSync').write_bytes(b'\xcf\xfa\xed\xfe substituted testing executable')
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse(Path(self.args.output).exists())
        self.assertFalse(any(stage == 'sign-bundle' for stage, _ in self.calls))

    def test_runtime_root_mode_drift_refuses(self):
        self.framework.chmod(0o700)
        with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse(Path(self.args.output).exists())

    def test_substitution_between_producer_check_and_raw_capture_refuses_before_signing(self):
        original = module.raw_bundle
        def replace_then_capture(*args):
            (self.app / 'Contents/MacOS/ShadowSync').write_bytes(b'\xcf\xfa\xed\xfe switched executable')
            return original(*args)
        with mock.patch.object(module, 'raw_bundle', side_effect=replace_then_capture):
            with self.assertRaises(module.Refusal): module.assemble(self.args)
        self.assertFalse(Path(self.args.output).exists())
        self.assertFalse(any(stage == 'sign-bundle' for stage, _ in self.calls))
