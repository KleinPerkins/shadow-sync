import Darwin
import Foundation

/// Failure evidence has no authority or leases. Probes may retain it after the
/// weak phase owner disappears without extending or reopening that phase.
final class CommandCustodyPhaseFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    var cleanupPending: Bool { lock.lock(); defer { lock.unlock() }; return pending }
    func recordPending() { lock.lock(); pending = true; lock.unlock() }
}

/// A caller-local capability for one phase's actual held authority. Neither a
/// path, a UUID from metadata, nor decoded descriptor numbers construct it.
/// Candidate classification and target admission remain command-adapter duties.
final class CommandCustodyContext: @unchecked Sendable {
    enum Diagnostic: Sendable { case serviceStatus, installedSignature }
    private final class WeakRun {
        weak var source: RunAuthority?
        init(_ source: RunAuthority) { self.source = source }
    }
    private final class WeakObservation {
        weak var source: LifecycleAdmissionAuthority?
        init(_ source: LifecycleAdmissionAuthority) { self.source = source }
    }
    private final class WeakRegistry {
        weak var source: RetainedCleanupRegistry?
        init(_ source: RetainedCleanupRegistry) { self.source = source }
    }
    private enum AdmissionSource {
        case independent
        case installation(InstallationTransactionOwner)
        case run(WeakRun)
        case observation(WeakObservation)
        var isOpen: Bool {
            switch self {
            case .independent: true
            case .installation(let owner): owner.commandAdmissionIsOpen
            case .run(let observer): observer.source?.commandAdmissionIsOpen ?? false
            case .observation(let observer): observer.source?.commandAdmissionIsOpen ?? false
            }
        }
    }
    // This mutex protects in-memory admission/registry references only. It is
    // never held across publisher checks, metadata I/O, waits or callbacks.
    private let admissionMutex = NSLock()
    private var closed = false
    let phaseFailure = CommandCustodyPhaseFailure()
    private var registries: [WeakRegistry] = []
    private let admissionSource: AdmissionSource
    private let scope: CustodyMetadataScope
    private let helper: CustodyHelperExecutable
    private let caller: ProcessIdentity
    private let account: EffectiveAccount
    private let location: StateLocation
    private let stateIdentity: FileIdentity
    private let installation: CustodyCatalogStore.InstallationCommandPermit?
    private let stagedCandidate: InstallationStagedCandidateAuthority?

    private init(leases: CustodyAuthorityLeaseSet, helper: CustodyHelperExecutable,
                 account: EffectiveAccount, location: StateLocation, admissionSource: AdmissionSource = .independent,
                 installation: CustodyCatalogStore.InstallationCommandPermit? = nil) throws {
        try helper.revalidate()
        guard account.uid == geteuid(), location.uid == account.uid else { throw CustodyRecordError.fenced }
        self.helper = helper; self.account = account; self.location = location; self.admissionSource = admissionSource; self.installation = installation
        let root = try leases.duplicateStateDirectory()
        var info = stat()
        guard fstat(root.0.value, &info) == 0 else { throw CustodyRecordError.fenced }
        stateIdentity = FileIdentity(info)
        try Self.validateStateBinding(leases: leases, location: location, expected: stateIdentity)
        stagedCandidate = try installation.flatMap { permit in
            guard permit.observation.stagedMode != nil else { return nil }
            return try InstallationStagedCandidateAuthority(binding: permit.observation, helper: helper, account: account)
        }
        let generation = installation?.generation ?? RunIdentity.make()
        caller = try ProcessIdentity.capture(processID: getpid(), generation: generation)
        // This validates the durable fence under the retained locks. A missing
        // initialized catalog cannot be interpreted as a fresh empty state.
        scope = try CustodyMetadataScope(leases: leases, releaseSHA256: helper.releaseSHA256, generation: generation, installation: installation)
        try revalidate()
    }

