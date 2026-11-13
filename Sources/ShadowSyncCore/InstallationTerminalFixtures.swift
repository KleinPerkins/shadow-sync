#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Registered refusal/retirement cases own actual guarded fixture roots. Signed
/// positives and postcommit cuts require the native driver's real retained
/// Bootstrap; no constructor here creates authenticated readiness or finish.
enum InstallationTerminalFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    private static func stored(_ location: StateLocation, profile: InstallationValidationProfile) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")), profile: profile)
    }
    static func beforeCleanup() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, registry in
            let parents = try InstallationParentPreparation.testing(root: root)
            try parents.revalidate()
            try journal.bindCompletionParents(parents)
            let before = try stored(location, profile: journal.testingValidationProfile)
            try H.refuses { _ = try journal.finishFreshInstallation(parents: parents, registry: registry) }
            try H.check(journal.terminalObservation() == .notAttempted && journal.testingTerminalPermit == nil
                && (try stored(location, profile: journal.testingValidationProfile)) == before, "early finish consumed or published terminal authority")
            let opened = try journal.completeAdmission(deadline: .init(seconds: 3))
            guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "terminal fixture endpoint absent") }
            let image = try endpoint.image
            try journal.closeReadiness(deadline: .init(seconds: 3))
            try H.refuses { _ = try journal.finishFreshInstallation(parents: parents, registry: registry) }
            try H.check(journal.terminalObservation() == .notAttempted && journal.testingTerminalPermit == nil
                && (try stored(location, profile: journal.testingValidationProfile)) == opened && (try endpoint.image) == image,
                "closed service substituted for causal cleanup/finish")
            try parents.revalidate()
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func uncertainAlias() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, owner, _, admission, journal, _ in
            // Positive control: a genuinely closed root family admits validation.
            var positive: CustodyAuthorityLeaseSet? = try admission.retainStartLeases()
            weak var positiveGone = positive
            positive = nil
            try H.check(positiveGone == nil, "positive alias still retained")
            try owner.validateStagedCommandAliasesRetired()
            var root: CustodyAuthorityLeaseSet? = try admission.retainStartLeases()
            var descendant: CustodyAuthorityLeaseSet? = try root!.duplicate()
            weak var rootGone = root, descendantGone = descendant
            try descendant!.testingUncertainInstallationClose()
            root = nil
            try H.check(rootGone != nil, "descendant failed to retain original family")
            descendant = nil
            try H.check(rootGone == nil && descendantGone == nil, "uncertain fixture aliases did not unwind")
            try H.refuses { try owner.validateStagedCommandAliasesRetired() }
            try H.refuses { _ = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart) }
            try H.check(journal.terminalObservation() == .notAttempted, "uncertain alias fabricated terminal attempt")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    /// Native driver prerequisite: actual signed bootstrap already completed
    /// cleanupReadinessCoordination, under its original readiness deadline. The
    /// driver owns the real host and guardian and must join both before cleanup.
    static func authenticatedPositive(_ bootstrap: InstallationBootstrap, root: String,
                                      location: StateLocation) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.coordinationCleanupObservation() == .complete,
              let journal = bootstrap.testingTerminalJournal() else {
            throw H.Failure(message: "signed terminal prerequisites absent")
        }
        let before = try stored(location, profile: journal.testingValidationProfile)
        guard before.step?.action == .cleanupCoordination, before.step?.status == .complete,
              before.readinessCommit != nil else { throw H.Failure(message: "durable causal cleanup absent") }
        let host = try Data(contentsOf: URL(fileURLWithPath: location.path + "/host-owner.json"))
        var operationBefore = stat(), operationAfter = stat(), hostBefore = stat(), hostAfter = stat()
        try H.check(lstat(location.path + "/operation.lock", &operationBefore) == 0
            && lstat(location.path + "/host.sock", &hostBefore) == 0, "terminal preimage missing")
        try InstallationOwnershipFixtures.excluded(location)
        try bootstrap.finishFreshInstallation()
        let after = try stored(location, profile: journal.testingValidationProfile)
        try H.check(after.step?.action == .finish && after.step?.status == .complete
            && after.step?.ordinal == 20 && after.revision == before.revision + 6
            && after.phase == .committed && after.readinessCommit == before.readinessCommit
            && after.state == before.state && after.transaction?.slots == before.transaction?.slots,
            "finish changed identity, commit or canonical state")
        let ownership = journal.testingOwner.testingTerminalOwnership()
        try H.check(bootstrap.completionObservation() == .complete && journal.terminalObservation() == .complete
            && ownership.attempted && ownership.complete && ownership.operation == .succeeded && ownership.state == .succeeded,
                    "durable finish preceded actual final owner retirement")
        try H.check(lstat(location.path + "/operation.lock", &operationAfter) == 0
            && operationBefore.st_dev == operationAfter.st_dev && operationBefore.st_ino == operationAfter.st_ino
            && lstat(location.path + "/host.sock", &hostAfter) == 0
            && hostBefore.st_dev == hostAfter.st_dev && hostBefore.st_ino == hostAfter.st_ino
            && host == (try Data(contentsOf: URL(fileURLWithPath: location.path + "/host-owner.json"))),
                    "finish replaced operation or disturbed normal host ownership")
        let raw = open(location.path + "/operation.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw H.Failure(message: "terminal contender open failed") }
        let contender = OwnedFileDescriptor(raw)
        try H.check(flock(raw, LOCK_EX | LOCK_NB) == 0, "original operation still held after reported completion")
        try H.check(contender.retireChecked() == .succeeded, "terminal contender close uncertain")
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.check(journal.testingTerminalPermit == nil, "completed journal retained reusable terminal capability")
    }
    /// One cut per original signed fixture child, never a retry. Its driver must
    /// own/join that child and the host before guardian root retirement. Pending
    /// owners deliberately survive this helper; process death is not success.
    static func authenticatedPublicationCut(_ bootstrap: InstallationBootstrap, location: StateLocation,
        action: InstallationAction, status: InstallationStepStatus, failure: J.TestingPublicationFailure) throws {
        guard [.cleanupBackups, .cleanupIncoming, .finish].contains(action),
              bootstrap.coordinationCleanupObservation() == .complete,
              let journal = bootstrap.testingTerminalJournal() else { throw H.Failure(message: "signed terminal cut prerequisites absent") }
        let before = try stored(location, profile: journal.testingValidationProfile)
        let probe = J.TestingPublicationProbe(action: action, status: status, failure: failure)
        try journal.testingObservePublication(probe)
        try H.refuses { try bootstrap.finishFreshInstallation() }
        guard let trace = probe.observed else { throw H.Failure(message: "terminal publication cut not reached") }
        try H.check(trace.after.readinessCommit == before.readinessCommit && journal.testingHasPending
            && bootstrap.completionObservation() == .pending && journal.terminalObservation() == .pending,
                    "terminal publication cut lost commit or pending evidence")
        try InstallationOwnershipFixtures.excluded(location)
        try H.refuses { try bootstrap.finishFreshInstallation() }
    }
    static func authenticatedCloseCut(_ bootstrap: InstallationBootstrap, location: StateLocation,
                                      resource: J.FinishPermit.Resource) throws {
        guard bootstrap.coordinationCleanupObservation() == .complete,
              let journal = bootstrap.testingTerminalJournal() else { throw H.Failure(message: "signed close cut prerequisites absent") }
        let before = try stored(location, profile: journal.testingValidationProfile)
        journal.testingTerminalUncertainClose = resource
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.check(journal.testingTerminalUncertainClose == nil
            && bootstrap.completionObservation() == .pending && journal.terminalObservation() == .pending,
                    "actual terminal close cut not reached or reported success")
        let after = try stored(location, profile: journal.testingValidationProfile)
        guard let finish = journal.testingTerminalPermit else { throw H.Failure(message: "pending finish owner absent") }
        let ownership = journal.testingOwner.testingTerminalOwnership()
        try H.check(after == finish.control && after.phase == .committed
            && after.step?.action == .finish && after.step?.status == .complete
            && after.readinessCommit == before.readinessCommit && after.recoveryReason == nil
            && journal.readinessCommitOutcome().recovery == nil && journal.testingTerminalCustodyRetained
            && !ownership.complete, "late close invented recovery fencing or dropped original pending ownership")
        if resource == .operation {
            try H.check(ownership.attempted && ownership.state == .succeeded
                && ownership.operation == .uncertain(EIO),
                "final-close uncertainty was converted to confirmed ownership/release")
        } else {
            try H.check(ownership.operation == .notAttempted,
                        "earlier resource failure attempted final operation close")
        }
        // The final operation close may already have closed in the kernel. That
        // uncertainty must stay pending; never claim exclusion from a failed
        // syscall. Every earlier cut still retains the actual original EX.
        if resource != .operation { try InstallationOwnershipFixtures.excluded(location) }
        try H.refuses { try bootstrap.finishFreshInstallation() }
    }
    /// This cut is distinct from an uncertain close: the original operation
    /// descriptor really closes successfully before its original clock expires.
    /// The signed driver must join the actual host and guardian after this helper.
    static func authenticatedSuccessfulOperationCloseDeadline(_ bootstrap: InstallationBootstrap,
                                                              location: StateLocation) throws {
        guard bootstrap.coordinationCleanupObservation() == .complete,
              let journal = bootstrap.testingTerminalJournal() else {
            throw H.Failure(message: "signed successful-close cut prerequisites absent")
        }
        let before = try stored(location, profile: journal.testingValidationProfile)
        var operationBefore = stat(), operationAfter = stat()
        try H.check(lstat(location.path + "/operation.lock", &operationBefore) == 0,
                    "successful-close operation preimage absent")
        try InstallationOwnershipFixtures.excluded(location)
        journal.testingTerminalDeadlineAfterSuccessfulClose = .operation
        try H.refuses { try bootstrap.finishFreshInstallation() }
        guard let finish = journal.testingTerminalPermit else {
            throw H.Failure(message: "successful-close pending finish absent")
        }
        let ownership = journal.testingOwner.testingTerminalOwnership()
        let after = try stored(location, profile: journal.testingValidationProfile)
        try H.check(journal.testingTerminalDeadlineAfterSuccessfulClose == nil
            && finish.deadline.hasExpired && journal.testingTerminalUncertainClose == nil
            && ownership.attempted && !ownership.complete
            && ownership.operation == .succeeded && ownership.state == .succeeded
            && bootstrap.completionObservation() == .pending && journal.terminalObservation() == .pending
            && journal.testingTerminalCustodyRetained,
                    "successful close deadline cut lost truthful pending ownership")
        try H.check(after == finish.control && after.phase == .committed
            && after.step?.action == .finish && after.step?.status == .complete
            && after.readinessCommit == before.readinessCommit && after.recoveryReason == nil
            && journal.readinessCommitOutcome().recovery == nil,
                    "successful close deadline cut changed durable finish or commit")
        try H.check(lstat(location.path + "/operation.lock", &operationAfter) == 0
            && operationBefore.st_dev == operationAfter.st_dev && operationBefore.st_ino == operationAfter.st_ino,
                    "successful close deadline cut replaced operation inode")
        let raw = open(location.path + "/operation.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw H.Failure(message: "successful-close contender open failed") }
        let contender = OwnedFileDescriptor(raw)
        try H.check(flock(raw, LOCK_EX | LOCK_NB) == 0,
                    "successful close still retained operation exclusion")
        try H.check(contender.retireChecked() == .succeeded, "successful-close contender retirement uncertain")
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.check((try stored(location, profile: journal.testingValidationProfile)) == after && journal.testingTerminalCustodyRetained,
                    "successful close retry changed finish or dropped pending custody")
    }
    static func authenticatedSyncCut(_ bootstrap: InstallationBootstrap, location: StateLocation,
                                     cut: J.TestingTerminalCut) throws {
        guard bootstrap.coordinationCleanupObservation() == .complete,
              let journal = bootstrap.testingTerminalJournal() else { throw H.Failure(message: "signed sync cut prerequisites absent") }
        let before = try stored(location, profile: journal.testingValidationProfile)
        journal.testingTerminalCut = cut
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.check(journal.testingTerminalCut == nil && journal.terminalObservation() == .pending
            && (try stored(location, profile: journal.testingValidationProfile)).readinessCommit == before.readinessCommit,
                    "terminal sync cut lost committed identity")
        try InstallationOwnershipFixtures.excluded(location)
        try H.refuses { try bootstrap.finishFreshInstallation() }
    }
}
#endif
