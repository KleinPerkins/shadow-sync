import Foundation

public enum Body3BatchNodeKind:
    String, Codable, Equatable, Sendable {
    case repair
    case reinspection
    case fastForward
    case retention
    case groupedRemovalConfirmation
    case worktreeRemoval
    case claimReinspection
    case branchRemoval
    case residueVerification
    case policyInvalidation

    public var phase: String {
        switch self {
        case .repair: return "Repair"
        case .reinspection: return "Re-inspect"
        case .fastForward: return "Fast-forward"
        case .retention: return "Recovery"
        case .groupedRemovalConfirmation:
            return "Confirm removals"
        case .worktreeRemoval: return "Remove Worktree"
        case .claimReinspection: return "Re-inspect claims"
        case .branchRemoval: return "Remove Branch"
        case .residueVerification: return "Verify residue"
        case .policyInvalidation: return "Refresh policy"
        }
    }
}

public enum Body3BatchNodeStatus:
    String, Codable, Equatable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case skipped
    case refused
    case failed
    case cancelled
    case cleanupPending

    public var isSettled: Bool { isTerminal || self == .cleanupPending }

    public var isTerminal: Bool {
        switch self {
        case .queued, .running, .cleanupPending: return false
        case .succeeded, .skipped, .refused,
             .failed, .cancelled:
            return true
        }
    }
}

public struct Body3BatchDependency:
    Codable, Equatable, Sendable {
    public let nodeID: String
    public let requiresSuccess: Bool

    public init(
        nodeID: String,
        requiresSuccess: Bool = true
    ) {
        self.nodeID = nodeID
        self.requiresSuccess = requiresSuccess
    }
}

public enum Body3BatchPayload:
    Codable, Equatable, Sendable {
    case operation(PlannedOperation)
    case reinspection(
        repositoryID: String,
        cloneID: String,
        reason: String
    )
    case retention(RemovalSelection)
    case confirmation([RemovalSelection])
    case removal(RemovalCandidate)
    case residue(RemovalCandidate)
    case policyInvalidation(repositoryID: String)
}

public struct Body3BatchNode:
    Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repositoryID: String?
    public let commonDirectoryKey: String?
    public let kind: Body3BatchNodeKind
    public let dependencies: [Body3BatchDependency]
    public let payload: Body3BatchPayload
    public let requiresExclusiveWorkerPool: Bool

    public init(
        id: String,
        repositoryID: String?,
        commonDirectoryKey: String?,
        kind: Body3BatchNodeKind,
        dependencies: [Body3BatchDependency],
        payload: Body3BatchPayload,
        requiresExclusiveWorkerPool: Bool = false
    ) throws {
        guard id.hasPrefix("body3-node:"),
              Set(dependencies.map(\.nodeID)).count
                == dependencies.count,
              !dependencies.contains(where: {
                  $0.nodeID == id
              }) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 batch node is invalid"
            )
        }
        self.id = id
        self.repositoryID = repositoryID
        self.commonDirectoryKey = commonDirectoryKey
        self.kind = kind
        self.dependencies = dependencies
        self.payload = payload
        self.requiresExclusiveWorkerPool =
            requiresExclusiveWorkerPool
    }

    var isStructurallyValid: Bool {
        guard id.hasPrefix("body3-node:"),
              Set(dependencies.map(\.nodeID)).count
                == dependencies.count,
              !dependencies.contains(where: {
                  $0.nodeID == id
              }) else {
            return false
        }
        switch (kind, payload) {
        case let (.fastForward, .operation(operation)):
            return operation.kind == .fastForward
                && repositoryID
                    == operation.target.repository.id
                && commonDirectoryKey
                    == operation.target.canonicalClone.id
        case let (.repair, .operation(operation)):
            return operation.kind != .fastForward
                && repositoryID
                    == operation.target.repository.id
                && commonDirectoryKey
                    == operation.target.canonicalClone.id
        case let (
            .reinspection,
            .reinspection(repository, clone, _)
        ), let (
            .claimReinspection,
            .reinspection(repository, clone, _)
        ):
            return repositoryID == repository
                && commonDirectoryKey == clone
        case let (.retention, .retention(selection)):
            return repositoryID
                    == selection.candidate.repository.id
                && commonDirectoryKey
                    == selection.candidate.clone.id
        case (.groupedRemovalConfirmation, .confirmation):
            return repositoryID == nil
                && commonDirectoryKey == nil
                && requiresExclusiveWorkerPool
        case let (.worktreeRemoval, .removal(candidate)):
            return candidate.kind == .worktree
                && repositoryID == candidate.repository.id
                && commonDirectoryKey == candidate.clone.id
        case let (.branchRemoval, .removal(candidate)):
            return candidate.kind == .branch
                && repositoryID == candidate.repository.id
                && commonDirectoryKey == candidate.clone.id
        case let (.residueVerification, .residue(candidate)):
            return repositoryID == candidate.repository.id
                && commonDirectoryKey == candidate.clone.id
        case let (
            .policyInvalidation,
            .policyInvalidation(repository)
        ):
            return repositoryID == repository
                && commonDirectoryKey != nil
                && requiresExclusiveWorkerPool
        default:
            return false
        }
    }
}

