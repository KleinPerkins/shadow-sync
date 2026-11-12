import Darwin
import ShadowSyncCatalog
import Foundation

public enum SelectedRepositoryScopeError:
    Error, CustomStringConvertible, Equatable {
    case invalidIntent
    case policyUnavailable
    case cleanupPending
    case catalogDegraded(String)
    case changed
    case unknown(String)
    case ambiguous(String)
    case forbidden(String)
    case unsafeTraversal(String)

    public var description: String {
        switch self {
        case .invalidIntent:
            return "Repository selection is empty or invalid."
        case .cleanupPending:
            return "Repository policy work is still stopping. Wait for recovery before continuing."
        case .policyUnavailable:
            return "The current repository policy is unavailable."
        case let .catalogDegraded(reason):
            return "Repository selection cannot continue: \(reason)"
        case .changed:
            return "Repository locations changed — reload before continuing."
        case let .unknown(id):
            return "Selected repository is no longer present: \(id)"
        case let .ambiguous(id):
            return "Selected repository is ambiguous: \(id)"
        case let .forbidden(id):
            return "Selected repository is no longer allowed: \(id)"
        case let .unsafeTraversal(id):
            return "Selected repository location is unsafe: \(id)"
        }
    }
}

public struct ValidatedSelectedRepository:
    Equatable, Sendable {
    public let repositoryID: String
    public let locator: RepositorySelectionLocator
    public let governedRootPath: String
    public let policyRootPath: String
    public let repositoryPath: String
    public let rootIdentity: FileIdentity
    public let repositoryIdentity: FileIdentity
}

public struct ValidatedSelectedRepositoryScope:
    Equatable, Sendable {
    public let selectionGeneration: UInt64
    public let policyDigest: String
    public let catalogGeneration: UInt64
    public let repositories: [ValidatedSelectedRepository]
    public let governedRootRole: GovernedRootRole?

    init(selectionGeneration: UInt64, policyDigest: String,
         catalogGeneration: UInt64, repositories: [ValidatedSelectedRepository],
         governedRootRole: GovernedRootRole? = nil) {
        self.selectionGeneration = selectionGeneration
        self.policyDigest = policyDigest
        self.catalogGeneration = catalogGeneration
        self.repositories = repositories
        self.governedRootRole = governedRootRole
    }

    public func requireGovernedRootRole() throws -> GovernedRootRole {
        guard let role = governedRootRole, role.policyDigest == policyDigest else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        return role
    }

    public var repositoryIDs: Set<String> {
        Set(repositories.map(\.repositoryID))
    }

    public var repositoryPaths: Set<String> {
        Set(repositories.map(\.repositoryPath))
    }

    public func exactRepositoryScope(
        repositoryID: String
    ) throws -> ValidatedSelectedRepositoryScope {
        let matches = repositories.filter {
            $0.repositoryID == repositoryID
        }
        guard matches.count == 1 else {
            throw matches.isEmpty
                ? SelectedRepositoryScopeError.unknown(repositoryID)
                : SelectedRepositoryScopeError.ambiguous(repositoryID)
        }
        return ValidatedSelectedRepositoryScope(
            selectionGeneration: selectionGeneration,
            policyDigest: policyDigest,
            catalogGeneration: catalogGeneration,
            repositories: matches,
            governedRootRole: governedRootRole
        )
    }

    public func admits(_ candidate: RepositoryCandidate) -> Bool {
        repositories.contains {
            $0.repositoryID == candidate.id
                && $0.repositoryPath == candidate.path
                && $0.repositoryIdentity.device
                    == candidate.rootIdentity?.device
                && $0.repositoryIdentity.inode
                    == candidate.rootIdentity?.inode
        }
    }

    #if SHADOW_SYNC_TESTING
    public static func testing(
        candidates: [RepositoryCandidate]
    ) throws -> ValidatedSelectedRepositoryScope {
        let grouped = Dictionary(
            grouping: candidates,
            by: \.id
        )
        var repositories: [ValidatedSelectedRepository] = []
        for (index, repositoryID) in grouped.keys.sorted().enumerated() {
            guard let candidate = grouped[repositoryID]?.first else {
                continue
            }
            var repositoryInfo = stat()
            guard lstat(candidate.path, &repositoryInfo) == 0 else {
                throw SelectedRepositoryScopeError.changed
            }
            let identity = FileIdentity(repositoryInfo)
            repositories.append(
                ValidatedSelectedRepository(
                    repositoryID: repositoryID,
                    locator: try RepositorySelectionLocator(
                        governedRoot: "testing",
                        components: ["repository-\(index)"]
                    ),
                    governedRootPath:
                        URL(fileURLWithPath: candidate.path)
                            .deletingLastPathComponent().path,
                    policyRootPath:
                        URL(fileURLWithPath: candidate.path)
                            .deletingLastPathComponent().path,
                    repositoryPath: candidate.path,
                    rootIdentity: identity,
                    repositoryIdentity: identity
                )
            )
        }
        return ValidatedSelectedRepositoryScope(
            selectionGeneration: 1,
            policyDigest: String(repeating: "0", count: 64),
            catalogGeneration: 1,
            repositories: repositories,
            governedRootRole: .testing()
        )
    }

    public static func testing(
        plan: Body3BatchPlan
    ) throws -> ValidatedSelectedRepositoryScope {
        let candidates = plan.nodes.flatMap {
            node -> [RepositoryCandidate] in
            switch node.payload {
            case let .operation(operation):
                return [
                    operation.target.canonicalClone.sourceSnapshot,
                ]
            case let .removal(candidate),
                 let .residue(candidate):
                return [candidate.clone.sourceSnapshot]
            case let .retention(selection):
                return [selection.candidate.clone.sourceSnapshot]
            case let .confirmation(selections):
                return selections.map {
                    $0.candidate.clone.sourceSnapshot
                }
            case .reinspection, .policyInvalidation:
                return []
            }
        }
        return try testing(candidates: candidates)
    }
    #endif
}

/// Serial metadata admission borrowed from one live binder. Saved selection
/// values cannot construct this service, and retaining it cannot extend a phase.
final class RepositoryDiscoveryPolicy {
    let scope: ValidatedSelectedRepositoryScope
    let account: EffectiveAccount
    let policy: RepositoryPolicy
    private let snapshot: HostPolicySnapshot
    private let admission: RepositorySelectionPathAdmission
    private let phase: @Sendable () throws -> Void
    private let cancellation: CancellationToken
    private let deadline: UInt64
    private var closed = false
    private var failure: SelectedRepositoryScopeError?
    #if SHADOW_SYNC_TESTING
    var testingBeforeAccess: ((String) -> Void)?
    var testingProtectedPath: ((String, UInt64) -> Void)?
    #endif

