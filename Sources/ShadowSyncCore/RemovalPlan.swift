import Foundation

public enum RemovalEntityKind: String, Codable, Equatable, Sendable {
    case worktree
    case branch

    public var operatorLabel: String {
        switch self {
        case .worktree: return "Worktree"
        case .branch: return "Branch"
        }
    }
}

public enum RemovalIdentityAccent:
    String, Codable, Equatable, Sendable {
    case teal
    case purple
}

public enum RemovalPullRequestAccent:
    String, Codable, Equatable, Sendable {
    case draft
    case open
    case merged
    case closed

    public init(_ state: PullRequestState) {
        switch state {
        case .draft: self = .draft
        case .open: self = .open
        case .merged: self = .merged
        case .closed: self = .closed
        }
    }
}

public struct RemovalCardPresentationSnapshot:
    Codable, Equatable, Sendable {
    public let identityLabel: String
    public let identityGlyph: String
    public let identitySystemSymbol: String
    public let secondaryIdentitySystemSymbol: String?
    public let accent: RemovalIdentityAccent
    public let recommendationLabel: String
    public let permissionLabel: String
    public let actionLabel: String
    public let pullRequestLabels: [String]
    public let pullRequestAccents:
        [RemovalPullRequestAccent]
    public let dependencies: [String]
    public let selectable: Bool
    public let selectAllEligible: Bool

    public init(candidate: RemovalCandidate) {
        switch candidate.kind {
        case .worktree:
            identityLabel = "WORKTREE"
            identityGlyph = "▱"
            identitySystemSymbol = "folder"
            secondaryIdentitySystemSymbol =
                "arrow.triangle.branch"
            accent = .teal
        case .branch:
            identityLabel = "BRANCH"
            identityGlyph = "⑂"
            identitySystemSymbol = "arrow.triangle.branch"
            secondaryIdentitySystemSymbol = nil
            accent = .purple
        }
        recommendationLabel =
            candidate.preview.recommendation.operatorLabel
        permissionLabel =
            candidate.preview.permission.operatorLabel
        if !candidate.dependencies.isEmpty {
            actionLabel = "Remove claiming Worktrees first"
        } else {
            switch candidate.preview.recommendation {
            case .recommended:
                actionLabel = "Remove"
            case .recovery:
                actionLabel = "Remove with recovery"
            case .keep:
                actionLabel = "Remove anyway…"
            case .override:
                actionLabel = "Operator override…"
            case .hardExcluded:
                actionLabel = "Protected"
            }
        }
        let branch = candidate.branch
            ?? candidate.worktree?.attachedBranchRef
                .flatMap { reference in
                    candidate.clone.branches.first {
                        $0.fullRef == reference
                    }
                }
        if branch?.pullRequestAvailability == .unavailable {
            pullRequestLabels = ["Unavailable"]
            pullRequestAccents = []
        } else if branch?.pullRequests?.isEmpty != false {
            pullRequestLabels = ["No known PR"]
            pullRequestAccents = []
        } else {
            pullRequestLabels = (branch?.pullRequests ?? [])
                .map {
                    "#\($0.number) · \($0.state.operatorLabel)"
                }
            pullRequestAccents =
                (branch?.pullRequests ?? []).map {
                    RemovalPullRequestAccent($0.state)
                }
        }
        dependencies = candidate.dependencies
        selectable = candidate.canSelect
        selectAllEligible = candidate.selectAllEligible
    }
}

public enum RemovalSelectionIntent: String, Codable, Equatable, Sendable {
    case remove
    case removeWithRecovery
    case removeAnyway
    case operatorOverride

    public var isExplicitOverride: Bool {
        self == .removeAnyway || self == .operatorOverride
    }
}

public enum RemovalFinalClass: String, Codable, Equatable, Sendable {
    case recommended
    case recoveryBacked
    case operatorOverrideRisk

    public var operatorLabel: String {
        switch self {
        case .recommended: return "Recommended"
        case .recoveryBacked: return "Recovery-backed"
        case .operatorOverrideRisk:
            return "Operator override — data/disruption risk"
        }
    }
}