public struct Body3BatchPlan:
    Codable, Equatable, Sendable {
    public let schema: String
    public let run: String
    public let createdAt: String
    public let policyEvidenceDigest: String
    public let nodes: [Body3BatchNode]

    public init(
        run: String,
        createdAt: String = WallClock.timestamp(),
        policyEvidenceDigest: String,
        nodes: [Body3BatchNode]
    ) throws {
        guard RunIdentity.isValid(run),
              !policyEvidenceDigest.isEmpty,
              !nodes.isEmpty,
              Self.nodesAreStructurallyValid(nodes) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 batch plan is not a closed DAG"
            )
        }
        schema = "shadow-sync-batch-plan/v2"
        self.run = run
        self.createdAt = createdAt
        self.policyEvidenceDigest = policyEvidenceDigest
        self.nodes = nodes
    }

    var isStructurallyValid: Bool {
        isStructurallyValidForLog(.current)
    }

    func isStructurallyValidForLog(_ identity: HistoricalLogIdentity) -> Bool {
        schema == identity.v2Plan
            && RunIdentity.isValid(run)
            && !policyEvidenceDigest.isEmpty
            && !nodes.isEmpty
            && Self.nodesAreStructurallyValid(nodes)
    }

    private static func nodesAreStructurallyValid(
        _ nodes: [Body3BatchNode]
    ) -> Bool {
        let ids = Set(nodes.map(\.id))
        return ids.count == nodes.count
            && nodes.allSatisfy({ node in
                node.isStructurallyValid
                    && Set(
                        node.dependencies.map(\.nodeID)
                    ).isSubset(of: ids)
            })
            && isAcyclic(nodes)
    }

    private static func isAcyclic(
        _ nodes: [Body3BatchNode]
    ) -> Bool {
        var remaining = Dictionary(
            uniqueKeysWithValues: nodes.map {
                ($0.id, Set($0.dependencies.map(\.nodeID)))
            }
        )
        var admitted = Set<String>()
        while let next = remaining.first(where: {
            $0.value.isSubset(of: admitted)
        })?.key {
            admitted.insert(next)
            remaining.removeValue(forKey: next)
        }
        return remaining.isEmpty
    }
}

public enum Body3BatchPlanner {
    #if SHADOW_SYNC_TESTING
    public static func make(run: String, operations: [PlannedOperation],
                            removals: [RemovalSelection]) throws -> Body3BatchPlan {
        try make(run: run, operations: operations, removals: removals,
                 governedRoot: .testing())
    }
    #endif

    // Rebuild the deterministic DAG from its payload under current, independently
    // bound policy. A valid serialized graph alone cannot omit or forge the
    // terminal policy update, exclusivity, or invalidation boundary.
    static func matchesPolicyBoundary(_ plan: Body3BatchPlan,
                                      governedRoot: GovernedRootRole) -> Bool {
        let operations = plan.nodes.compactMap { node -> PlannedOperation? in
            if case let .operation(operation) = node.payload { return operation }
            return nil
        }
        let confirmations = plan.nodes.compactMap { node -> [RemovalSelection]? in
            if case let .confirmation(rows) = node.payload { return rows }
            return nil
        }
        guard confirmations.count <= 1,
              let expected = try? make(run: plan.run, operations: operations,
                                       removals: confirmations.first ?? [],
                                       governedRoot: governedRoot) else { return false }
        return plan.nodes == expected.nodes
            && plan.policyEvidenceDigest == expected.policyEvidenceDigest
    }

