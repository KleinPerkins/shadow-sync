import Foundation

/// Retain this coordinator-owned object BEFORE calling reserve. It connects the
/// existing fresh-install owners. reserve stops at the completed reserve action;
/// prepareExclusive continues that same journal once through promotePlist.
/// transferToStagedAdmission then retains the existing detached intent/admission.
/// continueStagedJournal retains its actual journal without completing admission.
/// No owner accessor, release, recovery or command entry is exposed.
/// A failed attempt retains its actual owners for the coordinator's lifetime;
/// durable initialization/control records, not this lifetime, fence process loss.
final class InstallationBootstrap {
    enum Stage: String, CaseIterable {
        case authenticated, parentsRetained, parentsPrepared, initializerRetained
        case statePublished, authorityRetained, ownerConsumed, lifecycleRetained
        case journalRetained, reserveIntent, reserveComplete
    }
    /// Diagnostic observations only. Neither progress nor a successful return
    /// grants authority to reconstruct an owner or to continue another journal.
    struct Observation: Equatable {
        let stage: Stage
        let attempted: Bool
        let failedClosed: Bool
    }
    enum ExclusivePreparation: String { case notAttempted, running, complete, failed }
    private var exclusivePreparation: ExclusivePreparation = .notAttempted
    enum StagedTransfer: String { case notAttempted, running, complete, failed }
    private var stagedTransfer: StagedTransfer = .notAttempted
    private var stagedIntent: CustodyCatalogStore.InstallationStagedAdmissionIntent?
    private var stagedAdmission: InstallationStagedAdmission?
    enum StagedJournalContinuation: String { case notAttempted, running, complete, failed }
    private var stagedJournalContinuation: StagedJournalContinuation = .notAttempted
    private var stagedJournal: CustodyCatalogStore.InstallationStagedJournal?
    private var invocationDeadline: MonotonicDeadline?
    private let publisher: LifecyclePublisher?
    private let source: LifecyclePublisher.InstallationIdentity?
    private let mutex = NSLock()
    private var attempted = false
    private var failedClosed = false
    private var stage: Stage = .authenticated
    private var parents: InstallationParentPreparation?
    private var initializer: FreshStateInitialization?
    private var original: RunAuthority?
    private var owner: InstallationTransactionOwner?
    private var lifecycle: InstallationLifecycle?
    private var journal: CustodyCatalogStore.InstallationJournalSession?
    #if SHADOW_SYNC_TESTING
    private var fixtureRoot: String?
    private var cut: Stage?
    private var mutation: ((Stage) throws -> Void)?
    private var parentCut: InstallationParentPreparation.Cut?
    private var initializationFault: FreshStateInitialization.Fault?
    private var journalCut: CustodyCatalogStore.InstallationJournalSession.Cut?
    private var captureFault: CustodyCatalogStore.Fault?
    private var cutCompletion = false
    private var exclusiveCandidate: InstallationCandidate?
    private var exclusiveRegistry: RetainedCleanupRegistry?
    private var exclusiveDiagnostic = "installation-absent"
    private var exclusiveFault: @Sendable (String) throws -> Void = { _ in }
    private var exclusiveAfterClaim: (() throws -> Void)?
    enum TransferCheckpoint { case claimed, intentRetained, aliasesReleased, borrowingClosed, retired }
    private var transferCheckpoint: ((TransferCheckpoint) throws -> Void)?
    private var transferObservation: (() throws -> Void)?
    private var transferPostflight: (() throws -> Void)?
    private var transferIntentCut = false
    private var transferBorrow = false
    private var transferAlias: CustodyAuthorityLeaseSet?
    private var actualAliasesRetired = [false, false, false]
    private var stagedJournalAfterClaim: (() throws -> Void)?
    private var stagedJournalAfterReturn: (() throws -> Void)?
    private var stagedJournalHoldBorrow = false
    private var stagedJournalAlias: CustodyAuthorityLeaseSet?
    #endif

