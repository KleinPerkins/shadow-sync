import Darwin
import Foundation
import ShadowSyncCatalog

/// Separate from catalog classification. Only this session can construct a
/// classifier for the exact configuration sources derived by the fixed probe.
/// No arbitrary path-list entrypoint is exposed through the binder.
struct RepositoryConfigurationAdmission {
    fileprivate let evaluate: (GitConfigurationPreflight, EffectiveAccount, String, UInt64) throws -> Void

    func requireAllowed(_ preflight: GitConfigurationPreflight, account: EffectiveAccount,
                        identityCommitment: String, deadline: UInt64) throws {
        try evaluate(preflight, account, identityCommitment, deadline)
    }
}

/// One discovery/bind session over verified configuration and sealed resources.
/// The publisher factory supplies a separately qualified interpreter and resource
/// bytes and an owner-private, ACL-free scratch descriptor; this adapter does
/// not infer publisher trust or search PATH. Immutable fields and descriptor
/// lifetime are shared safely; the single transport invocation is lock-serialized.
final class PolicyCatalogSession: @unchecked Sendable {
    private let discoveryTransport: DiscoveryCommandTransport?
    private let snapshot: HostPolicySnapshot
    private let transport: PolicyHelperTransport
    private let directory: Int32
    private let directoryIdentity: FileIdentity
    private let cancellation: CancellationToken
    private let audit: CommandAudit?
    private let revalidateResources: @Sendable () throws -> Void
    private let execution = NSLock()
    private let pendingLock = NSLock()
    private var cleanupPending = false
    // The same short state lock records failed outer validations; only the
    // execution lock mutates the decision cache itself.
    private var cachedDecisionsRevoked = false
    private var isCleanupPending: Bool { pendingLock.lock(); defer { pendingLock.unlock() }; return cleanupPending }
    // The qualified AWA classifier is pure over bound policy/home/module bytes
    // and the exact lexical candidate. Reuse only inside one bounded scan; a
    // new catalog or bind deadline starts an empty decision set.
    private var decisionDeadline: UInt64?
    private var decisionsByPath: [Data: RepositorySelectionAdmissionDisposition] = [:]