    fileprivate init(scope: ValidatedSelectedRepositoryScope, snapshot: HostPolicySnapshot,
                     admission: RepositorySelectionPathAdmission, cancellation: CancellationToken,
                     phase: @escaping @Sendable () throws -> Void, deadline: UInt64) throws {
        self.scope = scope; self.snapshot = snapshot; self.admission = admission
        self.cancellation = cancellation; self.phase = phase; self.deadline = deadline
        account = snapshot.account
        policy = try RepositoryPolicy(snapshot: snapshot)
        guard scope.policyDigest == snapshot.admissionSHA256,
              !scope.repositories.isEmpty else { throw SelectedRepositoryScopeError.changed }
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.initial)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        try validate()
    }

    fileprivate func close() { closed = true }

    func validate() throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticHadCaller = DiscoveryFixtureDiagnostic.hasCaller
        let diagnosticCaller = diagnosticHadCaller ? nil : DiscoveryFixtureDiagnostic.enterCaller(.validate)
        defer { if !diagnosticHadCaller { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) } }
        #endif
        try validateLocalAuthority()
        do { try admission.validate(deadline: deadline) }
        catch { throw record(error) }
    }

    /// Lexical preparation has no candidate I/O. Its following classify call
    /// must retain admission's full resource validation before and after
    /// evaluation; the preparation's final validate remains complete as well.
    /// Avoid repeating that resource scan before pure path construction.
    private func validateLocalAuthority() throws {
        if let failure { throw failure }
        do {
            guard !closed, !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed,
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SelectedRepositoryScopeError.policyUnavailable
            }
            try phase(); try snapshot.revalidate()
        } catch { throw record(error) }
    }

    private func record(_ error: Error) -> SelectedRepositoryScopeError {
        let pending: Bool
        switch error {
        case RepositorySelectionAdmissionError.cleanupPending, PolicyHelperError.cleanupPending,
             SelectedRepositoryScopeError.cleanupPending: pending = true
        default: pending = false
        }
        if failure == nil || pending { failure = pending ? .cleanupPending : .policyUnavailable }
        return failure!
    }

    /// Strict lexical components only; no URL normalization or filesystem probe.
    private func homeRelative(_ path: String) throws -> [String] {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let home = account.homeDirectory.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= home.count,
              zip(pieces.prefix(home.count), home).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        let relative = Array(pieces.dropFirst(home.count))
        _ = try RepositorySelectionAdmissionPath(root: "~", components: relative)
        return relative
    }

    func requireAllowed(_ path: String) throws { try requireAllowed([path]) }

    func requireAllowed(_ paths: [String]) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.requireAllowed)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        try validateLocalAuthority()
        do {
            try classifyAllowed(paths)
            try validate()
        } catch { throw preparationFailure(error) }
    }

    /// Internal lexical preparation only; callers own entry/final phase checks.
    /// classify still performs full resource validation before and after every
    /// evaluation, including cache hits. No candidate access occurs here.
    private func classifyAllowed(_ paths: [String]) throws {
        let requests = try paths.map { try RepositorySelectionAdmissionPath(root: "~", components: homeRelative($0)) }
        let results = try admission.classify(requests, deadline: deadline)
        guard results.allSatisfy({ if case .allowed = $0 { return true }; return false }) else {
            #if SHADOW_SYNC_TESTING
            for (path, result) in zip(paths, results) {
                if case .protected = result { testingProtectedPath?(path, deadline) }
            }
            #endif
            throw SelectedRepositoryScopeError.policyUnavailable
        }
    }

    /// A permitted leaf does not grant access through a protected ancestor.
    /// Keep every prefix request inside the original metadata-stage deadline.
    func prepareAccess(_ paths: [String]) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.prepareAccess)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        try validateLocalAuthority()
        do {
            try classifyAccessPrefixes(paths)
            try validate()
        } catch { throw preparationFailure(error) }
    }

    /// Share preparation without nesting public boundaries. Every prefix is
    /// still classified under the original deadline. The enclosing method must
    /// finish with validate() before allowing its caller to access a candidate.
    private func classifyAccessPrefixes(_ paths: [String]) throws {
        guard !paths.isEmpty, paths.count <= 64 else { throw SelectedRepositoryScopeError.policyUnavailable }
        var prefixes: [String] = []
        var seen: Set<Data> = []
        for path in paths {
            let relative = try homeRelative(path)
            for count in 0...relative.count {
                let suffix = relative.prefix(count).joined(separator: "/")
                let prefix = account.homeDirectory + (suffix.isEmpty ? "" : "/" + suffix)
                // Filesystem names and classifier keys retain exact UTF-8.
                if seen.insert(Data(prefix.utf8)).inserted { prefixes.append(prefix) }
            }
        }
        for start in stride(from: 0, to: prefixes.count, by: 64) {
            try classifyAllowed(Array(prefixes[start..<min(start + 64, prefixes.count)]))
        }
    }

    /// A malformed lexical request must not hide an outstanding cleanup
    /// obligation that the former entry validation would have observed.
    /// This full check performs no candidate classification or access.
    private func preparationFailure(_ original: Error) -> SelectedRepositoryScopeError {
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.preparationFailure)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        do { try validate() } catch { _ = record(error) }
        return record(original)
    }

    func willAccess(_ path: String) throws { try willAccess([path]) }

    /// Consecutive lexical admissions may share one boundary only when no
    /// candidate I/O intervenes. Preserve each ordered hook and complete fresh
    /// validation after all hooks, immediately before the caller's candidate I/O.
    func willAccess(_ paths: [String]) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.willAccess)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        try validateLocalAuthority()
        do {
            try classifyAccessPrefixes(paths)
            #if SHADOW_SYNC_TESTING
            for path in paths { testingBeforeAccess?(path) }
            #endif
            try validate()
        } catch { throw preparationFailure(error) }
    }

    func policyRelativePath(_ path: String) throws -> String {
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.policyRelativePath)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        try validate()
        let relative = try homeRelative(path), prefix = snapshot.projection.rootComponents
        guard relative.count >= prefix.count,
              zip(relative.prefix(prefix.count), prefix).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
            throw SelectedRepositoryScopeError.changed
        }
        let suffix = relative.dropFirst(prefix.count)
        return suffix.isEmpty ? "." : suffix.joined(separator: "/")
    }

    func presentationLocation(_ path: String) throws -> String {
        let relative = try homeRelative(path)
        return relative.isEmpty ? "~" : "~/" + relative.joined(separator: "/")
    }

    func requireSelected(_ selected: ValidatedSelectedRepository) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.requireSelected)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
        #endif
        try validate()
        let relative = try homeRelative(selected.repositoryPath)
        let root = account.homeDirectory + "/" + snapshot.projection.rootComponents.joined(separator: "/")
        guard scope.repositories.contains(selected),
              selected.governedRootPath.utf8.elementsEqual(account.homeDirectory.utf8),
              selected.policyRootPath.utf8.elementsEqual(root.utf8),
              selected.locator.governedRoot == "~",
              relative.count == selected.locator.components.count,
              zip(relative, selected.locator.components).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
            throw SelectedRepositoryScopeError.changed
        }
        _ = try policyRelativePath(selected.repositoryPath)
        // Classification precedes traversal, including each intermediate node.
        try prepareAccess([selected.repositoryPath])
        try RepositoryRootPathIdentity.withVerifiedDirectory(path: account.homeDirectory,
            expected: RepositoryDirectoryIdentity(selected.rootIdentity)) { opened in
            var info = stat()
            guard fstat(opened.descriptor, &info) == 0, FileIdentity(info) == selected.rootIdentity else {
                throw SelectedRepositoryScopeError.changed
            }
        }
        try RepositoryRootPathIdentity.withVerifiedDirectory(path: selected.repositoryPath,
            expected: RepositoryDirectoryIdentity(selected.repositoryIdentity)) { opened in
            var info = stat()
            guard fstat(opened.descriptor, &info) == 0, FileIdentity(info) == selected.repositoryIdentity else {
                throw SelectedRepositoryScopeError.changed
            }
        }
        try validate()
    }
}

