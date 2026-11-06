import Darwin
import Foundation

enum RepositoryDiscoveryExecutionError: Error {
    case commandAdapterUnavailable
}

public struct RepositoryDiscovery: SelectedRepositoryDiscovering {
    private static let productionDirectoryLimit = 20_000
    private let account: EffectiveAccount?
    private let directoryLimit: Int
    private let usesLegacyCloneWideEligibility: Bool
    #if SHADOW_SYNC_TESTING
    private let scanObserver: (@Sendable (String) -> Void)?
    private let gitObserver: (@Sendable ([String]) -> Void)?
    private let gitCandidateObserver:
        (@Sendable (String, [String]) -> Void)?
    #endif

    public init() {
        account = nil
        directoryLimit = Self.productionDirectoryLimit
        usesLegacyCloneWideEligibility = false
        #if SHADOW_SYNC_TESTING
        scanObserver = nil
        gitObserver = nil
        gitCandidateObserver = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        testingHomeDirectory: String,
        testingDirectoryLimit: Int = 20_000,
        repositoryCentric: Bool = false,
        scanObserver: (@Sendable (String) -> Void)? = nil,
        gitObserver: (@Sendable ([String]) -> Void)? = nil,
        gitCandidateObserver:
            (@Sendable (String, [String]) -> Void)? = nil
    ) throws {
        guard testingDirectoryLimit > 0 else {
            throw M1RepositoryDiscoveryError.scanBudgetExceeded
        }
        account = try EffectiveAccount.isolated(homeDirectory: testingHomeDirectory)
        directoryLimit = testingDirectoryLimit
        usesLegacyCloneWideEligibility = !repositoryCentric
        self.scanObserver = scanObserver
        self.gitObserver = gitObserver
        self.gitCandidateObserver = gitCandidateObserver
    }
    #endif