public enum RemovalForceLevel: String, Codable, Equatable, Sendable {
    case ordinaryOnly
    case singleForce
    case doubleForceLocked

    public var arguments: [String] {
        switch self {
        case .ordinaryOnly: return []
        case .singleForce: return ["--force"]
        case .doubleForceLocked: return ["--force", "--force"]
        }
    }
}

public struct RemovalCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repository: RemoteRepository
    public let clone: LocalClone
    public let kind: RemovalEntityKind
    public let worktree: Worktree?
    public let branch: Branch?
    public let preview: RemovalPreview
    public let evidenceDigest: String
    public let hardExclusion: String?

    public init(
        repository: RemoteRepository,
        clone: LocalClone,
        worktree: Worktree,
        hardExclusion: String? = nil
    ) throws {
        guard clone.repositoryID == repository.id,
              worktree.cloneID == clone.id,
              clone.worktrees.contains(worktree) else {
            throw GitSafetyError.unsafeRepository(
                "removal worktree is not bound to the selected clone"
            )
        }
        id = "removal:\(worktree.id)"
        self.repository = repository
        self.clone = clone
        kind = .worktree
        self.worktree = worktree
        branch = nil
        let exclusion = Self.hardExclusion(
            repository: repository,
            clone: clone,
            worktree: worktree,
            branch: nil,
            explicit: hardExclusion
        )
        self.hardExclusion = exclusion
        preview = exclusion.map {
            RemovalPreview(
                recommendation: .hardExcluded,
                permission: .hardExcluded,
                explanation: $0
            )
        } ?? worktree.removalPreview ?? RemovalPreview(
            recommendation: .keep,
            permission: .previewOnly,
            explanation:
                "Removal evidence is incomplete; keeping this worktree is recommended.",
            overrideConsequence:
                "Remove anyway accepts the displayed unknown worktree risk."
        )
        evidenceDigest = V2EvidenceDigest.make([
            id,
            repository.id,
            clone.authorityEvidenceDigest,
            worktree.evidenceDigest,
            preview.recommendation.rawValue,
            preview.permission.rawValue,
            preview.dependencies.joined(separator: ","),
            preview.explanation,
            preview.recoveryConsequence ?? "no-recovery-consequence",
            preview.overrideConsequence ?? "no-override-consequence",
            exclusion ?? "in-scope",
        ])
    }

    public init(
        repository: RemoteRepository,
        clone: LocalClone,
        branch: Branch,
        hardExclusion: String? = nil
    ) throws {
        guard clone.repositoryID == repository.id,
              branch.cloneID == clone.id,
              clone.branches.contains(branch) else {
            throw GitSafetyError.unsafeRepository(
                "removal branch is not bound to the selected clone"
            )
        }
        id = "removal:\(branch.id)"
        self.repository = repository
        self.clone = clone
        kind = .branch
        worktree = nil
        self.branch = branch
        let exclusion = Self.hardExclusion(
            repository: repository,
            clone: clone,
            worktree: nil,
            branch: branch,
            explicit: hardExclusion
        )
        self.hardExclusion = exclusion
        preview = exclusion.map {
            RemovalPreview(
                recommendation: .hardExcluded,
                permission: .hardExcluded,
                explanation: $0
            )
        } ?? branch.removalPreview ?? RemovalPreview(
            recommendation: .keep,
            permission: branch.claimingWorktreeIDs.isEmpty
                ? .previewOnly : .dependencyBlocked,
            dependencies: branch.claimingWorktreeIDs,
            explanation:
                "Removal evidence is incomplete; keeping this branch is recommended.",
            overrideConsequence:
                "Remove anyway accepts the displayed unknown branch-history risk."
        )
        evidenceDigest = V2EvidenceDigest.make([
            id,
            repository.id,
            clone.authorityEvidenceDigest,
            branch.evidenceDigest,
            preview.recommendation.rawValue,
            preview.permission.rawValue,
            preview.dependencies.joined(separator: ","),
            preview.explanation,
            preview.recoveryConsequence ?? "no-recovery-consequence",
            preview.overrideConsequence ?? "no-override-consequence",
            exclusion ?? "in-scope",
        ])
    }

    public var target: String {
        worktree?.path ?? branch?.fullRef ?? ""
    }

    public var expectedOID: String? {
        branch?.tipOID
            ?? worktree?.detachedOID
            ?? worktree.flatMap { selected in
                clone.branches.first {
                    $0.fullRef == selected.attachedBranchRef
                }?.tipOID
            }
    }

    public var dependencies: [String] {
        preview.dependencies
    }

    public var canSelect: Bool {
        hardExclusion == nil
            && preview.permission == .previewOnly
    }

    public var selectAllEligible: Bool {
        canSelect && preview.recommendation == .recommended
    }

    public var requiresIndividualChoice: Bool {
        !selectAllEligible
    }

    public var requiresRecoveryAttempt: Bool {
        if preview.recommendation == .recovery
            || preview.recommendation == .override {
            return true
        }
        if worktree?.fileState?.isClean == false {
            return true
        }
        return !hasVerifiedHistorySink
    }

    var hasVerifiedHistorySink: Bool {
        let relation =
            branch?.relationToDefault
                ?? worktree?.relationToDefault
        if relation?.kind == .equal
            || relation?.kind == .behind {
            return true
        }
        let attached = worktree?.attachedBranchRef.flatMap {
            reference in
            clone.branches.first {
                $0.fullRef == reference
            }
        }
        let upstream = branch?.upstream
            ?? attached?.upstream
        return upstream?.fullRef.hasPrefix(
            "refs/remotes/origin/"
        ) == true
            && upstream?.localOID == upstream?.upstreamOID
    }

    public var defaultIntent: RemovalSelectionIntent {
        switch preview.recommendation {
        case .recommended: return .remove
        case .recovery: return .removeWithRecovery
        case .keep: return .removeAnyway
        case .override: return .operatorOverride
        case .hardExcluded: return .operatorOverride
        }
    }

    func liveRiskIsNoWorse(
        than original: RemovalCandidate
    ) -> Bool {
        guard kind == original.kind,
              !original.hasVerifiedHistorySink
                || hasVerifiedHistorySink,
              Self.recommendationRisk(
                  preview.recommendation
              ) <= Self.recommendationRisk(
                  original.preview.recommendation
              ),
              Self.activityRisk(
                  branch?.activity
                    ?? worktree?.activity
              ) <= Self.activityRisk(
                  original.branch?.activity
                    ?? original.worktree?.activity
              ),
              Self.purposeRisk(
                  branch?.purpose?.purpose
                    ?? worktree?.purpose?.purpose
              ) <= Self.purposeRisk(
                  original.branch?.purpose?.purpose
                    ?? original.worktree?
                        .purpose?.purpose
              ) else {
            return false
        }
        if let worktree {
            let previous = original.worktree
            guard worktree.currentSession != true
                    || previous?
                        .currentSession == true,
                  !worktree.isLocked
                    || previous?.isLocked == true,
                  Self.awaRisk(
                      worktree.awaEvidence?.state
                        ?? .unavailable
                  ) <= Self.awaRisk(
                      previous?.awaEvidence?.state
                        ?? .unavailable
                  ) else {
                return false
            }
        }
        return true
    }

    private static func recommendationRisk(
        _ recommendation: RemovalRecommendation
    ) -> Int {
        switch recommendation {
        case .recommended: return 0
        case .recovery: return 1
        case .keep: return 2
        case .override: return 3
        case .hardExcluded: return 4
        }
    }

    private static func activityRisk(
        _ activity: ActivityBand?
    ) -> Int {
        switch activity {
        case .idle, .staleCandidate:
            return 0
        case .recent:
            return 2
        case .unavailable, nil:
            return 1
        }
    }

    private static func purposeRisk(
        _ purpose: WorkPurpose?
    ) -> Int {
        switch purpose {
        case .completed, .integrated:
            return 0
        case .superseded, .noKnownPullRequest:
            return 1
        case .active, .ambiguous,
             .closedIncomplete, .unavailable, nil:
            return 2
        }
    }

    private static func awaRisk(
        _ state: AWAEvidenceState
    ) -> Int {
        switch state {
        case .notManaged: return 0
        case .dead, .stale, .untracked: return 1
        case .unavailable: return 2
        case .active: return 3
        }
    }

    private static func hardExclusion(
        repository: RemoteRepository,
        clone: LocalClone,
        worktree: Worktree?,
        branch: Branch?,
        explicit: String?
    ) -> String? {
        if let explicit {
            return Redactor.sanitize(explicit)
        }
        guard repository.policyCategory == .writable,
              clone.policyCategory == .writable,
              clone.kind == .primaryCheckout,
              clone.sourceSnapshot.blockedReason != .permanentNoTouch else {
            return "Protected, repository-owned, no-touch, or reference repository state has no removal control."
        }
        guard let resolvedDefault = repository.resolvedDefault else {
            return "The actual default branch is unavailable, so non-default identity cannot be proven."
        }
        if let branch,
           branch.fullRef == resolvedDefault.localRef {
            return "The resolved local default branch cannot be removed."
        }
        if let branch,
           (
               branch.tipOID == nil
                || !GitReferenceSyntax
                    .isValidLocalBranchRef(
                        branch.fullRef
                    )
           ) {
            return "A local Branch without an exact verified ref and tip cannot be removed."
        }
        if let branch,
           branch.removalPreview == nil
            || branch.relationToDefault == nil
            || branch.relationToDefault?.kind == .unavailable
            || branch.pullRequestAvailability != .available {
            return "Branch inspection evidence is incomplete, so this branch remains unavailable and retained."
        }
        if let worktree {
            guard worktree.verification == .verified,
                  worktree.rootIdentity != nil else {
                return "A path not exactly bound to a verified Git worktree registration cannot be removed."
            }
            if worktree.isPrimary {
                return "A primary checkout is not a Git-removable linked Worktree; the canonical update target remains protected."
            }
            guard worktree.registrationIdentity != nil else {
                return "The linked Worktree registration identity is incomplete and cannot be removed."
            }
            guard worktree.removalPreview != nil,
                  worktree.fileState != nil,
                  worktree.contentEvidenceDigest != nil,
                  worktree.relationToDefault != nil,
                  worktree.relationToDefault?.kind != .unavailable else {
                return "Worktree inspection evidence is incomplete, so this Worktree remains unavailable and retained."
            }
            if let attachedRef = worktree.attachedBranchRef {
                let attached = clone.branches.filter {
                    $0.fullRef == attachedRef
                }
                guard attached.count == 1,
                      attached[0].relationToDefault != nil,
                      attached[0].relationToDefault?.kind
                        != .unavailable,
                      attached[0].pullRequestAvailability
                        == .available else {
                    return "Attached Branch evidence for this Worktree is incomplete, so this Worktree remains unavailable and retained."
                }
            }
            if worktree.attachedBranchRef == resolvedDefault.localRef {
                return "A worktree claiming the resolved default branch cannot be removed."
            }
        }
        return nil
    }
}

