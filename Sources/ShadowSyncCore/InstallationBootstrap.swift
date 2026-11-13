import Foundation

/// Retain this coordinator-owned object BEFORE calling reserve. It connects the
/// existing fresh-install owners. reserve stops at the completed reserve action;
/// prepareExclusive continues that same journal once through promotePlist.
/// transferToStagedAdmission then retains the existing detached intent/admission.
/// continueStagedJournal retains its actual journal; openStagedReadiness then
/// completes admission once through that journal, retaining its actual service.
/// Fixed bootstrap/kickstart continue through original staged command custody.
/// No owner accessor, generic command, release or recovery entry is exposed.
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
    enum StagedReadinessOpening: String { case notAttempted, running, complete, failed }
    private var stagedReadinessOpening: StagedReadinessOpening = .notAttempted
    enum StagedReadinessClosure: String { case notAttempted, joined, pending }
    private var stagedReadinessClosure: StagedReadinessClosure = .notAttempted
    // Durable observation only. Service/endpoint ownership remains in the exact
    // retained journal, including a partial creation that throws before return.
    private var openedAdmission: InstallationControlRecord?
    enum StagedStart: String { case notAttempted, running, complete, failed }
    private var bootstrapStart: StagedStart = .notAttempted
    private var kickstartStart: StagedStart = .notAttempted
    private var bootstrapExecution: StartExecution?
    private var kickstartExecution: StartExecution?
    enum FailedStartRetirement: String { case notAttempted, collecting, pending, retired }
    private var failedStartRetirement: FailedStartRetirement = .notAttempted
    private var handlingStartFailure = false
    private var failedClosedStarts: ClosedInstallationStagedStarts?
    private var failedStartsRetired: RetainedCleanupRegistry.InstallationStagedStartRetirement?
    /// Retained before intent publication. Uncertain submissions keep the exact
    /// context, prepared resources and handle; only real retirement releases the
    /// command aliases. Result observations cannot manufacture this owner.
    private final class StartExecution {
        struct State {
            var intent: CustodyCatalogStore.InstallationStagedCommandObservation?
            var context: CommandCustodyContext?
            var command: PreparedCustodyCommand?
            var handle: RetainedCleanupRegistry.Handle?
            var retirement: RetainedCleanupRegistry.StagedCommandCompletion?
            var recoveryRetirement: RetainedCleanupRegistry.StagedRecoveryRetirement?
            var contextClosed = false
            var aliasesReleased = false
            var completed: InstallationControlRecord?
        }
        private let lock = NSLock()
        private var state = State()
        func read<Value>(_ body: (State) throws -> Value) rethrows -> Value {
            lock.lock(); defer { lock.unlock() }; return try body(state)
        }
        func store(_ body: (inout State) -> Void) {
            lock.lock(); defer { lock.unlock() }; body(&state)
        }
        func makeContext(_ create: () throws -> CommandCustodyContext) throws {
            let context = try create(); store { $0.context = context }
        }
        func makeCommand(_ prepare: (CommandCustodyContext) throws -> PreparedCustodyCommand) throws {
            guard let context = read({ $0.context }) else { throw CustodyRecordError.fenced }
            let command = try prepare(context); store { $0.command = command }
        }
        func submit(to registry: RetainedCleanupRegistry) throws {
            guard let command = read({ $0.command }) else { throw CustodyRecordError.fenced }
            let handle = try registry.start(command); store { $0.handle = handle }
        }
        func closeContext() {
            lock.lock()
            let context = state.contextClosed ? nil : state.context
            state.contextClosed = true
            lock.unlock()
            context?.close()
        }
        func cancelAndClose() {
            read { $0.handle }?.cancel()
            closeContext()
        }
        // Called only after actual registry retirement (or fixture teardown).
        // Destructors and scope callbacks run after releasing the state lock.
        func releaseCommandAliases() {
            lock.lock()
            let aliases = (state.command, state.context)
            state.command = nil; state.context = nil; state.aliasesReleased = true
            lock.unlock()
            withExtendedLifetime(aliases) {}
        }
    }
    enum CandidateReadiness: String { case notAttempted, running, complete, failed }
    private var candidateReadiness: CandidateReadiness = .notAttempted
    private var candidateExecution: ReadyExecution?
    private var candidateDeadline: MonotonicDeadline?
    enum ReadinessCommitProgress: String { case notAttempted, running, delivered, failed }
    enum CommitFailureDisposition: String { case noCommitObserved, pending, fenced }
    private var readinessCommitProgress: ReadinessCommitProgress = .notAttempted
    private var commitFailureDisposition: CommitFailureDisposition = .noCommitObserved
    private var commitOutcome: CustodyCatalogStore.InstallationStagedJournal.CommitOutcome?
    private var commitDelivered: InstallationPrecommitSession.CommitDelivered?
    enum NormalStartupProgress: String { case notAttempted, running, observed, failed }
    private var normalStartupProgress: NormalStartupProgress = .notAttempted
    private var normalStarted: InstallationPrecommitSession.NormalStarted?
    private var stoppedHost: InstallationPrecommitSession.Stopped?
    private var stoppedDeliveryProgress: CustodyCatalogStore.InstallationStagedJournal.StopRetirementProgress = .notAttempted
    func stoppedDeliveryObservation() -> CustodyCatalogStore.InstallationStagedJournal.StopRetirementProgress {
        mutex.lock(); defer { mutex.unlock() }; return stoppedDeliveryProgress
    }
    private var stopStartedHostAttempted = false
    func normalStartupObservation() -> NormalStartupProgress {
        mutex.lock(); defer { mutex.unlock() }; return normalStartupProgress
    }
    func observeNormalStartup() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard !failedClosed, readinessCommitProgress == .delivered,
              normalStartupProgress == .notAttempted, let journal = stagedJournal,
              let deadline = candidateDeadline else { mutex.unlock(); throw CustodyRecordError.fenced }
        normalStartupProgress = .running; mutex.unlock()
        do {
            try boundary(deadline)
            let observed = try journal.takeNormalStarted()
            mutex.lock(); normalStarted = observed; mutex.unlock()
            try boundary(deadline)
            mutex.lock(); normalStartupProgress = .observed; mutex.unlock()
        } catch {
            mutex.lock(); normalStartupProgress = .failed; failedClosed = true; mutex.unlock()
            _ = try? journal.fenceReadinessCommitFailure()
            retainCommitOutcome(from: journal)
            throw error
        }
    }
    enum CoordinationCleanupProgress: String { case notAttempted, running, complete, pending }
    private var coordinationCleanupProgress: CoordinationCleanupProgress = .notAttempted
    private var coordinationCleanupControl: InstallationControlRecord?
    func coordinationCleanupObservation() -> CoordinationCleanupProgress {
        mutex.lock(); defer { mutex.unlock() }; return coordinationCleanupProgress
    }
    /// Continue this retained invocation only; no journal, owner or retirement
    /// capability escapes, and no operation owner is released by this step.
    func cleanupReadinessCoordination() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard !failedClosed, normalStartupProgress == .observed,
              coordinationCleanupProgress == .notAttempted,
              let normalStarted, let journal = stagedJournal, let deadline = candidateDeadline,
              deadline.absoluteUptimeNanoseconds == normalStarted.deadline.absoluteUptimeNanoseconds else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        coordinationCleanupProgress = .running; mutex.unlock()
        do {
            try boundary(deadline)
            let completed = try journal.cleanupCoordination(after: normalStarted)
            mutex.lock(); coordinationCleanupControl = completed; mutex.unlock()
            try boundary(deadline)
            mutex.lock(); coordinationCleanupProgress = .complete; mutex.unlock()
        } catch {
            mutex.lock(); coordinationCleanupProgress = .pending; failedClosed = true; mutex.unlock()
            _ = try? journal.fenceReadinessCommitFailure()
            retainCommitOutcome(from: journal)
            throw error
        }
    }
    enum CompletionProgress: String { case notAttempted, running, complete, pending }
    private var completionProgress: CompletionProgress = .notAttempted
    private var completedInstallation: InstallationControlRecord?
    func completionObservation() -> CompletionProgress {
        mutex.lock(); defer { mutex.unlock() }; return completionProgress
    }
    /// Complete the same successful fresh invocation. An observation cannot
    /// release or reconstruct its owner. CLI installation remains unenrolled.
    func finishFreshInstallation() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard !failedClosed, coordinationCleanupProgress == .complete,
              completionProgress == .notAttempted, let journal = stagedJournal,
              let parents, let deadline = candidateDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        completionProgress = .running; mutex.unlock()
        do {
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
            #else
            let registry = RetainedCleanupRegistry.shared
            #endif
            let completed = try journal.finishFreshInstallation(parents: parents, registry: registry)
            // Its result follows checked final operation close. Retired parent
            // descriptions must not be revalidated or reopened for postflight.
            mutex.lock(); completedInstallation = completed; completionProgress = .complete; mutex.unlock()
        } catch {
            retainCommitOutcome(from: journal)
            mutex.lock(); failedClosed = true; completionProgress = .pending; mutex.unlock()
            throw error
        }
    }
    /// Continue only the retained original committed FRESH drain. The ordinary
    /// successful path stays failed-closed; this explicit route never resets it.
    func repairStoppedFreshInstallation() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard failedClosed, stoppedRecoveryProgress == .exclusive,
              completionProgress == .notAttempted || completionProgress == .pending,
              let exclusive = stoppedExclusive, let journal = stagedJournal, let parents else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        completionProgress = .running; mutex.unlock()
        do {
            #if SHADOW_SYNC_TESTING
            let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
            #else
            let registry = RetainedCleanupRegistry.shared
            #endif
            let result = try journal.repairStoppedFreshInstallation(exclusive, parents: parents, registry: registry)
            mutex.lock(); completedInstallation = result; completionProgress = .complete; mutex.unlock()
        } catch {
            mutex.lock(); completionProgress = .pending; mutex.unlock()
            throw error
        }
    }
    /// Continue only the retained original readiness-only FRESH drain. The ordinary
    /// successful path stays failed-closed; this explicit route never resets it.
    func restoreStoppedFreshInstallation() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard failedClosed, stoppedRecoveryProgress == .exclusive,
              completionProgress == .notAttempted || completionProgress == .pending,
              let exclusive = stoppedExclusive, let journal = stagedJournal, let parents else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        completionProgress = .running; mutex.unlock()
        do {
            #if SHADOW_SYNC_TESTING
            let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
            #else
            let registry = RetainedCleanupRegistry.shared
            #endif
            let result = try journal.restoreStoppedFreshInstallation(exclusive, parents: parents, registry: registry)
            mutex.lock(); completedInstallation = result; completionProgress = .complete; mutex.unlock()
        } catch {
            mutex.lock(); completionProgress = .pending; mutex.unlock()
            throw error
        }
    }
    #if SHADOW_SYNC_TESTING
    var testingFreshRestorationReachedCut: InstallationFreshRestorationCut? { stagedJournal?.testingFreshRestorationReachedCut }
    func testingFreshRestorationCut(_ cut: InstallationFreshRestorationCut) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        try journal.testingFreshRestorationCut(cut)
    }
    var testingFreshRestorationUnlinks: Int { stagedJournal?.testingFreshRestorationUnlinks ?? 0 }
    var testingFreshRestorationResources: InstallationFreshRestorationResourceObservation? { stagedJournal?.testingFreshRestorationResources }
    func testingFreshRestorationMutationBarrier(_ barrier: @escaping (Int, String) throws -> Void) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        try journal.testingFreshRestorationMutationBarrier(barrier)
    }
    func testingFreshRestorationResourceFault(_ fault: InstallationFreshRestorationResourceFault) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        try journal.testingFreshRestorationResourceFault(fault)
    }
    func testingFreshRestorationProbe(_ probe: @escaping (InstallationAction) throws -> Void) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        try journal.testingFreshRestorationProbe(probe)
    }
    func testingReadinessRestorationEndpointCut(_ cut: InstallationReadinessEndpoint.CleanupCut) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        try journal.testingReadinessRestorationCut(cut)
    }
    func testingStoppedRepairPublicationCut(beforeControl: Bool) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        journal.testingCut(beforeControl ? .beforeControl : .afterReceipt)
    }
    func testingStoppedRepairCut(_ cut: InstallationReadinessEndpoint.CleanupCut) throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        try journal.testingStoppedRepairCut(cut)
    }
    #endif
    enum StoppedRecoveryProgress: String { case notAttempted, draining, exclusive, pending }
    private var stoppedRecoveryProgress: StoppedRecoveryProgress = .notAttempted
    private var committedStopExecution: StartExecution?
    private var committedStopCapability: CustodyCatalogStore.InstallationCommittedStop?
    private var committedStopCompletion: CustodyCatalogStore.InstallationCommittedStopCompletion?
    private var closedCommittedStops: ClosedInstallationStagedStops?
    private var committedStopsRetired: RetainedCleanupRegistry.InstallationStagedStopRetirement?
    private var committedDrain: CustodyCatalogStore.InstallationStagedJournal.CandidateDrain?
    private var stoppedRecoveryIntent: CustodyCatalogStore.InstallationStagedJournal.StoppedRecoveryIntent?
    private var stoppedExclusive: InstallationStoppedExclusive?
    func stoppedRecoveryObservation() -> StoppedRecoveryProgress {
        mutex.lock(); defer { mutex.unlock() }; return stoppedRecoveryProgress
    }
    /// Retain this same invocation through authenticated host drain, fixed
    /// bootout and actual registry retirement, then reclaim lifecycle EX under
    /// the original continuously held operation EX. Fixed repair-forward writes
    /// remain a separate continuation; this never reports installation success.
    func stopNormallyStartedHost() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard (normalStartupProgress == .observed || normalStartupProgress == .failed), !stopStartedHostAttempted,
              coordinationCleanupProgress == .notAttempted, completionProgress == .notAttempted,
              let normalStarted, let journal = stagedJournal, let admission = stagedAdmission,
              let owner, let deadline = candidateDeadline,
              deadline.absoluteUptimeNanoseconds == normalStarted.deadline.absoluteUptimeNanoseconds else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        let execution = StartExecution()
        committedStopExecution = execution
        stopStartedHostAttempted = true; failedClosed = true
        stoppedDeliveryProgress = .pending; stoppedRecoveryProgress = .draining; mutex.unlock()
        #if SHADOW_SYNC_TESTING
        let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
        #else
        let registry = RetainedCleanupRegistry.shared
        #endif
        defer {
            retainCommitOutcome(from: journal)
            let (acknowledgment, progress) = journal.stoppedHostObservation()
            mutex.lock(); stoppedHost = acknowledgment
            stoppedDeliveryProgress = progress == .notAttempted ? .pending : progress; mutex.unlock()
        }
        do {
            try boundary(deadline)
            let acknowledgment = try journal.stopStartedHost(normalStarted)
            mutex.lock(); stoppedHost = acknowledgment; mutex.unlock()
            try boundary(deadline)
            let retiredStarts = try registry.installationStagedStartRetirement(after: admission.closeStarts())
            let stop = try admission.stopOnly(after: retiredStarts)
            let capability = try journal.committedCandidateStop(admission: stop)
            mutex.lock(); committedStopCapability = capability; mutex.unlock()
            try execution.makeContext {
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                return try .testingCommittedStop(capability, root: fixtureRoot)
                #else
                return try .borrowing(capability)
                #endif
            }
            try boundary(deadline)
            try execution.makeCommand { context in
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                return try context.testingCommittedBootout()
                #else
                return try context.prepareLifecycle(.bootout, deadline: deadline)
                #endif
            }
            try boundary(deadline)
            try execution.submit(to: registry)
            guard let handle = execution.read({ $0.handle }) else { throw CustodyRecordError.fenced }
            _ = handle.wait()
            let retired = try handle.stagedCompletion()
            execution.store { $0.retirement = retired }
            execution.closeContext(); execution.releaseCommandAliases()
            while true {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                do { _ = try retired.validate(operation: .bootout); break }
                catch {
                    guard !deadline.hasExpired else { throw error }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            try boundary(deadline)
            let completion = try journal.completeCommittedCandidateStop(capability, after: retired)
            mutex.lock(); committedStopCompletion = completion; mutex.unlock()
            let closed = try stop.closeStops(deadline: deadline)
            mutex.lock(); closedCommittedStops = closed; mutex.unlock()
            let stoppedRetirement = try registry.installationStagedStopRetirement(after: closed)
            mutex.lock(); committedStopsRetired = stoppedRetirement; mutex.unlock()
            try boundary(deadline)
            let drain = try journal.committedCandidateDrain(retirement: stoppedRetirement, registry: registry)
            mutex.lock(); committedDrain = drain; mutex.unlock()
            let intent = try journal.stoppedRecoveryIntent(after: drain)
            mutex.lock(); stoppedRecoveryIntent = intent; mutex.unlock()
            let exclusive = try owner.reenterStoppedRecovery(intent)
            mutex.lock(); stoppedExclusive = exclusive; mutex.unlock()
            try boundary(deadline)
            try exclusive.revalidate()
            mutex.lock(); stoppedRecoveryProgress = .exclusive; mutex.unlock()
        } catch {
            // Preserve the actual command/handle/outcome and failed phase. A
            // failed bootout or partial closure cannot mint a replacement drain.
            execution.cancelAndClose()
            mutex.lock(); stoppedRecoveryProgress = .pending; mutex.unlock()
            throw error
        }
    }
    private var readinessStopExecution: StartExecution?
    private var readinessDrain: CustodyCatalogStore.InstallationStagedJournal.ReadinessCandidateDrain?
    /// Bounded precommit branch from this original completed readiness only.
    /// An absent service or lost stream never supplies host drainage; failed
    /// handshakes retain the actual invocation and cannot authorize bootout.
    func stopReadinessOnlyHost() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, candidateReadiness == .complete,
              readinessCommitProgress == .notAttempted, normalStartupProgress == .notAttempted,
              coordinationCleanupProgress == .notAttempted, completionProgress == .notAttempted,
              stoppedRecoveryProgress == .notAttempted, !stopStartedHostAttempted,
              let journal = stagedJournal, let admission = stagedAdmission,
              let owner, let deadline = candidateDeadline else { mutex.unlock(); throw CustodyRecordError.fenced }
        let execution = StartExecution(); readinessStopExecution = execution
        stopStartedHostAttempted = true; failedClosed = true
        stoppedDeliveryProgress = .pending; stoppedRecoveryProgress = .draining; mutex.unlock()
        #if SHADOW_SYNC_TESTING
        let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
        #else
        let registry = RetainedCleanupRegistry.shared
        #endif
        defer {
            let (acknowledgment, progress) = journal.stoppedHostObservation()
            mutex.lock(); stoppedHost = acknowledgment
            stoppedDeliveryProgress = progress == .notAttempted ? .pending : progress; mutex.unlock()
        }
        do {
            try boundary(deadline)
            let starts = try registry.installationStagedStartRetirement(after: admission.closeStarts())
            let stop = try admission.stopOnly(after: starts)
            // This publishes durable restrictive intent BEFORE sending stop,
            // then requires checked host release and actual session/service join.
            let observed = try journal.stopReadinessOnlyHost(admission: stop)
            execution.store { $0.intent = observed }
            try boundary(deadline)
            try execution.makeContext {
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                return try .testingStaged(stop, intent: observed, root: fixtureRoot)
                #else
                return try .borrowing(stop, intent: observed, deadline: deadline)
                #endif
            }
            try execution.makeCommand { context in
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10)
                    .clipped(to: deadline, kind: .launchctlMutation, permittedWorkSeconds: 10)
                return try context.testingStagedLifecycle(.bootout, budget: budget)
                #else
                return try context.prepareLifecycle(.bootout, deadline: deadline)
                #endif
            }
            try boundary(deadline)
            try execution.submit(to: registry)
            guard let handle = execution.read({ $0.handle }) else { throw CustodyRecordError.fenced }
            _ = handle.wait()
            let retired = try handle.stagedCompletion()
            execution.store { $0.retirement = retired }
            execution.closeContext(); execution.releaseCommandAliases()
            while true {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                do { _ = try retired.validate(operation: .bootout); break }
                catch {
                    guard !deadline.hasExpired else { throw error }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            try boundary(deadline)
            let completed = try journal.completeCandidateStop(after: retired, deadline: deadline)
            execution.store { $0.completed = completed }
            let closed = try stop.closeStops(deadline: deadline)
            mutex.lock(); closedCommittedStops = closed; mutex.unlock()
            let stoppedRetirement = try registry.installationStagedStopRetirement(after: closed)
            mutex.lock(); committedStopsRetired = stoppedRetirement; mutex.unlock()
            let drain = try journal.readinessCandidateDrain(retirement: stoppedRetirement, registry: registry)
            mutex.lock(); readinessDrain = drain; mutex.unlock()
            let intent = try journal.stoppedRecoveryIntent(after: drain)
            mutex.lock(); stoppedRecoveryIntent = intent; mutex.unlock()
            let exclusive = try owner.reenterStoppedRecovery(intent)
            mutex.lock(); stoppedExclusive = exclusive; mutex.unlock()
            try boundary(deadline); try exclusive.revalidate()
            mutex.lock(); stoppedRecoveryProgress = .exclusive; mutex.unlock()
        } catch {
            execution.cancelAndClose()
            mutex.lock(); stoppedRecoveryProgress = .pending; mutex.unlock()
            throw error
        }
    }
    /// This owner keeps an uncertain diagnostic and its exact returned outcome.
    /// No command scope or prepared alias escapes the production continuation.
    private final class ReadyExecution {
        struct State {
            var intent: CustodyCatalogStore.InstallationStagedCommandObservation?
            var context: CommandCustodyContext?
            var command: PreparedCustodyCommand?
            var handle: RetainedCleanupRegistry.Handle?
            var retirement: RetainedCleanupRegistry.StagedRecoveryRetirement?
            var completed: InstallationControlRecord?
        }
        private let lock = NSLock()
        private var state = State()
        func read<Value>(_ body: (State) throws -> Value) rethrows -> Value {
            lock.lock(); defer { lock.unlock() }; return try body(state)
        }
        func store(_ body: (inout State) -> Void) {
            lock.lock(); defer { lock.unlock() }; body(&state)
        }
        func makeContext(_ create: () throws -> CommandCustodyContext) throws {
            let context = try create(); store { $0.context = context }
        }
        func makeCommand(_ prepare: (CommandCustodyContext) throws -> PreparedCustodyCommand) throws {
            guard let context = read({ $0.context }) else { throw CustodyRecordError.fenced }
            let command = try prepare(context); store { $0.command = command }
        }
        func submit(to registry: RetainedCleanupRegistry) throws {
            guard let command = read({ $0.command }) else { throw CustodyRecordError.fenced }
            let handle = try registry.start(command); store { $0.handle = handle }
        }
        func closeContext() { read { $0.context }?.close() }
        func cancelAndClose() { read { $0.handle }?.cancel(); closeContext() }
        func releaseCommandAliases() { store { $0.command = nil; $0.context = nil } }
    }
    private var invocationDeadline: MonotonicDeadline?
    private let publisher: LifecyclePublisher?
    private let source: LifecyclePublisher.InstallationIdentity?
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    private var signedContext: SignedInstallationFixtureContext?
    private var signedService: SignedInstallationFixtureService?
    #endif
    private let mutex = NSLock()
    private var attempted = false
    private var reserving = false
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
    private var readinessAfterClaim: (() throws -> Void)?
    private var readinessAfterReturn: (() throws -> Void)?
    private var readinessEndpointCut: InstallationReadinessEndpoint.TestingCut?
    private var readinessReceiptCut = false
    private var readinessPublicationBarrier: CustodyLeaseTestingBarrier?
    private var readinessSourceBarrier: CustodyLeaseTestingBarrier?
    enum StartCheckpoint { case claimed, intentRetained, contextRetained, commandRetained, submitted, retirementReceived, aliasesReleased, retired, completed }
    private var startCheckpoint: ((LifecycleLaunchCommand.Operation, StartCheckpoint) throws -> Void)?
    enum FailedStartRetirementCheckpoint { case claimed, retirementRetained, aliasesReleased, validated }
    private var failedStartRetirementCheckpoint: ((FailedStartRetirementCheckpoint) throws -> Void)?
    enum ReadyCheckpoint { case claimed, intentRetained, contextRetained, commandRetained, submitted, retirementReceived, aliasesReleased, retired, completed }
    enum CommitCheckpoint { case claimed, published, delivered }
    private var commitCheckpoint: ((CommitCheckpoint) throws -> Void)?
    private var commitPublicationProbe: CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe?
    private var readyCheckpoint: ((ReadyCheckpoint) throws -> Void)?
    private var readyPublicationProbe: CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe?
    private var startPublicationProbe: CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe?
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
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    static func signedFixture(_ context: SignedInstallationFixtureContext,
                              service: SignedInstallationFixtureService,
                              custody: InstallationReadinessFixtureCustody) throws -> InstallationBootstrap {
        try context.revalidate()
        guard custody.root == URL(fileURLWithPath: context.paths.home).deletingLastPathComponent().path,
              case let .signedFixture(profile) = context.profile else { throw CustodyRecordError.fenced }
        let value = Self(publisher: context.publisher, source: context.source)
        value.signedContext = context; value.signedService = service
        value.fixtureRoot = custody.root
        value.exclusiveRegistry = .testingInstance()
        custody.retain(value.exclusiveRegistry!); custody.retain(value); custody.retainService(service)
        try profile.bindService(service)
        return value
    }
    #endif
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
    private func makeProductionLifecycle() throws -> InstallationLifecycle {
        guard let publisher else { throw CustodyRecordError.fenced }
        let paths = try InstallationPaths.production()
        guard paths.home == publisher.account.homeDirectory, paths.state.uid == publisher.account.uid else { throw CustodyRecordError.fenced }
        return InstallationLifecycle(paths: paths, launchAgent: SystemLaunchAgentController(), host: SystemInstalledHostController())
    }
    private func boundary(_ deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        try authenticate()
        guard let parents else { throw CustodyRecordError.fenced }
        try parents.revalidate()
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
    }
    private func advance(_ value: Stage) throws {
        mutex.lock(); stage = value
        #if SHADOW_SYNC_TESTING
        let callback = mutation, stop = cut == value
        #endif
        mutex.unlock()
        #if SHADOW_SYNC_TESTING
        try callback?(value)
        if stop { throw CustodyRecordError.injectedFailure }
        #endif
    }
    /// Exactly one attempt and one absolute caller deadline. Each real owner is
    /// stored before the next fallible step. Catch never releases, replays,
    /// fabricates recovery/cleanup evidence, or replaces the durable journal.
    func reserve(deadline: MonotonicDeadline) throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard !attempted, !failedClosed else { mutex.unlock(); throw CustodyRecordError.fenced }
        attempted = true; reserving = true
        invocationDeadline = deadline; mutex.unlock()
        defer { mutex.lock(); reserving = false; mutex.unlock() }
        do {
            try authenticate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try advance(.authenticated)
            if let publisher, let source {
                #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
                if let signedContext { parents = try .signedFixture(signedContext) }
                else { parents = try .production(publisher: publisher, source: source) }
                #else
                parents = try .production(publisher: publisher, source: source)
                #endif
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
                #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
                if let signedContext { initializer = try .signedFixture(signedContext) }
                else { initializer = try .production(publisher: publisher, source: source) }
                #else
                initializer = try .production(publisher: publisher, source: source)
                #endif
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
                #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
                if let signedContext { owner = try InstallationTransactionOwner.consumeSignedFixture(original!, context: signedContext) }
                else { owner = try InstallationTransactionOwner.consume(original!, publisher: publisher) }
                #else
                owner = try InstallationTransactionOwner.consume(original!, publisher: publisher)
                #endif
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
                #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
                if let signedContext, let signedService {
                    lifecycle = InstallationLifecycle(paths: signedContext.paths, launchAgent: signedService, host: signedService)
                    lifecycle!.testingExclusiveRegistry = exclusiveRegistry
                } else { lifecycle = try makeProductionLifecycle() }
                #else
                lifecycle = try makeProductionLifecycle()
                #endif
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
            mutex.lock(); failedClosed = true; mutex.unlock()
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
        guard attempted, !reserving, !failedClosed, stage == .reserveComplete,
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
            guard let parents else { throw CustodyRecordError.fenced }
            try continued.bindCompletionParents(parents)
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

    func stagedReadinessObservation() -> StagedReadinessOpening {
        mutex.lock(); defer { mutex.unlock() }; return stagedReadinessOpening
    }
    func stagedReadinessClosureObservation() -> StagedReadinessClosure {
        mutex.lock(); defer { mutex.unlock() }; return stagedReadinessClosure
    }
    /// Open only the exact journal retained by this bootstrap. Returning proves
    /// admission completion, not candidate readiness, startup or installation.
    /// No wait, code verification or service join runs under the bootstrap lock.
    func openStagedReadiness() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, exclusivePreparation == .complete,
              stagedTransfer == .complete, stagedJournalContinuation == .complete,
              stagedReadinessOpening == .notAttempted,
              let journal = stagedJournal, let admission = stagedAdmission,
              let intent = stagedIntent, let owner, let deadline = invocationDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        stagedReadinessOpening = .running
        #if SHADOW_SYNC_TESTING
        let afterClaim = readinessAfterClaim, afterReturn = readinessAfterReturn
        readinessAfterClaim = nil; readinessAfterReturn = nil
        #endif
        mutex.unlock()
        do {
            #if SHADOW_SYNC_TESTING
            // Enroll BEFORE the first call that can create service work. The
            // fixture guardian must refuse root cleanup while a real join waits.
            guard let fixtureRoot else { throw CustodyRecordError.fenced }
            try RuntimeFixtureSession.installationRoot(fixtureRoot).retain(journal)
            if let readinessEndpointCut { journal.testingReadinessCut(readinessEndpointCut) }
            if readinessReceiptCut { journal.testingCut(.afterReceipt) }
            if let readinessPublicationBarrier { journal.testingPausePublication(readinessPublicationBarrier) }
            if let readinessSourceBarrier { journal.testingPauseSource(readinessSourceBarrier) }
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: intent)
            #if SHADOW_SYNC_TESTING
            try afterClaim?()
            #endif
            try boundary(deadline)
            let completed = try journal.completeAdmission(deadline: deadline)
            mutex.lock(); openedAdmission = completed; mutex.unlock()
            #if SHADOW_SYNC_TESTING
            try afterReturn?()
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: intent)
            try journal.validateOpenedAdmission(completed, deadline: deadline)
            try boundary(deadline)
            mutex.lock(); stagedReadinessOpening = .complete; mutex.unlock()
        } catch {
            let failure = error
            mutex.lock(); failedClosed = true; stagedReadinessOpening = .failed; mutex.unlock()
            // Close the actual start gate first. Unretired aliases can refuse
            // drainage without reopening it. Keep all owners and durable evidence.
            _ = try? admission.closeStarts()
            do {
                try journal.closeReadiness(deadline: deadline)
                mutex.lock(); stagedReadinessClosure = .joined; mutex.unlock()
            } catch {
                // Pending is observable, never silently reported as cancellation
                // success. No fresh cleanup deadline or endpoint unlink is allowed.
                mutex.lock(); stagedReadinessClosure = .pending; mutex.unlock()
                throw error
            }
            throw failure
        }
    }

    func bootstrapStartObservation() -> StagedStart {
        mutex.lock(); defer { mutex.unlock() }; return bootstrapStart
    }
    func kickstartStartObservation() -> StagedStart {
        mutex.lock(); defer { mutex.unlock() }; return kickstartStart
    }
    func failedStartRetirementObservation() -> FailedStartRetirement {
        mutex.lock(); defer { mutex.unlock() }; return failedStartRetirement
    }

    /// Collect only the original failed start attempt's actual command retirement.
    /// This is neither host drainage nor installation/exit completion. Partial
    /// construction without a returned handle stays retained: absence of that
    /// handle cannot prove no submission, spawn or outstanding resource owner.
    /// A pending turn may be observed again within the SAME invocation deadline.
    func retireFailedStartCommands() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, failedClosed, !handlingStartFailure,
              bootstrapStart == .failed || kickstartStart == .failed,
              failedStartRetirement == .notAttempted || failedStartRetirement == .pending,
              let admission = stagedAdmission, let owner, let deadline = invocationDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        let executions = [bootstrapExecution, kickstartExecution].compactMap { $0 }
        guard !executions.isEmpty else { mutex.unlock(); throw CustodyRecordError.fenced }
        failedStartRetirement = .collecting
        #if SHADOW_SYNC_TESTING
        let checkpoint = failedStartRetirementCheckpoint
        let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
        #else
        let registry = RetainedCleanupRegistry.shared
        #endif
        mutex.unlock()
        do {
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.claimed)
            #endif
            for execution in executions {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                if execution.read({ $0.recoveryRetirement }) == nil {
                    guard let handle = execution.read({ $0.handle }) else { throw CustodyRecordError.fenced }
                    // No wait, replay, synthetic success or replacement command.
                    let retired = try handle.stagedRecoveryRetirement()
                    execution.store { $0.recoveryRetirement = retired }
                    #if SHADOW_SYNC_TESTING
                    try checkpoint?(.retirementRetained)
                    #endif
                }
                try boundary(deadline)
                if !execution.read({ $0.aliasesReleased }) {
                    execution.closeContext()
                    execution.releaseCommandAliases()
                    #if SHADOW_SYNC_TESTING
                    try checkpoint?(.aliasesReleased)
                    #endif
                }
            }
            // The completed start-failure catch already closed future start
            // admission. Its zero-borrow close proof must wait until genuine
            // retirement tokens permit releasing the retained command aliases.
            // Retain that original proof before any later fallible validation.
            if failedClosedStarts == nil {
                let closed = try admission.closeStarts()
                mutex.lock(); failedClosedStarts = closed; mutex.unlock()
            }
            // Release every actually retired execution's aliases before the
            // owner-wide validator: it deliberately checks all original scopes.
            for execution in executions {
                guard let retired = execution.read({ $0.recoveryRetirement }) else { throw CustodyRecordError.fenced }
                try boundary(deadline)
                _ = try retired.validate()
            }
            try boundary(deadline)
            guard let closed = failedClosedStarts else { throw CustodyRecordError.fenced }
            if failedStartsRetired == nil {
                let retired = try registry.installationStagedStartRetirement(after: closed)
                mutex.lock(); failedStartsRetired = retired; mutex.unlock()
            }
            guard let retired = failedStartsRetired else { throw CustodyRecordError.fenced }
            try retired.revalidate(for: owner)
            try boundary(deadline)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.validated)
            #endif
            try boundary(deadline)
            mutex.lock(); failedStartRetirement = .retired; mutex.unlock()
        } catch {
            // Preserve tokens, partial aliases and the original failure/fence.
            // Unknown/poisoned evidence is returned, never translated to success.
            mutex.lock(); failedStartRetirement = .pending; mutex.unlock()
            throw error
        }
    }

    func bootstrapCandidate() throws { try startCandidate(kickstart: false) }
    func kickstartCandidate() throws { try startCandidate(kickstart: true) }

    /// Two closed transitions, no caller-supplied intent, result, command or clock.
    /// Each claims once, retaining original ownership before every fallible edge.
    /// The serial readiness service stays live throughout the synchronous command.
    private func startCandidate(kickstart: Bool) throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, stagedReadinessOpening == .complete,
              (kickstart ? bootstrapStart == .complete && kickstartStart == .notAttempted
                         : bootstrapStart == .notAttempted),
              let journal = stagedJournal, let admission = stagedAdmission,
              let admissionIntent = stagedIntent, let openedAdmission, let owner,
              let deadline = invocationDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        let execution = StartExecution()
        if kickstart { kickstartStart = .running; kickstartExecution = execution }
        else { bootstrapStart = .running; bootstrapExecution = execution }
        #if SHADOW_SYNC_TESTING
        let checkpoint = startCheckpoint
        let publicationProbe = startPublicationProbe
        let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
        #else
        let registry = RetainedCleanupRegistry.shared
        #endif
        mutex.unlock()
        let operation: LifecycleLaunchCommand.Operation = kickstart ? .kickstart : .bootstrap
        do {
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .claimed)
            if let publicationProbe, publicationProbe.action == (kickstart ? .kickstartCandidate : .bootstrapCandidate) {
                try journal.testingObservePublication(publicationProbe)
            }
            #endif
            try boundary(deadline)
            if !kickstart { try journal.validateOpenedAdmission(openedAdmission, deadline: deadline) }
            let intent = try kickstart ? journal.kickstartCandidateIntent(deadline: deadline)
                : journal.bootstrapCandidateIntent(deadline: deadline)
            execution.store { $0.intent = intent }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .intentRetained)
            #endif
            try boundary(deadline)
            try execution.makeContext {
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                return try .testingStaged(admission, intent: intent, root: fixtureRoot, deadline: deadline)
                #else
                return try .borrowing(admission, intent: intent, deadline: deadline)
                #endif
            }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .contextRetained)
            #endif
            try boundary(deadline)
            try execution.makeCommand { context in
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10)
                    .clipped(to: deadline, kind: .launchctlMutation, permittedWorkSeconds: 10)
                return try context.testingStagedLifecycle(operation, budget: budget)
                #else
                return try context.prepareLifecycle(operation, deadline: deadline)
                #endif
            }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .commandRetained)
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            try execution.submit(to: registry)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .submitted)
            #endif
            guard let handle = execution.read({ $0.handle }) else { throw CustodyRecordError.fenced }
            // Request endpoints are all clipped to reserve's absolute ceiling.
            // No Bootstrap/catalog/authority mutex spans this wait or closure.
            _ = handle.wait()
            try boundary(deadline)
            let retired = try handle.stagedCompletion()
            execution.store { $0.retirement = retired }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .retirementReceived)
            #endif
            execution.closeContext()
            execution.releaseCommandAliases()
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .aliasesReleased)
            #endif
            // Includes terminal fsync, EOF, exact reaping, registry removal and
            // destroyed context/scope aliases. A finished snapshot never suffices.
            // close() queues the existing scope close. Spend only the original
            // ceiling while that final registry callback releases its alias.
            while true {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                do { _ = try retired.validate(operation: operation); break }
                catch {
                    guard !deadline.hasExpired else { throw error }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .retired)
            #endif
            try boundary(deadline)
            let completed = try kickstart ? journal.completeKickstart(after: retired, deadline: deadline)
                : journal.completeBootstrap(after: retired, deadline: deadline)
            execution.store { $0.completed = completed }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(operation, .completed)
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            // completeKickstart consumes the registry's original retirement
            // timestamp. This wrapper never creates another readiness deadline.
            if kickstart { _ = try retired.readinessDeadline() }
            try boundary(deadline)
            mutex.lock()
            if kickstart { kickstartStart = .complete } else { bootstrapStart = .complete }
            mutex.unlock()
        } catch {
            let failure = error
            mutex.lock()
            failedClosed = true; handlingStartFailure = true
            if kickstart { kickstartStart = .failed } else { bootstrapStart = .failed }
            mutex.unlock()
            defer { mutex.lock(); handlingStartFailure = false; mutex.unlock() }
            // Gate closure is permanent even when live aliases prevent drainage.
            // Cancellation is a request, never retirement, candidate-stop or
            // endpoint-unlink proof. Uncertain resources remain in execution.
            _ = try? admission.closeStarts()
            execution.cancelAndClose()
            do {
                try journal.closeReadiness(deadline: deadline)
                mutex.lock(); stagedReadinessClosure = .joined; mutex.unlock()
            } catch {
                mutex.lock(); stagedReadinessClosure = .pending; mutex.unlock()
                throw error
            }
            throw failure
        }
    }

    func candidateReadinessObservation() -> CandidateReadiness {
        mutex.lock(); defer { mutex.unlock() }; return candidateReadiness
    }
    /// The sole original journal takes its actual authenticated ready observation.
    /// A fixed service diagnostic then retires completely before ready completion.
    /// A successful return is convergence only, not commit or normal startup.
    func confirmCandidateReady() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, kickstartStart == .complete,
              candidateReadiness == .notAttempted,
              let journal = stagedJournal, let admission = stagedAdmission,
              let admissionIntent = stagedIntent, let owner,
              let invocation = invocationDeadline,
              let kickstartRetirement = kickstartExecution?.read({ $0.retirement }) else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        let execution = ReadyExecution()
        candidateReadiness = .running; candidateExecution = execution
        #if SHADOW_SYNC_TESTING
        let checkpoint = readyCheckpoint, publicationProbe = readyPublicationProbe
        let registry = exclusiveRegistry ?? RetainedCleanupRegistry.shared
        #else
        let registry = RetainedCleanupRegistry.shared
        #endif
        mutex.unlock()
        // Preserve the original ceiling even if retirement's five seconds end
        // later. No relative deadline is introduced at ready or diagnostic work.
        var deadline = invocation
        do {
            let anchored = try kickstartRetirement.readinessDeadline()
            deadline = MonotonicDeadline(uptimeNanoseconds: min(invocation.absoluteUptimeNanoseconds,
                anchored.absoluteUptimeNanoseconds))
            mutex.lock(); candidateDeadline = deadline; mutex.unlock()
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.claimed)
            if let publicationProbe { try journal.testingObservePublication(publicationProbe) }
            #endif
            try boundary(deadline)
            let intent = try journal.candidateReadyIntent()
            execution.store { $0.intent = intent }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.intentRetained)
            #endif
            try boundary(deadline)
            try execution.makeContext {
                #if SHADOW_SYNC_TESTING && !SHADOW_SYNC_SIGNED_FIXTURE
                guard let fixtureRoot else { throw CustodyRecordError.fenced }
                return try .testingStaged(admission, intent: intent, root: fixtureRoot, deadline: deadline)
                #else
                return try .borrowing(admission, intent: intent, deadline: deadline)
                #endif
            }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.contextRetained)
            #endif
            try boundary(deadline)
            try execution.makeCommand { context in
                let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10)
                    .clipped(to: deadline, kind: .launchctlRead, permittedWorkSeconds: 10)
                // The fixed production adapter independently binds the actual
                // authenticated host and exact launch program. No PID input.
                return try context.prepare(.serviceStatus, budget: budget)
            }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.commandRetained)
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            try execution.submit(to: registry)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.submitted)
            #endif
            guard let handle = execution.read({ $0.handle }) else { throw CustodyRecordError.fenced }
            _ = handle.wait()
            // Retain the actual token before a fallible wrapper postflight.
            let retired = try handle.stagedRecoveryRetirement()
            execution.store { $0.retirement = retired }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.retirementReceived)
            #endif
            execution.closeContext(); execution.releaseCommandAliases()
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.aliasesReleased)
            #endif
            while true {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                do { _ = try retired.validate(); break }
                catch {
                    guard !deadline.hasExpired else { throw error }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.retired)
            #endif
            try boundary(deadline)
            let completed = try journal.completeCandidateReady(after: retired)
            execution.store { $0.completed = completed }
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.completed)
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            mutex.lock(); candidateReadiness = .complete; mutex.unlock()
        } catch {
            let failure = error
            mutex.lock(); failedClosed = true; candidateReadiness = .failed; mutex.unlock()
            _ = try? admission.closeStarts()
            execution.cancelAndClose()
            do {
                try journal.closeReadiness(deadline: deadline)
                mutex.lock(); stagedReadinessClosure = .joined; mutex.unlock()
            } catch {
                mutex.lock(); stagedReadinessClosure = .pending; mutex.unlock()
                throw error
            }
            throw failure
        }
    }

    func readinessCommitObservation() -> ReadinessCommitProgress {
        mutex.lock(); defer { mutex.unlock() }; return readinessCommitProgress
    }
    func commitFailureObservation() -> CommitFailureDisposition {
        mutex.lock(); defer { mutex.unlock() }; return commitFailureDisposition
    }
    private func retainCommitOutcome(from journal: CustodyCatalogStore.InstallationStagedJournal) {
        let outcome = journal.readinessCommitOutcome()
        mutex.lock(); commitOutcome = outcome; mutex.unlock()
    }
    /// Publish/fsync and deliver only through the exact retained journal once.
    /// Delivered means bytes written, never host consumption, normal startup,
    /// cleanup, operation release or installation success.
    func commitCandidateReadiness() throws {
        guard mutex.try() else { throw CustodyRecordError.busy }
        guard attempted, !failedClosed, candidateReadiness == .complete,
              readinessCommitProgress == .notAttempted,
              let journal = stagedJournal, let admission = stagedAdmission,
              let admissionIntent = stagedIntent, let owner, let deadline = candidateDeadline else {
            mutex.unlock(); throw CustodyRecordError.fenced
        }
        readinessCommitProgress = .running
        #if SHADOW_SYNC_TESTING
        let checkpoint = commitCheckpoint, publicationProbe = commitPublicationProbe
        #endif
        mutex.unlock()
        do {
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.claimed)
            if let publicationProbe { try journal.testingObservePublication(publicationProbe) }
            #endif
            try boundary(deadline)
            _ = try journal.publishReadinessCommit()
            retainCommitOutcome(from: journal)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.published)
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            let delivered = try journal.deliverReadinessCommit()
            // The actual transport outcome is held even if the next wrapper
            // postflight fails. Neither this value nor the durable record can
            // reserve another delivery or assert host startup.
            mutex.lock(); commitDelivered = delivered; mutex.unlock()
            retainCommitOutcome(from: journal)
            #if SHADOW_SYNC_TESTING
            try checkpoint?(.delivered)
            #endif
            try boundary(deadline)
            try admission.validateOwner(owner, intent: admissionIntent)
            mutex.lock(); readinessCommitProgress = .delivered; mutex.unlock()
        } catch {
            let failure = error
            mutex.lock(); failedClosed = true; readinessCommitProgress = .failed; mutex.unlock()
            // Includes an actual fsynced result returned by neither lower-level
            // call because its postflight failed, and uncertain atomic proposals.
            retainCommitOutcome(from: journal)
            var outcome = journal.readinessCommitOutcome()
            if outcome.proposed != nil || outcome.durable != nil {
                if outcome.recovery == nil {
                    _ = try? journal.fenceReadinessCommitFailure()
                }
                outcome = journal.readinessCommitOutcome()
                retainCommitOutcome(from: journal)
                mutex.lock()
                commitFailureDisposition = outcome.recovery == nil ? .pending : .fenced
                mutex.unlock()
            }
            _ = try? admission.closeStarts()
            do {
                try journal.closeReadiness(deadline: deadline)
                mutex.lock(); stagedReadinessClosure = .joined; mutex.unlock()
            } catch {
                mutex.lock(); stagedReadinessClosure = .pending; mutex.unlock()
                throw error
            }
            throw failure
        }
    }

    #if SHADOW_SYNC_TESTING
    @inline(never)
    func testingConfigureReadinessCommit(publicationProbe: CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe? = nil,
        checkpoint: ((CommitCheckpoint) throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted else { throw CustodyRecordError.fenced }
        commitPublicationProbe = publicationProbe; commitCheckpoint = checkpoint
    }
    @inline(never)
    func testingFenceCommitFailure() throws {
        guard let journal = stagedJournal else { throw CustodyRecordError.fenced }
        _ = try journal.fenceReadinessCommitFailure()
    }
    func testingCommitRetention() -> [Bool] {
        mutex.lock(); defer { mutex.unlock() }
        return [commitOutcome?.proposed != nil, commitOutcome?.durable != nil,
                commitOutcome?.recovery != nil, commitDelivered != nil]
    }
    #endif

    #if SHADOW_SYNC_TESTING
    @inline(never)
    func testingConfigureCandidateReady(publicationProbe: CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe? = nil,
        checkpoint: ((ReadyCheckpoint) throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted else { throw CustodyRecordError.fenced }
        readyPublicationProbe = publicationProbe; readyCheckpoint = checkpoint
    }
    @inline(never)
    private func testingReadyExecution() -> ReadyExecution? {
        mutex.lock(); defer { mutex.unlock() }; return candidateExecution
    }
    func testingCandidateReadyRetention() -> [Bool] {
        testingReadyExecution()?.read {
            [$0.intent != nil, $0.context != nil, $0.command != nil, $0.handle != nil,
             $0.retirement != nil, $0.completed != nil]
        } ?? Array(repeating: false, count: 6)
    }
    @inline(never)
    func testingCandidateReadyContext() -> CommandCustodyContext? { testingReadyExecution()?.read { $0.context } }
    @inline(never)
    func testingCandidateReadyHandle() -> RetainedCleanupRegistry.Handle? { testingReadyExecution()?.read { $0.handle } }
    @inline(never)
    func testingCandidateReadyBudget() -> CustodyBudget? { testingReadyExecution()?.read { $0.command?.resources.request.budget } }
    #endif

    #if SHADOW_SYNC_TESTING
    @inline(never)
    func testingConfigureStarts(publicationProbe: CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe? = nil,
        checkpoint: ((LifecycleLaunchCommand.Operation, StartCheckpoint) throws -> Void)? = nil,
        failedRetirementCheckpoint: ((FailedStartRetirementCheckpoint) throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted else { throw CustodyRecordError.fenced }
        startPublicationProbe = publicationProbe; startCheckpoint = checkpoint
        failedStartRetirementCheckpoint = failedRetirementCheckpoint
    }
    private func testingStartExecution(_ kickstart: Bool) -> StartExecution? {
        mutex.lock(); defer { mutex.unlock() }; return kickstart ? kickstartExecution : bootstrapExecution
    }
    func testingStartRetention(kickstart: Bool) -> [Bool] {
        testingStartExecution(kickstart)?.read {
            [$0.intent != nil, $0.context != nil, $0.command != nil, $0.handle != nil,
             $0.retirement != nil, $0.completed != nil]
        } ?? Array(repeating: false, count: 6)
    }
    func testingFailedStartRetirementDeadline() -> UInt64? {
        mutex.lock(); defer { mutex.unlock() }; return invocationDeadline?.absoluteUptimeNanoseconds
    }
    func testingFailedStartRetirementRetention(kickstart: Bool) -> [Bool] {
        testingStartExecution(kickstart)?.read {
            [$0.recoveryRetirement != nil, $0.contextClosed, $0.aliasesReleased]
        } ?? Array(repeating: false, count: 3)
    }
    func testingStartBudget(kickstart: Bool) -> CustodyBudget? {
        testingStartExecution(kickstart)?.read { $0.command?.resources.request.budget }
    }
    func testingStartHandle(kickstart: Bool) -> RetainedCleanupRegistry.Handle? {
        testingStartExecution(kickstart)?.read { $0.handle }
    }
    func testingStartContext(kickstart: Bool) -> CommandCustodyContext? {
        testingStartExecution(kickstart)?.read { $0.context }
    }
    func testingStartReadinessDeadline() throws -> UInt64 {
        guard let retired = testingStartExecution(true)?.read({ $0.retirement }) else { throw CustodyRecordError.fenced }
        return try retired.readinessDeadline().absoluteUptimeNanoseconds
    }
    /// Fixture teardown only: release failed-attempt aliases after the fixture's
    /// actual registry is fully quiescent. This grants no production recovery.
    func testingReleaseFailedStartAliases() throws {
        guard let registry = exclusiveRegistry, !registry.hasRetainedWork,
              registry.testingCount == 0, registry.testingOriginalHelpersReaped else { throw CustodyRecordError.fenced }
        testingStartExecution(false)?.releaseCommandAliases()
        testingStartExecution(true)?.releaseCommandAliases()
        testingReadyExecution()?.releaseCommandAliases()
    }
    #endif

    #if SHADOW_SYNC_TESTING
    @inline(never)
    func testingConfigureStagedReadiness(endpointCut: InstallationReadinessEndpoint.TestingCut? = nil,
        receiptCut: Bool = false, publicationBarrier: CustodyLeaseTestingBarrier? = nil,
        sourceBarrier: CustodyLeaseTestingBarrier? = nil,
        afterClaim: (() throws -> Void)? = nil, afterReturn: (() throws -> Void)? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !attempted, !failedClosed else { throw CustodyRecordError.fenced }
        readinessEndpointCut = endpointCut; readinessReceiptCut = receiptCut
        readinessPublicationBarrier = publicationBarrier; readinessSourceBarrier = sourceBarrier
        readinessAfterClaim = afterClaim; readinessAfterReturn = afterReturn
    }
    @inline(never)
    func testingReadinessRetention() -> [Bool] {
        mutex.lock(); defer { mutex.unlock() }
        return [openedAdmission != nil, stagedJournal != nil, stagedAdmission != nil, owner != nil, original != nil]
    }
    @inline(never)
    func testingTerminalJournal() -> CustodyCatalogStore.InstallationStagedJournal? { stagedJournal }
    @inline(never)
    func testingReadinessSession() -> InstallationPrecommitSession? { stagedJournal?.testingSession }
    @inline(never)
    func testingReadinessEndpoint() -> InstallationReadinessEndpoint? { stagedJournal?.testingEndpoint }
    @inline(never)
    func testingReadinessJournalLockAvailable() -> Bool { stagedJournal?.testingMetadataLockAvailable ?? false }
    @inline(never)
    func testingCloseReadiness(deadline: MonotonicDeadline) throws { try stagedJournal?.closeReadiness(deadline: deadline) }
    @inline(never)
    func testingRemoveReadinessEndpoint() throws { try stagedJournal?.testingRemoveReadinessEndpoint() }
    #endif

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
