import Darwin
import Foundation

public protocol RepositoryInventoryDiscovering: Sendable {
    func discoverInventory(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> RepositoryInventory
}

public enum RepositoryInventoryLifecycleEvent: Equatable, Sendable {
    case authorityAcquired
    case repositoryStarted(
        completed: Int,
        total: Int,
        repositoryID: String
    )
    case repositoryProgress(
        completed: Int,
        total: Int,
        repositoryID: String,
        phase: String
    )
    case childStarted(count: Int, phase: String)
    case cleanupProgress(CleanupInspectionProgress)
    case finished(childCount: Int)
    case failed(childCount: Int)
    case cancelled(childCount: Int)
}

public enum CleanupInspectionStage:
    String, Codable, Equatable, Sendable {
    case topology
    case worktreeEvidence
    case branchRelations
    case pullRequestEvidence
    case candidateAssembly
}

public struct CleanupInspectionProgress:
    Codable, Equatable, Sendable {
    public let repositoryID: String
    public let repositoryCompleted: Int
    public let repositoryTotal: Int
    public let stage: CleanupInspectionStage
    public let completed: Int
    public let total: Int
    public let activeChildren: Int
    public let maximumActiveChildren: Int
    public let partialCount: Int
    public let durationMilliseconds: Int64
    public let heartbeat: Int

    public init(
        repositoryID: String,
        repositoryCompleted: Int,
        repositoryTotal: Int,
        stage: CleanupInspectionStage,
        completed: Int,
        total: Int,
        activeChildren: Int = 0,
        maximumActiveChildren: Int = 0,
        partialCount: Int = 0,
        durationMilliseconds: Int64 = 0,
        heartbeat: Int? = nil
    ) {
        self.repositoryID = repositoryID
        self.repositoryCompleted = repositoryCompleted
        self.repositoryTotal = repositoryTotal
        self.stage = stage
        self.completed = completed
        self.total = total
        self.activeChildren = activeChildren
        self.maximumActiveChildren = maximumActiveChildren
        self.partialCount = partialCount
        self.durationMilliseconds =
            max(0, durationMilliseconds)
        self.heartbeat = max(0, heartbeat ?? completed)
    }
}

final class RepositoryInventoryProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let observer:
        (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)?
    private var phase = "git_read"
    private var childCount = 0

    init(
        observer: (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)?
    ) {
        self.observer = observer
    }

    func prepare(phase: String) {
        lock.lock()
        self.phase = phase
        lock.unlock()
    }

    func observe(_ identity: ProcessIdentity?) -> Bool {
        guard identity != nil else { return true }
        lock.lock()
        childCount += 1
        let count = childCount
        let phase = phase
        lock.unlock()
        observer?(.childStarted(count: count, phase: phase))
        return true
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return childCount
    }
}

