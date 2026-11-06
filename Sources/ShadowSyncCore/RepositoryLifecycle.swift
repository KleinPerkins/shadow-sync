import CryptoKit
import Darwin
import Foundation

enum CurrentSessionWorktreeEvidence: Equatable {
    case active
    case inactive
    case unknown
}

enum CurrentSessionWorktreeDetector {
    static func inspect(
        worktreePath: String,
        account: EffectiveAccount
    ) -> CurrentSessionWorktreeEvidence {
        guard worktreePath.hasPrefix("/"),
              !worktreePath.contains("\0"),
              !worktreePath.contains("\n"),
              !worktreePath.contains("\r") else {
            return .unknown
        }
        guard let directories = capture(
            account: account
        ) else {
            return .unknown
        }
        return directories.contains {
            $0 == worktreePath
                || $0.hasPrefix(worktreePath + "/")
        } ? .active : .inactive
    }

    static func capture(
        account: EffectiveAccount
    ) -> Set<String>? {
        let requestedBytes = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            nil,
            0
        )
        guard requestedBytes > 0 else {
            return nil
        }
        let stride = MemoryLayout<pid_t>.stride
        let capacity = min(
            32_768,
            Int(requestedBytes) / stride + 256
        )
        var processIDs = [pid_t](
            repeating: 0,
            count: capacity
        )
        let availableBytes = processIDs.count * stride
        let usedBytes = processIDs.withUnsafeMutableBytes {
            bytes in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard usedBytes >= 0,
              Int(usedBytes) < availableBytes else {
            return nil
        }
        let count = Int(usedBytes) / stride
        return capture(
            account: account,
            processIDs: Array(processIDs.prefix(count))
        )
    }

    #if SHADOW_SYNC_TESTING
    // Exercise the real kernel probe without inspecting unrelated host processes.
    static func inspectOwnedChild(
        worktreePath: String,
        account: EffectiveAccount,
        child: OwnedDirectChild
    ) throws -> CurrentSessionWorktreeEvidence {
        let root = URL(fileURLWithPath: account.homeDirectory)
            .deletingLastPathComponent().path
        _ = try TestIsolation.validateRoot(root)
        try TestIsolation.validateContainedDirectory(worktreePath, root: root)
        func stillOwnedAndLive() -> Bool {
            child.testingSuspendedSpawnHasResumed
                && child.observation == .running
                && child.terminalStatusHeld == nil
                && child.identity.isCurrent(expectedGeneration: child.identity.generation)
        }
        guard stillOwnedAndLive() else { return .unknown }
        var info = proc_bsdinfo()
        guard proc_pidinfo(
            child.identity.processID, PROC_PIDTBSDINFO, 0, &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        ) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_ppid == UInt32(getpid()),
              info.pbi_uid == account.uid,
              UInt64(info.pbi_start_tvsec) == child.identity.startSeconds,
              UInt64(info.pbi_start_tvusec) == child.identity.startMicroseconds,
              let directories = capture(
                account: account,
                processIDs: [child.identity.processID]
              ), stillOwnedAndLive() else { return .unknown }
        return directories.contains {
            $0 == worktreePath || $0.hasPrefix(worktreePath + "/")
        } ? .active : .inactive
    }
    #endif

    private static func capture(
        account: EffectiveAccount,
        processIDs: [pid_t]
    ) -> Set<String>? {
        var directories = Set<String>()
        var incomplete = false
        for processID in processIDs
        where processID > 1
            && processID != getpid() {
            var process = proc_bsdinfo()
            let processBytes = proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                &process,
                Int32(
                    MemoryLayout<proc_bsdinfo>.size
                )
            )
            guard processBytes
                    == MemoryLayout<proc_bsdinfo>.size,
                  process.pbi_uid == account.uid else {
                continue
            }
            var vnode = proc_vnodepathinfo()
            let vnodeBytes = proc_pidinfo(
                processID,
                PROC_PIDVNODEPATHINFO,
                0,
                &vnode,
                Int32(
                    MemoryLayout<
                        proc_vnodepathinfo
                    >.size
                )
            )
            guard vnodeBytes
                    == MemoryLayout<
                        proc_vnodepathinfo
                    >.size else {
                if kill(processID, 0) == 0 {
                    incomplete = true
                }
                continue
            }
            var pathBytes = withUnsafeBytes(
                of: &vnode.pvi_cdir.vip_path
            ) {
                Array($0)
            }
            if let terminator =
                    pathBytes.firstIndex(of: 0) {
                pathBytes.removeSubrange(
                    terminator...
                )
            }
            let currentDirectory = String(
                decoding: pathBytes,
                as: UTF8.self
            )
            if currentDirectory.hasPrefix("/") {
                directories.insert(currentDirectory)
            }
        }
        return incomplete ? nil : directories
    }
}

