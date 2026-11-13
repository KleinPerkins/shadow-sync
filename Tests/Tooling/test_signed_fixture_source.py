"""Offline source containment checks, never signed installation qualification."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('signed_fixture_source', ROOT / 'scripts/verify-signed-fixture-source.py')
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class SignedFixtureSourceTests(unittest.TestCase):
    def test_component_has_reachable_signed_only_source_entry(self):
        self.assertEqual(source.verify(ROOT), ['ordinary-build-exclusion', 'reachable-source-preflight',
            'production-decode-default', 'full-publisher-layout', 'pure-record-profile-validation', 'retained-staged-profile', 'retained-commit-profile', 'authenticated-helper-channel', 'connected-startup-stop-route', 'owned-service-handoff', 'real-appkit-entry', 'signed-host-side-effect-fences', 'committed-isolated-policy', 'external-root-disposal', 'owner-lock-reservations'])

    def test_signed_activation_fence_precedes_real_sink_and_testing_overrides(self):
        raw = (ROOT / 'Sources/ShadowSyncApp/AppDelegate.swift').read_text()
        source.verify_signed_host_side_effects(raw)
        activation = source.body(raw, 'private func requestApplicationActivation(')
        fence = 'guard !signedFixtureLifecycle else {\n            finishForeground(request, outcome: .denied)\n            return\n        }'
        self.assertEqual(activation.count(fence), 1)
        # Removing or moving the fence must reject the actual method. A guard
        # elsewhere or a fabricated successful activation is not containment.
        weakened = (
            activation.replace(fence, ''),
            activation.replace(fence, '') + '\n' + fence,
            activation.replace('outcome: .denied', 'outcome: .success'),
            activation.replace(fence, fence.replace('            return\n', '')),
            activation.replace(fence, 'if !signedFixtureLifecycle { }'),
        )
        for index, value in enumerate(weakened):
            with self.subTest(mutation=index):
                self.assertEqual(raw.count(activation), 1)
                with self.assertRaisesRegex(ValueError, 'fixture-brokered-activation'):
                    source.verify_signed_host_side_effects(raw.replace(activation, value))

    def test_signed_initializer_cannot_skip_real_startup_or_enable_external_log_open(self):
        raw = (ROOT / 'Sources/ShadowSyncApp/AppDelegate.swift').read_text()
        initializer = source.body(raw, 'init(executablePath: String, signedFixture entry:')
        for original, replacement in (
            ('testingHostChrome = false', 'testingHostChrome = true'),
            ('signedFixtureLifecycle = true', 'signedFixtureLifecycle = false'),
            ('logOpener = { _ in false }', 'logOpener = { NSWorkspace.shared.open($0) }'),
        ):
            with self.subTest(statement=original):
                self.assertEqual(initializer.count(original), 1)
                with self.assertRaisesRegex(ValueError, 'fixture-host-initializer'):
                    source.verify_signed_host_side_effects(raw.replace(initializer, initializer.replace(original, replacement)))

    def test_other_workspace_open_sink_is_detected(self):
        raw = (ROOT / 'Sources/ShadowSyncApp/AppDelegate.swift').read_text()
        startup = source.body(raw, 'func applicationDidFinishLaunching(')
        self.assertEqual(raw.count(startup), 1)
        with self.assertRaisesRegex(ValueError, 'fixture-extra-workspace-open'):
            source.verify_signed_host_side_effects(raw.replace(startup, startup + '\nNSWorkspace.shared.openApplication(at: Bundle.main.bundleURL)\n'))

    def test_commit_profile_cannot_fall_back_on_reachable_paths(self):
        mutations = [
            ('InstallationHostCommit.swift', 'try record.validate(profile: validationProfile)', 'try record.validate()', 'commit-construction-profile'),
            ('InstallationCommitDelivery.swift', 'committed.validate(profile: validationProfile)', 'committed.validate()', 'commit-construction-profile'),
            ('InstallationPrecommitSession.swift', 'self.validationProfile = session.validationProfile', '', 'ready-observation-profile'),
            ('InstallationPrecommitSession.swift', 'transcriptDigest: digest, validationProfile: validationProfile)', 'transcriptDigest: digest)', 'commit-route-profile'),
            ('InstallationPrecommitSession.swift', 'committed: delivery.control, deadline: deadline, validationProfile: validationProfile)', 'committed: delivery.control, deadline: deadline)', 'commit-route-profile'),
        ]
        with tempfile.TemporaryDirectory(prefix='shadow-sync-signed-profile-') as temporary:
            root = Path(temporary)
            config = root / 'config'; config.mkdir()
            shutil.copyfile(ROOT / 'config/signed-installation-fixtures.json', config / 'signed-installation-fixtures.json')
            shutil.copytree(ROOT / 'Sources', root / 'Sources')
            fixture = root / 'Tests/Fixtures'; fixture.mkdir(parents=True)
            shutil.copyfile(ROOT / 'Tests/Fixtures/signed-installation-source-markers.json', fixture / 'signed-installation-source-markers.json')
            for name, original, replacement, error in mutations:
                with self.subTest(name=name, original=original):
                    path = root / 'Sources/ShadowSyncCore' / name
                    text = path.read_text()
                    self.assertEqual(text.count(original), 1)
                    path.write_text(text.replace(original, replacement))
                    try:
                        with self.assertRaisesRegex(ValueError, error):
                            source.verify(root)
                    finally:
                        path.write_text(text)

    def test_signed_menu_does_not_read_or_mutate_login_registration(self):
        value = source.selected((ROOT / 'Sources/ShadowSyncApp/AppDelegate.swift').read_text(), True, True)
        for signature, guard in [('private func configureOpenAtLoginItem(', 'if signedFixtureLifecycle'),
                                 ('@objc private func toggleOpenAtLogin(', 'guard !signedFixtureLifecycle else { return }')]:
            start = value.index(signature)
            self.assertLess(value.index(guard, start), value.index('SMAppService.mainApp.status', start))
        ordinary = source.selected((ROOT / 'Sources/ShadowSyncApp/AppDelegate.swift').read_text(), False, False)
        self.assertNotIn('signedFixtureLifecycle', ordinary)
        self.assertIn('try SMAppService.mainApp.register()', ordinary)

    def test_selector_rejects_unknown_or_unbalanced_conditions(self):
        for text in ('#if UNKNOWN\nx\n#endif', '#if SHADOW_SYNC_TESTING\nx', '#else\nx',
                     '#if SHADOW_SYNC_TESTING || __import__(x)\nx\n#endif'):
            with self.assertRaises(ValueError):
                source.selected(text, False, False)

    def test_removing_second_build_fence_is_detected(self):
        original = (ROOT / 'Sources/ShadowSyncCore/SignedInstallationFixtureContext.swift').read_text()
        weakened = original.replace('#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE', '#if SHADOW_SYNC_TESTING', 1)
        self.assertNotIn('SignedInstallationFixtureContext', source.selected(original, True, False))
        self.assertIn('SignedInstallationFixtureContext', source.selected(weakened, True, False))

    def test_missing_production_decode_default_refuses(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-signed-source-') as temporary:
            root = Path(temporary)
            config = root / 'config'; config.mkdir()
            shutil.copyfile(ROOT / 'config/signed-installation-fixtures.json', config / 'signed-installation-fixtures.json')
            core = root / 'Sources/ShadowSyncCore'; core.mkdir(parents=True)
            for path in (ROOT / 'Sources/ShadowSyncCore').glob('*.swift'):
                shutil.copyfile(path, core / path.name)
            app = root / 'Sources/ShadowSyncApp'; app.mkdir(parents=True)
            for name in ('main.swift', 'AppDelegate.swift', 'SignedInstallationFixtureApp.swift'):
                shutil.copyfile(ROOT / 'Sources/ShadowSyncApp' / name, app / name)
            fixture = root / 'Tests/Fixtures'; fixture.mkdir(parents=True)
            shutil.copyfile(ROOT / 'Tests/Fixtures/signed-installation-source-markers.json',
                            fixture / 'signed-installation-source-markers.json')
            control = core / 'InstallationControlRecord.swift'
            control.write_text(control.read_text().replace('profile: InstallationValidationProfile = .production',
                                                           'profile: InstallationValidationProfile'))
            with self.assertRaisesRegex(ValueError, 'ordinary-control-decode-not-production'):
                source.verify(root)

    def test_record_profile_must_not_reenter_source_verification(self):
        text = (ROOT / 'Sources/ShadowSyncCore/SignedInstallationFixtureContext.swift').read_text()
        signature = 'func validate(_ release: ReleaseIdentity) throws {'
        start = text.index(signature)
        end = text.index('func validateCandidate(', start)
        self.assertNotIn('try revalidate()', text[start:end])
        self.assertNotIn('sealed.revalidate()', text[start:end])