    static func read() throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.production()
        let account = try EffectiveAccount.current(), location = try StateLocation.production()
        return try Self(leases: CustodyAuthorityLeaseSet.retainReadLeases(at: location),
                        helper: helper, account: account, location: location)
    }
    /// The phase exists before its body can load policy or inspect a candidate.
    /// Consumers must retain only weak admission checks, not this lease owner.
    /// In-flight registry commands retain their own authority after close.
    static func withReadPhase<Value>(_ body: (CommandCustodyContext) throws -> Value) throws -> Value {
        try withPhase(read(), body)
    }
    static func withPhase<Value>(_ context: CommandCustodyContext,
                                 _ body: (CommandCustodyContext) throws -> Value) throws -> Value {
        defer { context.close() }
        return try body(context)
    }
    var hasCleanupPending: Bool { phaseFailure.cleanupPending }
    func recordCleanupPending() {
        phaseFailure.recordPending()
        close()
    }
    func validatePendingCause() throws {
        if hasCleanupPending { throw SystemGitConfigurationError.cleanupPending }
    }
    func validatePhaseAdmission() throws { try validatePendingCause(); try revalidate() }
    func validatePhaseAdmission(account expected: EffectiveAccount) throws {
        try validatePendingCause()
        guard expected == account else { throw CustodyRecordError.fenced }
        try revalidate()
    }
    func phaseAdmissionCheck() -> @Sendable () throws -> Void {
        { [weak self] in
            guard let self else { throw CustodyRecordError.fenced }
            try self.validatePhaseAdmission()
        }
    }
    static func borrowing(_ authority: RunAuthority) throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.production()
        return try Self(leases: authority.retainCommandLeases(), helper: helper,
                        account: EffectiveAccount.current(), location: StateLocation.production(), admissionSource: .run(WeakRun(authority)))
    }
    static func borrowing(_ authority: RunAuthority, publisher: LifecyclePublisher) throws -> CommandCustodyContext {
        let leases = try authority.retainCommandLeases()
        guard leases.mode == .lifecycleMutation else { throw CustodyRecordError.fenced }
        return try Self(leases: leases, helper: CustodyHelperExecutable.lifecycle(publisher),
            account: publisher.account, location: StateLocation.production(), admissionSource: .run(WeakRun(authority)))
    }
    /// Only the consumed original owner and its one live journal can borrow.
    /// Reservation diagnostics do not grant a staged or consequential command.
    static func borrowing(_ owner: InstallationTransactionOwner,
                          journal: CustodyCatalogStore.InstallationJournalSession,
                          deadline: MonotonicDeadline) throws -> CommandCustodyContext {
        let helper = try owner.installationCommandHelper()
        let permit = try journal.commandPermit(for: owner, deadline: deadline)
        try permit.validateOwner(owner)
        return try Self(leases: owner.retainExclusiveLeases(), helper: helper,
            account: EffectiveAccount.current(), location: StateLocation.production(),
            admissionSource: .installation(owner), installation: permit)
    }
    static func borrowing(_ admission: InstallationStagedAdmission,
                          intent: CustodyCatalogStore.InstallationStagedCommandObservation,
                          deadline: MonotonicDeadline) throws -> CommandCustodyContext {
        let permit = try intent.commandPermit(admission: admission, deadline: deadline)
        return try Self(leases: admission.retainStartLeases(), helper: intent.commandHelper(),
            account: EffectiveAccount.current(), location: StateLocation.production(), installation: permit)
    }
    static func borrowing(_ admission: InstallationStagedStopAdmission,
                          intent: CustodyCatalogStore.InstallationStagedCommandObservation,
                          deadline: MonotonicDeadline) throws -> CommandCustodyContext {
        let permit = try intent.commandPermit(admission: admission, deadline: deadline)
        return try Self(leases: admission.retainStopLeases(), helper: intent.commandHelper(),
            account: EffectiveAccount.current(), location: StateLocation.production(), installation: permit)
    }
    static func observing(_ recovery: CustodyCatalogStore.InstallationStagedRecovery,
                          deadline: MonotonicDeadline) throws -> CommandCustodyContext {
        let permit = try recovery.commandPermit(deadline: deadline)
        return try Self(leases: recovery.retainLeases(), helper: recovery.commandHelper(),
            account: EffectiveAccount.current(), location: StateLocation.production(), installation: permit)
    }
    static func observing(_ authority: RunAuthority) throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.production()
        return try Self(leases: authority.retainObservationLeases(), helper: helper,
                        account: EffectiveAccount.current(), location: StateLocation.production(), admissionSource: .run(WeakRun(authority)))
    }
    static func observing(_ authority: LifecycleAdmissionAuthority) throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.production()
        return try Self(leases: authority.retainObservationLeases(), helper: helper,
                        account: EffectiveAccount.current(), location: StateLocation.production(), admissionSource: .observation(WeakObservation(authority)))
    }
    /// Uses the caller's actual retained admission locks, never metadata or
    /// reopened lock paths. Closing that authority closes future admission.
    static func observing(_ authority: LifecycleAdmissionAuthority,
                          publisher: LifecyclePublisher) throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.lifecycle(publisher)
        return try Self(leases: authority.retainObservationLeases(), helper: helper,
            account: publisher.account, location: StateLocation.production(),
            admissionSource: .observation(WeakObservation(authority)))
    }
    static func observation() throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.production()
        let account = try EffectiveAccount.current(), location = try StateLocation.production()
        let authority = try LifecycleAdmissionAuthority.acquire(at: location)
        defer { authority.release() }
        return try Self(leases: authority.retainObservationLeases(), helper: helper,
                        account: account, location: location, admissionSource: .independent)
    }

    #if SHADOW_SYNC_TESTING
    var testingRepositoryPausePhase: String?
    #endif
    var id: String { scope.id }
    var mode: CustodyAuthorityMode { scope.leases.mode }
    var isClosed: Bool { admissionMutex.lock(); defer { admissionMutex.unlock() }; return closed }
    /// Closure is immediate and bounded by in-memory bookkeeping, even while a
    /// metadata transition is paused. Actual scope/child drainage is separate.
    func close() {
        admissionMutex.lock()
        guard !closed else { admissionMutex.unlock(); return }
        closed = true
        let owners = registries.compactMap(\.source)
        admissionMutex.unlock()
        // With no registry submission there is no durable/live transaction to
        // close; the closed context alone prevents any future submission.
        for registry in owners { registry.close(scope: scope) }
    }
    fileprivate func register(_ registry: RetainedCleanupRegistry) throws {
        admissionMutex.lock(); defer { admissionMutex.unlock() }
        guard !closed else { throw CustodyRecordError.fenced }
        registries.removeAll { $0.source == nil }
        if !registries.contains(where: { $0.source === registry }) { registries.append(WeakRegistry(registry)) }
    }

    fileprivate func revalidate() throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.entry
        var diagnosticPassed = false
        defer {
            if !diagnosticPassed {
                // Contemporaneous cached state, not a claim about which
                // predicate first failed. No new wait, signal or identity read.
                var bits: UInt64 = 0
                if isClosed { bits |= 1 }
                if admissionSource.isOpen { bits |= 2 }
                switch scope.observation {
                case .open: break
                case .closing: bits |= 1 << 2
                case .pending: bits |= 2 << 2
                case .terminal: bits |= 3 << 2
                }
                DiscoveryFixtureDiagnostic.record(.phase, stage: diagnosticStage,
                    started: diagnosticStart, deadline: nil, resultBits: bits)
            }
        }
        #endif
        guard !isClosed, admissionSource.isOpen, scope.observation == .open, scope.uid == geteuid(),
              scope.bootID == (try CustodyBootIdentity.current()),
              caller == (try ProcessIdentity.capture(processID: getpid(), generation: caller.generation)) else {
            throw CustodyRecordError.fenced
        }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .resources
        #endif
        try helper.revalidate()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .lockValidation
        #endif
        try scope.leases.validate()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .installationFence
        #endif
        try scope.revalidateInstallation()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .authorityAfter
        #endif
        if let installation { try installation.validatePublisher(caller, helper: helper) }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .metadata
        #endif
        try stagedCandidate?.revalidate()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .postflight
        #endif
        try Self.validateStateBinding(leases: scope.leases, location: location, expected: stateIdentity)
        guard !isClosed, admissionSource.isOpen else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
    }
    private static func validateStateBinding(leases: CustodyAuthorityLeaseSet, location: StateLocation,
                                            expected: FileIdentity) throws {
        // Open only the app-owned directory, never another lock. This proves the
        // actual retained root still names canonical state, without reacquiring,
        // upgrading, replacing or unlocking any held lease.
        let named = try SecureStateDirectory.openExisting(location)
        let held = try leases.duplicateStateDirectory()
        var a = stat(), b = stat()
        guard fstat(named.descriptor.value, &a) == 0, fstat(held.0.value, &b) == 0,
              FileIdentity(a).matchesStableNode(expected), FileIdentity(b).matchesStableNode(expected) else {
            throw CustodyRecordError.fenced
        }
    }

    /// Closed diagnostic preparation only. No arbitrary label, bundle path,
    /// executable, arguments, environment, cwd or timeout enters this factory.
    /// The helper must independently validate its matching fixed adapter before
    /// target admission. Merely preparing this value creates no child/journal.
    func prepare(_ diagnostic: Diagnostic, budget supplied: CustodyBudget? = nil, cancellation: CancellationToken? = nil) throws -> PreparedCustodyCommand {
        // Reserve has no application mutation or installed-signature authority.
        guard installation == nil || mode.isInstallationStaged || diagnostic == .serviceStatus else { throw CustodyRecordError.fenced }
        let kind: CustodyCommandKind, arguments: [String]
        switch diagnostic {
        case .serviceStatus:
            kind = .launchctlRead
            arguments = ["print", "gui/\(account.uid)/\(InstallationPaths.label)"]
        case .installedSignature:
            kind = .signatureCheck
            arguments = ["--verify", "--strict", "--verbose=2", account.homeDirectory + "/Applications/ShadowSync.app"]
        }
        let originalBudget = try supplied ?? CustodyBudget.make(kind: kind, workSeconds: 10)
        let budget = try installation?.boundDiagnosticBudget(originalBudget) ?? originalBudget
        try budget.validate(kind: kind, permittedWorkSeconds: 10, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let directory = OwnedFileDescriptor(raw)
        let resources = try CustodyRequestResources(scope: scope, kind: kind, arguments: arguments,
            environment: ClosedProcessRunner.environment(account: account), budget: budget,
            stdoutLimit: UInt64(LifecycleCommandRunner.outputLimit), stderrLimit: UInt64(LifecycleCommandRunner.outputLimit),
            workingDirectory: directory, input: try installation?.sealedInput())
        try revalidate()
        try budget.validate(kind: kind, permittedWorkSeconds: 10, now: DispatchTime.now().uptimeNanoseconds)
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources, cancellation: cancellation)
    }

    func prepareLifecycle(_ operation: LifecycleLaunchCommand.Operation,
                          cancellation: CancellationToken? = nil) throws -> PreparedCustodyCommand {
        guard helper.isLifecycleCoordinator else { throw CustodyRecordError.fenced }
        if let installation {
            try installation.observation.validateStagedOperation(mode: mode, operation: operation)
        } else { guard mode == .lifecycleMutation else { throw CustodyRecordError.fenced } }
        let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10)
        try revalidate()
        let command = LifecycleLaunchCommand(operation: operation, account: account)
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .launchctlMutation,
            arguments: command.arguments, environment: ClosedProcessRunner.environment(account: account),
            budget: budget, stdoutLimit: UInt64(LifecycleCommandRunner.outputLimit),
            stderrLimit: UInt64(LifecycleCommandRunner.outputLimit), workingDirectory: OwnedFileDescriptor(raw),
            input: try installation?.sealedInput())
        // Refuse unqualified tools or installed input before registry reservation;
        // the helper reconstructs the same authority independently.
        _ = try LifecycleLaunchAuthority(request: resources.request, helper: helper, account: account, installation: installation?.observation)
        try revalidate(); try budget.validate(kind: .launchctlMutation, permittedWorkSeconds: 10,
                                             now: DispatchTime.now().uptimeNanoseconds)
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources, cancellation: cancellation)
    }

    func preparePolicy(input: Data, code: Data, snapshot: HostPolicySnapshot,
                       publisher: PublisherPolicyResources, budget: CustodyBudget,
                       cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        #if SHADOW_SYNC_TESTING
        // Parent-only observation; helper stdout/stderr/trace remain untouched.
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.entry
        var diagnosticPassed = false
        var diagnosticMilestones: [UInt64] = []
        defer {
            DiscoveryFixtureDiagnostic.record(.policyPreparation, stage: diagnosticStage,
                started: diagnosticStart, deadline: budget.work, succeeded: diagnosticPassed,
                milestones: diagnosticMilestones)
        }
        #endif
        guard snapshot.account == account, mode == .read || mode == .mutation else { throw CustodyRecordError.fenced }
        try budget.validate(kind: .policyClassify, permittedWorkSeconds: 2, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .authorityConstruction
        #endif
        let policy = try PolicyCommandAuthority(snapshot: snapshot, publisher: publisher,
            helper: helper, cancellation: cancellation)
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .input
        #endif
        try policy.validate(input: input, code: code)
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .resources
        #endif
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .policyClassify,
            arguments: PolicyCommandWire.logicalArguments, environment: ClosedProcessRunner.environment(account: account),
            budget: budget, stdoutLimit: 65_536, stderrLimit: 65_536,
            workingDirectory: OwnedFileDescriptor(raw), input: input, code: code)
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .postflight
        #endif
        try policy.revalidate(); try revalidate()
        try budget.validate(kind: .policyClassify, permittedWorkSeconds: 2, now: DispatchTime.now().uptimeNanoseconds)
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources, policy: policy, cancellation: cancellation)
    }

    func prepareDiscovery(policy: RepositoryDiscoveryCommandPolicy, candidate: RepositoryCandidate,
                          publisher: PublisherPolicyResources,
                          cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        guard policy.account == account, mode == .read || mode == .mutation,
              !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else { throw CustodyRecordError.fenced }
        try revalidate(); try policy.validate()
        let discovery = try DiscoveryCommandAuthority(commandPolicy: policy, candidate: candidate,
            publisher: publisher, helper: helper, cancellation: cancellation)
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .discoveryGit,
            arguments: policy.command.arguments, environment: ClosedProcessRunner.environment(account: account),
            budget: policy.budget, stdoutLimit: UInt64(DiscoveryGitCommand.stdoutLimit),
            stderrLimit: UInt64(DiscoveryGitCommand.stderrLimit), workingDirectory: OwnedFileDescriptor(raw),
            input: discovery.input.encode(), captureDiscoveryTrace: policy.command.capturesTransportConfiguration)
        try discovery.revalidate(); try revalidate()
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources,
                                      discovery: discovery, cancellation: cancellation)
    }

    func retentionAdmission(cancellation: CancellationToken) throws -> RetentionArchiveAdmission {
        guard installation == nil, mode == .mutation else { throw CustodyRecordError.fenced }
        try validatePhaseAdmission()
        let publisher: PublisherPolicyResources
        #if SHADOW_SYNC_TESTING
        if try helper.testingDiscoveryGraphResource() != nil { publisher = try PublisherPolicyResources.testingDiscovery(account: account) }
        else { publisher = try PublisherPolicyResources.production(account: account) }
        #else
        publisher = try PublisherPolicyResources.production(account: account)
        #endif
        return try RetentionArchiveAdmission(context: self, helper: helper, account: account, publisher: publisher, cancellation: cancellation)
    }
    func prepareRetention(_ authority: RetentionArchiveCommandAuthority, budget: CustodyBudget, cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        guard authority.admission.context === self, mode == .mutation else { throw CustodyRecordError.fenced }
        try budget.validate(kind: .retentionArchive, permittedWorkSeconds: 120, now: DispatchTime.now().uptimeNanoseconds)
        try validatePhaseAdmission(); try authority.revalidate()
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .retentionArchive,
            arguments: authority.arguments, environment: authority.input.environment(account: account), budget: budget,
            stdoutLimit: 16_777_216, stderrLimit: 16_777_216, workingDirectory: OwnedFileDescriptor(raw),
            input: authority.input.encode(), frozenConfiguration: authority.frozen, retention: authority)
        try authority.revalidate(); try validatePhaseAdmission()
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources, retention: authority, cancellation: cancellation)
    }

    func prepareSystemConfiguration(budget: CustodyBudget,
                                    cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        guard mode == .read || mode == .mutation,
              !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else { throw CustodyRecordError.fenced }
        try budget.validate(kind: .systemGitConfig, permittedWorkSeconds: 5, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        // Fail before registry reservation when this release/OS has no qualified
        // graph. The helper independently reconstructs the same authority.
        let graph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .systemGitConfig,
            arguments: SystemGitConfigurationCommand.arguments,
            environment: SystemGitConfigurationCommand.environment(account: account), budget: budget,
            stdoutLimit: SystemGitConfigurationCommand.outputLimit, stderrLimit: SystemGitConfigurationCommand.outputLimit,
            workingDirectory: OwnedFileDescriptor(raw))
        try SystemGitConfigurationCommand.validate(resources.request, account: account)
        try graph.revalidate(); try revalidate()
        try budget.validate(kind: .systemGitConfig, permittedWorkSeconds: 5, now: DispatchTime.now().uptimeNanoseconds)
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else { throw CustodyRecordError.fenced }
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources, graph: graph, cancellation: cancellation)
    }

    func frozenConfigurationAdmission(expectedPolicySHA256: String?, scratch: Int32, budget: CustodyBudget,
                                      cancellation: CancellationToken) throws -> (admit: ([String]) throws -> Void, revalidate: () throws -> Void) {
        try validatePhaseAdmission(account: account)
        let publisher: PublisherPolicyResources
        #if SHADOW_SYNC_TESTING
        if try helper.testingDiscoveryGraphResource() != nil { publisher = try PublisherPolicyResources.testingDiscovery(account: account) }
        else { publisher = try PublisherPolicyResources.production(account: account) }
        #else
        publisher = try PublisherPolicyResources.production(account: account)
        #endif
        let snapshot = try HostPolicySnapshot.load(account: account, contract: QualifiedAWAContract.decode(publisher.contract))
        guard snapshot.admissionSHA256 == expectedPolicySHA256 else { throw HostPolicyBindingError.unavailable }
        let transport = PolicyHelperTransport(snapshot: snapshot, publisher: publisher, context: self)
        // Both closures retain the same admitted host and publisher snapshots.
        // A phase-only check cannot authorize a later filesystem access.
        let revalidate: () throws -> Void = { [self] in
            guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed,
                  DispatchTime.now().uptimeNanoseconds < budget.work else { throw PolicyHelperError.unavailable }
            try snapshot.revalidate(); try publisher.revalidate(); try validatePhaseAdmission(account: account)
            guard DispatchTime.now().uptimeNanoseconds < budget.work else { throw PolicyHelperError.unavailable }
        }
        return (admit: { paths in
            try revalidate()
            for batch in try ConfigurationPolicyPlan(retentionPaths: paths).batches {
                try revalidate()
                let decisions = try transport.classify(candidates: batch, scratchDescriptor: scratch, timeout: 2,
                    absoluteDeadline: budget.work, enclosingBudget: budget, cancellation: cancellation)
                guard decisions.count == batch.count, decisions.allSatisfy(\.allowsCandidateAccess) else { throw PolicyHelperError.unavailable }
                try revalidate()
            }
        }, revalidate: revalidate)
    }

    func prepareRepositoryGit(arguments: [String], handle: RepositoryHandle, frozen: FrozenGitConfiguration,
                              snapshot: RepositoryExecutionSnapshot, budget: CustodyBudget,
                              outputLimit: Int, cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        guard mode == .read || mode == .mutation, !cancellation.isCancelled,
              !cancellation.areFutureChildAdmissionsClosed, outputLimit > 0,
              outputLimit <= DescriptorProcessRunner.completeRepositoryOutputLimit else { throw CustodyRecordError.fenced }
        try revalidate()
        let publisher: PublisherPolicyResources
        #if SHADOW_SYNC_TESTING
        if try helper.testingDiscoveryGraphResource() != nil { publisher = try PublisherPolicyResources.testingDiscovery(account: account) }
        else { publisher = try PublisherPolicyResources.production(account: account) }
        #else
        publisher = try PublisherPolicyResources.production(account: account)
        #endif
        let repository = try RepositoryGitCommandAuthority(handle: handle, frozen: frozen, snapshot: snapshot,
            arguments: arguments, mode: mode, account: account, helper: helper, publisher: publisher, cancellation: cancellation)
        #if SHADOW_SYNC_TESTING
        try repository.testingPause(at: testingRepositoryPausePhase)
        #endif
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .repositoryGit, arguments: arguments,
            environment: ClosedProcessRunner.environment(account: account), budget: budget,
            stdoutLimit: UInt64(outputLimit), stderrLimit: UInt64(outputLimit), workingDirectory: OwnedFileDescriptor(raw),
            input: repository.input.encode(), frozenConfiguration: frozen)
        try repository.revalidate(); try revalidate()
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources,
            repository: repository, cancellation: cancellation)
    }

    fileprivate var stagedCompletionAccount: EffectiveAccount? { mode.isInstallationStaged ? account : nil }
    fileprivate func owns(_ candidate: CustodyMetadataScope) -> Bool { scope === candidate }

    #if SHADOW_SYNC_TESTING
    static func testing(leases: CustodyAuthorityLeaseSet, location: StateLocation,
                        root: String, authority: RunAuthority? = nil, observation: LifecycleAdmissionAuthority? = nil,
                        discoveryFixture: Bool = false) throws -> CommandCustodyContext {
        _ = try TestIsolation.validateRoot(root)
        guard location == (try StateLocation.isolated(root: root)) else { throw CustodyRecordError.fenced }
        // An isolated account supplies only fixture HOME/path values. Actual
        // process/publisher fixture identity remains bound to the running binary.
        let home = root + "/home"
        // Several contexts deliberately share one fixture account. Existing
        // entries must still be an owner-private directory, never an alias.
        let created = Darwin.mkdir(home, 0o700)
        guard created == 0 || errno == EEXIST else { throw CustodyRecordError.fenced }
        var homeInfo = stat()
        guard lstat(home, &homeInfo) == 0, (homeInfo.st_mode & S_IFMT) == S_IFDIR,
              homeInfo.st_uid == geteuid(), (homeInfo.st_mode & 0o777) == 0o700 else {
            throw CustodyRecordError.fenced
        }
        let helper = try discoveryFixture ? CustodyHelperExecutable.testingDiscovery(home: home)
            : CustodyHelperExecutable.testing(releaseSHA256: String(repeating: "c", count: 64))
        return try Self(leases: leases, helper: helper,
                        account: EffectiveAccount.isolated(homeDirectory: home), location: location,
                        admissionSource: authority.map { AdmissionSource.run(WeakRun($0)) } ?? observation.map { AdmissionSource.observation(WeakObservation($0)) } ?? .independent)
    }
    static func testingInstallation(_ owner: InstallationTransactionOwner,
                                    journal: CustodyCatalogStore.InstallationJournalSession,
                                    root: String) throws -> CommandCustodyContext {
        let location = try StateLocation.isolated(root: TestIsolation.validateRoot(root))
        let permit = try journal.commandPermit(for: owner, deadline: MonotonicDeadline(seconds: 0.750))
        try permit.validateOwner(owner)
        let helper = try CustodyHelperExecutable.testingCustodian()
        try helper.bindTestingInstallationSource(root: root)
        return try Self(leases: owner.retainExclusiveLeases(), helper: helper,
            account: EffectiveAccount.isolated(homeDirectory: root + "/home"), location: location,
            admissionSource: .installation(owner), installation: permit)
    }
    static func testingStaged(_ admission: InstallationStagedAdmission,
        intent: CustodyCatalogStore.InstallationStagedCommandObservation, root: String) throws -> CommandCustodyContext {
        let permit = try intent.commandPermit(admission: admission, deadline: .init(seconds: 3))
        return try testingStaged(leases: admission.retainStartLeases(), permit: permit, root: root)
    }
    static func testingStaged(_ admission: InstallationStagedStopAdmission,
        intent: CustodyCatalogStore.InstallationStagedCommandObservation, root: String) throws -> CommandCustodyContext {
        let permit = try intent.commandPermit(admission: admission, deadline: .init(seconds: 3))
        return try testingStaged(leases: admission.retainStopLeases(), permit: permit, root: root)
    }
    static func testingRecovery(_ recovery: CustodyCatalogStore.InstallationStagedRecovery,
                                root: String) throws -> CommandCustodyContext {
        let permit = try recovery.commandPermit(deadline: .init(seconds: 3))
        return try testingStaged(leases: recovery.retainLeases(), permit: permit, root: root)
    }
    private static func testingStaged(leases: CustodyAuthorityLeaseSet,
        permit: CustodyCatalogStore.InstallationCommandPermit, root: String) throws -> CommandCustodyContext {
        let location = try StateLocation.isolated(root: TestIsolation.validateRoot(root))
        let helper = try CustodyHelperExecutable.testingCustodian()
        try helper.bindTestingInstallationSource(root: root)
        return try Self(leases: leases, helper: helper, account: EffectiveAccount.isolated(homeDirectory: root + "/home"),
                        location: location, installation: permit)
    }
    func testingStagedLifecycle(_ operation: LifecycleLaunchCommand.Operation, budget: CustodyBudget? = nil) throws -> PreparedCustodyCommand {
        guard let installation else { throw CustodyRecordError.fenced }
        try installation.observation.validateStagedOperation(mode: mode, operation: operation)
        try revalidate()
        let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CustodyRecordError.fenced }
        let resources = try CustodyRequestResources(scope: scope, kind: .launchctlMutation,
            arguments: LifecycleLaunchCommand(operation: operation, account: account).arguments,
            environment: ClosedProcessRunner.environment(account: account),
            budget: budget ?? CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10), stdoutLimit: 65_536, stderrLimit: 65_536,
            workingDirectory: OwnedFileDescriptor(fd), input: installation.sealedInput())
        try revalidate()
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources)
    }
    func testingInstallationDiagnostic(_ mode: String = "complete", budget: CustodyBudget? = nil) throws -> PreparedCustodyCommand {
        guard let installation, ["installation-absent", "installation-loaded", "installation-foreign", "complete", "resist", "terminal-delay", "after-admit"].contains(mode) else { throw CustodyRecordError.fenced }
        try revalidate()
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.fenced }
        let resources = try CustodyRequestResources(scope: scope, kind: .launchctlRead, arguments: [mode],
            environment: ClosedProcessRunner.environment(account: account),
            budget: budget ?? CustodyBudget.make(kind: .launchctlRead, workSeconds: 10),
            stdoutLimit: 65_536, stderrLimit: 65_536, workingDirectory: OwnedFileDescriptor(raw),
            input: installation.sealedInput())
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources)
    }
    var testingScope: CustodyMetadataScope { scope }
    func testingRevalidate() throws { try revalidate() }
    static func withTestingReadPhase<Value>(at location: StateLocation, root: String,
                                            _ body: (CommandCustodyContext) throws -> Value) throws -> Value {
        try withPhase(testing(leases: CustodyAuthorityLeaseSet.retainReadLeases(at: location),
                              location: location, root: root), body)
    }
    #endif
}

