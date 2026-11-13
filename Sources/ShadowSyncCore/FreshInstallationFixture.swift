#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// Creator-owned signed route through the actual driver. Independent fixture
/// teardown may drain hosts; it never supplies production settlement evidence.
enum SignedFreshInstallationDriverFixture {
    static func run(_ scenario: SignedInstallationFixtureCase, bootstrap: InstallationBootstrap,
        context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody) throws {
        if let cut = scenario.freshUncertainty {
            try runUncertainty(cut, bootstrap: bootstrap, context: context, custody: custody)
            return
        }
        typealias H = InstallationParentPreparationFixtures
        typealias J = CustodyCatalogStore.InstallationStagedJournal
        let ceiling = MonotonicDeadline(seconds: 30)
        let deadline = MonotonicDeadline(uptimeNanoseconds: min(ceiling.absoluteUptimeNanoseconds,
            context.deadline.absoluteUptimeNanoseconds))
        let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: deadline)
        custody.retain(attempt) // Before the real driver's first reserve.
        attempt.testingBeforePhase = { [weak bootstrap, weak attempt] phase in
            guard let bootstrap, let attempt else { throw CustodyRecordError.fenced }
            switch scenario {
            case .freshDriverCancelReady:
                if phase == .commit { attempt.requestCancellation() }
            case .freshDriverCancelNormal:
                if phase == .cleanup { attempt.requestCancellation() }
            case .freshDriverCleanup:
                if phase == .cleanup {
                    guard let endpoint = bootstrap.testingReadinessEndpoint() else { throw CustodyRecordError.fenced }
                    endpoint.testingCleanupCut = .afterUnlink
                }
            case .freshDriverCloseTemporaryStore:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .temporaryStore
                }
            case .freshDriverCloseStagedSlots:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .stagedSlots
                }
            case .freshDriverCloseStagedParents:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .stagedParents
                }
            case .freshDriverCloseBootstrapParents:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .bootstrapParents
                }
            case .freshDriverCloseMetadata:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .metadata
                }
            case .freshDriverCloseAdmission:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .admission
                }
            case .freshDriverCloseState:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .state
                }
            case .freshDriverCloseOperation:
                if phase == .finish {
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    journal.testingTerminalUncertainClose = .operation
                }
            case .freshDriverPositive: break
            default: throw CustodyRecordError.fenced
            }
        }
        defer { attempt.testingBeforePhase = nil }
        let update = attempt.runOnce()
        switch scenario {
        case .freshDriverPositive:
            guard case let .installed(receipt) = update else { throw CustodyRecordError.fenced }
            try H.check(attempt.testingTrace == [.reserve, .exclusive, .transfer, .journal, .readiness,
                .bootstrap, .kickstart, .ready, .commit, .normalStartup, .cleanup, .finish]
                && attempt.firstFailure == nil && bootstrap.completionObservation() == .complete
                && receipt.disposition == .installed && receipt.consume(for: bootstrap)
                && !receipt.consume(for: bootstrap), "actual fresh driver terminal receipt or one-use order failed")
            try InstallationOwnershipFixtures.excluded(context.paths.state, expected: false)
        case .freshDriverCancelReady, .freshDriverCancelNormal:
            guard case let .failedSettled(receipt, cause) = update else { throw CustodyRecordError.fenced }
            try H.check(cause == .cancelled && attempt.firstFailure == .cancelled
                && receipt.disposition == (scenario == .freshDriverCancelReady ? .restored : .repaired)
                && receipt.consume(for: bootstrap) && !receipt.consume(for: bootstrap),
                "cancelled original owner did not return failed checked settlement")
            try InstallationOwnershipFixtures.excluded(context.paths.state, expected: false)
        default:
            guard case .retained = update, let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
            try H.check(attempt.firstFailure != nil && attempt.phase == .failed,
                "driver converted partial cleanup into success")
            if scenario == .freshDriverCleanup {
                try H.check(bootstrap.coordinationCleanupObservation() == .pending
                    && bootstrap.completionObservation() == .notAttempted, "driver cleanup cut not reached")
            } else {
                try H.check(bootstrap.completionObservation() == .pending && journal.testingTerminalUncertainClose == nil
                    && journal.testingTerminalCustodyRetained, "driver close cut not reached or owner dropped")
            }
            if scenario != .freshDriverCloseOperation { try InstallationOwnershipFixtures.excluded(context.paths.state) }
            let failure = attempt.firstFailure, trace = attempt.testingTrace
            attempt.observeRetirement()
            guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
            try H.check(attempt.firstFailure == failure && attempt.testingTrace == trace,
                "late physical work replayed the failed installation")
        }
    }
}