public struct RemovalSelection: Codable, Equatable, Sendable {
    public let candidate: RemovalCandidate
    public let intent: RemovalSelectionIntent
    public let includePossibleSecrets: Bool
    public let selectedAt: String

    public init(
        candidate: RemovalCandidate,
        intent: RemovalSelectionIntent,
        includePossibleSecrets: Bool,
        dependenciesSatisfied: Bool = false,
        selectedAt: String = WallClock.timestamp()
    ) throws {
        guard (
                candidate.canSelect
                    || (
                        dependenciesSatisfied
                            && !candidate.dependencies.isEmpty
                            && candidate.hardExclusion == nil
                            && candidate.preview.permission
                                == .dependencyBlocked
                    )
              ),
              intent == candidate.defaultIntent
                || intent.isExplicitOverride else {
            throw GitSafetyError.unsafeRepository(
                "removal selection is not explicitly permitted"
            )
        }
        self.candidate = candidate
        self.intent = intent
        self.includePossibleSecrets = includePossibleSecrets
        self.selectedAt = selectedAt
    }
}

public struct PreparedRemoval: Codable, Equatable, Sendable {
    public let selection: RemovalSelection
    public let finalClass: RemovalFinalClass
    public let artifact: RetentionArtifactSummary?
    public let consequence: String
    public let forceLevel: RemovalForceLevel
    public let historyLossAccepted: Bool