/// One command's live policy admission. It cannot be constructed from a saved
/// selection, digest or execution snapshot. The binder owns its callback lifetime;
/// the enclosing custody phase owns the real leases. This service does not spawn
/// Git or grant a qualified command graph.
final class RepositoryDiscoveryCommandPolicy {
    let command: DiscoveryGitCommand
    let budget: CustodyBudget
    let selected: ValidatedSelectedRepository
    let identityCommitment: String
    private let metadata: RepositoryDiscoveryPolicy
    private let snapshot: HostPolicySnapshot
    private let configurationAdmission: RepositoryConfigurationAdmission?
    private var failure: SelectedRepositoryScopeError?

    fileprivate init(command: DiscoveryGitCommand, budget: CustodyBudget,
                     selected: ValidatedSelectedRepository,
                     metadata: RepositoryDiscoveryPolicy, snapshot: HostPolicySnapshot,
                     configurationAdmission: RepositoryConfigurationAdmission?) throws {
        self.command = command; self.budget = budget; self.selected = selected
        self.metadata = metadata; self.snapshot = snapshot
        self.configurationAdmission = configurationAdmission
        identityCommitment = try snapshot.identityCommitment()
        try validate()
        try metadata.requireSelected(selected)
    }

    var account: EffectiveAccount { metadata.account }
    var policy: RepositoryPolicy { metadata.policy }
    func currentSnapshot() throws -> HostPolicySnapshot { try validate(); return snapshot }

    private func record(_ error: Error) -> SelectedRepositoryScopeError {
        let pending: Bool
        switch error {
        case SelectedRepositoryScopeError.cleanupPending, PolicyHelperError.cleanupPending,
             RepositorySelectionAdmissionError.cleanupPending, SystemGitConfigurationError.cleanupPending: pending = true
        default: pending = false
        }
        if failure == nil || pending { failure = pending ? .cleanupPending : .policyUnavailable }
        return failure!
    }

    func validate() throws {
        if let failure { throw failure }
        do {
            try metadata.validate()
            try budget.validate(kind: .discoveryGit, permittedWorkSeconds: command.workSeconds,
                                now: DispatchTime.now().uptimeNanoseconds)
            guard try snapshot.identityCommitment() == identityCommitment else {
                throw SelectedRepositoryScopeError.changed
            }
            // File/ancestor validation consumes time and may observe revocation.
            // Recheck the live phase and original deadline after that work.
            try metadata.validate()
            try budget.validate(kind: .discoveryGit, permittedWorkSeconds: command.workSeconds,
                                now: DispatchTime.now().uptimeNanoseconds)
        } catch { throw record(error) }
    }

    /// A bound candidate must be the exact selected physical checkout under the
    /// same current policy. Selection is not authority over a substitute clone.
    func requireCandidate(_ candidate: RepositoryCandidate) throws {
        do {
            try validate()
            guard candidate.isEligible, metadata.scope.admits(candidate),
                  candidate.id.utf8.elementsEqual(selected.repositoryID.utf8),
                  candidate.path.utf8.elementsEqual(selected.repositoryPath.utf8),
                  candidate.policyAdmissionSHA256 == snapshot.admissionSHA256 else {
                throw SelectedRepositoryScopeError.changed
            }
            try metadata.requireSelected(selected)
            try validate()
        } catch { throw record(error) }
    }

    /// Call before inspecting repository metadata or a decoded linked target.
    /// No cached path/digest grants new access. The classifier checks the leaf
    /// and every ancestor using this command's original absolute deadline.
    func willAccess(_ path: String) throws {
        do {
            try validate()
            // This command is bound to one selected checkout. A classifier's
            // allowed answer for another repository cannot enlarge that scope.
            // External linked/configuration resources require their separately
            // derived and verified resource admission; they are not implicit.
            guard path.utf8.elementsEqual(selected.repositoryPath.utf8)
                    || path.utf8.starts(with: (selected.repositoryPath + "/").utf8) else {
                throw SelectedRepositoryScopeError.changed
            }
            try metadata.requireSelected(selected)
            try metadata.willAccess(path)
            try metadata.requireSelected(selected)
            try validate()
        } catch { throw record(error) }
    }