    public static func make(
        run: String,
        operations: [PlannedOperation],
        removals: [RemovalSelection],
        governedRoot: GovernedRootRole
    ) throws -> Body3BatchPlan {
        let selectedWorktreeIDs = Set(
            removals.compactMap {
                $0.candidate.worktree?.id
            }
        )
        guard Set(operations.map(\.id)).count
                == operations.count,
              Set(removals.map {
                  $0.candidate.id
              }).count == removals.count,
              operations.allSatisfy(\.isSelectable),
              removals.allSatisfy({
                  $0.candidate.canSelect
                    || (
                        !$0.candidate.dependencies.isEmpty
                            && $0.candidate.hardExclusion == nil
                            && $0.candidate.dependencies
                                .allSatisfy(
                                    selectedWorktreeIDs.contains
                                )
                    )
              }) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 batch selection contains duplicates"
            )
        }
        var nodes: [Body3BatchNode] = []
        var repositoryTail: [String: [String]] = [:]
        let governedRootID = governedRoot.repositoryID
        let rootFastForward = operations.first {
            $0.kind == .fastForward
                && $0.target.repository.id == governedRootID
        }
        guard rootFastForward == nil
                || !operations.contains(where: {
                    $0.target.repository.id == governedRootID
                        && $0.kind != .fastForward
                }),
              rootFastForward == nil
                || !removals.contains(where: {
                    $0.candidate.repository.id == governedRootID
                }) else {
            throw GitSafetyError.unsafeRepository(
                "The host-policy repository cannot combine Fast-forward with Repair or Remove"
            )
        }

        let ordinaryOperations = operations.filter {
            $0.target.repository.id != governedRootID
                || $0.kind != .fastForward
        }
        for group in Dictionary(
            grouping: ordinaryOperations,
            by: { $0.target.repository.id }
        ).sorted(by: { $0.key < $1.key }) {
            let repositoryID = group.key
            let commonKey = group.value[0]
                .target.canonicalClone.id
            let repairs = group.value.filter {
                $0.kind != .fastForward
            }.sorted { $0.id < $1.id }
            var repairIDs: [String] = []
            for operation in repairs {
                let node = try operationNode(
                    operation,
                    dependencies: []
                )
                nodes.append(node)
                repairIDs.append(node.id)
            }
            var tail = repairIDs
            if !repairs.isEmpty {
                let inspect = try node(
                    repositoryID: repositoryID,
                    commonKey: commonKey,
                    kind: .reinspection,
                    discriminator: "after-repair",
                    dependencies: repairIDs.map {
                        Body3BatchDependency(nodeID: $0)
                    },
                    payload: .reinspection(
                        repositoryID: repositoryID,
                        cloneID: commonKey,
                        reason: "after-repair"
                    )
                )
                nodes.append(inspect)
                tail = [inspect.id]
            }
            if let fastForward = group.value.first(
                where: { $0.kind == .fastForward }
            ) {
                let update = try operationNode(
                    fastForward,
                    dependencies: tail.map {
                        Body3BatchDependency(nodeID: $0)
                    }
                )
                nodes.append(update)
                let inspect = try node(
                    repositoryID: repositoryID,
                    commonKey: commonKey,
                    kind: .reinspection,
                    discriminator: "after-fast-forward",
                    dependencies: [
                        Body3BatchDependency(
                            nodeID: update.id
                        ),
                    ],
                    payload: .reinspection(
                        repositoryID: repositoryID,
                        cloneID: commonKey,
                        reason: "after-fast-forward"
                    )
                )
                nodes.append(inspect)
                tail = [inspect.id]
            }
            repositoryTail[repositoryID] = tail
        }

        var confirmationPrerequisiteIDs = Set<String>()
        var removalPrerequisitesByCandidate:
            [String: [Body3BatchDependency]] = [:]
        var removalInspectionByClone: [String: String] = [:]
        for selection in removals.sorted(by: {
            $0.candidate.id < $1.candidate.id
        }) {
            let candidate = selection.candidate
            var dependencies = repositoryTail[
                candidate.repository.id,
                default: []
            ].map {
                Body3BatchDependency(nodeID: $0)
            }
            if dependencies.isEmpty {
                if let inspectionID =
                        removalInspectionByClone[
                            candidate.clone.id
                        ] {
                    dependencies = [
                        Body3BatchDependency(
                            nodeID: inspectionID
                        ),
                    ]
                } else {
                    let inspect = try node(
                        repositoryID:
                            candidate.repository.id,
                        commonKey: candidate.clone.id,
                        kind: .reinspection,
                        discriminator:
                            "before-removal-\(candidate.clone.id)",
                        dependencies: [],
                        payload: .reinspection(
                            repositoryID:
                                candidate.repository.id,
                            cloneID: candidate.clone.id,
                            reason: "before-removal"
                        )
                    )
                    nodes.append(inspect)
                    removalInspectionByClone[
                        candidate.clone.id
                    ] = inspect.id
                    dependencies = [
                        Body3BatchDependency(
                            nodeID: inspect.id
                        ),
                    ]
                }
            }
            for dependency in dependencies {
                confirmationPrerequisiteIDs.insert(
                    dependency.nodeID
                )
            }
            if candidate.requiresRecoveryAttempt {
                let preparation = try node(
                    repositoryID:
                        candidate.repository.id,
                    commonKey: candidate.clone.id,
                    kind: .retention,
                    discriminator: candidate.id,
                    dependencies: dependencies,
                    payload: .retention(selection)
                )
                nodes.append(preparation)
                confirmationPrerequisiteIDs.insert(
                    preparation.id
                )
                removalPrerequisitesByCandidate[
                    candidate.id
                ] = [
                    Body3BatchDependency(
                        nodeID: preparation.id,
                        requiresSuccess: false
                    ),
                ]
            } else {
                removalPrerequisitesByCandidate[
                    candidate.id
                ] = dependencies
            }
        }

        var confirmationID: String?
        if !removals.isEmpty {
            let dependencies = confirmationPrerequisiteIDs
                .sorted().map {
                Body3BatchDependency(
                    nodeID: $0,
                    requiresSuccess: false
                )
            }
            let confirmation = try node(
                repositoryID: nil,
                commonKey: nil,
                kind: .groupedRemovalConfirmation,
                discriminator: "all-selected-removals",
                dependencies: dependencies,
                payload: .confirmation(removals),
                exclusive: true
            )
            nodes.append(confirmation)
            confirmationID = confirmation.id
        }

        var worktreeRemovalIDsByClone:
            [String: [String]] = [:]
        for selection in removals where
            selection.candidate.kind == .worktree {
            let candidate = selection.candidate
            var dependencies = confirmationID.map {
                [Body3BatchDependency(nodeID: $0)]
            } ?? []
            dependencies.append(
                contentsOf:
                    removalPrerequisitesByCandidate[
                        candidate.id,
                        default: []
                    ]
            )
            let removal = try node(
                repositoryID: candidate.repository.id,
                commonKey: candidate.clone.id,
                kind: .worktreeRemoval,
                discriminator: candidate.id,
                dependencies: dependencies,
                payload: .removal(candidate)
            )
            nodes.append(removal)
            worktreeRemovalIDsByClone[
                candidate.clone.id,
                default: []
            ].append(removal.id)
            let residue = try node(
                repositoryID: candidate.repository.id,
                commonKey: candidate.clone.id,
                kind: .residueVerification,
                discriminator: candidate.id,
                dependencies: [
                    Body3BatchDependency(
                        nodeID: removal.id,
                        requiresSuccess: false
                    ),
                ],
                payload: .residue(candidate)
            )
            nodes.append(residue)
        }

        for selection in removals where
            selection.candidate.kind == .branch {
            let candidate = selection.candidate
            var claimDependencies = confirmationID.map {
                [Body3BatchDependency(nodeID: $0)]
            } ?? []
            claimDependencies.append(
                contentsOf:
                    removalPrerequisitesByCandidate[
                        candidate.id,
                        default: []
                    ]
            )
            claimDependencies.append(
                contentsOf:
                    worktreeRemovalIDsByClone[
                        candidate.clone.id,
                        default: []
                    ].sorted()
                    .map {
                        Body3BatchDependency(
                            nodeID: $0,
                            requiresSuccess: false
                        )
                    }
            )
            let inspect = try node(
                repositoryID: candidate.repository.id,
                commonKey: candidate.clone.id,
                kind: .claimReinspection,
                discriminator: candidate.id,
                dependencies: claimDependencies,
                payload: .reinspection(
                    repositoryID: candidate.repository.id,
                    cloneID: candidate.clone.id,
                    reason: "before-branch-removal"
                )
            )
            nodes.append(inspect)
            let removal = try node(
                repositoryID: candidate.repository.id,
                commonKey: candidate.clone.id,
                kind: .branchRemoval,
                discriminator: candidate.id,
                dependencies: [
                    Body3BatchDependency(nodeID: inspect.id),
                ],
                payload: .removal(candidate)
            )
            nodes.append(removal)
            let residue = try node(
                repositoryID: candidate.repository.id,
                commonKey: candidate.clone.id,
                kind: .residueVerification,
                discriminator: candidate.id,
                dependencies: [
                    Body3BatchDependency(
                        nodeID: removal.id,
                        requiresSuccess: false
                    ),
                ],
                payload: .residue(candidate)
            )
            nodes.append(residue)
        }

        if let rootFastForward {
            let allPrior = nodes.map(\.id).sorted().map {
                Body3BatchDependency(
                    nodeID: $0,
                    requiresSuccess: false
                )
            }
            let update = try Body3BatchNode(
                id: nodeID(
                    repositoryID: governedRootID,
                    kind: .fastForward,
                    discriminator: rootFastForward.id
                ),
                repositoryID: governedRootID,
                commonDirectoryKey:
                    rootFastForward.target.canonicalClone.id,
                kind: .fastForward,
                dependencies: allPrior,
                payload: .operation(rootFastForward),
                requiresExclusiveWorkerPool: true
            )
            nodes.append(update)
            let invalidate = try node(
                repositoryID: governedRootID,
                commonKey:
                    rootFastForward.target.canonicalClone.id,
                kind: .policyInvalidation,
                discriminator: "after-policy-root-fast-forward",
                dependencies: [
                    Body3BatchDependency(
                        nodeID: update.id,
                        requiresSuccess: false
                    ),
                ],
                payload: .policyInvalidation(
                    repositoryID: governedRootID
                ),
                exclusive: true
            )
            nodes.append(invalidate)
        }
        guard !nodes.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 batch selection is empty"
            )
        }
        return try Body3BatchPlan(
            run: run,
            policyEvidenceDigest:
                evidenceDigest(
                    operations: operations,
                    removals: removals,
                    governedRoot: governedRoot
                ),
            nodes: nodes
        )
    }

    static func evidenceDigest(
        operations: [PlannedOperation],
        removals: [RemovalSelection],
        governedRoot: GovernedRootRole
    ) -> String {
        V2EvidenceDigest.make(
            [governedRoot.repositoryID, governedRoot.policyDigest] + operations.sorted { $0.id < $1.id }.flatMap {
                [
                    $0.id,
                    $0.evidenceDigest,
                    $0.target.repository
                        .policyCategory.rawValue,
                    $0.target.canonicalClone
                        .policyCategory.rawValue,
                ]
            } + removals.sorted {
                $0.candidate.id < $1.candidate.id
            }.flatMap {
                [
                    $0.candidate.id,
                    $0.candidate.evidenceDigest,
                    $0.candidate.repository
                        .policyCategory.rawValue,
                    $0.candidate.clone
                        .policyCategory.rawValue,
                ]
            }
        )
    }

    private static func operationNode(
        _ operation: PlannedOperation,
        dependencies: [Body3BatchDependency]
    ) throws -> Body3BatchNode {
        try Body3BatchNode(
            id: nodeID(
                repositoryID:
                    operation.target.repository.id,
                kind: operation.kind == .fastForward
                    ? .fastForward : .repair,
                discriminator: operation.id
            ),
            repositoryID:
                operation.target.repository.id,
            commonDirectoryKey:
                operation.target.canonicalClone.id,
            kind: operation.kind == .fastForward
                ? .fastForward : .repair,
            dependencies: dependencies,
            payload: .operation(operation),
            requiresExclusiveWorkerPool: false
        )
    }

    private static func node(
        repositoryID: String?,
        commonKey: String?,
        kind: Body3BatchNodeKind,
        discriminator: String,
        dependencies: [Body3BatchDependency],
        payload: Body3BatchPayload,
        exclusive: Bool = false
    ) throws -> Body3BatchNode {
        try Body3BatchNode(
            id: nodeID(
                repositoryID: repositoryID ?? "batch",
                kind: kind,
                discriminator: discriminator
            ),
            repositoryID: repositoryID,
            commonDirectoryKey: commonKey,
            kind: kind,
            dependencies: dependencies,
            payload: payload,
            requiresExclusiveWorkerPool: exclusive
        )
    }

    private static func nodeID(
        repositoryID: String,
        kind: Body3BatchNodeKind,
        discriminator: String
    ) -> String {
        "body3-node:\(kind.rawValue):"
            + String(V2EvidenceDigest.make([
                repositoryID,
                discriminator,
            ]).prefix(24))
    }
}