    public init(
        selection: RemovalSelection,
        finalClass: RemovalFinalClass,
        artifact: RetentionArtifactSummary?,
        consequence: String,
        forceLevel: RemovalForceLevel,
        historyLossAccepted: Bool
    ) throws {
        if finalClass == .recoveryBacked {
            guard artifact?.restoreProven == true else {
                throw GitSafetyError.unsafeRepository(
                    "recovery-backed removal lacks a restore-proven artifact"
                )
            }
        }
        if finalClass == .operatorOverrideRisk {
            guard selection.intent.isExplicitOverride else {
                throw GitSafetyError.unsafeRepository(
                    "operator override was not individually selected"
                )
            }
        }
        if forceLevel == .doubleForceLocked {
            guard finalClass == .operatorOverrideRisk,
                  selection.candidate.worktree?.isLocked == true else {
                throw GitSafetyError.unsafeRepository(
                    "double force is limited to a confirmed locked-worktree override"
                )
            }
        }
        self.selection = selection
        self.finalClass = finalClass
        self.artifact = artifact
        self.consequence = Redactor.sanitize(consequence)
        self.forceLevel = forceLevel
        self.historyLossAccepted = historyLossAccepted
    }
}

public struct ConfirmedRemovalRow: Codable, Equatable, Sendable {
    public let prepared: PreparedRemoval
    public let retained: Bool