public enum WorktreeOperationState: String, Codable, Equatable, Sendable {
    case clear
    case busy
    case unavailable
}

public struct WorktreeFileState: Codable, Equatable, Sendable {
    public let trackedChanges: Int
    public let untrackedFiles: Int
    public let ignoredFiles: Int
    public let hiddenIndexState: Bool
    public let operationState: WorktreeOperationState

    public init(
        trackedChanges: Int,
        untrackedFiles: Int,
        ignoredFiles: Int,
        hiddenIndexState: Bool,
        operationState: WorktreeOperationState
    ) {
        self.trackedChanges = max(0, trackedChanges)
        self.untrackedFiles = max(0, untrackedFiles)
        self.ignoredFiles = max(0, ignoredFiles)
        self.hiddenIndexState = hiddenIndexState
        self.operationState = operationState
    }

    public var isClean: Bool {
        trackedChanges == 0
            && untrackedFiles == 0
            && ignoredFiles == 0
            && !hiddenIndexState
            && operationState == .clear
    }
}

public enum AWAEvidenceState: String, Codable, Equatable, Sendable {
    case notManaged
    case active
    case stale
    case dead
    case untracked
    case unavailable
}

public struct AWAEvidence: Codable, Equatable, Sendable {
    public let state: AWAEvidenceState
    public let leaseID: String?
    public let lastHeartbeatAt: String?
    public let explanation: String
    public let blocksRemoval: Bool
    public let forceOverridableUnknown: Bool

    public init(
        state: AWAEvidenceState,
        leaseID: String? = nil,
        lastHeartbeatAt: String? = nil,
        explanation: String,
        blocksRemoval: Bool,
        forceOverridableUnknown: Bool = false
    ) {
        self.state = state
        self.leaseID = leaseID
        self.lastHeartbeatAt = lastHeartbeatAt
        self.explanation = Redactor.sanitize(explanation)
        self.blocksRemoval = blocksRemoval
        self.forceOverridableUnknown = forceOverridableUnknown
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case leaseID
        case lastHeartbeatAt
        case explanation
        case blocksRemoval
        case forceOverridableUnknown
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(
            keyedBy: CodingKeys.self
        )
        state = try values.decode(
            AWAEvidenceState.self,
            forKey: .state
        )
        leaseID = try values.decodeIfPresent(
            String.self,
            forKey: .leaseID
        )
        lastHeartbeatAt = try values.decodeIfPresent(
            String.self,
            forKey: .lastHeartbeatAt
        )
        explanation = try values.decode(
            String.self,
            forKey: .explanation
        )
        blocksRemoval = try values.decode(
            Bool.self,
            forKey: .blocksRemoval
        )
        forceOverridableUnknown =
            try values.decodeIfPresent(
                Bool.self,
                forKey: .forceOverridableUnknown
            ) ?? false
    }

    public static let notManaged = AWAEvidence(
        state: .notManaged,
        explanation: "No AWA-managed workspace evidence applies.",
        blocksRemoval: false
    )
}

public enum PullRequestState: String, Codable, Equatable, Sendable {
    case draft
    case open
    case merged
    case closed

    public var operatorLabel: String {
        rawValue.capitalized
    }
}