    init(snapshot: HostPolicySnapshot, publisher: PublisherPolicyResources,
         context: CommandCustodyContext, scratchDescriptor: Int32,
         cancellation: CancellationToken, audit: CommandAudit? = nil) throws {
        let pin = try QualifiedAWAContract.decode(publisher.contract)
        guard pin.releaseRevision == snapshot.binding.releaseRevision,
              pin.moduleSHA256 == snapshot.binding.module.sha256,
              !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else { throw PolicyHelperError.unavailable }
        try context.validatePhaseAdmission(); try snapshot.revalidate(); try publisher.revalidate()
        var info = stat()
        guard Self.privateScratch(scratchDescriptor), fstat(scratchDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == snapshot.account.uid,
              info.st_mode & 0o777 == 0o700 else { throw PolicyHelperError.unavailable }
        let owned = fcntl(scratchDescriptor, F_DUPFD_CLOEXEC, 10)
        guard owned >= 10 else { throw PolicyHelperError.unavailable }
        directory = owned; directoryIdentity = FileIdentity(info); self.snapshot = snapshot
        self.cancellation = cancellation; self.audit = audit
        discoveryTransport = DiscoveryCommandTransport(context: context, publisher: publisher, cancellation: cancellation)
        let phase = context.phaseAdmissionCheck()
        revalidateResources = { try phase(); try publisher.revalidate() }
        transport = PolicyHelperTransport(snapshot: snapshot, publisher: publisher, context: context)
    }

    #if SHADOW_SYNC_TESTING
    init(snapshot: HostPolicySnapshot, interpreter: String, adapter: Data, contract: Data,
         scratchDescriptor: Int32, cancellation: CancellationToken,
         revalidateResources: @escaping @Sendable () throws -> Void,
         validateInterpreter: @escaping @Sendable (pid_t) throws -> Void,
         audit: CommandAudit? = nil) throws {
        let pin = try QualifiedAWAContract.decode(contract)
        guard pin.releaseRevision == snapshot.binding.releaseRevision,
              pin.moduleSHA256 == snapshot.binding.module.sha256,
              !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw PolicyHelperError.unavailable
        }
        try snapshot.revalidate()
        try revalidateResources()
        var info = stat()
        guard Self.privateScratch(scratchDescriptor), fstat(scratchDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == snapshot.account.uid,
              info.st_mode & 0o777 == 0o700 else { throw PolicyHelperError.unavailable }
        let owned = fcntl(scratchDescriptor, F_DUPFD_CLOEXEC, 10)
        guard owned >= 10 else { throw PolicyHelperError.unavailable }
        self.directory = owned
        self.directoryIdentity = FileIdentity(info)
        self.snapshot = snapshot
        self.discoveryTransport = nil
        self.cancellation = cancellation
        self.audit = audit
        self.revalidateResources = revalidateResources
        self.transport = PolicyHelperTransport(interpreter: interpreter, adapter: adapter, contract: contract,
            bindingSHA256: snapshot.bindingSHA256, policySHA256: snapshot.binding.policy.sha256,
            moduleSHA256: snapshot.binding.module.sha256, account: snapshot.account,
            revalidateAuthority: { try snapshot.revalidate(); try revalidateResources() },
            validateSuspendedChild: { pid in
                try snapshot.revalidate()
                try revalidateResources()
                try validateInterpreter(pid)
            })
    }

    #endif

    private static func privateScratch(_ descriptor: Int32) -> Bool {
        guard let security = filesec_init() else { return false }
        defer { filesec_free(security) }
        var info = stat(), present: Int32 = 0
        return fstatx_np(descriptor, &info, security) == 0 && info.st_nlink > 0
            && filesec_query_property(security, FILESEC_ACL, &present) == 0 && present == 0
    }

    deinit { close(directory) }

    var admission: RepositorySelectionPathAdmission {
        let value = RepositorySelectionPathAdmission(evaluate: { [self] paths, deadline in
            try classifyWithinValidatedAdmission(paths, deadline: deadline)
        }, revalidate: { [self] in try revalidate() })
        #if SHADOW_SYNC_TESTING
        return value.testingObservingFailures { stage, started, deadline in
            let observation: DiscoveryFixtureDiagnostic.Stage
            switch stage {
            case .deadlineBefore: observation = .deadlineBefore
            case .revalidation: observation = .revalidation
            case .deadlineAfter: observation = .deadlineAfter
            }
            DiscoveryFixtureDiagnostic.record(.admission, stage: observation,
                started: started, deadline: deadline)
        }
        #else
        return value
        #endif
    }

    func binder(setupDeadline: UInt64? = nil,
                revalidatePhase: @escaping @Sendable () throws -> Void = {}) throws -> SelectedRepositoryScopeBinder {
        try revalidatePhase()
        try revalidate()
        return try SelectedRepositoryScopeBinder(snapshot: snapshot, admission: admission,
            configurationAdmission: RepositoryConfigurationAdmission(evaluate: { [self] preflight, account, identity, deadline in
                try classifyConfiguration(preflight, account: account, identityCommitment: identity, deadline: deadline)
            }), discoveryTransport: discoveryTransport, setupDeadline: setupDeadline, revalidatePhase: revalidatePhase)
    }

    private func classifyConfiguration(_ preflight: GitConfigurationPreflight,
        account: EffectiveAccount, identityCommitment: String, deadline: UInt64) throws {
        // Share the transport's serialized child ownership with catalog work,
        // but never add external configuration decisions to its path cache.
        guard execution.try() else { throw PolicyHelperError.unavailable }
        defer { execution.unlock() }
        do {
            func current() throws {
                try revalidate()
                guard DispatchTime.now().uptimeNanoseconds < deadline,
                      try snapshot.identityCommitment() == identityCommitment,
                      snapshot.account.uid == account.uid,
                      snapshot.account.username.utf8.elementsEqual(account.username.utf8),
                      snapshot.account.homeDirectory.utf8.elementsEqual(account.homeDirectory.utf8) else {
                    throw PolicyHelperError.unavailable
                }
                try revalidate()
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw PolicyHelperError.unavailable }
            }
            try current()
            let plan = try ConfigurationPolicyPlan(preflight: preflight, account: account)
            for requested in plan.batches {
                try current()
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw PolicyHelperError.unavailable }
                let answers = try transport.classify(candidates: requested,
                    scratchDescriptor: directory, timeout: min(2, Double(deadline - now) / 1_000_000_000),
                    absoluteDeadline: deadline, cancellation: cancellation, audit: audit)
                try current()
                guard answers.count == requested.count, answers.allSatisfy(\.allowsCandidateAccess) else {
                    throw PolicyHelperError.unavailable
                }
            }
            try current()
        } catch {
            if case PolicyHelperError.cleanupPending = error {
                pendingLock.lock(); cleanupPending = true; pendingLock.unlock()
                throw RepositorySelectionAdmissionError.cleanupPending
            }
            if case RepositorySelectionAdmissionError.cleanupPending = error { throw error }
            throw PolicyHelperError.unavailable
        }
    }

    private func revalidate() throws {
        var validated = false
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticSample = DiscoveryFixtureDiagnostic.sampleRevalidation()
        var diagnosticMilestones: [UInt64] = []
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.entry
        defer {
            if !validated || diagnosticSample {
                DiscoveryFixtureDiagnostic.record(.session, stage: diagnosticStage,
                    started: diagnosticStart, deadline: nil, succeeded: validated,
                    milestones: diagnosticMilestones)
            }
        }
        #endif
        defer {
            if !validated {
                pendingLock.lock(); cachedDecisionsRevoked = true; pendingLock.unlock()
            }
        }
        guard !isCleanupPending else { throw RepositorySelectionAdmissionError.cleanupPending }
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw PolicyHelperError.unavailable
        }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .scratch
        #endif
        var info = stat()
        guard Self.privateScratch(directory), fstat(directory, &info) == 0, FileIdentity(info).matchesStableNode(directoryIdentity),
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == snapshot.account.uid,
              info.st_mode & 0o777 == 0o700 else { throw PolicyHelperError.unavailable }
        do {
            #if SHADOW_SYNC_TESTING
            // Successful samples have four intervals: scratch, host snapshot,
            // publisher resources, then postflight. No pathname is recorded.
            if diagnosticSample { diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds) }
            diagnosticStage = .snapshot
            #endif
            try snapshot.revalidate()
            #if SHADOW_SYNC_TESTING
            if diagnosticSample { diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds) }
            diagnosticStage = .resources
            #endif
            try revalidateResources()
            #if SHADOW_SYNC_TESTING
            if diagnosticSample { diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds) }
            #endif
        } catch PolicyHelperError.cleanupPending {
            pendingLock.lock(); cleanupPending = true; pendingLock.unlock()
            throw RepositorySelectionAdmissionError.cleanupPending
        }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .postflight
        #endif
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw PolicyHelperError.unavailable
        }
        validated = true
    }

    /// Optional lexical prefetch only. A cached result never replaces the
    /// catalog's later exact-path decision and fresh authority/resource checks.
    /// Required candidates keep their slots when either bound is nearly full.
    static func prefetchCatalogMetadata(_ required: [String], cached: Set<Data>,
                                        projectionRoot: String, shelves: [[String]] = []) -> [String] {
        var result = required
        var keys = Set(required.map { Data($0.utf8) })
        let prefix = Data((projectionRoot + "/").utf8)
        let markerSuffix = Data("/.git".utf8)
        let suffixes = ["config", "refs", "refs/remotes", "refs/remotes/origin", "refs/remotes/origin/HEAD"]
        var markers = required.filter { Data($0.utf8).starts(with: prefix)
            && Data($0.utf8).suffix(markerSuffix.count).elementsEqual(markerSuffix) }
        // A returned directory name is lexical input, not candidate authority.
        // For exact children of authenticated shelves, ask for the fixed marker
        // and metadata in the same bounded request. No path is inspected here.
        // Later traversal still consumes its own exact decision under the same
        // deadline and freshly revalidated policy/resource lease.
        let parents = Set(shelves.map { Data((projectionRoot + "/" + $0.joined(separator: "/")).utf8) })
        for candidate in required {
            guard let slash = candidate.lastIndex(of: "/"),
                  parents.contains(Data(candidate[..<slash].utf8)) else { continue }
            let leaf = candidate[candidate.index(after: slash)...]
            guard !leaf.isEmpty, !leaf.hasPrefix(".") else { continue }
            let marker = candidate + "/.git", key = Data(marker.utf8)
            if !cached.contains(key), !keys.contains(key), result.count < 64, cached.count + result.count < 4096 {
                keys.insert(key); result.append(marker)
            }
            markers.append(marker)
        }
        for marker in markers {
            let bytes = Data(marker.utf8)
            guard bytes.starts(with: prefix), bytes.suffix(markerSuffix.count).elementsEqual(markerSuffix) else { continue }
            for suffix in suffixes where result.count < 64 && cached.count + result.count < 4096 {
                let candidate = marker + "/" + suffix, key = Data(candidate.utf8)
                if !cached.contains(key), keys.insert(key).inserted { result.append(candidate) }
            }
        }
        return result
    }

    // The sole caller is RepositorySelectionPathAdmission.evaluate. Its
    // nonoptional validate/evaluate/validate wrapper brackets this lexical
    // evaluation with full policy/resource checks. Revalidation failure at
    // either outer boundary revokes cache reuse for the next serialized call.
    private func classifyWithinValidatedAdmission(_ paths: [RepositorySelectionAdmissionPath], deadline: UInt64)
        throws -> [RepositorySelectionAdmissionDecision] {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.entry
        var diagnosticPassed = false
        defer {
            DiscoveryFixtureDiagnostic.record(.catalog, stage: diagnosticStage,
                started: diagnosticStart, deadline: deadline, succeeded: diagnosticPassed)
        }
        #endif
        // Concurrent callers cannot share the helper's child-ownership token.
        // Refuse instead of queueing beyond the caller's admission deadline.
        guard execution.try() else { throw PolicyHelperError.unavailable }
        defer { execution.unlock() }
        do {
            pendingLock.lock()
            let revoked = cachedDecisionsRevoked
            cachedDecisionsRevoked = false
            pendingLock.unlock()
            if revoked {
                decisionsByPath.removeAll(keepingCapacity: true)
                decisionDeadline = nil
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw PolicyHelperError.unavailable }
            let prefix = snapshot.projection.rootComponents.map { Array($0.utf8) }
            let candidates = try paths.map { path -> String in
                let parts = path.components.map { Array($0.utf8) }
                guard path.root.utf8.elementsEqual("~".utf8),
                      parts.starts(with: prefix) || prefix.starts(with: parts) else {
                    throw PolicyHelperError.unavailable
                }
                return snapshot.account.homeDirectory
                    + (path.components.isEmpty ? "" : "/" + path.components.joined(separator: "/"))
            }
            let keys = candidates.map { Data($0.utf8) }
            guard !keys.isEmpty, keys.count <= 64, Set(keys).count == keys.count else {
                throw PolicyHelperError.unavailable
            }
            if decisionDeadline != deadline {
                decisionsByPath.removeAll(keepingCapacity: true)
                decisionDeadline = deadline
            }
            let missing = keys.indices.filter { decisionsByPath[keys[$0]] == nil }
            if !missing.isEmpty {
                var requested = missing.map { candidates[$0] }
                var requestedKeys = Set(requested.map { Data($0.utf8) })
                // Projection prefixes are already authenticated lexical data.
                // Classify them in the first bounded batch without inspecting
                // any pathname. Later intermediate-path admission still needs
                // its exact cached decision and fresh policy/resource checks.
                // This avoids a separate interpreter for each known shelf.
                if decisionsByPath.isEmpty {
                    let projected = [snapshot.projection.rootComponents]
                        + snapshot.projection.shelves.map { snapshot.projection.rootComponents + $0 }
                    for components in projected {
                        for length in 0...components.count where requested.count < 64 {
                            let suffix = components.prefix(length).joined(separator: "/")
                            let candidate = snapshot.account.homeDirectory + (suffix.isEmpty ? "" : "/" + suffix)
                            if requestedKeys.insert(Data(candidate.utf8)).inserted { requested.append(candidate) }
                        }
                    }
                    // These marker paths are fixed by the already authenticated
                    // projection. Prefetch their lexical decisions in remaining
                    // batch capacity; traversal still consumes the exact decision
                    // with fresh policy/resource checks and the same deadline.
                    // The home anchor itself is never a projected repository.
                    for components in projected where requested.count < 64 {
                        let candidate = snapshot.account.homeDirectory + "/"
                            + (components + [".git"]).joined(separator: "/")
                        if requestedKeys.insert(Data(candidate.utf8)).inserted { requested.append(candidate) }
                    }
                }
                requested = Self.prefetchCatalogMetadata(requested, cached: Set(decisionsByPath.keys),
                    projectionRoot: snapshot.account.homeDirectory + "/" + snapshot.projection.rootComponents.joined(separator: "/"),
                    shelves: snapshot.projection.shelves)
                guard decisionsByPath.count + requested.count <= 4096 else { throw PolicyHelperError.unavailable }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw PolicyHelperError.unavailable }
                let budget = min(2, Double(deadline - now) / 1_000_000_000)
                #if SHADOW_SYNC_TESTING
                diagnosticStage = .execution
                #endif
                let decisions = try transport.classify(candidates: requested,
                    scratchDescriptor: directory, timeout: budget, absoluteDeadline: deadline, cancellation: cancellation, audit: audit)
                #if SHADOW_SYNC_TESTING
                diagnosticStage = .postflight
                #endif
                try revalidate()
                guard DispatchTime.now().uptimeNanoseconds < deadline, decisions.count == requested.count else {
                    throw PolicyHelperError.unavailable
                }
                // Validate the entire batch before retaining any decision.
                #if SHADOW_SYNC_TESTING
                diagnosticStage = .decisions
                #endif
                let admitted = try decisions.map { decision -> RepositorySelectionAdmissionDisposition in
                    if decision.allowsCandidateAccess { return .allowed }
                    if decision.policyValid && decision.matched
                        && (decision.kind == .exactRoot || decision.kind == .managedNamespace) { return .protected }
                    throw PolicyHelperError.unavailable
                }
                for (candidate, disposition) in zip(requested, admitted) { decisionsByPath[Data(candidate.utf8)] = disposition }
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw PolicyHelperError.unavailable }
            let results = try zip(paths, keys).map { path, key in
                guard let disposition = decisionsByPath[key] else { throw PolicyHelperError.unavailable }
                return RepositorySelectionAdmissionDecision(path: path, disposition: disposition)
            }
            #if SHADOW_SYNC_TESTING
            diagnosticPassed = true
            #endif
            return results
        } catch {
            // A failed classification must not leave a partial or previously
            // retained allow available to a later call in the failed scan.
            decisionsByPath.removeAll(keepingCapacity: true)
            decisionDeadline = nil
            if case PolicyHelperError.cleanupPending = error {
                pendingLock.lock(); cleanupPending = true; pendingLock.unlock()
                throw RepositorySelectionAdmissionError.cleanupPending
            }
            if case RepositorySelectionAdmissionError.cleanupPending = error { throw error }
            throw PolicyHelperError.unavailable
        }
    }
}