    /// Configuration is a closed, separately derived resource set. Admitting it
    /// does not enlarge willAccess's selected-repository scope. Validate before
    /// and after consumption so a caught refusal cannot become command success.
    func withConfiguration<Value>(_ preflight: GitConfigurationPreflight,
        _ body: (GitConfigurationPreflight) throws -> Value) throws -> Value {
        do {
            try validate()
            try metadata.requireSelected(selected)
            guard let configurationAdmission else { throw SelectedRepositoryScopeError.policyUnavailable }
            try configurationAdmission.requireAllowed(preflight, account: account,
                identityCommitment: identityCommitment, deadline: budget.work)
            try validate()
            try metadata.requireSelected(selected)
            let value = try body(preflight)
            try validate()
            try configurationAdmission.requireAllowed(preflight, account: account,
                identityCommitment: identityCommitment, deadline: budget.work)
            try metadata.requireSelected(selected)
            try validate()
            return value
        } catch {
            let original = error
            // Callback errors must not hide a concurrently observed pending
            // cleanup. Validation performs no new path classification and
            // cannot reopen a closed phase. Pending always wins in record().
            do { try validate() } catch { _ = record(error) }
            throw record(original)
        }
    }

    #if SHADOW_SYNC_TESTING
    var testingBeforeAccess: ((String) -> Void)? {
        get { metadata.testingBeforeAccess }
        set { metadata.testingBeforeAccess = newValue }
    }
    #endif
}