public struct Body3InfrastructureFailure:
    Codable, Equatable, Sendable {
    public let signature: String
    public let normalizedCategory: String

    public init(
        category: String,
        stableFields: [String]
    ) {
        normalizedCategory = Redactor.sanitize(category)
        signature = String(V2EvidenceDigest.make(
            [normalizedCategory] + stableFields.map {
                Redactor.sanitize($0)
            }
        ).prefix(32))
    }
}

public struct Body3BatchNodeOutcome:
    Equatable, Sendable {
    public let status: Body3BatchNodeStatus
    public let detail: String
    public let infrastructureFailure:
        Body3InfrastructureFailure?
    public let awaAdvisoryFailure: Bool
    public let technicalDetail: String?

    public init(
        status: Body3BatchNodeStatus,
        detail: String,
        infrastructureFailure:
            Body3InfrastructureFailure? = nil,
        awaAdvisoryFailure: Bool = false,
        technicalDetail: String? = nil
    ) {
        precondition(status.isSettled)
        self.status = status
        self.detail = String(
            Redactor.sanitize(detail).prefix(2_048)
        )
        self.infrastructureFailure = infrastructureFailure
        self.awaAdvisoryFailure = awaAdvisoryFailure
        self.technicalDetail =
            Body3TechnicalDetail.canonical(technicalDetail)
    }
}

