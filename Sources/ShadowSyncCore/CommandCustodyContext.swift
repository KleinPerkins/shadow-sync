import Darwin
import Foundation

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
        case run(WeakRun)
        case observation(WeakObservation)
        var isOpen: Bool {
            switch self {
            case .independent: true
            case .run(let observer): observer.source?.commandAdmissionIsOpen ?? false
            case .observation(let observer): observer.source?.commandAdmissionIsOpen ?? false
            }
        }
    }
    // This mutex protects in-memory admission/registry references only. It is
    // never held across publisher checks, metadata I/O, waits or callbacks.
    private let admissionMutex = NSLock()
    private var closed = false
    private var registries: [WeakRegistry] = []
    private let admissionSource: AdmissionSource
    private let scope: CustodyMetadataScope
    private let helper: CustodyHelperExecutable
    private let caller: ProcessIdentity
    private let account: EffectiveAccount
    private let location: StateLocation
    private let stateIdentity: FileIdentity

    private init(leases: CustodyAuthorityLeaseSet, helper: CustodyHelperExecutable,
                 account: EffectiveAccount, location: StateLocation, admissionSource: AdmissionSource = .independent) throws {
        try helper.revalidate()
        guard account.uid == geteuid(), location.uid == account.uid else { throw CustodyRecordError.fenced }
        self.helper = helper; self.account = account; self.location = location; self.admissionSource = admissionSource
        let root = try leases.duplicateStateDirectory()
        var info = stat()
        guard fstat(root.0.value, &info) == 0 else { throw CustodyRecordError.fenced }
        stateIdentity = FileIdentity(info)
        try Self.validateStateBinding(leases: leases, location: location, expected: stateIdentity)
        let generation = RunIdentity.make()
        caller = try ProcessIdentity.capture(processID: getpid(), generation: generation)
        // This validates the durable fence under the retained locks. A missing
        // initialized catalog cannot be interpreted as a fresh empty state.
        scope = try CustodyMetadataScope(leases: leases, releaseSHA256: helper.releaseSHA256, generation: generation)
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
    func validatePhaseAdmission() throws { try revalidate() }
    func validatePhaseAdmission(account expected: EffectiveAccount) throws {
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
    static func observation() throws -> CommandCustodyContext {
        let helper = try CustodyHelperExecutable.production()
        let account = try EffectiveAccount.current(), location = try StateLocation.production()
        let authority = try LifecycleAdmissionAuthority.acquire(at: location)
        defer { authority.release() }
        return try Self(leases: authority.retainObservationLeases(), helper: helper,
                        account: account, location: location, admissionSource: .independent)
    }

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
        guard !isClosed, admissionSource.isOpen, scope.observation == .open, scope.uid == geteuid(),
              scope.bootID == (try CustodyBootIdentity.current()),
              caller == (try ProcessIdentity.capture(processID: getpid(), generation: caller.generation)) else {
            throw CustodyRecordError.fenced
        }
        try helper.revalidate(); try scope.leases.validate()
        try Self.validateStateBinding(leases: scope.leases, location: location, expected: stateIdentity)
        guard !isClosed, admissionSource.isOpen else { throw CustodyRecordError.fenced }
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
        let kind: CustodyCommandKind, arguments: [String]
        switch diagnostic {
        case .serviceStatus:
            kind = .launchctlRead
            arguments = ["print", "gui/\(account.uid)/\(InstallationPaths.label)"]
        case .installedSignature:
            kind = .signatureCheck
            arguments = ["--verify", "--strict", "--verbose=2", account.homeDirectory + "/Applications/ShadowSync.app"]
        }
        let budget = try supplied ?? CustodyBudget.make(kind: kind, workSeconds: 10)
        try budget.validate(kind: kind, permittedWorkSeconds: 10, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let directory = OwnedFileDescriptor(raw)
        let resources = try CustodyRequestResources(scope: scope, kind: kind, arguments: arguments,
            environment: ClosedProcessRunner.environment(account: account), budget: budget,
            stdoutLimit: UInt64(LifecycleCommandRunner.outputLimit), stderrLimit: UInt64(LifecycleCommandRunner.outputLimit),
            workingDirectory: directory)
        try revalidate()
        try budget.validate(kind: kind, permittedWorkSeconds: 10, now: DispatchTime.now().uptimeNanoseconds)
        return PreparedCustodyCommand(context: self, helper: helper, resources: resources, cancellation: cancellation)
    }

    func preparePolicy(input: Data, code: Data, snapshot: HostPolicySnapshot,
                       publisher: PublisherPolicyResources, budget: CustodyBudget,
                       cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        guard snapshot.account == account, mode == .read || mode == .mutation else { throw CustodyRecordError.fenced }
        try budget.validate(kind: .policyClassify, permittedWorkSeconds: 2, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        let policy = try PolicyCommandAuthority(snapshot: snapshot, publisher: publisher,
            helper: helper, cancellation: cancellation)
        try policy.validate(input: input, code: code)
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let resources = try CustodyRequestResources(scope: scope, kind: .policyClassify,
            arguments: PolicyCommandWire.logicalArguments, environment: ClosedProcessRunner.environment(account: account),
            budget: budget, stdoutLimit: 65_536, stderrLimit: 65_536,
            workingDirectory: OwnedFileDescriptor(raw), input: input, code: code)
        try policy.revalidate(); try revalidate()
        try budget.validate(kind: .policyClassify, permittedWorkSeconds: 2, now: DispatchTime.now().uptimeNanoseconds)
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

    func prepareSystemConfiguration(budget: CustodyBudget,
                                    cancellation: CancellationToken) throws -> PreparedCustodyCommand {
        guard mode == .read || mode == .mutation,
              !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else { throw CustodyRecordError.fenced }
        try budget.validate(kind: .systemGitConfig, permittedWorkSeconds: 5, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        // Fail before registry reservation when this release/OS has no qualified
        // graph. The helper independently reconstructs the same authority.
        let graph = try QualifiedCommandGraph.production(kind: .systemGitConfig, helper: helper)
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
    private let cancellation: CancellationToken?
    #if SHADOW_SYNC_TESTING
    private var validationCancellation: CancellationToken?
    func testingCancelDuringValidation(_ token: CancellationToken) { mutex.lock(); validationCancellation = token; mutex.unlock() }
    #endif
    fileprivate init(context: CommandCustodyContext, helper: CustodyHelperExecutable, resources: CustodyRequestResources, policy: PolicyCommandAuthority? = nil, graph: QualifiedCommandGraph? = nil, discovery: DiscoveryCommandAuthority? = nil, cancellation: CancellationToken? = nil) {
        self.context = context; self.helper = helper; self.resources = resources; self.policy = policy; self.graph = graph; self.discovery = discovery; self.cancellation = cancellation
    }
    func claim(in registry: RetainedCleanupRegistry) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !claimed else { throw CustodyRecordError.fenced }
        try context.register(registry); claimed = true
    }
    var admissionClosed: Bool { context.isClosed || policy?.admissionClosed == true || cancellation?.isCancelled == true || cancellation?.areFutureChildAdmissionsClosed == true }
    func revalidate() throws {
        guard !admissionClosed else { throw CustodyRecordError.fenced }
        try context.revalidate()
        guard context.owns(resources.scope), resources.request.binding.releaseSHA256 == helper.releaseSHA256,
              [.launchctlRead, .signatureCheck, .policyClassify, .systemGitConfig, .discoveryGit].contains(resources.request.kind),
              (resources.request.kind == .policyClassify) == (policy != nil),
              (resources.request.kind == .systemGitConfig) == (graph != nil),
              (resources.request.kind == .discoveryGit) == (discovery != nil) else { throw CustodyRecordError.fenced }
        try policy?.revalidate()
        try graph?.revalidate(); try discovery?.revalidate()
        try resources.validate()
        #if SHADOW_SYNC_TESTING
        mutex.lock(); let token = validationCancellation; validationCancellation = nil; mutex.unlock()
        token?.cancel()
        #endif
        guard !admissionClosed else { throw CustodyRecordError.fenced }
    }
}
