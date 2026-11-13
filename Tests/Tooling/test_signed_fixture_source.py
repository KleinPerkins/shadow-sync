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

    def join_sources(self):
        core = ROOT / 'Sources/ShadowSyncCore'
        names = ('SignedInstallationFixtureJoinFixtures.swift', 'SignedInstallationFixtureEntrypoint.swift',
            'SignedInstallationFixtureContext.swift', 'SignedInstallationFixtureService.swift',
            'SignedInstallationFixtureAdapterChannel.swift', 'SignedInstallationFixtureCase.swift',
            'RetainedCleanupRegistry.swift')
        return {name: source.selected((core / name).read_text(), True, True) for name in names}, (core / 'CustodyCatalog.swift').read_text()

    def reject_join_mutation(self, name, original, replacement, error):
        files, catalog = self.join_sources()
        source.verify_signed_adapter_join(files, catalog)
        self.assertEqual(files[name].count(original), 1)
        files[name] = files[name].replace(original, replacement)
        with self.assertRaisesRegex(ValueError, error):
            source.verify_signed_adapter_join(files, catalog)

    def test_join_early_dispatch_cannot_fall_through_full_startup(self):
        self.reject_join_mutation('SignedInstallationFixtureEntrypoint.swift',
            '                            context: context, service: service, custody: custody)\n                        return',
            '                            context: context, service: service, custody: custody)', 'join-early-dispatch')

    def test_join_hold_must_follow_final_ack_and_cancel_cannot_release_it(self):
        files, catalog = self.join_sources()
        name = 'SignedInstallationFixtureAdapterChannel.swift'
        hold = 'try joinFixture?.holdAfterFinalAcknowledgment(channel: self)'
        moved = files[name].replace(hold, '').replace('        for (index, operation)', hold + '\n        for (index, operation)')
        files[name] = moved
        with self.assertRaisesRegex(ValueError, 'join-hold-after-real-final-ack'):
            source.verify_signed_adapter_join(files, catalog)
        self.reject_join_mutation(name, '        parent.interruptSocket()',
            '        joinFixture?.releaseAdapter(); parent.interruptSocket()', 'join-cancel-cannot-release')

    def test_join_real_wait_and_checked_disposal_cannot_be_replaced_by_success(self):
        self.reject_join_mutation('SignedInstallationFixtureAdapterChannel.swift',
            'try work?.join(deadline: deadline)', '_ = deadline', 'join-real-work')
        self.reject_join_mutation('RetainedCleanupRegistry.swift',
            '                  entry.resources.installationRetiredSuccessfully,',
            '                  true,', 'join-disposal-precondition')
        self.reject_join_mutation('RetainedCleanupRegistry.swift',
            '            guard remove(entry) else { throw CustodyRecordError.fenced }\n            timer?.cancel();',
            '            record.issuanceQualified = true\n            guard remove(entry) else { throw CustodyRecordError.fenced }\n            timer?.cancel();',
            'join-disposal-not-production-success')

    def test_join_throwing_unwind_and_finite_hold_source_obligations(self):
        # Mutation coverage checks real failure paths; it is not runtime fault execution.
        for original, replacement, error in (
            ('defer { owner.releaseOnUnwind() }', 'defer { }', 'join-root-owned-before-fallible-work'),
            ('releaseAdapter(); releaseInvocation()', 'releaseAdapter()', 'join-owner-release'),
            ('if let failure = failures.first { throw failure }', '_ = failures', 'join-unwind-retains-failure'),
            ('[weak owner]', '[owner]', 'join-checkpoint-owner-cycle'),
            ('emergency = true; adapterReleased = true', 'adapterReleased = true', 'join-finite-hold'),
        ):
            with self.subTest(original=original):
                self.reject_join_mutation('SignedInstallationFixtureJoinFixtures.swift', original, replacement, error)

    def test_join_exact_foreign_and_duplicate_match_controls_are_connected(self):
        self.reject_join_mutation('SignedInstallationFixtureJoinFixtures.swift',
            'guard bound == nil, !teardown, !ceiling.hasExpired', 'guard !teardown, !ceiling.hasExpired', 'join-duplicate-bind')
        self.reject_join_mutation('SignedInstallationFixtureJoinFixtures.swift',
            'binding.validationProfile == profile', 'true', 'join-exact-match')
        self.reject_join_mutation('SignedInstallationFixtureService.swift',
            'try controller.requireRejectedMatches(', 'try controller.unusedRejectedMatches(', 'join-adversarial-match-controls')

    def test_join_production_and_ordinary_testing_exclusion(self):
        raw = (ROOT / 'Sources/ShadowSyncCore/SignedInstallationFixtureJoinFixtures.swift').read_text()
        for testing, signed in ((False, False), (False, True), (True, False)):
            self.assertNotIn('SignedInstallationFixtureJoinController', source.selected(raw, testing, signed))
        weakened = raw.replace('#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE', '#if SHADOW_SYNC_TESTING', 1)
        self.assertIn('SignedInstallationFixtureJoinController', source.selected(weakened, True, False))

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
            ('testingQuitHandler = nil', 'testingQuitHandler = { NSApp.terminate(nil) }'),
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
            for name in ('main.swift', 'AppDelegate.swift', 'InstallationFixtureApp.swift'):
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