public enum Body3TechnicalDetail {
    public static let maximumUTF8Bytes = 2_048

    public static func canonical(
        _ input: String?
    ) -> String? {
        guard var value = input.map(Redactor.sanitize) else {
            return nil
        }
        let replacements: [(String, String)] = [
            (
                #"(?i)\b[a-z][a-z0-9+.-]*://[^\s]+"#,
                "[REDACTED URL]"
            ),
            (
                #"(?<![A-Za-z0-9_.-])/(?:[^\s/]+/)*[^\s,;:)\]}]*"#,
                "[REDACTED PATH]"
            ),
            (
                #"\b([A-Z_][A-Z0-9_]{1,63})=[^\s,;]+"#,
                "$1=[REDACTED]"
            ),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ) else {
                continue
            }
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(
                    value.startIndex..<value.endIndex,
                    in: value
                ),
                withTemplate: replacement
            )
        }
        value = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else { return nil }
        var bytes = Data(value.utf8.prefix(maximumUTF8Bytes))
        while String(data: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(data: bytes, encoding: .utf8)
    }

    public static func isCanonical(_ value: String) -> Bool {
        value.utf8.count <= maximumUTF8Bytes
            && canonical(value) == value
    }
}

public struct Body3BatchNodeResult:
    Codable, Equatable, Sendable {
    public let node: Body3BatchNode
    public let status: Body3BatchNodeStatus
    public let worker: Int?
    public let startedAt: String?
    public let endedAt: String
    public let durationMilliseconds: Int64
    public let detail: String
    public let technicalDetail: String?

    public init(
        node: Body3BatchNode,
        status: Body3BatchNodeStatus,
        worker: Int?,
        startedAt: String?,
        endedAt: String,
        durationMilliseconds: Int64,
        detail: String,
        technicalDetail: String? = nil
    ) {
        self.node = node
        self.status = status
        self.worker = worker
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.detail = String(
            Redactor.sanitize(detail).prefix(2_048)
        )
        self.technicalDetail =
            Body3TechnicalDetail.canonical(technicalDetail)
    }
}

public struct Body3BatchProgress:
    Equatable, Sendable {
    public let total: Int
    public let terminal: Int
    public let phase: String
    public let activeWorkers: Int
    public let elapsedMilliseconds: Int64
    public let paused: Bool
}

public struct Body3BatchReport:
    Codable, Equatable, Sendable {
    public let schema: String
    public let run: String
    public let startedAt: String
    public let endedAt: String
    public let cancelled: Bool
    public let paused: Bool
    public let results: [Body3BatchNodeResult]
    public let repositoryCounts: [String: Int]

    public var cleanupPending: Bool { results.contains { $0.status == .cleanupPending } }

    public var requiresReview: Bool {
        cleanupPending || cancelled
            || paused
            || results.contains {
                $0.status == .failed
                    || $0.status == .refused
                    || $0.status == .cancelled
            }
    }

    public init(
        run: String,
        startedAt: String,
        endedAt: String = WallClock.timestamp(),
        cancelled: Bool,
        paused: Bool = false,
        results: [Body3BatchNodeResult]
    ) throws {
        guard RunIdentity.isValid(run),
              !results.isEmpty,
              results.allSatisfy({
                  $0.status.isSettled
              }) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 report requires settled callbacks or explicit cleanup pending"
            )
        }
        schema = "shadow-sync-batch-report/v2"
        self.run = run
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cancelled = cancelled
        self.paused = paused
        self.results = results
        repositoryCounts = Dictionary(
            grouping: results.compactMap { result in
                result.node.repositoryID.map {
                    ($0, result)
                }
            },
            by: \.0
        ).mapValues(\.count)
    }
}