    public init(prepared: PreparedRemoval, retained: Bool) {
        self.prepared = prepared
        self.retained = retained
    }
}

public struct GroupedRemovalConfirmation:
    Codable, Equatable, Sendable {
    public let run: String
    public let authorizationID: String
    public let createdAt: String
    public let rows: [ConfirmedRemovalRow]

    public init(
        run: String,
        authorizationID: String = UUID().uuidString.lowercased(),
        createdAt: String = WallClock.timestamp(),
        rows: [ConfirmedRemovalRow]
    ) throws {
        guard RunIdentity.isValid(run),
              !rows.isEmpty,
              Set(rows.map { $0.prepared.selection.candidate.id }).count
                == rows.count,
              !authorizationID.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "grouped removal confirmation is invalid"
            )
        }
        self.run = run
        self.authorizationID = authorizationID
        self.createdAt = createdAt
        self.rows = rows
    }

    public var admitted: [PreparedRemoval] {
        rows.filter(\.retained).map(\.prepared)
    }

    public func authorizes(
        _ runtime: PreparedRemoval
    ) -> Bool {
        if admitted.contains(runtime) {
            return true
        }
        return rows.contains { row in
            guard row.retained else { return false }
            let confirmed = row.prepared
            let original =
                confirmed.selection.candidate
            let fresh = runtime.selection.candidate
            return original.id == fresh.id
                && original.repository.id
                    == fresh.repository.id
                && original.clone.id == fresh.clone.id
                && original.kind == fresh.kind
                && original.target == fresh.target
                && original.expectedOID
                    == fresh.expectedOID
                && original.worktree?.rootIdentity
                    == fresh.worktree?.rootIdentity
                && original.worktree?
                    .registrationIdentity
                    == fresh.worktree?
                        .registrationIdentity
                && original.worktree?
                    .contentEvidenceDigest
                    == fresh.worktree?
                        .contentEvidenceDigest
                && fresh.canSelect
                && fresh.liveRiskIsNoWorse(
                    than: original
                )
                && confirmed.finalClass
                    == runtime.finalClass
                && confirmed.artifact
                    == runtime.artifact
                && confirmed.consequence
                    == runtime.consequence
                && confirmed.forceLevel
                    == runtime.forceLevel
                && confirmed.historyLossAccepted
                    == runtime.historyLossAccepted
                && confirmed.selection
                    .includePossibleSecrets
                    == runtime.selection
                        .includePossibleSecrets
                && (
                    !confirmed.selection.intent
                        .isExplicitOverride
                        || confirmed.selection.intent
                            == runtime.selection.intent
                )
        }
    }

    public func rows(in finalClass: RemovalFinalClass)
        -> [ConfirmedRemovalRow] {
        rows.filter { $0.prepared.finalClass == finalClass }
    }

}