public final class RepositoryInventoryDiscovery:
    RepositoryInventoryDiscovering, @unchecked Sendable {
    static let inventoryOutputLimit =
        DescriptorProcessRunner.completeRepositoryOutputLimit
    private let executablePath: String
    private let stateLocation: StateLocation
    private let account: EffectiveAccount
    private let cloneDiscovery: RepositoryDiscovery
    private let pullRequestLookup: any PullRequestLookingUp
    private let cancellation: CancellationToken
    private let lifecycleObserver:
        (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)?
    #if SHADOW_SYNC_TESTING
    private let transportMapping: TransportMapping?
    #endif

    public init(
        executablePath: String,
        cancellation: CancellationToken = CancellationToken(),
        lifecycleObserver:
            (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)? = nil
    ) throws {
        guard executablePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw GitSafetyError.unsafeRepository(
                "application executable path is invalid"
            )
        }
        self.executablePath = executablePath
        stateLocation = try StateLocation.production()
        account = try EffectiveAccount.current()
        cloneDiscovery = RepositoryDiscovery()
        pullRequestLookup = ReadOnlyGitHubCLIAdapter(
            account: account,
            maximumConcurrentChildren: 4
        )
        self.cancellation = cancellation
        self.lifecycleObserver = lifecycleObserver
        #if SHADOW_SYNC_TESTING
        transportMapping = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        executablePath: String,
        isolatedRoot: String,
        transportMapping: TransportMapping,
        pullRequestLookup: any PullRequestLookingUp =
            UnavailablePullRequestLookup(),
        cancellation: CancellationToken = CancellationToken(),
        lifecycleObserver:
            (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)? = nil
    ) throws {
        let isolatedRoot = try TestIsolation.validateRoot(isolatedRoot)
        let home = URL(fileURLWithPath: isolatedRoot)
            .appendingPathComponent("home", isDirectory: true).path
        guard executablePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executablePath),
              transportMapping.containmentRoot == isolatedRoot else {
            throw GitSafetyError.unsafeRepository(
                "isolated inventory configuration is invalid"
            )
        }
        self.executablePath = executablePath
        stateLocation = try StateLocation.isolated(root: isolatedRoot)
        account = try EffectiveAccount.isolated(homeDirectory: home)
        cloneDiscovery = try RepositoryDiscovery(
            testingHomeDirectory: home,
            repositoryCentric: true
        )
        self.pullRequestLookup = pullRequestLookup
        self.cancellation = cancellation
        self.lifecycleObserver = lifecycleObserver
        self.transportMapping = transportMapping
    }
    #endif

    #if SHADOW_SYNC_TESTING
    public func discoverInventory() throws -> RepositoryInventory {
        try discoverInventoryForTesting()
    }
    #endif

    public func discoverInventory(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> RepositoryInventory {
        try discoverInventoryWithAuthority(scope: scope)
    }

    func discoverHydrationEvidence(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> SelectedRepositoryHydrationEvidence {
        let progress = RepositoryInventoryProgress(
            observer: lifecycleObserver
        )
        do {
            guard !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            let authority = try RunAuthority.acquireRun(at: stateLocation)
            lifecycleObserver?(.authorityAcquired)
            defer { authority.release() }
            let completed: SelectedRepositoryHydrationEvidence = try withFreshSelectedScope(scope, authority: authority) { scope, configurationProbe, discoveryBinder in
                let lease = try authority.duplicateOperationLease()
                defer { close(lease) }
                let inspection = try inspectSelectedClones(
                    candidates: discoverSelectedClones(scope: scope, binder: discoveryBinder),
                    state: authority.stateDirectory,
                    leaseDescriptor: lease,
                    audit: nil,
                    progress: progress,
                    configurationProbe: configurationProbe
                )
                let records = Dictionary(
                    uniqueKeysWithValues:
                        inspection.authoritySnapshot.usableRecords.map {
                            ($0.repositoryID, $0)
                        }
                )
                var proposals: [CanonicalAuthorityProposal] = []
                let grouped = Dictionary(
                    grouping: inspection.clones,
                    by: \.repositoryID
                )
                for repositoryID in grouped.keys.sorted() {
                    guard records[repositoryID] == nil,
                          let clones = grouped[repositoryID],
                          Self.aggregateCategory(clones) == .writable else {
                        continue
                    }
                    let eligible = clones.filter(\.isAuthorityEligible)
                    if eligible.count == 1, let clone = eligible.first {
                        proposals.append(
                            CanonicalAuthorityProposal(clone: clone)
                        )
                    }
                }
                let hydrated = Set(inspection.clones.map(\.repositoryID))
                guard hydrated.isSubset(of: scope.repositoryIDs),
                      !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
                return SelectedRepositoryHydrationEvidence(
                    scope: scope,
                    proposals: proposals,
                    authorityFileIdentity:
                        inspection.authoritySnapshot.fileIdentity,
                    hydratedRepositoryIDs: hydrated,
                    authorityCandidateClones: inspection.clones
                )
            }
            lifecycleObserver?(.finished(childCount: progress.count))
            return completed
        } catch {
            lifecycleObserver?(
                cancellation.areFutureChildAdmissionsClosed
                    ? .cancelled(childCount: progress.count)
                    : .failed(childCount: progress.count)
            )
            throw error
        }
    }

    func discoverSelectedHydration(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> SelectedRepositoryHydrationResult {
        let progress = RepositoryInventoryProgress(
            observer: lifecycleObserver
        )
        do {
            guard !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            let authority = try RunAuthority.acquireRun(at: stateLocation)
            lifecycleObserver?(.authorityAcquired)
            defer { authority.release() }
            let completed: SelectedRepositoryHydrationResult = try withFreshSelectedScope(scope, authority: authority) { scope, configurationProbe, discoveryBinder in
                let lease = try authority.duplicateOperationLease()
                defer { close(lease) }
                let candidates = try discoverSelectedClones(scope: scope, binder: discoveryBinder)
                let inspection = try inspectSelectedClones(
                    candidates: candidates,
                    state: authority.stateDirectory,
                    leaseDescriptor: lease,
                    audit: nil,
                    progress: progress,
                    configurationProbe: configurationProbe
                )
                let records = Dictionary(
                    uniqueKeysWithValues:
                        inspection.authoritySnapshot.usableRecords.map {
                            ($0.repositoryID, $0)
                        }
                )
                let grouped = Dictionary(
                    grouping: inspection.clones,
                    by: \.repositoryID
                )
                var proposals: [CanonicalAuthorityProposal] = []
                for repositoryID in grouped.keys.sorted() {
                    guard records[repositoryID] == nil,
                          let clones = grouped[repositoryID],
                          Self.aggregateCategory(clones) == .writable else {
                        continue
                    }
                    let eligible = clones.filter(\.isAuthorityEligible)
                    if eligible.count == 1, let clone = eligible.first {
                        proposals.append(
                            CanonicalAuthorityProposal(clone: clone)
                        )
                    }
                }
                let hydrated = Set(inspection.clones.map(\.repositoryID))
                guard hydrated == scope.repositoryIDs,
                      !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
                if !proposals.isEmpty {
                        return .onboarding(
                        scope,
                        RepositoryInventory(
                            cards: [],
                            onboardingProposals: proposals,
                            authorityFileIdentity:
                                inspection.authoritySnapshot.fileIdentity
                        )
                    )
                }
                let inventory = try makeInventory(
                    inspection: inspection,
                    scope: scope,
                    state: authority.stateDirectory,
                    progress: progress
                )
                guard !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
                return .verified(
                    try VerifiedSelectedRepositoryInventory(
                        capability:
                            VerifiedRepositoryAuthorityCapability(
                                scope: scope,
                                inventory: inventory
                            ),
                        inventory: inventory
                    )
                )
            }
            lifecycleObserver?(.finished(childCount: progress.count))
            return completed
        } catch {
            lifecycleObserver?(
                cancellation.areFutureChildAdmissionsClosed
                    ? .cancelled(childCount: progress.count)
                    : .failed(childCount: progress.count)
            )
            throw error
        }
    }

    private func discoverInventoryWithAuthority(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> RepositoryInventory {
        let progress = RepositoryInventoryProgress(
            observer: lifecycleObserver
        )
        do {
            guard !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            let authority = try RunAuthority.acquireRun(at: stateLocation)
            lifecycleObserver?(.authorityAcquired)
            defer { authority.release() }
            let completed: RepositoryInventory = try withFreshSelectedScope(scope, authority: authority) { scope, configurationProbe, discoveryBinder in
                let lease = try authority.duplicateOperationLease()
                defer { close(lease) }
                let inventory = try discoverInventory(
                    scope: scope,
                    state: authority.stateDirectory,
                    leaseDescriptor: lease,
                    progress: progress,
                    configurationProbe: configurationProbe,
                    discoveryBinder: discoveryBinder
                )
                guard !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
                return inventory
            }
            lifecycleObserver?(.finished(childCount: progress.count))
            return completed
        } catch {
            if cancellation.areFutureChildAdmissionsClosed {
                lifecycleObserver?(.cancelled(childCount: progress.count))
            } else {
                lifecycleObserver?(.failed(childCount: progress.count))
            }
            throw error
        }
    }

    /// Hydration already holds operation EX. Borrow its actual authority for
    /// fresh classification and keep that phase alive through all inspection.
    /// The source-built fixture path remains explicit and testing-only.
    private func discoverSelectedClones(scope: ValidatedSelectedRepositoryScope,
                                        binder: SelectedRepositoryScopeBinder?) throws -> [RepositoryCandidate] {
        if let binder {
            return try cloneDiscovery.discover(scope: scope, binder: binder, cancellation: cancellation)
        }
        #if SHADOW_SYNC_TESTING
        if transportMapping != nil { return try cloneDiscovery.discover(scope: scope) }
        #endif
        throw SelectedRepositoryScopeError.policyUnavailable
    }

    private func withFreshSelectedScope<Value>(_ scope: ValidatedSelectedRepositoryScope,
                                               authority: RunAuthority,
                                               _ body: (ValidatedSelectedRepositoryScope, SystemGitConfigurationProbe?, SelectedRepositoryScopeBinder?) throws -> Value) throws -> Value {
        #if SHADOW_SYNC_TESTING
        if transportMapping != nil { return try body(scope, nil, nil) }
        #endif
        return try SelectedRepositoryScopeBinder.withProductionConfigurationPhase(
            borrowing: authority, cancellation: cancellation
        ) { binder, probe in
            try binder.withReboundScope(scope, cancellation: cancellation) { fresh in
                let result = try body(fresh, probe, binder)
                try probe.validate(account: account)
                return result
            }
        }
    }

    #if SHADOW_SYNC_TESTING
    private func discoverInventoryForTesting()
        throws -> RepositoryInventory {
        let progress = RepositoryInventoryProgress(
            observer: lifecycleObserver
        )
        do {
            guard !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            let authority = try RunAuthority.acquireRun(
                at: stateLocation
            )
            lifecycleObserver?(.authorityAcquired)
            defer { authority.release() }
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            let inventory = try discoverInventory(
                state: authority.stateDirectory,
                leaseDescriptor: lease,
                progress: progress
            )
            lifecycleObserver?(.finished(childCount: progress.count))
            return inventory
        } catch {
            lifecycleObserver?(
                cancellation.areFutureChildAdmissionsClosed
                    ? .cancelled(childCount: progress.count)
                    : .failed(childCount: progress.count)
            )
            throw error
        }
    }
    #endif

    func discoverInventory(
        scope: ValidatedSelectedRepositoryScope,
        state: SecureStateDirectory,
        leaseDescriptor: Int32,
        audit: CommandAudit? = nil,
        progress: RepositoryInventoryProgress? = nil,
        configurationProbe: SystemGitConfigurationProbe? = nil,
        discoveryBinder: SelectedRepositoryScopeBinder? = nil
    ) throws -> RepositoryInventory {
        try makeInventory(
            candidates: discoverSelectedClones(scope: scope, binder: discoveryBinder),
            scope: scope,
            state: state,
            leaseDescriptor: leaseDescriptor,
            audit: audit,
            progress: progress,
            configurationProbe: configurationProbe
        )
    }

    #if SHADOW_SYNC_TESTING
    func discoverInventory(
        state: SecureStateDirectory,
        leaseDescriptor: Int32,
        audit: CommandAudit? = nil,
        progress: RepositoryInventoryProgress? = nil
    ) throws -> RepositoryInventory {
        try makeInventory(
            candidates: cloneDiscovery.discover(),
            scope: nil,
            state: state,
            leaseDescriptor: leaseDescriptor,
            audit: audit,
            progress: progress
        )
    }
    #endif

    public func inspectCleanup(
        inventory: RepositoryInventory,
        repositoryIDs: Set<String>,
        capability: VerifiedRepositoryAuthorityCapability
    ) throws -> RepositoryInventory {
        let inspectionStarted = Date()
        guard !repositoryIDs.isEmpty,
              repositoryIDs.isSubset(
                of: Set(inventory.cards.map(\.id))
              ),
              repositoryIDs.isSubset(
                of: capability.verifiedRepositoryIDs
              ),
              !cancellation.areFutureChildAdmissionsClosed else {
            throw GitSafetyError.unsafeRepository(
                "cleanup inspection scope is invalid"
            )
        }
        let authority = try RunAuthority.acquireRun(
            at: stateLocation
        )
        lifecycleObserver?(.authorityAcquired)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let progress = RepositoryInventoryProgress(
            observer: lifecycleObserver
        )
        let configurationContext: CommandCustodyContext?
        #if SHADOW_SYNC_TESTING
        configurationContext = transportMapping == nil ? try CommandCustodyContext.borrowing(authority) : nil
        #else
        configurationContext = try CommandCustodyContext.borrowing(authority)
        #endif
        defer { configurationContext?.close() }
        let configurationProbe = configurationContext.map {
            SystemGitConfigurationProbe(context: $0, cancellation: cancellation)
        }
        let runner = DescriptorProcessRunner(
            outputLimit: Self.inventoryOutputLimit,
            processObserver: { identity in
                progress.observe(identity)
            }
        )
        #if SHADOW_SYNC_TESTING
        let session = RepositoryReadSession(
            executablePath: executablePath,
            leaseDescriptor: lease,
            account: account,
            runner: runner,
            pullRequestLookup: pullRequestLookup,
            capturedNow: Date(),
            cancellation: cancellation,
            progress: progress,
            transportMapping: transportMapping,
            configurationProbe: configurationProbe
        )
        #else
        guard let configurationProbe else { throw SystemGitConfigurationError.unavailable }
        let session = RepositoryReadSession(
            executablePath: executablePath,
            leaseDescriptor: lease,
            account: account,
            runner: runner,
            pullRequestLookup: pullRequestLookup,
            capturedNow: Date(),
            cancellation: cancellation,
            progress: progress,
            configurationProbe: configurationProbe
        )
        #endif
        let setupDurationMilliseconds = Int64(
            Date().timeIntervalSince(inspectionStarted) * 1_000
        )
        var cards: [RepositoryCard] = []
        let repositoryTotal = repositoryIDs.count
        var repositoryCompleted = 0
        for card in inventory.cards {
            guard repositoryIDs.contains(card.id) else {
                cards.append(card)
                continue
            }
            let completedBefore = repositoryCompleted
            let emit: @Sendable (
                CleanupInspectionStage,
                Int,
                Int,
                Int,
                Int,
                Int,
                Int64
            ) -> Void = {
                [lifecycleObserver] stage, completed, total,
                active, maximum, partial, duration in
                lifecycleObserver?(
                    .cleanupProgress(
                        CleanupInspectionProgress(
                            repositoryID: card.id,
                            repositoryCompleted:
                                completedBefore,
                            repositoryTotal: repositoryTotal,
                            stage: stage,
                            completed: completed,
                            total: total,
                            activeChildren: active,
                            maximumActiveChildren: maximum,
                            partialCount: partial,
                            durationMilliseconds: duration,
                            heartbeat: max(
                                completed,
                                Int(duration / 1_000)
                            )
                        )
                    )
                )
            }
            emit(
                .topology,
                0,
                1,
                0,
                0,
                0,
                setupDurationMilliseconds
            )
            let clones = try card.clones.map {
                try session.validatePhaseCompletion()
                let clone = try session.inspectCleanup(
                    clone: $0,
                    remote: card.repository,
                    queryPullRequests: card.isWritable,
                    progressUpdate: emit
                )
                try session.validatePhaseCompletion()
                return clone
            }
            let assemblyStarted = Date()
            emit(.candidateAssembly, 0, 1, 0, 0, 0, 0)
            cards.append(
                try card.replacingClones(
                    clones,
                    capability: capability
                )
            )
            repositoryCompleted += 1
            lifecycleObserver?(
                .cleanupProgress(
                    CleanupInspectionProgress(
                        repositoryID: card.id,
                        repositoryCompleted: repositoryCompleted,
                        repositoryTotal: repositoryTotal,
                        stage: .candidateAssembly,
                        completed: 1,
                        total: 1,
                        durationMilliseconds: Int64(
                            Date().timeIntervalSince(
                                assemblyStarted
                            ) * 1_000
                        )
                    )
                )
            )
        }
        try session.validatePhaseCompletion()
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw GitSafetyError.cancelled
        }
        lifecycleObserver?(
            .finished(childCount: progress.count)
        )
        return RepositoryInventory(
            cards: cards,
            onboardingProposals:
                inventory.onboardingProposals,
            authorityFileIdentity:
                inventory.authorityFileIdentity
        )
    }

    private struct SelectedCloneInspection {
        let clones: [LocalClone]
        let authoritySnapshot: RepositoryAuthoritySnapshot
        let session: RepositoryReadSession
    }

    private func inspectSelectedClones(
        candidates: [RepositoryCandidate],
        state: SecureStateDirectory,
        leaseDescriptor: Int32,
        audit: CommandAudit?,
        progress: RepositoryInventoryProgress?,
        configurationProbe: SystemGitConfigurationProbe? = nil
    ) throws -> SelectedCloneInspection {
        let authoritySnapshot = RepositoryAuthorityStore(
            state: state
        ).snapshot()
        let runner = DescriptorProcessRunner(
            audit: audit,
            outputLimit: Self.inventoryOutputLimit,
            processObserver: { identity in
                progress?.observe(identity) ?? true
            }
        )
        #if SHADOW_SYNC_TESTING
        let session = RepositoryReadSession(
            executablePath: executablePath,
            leaseDescriptor: leaseDescriptor,
            account: account,
            runner: runner,
            pullRequestLookup: pullRequestLookup,
            capturedNow: Date(),
            cancellation: cancellation,
            progress: progress,
            transportMapping: transportMapping,
            configurationProbe: configurationProbe
        )
        #else
        guard let configurationProbe else { throw SystemGitConfigurationError.unavailable }
        let session = RepositoryReadSession(
            executablePath: executablePath,
            leaseDescriptor: leaseDescriptor,
            account: account,
            runner: runner,
            pullRequestLookup: pullRequestLookup,
            capturedNow: Date(),
            cancellation: cancellation,
            progress: progress,
            configurationProbe: configurationProbe
        )
        #endif
        var clones: [LocalClone] = []
        for candidate in candidates {
            guard !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            lifecycleObserver?(
                .repositoryProgress(
                    completed: 0,
                    total: candidates.count,
                    repositoryID: candidate.id,
                    phase: "Inspecting"
                )
            )
            guard let repositoryID =
                candidate.originIdentity?.canonicalName,
                  candidate.rootIdentity != nil,
                  candidate.commonDirectoryIdentity != nil else {
                continue
            }
            let category = Self.policyCategory(candidate)
            do {
                clones.append(
                    try session.inspectClone(
                        candidate,
                        category: category
                    )
                )
            } catch {
                try session.validatePhaseCompletion()
                if error is SystemGitConfigurationError { throw error }
                guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
                let fallback = try Self.fallbackClone(
                    candidate,
                    category: category,
                    error: error
                )
                guard fallback.repositoryID == repositoryID else {
                    continue
                }
                clones.append(fallback)
            }
        }
        try session.validatePhaseCompletion()
        return SelectedCloneInspection(
            clones: clones,
            authoritySnapshot: authoritySnapshot,
            session: session
        )
    }

    private func makeInventory(
        candidates: [RepositoryCandidate],
        scope: ValidatedSelectedRepositoryScope?,
        state: SecureStateDirectory,
        leaseDescriptor: Int32,
        audit: CommandAudit?,
        progress: RepositoryInventoryProgress?,
        configurationProbe: SystemGitConfigurationProbe? = nil
    ) throws -> RepositoryInventory {
        let inspection = try inspectSelectedClones(
            candidates: candidates,
            state: state,
            leaseDescriptor: leaseDescriptor,
            audit: audit,
            progress: progress,
            configurationProbe: configurationProbe
        )
        return try makeInventory(
            inspection: inspection,
            scope: scope,
            state: state,
            progress: progress
        )
    }

    private func makeInventory(
        inspection: SelectedCloneInspection,
        scope: ValidatedSelectedRepositoryScope?,
        state: SecureStateDirectory,
        progress: RepositoryInventoryProgress?
    ) throws -> RepositoryInventory {
        try inspection.session.validatePhaseCompletion()
        let clones = inspection.clones
        var authoritySnapshot = inspection.authoritySnapshot
        if let scope {
            if let first = scope.repositoryIDs.sorted().first {
                lifecycleObserver?(
                    .repositoryProgress(
                        completed: 0,
                        total: scope.repositoryIDs.count,
                        repositoryID: first,
                        phase: "Verifying authority"
                    )
                )
            }
            authoritySnapshot =
                try RepositoryAuthorityStore(
                    state: state
                ).refreshSelectedDeviceDrift(
                    selectedRepositoryIDs:
                        scope.repositoryIDs,
                    freshClones: clones,
                    expectedFileIdentity:
                        authoritySnapshot.fileIdentity
                )
        }
        let session = inspection.session
        let capability = try scope.map {
            try VerifiedRepositoryAuthorityCapability(
                scope: $0,
                clones: clones,
                authoritySnapshot: authoritySnapshot
            )
        }

        let authorityRecords = Dictionary(
            uniqueKeysWithValues: authoritySnapshot.usableRecords.map {
                ($0.repositoryID, $0)
            }
        )
        let grouped = Dictionary(grouping: clones, by: \.repositoryID)
        var cards: [RepositoryCard] = []
        var usableAuthorityCount = 0
        var onboardingProposals: [CanonicalAuthorityProposal] = []

        for repositoryID in grouped.keys.sorted() {
            try session.validatePhaseCompletion()
            guard let repositoryClones = grouped[repositoryID],
                  !repositoryClones.isEmpty else {
                continue
            }
            let category = Self.aggregateCategory(repositoryClones)
            lifecycleObserver?(
                .repositoryProgress(
                    completed: cards.count,
                    total: grouped.count,
                    repositoryID: repositoryID,
                    phase: "Resolving default branch"
                )
            )
            let authorityRecord = authorityRecords[repositoryID]
            let matchingAuthorityClone = authorityRecord.flatMap { record in
                let matches = repositoryClones.filter(record.matches)
                return matches.count == 1 ? matches[0] : nil
            }
            let authorityState: CanonicalAuthorityState
            if category != .writable {
                authorityState = CanonicalAuthorityState(
                    status: .notApplicable,
                    record: nil,
                    explanation:
                        "Canonical update authority is unavailable for this policy category."
                )
            } else if authoritySnapshot.status == .unusable {
                authorityState = CanonicalAuthorityState(
                    status: .unavailable,
                    record: nil,
                    explanation: authoritySnapshot.explanation
                        ?? "Canonical-root records are unavailable."
                )
            } else if let authorityRecord,
                      matchingAuthorityClone != nil {
                usableAuthorityCount += 1
                authorityState = CanonicalAuthorityState(
                    status: .usable,
                    record: authorityRecord,
                    explanation: "Canonical root verified."
                )
            } else if authorityRecord != nil {
                authorityState = CanonicalAuthorityState(
                    status: .stale,
                    record: authorityRecord,
                    explanation:
                        "Canonical root needs review because its live identity, origin, or policy no longer matches."
                )
            } else {
                let writable = repositoryClones.filter(
                    \.isAuthorityEligible
                )
                authorityState = CanonicalAuthorityState(
                    status: writable.count > 1 ? .ambiguous : .missing,
                    record: nil,
                    explanation: writable.count > 1
                        ? "Choose canonical root before Fast-forward is available."
                        : "Confirm this canonical root before Fast-forward is available."
                )
            }

            var resolvedDefault: RemoteDefaultBranch?
            var defaultUnavailable: String?
            if let matchingAuthorityClone {
                do {
                    resolvedDefault = try session.resolveRemoteDefault(
                        matchingAuthorityClone.sourceSnapshot
                    )
                } catch {
                    try session.validatePhaseCompletion()
                    defaultUnavailable = Self.defaultRefusal(error)
                }
            }
            let remote = try RemoteRepository(
                id: repositoryID,
                origins: repositoryClones.map(\.rawOrigin),
                policyCategory: category,
                resolvedDefault: resolvedDefault,
                defaultUnavailableReason: defaultUnavailable
            )
            lifecycleObserver?(
                .repositoryProgress(
                    completed: cards.count,
                    total: grouped.count,
                    repositoryID: repositoryID,
                    phase: "Checking default branch"
                )
            )
            let topLevelClones = try repositoryClones.map {
                try session.validatePhaseCompletion()
                let clone = try session.prepareTopLevel(
                    clone: $0,
                    remote: remote
                )
                try session.validatePhaseCompletion()
                return clone
            }
            let enrichedCanonicalClone = matchingAuthorityClone.flatMap {
                selected in
                topLevelClones.first { $0.id == selected.id }
            }
            let card = try Self.card(
                remote: remote,
                authority: authorityState,
                clones: topLevelClones,
                canonicalClone: enrichedCanonicalClone,
                session: session,
                capability: capability
            )
            try session.validatePhaseCompletion()
            cards.append(card)
            lifecycleObserver?(
                .repositoryProgress(
                    completed: cards.count,
                    total: grouped.count,
                    repositoryID: repositoryID,
                    phase: "Complete"
                )
            )
        }

        if usableAuthorityCount == 0 {
            for card in cards where card.isWritable {
                guard authorityRecords[card.id] == nil else {
                    continue
                }
                let eligible = card.clones.filter(\.isAuthorityEligible)
                if eligible.count == 1, let clone = eligible.first {
                    onboardingProposals.append(
                        CanonicalAuthorityProposal(clone: clone)
                    )
                }
            }
        }
        return RepositoryInventory(
            cards: cards,
            onboardingProposals: onboardingProposals,
            authorityFileIdentity: authoritySnapshot.fileIdentity
        )
    }

    private static func card(
        remote: RemoteRepository,
        authority: CanonicalAuthorityState,
        clones: [LocalClone],
        canonicalClone: LocalClone?,
        session: RepositoryReadSession,
        capability: VerifiedRepositoryAuthorityCapability?
    ) throws -> RepositoryCard {
        guard remote.policyCategory == .writable else {
            return try makeCardAggregate(
                repository: remote,
                authority: authority,
                clones: clones,
                relation: .unavailable,
                fastForward: nil,
                fastForwardRefusal: remote.policyCategory.operatorLabel,
                capability: capability
            )
        }
        guard authority.status == .usable,
              let canonicalClone else {
            return try makeCardAggregate(
                repository: remote,
                authority: authority,
                clones: clones,
                relation: .unavailable,
                fastForward: nil,
                fastForwardRefusal: authority.explanation,
                capability: capability
            )
        }
        guard let resolvedDefault = remote.resolvedDefault else {
            return try makeCardAggregate(
                repository: remote,
                authority: authority,
                clones: clones,
                relation: .unavailable,
                fastForward: nil,
                fastForwardRefusal: remote.defaultUnavailableReason
                    ?? "The actual remote default branch is unavailable.",
                capability: capability
            )
        }
        let maintenance = try session.maintenanceOperations(
            clone: canonicalClone,
            remote: remote,
            capability: capability
        )
        try session.validatePhaseCompletion()
        let originHead = try session.originHeadExplanation(
            clone: canonicalClone,
            remote: remote
        )
        try session.validatePhaseCompletion()
        func makeCard(
            relation: DefaultBranchRelation,
            fastForward: PlannedOperation?,
            refusal: String?
        ) throws -> RepositoryCard {
            try makeCardAggregate(
                repository: remote,
                authority: authority,
                clones: clones,
                relation: relation,
                fastForward: fastForward,
                fastForwardRefusal: refusal,
                maintenanceOperations:
                    maintenance.operations,
                maintenanceRefusals:
                    maintenance.refusals,
                maintenanceDiagnostics:
                    maintenance.diagnostics,
                originHeadExplanation: originHead,
                capability: capability
            )
        }
        guard let branch = canonicalClone.branches.first(where: {
            $0.fullRef == resolvedDefault.localRef
        }), let localOID = branch.tipOID else {
            return try makeCard(
                relation: .unavailable,
                fastForward: nil,
                refusal:
                    "The local default branch is missing. Use the explicit Initialize control when it is available."
            )
        }
        guard branch.claimingWorktreeIDs.count <= 1 else {
            return try makeCard(
                relation: .unavailable,
                fastForward: nil,
                refusal:
                    "Fast-forward refused because multiple worktrees claim the default branch."
            )
        }
        let relation = (try? session.cachedExactRelation(
            candidate: canonicalClone.sourceSnapshot,
            localOID: localOID,
            remote: resolvedDefault
        )) ?? .unavailable
        try session.validatePhaseCompletion()
        guard let worktreeID = branch.claimingWorktreeIDs.first else {
            guard relation.kind == .equal
                || relation.kind == .behind else {
                let refusal = relation.kind == .unavailable
                    ? "Fast-forward refused because the default-branch relation is unavailable."
                    : "Fast-forward refuses \(relation.operatorLabel)."
                return try makeCard(
                    relation: relation,
                    fastForward: nil,
                    refusal: refusal
                )
            }
            let hookEvidence =
                try? session.updateRefHookSHA256(
                    canonicalClone.sourceSnapshot
                )
            try session.validatePhaseCompletion()
            guard let hookEvidence else {
                return try makeCard(
                    relation: relation,
                    fastForward: nil,
                    refusal:
                        "Ref-only Fast-forward refused because its applicable reference-hook identity could not be verified."
                )
            }
            let preservationEvidence =
                try? session.refOnlyPreservation(
                    canonicalClone
                )
            try session.validatePhaseCompletion()
            guard let preservationEvidence else {
                return try makeCard(
                    relation: relation,
                    fastForward: nil,
                    refusal:
                        "Ref-only Fast-forward refused because its worktree, index, or registration identity could not be verified."
                )
            }
            let target = try DefaultBranchUpdateTarget(
                repository: remote,
                canonicalClone: canonicalClone,
                resolvedDefault: resolvedDefault,
                expectedLocalOID: localOID,
                expectedFetchedOID: resolvedDefault.advertisedOID,
                operationHookSHA256: hookEvidence,
                registrationSetSHA256:
                    preservationEvidence
                        .registrationDigest,
                preservationSHA256:
                    preservationEvidence.evidenceDigest,
                mode: .refOnly,
                worktreeID: nil,
                relation: relation
            )
            return try makeCard(
                relation: relation,
                fastForward: makePlannedOperation(
                    target: target,
                    capability: capability
                ),
                refusal: nil
            )
        }
        guard let worktree = canonicalClone.worktrees.first(where: {
            $0.id == worktreeID
        }), worktree.verification == .verified else {
            return try makeCard(
                relation: relation,
                fastForward: nil,
                refusal:
                    "The default-branch worktree could not be verified."
            )
        }
        guard worktree.cleanliness == .clean else {
            return try makeCard(
                relation: relation,
                fastForward: nil,
                refusal: worktree.cleanliness == .dirty
                    ? "The default-branch worktree has local changes."
                    : (
                        worktree.warning
                            ?? "The default-branch worktree cleanliness or index state is unavailable."
                    )
            )
        }
        guard relation.kind == .equal
            || relation.kind == .behind
            || relation.kind == .unavailable else {
            let refusal = "Fast-forward refuses \(relation.operatorLabel)."
            return try makeCard(
                relation: relation,
                fastForward: nil,
                refusal: refusal
            )
        }
        let target = try DefaultBranchUpdateTarget(
            repository: remote,
            canonicalClone: canonicalClone,
            resolvedDefault: resolvedDefault,
            expectedLocalOID: localOID,
            expectedFetchedOID: resolvedDefault.advertisedOID,
            mode: .checkedOut,
            worktreeID: worktreeID,
            relation: relation
        )
        return try makeCard(
            relation: relation,
            fastForward: makePlannedOperation(
                target: target,
                capability: capability
            ),
            refusal: nil
        )
    }

    private static func makePlannedOperation(
        target: DefaultBranchUpdateTarget,
        capability: VerifiedRepositoryAuthorityCapability?
    ) throws -> PlannedOperation {
        if let capability {
            return try PlannedOperation(
                target: target,
                capability: capability
            )
        }
        #if SHADOW_SYNC_TESTING
        return PlannedOperation(target: target)
        #else
        throw GitSafetyError.unsafeRepository(
            "planned operation construction lacks verified selected authority"
        )
        #endif
    }

    private static func makeCardAggregate(
        repository: RemoteRepository,
        authority: CanonicalAuthorityState,
        clones: [LocalClone],
        relation: DefaultBranchRelation,
        fastForward: PlannedOperation?,
        fastForwardRefusal: String?,
        maintenanceOperations: [PlannedOperation] = [],
        maintenanceRefusals: [String] = [],
        maintenanceDiagnostics: [String]? = nil,
        originHeadExplanation: String? = nil,
        capability: VerifiedRepositoryAuthorityCapability?
    ) throws -> RepositoryCard {
        if let capability {
            return try RepositoryCard(
                repository: repository,
                authority: authority,
                clones: clones,
                relation: relation,
                fastForward: fastForward,
                fastForwardRefusal: fastForwardRefusal,
                maintenanceOperations: maintenanceOperations,
                maintenanceRefusals: maintenanceRefusals,
                maintenanceDiagnostics:
                    maintenanceDiagnostics,
                originHeadExplanation: originHeadExplanation,
                capability: capability
            )
        }
        #if SHADOW_SYNC_TESTING
        return try RepositoryCard(
            repository: repository,
            authority: authority,
            clones: clones,
            relation: relation,
            fastForward: fastForward,
            fastForwardRefusal: fastForwardRefusal,
            maintenanceOperations: maintenanceOperations,
            maintenanceRefusals: maintenanceRefusals,
            maintenanceDiagnostics:
                maintenanceDiagnostics,
            originHeadExplanation: originHeadExplanation
        )
        #else
        throw GitSafetyError.unsafeRepository(
            "repository card construction lacks verified selected authority"
        )
        #endif
    }

    private static func policyCategory(
        _ candidate: RepositoryCandidate
    ) -> RepositoryPolicyCategory {
        if candidate.blockedReason == .permanentNoTouch {
            return .permanentNoTouch
        }
        #if SHADOW_SYNC_TESTING
        if candidate.originIdentity?.canonicalName == "fixture-owner/dev",
           candidate.presentationLocation == "~/dev" {
            return .writable
        }
        #endif
        if candidate.blockedReason == .readOnlyReference {
            return .reference
        }
        if candidate.blockedReason == .excludedByPolicy {
            return .repositoryOwnedWorkflow
        }
        return .writable
    }

    private static func aggregateCategory(
        _ clones: [LocalClone]
    ) -> RepositoryPolicyCategory {
        if clones.contains(where: {
            $0.policyCategory == .writable
        }) {
            return .writable
        }
        if clones.contains(where: {
            $0.policyCategory == .permanentNoTouch
        }) {
            return .permanentNoTouch
        }
        if clones.contains(where: {
            $0.policyCategory == .repositoryOwnedWorkflow
        }) {
            return .repositoryOwnedWorkflow
        }
        return .reference
    }

    #if SHADOW_SYNC_TESTING
    static func testingPolicyCategory(
        _ candidate: RepositoryCandidate
    ) -> RepositoryPolicyCategory {
        policyCategory(candidate)
    }
    #endif

    private static func fallbackClone(
        _ candidate: RepositoryCandidate,
        category: RepositoryPolicyCategory,
        error: Error
    ) throws -> LocalClone {
        guard let rootIdentity = candidate.rootIdentity,
              let commonIdentity = candidate.commonDirectoryIdentity,
              let repositoryID = candidate.originIdentity?.canonicalName else {
            throw error
        }
        let cloneID = LocalClone.id(for: commonIdentity)
        let primaryID =
            "worktree:\(cloneID):\(rootIdentity.device):\(rootIdentity.inode)"
        let primary = try Worktree(
            id: primaryID,
            cloneID: cloneID,
            path: candidate.path,
            rootIdentity: rootIdentity,
            registrationIdentity: nil,
            attachedBranchRef: nil,
            detachedOID: nil,
            isPrimary: true,
            locationKind: .canonicalPrimary,
            verification: .verified,
            warning: "Local topology could not be verified."
        )
        return try LocalClone(
            repositoryID: repositoryID,
            sourceSnapshot: candidate,
            effectiveOrigin: candidate.rawOrigin,
            originParityVerified: false,
            policyCategory: category,
            kind: category == .reference
                ? .readOnlyReference
                : (category == .writable
                    ? .primaryCheckout
                    : .protected),
            worktrees: [primary],
            branches: [],
            warnings: [String(describing: error)]
        )
    }

    private static func defaultRefusal(_ error: Error) -> String {
        if let error = error as? RemoteDefaultResolutionError {
            return error.operatorExplanation
        }
        return "The actual remote default branch could not be verified."
    }
}

public enum RemoteDefaultResolutionError:
    Error, CustomStringConvertible, Equatable {
    case missing
    case malformed
    case changed

    public var description: String {
        operatorExplanation
    }

    public var operatorExplanation: String {
        switch self {
        case .missing:
            return "The remote does not advertise a symbolic default branch."
        case .malformed:
            return "The remote default branch response is malformed."
        case .changed:
            return "The remote default branch changed during inspection."
        }
    }
}

enum RemoteDefaultResolver {
    static func parse(_ data: Data) throws -> RemoteDefaultBranch {
        guard let output = String(data: data, encoding: .utf8),
              !output.contains("\r"),
              !output.contains("\0") else {
            throw RemoteDefaultResolutionError.malformed
        }
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !lines.isEmpty else {
            throw RemoteDefaultResolutionError.missing
        }
        var branchName: String?
        var oid: String?
        for line in lines {
            if line.hasPrefix("ref: refs/heads/"),
               line.hasSuffix("\tHEAD") {
                guard branchName == nil else {
                    throw RemoteDefaultResolutionError.malformed
                }
                let start = line.index(
                    line.startIndex,
                    offsetBy: "ref: refs/heads/".count
                )
                let end = line.index(line.endIndex, offsetBy: -"\tHEAD".count)
                branchName = String(line[start..<end])
            } else if line.hasSuffix("\tHEAD") {
                guard oid == nil else {
                    throw RemoteDefaultResolutionError.malformed
                }
                oid = String(line.dropLast("\tHEAD".count))
            } else {
                throw RemoteDefaultResolutionError.malformed
            }
        }
        guard let branchName, let oid else {
            throw RemoteDefaultResolutionError.missing
        }
        return try RemoteDefaultBranch(
            name: branchName,
            advertisedOID: oid
        )
    }
}

final class RepositoryReadSession: @unchecked Sendable {
    private let executablePath: String
    private let leaseDescriptor: Int32
    private let account: EffectiveAccount
    private let runner: DescriptorProcessRunner
    private let pullRequestLookup: any PullRequestLookingUp
    private let capturedNow: Date
    private let cancellation: CancellationToken
    private let progress: RepositoryInventoryProgress?
    private let configurationProbe: SystemGitConfigurationProbe?
    #if SHADOW_SYNC_TESTING
    private let transportMapping: TransportMapping?
    #endif

    init(
        executablePath: String,
        leaseDescriptor: Int32,
        account: EffectiveAccount,
        runner: DescriptorProcessRunner,
        pullRequestLookup: any PullRequestLookingUp,
        capturedNow: Date,
        cancellation: CancellationToken = CancellationToken(),
        progress: RepositoryInventoryProgress? = nil,
        configurationProbe: SystemGitConfigurationProbe
    ) {
        self.executablePath = executablePath
        self.leaseDescriptor = leaseDescriptor
        self.account = account
        self.runner = runner
        self.pullRequestLookup = pullRequestLookup
        self.capturedNow = capturedNow
        self.cancellation = cancellation
        self.progress = progress
        self.configurationProbe = configurationProbe
        #if SHADOW_SYNC_TESTING
        transportMapping = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    init(
        executablePath: String,
        leaseDescriptor: Int32,
        account: EffectiveAccount,
        runner: DescriptorProcessRunner,
        pullRequestLookup: any PullRequestLookingUp =
            UnavailablePullRequestLookup(),
        capturedNow: Date = Date(),
        cancellation: CancellationToken = CancellationToken(),
        progress: RepositoryInventoryProgress? = nil,
        transportMapping: TransportMapping?,
        configurationProbe: SystemGitConfigurationProbe? = nil
    ) {
        self.executablePath = executablePath
        self.leaseDescriptor = leaseDescriptor
        self.account = account
        self.runner = runner
        self.pullRequestLookup = pullRequestLookup
        self.capturedNow = capturedNow
        self.cancellation = cancellation
        self.progress = progress
        self.configurationProbe = configurationProbe
        self.transportMapping = transportMapping
    }
    #endif

    func validatePhaseCompletion() throws {
        try configurationProbe?.validate(account: account)
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw GitSafetyError.cancelled
        }
    }

    func inspectClone(
        _ candidate: RepositoryCandidate,
        category: RepositoryPolicyCategory,
        inspectAllWorktreeState: Bool = false
    ) throws -> LocalClone {
        try validatePhaseCompletion()
        let handle = try RepositoryHandle.open(candidate)
        let frozen = try freeze(handle)
        let admission = try transportAdmission(
            handle: handle,
            frozen: frozen
        )
        let topology = try topology(
            candidate: candidate,
            handle: handle,
            frozen: frozen,
            admission: admission,
            inspectAllWorktreeState:
                inspectAllWorktreeState
        )
        try validatePhaseCompletion()
        return try LocalClone(
            repositoryID: handle.githubIdentity.canonicalName,
            sourceSnapshot: candidate,
            effectiveOrigin: admission.effectiveURL,
            originParityVerified: true,
            policyCategory: category,
            kind: category == .reference
                ? .readOnlyReference
                : (category == .writable
                    ? .primaryCheckout
                    : .protected),
            worktrees: topology.worktrees,
            branches: topology.branches,
            warnings: []
        )
    }

    func prepareTopLevel(
        clone: LocalClone,
        remote: RemoteRepository
    ) throws -> LocalClone {
        try validatePhaseCompletion()
        guard let resolvedDefault = remote.resolvedDefault else {
            return clone
        }
        do {
            let handle = try RepositoryHandle.open(
                clone.sourceSnapshot
            )
            let frozen = try freeze(handle)
            let admission = try transportAdmission(
                handle: handle,
                frozen: frozen
            )
            let defaultClaims = Set(
                clone.branches.first {
                    $0.fullRef == resolvedDefault.localRef
                }?.claimingWorktreeIDs ?? []
            )
            let targetIDs = defaultClaims.union(
                clone.worktrees.filter(\.isPrimary).map(\.id)
            )
            let worktrees = try clone.worktrees.map { worktree in
                try validatePhaseCompletion()
                guard targetIDs.contains(worktree.id),
                      worktree.verification == .verified,
                      worktree.fileState == nil else {
                    return worktree
                }
                let state = try worktreeState(
                    candidate: clone.sourceSnapshot,
                    worktree: worktree,
                    frozen: frozen,
                    admission: admission,
                    includeRemovalEvidence: false
                )
                let warnings = [
                    worktree.warning, state.warning,
                ].compactMap { $0 }
                return (
                    try? Worktree(
                        id: worktree.id,
                        cloneID: worktree.cloneID,
                        path: worktree.path,
                        rootIdentity: worktree.rootIdentity,
                        registrationIdentity:
                            worktree.registrationIdentity,
                        attachedBranchRef:
                            worktree.attachedBranchRef,
                        detachedOID: worktree.detachedOID,
                        isPrimary: worktree.isPrimary,
                        isLocked: worktree.isLocked,
                        locationKind: worktree.locationKind,
                        verification: worktree.verification,
                        cleanliness: state.cleanliness,
                        fileState: state.fileState,
                        contentEvidenceDigest:
                            state.contentEvidenceDigest,
                        warning: warnings.isEmpty
                            ? nil : warnings.joined(separator: " ")
                    )
                ) ?? worktree
            }
            return replacing(
                clone,
                worktrees: worktrees,
                branches: clone.branches
            )
        } catch {
            try validatePhaseCompletion()
            return clone
        }
    }

    func inspectCleanup(
        clone: LocalClone,
        remote: RemoteRepository,
        queryPullRequests: Bool,
        progressUpdate: (@Sendable (
            CleanupInspectionStage,
            Int,
            Int,
            Int,
            Int,
            Int,
            Int64
        ) -> Void)? = nil
    ) throws -> LocalClone {
        try validatePhaseCompletion()
        guard !cancellation.areFutureChildAdmissionsClosed else {
            return cloneWithWarning(
                clone,
                "Cleanup inspection not started because cancellation stopped new admission."
            )
        }
        do {
            progressUpdate?(
                .topology,
                1,
                1,
                0,
                0,
                0,
                0
            )
            let worktreeStarted = Date()
            progressUpdate?(
                .worktreeEvidence,
                0,
                clone.worktrees.count,
                0,
                0,
                0,
                0
            )
            let fresh = try inspectClone(
                clone.sourceSnapshot,
                category: clone.policyCategory,
                inspectAllWorktreeState: true
            )
            progressUpdate?(
                .worktreeEvidence,
                fresh.worktrees.count,
                fresh.worktrees.count,
                0,
                0,
                0,
                Int64(
                    Date().timeIntervalSince(
                        worktreeStarted
                    ) * 1_000
                )
            )
            return try enrichLifecycle(
                clone: fresh,
                remote: remote,
                queryPullRequests: queryPullRequests,
                progressUpdate: progressUpdate
            )
        } catch {
            try validatePhaseCompletion()
            return cloneWithWarning(
                clone,
                "Cleanup inspection failed: "
                    + Redactor.sanitize(
                        String(describing: error)
                    )
            )
        }
    }

    func enrichLifecycle(
        clone: LocalClone,
        remote: RemoteRepository,
        queryPullRequests: Bool,
        progressUpdate: (@Sendable (
            CleanupInspectionStage,
            Int,
            Int,
            Int,
            Int,
            Int,
            Int64
        ) -> Void)? = nil
    ) throws -> LocalClone {
        try validatePhaseCompletion()
        guard let resolvedDefault = remote.resolvedDefault else {
            return clone
        }
        let relationStarted = Date()
        progressUpdate?(
            .branchRelations,
            0,
            clone.branches.count,
            0,
            0,
            0,
            0
        )
        do {
            let handle = try RepositoryHandle.open(
                clone.sourceSnapshot
            )
            let frozen = try freeze(handle)
            let admission = try transportAdmission(
                handle: handle,
                frozen: frozen
            )
            let localDefaultOID = try optionalCommit(
                resolvedDefault.localRef,
                handle: handle,
                frozen: frozen,
                admission: admission
            )
            let trackingDefaultOID = try optionalCommit(
                    resolvedDefault.remoteTrackingRef,
                    handle: handle,
                    frozen: frozen,
                    admission: admission
                )
            let defaultComparisonOID =
                trackingDefaultOID == resolvedDefault.advertisedOID
                    || localDefaultOID == resolvedDefault.advertisedOID
                ? resolvedDefault.advertisedOID : nil

            let branchEvidence = try bulkBranchEvidence(
                defaultComparisonOID: defaultComparisonOID,
                handle: handle,
                frozen: frozen,
                admission: admission
            )
            progressUpdate?(
                .branchRelations,
                clone.branches.count,
                clone.branches.count,
                0,
                0,
                0,
                Int64(
                    Date().timeIntervalSince(
                        relationStarted
                    ) * 1_000
                )
            )
            let pullRequestBatch: PullRequestBatchOutcome
            if queryPullRequests {
                pullRequestBatch = lookupPullRequests(
                    repositoryID: clone.repositoryID,
                    branches: clone.branches.filter {
                        $0.fullRef
                            != resolvedDefault.localRef
                            && $0.tipOID != nil
                    },
                    progressUpdate: progressUpdate
                )
            } else {
                pullRequestBatch = PullRequestBatchOutcome(
                    results: [:],
                    incompleteCount: 0,
                    maximumActiveChildren: 0
                )
                progressUpdate?(
                    .pullRequestEvidence,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0
                )
            }
            let assemblyStarted = Date()
            progressUpdate?(
                .candidateAssembly,
                0,
                1,
                0,
                pullRequestBatch.maximumActiveChildren,
                pullRequestBatch.issueCount,
                0
            )
            var enrichedBranches: [Branch] = []
            for branch in clone.branches {
                try validatePhaseCompletion()
                let evidence = branchEvidence[branch.fullRef].flatMap {
                    $0.tipOID == branch.tipOID ? $0 : nil
                }
                let relationToDefault =
                    evidence?.relationToDefault
                let integrated = evidence?.integratedIntoDefault
                var upstream: BranchUpstream?
                if let configured = branch.upstream {
                    let upstreamEvidence =
                        evidence?.upstreamRef == configured.fullRef
                            ? evidence : nil
                    upstream = BranchUpstream(
                        fullRef: configured.fullRef,
                        localOID: branch.tipOID,
                        upstreamOID:
                            upstreamEvidence?.upstreamOID,
                        relation: Self.upstreamKind(
                            upstreamEvidence?
                                .upstreamRelation?.kind
                        ),
                        aheadCount:
                            upstreamEvidence?
                                .upstreamRelation?.aheadCount,
                        behindCount:
                            upstreamEvidence?
                                .upstreamRelation?.behindCount
                    )
                }
                let lookup: PullRequestLookupResult
                if queryPullRequests,
                   branch.fullRef != resolvedDefault.localRef,
                   branch.tipOID != nil {
                    lookup =
                        pullRequestBatch.results[branch.id]
                            ?? .unavailable(.timeout)
                } else {
                    lookup = PullRequestLookupResult(
                        records: [],
                        unavailableReason:
                            queryPullRequests ? nil : .adapterAbsent
                    )
                }
                let purpose = PurposeOracle.assess(
                    repositoryID: clone.repositoryID,
                    branch: branch.name,
                    tipOID: branch.tipOID,
                    pullRequests: lookup.records,
                    pullRequestAvailability: lookup.availability,
                    tipIntegratedIntoDefault: integrated
                )
                let activity = ActivityBandOracle.classify(
                    capturedNow: capturedNow,
                    commitDate: branch.commitDate.flatMap(
                        PullRequestRecord.parseTimestamp
                    ),
                    associatedPullRequests:
                        purpose.exactAssociations
                )
                let preserved = integrated.map { integrated in
                    integrated
                        || (
                            upstream?.fullRef.hasPrefix(
                                "refs/remotes/origin/"
                            ) == true
                                && upstream?.upstreamOID
                                    == branch.tipOID
                        )
                }
                let removal = RemovalPreviewOracle.branch(
                    isResolvedDefault:
                        branch.fullRef
                            == resolvedDefault.localRef,
                    policyCategory: clone.policyCategory,
                    claimIDs: branch.claimingWorktreeIDs,
                    purpose: purpose.purpose,
                    activity: activity,
                    tipPreserved: preserved
                )
                enrichedBranches.append(try Branch(
                    cloneID: branch.cloneID,
                    fullRef: branch.fullRef,
                    tipOID: branch.tipOID,
                    claimingWorktreeIDs:
                        branch.claimingWorktreeIDs,
                    relationToDefault: relationToDefault
                        ?? .unavailable,
                    upstream: upstream,
                    commitDate: branch.commitDate,
                    pullRequests: lookup.records,
                    pullRequestAvailability:
                        lookup.availability,
                    purpose: purpose,
                    activity: activity,
                    removalPreview: removal
                ))
            }
            if cancellation.areFutureChildAdmissionsClosed {
                return try LocalClone(
                    repositoryID: clone.repositoryID,
                    sourceSnapshot: clone.sourceSnapshot,
                    effectiveOrigin: clone.effectiveOrigin,
                    originParityVerified:
                        clone.originParityVerified,
                    policyCategory: clone.policyCategory,
                    kind: clone.kind,
                    worktrees: clone.worktrees,
                    branches: enrichedBranches,
                    warnings: clone.warnings + [
                        "Lifecycle inspection was cancelled; fully proven branch evidence remains visible and incomplete candidates remain retained.",
                    ]
                )
            }
            let branchByRef = Dictionary(
                uniqueKeysWithValues: enrichedBranches.map {
                    ($0.fullRef, $0)
                }
            )
            var detachedRelations:
                [String: DefaultBranchRelation] = [:]
            var detachedCommitDates: [String: Date] = [:]
            try validatePhaseCompletion()
            let currentSessionDirectories = CurrentSessionWorktreeDetector.capture(account: account)
            let enrichedWorktrees = try clone.worktrees.map {
                worktree -> Worktree in
                try validatePhaseCompletion()
                let attached = worktree.attachedBranchRef.flatMap {
                    branchByRef[$0]
                }
                let detachedRelation =
                    try worktree.detachedOID.flatMap {
                        detached in
                        if let cached =
                                detachedRelations[detached] {
                            return cached
                        }
                        guard let target =
                                defaultComparisonOID else {
                            return nil
                        }
                        let resolved = try relation(
                            detached,
                            target,
                            handle: handle,
                            frozen: frozen,
                            admission: admission
                        )
                        detachedRelations[detached] = resolved
                        return resolved
                    }
                let detachedIntegrated = detachedRelation.map {
                    $0.aheadCount == 0
                }
                let detachedPurpose = worktree.detachedOID.map { _ in
                    PurposeAssessment(
                        purpose: detachedIntegrated == true
                            ? .integrated : .noKnownPullRequest,
                        exactAssociations: [],
                        allCandidates: [],
                        explanation: detachedIntegrated == true
                            ? "Independent local ancestry proves this detached tip is integrated."
                            : "Detached work has no branch-based pull-request association."
                    )
                }
                let detachedDate =
                    try worktree.detachedOID.flatMap {
                        detached in
                        if let cached =
                                detachedCommitDates[detached] {
                            return cached
                        }
                        let resolved = try commitDate(
                            detached,
                            handle: handle,
                            frozen: frozen,
                            admission: admission
                        )
                        if let resolved {
                            detachedCommitDates[detached] =
                                resolved
                        }
                        return resolved
                    }
                let detachedDateText = detachedDate.map {
                    ISO8601DateFormatter().string(from: $0)
                }
                let purpose = attached?.purpose
                    ?? detachedPurpose
                let activity = attached?.activity
                    ?? ActivityBandOracle.classify(
                        capturedNow: capturedNow,
                        commitDate: detachedDate,
                        associatedPullRequests: []
                    )
                try validatePhaseCompletion()
                let awa = AWAEvidenceReader.read(
                    worktreePath: worktree.path,
                    commonDirectory:
                        handle.identity.commonDirectoryPath,
                    branch: worktree.attachedBranchRef.map {
                        String($0.dropFirst("refs/heads/".count))
                    },
                    location: worktree.locationKind,
                    account: account,
                    capturedNow: capturedNow
                )
                let branchPreserved: Bool?
                if let attached {
                    branchPreserved =
                        attached.relationToDefault?.kind == .equal
                            || attached.relationToDefault?.kind == .behind
                            || (
                                attached.upstream?.fullRef.hasPrefix(
                                    "refs/remotes/origin/"
                                ) == true
                                    && attached.upstream?.upstreamOID
                                        == attached.tipOID
                            )
                } else {
                    branchPreserved = detachedIntegrated
                }
                let currentSession =
                    currentSessionDirectories?.contains {
                        $0 == worktree.path
                            || $0.hasPrefix(
                                worktree.path + "/"
                            )
                    } ?? true
                let removal = RemovalPreviewOracle.worktree(
                    isResolvedDefaultClaim:
                        worktree.attachedBranchRef
                            == resolvedDefault.localRef,
                    policyCategory: clone.policyCategory,
                    verification: worktree.verification,
                    fileState: worktree.fileState,
                    awa: awa,
                    purpose: purpose?.purpose,
                    activity: activity,
                    branchTipPreserved: branchPreserved,
                    currentSession: currentSession,
                    isLocked: worktree.isLocked
                )
                return try Worktree(
                    id: worktree.id,
                    cloneID: worktree.cloneID,
                    path: worktree.path,
                    rootIdentity: worktree.rootIdentity,
                    registrationIdentity:
                        worktree.registrationIdentity,
                    attachedBranchRef:
                        worktree.attachedBranchRef,
                    detachedOID: worktree.detachedOID,
                    isPrimary: worktree.isPrimary,
                    isLocked: worktree.isLocked,
                    locationKind: worktree.locationKind,
                    verification: worktree.verification,
                    cleanliness: worktree.cleanliness,
                    fileState: worktree.fileState,
                    contentEvidenceDigest:
                        worktree.contentEvidenceDigest,
                    relationToDefault:
                        attached?.relationToDefault
                            ?? detachedRelation,
                    tipCommitDate:
                        attached?.commitDate
                            ?? detachedDateText,
                    awaEvidence: awa,
                    purpose: purpose,
                    activity: activity,
                    currentSession: currentSession,
                    removalPreview: removal,
                    warning: worktree.warning
                )
            }
            let enriched = try LocalClone(
                repositoryID: clone.repositoryID,
                sourceSnapshot: clone.sourceSnapshot,
                effectiveOrigin: clone.effectiveOrigin,
                originParityVerified:
                    clone.originParityVerified,
                policyCategory: clone.policyCategory,
                kind: clone.kind,
                worktrees: enrichedWorktrees,
                branches: enrichedBranches,
                warnings: clone.warnings
                    + (
                        pullRequestBatch.issueCount > 0
                            ? [
                                "Cleanup inspection pull-request evidence is incomplete for \(pullRequestBatch.issueCount) candidate\(pullRequestBatch.issueCount == 1 ? "" : "s"); those candidates remain unavailable and retained.",
                            ]
                            : []
                    )
            )
            progressUpdate?(
                .candidateAssembly,
                1,
                1,
                0,
                pullRequestBatch.maximumActiveChildren,
                pullRequestBatch.issueCount,
                Int64(
                    Date().timeIntervalSince(
                        assemblyStarted
                    ) * 1_000
                )
            )
            return enriched
        } catch {
            try validatePhaseCompletion()
            return cloneWithWarning(
                clone,
                "Lifecycle inspection failed: "
                    + Redactor.sanitize(
                        String(describing: error)
                    )
            )
        }
    }

    private struct BulkBranchEvidence: Sendable {
        let tipOID: String
        let relationToDefault: DefaultBranchRelation?
        let integratedIntoDefault: Bool?
        let upstreamRef: String?
        let upstreamOID: String?
        let upstreamRelation: DefaultBranchRelation?
    }

    private struct PullRequestBatchOutcome: Sendable {
        let results: [String: PullRequestLookupResult]
        let incompleteCount: Int
        let maximumActiveChildren: Int

        var issueCount: Int {
            results.values.filter {
                $0.availability == .unavailable
            }.count
        }
    }

    private struct PullRequestBatchRequest: Sendable {
        let id: String
        let name: String
        let tipOID: String
    }

    private final class PullRequestBatchState:
        @unchecked Sendable {
        private let lock = NSLock()
        private let requests: [PullRequestBatchRequest]
        private var nextIndex = 0
        private var active = 0
        private var maximumActive = 0
        private var completed = 0
        private var lastReported = 0
        private var results:
            [String: PullRequestLookupResult] = [:]
        private var childTokens: [UUID: CancellationToken] = [:]
        private var closed = false

        init(requests: [PullRequestBatchRequest]) {
            self.requests = requests
        }

        func take(
            before deadline: Date,
            parent: CancellationToken
        ) -> (
            PullRequestBatchRequest,
            UUID,
            CancellationToken
        )? {
            lock.lock()
            defer { lock.unlock() }
            guard !closed,
                  !parent.areFutureChildAdmissionsClosed,
                  Date() < deadline,
                  nextIndex < requests.count else {
                return nil
            }
            let request = requests[nextIndex]
            nextIndex += 1
            let key = UUID()
            let token = CancellationToken()
            childTokens[key] = token
            active += 1
            maximumActive = max(maximumActive, active)
            return (request, key, token)
        }

        func finish(
            key: UUID,
            request: PullRequestBatchRequest,
            result: PullRequestLookupResult
        ) -> (
            completed: Int,
            total: Int,
            active: Int,
            maximum: Int,
            shouldReport: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            childTokens.removeValue(forKey: key)
            active = max(0, active - 1)
            results[request.id] = result
            completed += 1
            let shouldReport =
                completed == requests.count
                    || completed - lastReported >= 4
            if shouldReport {
                lastReported = completed
            }
            return (
                completed,
                requests.count,
                active,
                maximumActive,
                shouldReport
            )
        }

        func closeAndCancelChildren() {
            lock.lock()
            closed = true
            let tokens = Array(childTokens.values)
            lock.unlock()
            for token in tokens {
                token.cancel()
            }
        }

        func progressSnapshot() -> (
            completed: Int,
            total: Int,
            active: Int,
            maximum: Int
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (
                completed,
                requests.count,
                active,
                maximumActive
            )
        }

        func outcome(
            missingReason: PullRequestUnavailableReason
        ) -> PullRequestBatchOutcome {
            lock.lock()
            defer { lock.unlock() }
            let missing = requests.filter {
                results[$0.id] == nil
            }
            var complete = results
            for request in missing {
                complete[request.id] =
                    .unavailable(missingReason)
            }
            return PullRequestBatchOutcome(
                results: complete,
                incompleteCount: missing.count,
                maximumActiveChildren: maximumActive
            )
        }
    }

    private func bulkBranchEvidence(
        defaultComparisonOID: String?,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> [String: BulkBranchEvidence] {
        let comparison = defaultComparisonOID ?? "HEAD"
        let format =
            "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track,nobracket)%00%(ahead-behind:\(comparison))%00"
        let result = try run(
            Self.localArguments([
                "for-each-ref",
                format,
                "refs/heads/",
                "refs/remotes/",
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 10
        )
        guard result.succeeded,
              !result.stdoutTruncated,
              !result.stderrTruncated else {
            throw GitSafetyError.commandFailed(
                "git for-each-ref",
                result.status,
                result.diagnostic
            )
        }
        var rows: [[String]] = []
        for line in result.stdout.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        ) {
            var fields = line.split(
                separator: 0,
                omittingEmptySubsequences: false
            ).map { String(decoding: $0, as: UTF8.self) }
            while fields.last?.isEmpty == true {
                fields.removeLast()
            }
            guard fields.count == 5,
                  !fields[0].isEmpty,
                  Self.validCommitOID(fields[1]) else {
                throw GitSafetyError.unsafeRepository(
                    "bulk branch relation output is malformed"
                )
            }
            rows.append(fields)
        }
        let objectIDs = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0[0], $0[1].lowercased())
            }
        )
        var evidence: [String: BulkBranchEvidence] = [:]
        for fields in rows
            where GitReferenceSyntax.isValidLocalBranchRef(fields[0]) {
            let upstreamRef =
                fields[2].isEmpty ? nil : fields[2]
            let upstreamOID = upstreamRef.flatMap {
                objectIDs[$0]
            }
            let defaultRelation = defaultComparisonOID.flatMap {
                _ in Self.parseAheadBehind(fields[4])
            }
            let upstreamRelation = upstreamRef.flatMap { _ in
                Self.parseTrackingRelation(
                    fields[3],
                    upstreamOID: upstreamOID
                )
            }
            evidence[fields[0]] = BulkBranchEvidence(
                tipOID: fields[1].lowercased(),
                relationToDefault: defaultRelation,
                integratedIntoDefault:
                    defaultRelation.map { $0.aheadCount == 0 },
                upstreamRef: upstreamRef,
                upstreamOID: upstreamOID,
                upstreamRelation: upstreamRelation
            )
        }
        return evidence
    }

    private func lookupPullRequests(
        repositoryID: String,
        branches: [Branch],
        progressUpdate: (@Sendable (
            CleanupInspectionStage,
            Int,
            Int,
            Int,
            Int,
            Int,
            Int64
        ) -> Void)?
    ) -> PullRequestBatchOutcome {
        let requests = branches.compactMap {
            branch -> PullRequestBatchRequest? in
            guard let tipOID = branch.tipOID else { return nil }
            return PullRequestBatchRequest(
                id: branch.id,
                name: branch.name,
                tipOID: tipOID
            )
        }
        guard !requests.isEmpty else {
            progressUpdate?(
                .pullRequestEvidence, 0, 0, 0, 0, 0, 0
            )
            return PullRequestBatchOutcome(
                results: [:],
                incompleteCount: 0,
                maximumActiveChildren: 0
            )
        }
        let workerCount = min(4, requests.count)
        let budget = Self.pullRequestStageBudget(
            candidateCount: requests.count,
            workerCount: workerCount
        )
        let deadline = Date().addingTimeInterval(budget)
        let state = PullRequestBatchState(requests: requests)
        let group = DispatchGroup()
        let stageStarted = Date()
        progressUpdate?(
            .pullRequestEvidence,
            0,
            requests.count,
            0,
            0,
            0,
            0
        )
        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(
                qos: .userInitiated
            ).async { [pullRequestLookup, cancellation] in
                defer { group.leave() }
                while let (
                    request,
                    key,
                    childCancellation
                ) = state.take(
                    before: deadline,
                    parent: cancellation
                ) {
                    let result = pullRequestLookup.lookup(
                        repositoryID: repositoryID,
                        branch: request.name,
                        tipOID: request.tipOID,
                        cancellation: childCancellation
                    )
                    let snapshot = state.finish(
                        key: key,
                        request: request,
                        result: result
                    )
                    if snapshot.shouldReport {
                        progressUpdate?(
                            .pullRequestEvidence,
                            snapshot.completed,
                            snapshot.total,
                            snapshot.active,
                            snapshot.maximum,
                            0,
                            Int64(
                                Date().timeIntervalSince(
                                    stageStarted
                                ) * 1_000
                            )
                        )
                    }
                }
            }
        }
        var deadlineReached = false
        var lastHeartbeatSecond = 0
        while group.wait(
            timeout: .now() + .milliseconds(100)
        ) == .timedOut {
            let elapsed = Date().timeIntervalSince(
                stageStarted
            )
            let heartbeatSecond = Int(elapsed)
            if heartbeatSecond > lastHeartbeatSecond {
                lastHeartbeatSecond = heartbeatSecond
                let snapshot = state.progressSnapshot()
                progressUpdate?(
                    .pullRequestEvidence,
                    snapshot.completed,
                    snapshot.total,
                    snapshot.active,
                    snapshot.maximum,
                    0,
                    Int64(elapsed * 1_000)
                )
            }
            if cancellation.areFutureChildAdmissionsClosed
                || Date() >= deadline {
                deadlineReached = Date() >= deadline
                state.closeAndCancelChildren()
                break
            }
        }
        group.wait()
        let reason: PullRequestUnavailableReason =
            cancellation.areFutureChildAdmissionsClosed
                ? .cancelled
                : (deadlineReached ? .timeout : .cancelled)
        let outcome = state.outcome(missingReason: reason)
        progressUpdate?(
            .pullRequestEvidence,
            requests.count - outcome.incompleteCount,
            requests.count,
            0,
            outcome.maximumActiveChildren,
            outcome.issueCount,
            Int64(
                Date().timeIntervalSince(
                    stageStarted
                ) * 1_000
            )
        )
        return outcome
    }

    static func pullRequestStageBudget(
        candidateCount: Int,
        workerCount: Int = 4
    ) -> TimeInterval {
        guard candidateCount > 0 else { return 0 }
        let admittedWorkers =
            min(4, max(1, workerCount))
        let waves =
            (candidateCount + admittedWorkers - 1)
                / admittedWorkers
        return min(
            60.0,
            max(15.0, 10.0 + Double(waves * 2))
        )
    }

    private static func validCommitOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    private static func parseAheadBehind(
        _ value: String
    ) -> DefaultBranchRelation? {
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let ahead = Int(fields[0]),
              let behind = Int(fields[1]),
              ahead >= 0,
              behind >= 0 else {
            return nil
        }
        return relation(ahead: ahead, behind: behind)
    }

    private static func parseTrackingRelation(
        _ value: String,
        upstreamOID: String?
    ) -> DefaultBranchRelation? {
        guard upstreamOID != nil else { return nil }
        if value.isEmpty {
            return relation(ahead: 0, behind: 0)
        }
        guard value != "gone" else { return nil }
        var ahead = 0
        var behind = 0
        for component in value.split(separator: ",") {
            let fields = component
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ")
            guard fields.count == 2,
                  let count = Int(fields[1]),
                  count >= 0 else {
                return nil
            }
            if fields[0] == "ahead" {
                ahead = count
            } else if fields[0] == "behind" {
                behind = count
            } else {
                return nil
            }
        }
        return relation(ahead: ahead, behind: behind)
    }

    private static func relation(
        ahead: Int,
        behind: Int
    ) -> DefaultBranchRelation {
        let kind: DefaultBranchRelationKind
        if ahead == 0, behind == 0 {
            kind = .equal
        } else if ahead == 0 {
            kind = .behind
        } else if behind == 0 {
            kind = .ahead
        } else {
            kind = .diverged
        }
        return DefaultBranchRelation(
            kind: kind,
            aheadCount: ahead,
            behindCount: behind
        )
    }

    private func cloneWithWarning(
        _ clone: LocalClone,
        _ warning: String
    ) -> LocalClone {
        (
            try? LocalClone(
                repositoryID: clone.repositoryID,
                sourceSnapshot: clone.sourceSnapshot,
                effectiveOrigin: clone.effectiveOrigin,
                originParityVerified: clone.originParityVerified,
                policyCategory: clone.policyCategory,
                kind: clone.kind,
                worktrees: clone.worktrees,
                branches: clone.branches,
                warnings: clone.warnings + [warning]
            )
        ) ?? clone
    }

    private func replacing(
        _ clone: LocalClone,
        worktrees: [Worktree],
        branches: [Branch],
        warnings: [String]? = nil
    ) -> LocalClone {
        (
            try? LocalClone(
                repositoryID: clone.repositoryID,
                sourceSnapshot: clone.sourceSnapshot,
                effectiveOrigin: clone.effectiveOrigin,
                originParityVerified:
                    clone.originParityVerified,
                policyCategory: clone.policyCategory,
                kind: clone.kind,
                worktrees: worktrees,
                branches: branches,
                warnings: warnings ?? clone.warnings
            )
        ) ?? clone
    }

    func maintenanceOperations(
        clone: LocalClone,
        remote: RemoteRepository,
        capability: VerifiedRepositoryAuthorityCapability?
    ) throws -> (
        operations: [PlannedOperation],
        refusals: [String],
        diagnostics: [String]
    ) {
        try validatePhaseCompletion()
        guard clone.policyCategory == .writable,
              clone.isAuthorityEligible,
              let resolvedDefault = remote.resolvedDefault else {
            return ([], [], [])
        }
        do {
            let handle = try RepositoryHandle.open(
                clone.sourceSnapshot
            )
            let frozen = try freeze(handle)
            let admission = try transportAdmission(
                handle: handle,
                frozen: frozen
            )
            let previewLock =
                try handle.probeCommonDirectoryOperationLock(
                    account: account
                )
            defer { withExtendedLifetime(previewLock) {} }
            let draft = try RepositoryMaintenancePlanner.inspect(
                clone: clone,
                remote: remote,
                account: account,
                handle: handle,
                frozen: frozen,
                admission: admission,
                capturedNow: capturedNow,
                validateAdmission: validatePhaseCompletion
            ) { [self] arguments, target, configuration, transport, timeout in
                try run(
                    arguments,
                    handle: target,
                    frozen: configuration,
                    admission: transport,
                    timeout: timeout
                )
            }
            let localDefault = clone.branches.first {
                $0.fullRef == resolvedDefault.localRef
            }
            let metadataTarget = try DefaultBranchUpdateTarget(
                repository: remote,
                canonicalClone: clone,
                resolvedDefault: resolvedDefault,
                expectedLocalOID: localDefault?.tipOID,
                expectedFetchedOID:
                    resolvedDefault.advertisedOID,
                mode: .metadataMaintenance,
                worktreeID: nil,
                relation: .unavailable
            )
            var operations: [PlannedOperation] = []
            var refusals = draft.refusals
            var diagnostics = draft.diagnostics
            if !draft.prunable.isEmpty {
                operations.append(try makeMaintenanceOperation(
                    kind: .repairPruneRegistrations,
                    target: metadataTarget,
                    maintenanceEvidence:
                        .prune(draft.prunable),
                    capability: capability
                ))
            }
            for moved in draft.moved {
                try validatePhaseCompletion()
                do {
                    try verifyMovedCandidate(
                        moved,
                        clone: clone,
                        frozen: frozen,
                        admission: admission
                    )
                    operations.append(try makeMaintenanceOperation(
                        kind: .repairMovedWorktree,
                        target: metadataTarget,
                        maintenanceEvidence:
                            .repairMoved(moved),
                        capability: capability
                    ))
                } catch {
            try validatePhaseCompletion()
                    refusals.append(
                        "Moved-worktree Repair is unavailable because cleanliness, identity, activity, or branch-tip evidence changed."
                    )
                    diagnostics.append(
                        "Moved-worktree Repair evidence changed during read-only verification."
                    )
                }
            }
            if localDefault?.tipOID == nil {
                let claims = localDefault?
                    .claimingWorktreeIDs ?? []
                let completeClaims = clone.worktrees.allSatisfy {
                    $0.verification == .verified
                        && $0.fileState?.operationState
                            == .clear
                }
                let namespaceAvailable = !clone.branches.contains {
                    $0.fullRef.hasPrefix(
                        resolvedDefault.localRef + "/"
                    ) || resolvedDefault.localRef.hasPrefix(
                        $0.fullRef + "/"
                    )
                }
                if claims.isEmpty,
                   completeClaims,
                   namespaceAvailable {
                    let target = try DefaultBranchUpdateTarget(
                        repository: remote,
                        canonicalClone: clone,
                        resolvedDefault: resolvedDefault,
                        expectedLocalOID: nil,
                        expectedFetchedOID:
                            resolvedDefault.advertisedOID,
                        mode: .initializeAbsent,
                        worktreeID: nil,
                        relation: .unavailable
                    )
                    operations.append(try makeMaintenanceOperation(
                        kind: .initializeDefaultBranch,
                        target: target,
                        maintenanceEvidence:
                            .initializeDefault,
                        capability: capability
                    ))
                } else {
                    refusals.append(
                        "Initialize is unavailable because the absent default has a claim or topology evidence is incomplete."
                    )
                }
            }
            return (
                operations,
                refusals,
                diagnostics
            )
        } catch {
            try validatePhaseCompletion()
            return (
                [],
                [
                    "Repair and Initialize are unavailable because operation admission could not be verified.",
                ],
                [
                    "Operation admission could not verify Repair or Initialize evidence.",
                ]
            )
        }
    }

    private func makeMaintenanceOperation(
        kind: PlannedOperationKind,
        target: DefaultBranchUpdateTarget,
        maintenanceEvidence: RepositoryMaintenanceEvidence,
        capability: VerifiedRepositoryAuthorityCapability?
    ) throws -> PlannedOperation {
        if let capability {
            return try PlannedOperation(
                kind: kind,
                target: target,
                maintenanceEvidence: maintenanceEvidence,
                capability: capability
            )
        }
        #if SHADOW_SYNC_TESTING
        return try PlannedOperation(
            kind: kind,
            target: target,
            maintenanceEvidence: maintenanceEvidence
        )
        #else
        throw GitSafetyError.unsafeRepository(
            "maintenance construction lacks verified selected authority"
        )
        #endif
    }

    func originHeadExplanation(
        clone: LocalClone,
        remote: RemoteRepository
    ) throws -> String? {
        try validatePhaseCompletion()
        guard let resolvedDefault = remote.resolvedDefault else {
            return nil
        }
        do {
            let handle = try RepositoryHandle.open(
                clone.sourceSnapshot
            )
            let frozen = try freeze(handle)
            let admission = try transportAdmission(
                handle: handle,
                frozen: frozen
            )
            let result = try run(
                Self.localArguments([
                    "symbolic-ref", "--quiet",
                    "refs/remotes/origin/HEAD",
                ]),
                handle: handle,
                frozen: frozen,
                admission: admission,
                timeout: 5
            )
            if result.status == 1 {
                return
                    "Local origin/HEAD is missing. The live remote HEAD remains authoritative; no repair is needed."
            }
            guard result.succeeded,
                  !result.stdoutTruncated,
                  let value = String(
                      data: result.stdout,
                      encoding: .utf8
                  )?.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ) else {
                return
                    "Local origin/HEAD could not be read. The live remote HEAD remains authoritative; no repair is needed."
            }
            if value != resolvedDefault.remoteTrackingRef {
                return
                    "Local origin/HEAD is stale. The live remote HEAD remains authoritative; no repair is needed."
            }
            return nil
        } catch {
            try validatePhaseCompletion()
            return
                "Local origin/HEAD is unavailable. The live remote HEAD remains authoritative; no repair is needed."
        }
    }

    private func verifyMovedCandidate(
        _ evidence: MovedWorktreeEvidence,
        clone: LocalClone,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws {
        try validatePhaseCompletion()
        let moved = try RepositoryHandle.openMovedWorktree(
            clone.sourceSnapshot,
            evidence: evidence
        )
        try moved.rejectBusyState(
            defaultBranch: String(
                evidence.branchRef.dropFirst(
                    "refs/heads/".count
                )
            )
        )
        let status = try run(
            Self.localArguments([
                "status", "--porcelain=v1", "-z",
                "--untracked-files=all",
            ]),
            handle: moved,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        let index = try run(
            Self.localArguments(["ls-files", "-v", "-z"]),
            handle: moved,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        let branch = try run(
            Self.localArguments([
                "symbolic-ref", "--quiet", "--short", "HEAD",
            ]),
            handle: moved,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        let oid = try optionalCommit(
            evidence.branchRef,
            handle: moved,
            frozen: frozen,
            admission: admission
        )
        guard status.succeeded,
              status.stdout.isEmpty,
              !status.stdoutTruncated,
              index.succeeded,
              !index.stdoutTruncated,
              (try? GitIndexVisibility.validate(
                  index.stdout
              )) != nil,
              branch.succeeded,
              String(
                  data: branch.stdout,
                  encoding: .utf8
              )?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ) == String(
                  evidence.branchRef.dropFirst(
                      "refs/heads/".count
                  )
              ),
              oid == evidence.branchOID else {
            throw GitSafetyError.unsafeRepository(
                "moved worktree candidate changed"
            )
        }
    }

    func resolveRemoteDefault(
        _ candidate: RepositoryCandidate
    ) throws -> RemoteDefaultBranch {
        try validatePhaseCompletion()
        let handle = try RepositoryHandle.open(candidate)
        let frozen = try freeze(handle)
        let admission = try transportAdmission(
            handle: handle,
            frozen: frozen
        )
        let first = try remoteDefault(
            handle: handle,
            frozen: frozen,
            admission: admission
        )
        let second = try remoteDefault(
            handle: handle,
            frozen: frozen,
            admission: admission
        )
        guard first.name == second.name else {
            throw RemoteDefaultResolutionError.changed
        }
        return second
    }

    func cachedExactRelation(
        candidate: RepositoryCandidate,
        localOID: String,
        remote: RemoteDefaultBranch
    ) throws -> DefaultBranchRelation {
        try validatePhaseCompletion()
        let handle = try RepositoryHandle.open(candidate)
        let frozen = try freeze(handle)
        let admission = try transportAdmission(
            handle: handle,
            frozen: frozen
        )
        let tracking = try optionalCommit(
            remote.remoteTrackingRef,
            handle: handle,
            frozen: frozen,
            admission: admission
        )
        return try Self.classifyCachedRelation(
            trackingOID: tracking,
            advertisedOID: remote.advertisedOID
        ) {
            try relation(
                localOID,
                remote.advertisedOID,
                handle: handle,
                frozen: frozen,
                admission: admission
            )
        }
    }

    static func classifyCachedRelation(
        trackingOID: String?,
        advertisedOID: String,
        exactRelation: () throws -> DefaultBranchRelation
    ) rethrows -> DefaultBranchRelation {
        guard let trackingOID else {
            return .unavailable
        }
        guard trackingOID == advertisedOID else {
            return .remoteChangedSinceLastFetch
        }
        return try exactRelation()
    }

    func updateRefHookSHA256(
        _ candidate: RepositoryCandidate
    ) throws -> String? {
        try validatePhaseCompletion()
        let handle = try RepositoryHandle.open(candidate)
        let frozen = try freeze(handle)
        guard let hooksDirectory =
                frozen.effectiveHooksDirectory else {
            return nil
        }
        return OperationHookEvidence.updateRefSHA256(
            hooksDirectory: hooksDirectory,
            account: account
        )
    }

    func refOnlyPreservation(
        _ clone: LocalClone
    ) throws -> RefOnlyPreservationSnapshot {
        try validatePhaseCompletion()
        return try RefOnlyPreservationSnapshot.capture(
            clone: clone,
            account: account,
            cancellation: cancellation
        )
    }

    private func freeze(_ handle: RepositoryHandle)
        throws -> FrozenGitConfiguration {
        try validatePhaseCompletion()
        #if SHADOW_SYNC_TESTING
        let additional = transportMapping.flatMap {
            $0.logicalURL == handle.rawOrigin ? $0.gitConfigText : nil
        }
        #else
        let additional: String? = nil
        #endif
        if let configurationProbe {
            return try handle.freezeConfiguration(account: account,
                configurationProbe: configurationProbe, additionalConfiguration: additional)
        }
        #if SHADOW_SYNC_TESTING
        return try handle.freezeConfiguration(account: account, additionalConfiguration: additional)
        #else
        throw SystemGitConfigurationError.unavailable
        #endif
    }

    private func transportAdmission(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration
    ) throws -> GitAdmissionSnapshot {
        let first = try effectiveTransport(
            handle: handle,
            frozen: frozen
        )
        let second = try effectiveTransport(
            handle: handle,
            frozen: frozen
        )
        guard first.url == second.url, first.transport == second.transport else {
            throw GitSafetyError.originChanged
        }
        #if SHADOW_SYNC_TESTING
        return GitAdmissionSnapshot(
            effectiveURL: second.url,
            transport: second.transport,
            frozenConfigSHA256: frozen.snapshot.frozenSHA256,
            mappedTestURL: transportMapping?.effectiveURL
        )
        #else
        return GitAdmissionSnapshot(
            effectiveURL: second.url,
            transport: second.transport,
            frozenConfigSHA256: frozen.snapshot.frozenSHA256
        )
        #endif
    }

    private func effectiveTransport(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration
    ) throws -> (url: String, transport: GitTransport) {
        let result = try run(
            Self.localArguments(["remote", "get-url", "--all", "origin"]),
            handle: handle,
            frozen: frozen,
            admission: nil,
            timeout: 5
        )
        guard result.succeeded,
              !result.stdoutTruncated,
              let line = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              !line.contains("\n") else {
            throw GitSafetyError.originChanged
        }
        var identityURL = line
        #if SHADOW_SYNC_TESTING
        if line == transportMapping?.effectiveURL {
            identityURL = transportMapping!.logicalURL
        }
        #endif
        guard let identity = GitHubIdentity.parse(identityURL),
              identity.canonicalName == handle.githubIdentity.canonicalName else {
            throw GitSafetyError.originChanged
        }
        let configuration = try run(
            Self.localArguments(
                EffectiveTransportConfiguration.queryArguments
            ),
            handle: handle,
            frozen: frozen,
            admission: nil,
            timeout: 5
        )
        try EffectiveTransportConfiguration.validate(
            status: configuration.status,
            output: configuration.stdout,
            transport: identity.transport,
            operation: "git config effective transport",
            diagnostic: configuration.diagnostic
        )
        return (identityURL, identity.transport)
    }

    private func remoteDefault(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> RemoteDefaultBranch {
        let result = try run(
            ["--no-replace-objects", "ls-remote", "--symref", "origin", "HEAD"],
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 30
        )
        guard result.succeeded, !result.stdoutTruncated else {
            if result.status == 0 {
                throw RemoteDefaultResolutionError.malformed
            }
            throw RemoteDefaultResolutionError.missing
        }
        return try RemoteDefaultResolver.parse(result.stdout)
    }

    private struct Topology {
        let worktrees: [Worktree]
        let branches: [Branch]
    }

    private struct WorktreeRecord {
        let path: String
        let head: String?
        let branch: String?
        let isLocked: Bool
    }

    private func topology(
        candidate: RepositoryCandidate,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        inspectAllWorktreeState: Bool
    ) throws -> Topology {
        let result = try run(
            Self.localArguments(["worktree", "list", "--porcelain", "-z"]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        guard result.succeeded, !result.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git worktree list",
                result.status,
                result.diagnostic
            )
        }
        let records = try Self.parseWorktrees(result.stdout)
        guard let common = candidate.commonDirectoryIdentity else {
            throw GitSafetyError.unsafeRepository(
                "common-directory identity is missing"
            )
        }
        let cloneID = LocalClone.id(for: common)
        var worktrees: [Worktree] = []
        for record in records {
            try validatePhaseCompletion()
            guard !cancellation
                    .areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            let provisional: Worktree
            do {
                let claim = try handle.verifyWorktreeClaim(
                    path: record.path
                )
                let id =
                    "worktree:\(cloneID):\(claim.rootIdentity.device):\(claim.rootIdentity.inode)"
                let registration = candidate.linkedWorktrees.first {
                    $0.rootIdentity == claim.rootIdentity
                }
                provisional = try Worktree(
                    id: id,
                    cloneID: cloneID,
                    path: claim.canonicalPath,
                    rootIdentity: claim.rootIdentity,
                    registrationIdentity:
                        registration?.registrationDirectoryIdentity,
                    attachedBranchRef: record.branch,
                    detachedOID:
                        record.branch == nil ? record.head : nil,
                    isPrimary: claim.isPrimary,
                    isLocked: record.isLocked,
                    locationKind: Self.locationKind(
                        record.path,
                        primary: candidate.path,
                        account: account
                    ),
                    verification: .verified,
                    warning: claim.isPrimary
                        ? nil
                        : Self.locationWarning(
                            record.path,
                            account: account
                        )
                )
            } catch {
            try validatePhaseCompletion()
                provisional = try Worktree(
                    id: "worktree:\(cloneID):unavailable:"
                        + V2EvidenceDigest.make([
                            cloneID, record.path,
                        ]),
                    cloneID: cloneID,
                    path: record.path,
                    rootIdentity: nil,
                    registrationIdentity: nil,
                    attachedBranchRef: record.branch,
                    detachedOID:
                        record.branch == nil ? record.head : nil,
                    isPrimary: record.path == candidate.path,
                    isLocked: record.isLocked,
                    locationKind: Self.locationKind(
                        record.path,
                        primary: candidate.path,
                        account: account
                    ),
                    verification: .unavailable,
                    cleanliness: .unknown,
                    warning:
                        "This worktree association could not be verified; its branch claim is treated as unknown."
                )
            }
            let state = provisional.verification == .verified
                && (
                    inspectAllWorktreeState
                        || provisional.isPrimary
                )
                ? try worktreeState(
                    candidate: candidate,
                    worktree: provisional,
                    frozen: frozen,
                    admission: admission,
                    includeRemovalEvidence:
                        inspectAllWorktreeState
                )
                : (
                    cleanliness: WorktreeCleanliness.unknown,
                    fileState: WorktreeFileState?.none,
                    contentEvidenceDigest: String?.none,
                    warning: String?.none
                )
            let warning = [provisional.warning, state.warning]
                .compactMap { $0 }
                .joined(separator: " ")
            worktrees.append(try Worktree(
                id: provisional.id,
                cloneID: provisional.cloneID,
                path: provisional.path,
                rootIdentity: provisional.rootIdentity,
                registrationIdentity:
                    provisional.registrationIdentity,
                attachedBranchRef:
                    provisional.attachedBranchRef,
                detachedOID: provisional.detachedOID,
                isPrimary: provisional.isPrimary,
                isLocked: provisional.isLocked,
                locationKind: provisional.locationKind,
                verification: provisional.verification,
                cleanliness: state.cleanliness,
                fileState: state.fileState,
                contentEvidenceDigest:
                    state.contentEvidenceDigest,
                warning: warning.isEmpty ? nil : warning
            ))
        }
        let branchResult = try run(
            Self.localArguments([
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(upstream)%00%(committerdate:iso-strict)%00",
                "refs/heads/",
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        guard branchResult.succeeded,
              !branchResult.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git for-each-ref",
                branchResult.status,
                branchResult.diagnostic
            )
        }
        var branches: [Branch] = []
        var branchFields = try branchResult.stdout.split(
            separator: 0,
            omittingEmptySubsequences: false
        ).map { field -> String in
            guard let value = String(data: field, encoding: .utf8) else {
                throw GitSafetyError.unsafeRepository(
                    "branch inventory output is malformed"
                )
            }
            return value.trimmingCharacters(in: .newlines)
        }
        while branchFields.last?.isEmpty == true {
            branchFields.removeLast()
        }
        guard branchFields.count.isMultiple(of: 4) else {
            throw GitSafetyError.unsafeRepository(
                "branch inventory output is malformed"
            )
        }
        for index in stride(from: 0, to: branchFields.count, by: 4) {
            let reference = branchFields[index]
            let oid = branchFields[index + 1]
            let upstreamRef = branchFields[index + 2]
            let commitDate = branchFields[index + 3]
            let claims = worktrees.filter {
                $0.attachedBranchRef == reference
            }.map(\.id)
            branches.append(try Branch(
                cloneID: cloneID,
                fullRef: reference,
                tipOID: oid,
                claimingWorktreeIDs: claims,
                upstream: upstreamRef.isEmpty ? nil : BranchUpstream(
                    fullRef: upstreamRef,
                    localOID: oid,
                    upstreamOID: nil,
                    relation: .unavailable,
                    aheadCount: nil,
                    behindCount: nil
                ),
                commitDate: commitDate.isEmpty ? nil : commitDate
            ))
        }
        let knownRefs = Set(branches.map(\.fullRef))
        for missing in Set(
            worktrees.compactMap(\.attachedBranchRef)
        ).subtracting(knownRefs).sorted() {
            branches.append(try Branch(
                cloneID: cloneID,
                fullRef: missing,
                tipOID: nil,
                claimingWorktreeIDs: worktrees.filter {
                    $0.attachedBranchRef == missing
                }.map(\.id)
            ))
        }
        return Topology(worktrees: worktrees, branches: branches)
    }

    #if SHADOW_SYNC_TESTING
    func testingWorktreePhaseRefusal(candidate: RepositoryCandidate, worktree: Worktree,
        frozen: FrozenGitConfiguration, admission: GitAdmissionSnapshot) throws -> WorktreeCleanliness {
        try worktreeState(candidate: candidate, worktree: worktree, frozen: frozen,
            admission: admission, includeRemovalEvidence: true).cleanliness
    }
    #endif

    private func worktreeState(
        candidate: RepositoryCandidate,
        worktree: Worktree,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        includeRemovalEvidence: Bool
    ) throws -> (
        cleanliness: WorktreeCleanliness,
        fileState: WorktreeFileState?,
        contentEvidenceDigest: String?,
        warning: String?
    ) {
        try validatePhaseCompletion()
        do {
            let target = try RepositoryHandle.open(
                candidate,
                targetWorktree: worktree
            )
            let status = try run(
                Self.localArguments([
                    "status", "--porcelain=v1", "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                ]),
                handle: target,
                frozen: frozen,
                admission: admission,
                timeout: 5
            )
            guard !cancellation
                    .areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            guard status.succeeded,
                  !status.stdoutTruncated else {
                return (
                    .unknown,
                    nil,
                    nil,
                    Self.inspectionFailure(
                        check: "git status",
                        result: status,
                        timeout: 5
                    )
                )
            }
            let index = try run(
                Self.localArguments([
                    "ls-files", "--stage", "-v", "-z",
                ]),
                handle: target,
                frozen: frozen,
                admission: admission,
                timeout: 5
            )
            guard !cancellation
                    .areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            guard index.succeeded,
                  !index.stdoutTruncated else {
                return (
                    .unknown,
                    nil,
                    nil,
                    Self.inspectionFailure(
                        check: "git index visibility",
                        result: index,
                        timeout: 5
                    )
                )
            }
            let hiddenIndexState: Bool
            do {
                try GitIndexVisibility.validate(index.stdout)
                hiddenIndexState = false
            } catch {
            try validatePhaseCompletion()
                hiddenIndexState = true
            }
            let counts = try Self.statusCounts(status.stdout)
            try validatePhaseCompletion()
            let filesystemDigest = includeRemovalEvidence
                ? try RemovalContentEvidence
                    .filesystemDigest(
                        rootDescriptor:
                            target.worktreeDescriptor,
                        cancellation: cancellation
                    )
                : nil
            try validatePhaseCompletion()
            let operationState: WorktreeOperationState
            do {
                try target.rejectBusyState(
                    defaultBranch: worktree.attachedBranchRef.map {
                        String($0.dropFirst("refs/heads/".count))
                    } ?? "main"
                )
                operationState = .clear
            } catch GitSafetyError.busy {
                try validatePhaseCompletion()
                operationState = .busy
            } catch {
            try validatePhaseCompletion()
                operationState = .unavailable
            }
            let fileState = WorktreeFileState(
                trackedChanges: counts.tracked,
                untrackedFiles: counts.untracked,
                ignoredFiles: counts.ignored,
                hiddenIndexState: hiddenIndexState,
                operationState: operationState
            )
            let cleanliness: WorktreeCleanliness =
                counts.tracked == 0 && counts.untracked == 0
                    && !hiddenIndexState
                    && operationState == .clear
                    ? .clean : .dirty
            return (
                cleanliness,
                fileState,
                filesystemDigest.map {
                    RemovalContentEvidence.make(
                        status: status.stdout,
                        index: index.stdout,
                        filesystemDigest: $0
                    )
                },
                cleanliness == .clean
                    ? nil
                    : (hiddenIndexState
                        ? "Hidden index state affects this worktree only."
                        : "Local changes or operation state affects this worktree only.")
            )
        } catch {
            try validatePhaseCompletion()
            return (
                .unknown,
                nil,
                nil,
                "Target worktree inspection failed: "
                    + Redactor.sanitize(
                        String(describing: error)
                    )
            )
        }
    }

    private static func inspectionFailure(
        check: String,
        result: ProcessResult,
        timeout: Int
    ) -> String {
        if result.cancelled {
            return "\(check) was cancelled."
        }
        if result.timedOut {
            return "\(check) timed out after \(timeout) seconds."
        }
        if result.stdoutTruncated || result.stderrTruncated {
            return "\(check) output exceeded the safe inspection limit."
        }
        return "\(check) exited with status \(result.status)."
    }

    private static func statusCounts(
        _ data: Data
    ) throws -> (tracked: Int, untracked: Int, ignored: Int) {
        let records = data.split(
            separator: 0,
            omittingEmptySubsequences: true
        )
        var tracked = 0
        var untracked = 0
        var ignored = 0
        var skipRenameTarget = false
        for record in records {
            if skipRenameTarget {
                skipRenameTarget = false
                continue
            }
            guard record.count >= 3,
                  record[record.index(
                      record.startIndex,
                      offsetBy: 2
                  )] == Character(" ").asciiValue else {
                throw GitSafetyError.unsafeRepository(
                    "worktree status output is malformed"
                )
            }
            let first = record[record.startIndex]
            let second = record[
                record.index(after: record.startIndex)
            ]
            if first == Character("?").asciiValue,
               second == Character("?").asciiValue {
                untracked += 1
            } else if first == Character("!").asciiValue,
                      second == Character("!").asciiValue {
                ignored += 1
            } else {
                tracked += 1
                skipRenameTarget =
                    first == Character("R").asciiValue
                    || first == Character("C").asciiValue
                    || second == Character("R").asciiValue
                    || second == Character("C").asciiValue
            }
        }
        return (tracked, untracked, ignored)
    }

    private func optionalCommit(
        _ reference: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> String? {
        let result = try run(
            Self.localArguments([
                "rev-parse", "--verify", "--quiet", "\(reference)^{commit}",
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        if result.status == 1 {
            return nil
        }
        guard result.succeeded,
              !result.stdoutTruncated,
              let oid = Self.objectID(result.stdout) else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                result.status,
                result.diagnostic
            )
        }
        return oid
    }

    private func relation(
        _ local: String,
        _ remote: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> DefaultBranchRelation {
        let result = try run(
            Self.localArguments([
                "rev-list", "--left-right", "--count", "\(local)...\(remote)",
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        guard result.succeeded,
              !result.stdoutTruncated,
              let output = String(
                  data: result.stdout,
                  encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw GitSafetyError.commandFailed(
                "git rev-list",
                result.status,
                result.diagnostic
            )
        }
        let counts = output.split { $0.isWhitespace }
        guard counts.count == 2,
              let ahead = Int(counts[0]),
              let behind = Int(counts[1]),
              ahead >= 0,
              behind >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "Git relation output is malformed"
            )
        }
        let kind: DefaultBranchRelationKind
        if ahead == 0, behind == 0 {
            kind = .equal
        } else if ahead == 0 {
            kind = .behind
        } else if behind == 0 {
            kind = .ahead
        } else {
            kind = .diverged
        }
        return DefaultBranchRelation(
            kind: kind,
            aheadCount: ahead,
            behindCount: behind
        )
    }

    private func isAncestor(
        _ ancestor: String,
        _ descendant: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> Bool {
        let result = try run(
            Self.localArguments([
                "merge-base", "--is-ancestor",
                ancestor, descendant,
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        if result.status == 1 {
            return false
        }
        guard result.succeeded,
              !result.stdoutTruncated,
              result.stdout.isEmpty else {
            throw GitSafetyError.commandFailed(
                "git merge-base",
                result.status,
                result.diagnostic
            )
        }
        return true
    }

    private func commitDate(
        _ oid: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> Date? {
        let result = try run(
            Self.localArguments([
                "show", "-s", "--format=%cI", oid,
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            timeout: 5
        )
        guard result.succeeded,
              !result.stdoutTruncated,
              let value = String(
                  data: result.stdout,
                  encoding: .utf8
              )?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ) else {
            return nil
        }
        return PullRequestRecord.parseTimestamp(value)
    }

    private static func upstreamKind(
        _ value: DefaultBranchRelationKind?
    ) -> UpstreamRelationKind {
        switch value {
        case .equal: return .equal
        case .ahead: return .ahead
        case .behind: return .behind
        case .diverged: return .diverged
        case .unavailable, .none: return .unavailable
        }
    }

    private func run(
        _ arguments: [String],
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try validatePhaseCompletion()
        var admitted = arguments
        #if SHADOW_SYNC_TESTING
        if transportMapping != nil {
            admitted = ["-c", GitCommandPolicy.testRootMarker] + arguments
        }
        #endif
        let snapshot: RepositoryExecutionSnapshot
        if let configurationProbe {
            snapshot = try handle.executionSnapshot(account: account, frozenConfiguration: frozen,
                admission: admission, configurationProbe: configurationProbe)
        } else {
            #if SHADOW_SYNC_TESTING
            snapshot = try handle.executionSnapshot(account: account, frozenConfiguration: frozen, admission: admission)
            #else
            throw SystemGitConfigurationError.unavailable
            #endif
        }
        let environment = ClosedGitEnvironment.make(
            account: account,
            transport: admission?.transport
                ?? handle.githubIdentity.transport,
            frozenConfigPath: frozen.snapshot.frozenPath
        )
        progress?.prepare(phase: Self.inventoryPhase(arguments))
        let result = try runner.run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: admitted,
                environment: environment,
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: leaseDescriptor,
                frozenConfigDescriptor: frozen.descriptor,
                frozenConfigDirectoryDescriptor: frozen.directoryDescriptor,
                timeoutSeconds: timeout,
                trampolineExecutable: executablePath,
                executionSnapshot: snapshot
            ),
            cancellation: cancellation
        )
        try validatePhaseCompletion()
        if let configurationProbe {
            try handle.validateExecutionSnapshot(snapshot, account: account,
                requirePackedIdentity: true, configurationProbe: configurationProbe)
        }
        return result
    }

    private static func inventoryPhase(_ arguments: [String]) -> String {
        let phases = [
            "worktree", "for-each-ref", "symbolic-ref", "rev-parse",
            "merge-base", "show", "status", "config",
        ]
        return phases.first(where: arguments.contains) ?? "git_read"
    }

    private static func parseWorktrees(
        _ data: Data
    ) throws -> [WorktreeRecord] {
        guard !data.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "worktree inventory is empty"
            )
        }
        let fields = try data.split(
            separator: 0,
            omittingEmptySubsequences: true
        ).map { field -> String in
            guard let value = String(data: field, encoding: .utf8),
                  !value.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\0") else {
                throw GitSafetyError.unsafeRepository(
                    "worktree inventory is malformed"
                )
            }
            return value
        }
        var records: [WorktreeRecord] = []
        var path: String?
        var head: String?
        var branch: String?
        var isLocked = false
        func appendCurrent() {
            if let path {
                records.append(
                    WorktreeRecord(
                        path: path,
                        head: head,
                        branch: branch,
                        isLocked: isLocked
                    )
                )
            }
        }
        for field in fields {
            if field.hasPrefix("worktree ") {
                appendCurrent()
                path = String(field.dropFirst("worktree ".count))
                head = nil
                branch = nil
                isLocked = false
            } else if field.hasPrefix("HEAD ") {
                guard path != nil, head == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree HEAD inventory is ambiguous"
                    )
                }
                head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                guard path != nil, branch == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree branch inventory is ambiguous"
                    )
                }
                branch = String(field.dropFirst("branch ".count))
            } else if field == "locked" || field.hasPrefix("locked ") {
                isLocked = true
            } else if field == "detached" || field == "bare"
                || field == "prunable" || field.hasPrefix("prunable ") {
                continue
            } else {
                throw GitSafetyError.unsafeRepository(
                    "unknown worktree inventory field"
                )
            }
        }
        appendCurrent()
        guard !records.isEmpty,
              Set(records.map(\.path)).count == records.count,
              records.allSatisfy({
                  $0.path.hasPrefix("/")
                    && $0.head.map(Self.validOID) != false
                    && $0.branch.map(
                        GitReferenceSyntax.isValidLocalBranchRef
                    ) != false
              }) else {
            throw GitSafetyError.unsafeRepository(
                "worktree inventory is incomplete"
            )
        }
        return records
    }

    private static func locationKind(
        _ path: String,
        primary: String,
        account: EffectiveAccount
    ) -> WorktreeLocationKind {
        if path == primary {
            return .canonicalPrimary
        }
        if path.hasPrefix(account.homeDirectory + "/dev/") {
            return .dev
        }
        if path.hasPrefix(account.homeDirectory + "/.cursor/worktrees/") {
            return .cursorManaged
        }
        if path.hasPrefix(
            account.homeDirectory + "/.local/share/awa/worktrees/"
        ) {
            return .awaManaged
        }
        return .external
    }

    private static func locationWarning(
        _ path: String,
        account: EffectiveAccount
    ) -> String? {
        switch locationKind(path, primary: "", account: account) {
        case .external:
            return
                "This external feature worktree is context; it does not block Fast-forward of another verified target."
        case .cursorManaged, .awaManaged:
            return
                "This managed feature worktree is context; its location does not block Fast-forward."
        case .canonicalPrimary, .dev:
            return nil
        }
    }

    private static func objectID(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              validOID(value) else {
            return nil
        }
        return value
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }

    private static func localArguments(_ command: [String]) -> [String] {
        ["--no-replace-objects", "--no-lazy-fetch"] + command
    }
}