public struct Body3BatchMetadata:
    Equatable, Sendable {
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int64
    public let repositoryIDs: [String]
    public let attemptedActionCount: Int
    public let outcomeCounts: [Body3BatchNodeStatus: Int]

    public static func derive(
        plan: Body3BatchPlan,
        report: Body3BatchReport
    ) throws -> Body3BatchMetadata {
        try deriveForLog(plan: plan, report: report, identity: .current)
    }

    // Historical validation is used only to present preserved evidence. Execution
    // and interrupted-run reconstruction keep their current-identity admission.
    static func deriveForLog(
        plan: Body3BatchPlan,
        report: Body3BatchReport,
        identity: HistoricalLogIdentity
    ) throws -> Body3BatchMetadata {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        guard report.run == plan.run,
              plan.schema == identity.v2Plan,
              report.schema == identity.v2Report,
              report.results.count == plan.nodes.count,
              Set(report.results.map(\.node.id))
                == Set(plan.nodes.map(\.id)),
              report.results.allSatisfy({
                  $0.status.isSettled
                      && plan.nodes.contains($0.node)
                      && $0.durationMilliseconds >= 0
                      && (
                          $0.technicalDetail.map(
                              Body3TechnicalDetail.isCanonical
                          ) ?? true
                      )
              }),
              let start = formatter.date(
                  from: report.startedAt
              ),
              let end = formatter.date(from: report.endedAt),
              end >= start else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 report metadata is contradictory"
            )
        }
        for result in report.results {
            guard let resultEnd = formatter.date(
                from: result.endedAt
            ),
            resultEnd >= start,
            resultEnd <= end else {
                throw GitSafetyError.unsafeRepository(
                    "Body 3 result metadata is contradictory"
                )
            }
            if let startedAt = result.startedAt {
                guard let resultStart = formatter.date(
                    from: startedAt
                ),
                resultStart >= start,
                resultStart <= resultEnd else {
                    throw GitSafetyError.unsafeRepository(
                        "Body 3 action timing is contradictory"
                    )
                }
            }
        }
        let repositories = Array(
            Set(plan.nodes.compactMap(\.repositoryID))
        ).sorted()
        let expectedCounts = Dictionary(
            grouping: report.results.compactMap {
                result in
                result.node.repositoryID.map {
                    ($0, result)
                }
            },
            by: \.0
        ).mapValues(\.count)
        guard expectedCounts == report.repositoryCounts else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 repository totals are contradictory"
            )
        }
        let outcomes = Dictionary(
            grouping: report.results,
            by: \.status
        ).mapValues(\.count)
        return Body3BatchMetadata(
            startedAt: report.startedAt,
            endedAt: report.endedAt,
            durationMilliseconds: Int64(
                end.timeIntervalSince(start) * 1_000
            ),
            repositoryIDs: repositories,
            attemptedActionCount: report.results.filter {
                $0.startedAt != nil
            }.count,
            outcomeCounts: outcomes
        )
    }
}

#if SHADOW_SYNC_TESTING
public extension Body3BatchReport {
    static func testing(
        plan: Body3BatchPlan,
        status: Body3BatchNodeStatus,
        cancelled: Bool,
        paused: Bool = false,
        nodes: [Body3BatchNode]? = nil,
        detail: String = "Synthetic terminal result."
    ) throws -> Body3BatchReport {
        try Body3BatchReport(
            run: plan.run,
            startedAt: plan.createdAt,
            cancelled: cancelled,
            paused: paused,
            results: (nodes ?? plan.nodes).map {
                Body3BatchNodeResult(
                    node: $0,
                    status: status,
                    worker: nil,
                    startedAt: nil,
                    endedAt: WallClock.timestamp(),
                    durationMilliseconds: 0,
                    detail: detail
                )
            }
        )
    }
}
#endif

public final class Body3BatchControl:
    @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false
    private var tokens: [String: CancellationToken] = [:]

    public init() {}

    public func cancel() {
        condition.lock()
        cancelled = true
        let active = Array(tokens.values)
        paused = false
        condition.broadcast()
        condition.unlock()
        active.forEach { $0.cancel() }
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    fileprivate func register(
        _ token: CancellationToken,
        nodeID: String,
        allowAfterCancellation: Bool = false
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled || allowAfterCancellation else {
            return false
        }
        tokens[nodeID] = token
        return true
    }

    fileprivate func unregister(nodeID: String) {
        condition.lock()
        tokens.removeValue(forKey: nodeID)
        condition.unlock()
    }

    fileprivate func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        condition.unlock()
    }

}

