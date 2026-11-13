"""Mutation controls for rollback/profile composition; no runtime fixture imports."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('stopped_rollback_source', ROOT / 'scripts/verify-stopped-rollback-source.py')
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class StoppedRollbackSourceTests(unittest.TestCase):
    def setUp(self):
        self.raw = source.read_sources(ROOT)

    def refuses(self, filename, signature, before, after, reason):
        original = source.body(self.raw[filename], signature)
        self.assertEqual(original.count(before), 1)
        values = dict(self.raw)
        values[filename] = values[filename].replace(original, original.replace(before, after))
        with self.assertRaisesRegex(ValueError, reason):
            source.verify_sources(values)

    def test_composed_source_obligations(self):
        self.assertEqual(len(source.verify_sources(self.raw)), 5)

    def test_new_store_and_each_control_replacement_cannot_default_or_forge_profile(self):
        filename = 'CustodyCatalog.swift'
        signature = 'func restoreStoppedFreshInstallation('
        for before in ('validationProfile: owner.validationProfile',
                       'receipts: chain + [proposed.receipt.receipt], profile: owner.validationProfile',
                       'receipts: chain, profile: owner.validationProfile'):
            for after in (before.replace('owner.validationProfile', '.production'),
                          before.replace('owner.validationProfile', 'unrelatedProfile')):
                with self.subTest(site=before, replacement=after):
                    self.refuses(filename, signature, before, after, 'restoration-retained-profile')

    def test_owned_guardian_cannot_use_a_guessed_signed_root(self):
        self.refuses('InstallationLifecycle.swift', 'func completeFreshRestoration(',
                     'fixtureRoot = try profile.location.anchorPath', 'fixtureRoot = observer.paths.home',
                     'restoration-signed-root')
        self.refuses('InstallationLifecycle.swift', 'func completeFreshRestoration(',
                     'try InstallationPaths.isolated(root: fixtureRoot) == observer.paths', 'true',
                     'restoration-owned-guardian')

    def test_snapshot_must_retain_original_profile_and_validate_location(self):
        filename = 'InstallationBootstrapFixtures.swift'
        signature = 'private static func stored(_ location: StateLocation, bootstrap: B)'
        for before, after in (('journal.testingValidationProfile', 'InstallationValidationProfile.production'),
                              ('try profile.validateLocation(location)', ''),
                              ('profile: profile', 'profile: unrelatedProfile')):
            with self.subTest(site=before):
                self.refuses(filename, signature, before, after, 'restoration-fixture-retained-profile')
        self.refuses(filename, 'static func authenticatedFreshPartialTreeRefusal(',
                     'let control = try stored(location, bootstrap: bootstrap)', 'let control = try stored(location)',
                     'restoration-fixture-snapshot-profile')

    def test_live_gate_and_exact_generation_cannot_be_removed(self):
        self.refuses('InstallationLifecycle.swift', 'private func restoreFreshPlist(',
                     'try permit.validateMutation(owner: owner, action: .restorePlist)', '',
                     'restoration-plist-live-gate')
        self.refuses('CustodyCatalog.swift', 'private func validateFreshRestorationMutation(',
                     'try repair.drain.retirement.revalidate(for: owner, registry: repair.drain.registry)', '',
                     'restoration-live-gate-order')
        filename = 'CustodyCatalog.swift'
        signature = 'private func validateFreshRestorationMutation('
        original = source.body(self.raw[filename], signature)
        # This check occurs twice; remove only the final mutex postflight gate.
        index = original.rindex('metadataGeneration == pins.generation')
        changed = original[:index] + original[index:].replace('metadataGeneration == pins.generation', 'true', 1)
        values = dict(self.raw); values[filename] = values[filename].replace(original, changed)
        with self.assertRaisesRegex(ValueError, 'restoration-exact-postflight'):
            source.verify_sources(values)


if __name__ == '__main__':
    unittest.main()