public final class SelectedRepositoryScopeBinder:
    @unchecked Sendable {
    private let governedRootPath: String
    private let policyRootPath: String
    private let logicalRoot: String
    private let policyPathPrefix: [String]
    private let expectedUID: uid_t
    private let catalogLimits: RepositorySelectionCatalogLimits
    private let admission: RepositorySelectionPathAdmission
    private let discoveryTransport: DiscoveryCommandTransport?
    private let configurationAdmission: RepositoryConfigurationAdmission?
    private let snapshot: HostPolicySnapshot?
    private let setupDeadline: UInt64?
    private let revalidatePhase: @Sendable () throws -> Void

    #if SHADOW_SYNC_TESTING
    // Per-binder, synchronous seam; never a production source of authority.
    var testingAfterRebindCatalog: (() throws -> Void)?
    #endif

    public static func withProductionReadPhase<Value>(cancellation: CancellationToken,
        _ body: (SelectedRepositoryScopeBinder) throws -> Value
    ) throws -> Value {
        let context: CommandCustodyContext
        do { context = try CommandCustodyContext.read() }
        catch { throw SelectedRepositoryScopeError.policyUnavailable }
        return try CommandCustodyContext.withPhase(context) { phase in
            try body(production(context: phase, cancellation: cancellation))
        }
    }

    /// A caller already changing canonical authority borrows its actual EX
    /// leases. It must not recursively acquire a separate SH operation lock.
    public static func withProductionPhase<Value>(borrowing authority: RunAuthority, cancellation: CancellationToken,
        _ body: (SelectedRepositoryScopeBinder) throws -> Value
    ) throws -> Value {
        try withProductionConfigurationPhase(borrowing: authority, cancellation: cancellation) { binder, _ in
            try body(binder)
        }
    }

    /// Inspection receives a weak service over the same actual EX authority as
    /// the binder. It cannot reconstruct authority from a transport descriptor.
    static func withProductionConfigurationPhase<Value>(borrowing authority: RunAuthority,
        cancellation: CancellationToken,
        _ body: (SelectedRepositoryScopeBinder, SystemGitConfigurationProbe) throws -> Value
    ) throws -> Value {
        let context: CommandCustodyContext
        do { context = try CommandCustodyContext.borrowing(authority) }
        catch { throw SelectedRepositoryScopeError.policyUnavailable }
        return try CommandCustodyContext.withPhase(context) { phase in
            let binder = try production(context: phase, cancellation: cancellation)
            let probe = SystemGitConfigurationProbe(context: phase, cancellation: cancellation)
            return try probe.withValidatedCompletion {
                let value = try body(binder, probe)
                try phase.validatePhaseAdmission()
                guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                    throw SelectedRepositoryScopeError.policyUnavailable
                }
                return value
            }
        }
    }

    private static func policyFailure(_ error: Error) -> SelectedRepositoryScopeError {
        if case RepositorySelectionAdmissionError.cleanupPending = error { return .cleanupPending }
        if case PolicyHelperError.cleanupPending = error { return .cleanupPending }
        if case SelectedRepositoryScopeError.cleanupPending = error { return .cleanupPending }
        return .policyUnavailable
    }

    private static func production(context: CommandCustodyContext, cancellation: CancellationToken) throws -> SelectedRepositoryScopeBinder {
        do { return try context.currentPolicyBinder(cancellation: cancellation) }
        catch { throw Self.policyFailure(error) }
    }

    #if SHADOW_SYNC_TESTING
    public init(
        governedRootPath: String,
        policyRootPath: String? = nil,
        logicalRoot: String,
        policyPathPrefix: [String] = [],
        expectedUID: uid_t = geteuid(),
        catalogLimits: RepositorySelectionCatalogLimits =
            RepositorySelectionCatalogLimits(),
        admission: RepositorySelectionPathAdmission = .unavailable,
        revalidatePhase: @escaping @Sendable () throws -> Void = {}
    ) {
        self.governedRootPath = governedRootPath
        self.policyRootPath = policyRootPath ?? governedRootPath
        self.logicalRoot = logicalRoot
        self.policyPathPrefix = policyPathPrefix
        self.expectedUID = expectedUID
        self.catalogLimits = catalogLimits
        self.admission = admission
        self.configurationAdmission = nil
        self.discoveryTransport = nil
        self.snapshot = nil
        self.setupDeadline = nil
        self.revalidatePhase = revalidatePhase
    }
    #endif

    init(snapshot: HostPolicySnapshot, admission: RepositorySelectionPathAdmission,
         configurationAdmission: RepositoryConfigurationAdmission? = nil,
         discoveryTransport: DiscoveryCommandTransport? = nil, setupDeadline: UInt64? = nil,
         revalidatePhase: @escaping @Sendable () throws -> Void = {}) throws {
        try revalidatePhase()
        if let setupDeadline, DispatchTime.now().uptimeNanoseconds >= setupDeadline {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        try snapshot.revalidate()
        let limits = RepositorySelectionCatalogLimits()
        guard snapshot.projection.rootComponents.count + 1 <= limits.relativeDepth,
              snapshot.projection.shelves.allSatisfy({
                  snapshot.projection.rootComponents.count + $0.count + 1 <= limits.relativeDepth
              }) else { throw SelectedRepositoryScopeError.policyUnavailable }
        self.governedRootPath = snapshot.account.homeDirectory
        self.policyRootPath = snapshot.account.homeDirectory + "/" + snapshot.projection.rootComponents.joined(separator: "/")
        self.logicalRoot = "~"
        self.policyPathPrefix = snapshot.projection.rootComponents
        self.expectedUID = snapshot.account.uid
        self.catalogLimits = limits
        self.setupDeadline = setupDeadline
        self.admission = admission
        self.configurationAdmission = configurationAdmission
        self.discoveryTransport = discoveryTransport
        self.snapshot = snapshot
        self.revalidatePhase = revalidatePhase
    }

    private func activeSelectionPolicy() throws -> RepositorySelectionPolicy {
        try revalidatePhase()
        if let snapshot {
            try snapshot.revalidate()
            let projection = snapshot.projection
            func prefixed(_ value: String) -> String {
                let prefix = projection.rootComponents.joined(separator: "/")
                return value == "." ? prefix : prefix + "/" + value
            }
            return try RepositorySelectionPolicy(
                shelfPaths: [projection.rootComponents] + projection.shelves.map { projection.rootComponents + $0 },
                excludedPaths: projection.paths.excluded.map(prefixed),
                readOnlyPaths: projection.paths.readOnly.map(prefixed),
                artifactPaths: projection.paths.artifacts.map(prefixed),
                writablePaths: projection.paths.writable.map(prefixed),
                permanentNoTouchRepositoryIDs: Set(projection.permanentNoTouchRepositoryIDs),
                digest: snapshot.admissionSHA256)
        }
        #if SHADOW_SYNC_TESTING
        return try selectionPolicy(RepositoryPolicyLoader.load(rootPath: policyRootPath))
        #else
        throw SelectedRepositoryScopeError.policyUnavailable
        #endif
    }

    public func processFreeCatalog(
        preferences: RepositorySelectionPreferenceDocument?,
        canonicalLocators:
            [String: RepositorySelectionLocator] = [:],
        sessionEntries:
            [RepositorySelectionPreferenceEntry] = [],
        generation: UInt64
    ) throws -> RepositorySelectionCatalogResult {
        try processFreeCatalogBound(preferences: preferences, canonicalLocators: canonicalLocators,
            sessionEntries: sessionEntries, generation: generation, deadlineLimit: nil)
    }

    private func processFreeCatalogBound(preferences: RepositorySelectionPreferenceDocument?,
        canonicalLocators: [String: RepositorySelectionLocator] = [:],
        sessionEntries: [RepositorySelectionPreferenceEntry] = [], generation: UInt64,
        deadlineLimit: UInt64?, firstAdmissionHints: [RepositorySelectionLocator] = []
    ) throws -> RepositorySelectionCatalogResult {
        let deadline = boundedMetadataDeadline(deadlineLimit)
        #if SHADOW_SYNC_TESTING
        let previousDiagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.catalog)
        defer { DiscoveryFixtureDiagnostic.leaveCaller(previousDiagnosticCaller) }
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.root
        var diagnosticPassed = false
        defer {
            DiscoveryFixtureDiagnostic.record(.binder, stage: diagnosticStage,
                started: diagnosticStart, deadline: deadline, succeeded: diagnosticPassed)
        }
        #endif
        let root = try openRoot(deadline: deadline, lexicalHints: firstAdmissionHints)
        defer { close(root.descriptor) }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .projection
        #endif
        let projection = try activeSelectionPolicy()
        let rootSelectionIdentity =
            RepositorySelectionCatalogIdentity(
                device: root.identity.device,
                inode: root.identity.inode,
                owner: root.identity.owner
            )
        let catalogRoot = try RepositorySelectionCatalogRoot(
            logicalKey: logicalRoot,
            descriptor: root.descriptor,
            identity: rootSelectionIdentity
        )
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .metadata
        #endif
        let result = RepositorySelectionCatalogDiscovery.discoverCatalog(
            configuration: RepositorySelectionCatalogConfiguration(
                roots: [catalogRoot],
                policy: projection,
                preferences: preferences,
                canonicalLocators: canonicalLocators,
                sessionEntries: sessionEntries,
                generation: generation,
                limits: catalogLimits,
                deadlineUptimeNanoseconds: deadline,
                admission: admission,
                inspectRootRepository: snapshot == nil
            )
        )
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = result.isComplete
        #endif
        return result
    }

    public func bind(
        intent: RepositorySelectionIntent
    ) throws -> ValidatedSelectedRepositoryScope {
        try bindBound(intent: intent, deadlineLimit: nil)
    }

    private func boundedMetadataDeadline(_ limit: UInt64?) -> UInt64 {
        let fresh = DispatchTime.now().uptimeNanoseconds &+ catalogLimits.elapsedNanoseconds
        // An explicit command stage is independent of completed publisher setup.
        // Its absolute ceiling is never extended by a later catalog/bind call.
        if let limit { return min(fresh, limit) }
        return setupDeadline ?? fresh
    }

    private func bindBound(intent: RepositorySelectionIntent, deadlineLimit: UInt64?,
                           completedCatalog: RepositorySelectionCatalogResult? = nil)
        throws -> ValidatedSelectedRepositoryScope {
        guard !intent.entries.isEmpty else {
            throw SelectedRepositoryScopeError.invalidIntent
        }
        let deadline = boundedMetadataDeadline(deadlineLimit)
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.root
        var diagnosticPassed = false
        defer {
            DiscoveryFixtureDiagnostic.record(.selection, stage: diagnosticStage,
                started: diagnosticStart, deadline: deadline, succeeded: diagnosticPassed)
        }
        #endif
        let root = try openRoot(deadline: deadline,
            lexicalHints: Array(intent.entries.prefix(63).map(\.locator)))
        defer { close(root.descriptor) }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .projection
        #endif
        let projection = try activeSelectionPolicy()
        let rootSelectionIdentity =
            RepositorySelectionCatalogIdentity(
                device: root.identity.device,
                inode: root.identity.inode,
                owner: root.identity.owner
            )
        guard intent.policyDigest == projection.digest,
              intent.rootIdentities == [
                  logicalRoot: rootSelectionIdentity
              ] else {
            throw SelectedRepositoryScopeError.changed
        }
        let catalogRoot = try RepositorySelectionCatalogRoot(
            logicalKey: logicalRoot,
            descriptor: root.descriptor,
            identity: rootSelectionIdentity
        )
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .metadata
        #endif
        let catalog: RepositorySelectionCatalogResult
        if let completedCatalog {
            // Rebind alone supplies its immediately completed catalog. This is
            // advisory metadata from this call, never a saved access grant.
            // Live root/policy checks above and exact traversal below still run.
            catalog = completedCatalog
        } else {
            catalog = RepositorySelectionCatalogDiscovery.discoverCatalog(
                configuration: RepositorySelectionCatalogConfiguration(
                    roots: [catalogRoot],
                    policy: projection,
                    preferences: nil,
                    canonicalLocators: Dictionary(
                        uniqueKeysWithValues: intent.entries.map {
                            ($0.repositoryID, $0.locator)
                        }
                    ),
                    generation: intent.generation,
                    limits: catalogLimits,
                    deadlineUptimeNanoseconds: deadline,
                    admission: admission,
                    inspectRootRepository: snapshot == nil
                )
            )
        }
        guard catalog.isComplete else {
            if catalog.degradedReason == .cleanupPending { throw SelectedRepositoryScopeError.cleanupPending }
            throw SelectedRepositoryScopeError.catalogDegraded(
                catalog.degradedReason?.operatorExplanation
                    ?? "catalog incomplete"
            )
        }
        guard catalog.catalog.generation == intent.generation,
              catalog.catalog.policyDigest == intent.policyDigest,
              catalog.catalog.rootIdentities
                == intent.rootIdentities else {
            throw SelectedRepositoryScopeError.changed
        }
        var bound: [ValidatedSelectedRepository] = []
        for entry in intent.entries {
            #if SHADOW_SYNC_TESTING
            diagnosticStage = .decisions
            #endif
            guard entry.locator.governedRoot == logicalRoot else {
                throw SelectedRepositoryScopeError.forbidden(
                    entry.repositoryID
                )
            }
            let matches = catalog.catalog.candidates.filter {
                $0.id == entry.repositoryID
                    && $0.locator == entry.locator
            }
            guard matches.count == 1, let candidate = matches.first else {
                let idMatches = catalog.catalog.candidates.filter {
                    $0.id == entry.repositoryID
                        || $0.locator == entry.locator
                }
                throw idMatches.isEmpty
                    ? SelectedRepositoryScopeError.unknown(
                        entry.repositoryID
                    )
                    : SelectedRepositoryScopeError.ambiguous(
                        entry.repositoryID
                    )
            }
            guard candidate.isVisible,
                  candidate.isEligible,
                  candidate.policyDisposition == .writable,
                  candidate.catalogRootIdentity
                    == rootSelectionIdentity,
                  let expectedRepositoryIdentity =
                    intent.repositoryIdentities[entry],
                  candidate.catalogRepositoryIdentity
                    == expectedRepositoryIdentity,
                  !projection.isArtifactOrHiddenPrefix(
                      entry.locator.components
                  ) else {
                throw SelectedRepositoryScopeError.forbidden(
                    entry.repositoryID
                )
            }
            #if SHADOW_SYNC_TESTING
            diagnosticStage = .authorityBefore
            #endif
            let repository = try traverse(
                entry: entry,
                root: root,
                deadline: deadline
            )
            guard RepositorySelectionCatalogIdentity(
                device: repository.repositoryIdentity.device,
                inode: repository.repositoryIdentity.inode,
                owner: repository.repositoryIdentity.owner
            ) == expectedRepositoryIdentity else {
                throw SelectedRepositoryScopeError.changed
            }
            bound.append(repository)
        }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .postflight
        #endif
        var finalRoot = stat()
        guard fstat(root.descriptor, &finalRoot) == 0,
              FileIdentity(finalRoot) == root.identity else {
            throw SelectedRepositoryScopeError.changed
        }
        guard Set(bound.map(\.repositoryID)).count == bound.count,
              Set(bound.map(\.repositoryPath)).count == bound.count else {
            throw SelectedRepositoryScopeError.ambiguous(
                "duplicate selected scope"
            )
        }
        let governedRootRole: GovernedRootRole
        if let snapshot {
            governedRootRole = try GovernedRootRole(snapshot: snapshot)
        } else {
            #if SHADOW_SYNC_TESTING
            governedRootRole = .testing(policyDigest: projection.digest)
            #else
            throw SelectedRepositoryScopeError.policyUnavailable
            #endif
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
        return ValidatedSelectedRepositoryScope(
            selectionGeneration: intent.generation,
            policyDigest: projection.digest,
            catalogGeneration: catalog.catalog.generation,
            repositories: bound.sorted {
                $0.repositoryID == $1.repositoryID
                    ? $0.locator < $1.locator
                    : $0.repositoryID < $1.repositoryID
            },
            governedRootRole: governedRootRole
        )
    }

    /// Saved selection data is not a current policy decision. A new operation
    /// phase reclassifies it with this phase's resources and compares every
    /// identity before handing it to repository inspection.
    func rebind(_ scope: ValidatedSelectedRepositoryScope,
                deadlineLimit: UInt64? = nil) throws -> ValidatedSelectedRepositoryScope {
        // Catalog discovery and binding share one ceiling, including ordinary
        // reads with no enclosing command limit. Neither phase renews it.
        let stageDeadline = boundedMetadataDeadline(deadlineLimit)
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.prepare
        var diagnosticPassed = false
        defer {
            DiscoveryFixtureDiagnostic.record(.rebind, stage: diagnosticStage,
                started: diagnosticStart, deadline: stageDeadline, succeeded: diagnosticPassed)
        }
        #endif
        try revalidatePhase()
        guard !scope.repositories.isEmpty,
              scope.catalogGeneration == scope.selectionGeneration,
              Set(scope.repositories.map(\.repositoryID)).count == scope.repositories.count,
              Set(scope.repositories.map(\.locator)).count == scope.repositories.count,
              scope.policyDigest == (try activeSelectionPolicy()).digest else {
            throw SelectedRepositoryScopeError.changed
        }
        let entries = try scope.repositories.map {
            try RepositorySelectionPreferenceEntry(repositoryID: $0.repositoryID, locator: $0.locator)
        }.sorted()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .metadata
        #endif
        let catalog = try processFreeCatalogBound(preferences: nil,
            canonicalLocators: Dictionary(uniqueKeysWithValues: entries.map { ($0.repositoryID, $0.locator) }),
            generation: scope.selectionGeneration, deadlineLimit: stageDeadline,
            firstAdmissionHints: Array(entries.prefix(63).map(\.locator)))
        guard catalog.isComplete else {
            if catalog.degradedReason == .cleanupPending { throw SelectedRepositoryScopeError.cleanupPending }
            throw SelectedRepositoryScopeError.catalogDegraded(
                catalog.degradedReason?.operatorExplanation ?? "catalog incomplete")
        }
        let intent: RepositorySelectionIntent
        do { intent = try RepositorySelectionIntent(catalog: catalog.catalog, entries: entries) }
        catch { throw SelectedRepositoryScopeError.changed }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = .decisions
        #endif
        #if SHADOW_SYNC_TESTING
        try testingAfterRebindCatalog?()
        #endif
        let rebound = try bindBound(intent: intent, deadlineLimit: stageDeadline, completedCatalog: catalog)
        guard rebound == scope else {
            #if SHADOW_SYNC_TESTING
            DiscoveryFixtureDiagnostic.recordRebindMismatch(original: scope, current: rebound)
            #endif
            throw SelectedRepositoryScopeError.changed
        }
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
        return rebound
    }

    /// The enclosing factory retains the actual read or borrowed EX context.
    /// Validate again before returning a result, so cancellation, pending
    /// cleanup or revoked policy cannot publish a partial inventory as complete.
    func withReboundScope<Value>(_ scope: ValidatedSelectedRepositoryScope,
                                cancellation: CancellationToken, deadlineLimit: UInt64? = nil,
                                _ body: (ValidatedSelectedRepositoryScope) throws -> Value) throws -> Value {
        func validate() throws {
            guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            do {
                try revalidatePhase()
                try snapshot?.revalidate()
                try admission.validate(deadline: deadlineLimit ?? (DispatchTime.now().uptimeNanoseconds &+ catalogLimits.elapsedNanoseconds))
            } catch { throw Self.policyFailure(error) }
        }
        try validate()
        let rebound = try rebind(scope, deadlineLimit: deadlineLimit)
        try validate()
        let value = try body(rebound)
        try validate()
        return value
    }

    /// Metadata gets a distinct bounded stage after fresh selection binding.
    /// One deadline covers all paths in this stage; no per-path extension.
    func withDiscoveryPolicy<Value>(_ scope: ValidatedSelectedRepositoryScope,
                                    cancellation: CancellationToken,
                                    _ body: (RepositoryDiscoveryPolicy) throws -> Value) throws -> Value {
        try withReboundScope(scope, cancellation: cancellation) { rebound in
            #if SHADOW_SYNC_TESTING
            let diagnosticStart = DispatchTime.now().uptimeNanoseconds
            var diagnosticPassed = false
            defer {
                DiscoveryFixtureDiagnostic.record(.discovery, stage: .metadata,
                    started: diagnosticStart, deadline: nil, succeeded: diagnosticPassed)
            }
            #endif
            guard let snapshot else { throw SelectedRepositoryScopeError.policyUnavailable }
            let service = try RepositoryDiscoveryPolicy(scope: rebound, snapshot: snapshot,
                admission: admission, cancellation: cancellation, phase: revalidatePhase,
                deadline: DispatchTime.now().uptimeNanoseconds &+ catalogLimits.elapsedNanoseconds)
            defer { service.close() }
            do {
                let value = try body(service)
                #if SHADOW_SYNC_TESTING
                let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.finalValidation)
                defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
                #endif
                try service.validate()
                #if SHADOW_SYNC_TESTING
                diagnosticPassed = true
                #endif
                return value
            } catch {
                #if SHADOW_SYNC_TESTING
                let diagnosticCaller = DiscoveryFixtureDiagnostic.enterCaller(.errorValidation)
                defer { DiscoveryFixtureDiagnostic.leaveCaller(diagnosticCaller) }
                #endif
                try service.validate()
                throw error
            }
        }
    }

    /// A command is a separate bounded stage, not an extension of the metadata
    /// scan's 750ms deadline. The caller creates its budget once; rebinding and
    /// every classifier/identity check consume that same budget. The helper will
    /// independently authenticate policy and resources before actual execution.
    func withDiscoveryCommandPolicy<Value>(_ scope: ValidatedSelectedRepositoryScope,
        selected: ValidatedSelectedRepository, command: DiscoveryGitCommand,
        budget: CustodyBudget, cancellation: CancellationToken,
        _ body: (RepositoryDiscoveryCommandPolicy) throws -> Value
    ) throws -> Value {
        try budget.validate(kind: .discoveryGit, permittedWorkSeconds: command.workSeconds,
                            now: DispatchTime.now().uptimeNanoseconds)
        return try withReboundScope(scope, cancellation: cancellation, deadlineLimit: budget.work) { rebound in
            guard let snapshot, rebound.repositories.contains(selected) else {
                throw SelectedRepositoryScopeError.changed
            }
            let service = try RepositoryDiscoveryPolicy(scope: rebound, snapshot: snapshot,
                admission: admission, cancellation: cancellation, phase: revalidatePhase,
                deadline: budget.work)
            defer { service.close() }
            let commandPolicy = try RepositoryDiscoveryCommandPolicy(command: command, budget: budget,
                selected: selected, metadata: service, snapshot: snapshot,
                configurationAdmission: configurationAdmission)
            do {
                let result = try body(commandPolicy)
                try commandPolicy.validate()
                return result
            } catch {
                // Pending/sticky policy failure takes precedence over a caught
                // inner error or a nominal callback result.
                try commandPolicy.validate()
                throw error
            }
        }
    }

    func executeDiscovery(scope: ValidatedSelectedRepositoryScope, candidate: RepositoryCandidate,
                          command: DiscoveryGitCommand, cancellation: CancellationToken) throws -> CustodyRegistryResult {
        guard let discoveryTransport,
              let selected = scope.repositories.first(where: {
                  $0.repositoryID == candidate.id && $0.repositoryPath == candidate.path
              }) else { throw RepositoryDiscoveryExecutionError.commandAdapterUnavailable }
        // Construct once before rebinding. All policy, helper preflights and
        // final Git consume this original absolute budget.
        let budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: command.workSeconds)
        return try withDiscoveryCommandPolicy(scope, selected: selected, command: command,
            budget: budget, cancellation: cancellation) { policy in
            try discoveryTransport.execute(policy: policy, candidate: candidate)
        }
    }

    public func canonicalLocators(
        records: [RepositoryAuthorityRecord]
    ) -> [String: RepositorySelectionLocator] {
        records.reduce(into: [:]) { result, record in
            let root = URL(
                fileURLWithPath: governedRootPath,
                isDirectory: true
            ).standardizedFileURL.path
            let canonical = URL(
                fileURLWithPath: record.canonicalRoot,
                isDirectory: true
            ).standardizedFileURL.path
            let relative: String
            if canonical == root {
                relative = ""
            } else if canonical.hasPrefix(root + "/") {
                relative = String(
                    canonical.dropFirst(root.count + 1)
                )
            } else {
                return
            }
            let components = relative.isEmpty
                ? [] : relative.split(separator: "/").map(String.init)
            guard let locator = try? RepositorySelectionLocator(
                governedRoot: logicalRoot,
                components: components
            ) else {
                return
            }
            result[record.repositoryID] = locator
        }
    }

    public func canonicalRootPath(
        for locator: RepositorySelectionLocator
    ) -> String? {
        guard locator.governedRoot == logicalRoot else {
            return nil
        }
        let suffix = locator.components.joined(separator: "/")
        return suffix.isEmpty
            ? governedRootPath
            : governedRootPath + "/" + suffix
    }

    private struct OpenedRoot {
        let descriptor: Int32
        let physicalPath: String
        let identity: FileIdentity
    }

    /// Hints are bounded lexical input only. Reserve the first slot for root
    /// admission and preserve exact bytes when filtering and deduplicating.
    /// Inspect at most 63 hints, even when duplicates or unrelated roots occur.
    static func firstRootAdmissionPaths(root: String, projectionRoot: [String],
                                        lexicalHints: [RepositorySelectionLocator]) throws
        -> [RepositorySelectionAdmissionPath] {
        var paths = [try RepositorySelectionAdmissionPath(root: root, components: [])]
        var seen = Set<Data>()
        let prefix = projectionRoot.map { Data($0.utf8) }
        for hint in lexicalHints.prefix(63) {
            guard hint.governedRoot.utf8.elementsEqual(root.utf8),
                  hint.components.map({ Data($0.utf8) }).starts(with: prefix),
                  seen.insert(Data(hint.relativePath.utf8)).inserted else { continue }
            paths.append(try RepositorySelectionAdmissionPath(root: root, components: hint.components))
        }
        return paths
    }

    private func openRoot(deadline: UInt64, lexicalHints: [RepositorySelectionLocator] = []) throws -> OpenedRoot {
        try revalidatePhase()
        do {
            // Bind and rebind supply lexical hints. Classify them with the required root
            // in this invocation's first batch, before any root filesystem I/O.
            // Hint decisions never grant access; later exact admissions and
            // physical identity checks remain mandatory, including for root.
            let paths = try Self.firstRootAdmissionPaths(root: logicalRoot,
                projectionRoot: snapshot?.projection.rootComponents ?? [], lexicalHints: lexicalHints)
            guard case .allowed = try admission.classify(paths, deadline: deadline)[0] else {
                throw RepositorySelectionAdmissionError.unavailable
            }
        } catch { throw Self.policyFailure(error) }
        let descriptor = Darwin.open(
            governedRootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SelectedRepositoryScopeError.changed
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  FileIdentity(info).isDirectory,
                  info.st_uid == expectedUID,
                  (info.st_mode & 0o022) == 0 else {
                throw SelectedRepositoryScopeError.changed
            }
            let path = try descriptorPath(descriptor)
            return OpenedRoot(
                descriptor: descriptor,
                physicalPath: path,
                identity: FileIdentity(info)
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func traverse(
        entry: RepositorySelectionPreferenceEntry,
        root: OpenedRoot,
        deadline: UInt64
    ) throws -> ValidatedSelectedRepository {
        var current = dup(root.descriptor)
        guard current >= 0 else {
            throw SelectedRepositoryScopeError.unsafeTraversal(
                entry.repositoryID
            )
        }
        defer { close(current) }
        var identity = root.identity
        for (index, component) in entry.locator.components.enumerated() {
            do {
                try admission.requireAllowed(RepositorySelectionAdmissionPath(
                    root: logicalRoot, components: Array(entry.locator.components.prefix(index + 1))),
                    deadline: deadline)
            } catch { throw Self.policyFailure(error) }
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw SelectedRepositoryScopeError.changed
            }
            close(current)
            current = next
            var info = stat()
            guard fstat(current, &info) == 0,
                  FileIdentity(info).isDirectory,
                  info.st_uid == expectedUID,
                  (info.st_mode & 0o022) == 0 else {
                throw SelectedRepositoryScopeError.unsafeTraversal(
                    entry.repositoryID
                )
            }
            identity = FileIdentity(info)
            var rootInfo = stat()
            guard fstat(root.descriptor, &rootInfo) == 0,
                  FileIdentity(rootInfo) == root.identity else {
                throw SelectedRepositoryScopeError.changed
            }
        }
        var gitInfo = stat()
        guard fstatat(
            current,
            ".git",
            &gitInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              (gitInfo.st_mode & S_IFMT) == S_IFDIR
                || (gitInfo.st_mode & S_IFMT) == S_IFREG else {
            throw SelectedRepositoryScopeError.changed
        }
        let physical = try descriptorPath(current)
        guard physical == root.physicalPath
                + "/" + entry.locator.relativePath else {
            throw SelectedRepositoryScopeError.changed
        }
        return ValidatedSelectedRepository(
            repositoryID: entry.repositoryID,
            locator: entry.locator,
            governedRootPath: root.physicalPath,
            policyRootPath: policyRootPath,
            repositoryPath: physical,
            rootIdentity: root.identity,
            repositoryIdentity: identity
        )
    }

    #if SHADOW_SYNC_TESTING
    private func selectionPolicy(
        _ policy: RepositoryPolicy
    ) throws -> RepositorySelectionPolicy {
        func prefixed(_ path: String) -> String {
            let prefix = policyPathPrefix.joined(separator: "/")
            guard !prefix.isEmpty else { return path }
            return path == "." ? prefix : prefix + "/" + path
        }
        let shelves = policyPathPrefix.isEmpty
            ? [
                ["capabilities"],
                ["personal"],
                ["fixture-owner", "src"],
                ["fixture-owner", "vendor"],
            ]
            : [
                policyPathPrefix,
                policyPathPrefix + ["capabilities"],
                policyPathPrefix + ["personal"],
                policyPathPrefix + ["fixture-owner", "src"],
                policyPathPrefix + ["fixture-owner", "vendor"],
            ]
        return try RepositorySelectionPolicy(
            shelfPaths: shelves,
            excludedPaths: policy.excludedPaths.map(prefixed),
            readOnlyPaths: policy.readOnlyPaths.map(prefixed),
            artifactPaths: policy.artifactPaths.map(prefixed),
            writablePaths: policyPathPrefix.isEmpty
                ? [] : [
                    policyPathPrefix.joined(separator: "/"),
                ],
            permanentNoTouchRepositoryIDs: policy.excludedOrigins,
            digest: policy.admissionSHA256
        )
    }

    #endif

    private func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw SelectedRepositoryScopeError.changed
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }
}