    #if SHADOW_SYNC_TESTING
    public func discover() throws -> [RepositoryCandidate] {
        return try RuntimeFixtureSession.withLegacyDiscovery {
        let effectiveAccount: EffectiveAccount
        if let account {
            effectiveAccount = account
        } else {
            do {
                effectiveAccount = try EffectiveAccount.current()
            } catch {
                throw M1RepositoryDiscoveryError.accountUnavailable
            }
        }
        let requestedRoot = URL(fileURLWithPath: effectiveAccount.homeDirectory)
            .appendingPathComponent("dev", isDirectory: true).path
        let rootDescriptor = Darwin.open(
            requestedRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw M1RepositoryDiscoveryError.requiredRootUnavailable
        }
        defer { close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == effectiveAccount.uid else {
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        let rootPath = try Self.descriptorPath(rootDescriptor)
        let policy: RepositoryPolicy
        do {
            policy = try RepositoryPolicyLoader.load(rootPath: rootPath)
        } catch {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }

        var rows: [String: AccumulatedCandidate] = [:]
        var scannedDirectories = 0
        try scan(
            path: rootPath,
            relativePath: ".",
            isUmbrella: true,
            inheritedPolicyBlock: nil,
            account: effectiveAccount,
            policy: policy,
            scannedDirectories: &scannedDirectories,
            rows: &rows
        )
        return validate(
            rows: rows,
            account: effectiveAccount
        )
        }
    }
    #endif

    public func discover(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> [RepositoryCandidate] {
        #if SHADOW_SYNC_TESTING
        return try RuntimeFixtureSession.withLegacyDiscovery {
        let effectiveAccount: EffectiveAccount
        if let account {
            effectiveAccount = account
        } else {
            effectiveAccount = try EffectiveAccount.current()
        }
        var rows: [String: AccumulatedCandidate] = [:]
        var scannedDirectories = 0
        for selected in scope.repositories {
            let policy = try RepositoryPolicyLoader.load(
                rootPath: selected.policyRootPath
            )
            guard policy.admissionSHA256 == scope.policyDigest else {
                throw SelectedRepositoryScopeError.changed
            }
            try scan(
                path: selected.repositoryPath,
                relativePath: selected.locator.relativePath,
                isUmbrella: false,
                inheritedPolicyBlock: nil,
                account: effectiveAccount,
                policy: policy,
                scannedDirectories: &scannedDirectories,
                rows: &rows
            )
        }
        let candidates = validate(
            rows: rows,
            account: effectiveAccount
        )
        guard candidates.count == scope.repositories.count,
              candidates.allSatisfy(scope.admits),
              scope.repositories.allSatisfy({ selected in
                  candidates.contains {
                      $0.id == selected.repositoryID
                          && $0.path == selected.repositoryPath
                  }
              }) else {
            throw GitSafetyError.unsafeRepository(
                "selected discovery returned foreign or missing repository data"
            )
        }
        return candidates
        }
        #else
        throw SelectedRepositoryScopeError.policyUnavailable
        #endif
    }

    /// Metadata authority alone does not grant a command transport. Production
    /// inventory uses the phase-bound binder overload below.
    func discover(scope: ValidatedSelectedRepositoryScope,
                  policy service: RepositoryDiscoveryPolicy) throws -> [RepositoryCandidate] {
        _ = try discoverMetadata(scope: scope, policy: service)
        throw RepositoryDiscoveryExecutionError.commandAdapterUnavailable
    }

    func discover(scope: ValidatedSelectedRepositoryScope,
                  binder: SelectedRepositoryScopeBinder,
                  cancellation: CancellationToken) throws -> [RepositoryCandidate] {
        let (effectiveAccount, candidates) = try binder.withDiscoveryPolicy(scope, cancellation: cancellation) { service in
            (service.account, try discoverMetadata(scope: scope, policy: service))
        }
        // The metadata callback has closed. Each command allocates its original
        // budget before rebinding; local reads receive their own short admission.
        let probe = DiscoveryGitProbe(account: effectiveAccount, binder: binder, scope: scope, cancellation: cancellation)
        var validated: [RepositoryCandidate] = []
        for candidate in candidates {
            guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                throw GitSafetyError.cancelled
            }
            guard candidate.isEligible else { validated.append(candidate); continue }
            do {
                let inspection = try probe.validate(candidate)
                var inspected = Self.withCachedRelation(candidate, relation: inspection.cachedMainRelation)
                if usesLegacyCloneWideEligibility, let reason = inspection.blockedReason {
                    inspected = Self.blocked(inspected, reason: reason)
                }
                validated.append(inspected)
            } catch let error as SelectedRepositoryScopeError {
                // Revocation and unresolved cleanup cannot become an ordinary
                // disabled row followed by further repository admissions.
                throw error
            } catch RepositoryDiscoveryExecutionError.commandAdapterUnavailable {
                throw RepositoryDiscoveryExecutionError.commandAdapterUnavailable
            } catch GitSafetyError.cancelled {
                throw GitSafetyError.cancelled
            } catch GitSafetyError.originChanged {
                validated.append(Self.blockedWithoutCanonicalIdentity(candidate, reason: .originChanged))
            } catch GitSafetyError.repositoryRemoved {
                validated.append(Self.blockedWithoutCanonicalIdentity(candidate, reason: .repositoryUnavailable))
            } catch GitSafetyError.customTransport {
                validated.append(Self.blocked(candidate, reason: .unsupportedGitConfiguration))
            } catch GitSafetyError.malformedConfig {
                validated.append(Self.blocked(candidate, reason: .unsupportedGitConfiguration))
            } catch {
                validated.append(Self.blocked(candidate, reason: .localStateUnverifiable))
            }
        }
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw GitSafetyError.cancelled
        }
        return Self.operatorSortedCandidates(validated)
    }

    func discoverMetadata(scope: ValidatedSelectedRepositoryScope,
                          policy service: RepositoryDiscoveryPolicy) throws -> [RepositoryCandidate] {
        try service.validate()
        guard service.scope == scope, account == nil || account == service.account else {
            throw SelectedRepositoryScopeError.changed
        }
        var rows: [String: AccumulatedCandidate] = [:]
        for selected in scope.repositories {
            let names = [".git", ".git/config", ".git/config.worktree", ".git/commondir",
                ".git/objects", ".git/objects/info/alternates", ".git/info/grafts", ".git/refs/replace",
                ".git/worktrees"] + service.policy.hookAdmissionRelativePaths()
            // All names are lexical inputs from the bound selection and policy.
            // Include them in the first classification, before requireSelected
            // can inspect a directory. Every later access still consumes its
            // exact decision with fresh authority checks and the same deadline.
            for offset in stride(from: 0, to: names.count, by: 64) {
                try service.prepareAccess(names[offset..<min(offset + 64, names.count)]
                    .map { selected.repositoryPath + "/" + $0 })
            }
            try service.requireSelected(selected)
            // A selected path is exact. Missing metadata cannot start a recursive
            // search for another checkout beneath that path.
            let relative = try service.policyRelativePath(selected.repositoryPath)
            guard let found = try inspectRepository(representationPath: selected.repositoryPath,
                relativePath: relative, account: service.account, policy: service.policy,
                inheritedPolicyBlock: nil, admission: service) else {
                throw SelectedRepositoryScopeError.changed
            }
            guard rows[found.deduplicationKey] == nil else { throw SelectedRepositoryScopeError.changed }
            rows[found.deduplicationKey] = found
            try service.requireSelected(selected)
        }
        let candidates = rows.values.map(\.resolvedCandidate).sorted { $0.id < $1.id }
        guard candidates.count == scope.repositories.count, candidates.allSatisfy(scope.admits),
              scope.repositories.allSatisfy({ selected in
                  candidates.contains { $0.id == selected.repositoryID && $0.path == selected.repositoryPath }
              }) else { throw SelectedRepositoryScopeError.changed }
        try service.validate()
        return candidates
    }

    private func validate(
        rows: [String: AccumulatedCandidate],
        account effectiveAccount: EffectiveAccount
    ) -> [RepositoryCandidate] {
        #if SHADOW_SYNC_TESTING
        let gitProbe = DiscoveryGitProbe(
            account: effectiveAccount,
            observer: gitObserver,
            candidateObserver: gitCandidateObserver
        )
        #else
        let gitProbe = DiscoveryGitProbe(account: effectiveAccount)
        #endif
        let candidates = rows.values.map(\.resolvedCandidate)
        let validation = RepositoryDiscoveryValidation()
        let validationQueue = OperationQueue()
        validationQueue.maxConcurrentOperationCount = min(
            16,
            max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
        )
        validationQueue.qualityOfService = .userInitiated
        for candidate in candidates {
            validationQueue.addOperation {
                guard candidate.isEligible else {
                    validation.record(candidate)
                    return
                }
                do {
                    let inspection = try gitProbe.validate(candidate)
                    var inspected = Self.withCachedRelation(
                        candidate,
                        relation: inspection.cachedMainRelation
                    )
                    if usesLegacyCloneWideEligibility,
                       let reason = inspection.blockedReason {
                        inspected = Self.blocked(
                            inspected,
                            reason: reason
                        )
                    }
                    validation.record(inspected)
                } catch GitSafetyError.originChanged {
                    validation.record(
                        Self.blockedWithoutCanonicalIdentity(
                            candidate,
                            reason: .originChanged
                        )
                    )
                } catch GitSafetyError.repositoryRemoved {
                    validation.record(
                        Self.blockedWithoutCanonicalIdentity(
                            candidate,
                            reason: .repositoryUnavailable
                        )
                    )
                } catch GitSafetyError.customTransport(_) {
                    validation.record(
                        Self.blocked(
                            candidate,
                            reason: .unsupportedGitConfiguration
                        )
                    )
                } catch GitSafetyError.malformedConfig(_) {
                    validation.record(
                        Self.blocked(
                            candidate,
                            reason: .unsupportedGitConfiguration
                        )
                    )
                } catch {
                    validation.record(
                        Self.blocked(
                            candidate,
                            reason: .localStateUnverifiable
                        )
                    )
                }
            }
        }
        validationQueue.waitUntilAllOperationsAreFinished()
        return Self.operatorSortedCandidates(validation.candidates)
    }

    private static func operatorSortedCandidates(_ candidates: [RepositoryCandidate]) -> [RepositoryCandidate] {
        candidates.sorted { lhs, rhs in
            let left = RepositoryOperatorPresentation.primaryName(lhs)
                .precomposedStringWithCanonicalMapping
                .lowercased()
            let right = RepositoryOperatorPresentation.primaryName(rhs)
                .precomposedStringWithCanonicalMapping
                .lowercased()
            if left != right {
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            let leftLocation =
                RepositoryOperatorPresentation.secondaryLocation(lhs) ?? ""
            let rightLocation =
                RepositoryOperatorPresentation.secondaryLocation(rhs) ?? ""
            if leftLocation != rightLocation {
                return leftLocation.localizedStandardCompare(rightLocation)
                    == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    static func validateRuntimeEligibility(
        _ candidate: RepositoryCandidate,
        account: EffectiveAccount
    ) throws {
        guard candidate.isEligible else {
            throw GitSafetyError.unsafeRepository(
                "blocked repository entered worker admission"
            )
        }
        let requestedRoot = URL(fileURLWithPath: account.homeDirectory)
            .appendingPathComponent("dev", isDirectory: true).path
        let rootDescriptor = Darwin.open(
            requestedRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw M1RepositoryDiscoveryError.requiredRootUnavailable
        }
        defer { close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == account.uid else {
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        let rootPath = try descriptorPath(rootDescriptor)
        guard isContained(candidate.path, root: rootPath) else {
            throw GitSafetyError.unsafeRepository("repository left the governed root")
        }
        let policy = try RepositoryPolicyLoader.load(rootPath: rootPath)
        let relative = relativePath(candidate.path, root: rootPath)
        let origin = GitHubIdentity.parse(candidate.rawOrigin)
        guard origin != nil,
              candidate.originIdentity == origin,
              candidate.id.lowercased() == origin?.canonicalName,
              policy.pathDisposition(relativePath: relative) == .allowed,
              !policy.excludedOrigins.contains(origin!.canonicalName) else {
            throw GitSafetyError.unsafeRepository("repository became policy-excluded")
        }
        let expectedLocation = relative == "." ? "~/dev" : "~/dev/\(relative)"
        guard candidate.presentationLocation == expectedLocation,
              Self.hasNoUnsafeGraphMetadata(candidate.path) else {
            throw GitSafetyError.unsafeRepository(
                "repository identity or graph metadata changed"
            )
        }
        guard !policy.hasUnsupportedHookMarker(repositoryPath: candidate.path) else {
            throw GitSafetyError.unsupportedHookFramework
        }
        guard candidate.policyAdmissionSHA256 == policy.admissionSHA256,
              let hookAdmissionSHA256 = policy.hookAdmissionSHA256(
                  repositoryPath: candidate.path
              ),
              candidate.hookAdmissionSHA256 == hookAdmissionSHA256 else {
            throw GitSafetyError.unsafeRepository(
                "repository policy or hook snapshot changed"
            )
        }
        let topology: [RepositoryLinkedWorktree]
        do {
            topology = try Self.registeredLinkedWorktrees(
                commonDirectory: candidate.path + "/.git",
                rootPath: rootPath,
                account: account
            )
        } catch {
            throw GitSafetyError.unsafeRepository(
                "linked worktree topology changed"
            )
        }
        guard topology == candidate.linkedWorktrees,
              topology.map(\.path) == candidate.linkedWorktreePaths,
              !topology.contains(where: {
                  $0.headValue == "ref: refs/heads/main"
              }) else {
            throw GitSafetyError.unsafeRepository(
                "linked worktree topology changed"
            )
        }
    }

    static func validateRuntimeEligibility(
        _ operation: PlannedOperation,
        account: EffectiveAccount,
        stateLocation: StateLocation? = nil,
        governedRootPath: String? = nil
    ) throws {
        guard operation.isSelectable,
              operation.target.repository.policyCategory == .writable,
              operation.target.canonicalClone.isAuthorityEligible else {
            throw GitSafetyError.unsafeRepository(
                "Repository operation is not eligible"
            )
        }
        if operation.kind == .fastForward {
            switch operation.target.mode {
            case .checkedOut:
                guard let worktree = operation.target.worktree,
                      worktree.verification == .verified else {
                    throw GitSafetyError.unsafeRepository(
                        "Fast-forward worktree is not eligible"
                    )
                }
            case .refOnly:
                guard operation.target.worktree == nil,
                      operation.target.expectedLocalOID != nil,
                      operation.target.operationHookSHA256 != nil,
                      operation.target.registrationSetSHA256
                        != nil,
                      operation.target.preservationSHA256
                        != nil else {
                    throw GitSafetyError.unsafeRepository(
                        "Ref-only Fast-forward evidence is incomplete"
                    )
                }
            default:
                throw GitSafetyError.unsafeRepository(
                    "Fast-forward target mode is not eligible"
                )
            }
        }
        let authorityState = try SecureStateDirectory.openExisting(
            stateLocation ?? (try StateLocation.production())
        )
        let authoritySnapshot = RepositoryAuthorityStore(
            state: authorityState
        ).snapshot()
        let authorityMatches = authoritySnapshot.usableRecords.filter {
            $0.repositoryID == operation.target.repository.id
                && $0.matches(operation.target.canonicalClone)
        }
        guard authoritySnapshot.status == .available,
              authorityMatches.count == 1 else {
            throw GitSafetyError.unsafeRepository(
                "canonical update authority changed"
            )
        }
        let candidate = operation.target.canonicalClone.sourceSnapshot
        let requestedRoot = governedRootPath
            ?? URL(fileURLWithPath: account.homeDirectory)
                .appendingPathComponent("dev", isDirectory: true).path
        let rootDescriptor = Darwin.open(
            requestedRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw M1RepositoryDiscoveryError.requiredRootUnavailable
        }
        defer { close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == account.uid else {
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        let rootPath = try descriptorPath(rootDescriptor)
        guard isContained(candidate.path, root: rootPath) else {
            throw GitSafetyError.unsafeRepository(
                "physical clone left the governed root"
            )
        }
        let policy = try RepositoryPolicyLoader.load(rootPath: rootPath)
        let relative = relativePath(candidate.path, root: rootPath)
        guard let origin = GitHubIdentity.parse(candidate.rawOrigin),
              origin == candidate.originIdentity,
              origin.canonicalName == operation.target.repository.id,
              candidate.rootIdentity
                == operation.target.canonicalClone.rootIdentity,
              candidate.commonDirectoryIdentity
                == operation.target.canonicalClone.commonDirectoryIdentity else {
            throw GitSafetyError.unsafeRepository(
                "Operation repository identity changed"
            )
        }
        #if SHADOW_SYNC_TESTING
        let legacyFixtureRoot = origin.canonicalName == "fixture-owner/dev" && relative == "."
        #else
        let legacyFixtureRoot = false
        #endif
        guard policy.pathDisposition(relativePath: relative) == .allowed,
              !policy.excludedOrigins.contains(origin.canonicalName) || legacyFixtureRoot else {
            throw GitSafetyError.unsafeRepository(
                "Operation policy eligibility changed"
            )
        }
        guard candidate.policyAdmissionSHA256
                == policy.admissionSHA256 else {
            throw GitSafetyError.unsafeRepository(
                "Operation policy snapshot changed"
            )
        }
        guard Self.hasNoUnsafeGraphMetadata(candidate.path) else {
            throw GitSafetyError.unsafeRepository(
                "Operation graph metadata changed"
            )
        }
        // V2 discovery admits operations from verified target evidence even
        // when unrelated stale registrations need Repair. The transactions
        // re-open and revalidate the exact target, refs, configuration,
        // preservation evidence, and Repair set before every mutation.
        // Requiring every legacy registration to resolve here would make an
        // exact stale-registration Repair invalidate itself.
    }

    static func validateRemovalRuntimeEligibility(
        _ candidate: RepositoryCandidate,
        repositoryID: String,
        account: EffectiveAccount
    ) throws {
        guard candidate.isEligible else {
            throw GitSafetyError.unsafeRepository(
                "blocked repository entered removal admission"
            )
        }
        let requestedRoot = URL(fileURLWithPath: account.homeDirectory)
            .appendingPathComponent("dev", isDirectory: true).path
        let rootDescriptor = Darwin.open(
            requestedRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw M1RepositoryDiscoveryError.requiredRootUnavailable
        }
        defer { close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == account.uid else {
            throw M1RepositoryDiscoveryError.locationUnavailable
        }
        let rootPath = try descriptorPath(rootDescriptor)
        guard isContained(candidate.path, root: rootPath) else {
            throw GitSafetyError.unsafeRepository(
                "canonical clone left the governed root"
            )
        }
        let policy = try RepositoryPolicyLoader.load(
            rootPath: rootPath
        )
        let relative = relativePath(candidate.path, root: rootPath)
        guard let origin = GitHubIdentity.parse(candidate.rawOrigin),
              origin == candidate.originIdentity,
              origin.canonicalName == repositoryID,
              policy.pathDisposition(relativePath: relative) == .allowed,
              !policy.excludedOrigins.contains(origin.canonicalName),
              candidate.presentationLocation
                == (relative == "."
                    ? "~/dev" : "~/dev/\(relative)"),
              candidate.policyAdmissionSHA256
                == policy.admissionSHA256,
              Self.hasNoUnsafeGraphMetadata(candidate.path) else {
            throw GitSafetyError.unsafeRepository(
                "removal policy or repository identity changed"
            )
        }
        let topology = try registeredLinkedWorktrees(
            commonDirectory: candidate.path + "/.git",
            rootPath: rootPath,
            account: account,
            allowExternal: true
        )
        // Earlier admitted removals in this same immutable batch may
        // legitimately shrink the registered topology. A new or changed
        // registration is never accepted; target/backlink checks below
        // still require the exact selected entity to remain present.
        guard topology.allSatisfy({
            candidate.linkedWorktrees.contains($0)
        }) else {
            throw GitSafetyError.unsafeRepository(
                "repository worktree topology changed"
            )
        }
    }

    #if SHADOW_SYNC_TESTING
    static func testingLinkedCommonDirectory(
        markerPath: String,
        account: EffectiveAccount
    ) throws -> String {
        try resolveLinkedCommonDirectory(markerPath: markerPath, account: account)
    }

    static func testingRegisteredLinkedWorktrees(
        commonDirectory: String,
        rootPath: String,
        account: EffectiveAccount
    ) throws -> [RepositoryLinkedWorktree] {
        try registeredLinkedWorktrees(
            commonDirectory: commonDirectory,
            rootPath: rootPath,
            account: account
        )
    }

    static func testingMatchesRegisteredRepresentation(
        rootIdentity: RepositoryDirectoryIdentity,
        linkedWorktrees: [RepositoryLinkedWorktree]
    ) -> Bool {
        matchesRegisteredRepresentation(
            rootIdentity: rootIdentity,
            linkedWorktrees: linkedWorktrees
        )
    }
    #endif

    private enum CandidateProvenance: Int {
        case staleLinkedRepresentation
        case registeredLinkedRepresentation
        case primaryRepresentation
        case primarySafetyFailure
    }

    private struct AccumulatedCandidate {
        var candidate: RepositoryCandidate
        var provenance: CandidateProvenance

        var deduplicationKey: String {
            if let identity = candidate.commonDirectoryIdentity {
                return "common:\(identity.device):\(identity.inode)"
            }
            if let identity = candidate.rootIdentity {
                return "root:\(identity.device):\(identity.inode)"
            }
            return "path:\(candidate.path)"
        }

        var resolvedCandidate: RepositoryCandidate {
            guard provenance == .primaryRepresentation
                    || provenance == .primarySafetyFailure
                    || !candidate.isEligible else {
                return RepositoryDiscovery.blocked(
                    candidate,
                    reason: .unsafeWorktreeTopology
                )
            }
            return candidate
        }

        mutating func merge(_ other: AccumulatedCandidate) {
            if other.provenance.rawValue > provenance.rawValue {
                self = other
                return
            }
            guard other.provenance == provenance,
                  candidate != other.candidate else {
                return
            }

            if candidate.blockedReason == nil,
               other.candidate.blockedReason != nil {
                candidate = other.candidate
            } else if candidate.blockedReason != nil,
                      other.candidate.blockedReason != nil,
                      other.candidate.blockedReason!.rawValue
                        .localizedStandardCompare(candidate.blockedReason!.rawValue)
                        == .orderedAscending {
                candidate = other.candidate
            } else if candidate.blockedReason == nil {
                candidate = RepositoryDiscovery.blocked(
                    candidate,
                    reason: .unsafeWorktreeTopology
                )
            }
        }
    }

    private func scan(
        path: String,
        relativePath: String,
        isUmbrella: Bool,
        inheritedPolicyBlock: RepositoryBlockReason?,
        account: EffectiveAccount,
        policy: RepositoryPolicy,
        scannedDirectories: inout Int,
        rows: inout [String: AccumulatedCandidate]
    ) throws {
        guard scannedDirectories < directoryLimit else {
            throw M1RepositoryDiscoveryError.scanBudgetExceeded
        }
        let disposition = policy.pathDisposition(
            relativePath: relativePath
        )
        if !isUmbrella, disposition == .artifact {
            return
        }
        let policyBlock = inheritedPolicyBlock
            ?? Self.blockReason(for: disposition)
        scannedDirectories += 1
        #if SHADOW_SYNC_TESTING
        scanObserver?(path)
        #endif

        if let discovered = try inspectRepository(
            representationPath: path,
            relativePath: relativePath,
            account: account,
            policy: policy,
            inheritedPolicyBlock: policyBlock
        ) {
            let key = discovered.deduplicationKey
            if var existing = rows[key] {
                existing.merge(discovered)
                rows[key] = existing
            } else {
                rows[key] = discovered
            }
            if !isUmbrella {
                return
            }
        }

        let scanDescriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard scanDescriptor >= 0 else {
            if isUmbrella {
                throw M1RepositoryDiscoveryError.locationUnavailable
            }
            return
        }
        var scanInfo = stat()
        guard fstat(scanDescriptor, &scanInfo) == 0,
              FileIdentity(scanInfo).isDirectory,
              scanInfo.st_uid == account.uid,
              (try? Self.descriptorPath(scanDescriptor)) == path else {
            close(scanDescriptor)
            if isUmbrella {
                throw M1RepositoryDiscoveryError.locationUnavailable
            }
            return
        }
        let children: [String]
        do {
            children = try Self.directoryEntryNames(
                descriptor: scanDescriptor
            ).sorted()
        } catch {
            close(scanDescriptor)
            if isUmbrella {
                throw M1RepositoryDiscoveryError.locationUnavailable
            }
            return
        }
        close(scanDescriptor)
        let pruned = Set([
            ".git", ".build", ".cache", ".cursor", ".swiftpm",
            "node_modules", ".venv", "venv", ".next", "dist", "build", "target",
        ])
        for name in children {
            guard !name.isEmpty,
                  name != ".", name != "..",
                  !name.contains("/"),
                  !name.contains("\0"),
                  !name.hasPrefix("."),
                  !pruned.contains(name) else {
                continue
            }
            let childRelative = relativePath == "." ? name : "\(relativePath)/\(name)"
            let childDisposition = policy.pathDisposition(
                relativePath: childRelative
            )
            if childDisposition == .artifact {
                continue
            }
            let child = URL(fileURLWithPath: path)
                .appendingPathComponent(name, isDirectory: true).path
            var info = stat()
            guard lstat(child, &info) == 0 else {
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == account.uid else {
                continue
            }
            let descriptor = Darwin.open(
                child,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                continue
            }
            let canonical: String?
            var openedInfo = stat()
            if fstat(descriptor, &openedInfo) == 0,
               FileIdentity(openedInfo).isDirectory,
               openedInfo.st_uid == account.uid {
                canonical = try? Self.descriptorPath(descriptor)
            } else {
                canonical = nil
            }
            close(descriptor)
            guard let canonical,
                  Self.isContained(canonical, root: pathForRoot(path, relativePath: relativePath))
            else {
                continue
            }
            try scan(
                path: canonical,
                relativePath: childRelative,
                isUmbrella: false,
                inheritedPolicyBlock: policyBlock
                    ?? Self.blockReason(for: childDisposition),
                account: account,
                policy: policy,
                scannedDirectories: &scannedDirectories,
                rows: &rows
            )
        }
    }

    private func inspectRepository(
        representationPath: String,
        relativePath: String,
        account: EffectiveAccount,
        policy: RepositoryPolicy,
        inheritedPolicyBlock: RepositoryBlockReason?,
        admission: RepositoryDiscoveryPolicy? = nil
    ) throws -> AccumulatedCandidate? {
        try admission?.willAccess(representationPath)
        let gitMarker = URL(fileURLWithPath: representationPath)
            .appendingPathComponent(".git").path
        try admission?.willAccess(gitMarker)
        var markerInfo = stat()
        guard lstat(gitMarker, &markerInfo) == 0 else {
            return nil
        }
        let isPrimaryRepresentation: Bool
        let primaryPath: String
        if (markerInfo.st_mode & S_IFMT) == S_IFDIR {
            isPrimaryRepresentation = true
            primaryPath = representationPath
        } else if (markerInfo.st_mode & S_IFMT) == S_IFREG,
                  markerInfo.st_uid == account.uid,
                  markerInfo.st_nlink == 1,
                  let resolved = try? Self.resolveLinkedCommonDirectory(
                      markerPath: gitMarker,
                      account: account, admission: admission
                  ) {
            isPrimaryRepresentation = false
            primaryPath = URL(fileURLWithPath: resolved)
                .deletingLastPathComponent().path
        } else {
            try admission?.validate()
            return nil
        }
        try admission?.willAccess(primaryPath)
        let rootPath = pathForRoot(representationPath, relativePath: relativePath)
        guard Self.isContained(primaryPath, root: rootPath) else {
            return nil
        }
        let primaryRelative = Self.relativePath(
            primaryPath,
            root: rootPath
        )
        let primaryDisposition = policy.pathDisposition(
            relativePath: primaryRelative
        )
        if primaryDisposition == .artifact {
            return nil
        }
        let presentationLocation = try admission?.presentationLocation(primaryPath)
            ?? (primaryRelative == "." ? "~/dev" : "~/dev/\(primaryRelative)")
        for name in [".git", ".git/config", ".git/config.worktree", ".git/commondir"] {
            try admission?.willAccess(primaryPath + "/" + name)
        }
        var candidate: RepositoryCandidate
        do {
            candidate = try RepositoryHandle.discoveryCandidate(
                path: primaryPath,
                presentationLocation: presentationLocation
            )
        } catch {
            try admission?.validate()
            guard let fallback = Self.safeLocalCandidate(
                path: primaryPath,
                location: presentationLocation,
                account: account,
                reason: .unsafeGitMetadata
            ) else {
                return nil
            }
            return AccumulatedCandidate(
                candidate: fallback,
                provenance: isPrimaryRepresentation
                    ? .primarySafetyFailure
                    : .staleLinkedRepresentation
            )
        }
        if policy.identityBlockReason(origin: candidate.originIdentity) == .permanentNoTouch {
            return AccumulatedCandidate(
                candidate: Self.blocked(candidate, reason: .permanentNoTouch),
                provenance: isPrimaryRepresentation
                    ? .primarySafetyFailure : .registeredLinkedRepresentation
            )
        }
        if let policyBlock = inheritedPolicyBlock
            ?? Self.blockReason(for: primaryDisposition) {
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    candidate,
                    reason: policyBlock
                ),
                provenance: isPrimaryRepresentation
                    ? .primarySafetyFailure
                    : .registeredLinkedRepresentation
            )
        }
        if let candidateBlock = candidate.blockedReason {
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    candidate,
                    reason: candidateBlock
                ),
                provenance: isPrimaryRepresentation
                    ? .primarySafetyFailure
                    : .registeredLinkedRepresentation
            )
        }
        guard let origin = candidate.originIdentity else {
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    candidate,
                    reason: .unsupportedOrigin
                ),
                provenance: .primarySafetyFailure
            )
        }
        #if SHADOW_SYNC_TESTING
        let isWritableFixtureUmbrella =
            origin.canonicalName == "fixture-owner/dev" && primaryRelative == "."
        #else
        let isWritableFixtureUmbrella = false
        #endif
        if policy.excludedOrigins.contains(origin.canonicalName),
           !isWritableFixtureUmbrella {
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    candidate,
                    reason: .excludedByPolicy
                ),
                provenance: isPrimaryRepresentation
                    ? .primarySafetyFailure
                    : .registeredLinkedRepresentation
            )
        }
        guard let commonIdentity = candidate.commonDirectoryIdentity else {
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    candidate,
                    reason: .unsafeGitMetadata
                ),
                provenance: .primarySafetyFailure
            )
        }
        if usesLegacyCloneWideEligibility,
           policy.hasUnsupportedHookMarker(repositoryPath: primaryPath) {
            return AccumulatedCandidate(
                candidate: Self.blocked(candidate, reason: .unsupportedHook),
                provenance: .primarySafetyFailure
            )
        }
        let hookAdmissionSHA256 = try policy.hookAdmissionSHA256(
            repositoryPath: primaryPath, beforeAccess: { try admission?.willAccess($0) }
        )
        if usesLegacyCloneWideEligibility,
           hookAdmissionSHA256 == nil {
            return AccumulatedCandidate(
                candidate: Self.blocked(candidate, reason: .unsupportedHook),
                provenance: .primarySafetyFailure
            )
        }
        guard try Self.hasNoUnsafeGraphMetadata(primaryPath, beforeAccess: { try admission?.willAccess($0) }) else {
            return AccumulatedCandidate(
                candidate: Self.blocked(candidate, reason: .unsafeGitMetadata),
                provenance: .primarySafetyFailure
            )
        }
        let registeredLinkedWorktrees: [RepositoryLinkedWorktree]
        do {
            registeredLinkedWorktrees = try Self.registeredLinkedWorktrees(
                commonDirectory: primaryPath + "/.git",
                rootPath: rootPath,
                account: account,
                allowExternal: !usesLegacyCloneWideEligibility, admission: admission
            )
        } catch RepositoryLinkedWorktreeError.unsupportedExternalLocation {
            try admission?.validate()
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    Self.presentable(
                        candidate,
                        location: presentationLocation,
                        linkedWorktrees: [],
                        policyAdmissionSHA256:
                            policy.admissionSHA256,
                        hookAdmissionSHA256:
                            hookAdmissionSHA256
                    ),
                    reason: .unsupportedExternalWorktree
                ),
                provenance: .primarySafetyFailure
            )
        } catch {
            try admission?.validate()
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    Self.presentable(
                        candidate,
                        location: presentationLocation,
                        linkedWorktrees: [],
                        policyAdmissionSHA256:
                            policy.admissionSHA256,
                        hookAdmissionSHA256:
                            hookAdmissionSHA256
                    ),
                    reason: .unsafeWorktreeTopology
                ),
                provenance: .primarySafetyFailure
            )
        }
        if !isPrimaryRepresentation {
            guard let linkedCommon = try? Self.resolveLinkedCommonDirectory(
                markerPath: gitMarker,
                account: account, admission: admission
            ) else {
                try admission?.validate()
                return nil
            }
            try admission?.willAccess(linkedCommon)
            let linkedDescriptor = Darwin.open(
                linkedCommon,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard linkedDescriptor >= 0 else {
                return nil
            }
            var linkedInfo = stat()
            let matches = fstat(linkedDescriptor, &linkedInfo) == 0
                && RepositoryDirectoryIdentity(FileIdentity(linkedInfo)) == commonIdentity
            close(linkedDescriptor)
            guard matches else {
                return AccumulatedCandidate(
                    candidate: Self.blocked(
                        candidate,
                        reason: .unsafeWorktreeTopology
                    ),
                    provenance: .primarySafetyFailure
                )
            }

            try admission?.willAccess(representationPath)
            let representationDescriptor = Darwin.open(
                representationPath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard representationDescriptor >= 0 else {
                return nil
            }
            var representationInfo = stat()
            let representationMatchesRegistration =
                fstat(representationDescriptor, &representationInfo) == 0
                && FileIdentity(representationInfo).isDirectory
                && representationInfo.st_uid == account.uid
                && Self.matchesRegisteredRepresentation(
                    rootIdentity: RepositoryDirectoryIdentity(
                        FileIdentity(representationInfo)
                    ),
                    linkedWorktrees: registeredLinkedWorktrees
                )
            close(representationDescriptor)
            guard representationMatchesRegistration else {
                return AccumulatedCandidate(
                    candidate: Self.blocked(
                        candidate,
                        reason: .unsafeWorktreeTopology
                    ),
                    provenance: .staleLinkedRepresentation
                )
            }
        }
        try admission?.validate()
        candidate = Self.presentable(
            candidate,
            location: presentationLocation,
            linkedWorktrees: registeredLinkedWorktrees,
            policyAdmissionSHA256: policy.admissionSHA256,
            hookAdmissionSHA256: hookAdmissionSHA256
        )
        if usesLegacyCloneWideEligibility,
           registeredLinkedWorktrees.contains(where: {
            $0.headValue == "ref: refs/heads/main"
        }) {
            return AccumulatedCandidate(
                candidate: Self.blocked(
                    candidate,
                    reason: .mainInLinkedWorktree
                ),
                provenance: .primarySafetyFailure
            )
        }
        return AccumulatedCandidate(
            candidate: candidate,
            provenance: isPrimaryRepresentation
                ? .primaryRepresentation
                : .registeredLinkedRepresentation
        )
    }

    private static func matchesRegisteredRepresentation(
        rootIdentity: RepositoryDirectoryIdentity,
        linkedWorktrees: [RepositoryLinkedWorktree]
    ) -> Bool {
        linkedWorktrees.contains {
            $0.rootIdentity == rootIdentity
        }
    }

    private static func presentable(
        _ candidate: RepositoryCandidate,
        location: String,
        linkedWorktrees: [RepositoryLinkedWorktree],
        policyAdmissionSHA256: String,
        hookAdmissionSHA256: String?
    ) -> RepositoryCandidate {
        RepositoryCandidate(
            id: candidate.id,
            displayName: candidate.displayName,
            path: candidate.path,
            rawOrigin: candidate.rawOrigin,
            presentationLocation: location,
            rootIdentity: candidate.rootIdentity,
            gitDirectoryIdentity: candidate.gitDirectoryIdentity,
            commonDirectoryIdentity: candidate.commonDirectoryIdentity,
            configIdentity: candidate.configIdentity,
            policyAdmissionSHA256: policyAdmissionSHA256,
            hookAdmissionSHA256: hookAdmissionSHA256,
            linkedWorktreePaths: linkedWorktrees.map(\.path),
            linkedWorktrees: linkedWorktrees,
            cachedMainRelation: candidate.cachedMainRelation,
            blockedReason: candidate.blockedReason
        )
    }

    private static func blocked(
        _ candidate: RepositoryCandidate,
        reason: RepositoryBlockReason
    ) -> RepositoryCandidate {
        RepositoryCandidate(
            id: candidate.id,
            displayName: candidate.displayName,
            path: candidate.path,
            rawOrigin: candidate.rawOrigin,
            presentationLocation: candidate.presentationLocation,
            rootIdentity: candidate.rootIdentity,
            gitDirectoryIdentity: candidate.gitDirectoryIdentity,
            commonDirectoryIdentity: candidate.commonDirectoryIdentity,
            configIdentity: candidate.configIdentity,
            policyAdmissionSHA256: candidate.policyAdmissionSHA256,
            hookAdmissionSHA256: candidate.hookAdmissionSHA256,
            linkedWorktreePaths: candidate.linkedWorktreePaths,
            linkedWorktrees: candidate.linkedWorktrees,
            cachedMainRelation: candidate.cachedMainRelation,
            blockedReason: reason
        )
    }

    private static func withCachedRelation(
        _ candidate: RepositoryCandidate,
        relation: RepositoryCachedMainRelation
    ) -> RepositoryCandidate {
        RepositoryCandidate(
            id: candidate.id,
            displayName: candidate.displayName,
            path: candidate.path,
            rawOrigin: candidate.rawOrigin,
            presentationLocation: candidate.presentationLocation,
            rootIdentity: candidate.rootIdentity,
            gitDirectoryIdentity: candidate.gitDirectoryIdentity,
            commonDirectoryIdentity: candidate.commonDirectoryIdentity,
            configIdentity: candidate.configIdentity,
            policyAdmissionSHA256: candidate.policyAdmissionSHA256,
            hookAdmissionSHA256: candidate.hookAdmissionSHA256,
            linkedWorktreePaths: candidate.linkedWorktreePaths,
            linkedWorktrees: candidate.linkedWorktrees,
            cachedMainRelation: relation,
            blockedReason: candidate.blockedReason
        )
    }

    private static func blockedWithoutCanonicalIdentity(
        _ candidate: RepositoryCandidate,
        reason: RepositoryBlockReason
    ) -> RepositoryCandidate {
        let localID = candidate.rootIdentity.map {
            "local:\($0.device):\($0.inode)"
        } ?? "local-path:\(candidate.path)"
        return RepositoryCandidate(
            id: localID,
            displayName: candidate.displayName,
            path: candidate.path,
            rawOrigin: "",
            presentationLocation: candidate.presentationLocation,
            rootIdentity: candidate.rootIdentity,
            gitDirectoryIdentity: candidate.gitDirectoryIdentity,
            commonDirectoryIdentity: candidate.commonDirectoryIdentity,
            configIdentity: candidate.configIdentity,
            policyAdmissionSHA256: candidate.policyAdmissionSHA256,
            hookAdmissionSHA256: candidate.hookAdmissionSHA256,
            linkedWorktreePaths: candidate.linkedWorktreePaths,
            linkedWorktrees: candidate.linkedWorktrees,
            cachedMainRelation: candidate.cachedMainRelation,
            blockedReason: reason
        )
    }

    private static func blockReason(
        for disposition: RepositoryPolicyPathDisposition
    ) -> RepositoryBlockReason? {
        switch disposition {
        case .allowed, .artifact:
            return nil
        case .excluded:
            return .excludedByPolicy
        case .readOnlyReference:
            return .readOnlyReference
        }
    }

    private static func safeLocalCandidate(
        path: String,
        location: String,
        account: EffectiveAccount,
        reason: RepositoryBlockReason
    ) -> RepositoryCandidate? {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isDirectory,
              info.st_uid == account.uid,
              (try? descriptorPath(descriptor)) == path else {
            return nil
        }
        let identity = RepositoryDirectoryIdentity(FileIdentity(info))
        return RepositoryCandidate(
            id: "local:\(identity.device):\(identity.inode)",
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            rawOrigin: "",
            presentationLocation: location,
            rootIdentity: identity,
            blockedReason: reason
        )
    }

    private static func registeredLinkedWorktrees(
        commonDirectory: String,
        rootPath: String,
        account: EffectiveAccount,
        allowExternal: Bool = false,
        admission: RepositoryDiscoveryPolicy? = nil
    ) throws -> [RepositoryLinkedWorktree] {
        try admission?.willAccess(commonDirectory)
        let commonDescriptor = try openDiscoveryDirectory(commonDirectory, account: account, admission: admission)
        guard commonDescriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "common worktree metadata cannot be opened"
            )
        }
        defer { close(commonDescriptor) }
        var commonInfo = stat()
        guard fstat(commonDescriptor, &commonInfo) == 0,
              FileIdentity(commonInfo).isDirectory,
              commonInfo.st_uid == account.uid,
              (commonInfo.st_mode & 0o022) == 0,
              try descriptorPath(commonDescriptor) == commonDirectory else {
            throw GitSafetyError.unsafeRepository(
                "common worktree metadata is unsafe"
            )
        }
        try admission?.willAccess(commonDirectory + "/worktrees")
        let worktreesDescriptor = openat(
            commonDescriptor,
            "worktrees",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if worktreesDescriptor < 0, errno == ENOENT {
            return []
        }
        guard worktreesDescriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata cannot be opened"
            )
        }
        defer { close(worktreesDescriptor) }
        let worktrees = commonDirectory + "/worktrees"
        var worktreesInfo = stat()
        guard fstat(worktreesDescriptor, &worktreesInfo) == 0,
              FileIdentity(worktreesInfo).isDirectory,
              worktreesInfo.st_uid == account.uid,
              (worktreesInfo.st_mode & 0o022) == 0,
              try descriptorPath(worktreesDescriptor) == worktrees else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata owner, type, or path is unsafe"
            )
        }
        var registrations: [RepositoryLinkedWorktree] = []
        for name in try directoryEntryNames(descriptor: worktreesDescriptor) {
            guard !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("/"),
                  !name.contains("\0") else {
                throw GitSafetyError.unsafeRepository("worktree metadata name is invalid")
            }
            let entry = worktrees + "/" + name
            try admission?.prepareAccess([entry, entry + "/gitdir", entry + "/commondir",
                                          entry + "/config.worktree", entry + "/HEAD"])
            try admission?.willAccess(entry)
            let entryDescriptor = openat(
                worktreesDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard entryDescriptor >= 0 else {
                throw GitSafetyError.unsafeRepository("worktree metadata entry cannot be opened")
            }
            defer { close(entryDescriptor) }
            let canonicalEntry = try descriptorPath(entryDescriptor)
            var entryInfo = stat()
            let entrySafe = fstat(entryDescriptor, &entryInfo) == 0
                && FileIdentity(entryInfo).isDirectory
                && entryInfo.st_uid == account.uid
                && (entryInfo.st_mode & 0o022) == 0
                && canonicalEntry == entry
            guard entrySafe else {
                throw GitSafetyError.unsafeRepository("worktree metadata entry is unsafe")
            }
            try admission?.willAccess(entry + "/gitdir")
            let gitdir = try readOwnedRegularFileSnapshot(
                "gitdir",
                directoryDescriptor: entryDescriptor,
                account: account,
                maximumBytes: 16_384
            )
            let markerPath = try metadataLine(
                gitdir.data,
                description: "registered worktree path"
            )
            guard safeAbsolutePath(markerPath),
                  markerPath.hasSuffix("/.git") else {
                throw GitSafetyError.unsafeRepository(
                    "registered worktree path is unsupported"
                )
            }
            // Parse untrusted metadata lexically before any path admission.
            let requestedWorktree = String(markerPath.dropLast("/.git".count))
            try admission?.willAccess(requestedWorktree)
            let physicalWorktree: (
                path: String,
                identity: RepositoryDirectoryIdentity,
                descriptor: Int32
            )
            if isContained(requestedWorktree, root: rootPath) {
                physicalWorktree = try validatePhysicalDirectory(
                    requestedWorktree,
                    beneath: rootPath,
                    account: account,
                    minimumDescendantComponents: 1,
                    admission: admission
                )
            } else if !allowExternal {
                let cursorRoot = URL(fileURLWithPath: account.homeDirectory)
                    .appendingPathComponent(".cursor/worktrees").path
                guard isContained(requestedWorktree, root: cursorRoot) else {
                    throw RepositoryLinkedWorktreeError.unsupportedExternalLocation
                }
                let cursorRelative = relativePath(
                    requestedWorktree,
                    root: cursorRoot
                ).split(separator: "/")
                guard cursorRelative.count >= 2 else {
                    throw RepositoryLinkedWorktreeError.unsafeTopology(
                        "Cursor path depth"
                    )
                }
                physicalWorktree = try validatePhysicalDirectory(
                    requestedWorktree,
                    beneath: account.homeDirectory,
                    account: account,
                    minimumDescendantComponents: 4,
                    admission: admission
                )
            } else if let admission {
                physicalWorktree = try validatePhysicalDirectory(
                    requestedWorktree,
                    beneath: account.homeDirectory,
                    account: account,
                    minimumDescendantComponents: 0,
                    admission: admission
                )
            } else {
                physicalWorktree = try validateExternalPhysicalDirectory(
                    requestedWorktree,
                    account: account
                )
            }
            defer { close(physicalWorktree.descriptor) }
            let canonicalMarker = physicalWorktree.path + "/.git"
            guard markerPath == canonicalMarker else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "canonical marker path"
                )
            }
            try admission?.willAccess(canonicalMarker)
            let marker = try readOwnedRegularFileSnapshot(
                ".git",
                directoryDescriptor: physicalWorktree.descriptor,
                account: account,
                maximumBytes: 16_384
            )
            let markerText = try metadataLine(
                marker.data,
                description: "linked worktree marker"
            )
            guard markerText.hasPrefix("gitdir: ") else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "marker prefix"
                )
            }
            let markerValue = String(markerText.dropFirst("gitdir: ".count))
            let linkedGitDirectory = try lexicallyResolvedPath(
                markerValue,
                relativeTo: physicalWorktree.path
            )
            guard linkedGitDirectory == canonicalEntry,
                  canonicalEntry == entry else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "backlink identity: \(linkedGitDirectory) != \(entry) / \(canonicalEntry)"
                )
            }
            try admission?.willAccess(entry + "/config.worktree")
            var worktreeConfigInfo = stat()
            if fstatat(
                entryDescriptor,
                "config.worktree",
                &worktreeConfigInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0 || errno != ENOENT {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "worktree config"
                )
            }
            try admission?.willAccess(entry + "/commondir")
            let commonMarker = try readOwnedRegularFileSnapshot(
                "commondir",
                directoryDescriptor: entryDescriptor,
                account: account,
                maximumBytes: 4_096
            )
            let commonValue = try metadataLine(
                commonMarker.data,
                description: "linked common directory"
            )
            let resolvedCommon = try lexicallyResolvedPath(
                commonValue,
                relativeTo: entry
            )
            guard resolvedCommon == commonDirectory else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "common directory"
                )
            }
            try admission?.willAccess(entry + "/HEAD")
            let head = try readOwnedRegularFileSnapshot(
                "HEAD",
                directoryDescriptor: entryDescriptor,
                account: account,
                maximumBytes: 4_096
            )
            let headValue = try metadataLine(
                head.data,
                description: "linked worktree HEAD"
            )
            guard validLinkedHead(headValue) else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "linked HEAD"
                )
            }
            registrations.append(RepositoryLinkedWorktree(
                path: physicalWorktree.path,
                rootIdentity: physicalWorktree.identity,
                markerIdentity: marker.identity,
                registrationDirectoryIdentity:
                    RepositoryDirectoryIdentity(FileIdentity(entryInfo)),
                registrationGitdirIdentity: gitdir.identity,
                commonDirectoryMarkerIdentity: commonMarker.identity,
                headIdentity: head.identity,
                headValue: headValue
            ))
        }
        try admission?.validate()
        return registrations.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// Decoded metadata paths must be admitted at each physical traversal step.
    /// Unbound callers retain their existing behavior; production has a service.
    private static func openDiscoveryDirectory(_ path: String, account: EffectiveAccount,
        admission: RepositoryDiscoveryPolicy?) throws -> Int32 {
        if let admission {
            return try validatePhysicalDirectory(path, beneath: account.homeDirectory,
                account: account, minimumDescendantComponents: 0, admission: admission).descriptor
        }
        return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    private static func validatePhysicalDirectory(
        _ requestedPath: String,
        beneath rootPath: String,
        account: EffectiveAccount,
        minimumDescendantComponents: Int,
        admission: RepositoryDiscoveryPolicy? = nil
    ) throws -> (
        path: String,
        identity: RepositoryDirectoryIdentity,
        descriptor: Int32
    ) {
        guard safeAbsolutePath(rootPath),
              safeAbsolutePath(requestedPath),
              isContained(requestedPath, root: rootPath) else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "physical containment"
            )
        }
        let relative = relativePath(requestedPath, root: rootPath)
        let components = relative == "."
            ? []
            : relative.split(separator: "/").map(String.init)
        guard components.count >= minimumDescendantComponents else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "physical path depth"
            )
        }
        try admission?.willAccess(rootPath)
        var descriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "physical root open"
            )
        }
        defer { close(descriptor) }
        try admission?.validate()
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == account.uid,
              (rootInfo.st_mode & 0o022) == 0,
              try descriptorPath(descriptor) == rootPath else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "physical root identity"
            )
        }
        var traversedPath = rootPath
        for component in components {
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/") else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "physical component"
                )
            }
            traversedPath += "/" + component
            try admission?.willAccess(traversedPath)
            let next = component.withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "physical component open: \(component)"
                )
            }
            close(descriptor)
            descriptor = next
            try admission?.validate()
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  FileIdentity(info).isDirectory,
                  info.st_uid == account.uid,
                  (info.st_mode & 0o022) == 0 else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "physical component identity"
                )
            }
        }
        try admission?.validate()
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              try descriptorPath(descriptor) == requestedPath else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "physical final identity"
            )
        }
        let retainedDescriptor = dup(descriptor)
        guard retainedDescriptor >= 0 else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "physical final retain"
            )
        }
        return (
            requestedPath,
            RepositoryDirectoryIdentity(FileIdentity(finalInfo)),
            retainedDescriptor
        )
    }

    private static func validateExternalPhysicalDirectory(
        _ requestedPath: String,
        account: EffectiveAccount
    ) throws -> (
        path: String,
        identity: RepositoryDirectoryIdentity,
        descriptor: Int32
    ) {
        guard safeAbsolutePath(requestedPath) else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "external worktree path"
            )
        }
        return try RepositoryRootPathIdentity.withVerifiedDirectory(
            path: requestedPath
        ) { opened in
            var info = stat()
            guard fstat(opened.descriptor, &info) == 0,
                  FileIdentity(info).isDirectory,
                  info.st_uid == account.uid,
                  (info.st_mode & 0o022) == 0,
                  opened.canonicalPath == requestedPath else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "external worktree identity"
                )
            }
            let retained = dup(opened.descriptor)
            guard retained >= 0 else {
                throw SecureStateError.systemCall(
                    "retain external worktree",
                    errno
                )
            }
            return (
                path: opened.canonicalPath,
                identity: RepositoryDirectoryIdentity(FileIdentity(info)),
                descriptor: retained
            )
        }
    }

    private static func safeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              path.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.count > 1
            && components[0].isEmpty
            && components.dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func lexicallyResolvedPath(
        _ value: String,
        relativeTo base: String
    ) throws -> String {
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              safeAbsolutePath(base) else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "metadata path syntax"
            )
        }
        var components = value.hasPrefix("/")
            ? [String]()
            : base.split(separator: "/").map(String.init)
        for component in value.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    throw RepositoryLinkedWorktreeError.unsafeTopology(
                        "metadata path escaped root"
                    )
                }
                components.removeLast()
                continue
            }
            guard !component.contains("\\") else {
                throw RepositoryLinkedWorktreeError.unsafeTopology(
                    "metadata path component"
                )
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw RepositoryLinkedWorktreeError.unsafeTopology(
                "metadata path is empty"
            )
        }
        return "/" + components.joined(separator: "/")
    }

    private static func metadataLine(
        _ data: Data,
        description: String
    ) throws -> String {
        guard var text = String(data: data, encoding: .utf8),
              !text.contains("\r"),
              !text.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "\(description) is malformed"
            )
        }
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        guard !text.isEmpty,
              !text.contains("\n"),
              text == text.trimmingCharacters(in: .whitespaces) else {
            throw GitSafetyError.unsafeRepository(
                "\(description) is malformed"
            )
        }
        return text
    }

    private static func validLinkedHead(_ value: String) -> Bool {
        if (value.utf8.count == 40 || value.utf8.count == 64),
           value.utf8.allSatisfy({
               ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
           }) {
            return true
        }
        let prefix = "ref: refs/heads/"
        guard value.hasPrefix(prefix) else {
            return false
        }
        let branch = String(value.dropFirst(prefix.count))
        let forbidden = CharacterSet(charactersIn: #"~^:?*[\\"#)
        return !branch.isEmpty
            && branch != "@"
            && !branch.hasPrefix("/")
            && !branch.hasSuffix("/")
            && !branch.hasSuffix(".")
            && !branch.hasSuffix(".lock")
            && !branch.contains("//")
            && !branch.contains("..")
            && !branch.contains("@{")
            && branch.rangeOfCharacter(
                from: .controlCharacters.union(.whitespaces)
            ) == nil
            && branch.rangeOfCharacter(from: forbidden) == nil
            && branch.split(separator: "/").allSatisfy {
                !$0.hasPrefix(".")
                    && !$0.hasSuffix(".")
                    && !$0.hasSuffix(".lock")
            }
    }

    private static func resolveLinkedCommonDirectory(
        markerPath: String,
        account: EffectiveAccount,
        admission: RepositoryDiscoveryPolicy? = nil
    ) throws -> String {
        try admission?.willAccess(markerPath)
        let marker = try readOwnedRegularFile(
            markerPath,
            account: account,
            maximumBytes: 16_384
        )
        let markerLine = try metadataLine(
            marker,
            description: "linked worktree marker"
        )
        guard markerLine.hasPrefix("gitdir: ") else {
            throw GitSafetyError.unsafeRepository("linked worktree marker is malformed")
        }
        let value = String(markerLine.dropFirst("gitdir: ".count))
        guard !value.isEmpty else {
            throw GitSafetyError.unsafeRepository("linked worktree Git directory is absent")
        }
        let markerDirectory = URL(fileURLWithPath: markerPath)
            .deletingLastPathComponent().path
        let gitDirectory = try lexicallyResolvedPath(
            value,
            relativeTo: markerDirectory
        )
        try admission?.willAccess(gitDirectory)
        let gitDescriptor = try openDiscoveryDirectory(gitDirectory, account: account, admission: admission)
        guard gitDescriptor >= 0 else {
            throw GitSafetyError.unsafeRepository("linked worktree Git directory cannot be opened")
        }
        defer { close(gitDescriptor) }
        var gitInfo = stat()
        guard fstat(gitDescriptor, &gitInfo) == 0,
              FileIdentity(gitInfo).isDirectory,
              gitInfo.st_uid == account.uid,
              (gitInfo.st_mode & 0o022) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "linked worktree Git directory is unsafe"
            )
        }
        let canonicalGit = try descriptorPath(gitDescriptor)
        try admission?.willAccess(canonicalGit + "/config.worktree")
        var worktreeConfigInfo = stat()
        if fstatat(
            gitDescriptor,
            "config.worktree",
            &worktreeConfigInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 || errno != ENOENT {
            throw GitSafetyError.unsafeRepository(
                "linked worktree configuration is unsupported"
            )
        }
        try admission?.willAccess(canonicalGit + "/commondir")
        let commonData = try readOwnedRegularFileSnapshot(
            "commondir",
            directoryDescriptor: gitDescriptor,
            account: account,
            maximumBytes: 4_096
        ).data
        let commonValue = try metadataLine(
            commonData,
            description: "linked common directory"
        )
        let commonPath = try lexicallyResolvedPath(
            commonValue,
            relativeTo: canonicalGit
        )
        try admission?.willAccess(commonPath)
        let commonDescriptor = try openDiscoveryDirectory(commonPath, account: account, admission: admission)
        guard commonDescriptor >= 0 else {
            throw GitSafetyError.unsafeRepository("common Git directory cannot be opened")
        }
        defer { close(commonDescriptor) }
        var commonInfo = stat()
        guard fstat(commonDescriptor, &commonInfo) == 0,
              FileIdentity(commonInfo).isDirectory,
              commonInfo.st_uid == account.uid,
              (commonInfo.st_mode & 0o022) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "common Git directory is unsafe"
            )
        }
        let canonicalCommon = try descriptorPath(commonDescriptor)
        try admission?.willAccess(canonicalCommon)
        return canonicalCommon
    }

    private static func hasNoUnsafeGraphMetadata(_ repositoryPath: String) -> Bool {
        (try? hasNoUnsafeGraphMetadata(repositoryPath, beforeAccess: { _ in })) ?? false
    }

    private static func hasNoUnsafeGraphMetadata(_ repositoryPath: String,
        beforeAccess: (String) throws -> Void) throws -> Bool {
        let objectsPath = URL(fileURLWithPath: repositoryPath)
            .appendingPathComponent(".git/objects").path
        try beforeAccess(objectsPath)
        var objectsInfo = stat()
        guard lstat(objectsPath, &objectsInfo) == 0,
              (objectsInfo.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        for relative in [
            ".git/objects/info/alternates",
            ".git/info/grafts",
            ".git/refs/replace",
        ] {
            let path = URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent(relative).path
            try beforeAccess(path)
            var info = stat()
            if lstat(path, &info) == 0 || errno != ENOENT {
                return false
            }
        }
        return true
    }

    private struct OwnedMetadataFile {
        let data: Data
        let identity: RepositoryMetadataFileIdentity
    }

    private static func readOwnedRegularFileSnapshot(
        _ path: String,
        account: EffectiveAccount,
        maximumBytes: Int
    ) throws -> OwnedMetadataFile {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository("metadata file cannot be opened")
        }
        defer { close(descriptor) }
        return try readOwnedRegularFileSnapshot(
            descriptor: descriptor,
            account: account,
            maximumBytes: maximumBytes
        )
    }

    private static func readOwnedRegularFileSnapshot(
        _ name: String,
        directoryDescriptor: Int32,
        account: EffectiveAccount,
        maximumBytes: Int
    ) throws -> OwnedMetadataFile {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw GitSafetyError.unsafeRepository(
                "metadata file name is unsafe"
            )
        }
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository("metadata file cannot be opened")
        }
        defer { close(descriptor) }
        return try readOwnedRegularFileSnapshot(
            descriptor: descriptor,
            account: account,
            maximumBytes: maximumBytes
        )
    }

    private static func readOwnedRegularFileSnapshot(
        descriptor: Int32,
        account: EffectiveAccount,
        maximumBytes: Int
    ) throws -> OwnedMetadataFile {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              (info.st_mode & 0o022) == 0,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw GitSafetyError.unsafeRepository("metadata file owner, type, or size")
        }
        let initialIdentity = RepositoryMetadataFileIdentity(info)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count == 0 else {
                throw GitSafetyError.unsafeRepository("metadata file read failed")
            }
            var finalInfo = stat()
            guard fstat(descriptor, &finalInfo) == 0,
                  RepositoryMetadataFileIdentity(finalInfo)
                    == initialIdentity else {
                throw GitSafetyError.unsafeRepository(
                    "metadata file changed while it was read"
                )
            }
            return OwnedMetadataFile(
                data: data,
                identity: initialIdentity
            )
        }
        throw GitSafetyError.unsafeRepository("metadata file is too large")
    }

    private static func readOwnedRegularFile(
        _ path: String,
        account: EffectiveAccount,
        maximumBytes: Int
    ) throws -> Data {
        try readOwnedRegularFileSnapshot(
            path,
            account: account,
            maximumBytes: maximumBytes
        ).data
    }

    private static func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw GitSafetyError.unsafeRepository("directory path is unavailable")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8), path.hasPrefix("/") else {
            throw GitSafetyError.unsafeRepository("directory path is invalid")
        }
        return path
    }

    private static func directoryEntryNames(
        descriptor: Int32
    ) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 {
                close(duplicate)
            }
            throw GitSafetyError.unsafeRepository(
                "worktree metadata directory cannot be read"
            )
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata directory read failed"
            )
        }
        return names.sorted()
    }

    private static func relativePath(_ path: String, root: String) -> String {
        path == root ? "." : String(path.dropFirst(root.count + 1))
    }

    private static func isContained(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func pathForRoot(_ path: String, relativePath: String) -> String {
        if relativePath == "." {
            return path
        }
        let components = relativePath.split(separator: "/")
        var url = URL(fileURLWithPath: path)
        for _ in components {
            url.deleteLastPathComponent()
        }
        return url.path
    }
}

#if SHADOW_SYNC_TESTING
extension RepositoryDiscovery: RepositoryDiscovering {}
#endif

private final class RepositoryDiscoveryValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: RepositoryCandidate] = [:]

    func record(_ candidate: RepositoryCandidate) {
        lock.lock()
        rows[candidate.path] = candidate
        lock.unlock()
    }

    var candidates: [RepositoryCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return Array(rows.values)
    }
}

private enum RepositoryLinkedWorktreeError: Error {
    case unsupportedExternalLocation
    case unsafeTopology(String)
}