public final class Body3BatchCoordinator:
    @unchecked Sendable {
    public typealias NodeRunner = @Sendable (
        Body3BatchNode,
        Int,
        CancellationToken
    ) -> Body3BatchNodeOutcome

    private struct MutableState {
        var status: Body3BatchNodeStatus = .queued
        var worker: Int?
        var startedAt: String?
        var started: MonotonicInstant?
        var endedAt: String?
        var duration: Int64 = 0
        var detail = ""
        var technicalDetail: String?
    }

    private final class SchedulerState:
        @unchecked Sendable {
        var nodes: [String: MutableState]
        var activeKeys = Set<String>()
        var activeWorkers: [Int: String] = [:]
        var consecutiveSignature: String?
        var consecutiveCount = 0

        init(plan: Body3BatchPlan) {
            nodes = Dictionary(
                uniqueKeysWithValues: plan.nodes.map {
                    ($0.id, MutableState())
                }
            )
        }
    }

    public init() {}

    public func execute(
        plan: Body3BatchPlan,
        control: Body3BatchControl,
        externalCancellation: CancellationToken? = nil,
        onProgress: @escaping @Sendable (
            Body3BatchProgress
        ) -> Void = { _ in },
        onNodeTerminal: @escaping @Sendable (
            String,
            Body3BatchNodeStatus
        ) -> Void = { _, _ in },
        runner: @escaping NodeRunner
    ) throws -> Body3BatchReport {
        let condition = NSCondition()
        let queue = DispatchQueue(
            label: "shadow-sync.body3.batch",
            attributes: .concurrent
        )
        let scheduler = SchedulerState(plan: plan)
        let startedAt = WallClock.timestamp()
        let started = MonotonicInstant.now()

        @Sendable func emitProgress(
            phase: String,
            paused: Bool = false
        ) {
            let terminal = scheduler.nodes.values.filter {
                $0.status.isTerminal
            }.count
            onProgress(Body3BatchProgress(
                total: plan.nodes.count,
                terminal: terminal,
                phase: phase,
                activeWorkers:
                    scheduler.activeWorkers.count,
                elapsedMilliseconds:
                    MonotonicInstant.now().milliseconds(
                        since: started
                    ),
                paused: paused
            ))
        }

        condition.lock()
        while scheduler.nodes.values.contains(where: {
            !$0.status.isSettled
        }) {
            if externalCancellation?.isCancelled == true {
                control.cancel()
            }
            if control.isCancelled {
                for node in plan.nodes where
                    scheduler.nodes[node.id]?.status
                        == .queued {
                    let dependencyStatuses =
                        node.dependencies.compactMap {
                            scheduler.nodes[$0.nodeID]?
                                .status
                        }
                    let waiting = dependencyStatuses
                        .contains { !$0.isSettled }
                    let failedRequired =
                        node.dependencies.contains {
                            dependency in
                            dependency.requiresSuccess
                                && scheduler.nodes[
                                    dependency.nodeID
                                ]?.status.isSettled
                                    == true
                                && scheduler.nodes[
                                    dependency.nodeID
                                ]?.status
                                    != .succeeded
                        }
                    if !waiting, !failedRequired,
                       node.kind
                        != .residueVerification {
                        scheduler.nodes[node.id]?.status =
                            .cancelled
                        scheduler.nodes[node.id]?.endedAt =
                            WallClock.timestamp()
                        scheduler.nodes[node.id]?.detail =
                            "Cancelled before admission."
                        onNodeTerminal(
                            node.id,
                            .cancelled
                        )
                    }
                }
            }

            var changed = true
            while changed {
                changed = false
                for node in plan.nodes where
                    scheduler.nodes[node.id]?.status == .queued {
                    let failedDependency =
                        node.dependencies.first {
                            dependency in
                            guard dependency.requiresSuccess,
                                  let status = scheduler.nodes[
                                    dependency.nodeID
                                  ]?.status,
                                  status.isSettled else {
                                return false
                            }
                            return status != .succeeded
                        }
                    if let failedDependency {
                        scheduler.nodes[node.id]?.status =
                            .running
                        scheduler.nodes[node.id]?.startedAt =
                            WallClock.timestamp()
                        scheduler.nodes[node.id]?.started =
                            MonotonicInstant.now()
                        scheduler.nodes[node.id]?.status =
                            .skipped
                        scheduler.nodes[node.id]?.endedAt =
                            WallClock.timestamp()
                        scheduler.nodes[node.id]?.detail =
                            "Skipped because dependency \(failedDependency.nodeID) did not succeed."
                        onNodeTerminal(
                            node.id,
                            .skipped
                        )
                        changed = true
                    }
                }
            }

            if scheduler.nodes.values.allSatisfy({
                $0.status.isSettled
            }) {
                break
            }

            if control.isPaused {
                emitProgress(
                    phase:
                        "Paused after repeated infrastructure failure",
                    paused: true
                )
                if scheduler.activeWorkers.isEmpty {
                    for id in scheduler.nodes.keys where
                        scheduler.nodes[id]?.status == .queued {
                        scheduler.nodes[id]?.status =
                            .running
                        scheduler.nodes[id]?.startedAt =
                            WallClock.timestamp()
                        scheduler.nodes[id]?.started =
                            MonotonicInstant.now()
                        scheduler.nodes[id]?.status =
                            .skipped
                        scheduler.nodes[id]?.endedAt =
                            WallClock.timestamp()
                        scheduler.nodes[id]?.detail =
                            "Skipped after the infrastructure circuit breaker paused new admission."
                        onNodeTerminal(
                            id,
                            .skipped
                        )
                    }
                    break
                }
                _ = condition.wait(
                    until: Date(
                        timeIntervalSinceNow: 0.05
                    )
                )
                continue
            }

            var admittedAny = false
            for node in plan.nodes where
                scheduler.nodes[node.id]?.status == .queued {
                guard scheduler.activeWorkers.count < 2 else {
                    break
                }
                let dependenciesTerminal =
                    node.dependencies.allSatisfy {
                        scheduler.nodes[$0.nodeID]?
                            .status.isSettled
                            == true
                    }
                guard dependenciesTerminal else { continue }
                if node.requiresExclusiveWorkerPool,
                   !scheduler.activeWorkers.isEmpty {
                    continue
                }
                if !node.requiresExclusiveWorkerPool,
                   scheduler.activeWorkers.values.contains(where: {
                       activeID in
                       plan.nodes.first {
                           $0.id == activeID
                       }?.requiresExclusiveWorkerPool == true
                   }) {
                    continue
                }
                if let key = node.commonDirectoryKey,
                   scheduler.activeKeys.contains(key) {
                    continue
                }
                let worker = [1, 2].first {
                    scheduler.activeWorkers[$0] == nil
                }!
                let token = CancellationToken()
                guard control.register(
                    token,
                    nodeID: node.id,
                    allowAfterCancellation:
                        node.kind
                            == .residueVerification
                ) else {
                    scheduler.nodes[node.id]?.status =
                        .cancelled
                    scheduler.nodes[node.id]?.endedAt =
                        WallClock.timestamp()
                    onNodeTerminal(
                        node.id,
                        .cancelled
                    )
                    continue
                }
                scheduler.nodes[node.id]?.status = .running
                scheduler.nodes[node.id]?.worker = worker
                scheduler.nodes[node.id]?.startedAt =
                    WallClock.timestamp()
                scheduler.nodes[node.id]?.started =
                    MonotonicInstant.now()
                scheduler.activeWorkers[worker] = node.id
                if let key = node.commonDirectoryKey {
                    scheduler.activeKeys.insert(key)
                }
                admittedAny = true
                emitProgress(phase: node.kind.phase)
                queue.async {
                    let outcome = runner(
                        node,
                        worker,
                        token
                    )
                    condition.lock()
                    let end = MonotonicInstant.now()
                    if let begin =
                        scheduler.nodes[node.id]?.started {
                        scheduler.nodes[node.id]?.duration =
                            end.milliseconds(since: begin)
                    }
                    scheduler.nodes[node.id]?.status =
                        outcome.status
                    scheduler.nodes[node.id]?.endedAt =
                        WallClock.timestamp()
                    scheduler.nodes[node.id]?.detail =
                        outcome.detail
                    scheduler.nodes[node.id]?.technicalDetail =
                        outcome.technicalDetail
                    if outcome.status.isTerminal {
                        onNodeTerminal(node.id, outcome.status)
                    }
                    scheduler.activeWorkers.removeValue(
                        forKey: worker
                    )
                    if let key = node.commonDirectoryKey {
                        scheduler.activeKeys.remove(key)
                    }
                    control.unregister(nodeID: node.id)
                    if outcome.status == .succeeded {
                        scheduler.consecutiveSignature = nil
                        scheduler.consecutiveCount = 0
                    } else if outcome.awaAdvisoryFailure {
                        // Advisory AWA outcomes neither advance nor
                        // erase the infrastructure-failure sequence.
                    } else if
                        let failure =
                            outcome.infrastructureFailure {
                        if scheduler.consecutiveSignature
                            == failure.signature {
                            scheduler.consecutiveCount += 1
                        } else {
                            scheduler.consecutiveSignature =
                                failure.signature
                            scheduler.consecutiveCount = 1
                        }
                        if scheduler.consecutiveCount >= 3 {
                            control.pause()
                        }
                    } else if outcome.infrastructureFailure
                                == nil {
                        scheduler.consecutiveSignature = nil
                        scheduler.consecutiveCount = 0
                    }
                    emitProgress(
                        phase: node.kind.phase,
                        paused: control.isPaused
                    )
                    condition.broadcast()
                    condition.unlock()
                }
                if node.requiresExclusiveWorkerPool {
                    break
                }
            }
            if !admittedAny {
                _ = condition.wait(
                    until: Date(
                        timeIntervalSinceNow: 0.05
                    )
                )
            }
        }
        condition.unlock()

        let results = plan.nodes.map { node in
            let state = scheduler.nodes[node.id]!
            return Body3BatchNodeResult(
                node: node,
                status: state.status,
                worker: state.worker,
                startedAt: state.startedAt,
                endedAt:
                    state.endedAt ?? WallClock.timestamp(),
                durationMilliseconds: state.duration,
                detail: state.detail,
                technicalDetail: state.technicalDetail
            )
        }
        return try Body3BatchReport(
            run: plan.run,
            startedAt: startedAt,
            cancelled: control.isCancelled
                || results.contains {
                    $0.node.kind
                        == .groupedRemovalConfirmation
                        && $0.status == .cancelled
                },
            paused: control.isPaused,
            results: results
        )
    }
}
