import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('coordinator_entry', ROOT / 'scripts/verify-coordinator-entry.py')
entry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(entry)


class CoordinatorEntryTests(unittest.TestCase):
    def test_parent_escape_refuses_before_executing_any_binary(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-coordinator-path-', dir='/private/tmp') as temp:
            parent = Path(temp); root = parent / 'fixture'; root.mkdir(mode=0o700)
            outside = parent / 'outside'; outside.mkdir(mode=0o700)
            binary = outside / 'coordinator'; binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            for candidate in (root / '../outside/coordinator', binary):
                with self.subTest(path=str(candidate)), patch.object(entry.subprocess, 'run') as execute:
                    with self.assertRaises(ValueError): entry.verify(root, candidate, root / 'ShadowSync.app')
                    execute.assert_not_called()

    def test_owned_contained_executable_accepts_and_alias_refuses(self):
        with tempfile.TemporaryDirectory(prefix='shadow-sync-coordinator-path-', dir='/private/tmp') as temp:
            root = Path(temp); binary = root / 'coordinator'
            binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            entry.contained(root, binary)
            alias = root / 'alias'; alias.symlink_to(binary)
            with self.assertRaises(ValueError): entry.contained(root, alias)

class FreshInstallationDriverSourceTests(unittest.TestCase):
    """Mutation-sensitive source obligations, not compiled/native evidence."""
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fresh_driver_source', ROOT / 'scripts/verify-signed-fixture-source.py')
        self.source = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.source)
        self.driver = (ROOT / 'Sources/ShadowSyncCore/ProductionInstallationDriver.swift').read_text()
        self.bootstrap = (ROOT / 'Sources/ShadowSyncCore/InstallationBootstrap.swift').read_text()
        self.publisher = (ROOT / 'Sources/ShadowSyncCore/LifecyclePublisher.swift').read_text()

    def test_fresh_runtime_has_no_unconditional_integer_exit(self):
        main = (ROOT / 'Sources/ShadowSyncLifecycleCoordinator/main.swift').read_text()
        self.assertIn('LifecycleCoordinatorMain.runRuntime(arguments:', main)
        self.assertNotIn('exit(LifecycleCoordinatorMain.run(', main)
        root = self.source.body(self.driver, 'private final class CoordinatorProcessRoot')
        self.assertIn('private var root: CoordinatorInvocationLifetime?', root)
        self.assertIn('root = lifetime', root)
        launch = self.source.body(self.driver, 'fileprivate func launch()')
        self.assertLess(launch.index('CoordinatorProcessRoot.shared.contains(self)'), launch.index('queue.async'))
        self.assertIn('dispatchMain()', self.driver)
        self.assertNotIn('asyncAfter', self.driver)
        self.assertNotIn('Thread.sleep', self.driver)
        self.assertNotIn('makeTimerSource', self.driver)

    def test_testing_fresh_entry_refuses_before_resolution(self):
        for signed in (False, True):
            body = self.source.body(self.source.selected(self.driver, True, signed), 'static func start(arguments:')
            self.assertIn('return .exit(.beforeEffects(78))', body)
            self.assertNotIn('FreshInstallationAttempt.production', body)
            self.assertNotIn('EffectiveAccount.current', body)
        admission = self.source.body(self.publisher, 'final class CoordinatorInstallationAdmission')
        self.assertNotIn('static func testing', admission)
        self.assertIn('PolicyResourcesSource.capture(publisher, installation: installation)', admission)
        factory = self.source.body(self.bootstrap, 'static func production(admission:')
        self.assertIn('publisher: admission.publisher, source: admission.installation', factory)
        self.assertNotIn('LifecyclePublisher.current()', factory)

    def test_terminal_receipt_is_exact_owner_and_one_use(self):
        receipt = self.source.body(self.bootstrap, 'final class FreshInstallationExitReceipt')
        self.assertIn('fileprivate init(bootstrap:', receipt)
        self.assertIn('private weak var bootstrap: InstallationBootstrap', receipt)
        self.assertIn('guard !consumed, self.bootstrap === bootstrap', receipt)
        for name in ('finishFreshInstallation', 'repairStoppedFreshInstallation', 'restoreStoppedFreshInstallation'):
            body = self.source.body(self.bootstrap, 'func ' + name + '()')
            self.assertLess(body.index('try journal.' + name), body.index('return FreshInstallationExitReceipt'))
        permit = self.source.body(self.driver, 'fileprivate static func terminal(')
        self.assertIn('receipt.consume(for: attempt.bootstrap)', permit)
        self.assertIn('!failed && uncancelled && attempt.firstFailure == nil', permit)

    def test_primary_error_precedes_cleanup_and_settlement_is_policy_free(self):
        for name in ('openStagedReadiness', 'startCandidate', 'confirmCandidateReady', 'commitCandidateReadiness'):
            body = self.source.body(self.bootstrap, 'func ' + name + '(')
            self.assertLess(body.index('rememberPrimaryFailure(error)'), body.index('try journal.closeReadiness('))
            self.assertIn('rememberSettlementFailure(error)', body)
        for name in ('settleOriginalAttempt', 'stopNormallyStartedHost', 'stopReadinessOnlyHost',
                     'cleanupReadinessCoordination', 'finishFreshInstallation', 'collectOriginalRetirement'):
            body = self.source.body(self.bootstrap, 'func ' + name + '(')
            self.assertNotIn('revalidateForward', body)
            self.assertNotIn('forwardBoundary', body)
        boundary = self.source.body(self.bootstrap, 'private func forwardBoundary(')
        self.assertGreater(boundary.rindex('cancellationGate.check()'), boundary.index('forwardAdmission.revalidateForward()'))

    def test_actual_publication_notice_is_separate_from_pending(self):
        registry = (ROOT / 'Sources/ShadowSyncCore/RetainedCleanupRegistry.swift').read_text()
        cell = self.source.body(registry, 'fileprivate final class ResultCell')
        self.assertIn('private var actualRetirementPublished = false', cell)
        publish = self.source.body(cell, 'func publishActualRetirement()')
        self.assertLess(publish.index('mutex.unlock()\n            for observer'), publish.index('observer.publish()'))
        pending = self.source.body(cell, 'func publish(_ result:')
        self.assertNotIn('publishActualRetirement', pending)
        retire = self.source.body(registry, 'private func retireAndPublish(')
        self.assertLess(retire.index('entry.releaseCommandAliases()'), retire.index('queue.async'))
        self.assertLess(retire.index('cell.publishStagedRetirement'), retire.index('cell.publishActualRetirement()'))
        lifetime = self.source.body(self.driver, 'final class CoordinatorInvocationLifetime')
        self.assertIn('observeOriginalWork(on: queue) { [weak self]', lifetime)
        session = (ROOT / 'Sources/ShadowSyncCore/InstallationPrecommitSession.swift').read_text()
        notice = self.source.body(session, 'func observeWorkFinished(')
        self.assertIn('group.notify', notice)
        self.assertNotIn('retainedSelf = nil', notice)
        self.assertNotIn('didJoinReadiness', notice)

    def test_real_driver_sequence_and_original_ceiling(self):
        body = self.source.body(self.driver, 'func runOnce()')
        calls = ['reserve(deadline: deadline)', 'prepareExclusive()', 'transferToStagedAdmission()',
                 'continueStagedJournal()', 'openStagedReadiness()', 'bootstrapCandidate()', 'kickstartCandidate()',
                 'confirmCandidateReady()', 'commitCandidateReadiness()', 'observeNormalStartup()',
                 'cleanupReadinessCoordination()', 'finishFreshInstallation()']
        self.assertEqual([body.index('bootstrap.' + call) for call in calls], sorted(body.index('bootstrap.' + call) for call in calls))
        self.assertIn('switch phase', body)
        self.assertEqual(self.driver.count('MonotonicDeadline(seconds: 30)'), 1)
        self.assertIn('guard firstFailure != nil, !deadline.hasExpired else', self.driver)
        self.assertIn('bootstrap.failureObservation().primary ?? InstallationFailure.classify(error)', body)
        signed = (ROOT / 'Sources/ShadowSyncCore/FreshInstallationFixture.swift').read_text()
        self.assertIn('let update = attempt.runOnce()', signed)
        self.assertIn('receipt.consume(for: bootstrap)', signed)
        self.assertIn('journal.testingTerminalUncertainClose', signed)

    def test_exclusive_diagnostic_rechecks_same_gate_immediately_before_submission(self):
        raw = (ROOT / 'Sources/ShadowSyncCore/InstallationLifecycle.swift').read_text()
        catalog = (ROOT / 'Sources/ShadowSyncCore/CustodyCatalog.swift').read_text()
        preparation = self.source.body(catalog, 'private func prepareExclusiveImpl(')
        self.assertIn('cancellation: forwardAdmission.cancellation', preparation)
        forwarding = self.source.body(raw, 'func observeExclusiveServiceAbsence(journal:')
        self.assertIn('deadline: deadline, cancellation: cancellation', forwarding)
        def check(text):
            body = self.source.body(self.source.selected(text, False, False), 'fileprivate func observeExclusiveServiceAbsence(')
            boundary = 'try cancellation.check()\n            result = try registry.start(command).wait()'
            self.source.require(boundary in body, 'final-original-gate')
            self.source.require(body.index('context!.prepare(.serviceStatus') < body.index(boundary), 'after-fallible-preparation')
        check(raw)
        with self.assertRaisesRegex(ValueError, 'final-original-gate'):
            check(raw.replace('try cancellation.check()', ''))
        fixture = (ROOT / 'Sources/ShadowSyncCore/InstallationBootstrapFixtures.swift').read_text()
        case = self.source.body(fixture, 'static func driverExclusiveDiagnosticCancellation()')
        for required in ('attempt.runOnce()', 'registry.testingPreparedStartCount == 0',
                         'control.step?.action == .drainPrior', 'attempt.firstFailure == .cancelled',
                         'InstallationOwnershipFixtures.excluded(location)', 'bootstrap.testingRetained() == retained'):
            self.assertIn(required, case)

    def test_actual_driver_uncertainty_covers_closed_checkpoint_and_publication_matrix(self):
        import re
        cases = (ROOT / 'Sources/ShadowSyncCore/SignedInstallationFixtureCase.swift').read_text()
        mapping = self.source.body(cases, 'var freshUncertainty:')
        self.assertEqual(len(re.findall(r'return \.ready\(', mapping)), 9)
        self.assertEqual(len(re.findall(r'return \.commit\(', mapping)), 3)
        self.assertEqual(len(re.findall(r'return \.publication\(', mapping)), 36)
        self.assertEqual(len(re.findall(r'return \.delivery\(', mapping)), 2)
        for cut in ('lostNormal', 'lateNormal'):
            self.assertIn('return .' + cut, mapping)
        signed = (ROOT / 'Sources/ShadowSyncCore/FreshInstallationFixture.swift').read_text()
        driver = self.source.body(signed, 'static func runUncertainty(')
        for required in ('let update = attempt.runOnce()', 'case let .retained(cause, phase)',
                         'bootstrap.failureObservation().primary == cause', 'requireReached(probe)',
                         'observed == (swapped ? trace.after : trace.before)',
                         'bootstrap.stoppedRecoveryObservation() == .notAttempted',
                         'session.testingNormalEvidence', 'session.observeWorkFinished(on: queue)',
                         'attempt.testingTrace == trace', 'bootstrap.testingCommitRetention() == retention'):
            self.assertIn(required, driver)
        for manual in ('bootstrap.reserve(', 'bootstrap.prepareExclusive()', 'bootstrap.transferToStagedAdmission()',
                       'bootstrap.openStagedReadiness()', 'bootstrap.bootstrapCandidate()', 'bootstrap.kickstartCandidate()'):
            self.assertNotIn(manual, driver)

    def test_normal_frame_fault_is_after_authentication_and_testing_only(self):
        raw = (ROOT / 'Sources/ShadowSyncCore/InstallationPrecommitSession.swift').read_text()
        live = self.source.selected(raw, False, False)
        for seam in ('testingFailDelivery', 'testingReceivedNormalFrame', 'testingNormalEvidence',
                     'testingWaitForNormalEvidence', 'testingBeforeNormalFrame'):
            self.assertNotIn(seam, live)
        body = self.source.body(raw, 'private func continueStartup(')
        self.assertLess(body.index('testingBeforeNormalFrame()'), body.index('reader.read('))
        self.assertLess(body.index('InstallationPrecommitTransport.authenticate('), body.index('testingReceivedNormalFrame('))
        self.assertLess(body.index('transcript.consume(normal'), body.index('testingReceivedNormalFrame('))
        self.assertLess(body.index('testingReceivedNormalFrame('), body.index('let observation = NormalStarted('))
        fault = self.source.body(raw, 'private func testingReceivedNormalFrame(')
        self.assertIn('receivedNormalControl = control', fault)
        self.assertIn('throw CustodyRecordError.injectedFailure', fault)
        self.assertNotIn('NormalStarted(', fault)