    private init(publisher: LifecyclePublisher?, source: LifecyclePublisher.InstallationIdentity?) {
        self.publisher = publisher; self.source = source
    }
    /// This factory performs authentication only. It has no account-directory
    /// effects and cannot discard a partially effective bootstrap on a throw.
    static func production() throws -> InstallationBootstrap {
        #if SHADOW_SYNC_TESTING
        throw CustodyRecordError.fenced
        #else
        let publisher = try LifecyclePublisher.current()
        let source = try publisher.installationIdentity()
        try source.revalidate(); try publisher.revalidate()
        return Self(publisher: publisher, source: source)
        #endif
    }
    func observation() -> Observation {
        mutex.lock(); defer { mutex.unlock() }
        return Observation(stage: stage, attempted: attempted, failedClosed: failedClosed)
    }
    private func authenticate() throws {
        if let publisher, let source {
            try publisher.revalidate(); try source.revalidate()
            guard try publisher.installationIdentity() == source else { throw CustodyRecordError.fenced }
        } else {
            #if SHADOW_SYNC_TESTING
            guard let fixtureRoot, try TestIsolation.validateRoot(fixtureRoot) == fixtureRoot else {
                throw CustodyRecordError.fenced
            }
            #else
            throw CustodyRecordError.fenced
            #endif
        }
    }
    private func boundary(_ deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        try authenticate()
        guard let parents else { throw CustodyRecordError.fenced }
        try parents.revalidate()
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
    }
    private func advance(_ value: Stage) throws {
        stage = value
        #if SHADOW_SYNC_TESTING
        try mutation?(value)
        if cut == value { throw CustodyRecordError.injectedFailure }
        #endif
    }
    /// Exactly one attempt and one absolute caller deadline. Each real owner is
    /// stored before the next fallible step. Catch never releases, replays,
    /// fabricates recovery/cleanup evidence, or replaces the durable journal.
    func reserve(deadline: MonotonicDeadline) throws {
        guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
        guard !attempted, !failedClosed else { throw CustodyRecordError.fenced }
        attempted = true
        invocationDeadline = deadline
        do {
            try authenticate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try advance(.authenticated)
            if let publisher, let source {
                parents = try .production(publisher: publisher, source: source)
            } else {
                #if SHADOW_SYNC_TESTING
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                parents = try .testing(root: fixtureRoot)
                #else
                throw CustodyRecordError.fenced
                #endif
            }
            try advance(.parentsRetained)
            #if SHADOW_SYNC_TESTING
            parents!.testingCut(parentCut)
            #endif
            try authenticate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try parents!.prepare()
            try advance(.parentsPrepared)
            try boundary(deadline)
            if let publisher, let source {
                initializer = try .production(publisher: publisher, source: source)
            } else {
                #if SHADOW_SYNC_TESTING
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                initializer = try .testing(root: fixtureRoot)
                #else
                throw CustodyRecordError.fenced
                #endif
            }
            try advance(.initializerRetained)
            #if SHADOW_SYNC_TESTING
            if let initializationFault { initializer!.testingFault(initializationFault) }
            #endif
            try boundary(deadline)
            _ = try initializer!.publish()
            try advance(.statePublished)
            try boundary(deadline)
            original = try initializer!.takeInstallationAuthority()
            try advance(.authorityRetained)
            try boundary(deadline)
            if let publisher {
                owner = try InstallationTransactionOwner.consume(original!, publisher: publisher)
            } else {
                #if SHADOW_SYNC_TESTING
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                owner = try InstallationTransactionOwner.testingConsume(original!, root: fixtureRoot)
                #else
                throw CustodyRecordError.fenced
                #endif
            }
            try advance(.ownerConsumed)
            try boundary(deadline)
            if publisher != nil {
                let paths = try InstallationPaths.production()
                guard paths.home == publisher!.account.homeDirectory,
                      paths.state.uid == publisher!.account.uid else { throw CustodyRecordError.fenced }
                lifecycle = InstallationLifecycle(paths: paths,
                    launchAgent: SystemLaunchAgentController(), host: SystemInstalledHostController())
            } else {
                #if SHADOW_SYNC_TESTING
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                if let exclusiveCandidate {
                    let binding = try InstallationBindingTestingSource(root: fixtureRoot, candidate: exclusiveCandidate,
                        process: ProcessIdentity.capture(processID: ProcessInfo.processInfo.processIdentifier, generation: RunIdentity.make()),
                        boot: CustodyBootIdentity.current())
                    try owner!.testingSetBindingSource(binding)
                } else {
                    try owner!.testingSetBindingSource(InstallationOwnershipFixtures.bindingSource(fixtureRoot, original!))
                }
                lifecycle = try InstallationLifecycle(paths: .isolated(root: fixtureRoot),
                    launchAgent: InstallationSlotCaptureFixtures.NoCommands(), host: InstallationSlotCaptureFixtures.NoCommands(),
                    fault: exclusiveFault)
                if let exclusiveRegistry {
                    lifecycle!.testingExclusiveRoot = fixtureRoot
                    lifecycle!.testingExclusiveRegistry = exclusiveRegistry
                    lifecycle!.testingExclusiveDiagnostic = exclusiveDiagnostic
                }
                #else
                throw CustodyRecordError.fenced
                #endif
            }
            #if SHADOW_SYNC_TESTING
            lifecycle!.testingSlotCaptureStoreFault = captureFault
            #endif
            try advance(.lifecycleRetained)
            try boundary(deadline)
            journal = try owner!.installationJournal(intent: .install, lifecycle: lifecycle!)
            try advance(.journalRetained)
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            if !cutCompletion { journal!.testingCut(journalCut) }
            #endif
            _ = try journal!.begin(deadline: deadline)
            try advance(.reserveIntent)
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            if cutCompletion { journal!.testingCut(journalCut) }
            #endif
            _ = try journal!.completeReservation(deadline: deadline)
            try advance(.reserveComplete)
            try boundary(deadline)
        } catch {
            failedClosed = true
            throw error
        }
    }