extension SignedFreshInstallationDriverFixture {
    enum Uncertainty {
        case ready(InstallationBootstrap.ReadyCheckpoint)
        case commit(InstallationBootstrap.CommitCheckpoint)
        case publication(InstallationCandidateReadyTransitionHarness.Transition,
            CustodyCatalogStore.InstallationStagedJournal.TestingPublicationFailure)
        case delivery(InstallationPrecommitSession.TestingDeliveryPoint)
        case lostNormal, lateNormal
    }
    /// Each invocation uses one creator-owned root, real signed host and the
    /// original driver/Bootstrap. A reached cut is required before a refusal
    /// counts; these tests never manually advance a parallel bootstrap sequence.
    static func runUncertainty(_ cut: Uncertainty, bootstrap: InstallationBootstrap,
        context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody) throws {
        typealias H = InstallationParentPreparationFixtures
        typealias J = CustodyCatalogStore.InstallationStagedJournal
        let original = MonotonicDeadline(uptimeNanoseconds: min(
            MonotonicDeadline(seconds: 30).absoluteUptimeNanoseconds, context.deadline.absoluteUptimeNanoseconds))
        let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: original)
        custody.retain(attempt)
        var reached = false
        var probe: J.TestingPublicationProbe?
        var returnedCommit: [Bool]?
        let normalBarrier: CustodyLeaseTestingBarrier?
        switch cut { case .lostNormal, .lateNormal: normalBarrier = CustodyLeaseTestingBarrier()
        default: normalBarrier = nil }
        defer { normalBarrier?.release(); attempt.testingBeforePhase = nil }
        switch cut {
        case let .ready(selected):
            try bootstrap.testingConfigureCandidateReady(checkpoint: { point in
                if point == selected { reached = true; throw InstallationFailure.policy }
            })
        case let .commit(selected):
            try bootstrap.testingConfigureReadinessCommit(checkpoint: { [weak bootstrap] point in
                guard point == selected, let bootstrap else { return }
                reached = true; returnedCommit = bootstrap.testingCommitRetention()
                throw InstallationFailure.policy
            })
        case let .publication(edge, failure):
            let value = J.TestingPublicationProbe(action: edge.action, status: edge.status, failure: failure)
            probe = value
            if edge.action == .candidateReady { try bootstrap.testingConfigureCandidateReady(publicationProbe: value) }
            else { try bootstrap.testingConfigureReadinessCommit(publicationProbe: value) }
        default: break
        }
        attempt.testingBeforePhase = { [weak bootstrap] phase in
            guard let bootstrap else { throw CustodyRecordError.fenced }
            if phase == .commit {
                guard let session = bootstrap.testingReadinessSession() else { throw CustodyRecordError.fenced }
                switch cut {
                case let .delivery(point): try session.testingFailDelivery(at: point)
                case .lostNormal, .lateNormal:
                    guard let normalBarrier else { throw CustodyRecordError.fenced }
                    try session.testingCutNormalFrame(.deferred, barrier: normalBarrier)
                default: break
                }
            }
            if phase == .normalStartup {
                switch cut {
                case .lostNormal: normalBarrier?.release()
                case .lateNormal: throw InstallationFailure.policy
                default: break
                }
            }
        }
        let update = attempt.runOnce() // Includes the real settleOriginalAttempt selector.
        guard case let .retained(cause, phase) = update,
              let journal = bootstrap.testingTerminalJournal(),
              let session = bootstrap.testingReadinessSession(),
              let candidateDeadline = session.testingAnchoredDeadline else { throw CustodyRecordError.fenced }
        try H.check(attempt.bootstrap === bootstrap && attempt.firstFailure == cause
            && attempt.phase == .failed && bootstrap.failureObservation().primary == cause
            && candidateDeadline.absoluteUptimeNanoseconds <= original.absoluteUptimeNanoseconds
            && !original.hasExpired, "uncertainty lost original failure, owner or deadline")
        // None of these cuts possesses Bootstrap's genuine normal-started token.
        // A completed ready stage alone must never select stopped restoration
        // after any commit attempt, even a throw before commit proposal creation.
        try H.check(!bootstrap.testingNormalStartedRetained
            && bootstrap.stoppedRecoveryObservation() == .notAttempted
            && bootstrap.stoppedDeliveryObservation() == .notAttempted
            && bootstrap.coordinationCleanupObservation() == .notAttempted
            && bootstrap.completionObservation() == .notAttempted,
            "driver selected stopped settlement for uncertain readiness/commit")
        try InstallationOwnershipFixtures.excluded(context.paths.state)
        let controlPath = context.paths.state.path + "/custody/installation.json"
        func control() throws -> InstallationControlRecord {
            try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: controlPath)), profile: context.profile)
        }
        let observed = try control(), held = bootstrap.testingCommitRetention()
        switch cut {
        case .ready:
            try H.check(reached && phase == .ready && cause == .policy
                && bootstrap.candidateReadinessObservation() == .failed
                && bootstrap.readinessCommitObservation() == .notAttempted
                && observed.readinessCommit == nil && held == [false, false, false, false],
                "ready checkpoint did not reach the real driver failure")
        case let .commit(point):
            try H.check(reached && phase == .commit && cause == .policy
                && bootstrap.candidateReadinessObservation() == .complete
                && bootstrap.readinessCommitObservation() == .failed,
                "commit checkpoint did not retain failed commit attempt")
            if point == .claimed {
                try H.check(returnedCommit == [false, false, false, false] && held == [false, false, false, false]
                    && observed.readinessCommit == nil && bootstrap.commitFailureObservation() == .noCommitObserved,
                    "claimed commit incorrectly became rollback-eligible or durable")
            } else {
                try H.check(returnedCommit == [true, true, false, point == .delivered]
                    && held[0] && held[1] && held[3] == (point == .delivered) && observed.readinessCommit != nil,
                    "returned commit/transport outcome was lost before driver settlement")
                try checkCommitFence(bootstrap, journal: journal, observed: observed)
            }
        case let .publication(edge, failure):
            guard let probe else { throw CustodyRecordError.fenced }
            let trace = try InstallationCandidateReadyTransitionHarness.requireReached(probe)
            let swapped: Bool
            switch failure { case .controlAfterSwap, .controlAfterDirectorySync, .controlAfterPreimageUnlink: swapped = true
            default: swapped = false }
            try H.check(phase == (edge.action == .candidateReady ? .ready : .commit) && cause == .custody
                && bootstrap.observation().failedClosed && observed == (swapped ? trace.after : trace.before),
                "driver publication failure did not preserve exact durable pre/postimage")
            let receiptPath = context.paths.state.path + "/custody/receipts/" + (try trace.receipt.filename(uid: context.paths.state.uid))
            if failure == .receiptBeforeSwap {
                var node = stat()
                try H.check(lstat(receiptPath, &node) == -1 && errno == ENOENT, "pre-swap driver receipt appeared")
            } else {
                try H.check(try Data(contentsOf: URL(fileURLWithPath: receiptPath)) == trace.receipt.encode(uid: context.paths.state.uid),
                    "driver lost actual uncertain publication receipt")
            }
            if edge == .commitComplete {
                try H.check(held[0] && !held[2] && !held[3] && bootstrap.commitFailureObservation() == .pending
                    && observed.readinessCommit == (swapped ? trace.after.readinessCommit : nil),
                    "uncertain commit proposal was cleared, delivered or treated as no commit")
            } else {
                try H.check(observed.readinessCommit == nil && held == [false, false, false, false],
                    "precommit publication manufactured durable commit")
            }
        case let .delivery(point):
            try H.check(session.testingReachedDeliveryFailure == point && phase == .commit && cause == .custody
                && bootstrap.readinessCommitObservation() == .failed && held[0] && held[1] && !held[3]
                && observed.readinessCommit != nil, "real commit transport cut was not reached")
            try checkCommitFence(bootstrap, journal: journal, observed: observed)
        case .lostNormal:
            try H.check(phase == .normalStartup && cause == .custody
                && bootstrap.normalStartupObservation() == .failed && held[0] && held[1] && held[3]
                && session.testingNormalEvidence.control?.readinessCommit == observed.readinessCommit
                && observed.readinessCommit != nil && !session.testingNormalEvidence.retained
                && !session.testingNormalEvidence.claimed,
                "lost normal-started case did not authenticate a consumed real commit")
        case .lateNormal:
            guard let normalBarrier else { throw CustodyRecordError.fenced }
            try H.check(phase == .normalStartup && cause == .policy && normalBarrier.waitUntilEntered()
                && bootstrap.normalStartupObservation() == .notAttempted && held == [true, true, false, true]
                && observed.phase == .committed && observed.readinessCommit != nil
                && session.testingNormalEvidence.control == nil,
                "late normal-started case did not retain before actual frame reception")
            normalBarrier.release()
            try session.testingWaitForNormalEvidence(deadline: candidateDeadline)
            let evidence = session.testingNormalEvidence
            try H.check(evidence.control == observed && !evidence.retained && !evidence.claimed,
                "late frame did not authenticate the same consumed commit without a startup token")
        }
        // Deliver the real session-group notice only AFTER the failed driver
        // has returned. Subscription is an observation and cannot settle it.
        let noticed = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "shadow-sync.fixture.driver-uncertainty-notice")
        let subscription = session.observeWorkFinished(on: queue) { [weak attempt] in
            attempt?.observeRetirement(); noticed.signal()
        }
        defer { subscription.cancel() }
        if case .lateNormal = cut {
            // Original failed service has already finished; checked join is
            // fixture handback only and keeps the actual endpoint/EX retained.
            try session.cancelAndJoin(deadline: candidateDeadline)
        }
        try H.check(noticed.wait(timeout: .init(uptimeNanoseconds: candidateDeadline.absoluteUptimeNanoseconds)) == .success,
            "actual failed session notice was not delivered within original budget")
        let trace = attempt.testingTrace, durable = try Data(contentsOf: URL(fileURLWithPath: controlPath))
        let retention = bootstrap.testingCommitRetention()
        attempt.observeRetirement()
        guard case let .retained(lateCause, latePhase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
        try H.check(lateCause == cause && latePhase == phase && attempt.firstFailure == cause
            && attempt.testingTrace == trace && bootstrap.testingCommitRetention() == retention
            && !bootstrap.testingNormalStartedRetained && bootstrap.completionObservation() == .notAttempted
            && (try Data(contentsOf: URL(fileURLWithPath: controlPath))) == durable,
            "late physical notice replayed forward work or converted failure to success")
        try InstallationOwnershipFixtures.excluded(context.paths.state)
        try H.refuses { try bootstrap.confirmCandidateReady() }
        try H.refuses { try bootstrap.commitCandidateReadiness() }
        try H.check(try Data(contentsOf: URL(fileURLWithPath: controlPath)) == durable,
            "failed driver exposed replayable ready/commit publication")
    }
    private static func checkCommitFence(_ bootstrap: InstallationBootstrap,
        journal: CustodyCatalogStore.InstallationStagedJournal, observed: InstallationControlRecord) throws {
        let actual = journal.readinessCommitOutcome(), held = bootstrap.testingCommitRetention()
        try InstallationParentPreparationFixtures.check(actual.proposed?.readinessCommit != nil
            && actual.durable?.readinessCommit == observed.readinessCommit && observed.readinessCommit != nil,
            "actual durable commit was replaced by proposed or transport evidence")
        if let recovery = actual.recovery {
            try InstallationParentPreparationFixtures.check(held[2] && observed == recovery && observed.phase == .recovery
                && bootstrap.commitFailureObservation() == .fenced, "driver claimed fencing without exact durable recovery")
        } else {
            try InstallationParentPreparationFixtures.check(!held[2] && observed.phase == .committed
                && bootstrap.commitFailureObservation() == .pending, "uncertain fence became rollback or false durable recovery")
        }
    }
}
#endif