class SignedFixtureControlSourceTests(unittest.TestCase):
    def files(self):
        core=ROOT/'Sources/ShadowSyncCore'
        return {name:source.selected((core/name).read_text(),True,True) for name in (
            'SignedInstallationFixtureJoinControlFixtures.swift','SignedInstallationFixtureJoinFixtures.swift',
            'SignedInstallationFixtureEntrypoint.swift','SignedInstallationFixtureCase.swift','RetainedCleanupRegistry.swift')}

    def test_control_source_connected_and_dual_fenced(self):
        source.verify_signed_adapter_controls(self.files())
        raw=(ROOT/'Sources/ShadowSyncCore/SignedInstallationFixtureJoinControlFixtures.swift').read_text()
        for testing,signed in ((False,False),(True,False),(False,True)):
            self.assertEqual(source.selected(raw,testing,signed).strip(),'')

    def test_control_fault_prerequisite_and_one_use_certificate_mutations_refuse(self):
        mutations=[('bootstrapStartObservation() == .notAttempted','bootstrapStartObservation() == .failed'),
            ('quiet.preceding > 0','quiet.preceding >= 0'),
            ('injection.certificate === certificate','true'),
            ('!consumed, self.scenario','true, self.scenario'),
            ('expiry.expiryAwaiting','true'),
            ('bound?.channel == controller.binding?.channel','true'),
            ('current.originalReceipt == snapshot.originalReceipt','true')]
        for old,new in mutations:
            files=self.files();name='SignedInstallationFixtureJoinControlFixtures.swift';files[name]=files[name].replace(old,new)
            with self.subTest(old=old),self.assertRaises(ValueError): source.verify_signed_adapter_controls(files)

    def test_control_no_generic_H_success_swallow_or_timeout_fabrication(self):
        for name,old,new in [
            ('SignedInstallationFixtureJoinControlFixtures.swift','catch let error as SignedJoinHoldTimeout','catch let error as CustodyRecordError'),
            ('SignedInstallationFixtureJoinControlFixtures.swift','try work.value(deadline: context.deadline)','try work.join(deadline: context.deadline)'),
            ('SignedInstallationFixtureJoinFixtures.swift','let result = adapterRelease.wait(timeout: .init(uptimeNanoseconds: ceiling.absoluteUptimeNanoseconds))','let result = DispatchTimeoutResult.timedOut'),
            ('SignedInstallationFixtureJoinFixtures.swift','invocationObservation.returned = RuntimeSuiteGuardian.now','invocationObservation.returned = nil'),
        ]:
            files=self.files();self.assertIn(old,files[name]);files[name]=files[name].replace(old,new)
            with self.subTest(old=old),self.assertRaises(ValueError): source.verify_signed_adapter_controls(files)

    def test_control_teardown_disposal_or_normal_success_shortcuts_refuse(self):
        for old,new in [
            ('guard scenario == .startAdapterJoinFaultBeforeJoin || scenario == .startAdapterJoinFaultAfterRefusal','guard scenario.isStartAdapterJoinControl'),
            ('later.physicallyRetired && later.scope == sticky.scope','later.physicallyRetired'),
            ('quiet.selectedDelivered','true'),
            ('bootstrap.bootstrapStartObservation() == .complete','true'),
            ('try custody.finish(deadline: context.deadline)','_ = custody'),
            ('if let timeout { throw timeout }','if let timeout { _ = timeout }'),
            ('try emit(report, deadline: context.deadline)','_ = report'),
            ('if let failure = failures.first { throw failure }','_ = failures'),
        ]:
            files=self.files();name='SignedInstallationFixtureJoinControlFixtures.swift';self.assertIn(old,files[name]);files[name]=files[name].replace(old,new)
            with self.subTest(old=old),self.assertRaises(ValueError): source.verify_signed_adapter_controls(files)

    def test_control_report_transport_deadline_and_accounting_mutations_refuse(self):
        for name,old,new in [
            ('SignedInstallationFixtureJoinControlFixtures.swift','bytes.count <= 4096','bytes.count <= 65536'),
            ('SignedInstallationFixtureJoinControlFixtures.swift','flags & O_NONBLOCK','flags & O_APPEND'),
            ('SignedInstallationFixtureJoinControlFixtures.swift','Darwin.write(','fwrite('),
            ('SignedInstallationFixtureJoinControlFixtures.swift','POLLERR | POLLHUP | POLLNVAL','POLLERR'),
            ('RetainedCleanupRegistry.swift','$0.delivery == .delivered','true'),
            ('RetainedCleanupRegistry.swift','reservationOutputs.values.reduce(0, +) == outputReserved','true'),
        ]:
            files=self.files();self.assertIn(old,files[name]);files[name]=files[name].replace(old,new)
            with self.subTest(old=old),self.assertRaises(ValueError): source.verify_signed_adapter_controls(files)