public enum PreparedRemovalOracle {
    public static func prepare(
        selection: RemovalSelection,
        retention: RetentionPreparation?
    ) throws -> PreparedRemoval {
        let artifact: RetentionArtifactSummary?
        let gap: String?
        switch retention {
        case let .completed(summary):
            artifact = summary
            gap = nil
        case let .incomplete(
            excluded, secretShaped, reason
        ):
            artifact = nil
            let names = (excluded + secretShaped)
                .prefix(8)
                .joined(separator: ", ")
            gap = reason
                + (names.isEmpty
                    ? "" : " Omitted: \(names).")
        case .cancelled:
            artifact = nil
            gap = "Recovery preparation was cancelled."
        case nil:
            artifact = nil
            gap = nil
        }

        let candidate = selection.candidate
        let finalSelection: RemovalSelection
        let finalClass: RemovalFinalClass
        if candidate.preview.recommendation == .override
            || candidate.preview.recommendation == .keep {
            finalSelection = try RemovalSelection(
                candidate: candidate,
                intent: .operatorOverride,
                includePossibleSecrets:
                    selection.includePossibleSecrets,
                selectedAt: selection.selectedAt
            )
            finalClass = .operatorOverrideRisk
        } else if artifact?.restoreProven == true {
            finalSelection = selection
            finalClass = .recoveryBacked
        } else if gap != nil {
            finalSelection = try RemovalSelection(
                candidate: candidate,
                intent: .operatorOverride,
                includePossibleSecrets:
                    selection.includePossibleSecrets,
                selectedAt: selection.selectedAt
            )
            finalClass = .operatorOverrideRisk
        } else if candidate.preview.recommendation
            == .recommended {
            finalSelection = selection
            finalClass = .recommended
        } else {
            finalSelection = try RemovalSelection(
                candidate: candidate,
                intent: .operatorOverride,
                includePossibleSecrets:
                    selection.includePossibleSecrets,
                selectedAt: selection.selectedAt
            )
            finalClass = .operatorOverrideRisk
        }

        let force: RemovalForceLevel
        if candidate.kind == .branch {
            force = .ordinaryOnly
        } else if candidate.worktree?.isLocked == true,
           finalClass == .operatorOverrideRisk {
            force = .doubleForceLocked
        } else if finalClass == .recommended {
            force = .ordinaryOnly
        } else {
            force = .singleForce
        }
        let potentialHistoryLoss =
            candidate.kind == .branch
                && artifact == nil
                && !candidate.hasVerifiedHistorySink
        let consequence = [
            gap,
            candidate.preview.overrideConsequence,
            candidate.preview.recoveryConsequence,
            candidate.kind == .worktree
                ? "The exact registered Worktree path may be removed; its Branch is a separate downstream operation."
                : "The exact local Branch ref may be removed after a fresh empty claim set; remote refs are unchanged.",
            candidate.kind == .worktree
                ? "Admitted native force: \(force.rawValue)."
                : "Force deletion is never admitted; only branch -d or exact expected-old update-ref CAS may run.",
        ].compactMap { $0 }.joined(separator: " ")
        return try PreparedRemoval(
            selection: finalSelection,
            finalClass: finalClass,
            artifact: artifact,
            consequence: consequence,
            forceLevel: force,
            historyLossAccepted: potentialHistoryLoss
                && finalClass == .operatorOverrideRisk
        )
    }
}

public struct RemovalSelectionSet: Equatable, Sendable {
    public private(set) var selections: [String: RemovalSelection]