public struct PullRequestRecord:
    Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let number: Int
    public let url: String
    public let repositoryID: String
    public let state: PullRequestState
    public let headRefName: String
    public let headRefOID: String?
    public let isCrossRepository: Bool
    public let updatedAt: String
    public let closedAt: String?
    public let mergedAt: String?

    public init(
        number: Int,
        url: String,
        repositoryID: String,
        state: PullRequestState,
        headRefName: String,
        headRefOID: String?,
        isCrossRepository: Bool,
        updatedAt: String,
        closedAt: String?,
        mergedAt: String?
    ) throws {
        guard number > 0,
              repositoryID == repositoryID.lowercased(),
              GitHubIdentity.parse(
                  "git@github.com:\(repositoryID).git"
              )?.canonicalName == repositoryID,
              Self.validPullRequestURL(
                  url,
                  repositoryID: repositoryID,
                  number: number
              ),
              GitReferenceSyntax.isValidBranchName(headRefName),
              headRefOID == nil || Self.validOID(headRefOID!),
              Self.parseTimestamp(updatedAt) != nil,
              closedAt == nil || Self.parseTimestamp(closedAt!) != nil,
              mergedAt == nil || Self.parseTimestamp(mergedAt!) != nil,
              Self.validStateDates(
                  state: state,
                  closedAt: closedAt,
                  mergedAt: mergedAt
              ) else {
            throw GitSafetyError.unsafeRepository(
                "GitHub pull-request evidence is invalid"
            )
        }
        id = number
        self.number = number
        self.url = url
        self.repositoryID = repositoryID
        self.state = state
        self.headRefName = headRefName
        self.headRefOID = headRefOID?.lowercased()
        self.isCrossRepository = isCrossRepository
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.mergedAt = mergedAt
    }

    public var updatedDate: Date? {
        Self.parseTimestamp(updatedAt)
    }

    private static func validPullRequestURL(
        _ value: String,
        repositoryID: String,
        number: Int
    ) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return components.path.lowercased()
            == "/\(repositoryID)/pull/\(number)"
    }

    private static func validStateDates(
        state: PullRequestState,
        closedAt: String?,
        mergedAt: String?
    ) -> Bool {
        switch state {
        case .draft, .open:
            return closedAt == nil && mergedAt == nil
        case .merged:
            return mergedAt != nil
        case .closed:
            return closedAt != nil && mergedAt == nil
        }
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        if let value = fractional.date(from: value) {
            return value
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

public enum PullRequestAvailability:
    String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public enum WorkPurpose: String, Codable, Equatable, Sendable {
    case ambiguous
    case active
    case completed
    case integrated
    case closedIncomplete
    case superseded
    case noKnownPullRequest
    case unavailable

    public var operatorLabel: String {
        switch self {
        case .ambiguous: return "Ambiguous"
        case .active: return "Active"
        case .completed: return "Completed"
        case .integrated: return "Integrated"
        case .closedIncomplete: return "Closed incomplete"
        case .superseded: return "Superseded"
        case .noKnownPullRequest: return "No known PR"
        case .unavailable: return "Unavailable"
        }
    }

    public var isFulfilled: Bool {
        self == .completed || self == .integrated
    }
}

public struct PurposeAssessment: Codable, Equatable, Sendable {
    public let purpose: WorkPurpose
    public let exactAssociations: [PullRequestRecord]
    public let allCandidates: [PullRequestRecord]
    public let explanation: String

    public init(
        purpose: WorkPurpose,
        exactAssociations: [PullRequestRecord],
        allCandidates: [PullRequestRecord],
        explanation: String
    ) {
        self.purpose = purpose
        self.exactAssociations = exactAssociations
        self.allCandidates = allCandidates
        self.explanation = Redactor.sanitize(explanation)
    }
}

public enum PurposeOracle {
    public static func assess(
        repositoryID: String,
        branch: String,
        tipOID: String?,
        pullRequests: [PullRequestRecord],
        pullRequestAvailability: PullRequestAvailability,
        tipIntegratedIntoDefault: Bool?
    ) -> PurposeAssessment {
        guard let tipOID else {
            return PurposeAssessment(
                purpose: .unavailable,
                exactAssociations: [],
                allCandidates: pullRequests,
                explanation: "Branch-tip identity is unavailable."
            )
        }
        let sameIdentity = pullRequests.filter {
            $0.repositoryID == repositoryID
                && !$0.isCrossRepository
                && $0.headRefName == branch
        }
        let exact = sameIdentity.filter {
            $0.headRefOID == tipOID
        }
        let contradictory = pullRequests.contains {
            $0.repositoryID != repositoryID
                || $0.isCrossRepository
                || $0.headRefName != branch
                || $0.headRefOID == nil
        }
        if contradictory || pullRequests.count > 1 {
            return PurposeAssessment(
                purpose: .ambiguous,
                exactAssociations: exact,
                allCandidates: pullRequests,
                explanation:
                    "Pull-request evidence is contradictory or has multiple exact matches."
            )
        }
        if let associated = exact.first,
           associated.state == .draft || associated.state == .open {
            return PurposeAssessment(
                purpose: .active,
                exactAssociations: exact,
                allCandidates: pullRequests,
                explanation: "An exact Draft or Open pull request is active."
            )
        }
        if let associated = exact.first,
           associated.state == .merged,
           associated.mergedAt != nil {
            return PurposeAssessment(
                purpose: .completed,
                exactAssociations: exact,
                allCandidates: pullRequests,
                explanation: "The exact branch tip has a merged pull request."
            )
        }
        if tipIntegratedIntoDefault == true {
            return PurposeAssessment(
                purpose: .integrated,
                exactAssociations: exact,
                allCandidates: pullRequests,
                explanation:
                    "Independent local ancestry proves the branch tip is integrated into the resolved default."
            )
        }
        if let associated = exact.first,
           associated.state == .closed {
            return PurposeAssessment(
                purpose: .closedIncomplete,
                exactAssociations: exact,
                allCandidates: pullRequests,
                explanation:
                    "The exact pull request closed without a verified merge."
            )
        }
        if !sameIdentity.isEmpty {
            return PurposeAssessment(
                purpose: .superseded,
                exactAssociations: [],
                allCandidates: pullRequests,
                explanation:
                    "Pull-request history exists for this branch name, but not for its current tip."
            )
        }
        if pullRequestAvailability == .available {
            return PurposeAssessment(
                purpose: .noKnownPullRequest,
                exactAssociations: [],
                allCandidates: pullRequests,
                explanation: "No pull request is known for this branch tip."
            )
        }
        return PurposeAssessment(
            purpose: .unavailable,
            exactAssociations: [],
            allCandidates: pullRequests,
            explanation: "Pull-request evidence is unavailable."
        )
    }
}

public enum ActivityBand: String, Codable, Equatable, Sendable {
    case recent
    case idle
    case staleCandidate
    case unavailable

    public var operatorLabel: String {
        switch self {
        case .recent: return "Recent"
        case .idle: return "Idle"
        case .staleCandidate: return "Stale Candidate"
        case .unavailable: return "Unavailable"
        }
    }
}

public enum ActivityBandOracle {
    public static let completeDay: TimeInterval = 86_400

    public static func classify(
        capturedNow: Date,
        commitDate: Date?,
        associatedPullRequests: [PullRequestRecord]
    ) -> ActivityBand {
        let dates = [commitDate]
            .compactMap { $0 }
            + associatedPullRequests.compactMap(\.updatedDate)
        guard let newest = dates.max() else {
            return .unavailable
        }
        let elapsed = max(0, capturedNow.timeIntervalSince(newest))
        let completeDays = Int(elapsed / completeDay)
        if completeDays <= 7 {
            return .recent
        }
        if completeDays <= 30 {
            return .idle
        }
        return .staleCandidate
    }
}

public enum RemovalRecommendation: String, Codable, Equatable, Sendable {
    case recommended
    case recovery
    case keep
    case override
    case hardExcluded

    public var operatorLabel: String {
        switch self {
        case .recommended: return "Recommended"
        case .recovery: return "Recovery copy required"
        case .keep: return "Keep"
        case .override: return "Override risk"
        case .hardExcluded: return "Hard exclusion"
        }
    }
}

public enum RemovalPermissionState:
    String, Codable, Equatable, Sendable {
    case previewOnly
    case dependencyBlocked
    case hardExcluded

    public var operatorLabel: String {
        switch self {
        case .previewOnly: return "Preview only"
        case .dependencyBlocked: return "Dependency blocked"
        case .hardExcluded: return "Hard excluded"
        }
    }
}

public struct RemovalPreview: Codable, Equatable, Sendable {
    public let recommendation: RemovalRecommendation
    public let permission: RemovalPermissionState
    public let dependencies: [String]
    public let explanation: String
    public let recoveryConsequence: String?
    public let overrideConsequence: String?

    public init(
        recommendation: RemovalRecommendation,
        permission: RemovalPermissionState,
        dependencies: [String] = [],
        explanation: String,
        recoveryConsequence: String? = nil,
        overrideConsequence: String? = nil
    ) {
        self.recommendation = recommendation
        self.permission = permission
        self.dependencies = dependencies
        self.explanation = Redactor.sanitize(explanation)
        self.recoveryConsequence = recoveryConsequence.map(Redactor.sanitize)
        self.overrideConsequence = overrideConsequence.map(Redactor.sanitize)
    }
}

public enum RemovalPreviewOracle {
    public static func branch(
        isResolvedDefault: Bool,
        policyCategory: RepositoryPolicyCategory,
        claimIDs: [String],
        purpose: WorkPurpose,
        activity: ActivityBand,
        tipPreserved: Bool?,
        recoverySupported: Bool = true,
        preservationFailed: Bool = false,
        currentSession: Bool = false
    ) -> RemovalPreview {
        if isResolvedDefault || policyCategory != .writable {
            return RemovalPreview(
                recommendation: .hardExcluded,
                permission: .hardExcluded,
                explanation:
                    "The resolved default and protected/read-only policy categories cannot be removal candidates."
            )
        }
        if !claimIDs.isEmpty {
            return RemovalPreview(
                recommendation: .keep,
                permission: .dependencyBlocked,
                dependencies: claimIDs,
                explanation:
                    "Remove every claiming worktree before branch removal can be considered."
            )
        }
        if preservationFailed
            || (tipPreserved == false && !recoverySupported) {
            return RemovalPreview(
                recommendation: .override,
                permission: .previewOnly,
                explanation:
                    "History preservation is incomplete or unsupported; removal requires an explicit operator override.",
                overrideConsequence:
                    "Operator override accepts the displayed risk of losing unique branch history."
            )
        }
        if currentSession
            || activity == .recent
            || purpose == .active
            || purpose == .closedIncomplete
            || purpose == .ambiguous
            || purpose == .unavailable {
            return RemovalPreview(
                recommendation: .keep,
                permission: .previewOnly,
                explanation:
                    "Current, recent, active, incomplete, or uncertain work recommends keeping this branch.",
                overrideConsequence:
                    "Remove anyway accepts the displayed work-disruption or history risk."
            )
        }
        if purpose.isFulfilled, tipPreserved == true {
            return RemovalPreview(
                recommendation: .recommended,
                permission: .previewOnly,
                explanation:
                    "Purpose is fulfilled and the exact tip has a verified preservation sink."
            )
        }
        if purpose.isFulfilled, tipPreserved == false {
            return RemovalPreview(
                recommendation: .recovery,
                permission: .previewOnly,
                explanation:
                    "Purpose appears fulfilled, but unique history needs a recovery artifact before removal.",
                recoveryConsequence:
                    "A retained, restore-proven recovery artifact would be required before removal."
            )
        }
        if tipPreserved == false, recoverySupported {
            return RemovalPreview(
                recommendation: .recovery,
                permission: .previewOnly,
                explanation:
                    "Unique local history needs a protected, restore-proven recovery copy.",
                recoveryConsequence:
                    "A complete recovery artifact must be proven before ordinary removal; otherwise this becomes Override risk."
            )
        }
        return RemovalPreview(
            recommendation: .keep,
            permission: .previewOnly,
            explanation:
                "Purpose, activity, or preservation evidence does not support removal.",
            overrideConsequence:
                "Remove anyway accepts the displayed purpose or preservation risk."
        )
    }

    public static func worktree(
        isResolvedDefaultClaim: Bool,
        policyCategory: RepositoryPolicyCategory,
        verification: WorktreeVerification,
        fileState: WorktreeFileState?,
        awa: AWAEvidence,
        purpose: WorkPurpose?,
        activity: ActivityBand?,
        branchTipPreserved: Bool?,
        recoverySupported: Bool = true,
        preservationFailed: Bool = false,
        currentSession: Bool = false,
        isLocked: Bool = false
    ) -> RemovalPreview {
        if isResolvedDefaultClaim || policyCategory != .writable {
            return RemovalPreview(
                recommendation: .hardExcluded,
                permission: .hardExcluded,
                explanation:
                    "The resolved-default target and protected/read-only policy categories cannot be removal candidates."
            )
        }
        if preservationFailed
            || (branchTipPreserved == false && !recoverySupported) {
            return RemovalPreview(
                recommendation: .override,
                permission: .previewOnly,
                explanation:
                    "Recovery completeness or history preservation failed; removal requires Operator override.",
                overrideConsequence:
                    "Operator override accepts possible unrecoverable files, index state, or history."
            )
        }
        if verification != .verified
            || fileState == nil
            || fileState?.operationState != .clear
            || awa.state == .active
            || awa.state == .stale
            || awa.state == .dead
            || awa.state == .untracked {
            return RemovalPreview(
                recommendation: .keep,
                permission: .previewOnly,
                explanation:
                    "Unknown identity, active work, lock state, or AWA evidence requires keeping this worktree.",
                overrideConsequence:
                    "Remove anyway accepts possible work disruption or stale AWA bookkeeping."
            )
        }
        if awa.state == .unavailable,
           awa.forceOverridableUnknown {
            return RemovalPreview(
                recommendation: .override,
                permission: .previewOnly,
                explanation:
                    "AWA evidence is unavailable and explicitly force-overridable; removal requires Operator override.",
                overrideConsequence:
                    "Operator override accepts unknown AWA state; AWA remains advisory."
            )
        }
        if awa.state == .unavailable {
            return RemovalPreview(
                recommendation: .keep,
                permission: .previewOnly,
                explanation:
                    "AWA evidence is unavailable, so keeping this worktree is recommended.",
                overrideConsequence:
                    "Remove anyway accepts unknown AWA state; AWA remains advisory."
            )
        }
        if currentSession
            || activity == .recent
            || purpose == .active
            || purpose == .closedIncomplete
            || purpose == .ambiguous
            || purpose == .unavailable
            || isLocked {
            return RemovalPreview(
                recommendation: .keep,
                permission: .previewOnly,
                explanation: "Recent or active feature work recommends keeping this worktree.",
                overrideConsequence:
                    "Remove anyway accepts current-work disruption."
            )
        }
        if fileState?.isClean == false
            || (
                purpose?.isFulfilled == true
                    && branchTipPreserved == false
            ) {
            guard recoverySupported else {
                return RemovalPreview(
                    recommendation: .override,
                    permission: .previewOnly,
                    explanation:
                        "Local state needs recovery, but a complete artifact cannot be proven.",
                    overrideConsequence:
                        "Operator override accepts possible unrecoverable files, index state, or history."
                )
            }
            return RemovalPreview(
                recommendation: .recovery,
                permission: .previewOnly,
                explanation:
                    "Local state or unique history requires recovery before removal.",
                recoveryConsequence:
                    "A complete retained recovery artifact would be required before removal."
            )
        }
        if branchTipPreserved == false {
            return recoverySupported
                ? RemovalPreview(
                    recommendation: .recovery,
                    permission: .previewOnly,
                    explanation:
                        "Unique local history needs a protected, restore-proven recovery copy.",
                    recoveryConsequence:
                        "A complete recovery artifact must be proven before ordinary removal."
                )
                : RemovalPreview(
                    recommendation: .override,
                    permission: .previewOnly,
                    explanation:
                        "Unique local history has no verified preservation path.",
                    overrideConsequence:
                        "Operator override accepts possible loss of unique history."
                )
        }
        if purpose?.isFulfilled == true,
           fileState?.isClean == true,
           branchTipPreserved == true {
            return RemovalPreview(
                recommendation: .recommended,
                permission: .previewOnly,
                explanation:
                    "The worktree is clean, inactive, fulfilled, and its branch tip is preserved."
            )
        }
        return RemovalPreview(
            recommendation: .keep,
            permission: .previewOnly,
            explanation:
                "The current evidence does not support worktree removal.",
            overrideConsequence:
                "Remove anyway accepts the displayed purpose or preservation risk."
        )
    }
}

enum AWAEvidenceReader {
    private struct LeaseDocument: Decodable {
        let schema: String
        let leaseID: String
        let worktreePath: String
        let branch: String
        let gitCommonDir: String
        let bootID: String

        enum CodingKeys: String, CodingKey {
            case schema
            case leaseID = "lease_id"
            case worktreePath = "worktree_path"
            case branch
            case gitCommonDir = "git_common_dir"
            case bootID = "boot_id"
        }
    }

    private struct ActiveRootDocument: Decodable {
        let schema: String
        let rootPath: String
        let gitCommonDir: String?
        let branch: String?
        let bootID: String?
        let pid: Int32?
        let lastHeartbeatEpoch: Int64?
        let lastHeartbeat: String?

        enum CodingKeys: String, CodingKey {
            case schema
            case rootPath = "root_path"
            case gitCommonDir = "git_common_dir"
            case branch
            case bootID = "boot_id"
            case pid
            case lastHeartbeatEpoch = "last_heartbeat_epoch"
            case lastHeartbeat = "last_heartbeat"
        }
    }

    static func read(
        worktreePath: String,
        commonDirectory: String,
        branch: String?,
        location: WorktreeLocationKind,
        account: EffectiveAccount,
        capturedNow: Date,
        activeRootTTL: TimeInterval = 12 * 3_600
    ) -> AWAEvidence {
        let canonical = physicalPath(worktreePath) ?? worktreePath
        let activeRootPath = URL(fileURLWithPath: account.homeDirectory)
            .appendingPathComponent(".local/state/awa/roots", isDirectory: true)
            .appendingPathComponent(
                "\(rootSlug(canonical))-\(rootHash(canonical)).json"
            ).path
        let active = readPrivateJSON(
            ActiveRootDocument.self,
            path: activeRootPath,
            account: account
        )
        switch active {
        case let .value(record):
            guard record.schema == "active_root/v1",
                  record.rootPath == canonical,
                  record.gitCommonDir == nil
                    || record.gitCommonDir == commonDirectory,
                  record.branch == nil || record.branch == branch else {
                return AWAEvidence(
                    state: .unavailable,
                    explanation:
                        "AWA active-root evidence is inconsistent; fail-safe keep applies.",
                    blocksRemoval: true,
                    forceOverridableUnknown: true
                )
            }
            if let pid = record.pid,
               pid > 1,
               record.bootID == currentBootID() {
                let heartbeatText = heartbeatDate(record).map {
                    ISO8601DateFormatter().string(from: $0)
                }
                if kill(pid, 0) == 0 || errno == EPERM {
                    return AWAEvidence(
                        state: .active,
                        leaseID: leaseID(
                            worktreePath: canonical,
                            commonDirectory: commonDirectory,
                            branch: branch,
                            account: account
                        ),
                        lastHeartbeatAt: heartbeatText,
                        explanation:
                            "AWA records a live owner process for this worktree.",
                        blocksRemoval: true
                    )
                }
                return AWAEvidence(
                    state: .stale,
                    lastHeartbeatAt: heartbeatText,
                    explanation:
                        "AWA records an owner process that is no longer active.",
                    blocksRemoval: false
                )
            }
            guard let heartbeat = heartbeatDate(record) else {
                return AWAEvidence(
                    state: .unavailable,
                    explanation:
                        "AWA heartbeat time is unavailable; fail-safe keep applies.",
                    blocksRemoval: true,
                    forceOverridableUnknown: true
                )
            }
            if capturedNow.timeIntervalSince(heartbeat) < activeRootTTL {
                return AWAEvidence(
                    state: .active,
                    lastHeartbeatAt:
                        ISO8601DateFormatter().string(
                            from: heartbeat
                        ),
                    explanation: "AWA heartbeat evidence is still active.",
                    blocksRemoval: true
                )
            }
            return AWAEvidence(
                state: .stale,
                lastHeartbeatAt:
                    ISO8601DateFormatter().string(
                        from: heartbeat
                    ),
                explanation: "AWA heartbeat evidence is stale.",
                blocksRemoval: false
            )
        case .unsafe:
            return AWAEvidence(
                state: .unavailable,
                explanation:
                    "AWA active-root evidence is unreadable; fail-safe keep applies.",
                blocksRemoval: true,
                forceOverridableUnknown: true
            )
        case .absent:
            break
        }

        if location != .awaManaged {
            return .notManaged
        }
        let leasePath = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(".awa/lease.json").path
        switch readPrivateJSON(
            LeaseDocument.self,
            path: leasePath,
            account: account
        ) {
        case let .value(lease):
            let expected = expectedLeaseID(
                worktreePath: worktreePath,
                branch: branch,
                commonDirectory: commonDirectory,
                bootID: lease.bootID
            )
            guard lease.schema == "awa-lease/v1",
                  lease.worktreePath == worktreePath,
                  lease.gitCommonDir == commonDirectory,
                  lease.branch == branch,
                  lease.leaseID == expected,
                  !lease.leaseID.allSatisfy(\.isNumber) else {
                return AWAEvidence(
                    state: .unavailable,
                    explanation:
                        "AWA lease identity is inconsistent; fail-safe keep applies.",
                    blocksRemoval: true,
                    forceOverridableUnknown: true
                )
            }
            return AWAEvidence(
                state: .untracked,
                leaseID: lease.leaseID,
                explanation:
                    "AWA lease is present without a current active-root heartbeat.",
                blocksRemoval: false
            )
        case .unsafe:
            return AWAEvidence(
                state: .unavailable,
                explanation:
                    "AWA lease evidence is unreadable; fail-safe keep applies.",
                blocksRemoval: true,
                forceOverridableUnknown: true
            )
        case .absent:
            return AWAEvidence(
                state: .unavailable,
                explanation:
                    "AWA-managed location has no verifiable lease; fail-safe keep applies.",
                blocksRemoval: true,
                forceOverridableUnknown: true
            )
        }
    }

    private enum ReadResult<T> {
        case value(T)
        case absent
        case unsafe
    }

    private static func readPrivateJSON<T: Decodable>(
        _ type: T.Type,
        path: String,
        account: EffectiveAccount
    ) -> ReadResult<T> {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .absent : .unsafe
        }
        guard FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0,
              info.st_size >= 0,
              info.st_size <= 262_144 else {
            return .unsafe
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return .unsafe }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              FileIdentity(opened).matchesStableNode(FileIdentity(info)) else {
            return .unsafe
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while data.count <= 262_144 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return .unsafe
            }
        }
        guard data.count <= 262_144,
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return .unsafe
        }
        return .value(decoded)
    }

    private static func heartbeatDate(_ record: ActiveRootDocument) -> Date? {
        if let epoch = record.lastHeartbeatEpoch {
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }
        guard let value = record.lastHeartbeat else { return nil }
        return PullRequestRecord.parseTimestamp(value)
    }

    private static func expectedLeaseID(
        worktreePath: String,
        branch: String?,
        commonDirectory: String,
        bootID: String
    ) -> String {
        let material = [
            worktreePath,
            branch ?? "",
            commonDirectory,
            bootID,
        ].joined(separator: "\u{001f}")
        let digest = SHA256.hash(data: Data(material.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "awa1-\(digest)"
    }

    private static func leaseID(
        worktreePath: String,
        commonDirectory: String,
        branch: String?,
        account: EffectiveAccount
    ) -> String? {
        let path = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(".awa/lease.json").path
        guard case let .value(lease) = readPrivateJSON(
            LeaseDocument.self,
            path: path,
            account: account
        ) else {
            return nil
        }
        return expectedLeaseID(
            worktreePath: worktreePath,
            branch: branch,
            commonDirectory: commonDirectory,
            bootID: lease.bootID
        ) == lease.leaseID ? lease.leaseID : nil
    }

    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func rootHash(_ path: String) -> String {
        String(
            SHA256.hash(data: Data(path.utf8)).map {
                String(format: "%02x", $0)
            }.joined().prefix(16)
        )
    }

    private static func rootSlug(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        var transformed = ""
        var replacing = false
        for scalar in name.unicodeScalars {
            let value = scalar.value
            let accepted =
                (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57)
                || scalar == "." || scalar == "_"
                || scalar == "-"
            if accepted {
                transformed.unicodeScalars.append(scalar)
                replacing = false
            } else if !replacing {
                transformed.append("-")
                replacing = true
            }
        }
        let slug = transformed
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            .lowercased()
        return slug.isEmpty ? "root" : slug
    }

    private static func currentBootID() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else {
            return nil
        }
        return "darwin-boot-\(bootTime.tv_sec)"
    }
}