/// Sealed caller-side preparation, not a generic execution request or evidence
/// of helper-side admission. One registry submission owns this value permanently.
final class PreparedCustodyCommand: @unchecked Sendable {
    fileprivate let context: CommandCustodyContext
    let resources: CustodyRequestResources
    let helper: CustodyHelperExecutable
    private let mutex = NSLock()
    private var claimed = false
    private let policy: PolicyCommandAuthority?
    private let graph: QualifiedCommandGraph?
    private let discovery: DiscoveryCommandAuthority?
    private var repository: RepositoryGitCommandAuthority?
    private var retention: RetentionArchiveCommandAuthority?
    private let cancellation: CancellationToken?
    #if SHADOW_SYNC_TESTING
    private var validationCancellation: CancellationToken?
    func testingCancelDuringValidation(_ token: CancellationToken) { mutex.lock(); validationCancellation = token; mutex.unlock() }
    #endif
    fileprivate init(context: CommandCustodyContext, helper: CustodyHelperExecutable, resources: CustodyRequestResources, policy: PolicyCommandAuthority? = nil, graph: QualifiedCommandGraph? = nil, discovery: DiscoveryCommandAuthority? = nil, repository: RepositoryGitCommandAuthority? = nil, retention: RetentionArchiveCommandAuthority? = nil, cancellation: CancellationToken? = nil) {
        self.context = context; self.helper = helper; self.resources = resources; self.policy = policy; self.graph = graph; self.discovery = discovery; self.repository = repository; self.retention = retention; self.cancellation = cancellation
    }
    func claim(in registry: RetainedCleanupRegistry) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !claimed else { throw CustodyRecordError.fenced }
        try context.register(registry); claimed = true
    }
    var stagedCompletionAccount: EffectiveAccount? { context.stagedCompletionAccount }
    func retireRepositoryResources() { repository = nil; retention?.retire(); retention = nil }
    var admissionClosed: Bool { context.isClosed || policy?.admissionClosed == true || cancellation?.isCancelled == true || cancellation?.areFutureChildAdmissionsClosed == true }
    func revalidate() throws {
        guard !admissionClosed else { throw CustodyRecordError.fenced }
        try context.revalidate()
        guard context.owns(resources.scope), resources.request.binding.releaseSHA256 == helper.releaseSHA256,
              [.repositoryGit, .retentionArchive, .launchctlRead, .launchctlMutation, .signatureCheck, .policyClassify, .systemGitConfig, .discoveryGit].contains(resources.request.kind),
              (resources.request.kind == .policyClassify) == (policy != nil),
              (resources.request.kind == .systemGitConfig) == (graph != nil),
              (resources.request.kind == .discoveryGit) == (discovery != nil),
              (resources.request.kind == .repositoryGit) == (repository != nil),
              (resources.request.kind == .retentionArchive) == (retention != nil) else { throw CustodyRecordError.fenced }
        try policy?.revalidate()
        try graph?.revalidate(); try discovery?.revalidate(); try repository?.revalidate(); try retention?.revalidate()
        #if SHADOW_SYNC_TESTING
        mutex.lock(); let token = validationCancellation; validationCancellation = nil; mutex.unlock()
        token?.cancel()
        #endif
        guard !admissionClosed else { throw CustodyRecordError.fenced }
    }
}