    public init(selections: [String: RemovalSelection] = [:]) {
        self.selections = selections
    }

    public mutating func set(
        candidate: RemovalCandidate,
        selected: Bool,
        intent: RemovalSelectionIntent? = nil,
        includePossibleSecrets: Bool = false
    ) throws {
        if selected {
            selections[candidate.id] = try RemovalSelection(
                candidate: candidate,
                intent: intent ?? candidate.defaultIntent,
                includePossibleSecrets: includePossibleSecrets
            )
        } else {
            selections.removeValue(forKey: candidate.id)
        }
    }

    public mutating func selectAllRecommended(
        _ candidates: [RemovalCandidate],
        selected: Bool
    ) throws {
        for candidate in candidates where candidate.selectAllEligible {
            try set(candidate: candidate, selected: selected)
        }
    }
}

public enum RepositoryInventoryRemovalCandidates {
    public static func make(
        from inventory: RepositoryInventory,
        capability: VerifiedRepositoryAuthorityCapability,
        protectedPaths: [String] = [],
        protectionBoundaryEstablished: Bool = true
    ) -> [RemovalCandidate] {
        guard capability.admits(inventory) else {
            return []
        }
        return makeUnverified(
            from: inventory,
            protectedPaths: protectedPaths,
            protectionBoundaryEstablished:
                protectionBoundaryEstablished
        )
    }

    #if SHADOW_SYNC_TESTING
    public static func make(
        from inventory: RepositoryInventory,
        protectedPaths: [String] = [],
        protectionBoundaryEstablished: Bool = true
    ) -> [RemovalCandidate] {
        makeUnverified(
            from: inventory,
            protectedPaths: protectedPaths,
            protectionBoundaryEstablished:
                protectionBoundaryEstablished
        )
    }
    #endif

    private static func makeUnverified(
        from inventory: RepositoryInventory,
        protectedPaths: [String],
        protectionBoundaryEstablished: Bool
    ) -> [RemovalCandidate] {
        func overlapsProtectedPath(_ path: String) -> Bool {
            protectedPaths.contains {
                path == $0
                    || path.hasPrefix($0 + "/")
                    || $0.hasPrefix(path + "/")
            }
        }
        let unavailableBoundary =
            protectionBoundaryEstablished ? nil
                : "ShadowSync could not establish its private state boundary, so cleanup is unavailable."
        var result: [RemovalCandidate] = []
        for card in inventory.cards {
            for clone in card.clones {
                let cloneProtected = overlapsProtectedPath(
                    clone.primaryRoot
                ) ? "ShadowSync runtime, install, source, and private state paths cannot be removed."
                    : nil
                for worktree in clone.worktrees {
                    let protected = unavailableBoundary
                        ?? cloneProtected
                        ?? (
                            overlapsProtectedPath(worktree.path)
                                ? "ShadowSync runtime, install, source, and private state paths cannot be removed."
                                : nil
                        )
                    if let row = try? RemovalCandidate(
                        repository: card.repository,
                        clone: clone,
                        worktree: worktree,
                        hardExclusion: protected
                    ) {
                        result.append(row)
                    }
                }
                for branch in clone.branches {
                    let incompleteInspection =
                        branch.pullRequestAvailability == .unavailable
                            ? "Pull-request evidence is incomplete, so this branch remains unavailable and retained."
                            : nil
                    if let row = try? RemovalCandidate(
                        repository: card.repository,
                        clone: clone,
                        branch: branch,
                        hardExclusion:
                            unavailableBoundary
                                ?? cloneProtected
                                ?? incompleteInspection
                    ) {
                        result.append(row)
                    }
                }
            }
        }
        return result.sorted {
            if $0.repository.id != $1.repository.id {
                return $0.repository.id < $1.repository.id
            }
            if $0.clone.id != $1.clone.id {
                return $0.clone.id < $1.clone.id
            }
            if $0.kind != $1.kind {
                return $0.kind == .worktree
            }
            return $0.target.localizedStandardCompare($1.target)
                == .orderedAscending
        }
    }
}