    /// An observation is not a continuation capability. Only this retained
    /// instance can claim its original journal; no caller timeout can replace
    /// the absolute deadline captured by reserve.
    func exclusiveObservation() -> ExclusivePreparation {
        mutex.lock(); defer { mutex.unlock() }
        return exclusivePreparation
    }
    func prepareExclusive() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, stage == .reserveComplete,
              exclusivePreparation == .notAttempted,
              let deadline = invocationDeadline, let journal else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        exclusivePreparation = .running
        mutex.unlock()
        // No bootstrap mutex spans authentication, commands or retirement. All
        // original owners remain fields of this live instance on both outcomes.
        do {
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            try exclusiveAfterClaim?()
            #endif
            try boundary(deadline)
            _ = try journal.prepareExclusive(deadline: deadline)
            try boundary(deadline)
            mutex.lock(); exclusivePreparation = .complete; mutex.unlock()
        } catch {
            mutex.lock(); failedClosed = true; exclusivePreparation = .failed; mutex.unlock()
            throw error
        }
    }

    func stagedObservation() -> StagedTransfer {
        mutex.lock(); defer { mutex.unlock() }
        return stagedTransfer
    }
    /// Claim once on this retained instance. Keep the original operation owner
    /// and deadline; only the old admission aliases are retired here. Failure
    /// never resets the claim, drops the durable intent, or reopens borrowing.
    func transferToStagedAdmission() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, exclusivePreparation == .complete,
              stagedTransfer == .notAttempted, journal != nil,
              let owner, let deadline = invocationDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        stagedTransfer = .running
        mutex.unlock()
        #if SHADOW_SYNC_TESTING
        defer {
            transferCheckpoint = nil; transferObservation = nil; transferPostflight = nil
            owner.testingObserveAdmissionTransfer(nil)
            owner.testingObserveAdmissionPostflight(nil)
        }
        #endif
        do {
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            try transferCheckpoint?(.claimed)
            owner.testingObserveAdmissionTransfer(transferObservation)
            owner.testingObserveAdmissionPostflight(transferPostflight)
            transferObservation = nil; transferPostflight = nil
            if transferIntentCut { journal!.testingCut(.afterReceipt) }
            if transferBorrow { transferAlias = try owner.retainExclusiveLeases() }
            #endif
            // Do not bind journal/lifecycle/initializer to local strong aliases:
            // their fields must be the last owners before closeBorrowing.
            stagedIntent = try journal!.stagedAdmissionIntent(deadline: deadline)
            #if SHADOW_SYNC_TESTING
            try transferCheckpoint?(.intentRetained)
            weak var releasedInitializer = initializer
            weak var releasedJournal = journal
            weak var releasedLifecycle = lifecycle
            #endif
            journal = nil; lifecycle = nil; initializer = nil
            #if SHADOW_SYNC_TESTING
            actualAliasesRetired = [releasedInitializer == nil, releasedJournal == nil, releasedLifecycle == nil]
            try transferCheckpoint?(.aliasesReleased)
            #endif
            try boundary(deadline)
            let closed = try owner.closeBorrowing()
            #if SHADOW_SYNC_TESTING
            try transferCheckpoint?(.borrowingClosed)
            let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
            #else
            let registry = RetainedCleanupRegistry.shared
            #endif
            // This is the actual preparation registry (shared in production,
            // injected into the existing lifecycle in disposable fixtures).
            let retirement = try registry.installationRetirement(after: closed)
            #if SHADOW_SYNC_TESTING
            try transferCheckpoint?(.retired)
            #endif
            try boundary(deadline)
            stagedAdmission = try owner.transferToStagedAdmission(intent: stagedIntent!,
                after: retirement, deadline: deadline)
            try stagedAdmission!.revalidate()
            try boundary(deadline)
            mutex.lock(); stagedTransfer = .complete; mutex.unlock()
        } catch {
            // A checkpoint or intent-publication cut may precede alias release.
            // Close the same owner's gate even then; live aliases may refuse
            // drainage, but can never make this bootstrap retryable.
            _ = try? owner.closeBorrowing()
            mutex.lock(); failedClosed = true; stagedTransfer = .failed; mutex.unlock()
            throw error
        }
    }

    func stagedJournalObservation() -> StagedJournalContinuation {
        mutex.lock(); defer { mutex.unlock() }
        return stagedJournalContinuation
    }
    /// Continue the actual retained admission once, using reserve's original
    /// absolute deadline. A successful constructor is retained before postflight;
    /// it neither completes ordinal 12 nor creates readiness or command resources.
    func continueStagedJournal() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, exclusivePreparation == .complete,
              stagedTransfer == .complete, stagedJournalContinuation == .notAttempted,
              let admission = stagedAdmission, let intent = stagedIntent,
              let owner, let deadline = invocationDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        stagedJournalContinuation = .running
        #if SHADOW_SYNC_TESTING
        // Consume synchronous hooks before invoking them outside every bootstrap
        // lock. Reentry observes running and cannot reach a second constructor.
        let afterClaim = stagedJournalAfterClaim, afterReturn = stagedJournalAfterReturn
        stagedJournalAfterClaim = nil; stagedJournalAfterReturn = nil
        #endif
        mutex.unlock()
        do {
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            try afterClaim?()
            #endif
            try boundary(deadline)
            let continued = try admission.continueJournal(deadline: deadline)
            mutex.lock(); stagedJournal = continued; mutex.unlock()
            #if SHADOW_SYNC_TESTING
            if stagedJournalHoldBorrow { stagedJournalAlias = try admission.retainStartLeases() }
            try afterReturn?()
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: intent)
            try intent.revalidate(for: owner, deadline: deadline)
            try boundary(deadline)
            mutex.lock(); stagedJournalContinuation = .complete; mutex.unlock()
        } catch {
            mutex.lock(); failedClosed = true; stagedJournalContinuation = .failed; mutex.unlock()
            // Closing this same admission fences future starts even if outstanding
            // aliases make drainage refuse. A failed close is never cleanup proof.
            // Keep owner, intent, admission and any actual returned journal.
            _ = try? admission.closeStarts()
            throw error
        }
    }

    #if SHADOW_SYNC_TESTING
    @inline(never)
    func testingConfigureStagedJournal(holdBorrow: Bool = false,
        afterClaim: (() throws -> Void)? = nil, afterReturn: (() throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted, !failedClosed else { throw CustodyRecordError.fenced }
        stagedJournalAfterClaim = afterClaim; stagedJournalAfterReturn = afterReturn
        stagedJournalHoldBorrow = holdBorrow
    }
    @inline(never)
    func testingStagedJournalRetention() -> [Bool] {
        mutex.lock(); defer { mutex.unlock() }
        return [stagedJournal != nil, stagedIntent != nil, stagedAdmission != nil,
                owner != nil, original != nil, stagedJournalAlias != nil]
    }
    @inline(never)
    func testingStagedJournalStartsRefused() throws -> Bool {
        guard let stagedAdmission else { throw CustodyRecordError.fenced }
        do { _ = try stagedAdmission.retainStartLeases(); return false } catch { return true }
    }
    @inline(never)
    func testingReleaseStagedJournalBorrow() { stagedJournalAlias = nil }
    @inline(never)
    func testingConfigureStagedTransfer(holdBorrow: Bool = false, intentReceiptCut: Bool = false,
        checkpoint: ((TransferCheckpoint) throws -> Void)? = nil,
        acquisition: (() throws -> Void)? = nil, postflight: (() throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted, !failedClosed else { throw CustodyRecordError.fenced }
        transferBorrow = holdBorrow; transferIntentCut = intentReceiptCut; transferCheckpoint = checkpoint
        transferObservation = acquisition; transferPostflight = postflight
    }
    func testingStagedRetention() -> [Bool] {
        mutex.lock(); defer { mutex.unlock() }
        return actualAliasesRetired + [stagedIntent != nil, stagedAdmission != nil, owner != nil, original != nil]
    }
    @inline(never)
    func testingReleaseTransferBorrow() { transferAlias = nil }
    func testingStagedIdentity() throws -> Bool {
        guard let stagedIntent, let owner else { throw CustodyRecordError.fenced }
        if let stagedAdmission { try stagedAdmission.validateOwner(owner, intent: stagedIntent) }
        else { try stagedIntent.revalidate(for: owner, deadline: invocationDeadline!) }
        return !owner.commandAdmissionIsOpen
    }
    /// Configured before reservation only, on an existing owned fixture root.
    /// The root retains both this bootstrap and the actual command registry.
    func testingConfigureExclusive(candidate: InstallationCandidate, registry: RetainedCleanupRegistry,
        diagnostic: String = "installation-absent", fault: @escaping @Sendable (String) throws -> Void = { _ in },
        afterClaim: (() throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted, let fixtureRoot else { throw CustodyRecordError.fenced }
        _ = try RuntimeFixtureSession.installationRoot(fixtureRoot)
        exclusiveCandidate = candidate; exclusiveRegistry = registry
        exclusiveDiagnostic = diagnostic; exclusiveFault = fault; exclusiveAfterClaim = afterClaim
    }
    static func testing(root: String) throws -> InstallationBootstrap {
        let root = try TestIsolation.validateRoot(root)
        let value = Self(publisher: nil, source: nil); value.fixtureRoot = root
        return value
    }
    func testingConfigure(cut: Stage? = nil, parentCut: InstallationParentPreparation.Cut? = nil,
                          initializationFault: FreshStateInitialization.Fault? = nil,
                          journalCut: CustodyCatalogStore.InstallationJournalSession.Cut? = nil,
                          captureFault: CustodyCatalogStore.Fault? = nil, cutCompletion: Bool = false,
                          mutation: ((Stage) throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted else { throw CustodyRecordError.fenced }
        self.cut = cut; self.parentCut = parentCut; self.initializationFault = initializationFault
        self.journalCut = journalCut; self.mutation = mutation
        self.captureFault = captureFault; self.cutCompletion = cutCompletion
    }
    /// Presence observations never expose a descriptor, lease or journal.
    func testingRetained() -> [Bool] {
        mutex.lock(); defer { mutex.unlock() }
        return [parents != nil, initializer != nil, original != nil,
                owner != nil, lifecycle != nil, journal != nil]
    }
    func testingOneUseRefusals() throws -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard let fixtureRoot, let initializer, let original, let owner, let lifecycle, let journal else {
            throw CustodyRecordError.fenced
        }
        do { _ = try initializer.takeInstallationAuthority(); return false } catch {}
        do { _ = try InstallationTransactionOwner.testingConsume(original, root: fixtureRoot); return false } catch {}
        do { _ = try owner.installationJournal(intent: .install, lifecycle: lifecycle); return false } catch {}
        do { _ = try journal.begin(deadline: .init(seconds: 0.750)); return false } catch {}
        return true
    }
    #endif
}
