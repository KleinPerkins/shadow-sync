import Darwin
import Foundation

public let shadowSyncRecordSchema = "shadow-sync-log/v1"
public let shadowSyncEventSchema = "shadow-sync-event/v1"

public enum RunIdentity {
    public static func make() -> String {
        UUID().uuidString.lowercased()
    }

    public static func isValid(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

public struct RepositoryDirectoryIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    init(_ identity: FileIdentity) {
        device = identity.device
        inode = identity.inode
    }
}

public struct RepositoryMetadataFileIdentity: Codable, Equatable, Sendable {
    public let identity: FileIdentity
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    init(_ info: stat) {
        identity = FileIdentity(info)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
}

public struct RepositoryLinkedWorktree: Codable, Equatable, Sendable {
    public let path: String
    public let rootIdentity: RepositoryDirectoryIdentity
    public let markerIdentity: RepositoryMetadataFileIdentity
    public let registrationDirectoryIdentity: RepositoryDirectoryIdentity
    public let registrationGitdirIdentity: RepositoryMetadataFileIdentity
    public let commonDirectoryMarkerIdentity: RepositoryMetadataFileIdentity
    public let headIdentity: RepositoryMetadataFileIdentity
    public let headValue: String
}

public enum RepositoryCachedMainRelation: String, Codable, Equatable, Sendable {
    case equal
    case behind
    case ahead
    case diverged
    case unavailable

    public var operatorLabel: String {
        switch self {
        case .equal:
            return "Equal"
        case .behind:
            return "Behind"
        case .ahead:
            return "Ahead"
        case .diverged:
            return "Diverged"
        case .unavailable:
            return "Unavailable"
        }
    }
}

public enum RepositoryBlockReason: String, Codable, Equatable, Sendable {
    case excludedByPolicy
    case permanentNoTouch
    case readOnlyReference
    case unsupportedOrigin
    case repositoryUnavailable
    case originChanged
    case unsupportedHook
    case unsupportedExternalWorktree
    case unsafeWorktreeTopology
    case mainInLinkedWorktree
    case unsafeGitMetadata
    case unsupportedGitConfiguration
    case busy
    case localMainMissing
    case detachedHead
    case primaryNotOnMain
    case dirty
    case hiddenIndex
    case localStateUnverifiable

    public var operatorExplanation: String {
        switch self {
        case .excludedByPolicy:
            return "The repository is excluded by the safety policy."
        case .permanentNoTouch:
            return "Permanently protected; ShadowSync cannot operate here."
        case .readOnlyReference:
            return "This is a read-only reference repository."
        case .unsupportedOrigin:
            return "The origin is missing or is not a supported GitHub URL."
        case .repositoryUnavailable:
            return "The repository could not be reopened safely."
        case .originChanged:
            return "The origin changed while the repository was inspected."
        case .unsupportedHook:
            return "An unsupported Git hook is installed."
        case .unsupportedExternalWorktree:
            return "A linked worktree is outside Cursor's managed location."
        case .unsafeWorktreeTopology:
            return "Linked worktree metadata could not be safely verified."
        case .mainInLinkedWorktree:
            return "Main is checked out in another worktree."
        case .unsafeGitMetadata:
            return "Git metadata could not be safely verified."
        case .unsupportedGitConfiguration:
            return "Git configuration could not be safely verified."
        case .busy:
            return "Another Git operation is active."
        case .localMainMissing:
            return "The local main branch is missing."
        case .detachedHead:
            return "The primary working copy is detached."
        case .primaryNotOnMain:
            return "The primary working copy is not on main."
        case .dirty:
            return "The primary working copy has local changes."
        case .hiddenIndex:
            return "Hidden index state is present."
        case .localStateUnverifiable:
            return "Local repository state could not be safely verified."
        }
    }
}

public struct RepositoryCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String
    public let rawOrigin: String
    public let originIdentity: GitHubIdentity?
    public let presentationLocation: String?
    public let rootIdentity: RepositoryDirectoryIdentity?
    public let gitDirectoryIdentity: RepositoryDirectoryIdentity?
    public let commonDirectoryIdentity: RepositoryDirectoryIdentity?
    public let configIdentity: RepositoryMetadataFileIdentity?
    public let policyAdmissionSHA256: String?
    public let hookAdmissionSHA256: String?
    public let linkedWorktreePaths: [String]
    public let linkedWorktrees: [RepositoryLinkedWorktree]
    public let cachedMainRelation: RepositoryCachedMainRelation
    public let blockedReason: RepositoryBlockReason?

    public init(
        id: String,
        displayName: String,
        path: String,
        rawOrigin: String,
        presentationLocation: String? = nil,
        rootIdentity: RepositoryDirectoryIdentity? = nil,
        gitDirectoryIdentity: RepositoryDirectoryIdentity? = nil,
        commonDirectoryIdentity: RepositoryDirectoryIdentity? = nil,
        configIdentity: RepositoryMetadataFileIdentity? = nil,
        policyAdmissionSHA256: String? = nil,
        hookAdmissionSHA256: String? = nil,
        linkedWorktreePaths: [String] = [],
        linkedWorktrees: [RepositoryLinkedWorktree] = [],
        cachedMainRelation: RepositoryCachedMainRelation = .unavailable,
        blockedReason: RepositoryBlockReason? = nil
    ) {
        self.id = id
        self.displayName = Self.validLocalLabel(displayName)
            ?? "Local repository"
        self.path = path
        self.rawOrigin = rawOrigin
        originIdentity = GitHubIdentity.parse(rawOrigin)
        self.presentationLocation = Self.validPresentationLocation(
            presentationLocation
        )
        self.rootIdentity = rootIdentity
        self.gitDirectoryIdentity = gitDirectoryIdentity
        self.commonDirectoryIdentity = commonDirectoryIdentity
        self.configIdentity = configIdentity
        self.policyAdmissionSHA256 = Self.normalizedSHA256(
            policyAdmissionSHA256
        )
        self.hookAdmissionSHA256 = Self.normalizedSHA256(
            hookAdmissionSHA256
        )
        self.linkedWorktreePaths = linkedWorktreePaths
        self.linkedWorktrees = linkedWorktrees
        self.cachedMainRelation = cachedMainRelation
        self.blockedReason = blockedReason
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case path
        case rawOrigin
        case originIdentity
        case presentationLocation
        case rootIdentity
        case gitDirectoryIdentity
        case commonDirectoryIdentity
        case configIdentity
        case policyAdmissionSHA256
        case hookAdmissionSHA256
        case linkedWorktreePaths
        case linkedWorktrees
        case cachedMainRelation
        case blockedReason
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        rawOrigin = try values.decode(String.self, forKey: .rawOrigin)
        blockedReason = try values.decodeIfPresent(
            RepositoryBlockReason.self,
            forKey: .blockedReason
        )
        let parsedIdentity = GitHubIdentity.parse(rawOrigin)
        let encodedIdentity = try values.decodeIfPresent(
            GitHubIdentity.self,
            forKey: .originIdentity
        )
        if let encodedIdentity, encodedIdentity != parsedIdentity {
            throw DecodingError.dataCorruptedError(
                forKey: .originIdentity,
                in: values,
                debugDescription: "repository origin identity does not match"
            )
        }
        guard parsedIdentity != nil || blockedReason != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawOrigin,
                in: values,
                debugDescription: "eligible repository origin identity is invalid"
            )
        }
        originIdentity = parsedIdentity
        let decodedDisplayName = try values.decode(
            String.self,
            forKey: .displayName
        )
        guard let safeDisplayName = Self.decodedDisplayLabel(
            decodedDisplayName,
            id: id,
            originIdentity: parsedIdentity
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayName,
                in: values,
                debugDescription: "repository display label is invalid"
            )
        }
        displayName = safeDisplayName
        let decodedLocation = try values.decodeIfPresent(
            String.self,
            forKey: .presentationLocation
        )
        presentationLocation = Self.validPresentationLocation(
            decodedLocation
        )
        rootIdentity = try values.decodeIfPresent(
            RepositoryDirectoryIdentity.self,
            forKey: .rootIdentity
        )
        gitDirectoryIdentity = try values.decodeIfPresent(
            RepositoryDirectoryIdentity.self,
            forKey: .gitDirectoryIdentity
        )
        commonDirectoryIdentity = try values.decodeIfPresent(
            RepositoryDirectoryIdentity.self,
            forKey: .commonDirectoryIdentity
        )
        configIdentity = try values.decodeIfPresent(
            RepositoryMetadataFileIdentity.self,
            forKey: .configIdentity
        )
        let decodedPolicySHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .policyAdmissionSHA256
        )
        let decodedHookSHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .hookAdmissionSHA256
        )
        guard decodedPolicySHA256 == nil
                || Self.normalizedSHA256(decodedPolicySHA256) != nil,
              decodedHookSHA256 == nil
                || Self.normalizedSHA256(decodedHookSHA256) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .policyAdmissionSHA256,
                in: values,
                debugDescription: "repository admission digest is invalid"
            )
        }
        policyAdmissionSHA256 = Self.normalizedSHA256(
            decodedPolicySHA256
        )
        hookAdmissionSHA256 = Self.normalizedSHA256(
            decodedHookSHA256
        )
        linkedWorktreePaths = try values.decodeIfPresent(
            [String].self,
            forKey: .linkedWorktreePaths
        ) ?? []
        linkedWorktrees = try values.decodeIfPresent(
            [RepositoryLinkedWorktree].self,
            forKey: .linkedWorktrees
        ) ?? []
        cachedMainRelation = try values.decodeIfPresent(
            RepositoryCachedMainRelation.self,
            forKey: .cachedMainRelation
        ) ?? .unavailable
        if !linkedWorktrees.isEmpty,
           linkedWorktrees.map(\.path) != linkedWorktreePaths {
            throw DecodingError.dataCorruptedError(
                forKey: .linkedWorktrees,
                in: values,
                debugDescription: "linked worktree identities do not match their paths"
            )
        }
    }

    public var canonicalOriginName: String? {
        originIdentity?.canonicalName
    }

    public var hasValidatedOriginIdentity: Bool {
        guard let originIdentity else {
            return false
        }
        return GitHubIdentity.parse(rawOrigin) == originIdentity
    }

    public var isEligible: Bool {
        blockedReason == nil
            && hasValidatedOriginIdentity
            && id.lowercased() == originIdentity?.canonicalName
            && Self.validAbsolutePath(path)
    }

    public var admissionIdentity: RepositoryAdmissionIdentity {
        RepositoryAdmissionIdentity(candidate: self)
    }

    public func hasSameAdmissionIdentity(
        as other: RepositoryCandidate
    ) -> Bool {
        admissionIdentity == other.admissionIdentity
    }

    private static func validPresentationLocation(
        _ value: String?
    ) -> String? {
        guard let value,
              value.count <= 1_024,
              value == "~" || value.hasPrefix("~/"),
              !value.contains("//"),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              value.split(
                separator: "/",
                omittingEmptySubsequences: false
              ).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            return nil
        }
        return value
    }

    private static func validLocalLabel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.utf8.count <= 255,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.lowercased().contains("%2f"),
              !trimmed.lowercased().contains("%5c"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return trimmed
    }

    private static func decodedDisplayLabel(
        _ value: String,
        id: String,
        originIdentity: GitHubIdentity?
    ) -> String? {
        if let local = validLocalLabel(value) {
            return local
        }
        guard let originIdentity else { return nil }
        let canonical = originIdentity.canonicalName
        guard value == canonical,
              id.lowercased() == canonical,
              canonical.split(
                separator: "/",
                omittingEmptySubsequences: false
              ).count == 2,
              let repository = canonical.split(separator: "/").last else {
            return nil
        }
        return validLocalLabel(String(repository))
    }

    private static func validAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && !value.contains("//")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
            && value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func normalizedSHA256(
        _ value: String?
    ) -> String? {
        guard let normalized = value?.lowercased(),
              normalized.count == 64,
              normalized.allSatisfy({
                  $0.isNumber || ("a"..."f").contains($0)
              }) else {
            return nil
        }
        return normalized
    }
}

public struct RepositoryAdmissionIdentity: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String
    public let rawOrigin: String
    public let originIdentity: GitHubIdentity?
    public let canonicalOriginName: String?
    public let presentationLocation: String?
    public let rootIdentity: RepositoryDirectoryIdentity?
    public let gitDirectoryIdentity: RepositoryDirectoryIdentity?
    public let commonDirectoryIdentity: RepositoryDirectoryIdentity?
    public let configIdentity: RepositoryMetadataFileIdentity?
    public let policyAdmissionSHA256: String?
    public let hookAdmissionSHA256: String?
    public let linkedWorktreePaths: [String]
    public let linkedWorktrees: [RepositoryLinkedWorktree]
    public let blockedReason: RepositoryBlockReason?
    public let isEligible: Bool

    fileprivate init(candidate: RepositoryCandidate) {
        id = candidate.id
        displayName = candidate.displayName
        path = candidate.path
        rawOrigin = candidate.rawOrigin
        originIdentity = candidate.originIdentity
        canonicalOriginName = candidate.canonicalOriginName
        presentationLocation = candidate.presentationLocation
        rootIdentity = candidate.rootIdentity
        gitDirectoryIdentity = candidate.gitDirectoryIdentity
        commonDirectoryIdentity = candidate.commonDirectoryIdentity
        configIdentity = candidate.configIdentity
        policyAdmissionSHA256 = candidate.policyAdmissionSHA256
        hookAdmissionSHA256 = candidate.hookAdmissionSHA256
        linkedWorktreePaths = candidate.linkedWorktreePaths
        linkedWorktrees = candidate.linkedWorktrees
        blockedReason = candidate.blockedReason
        isEligible = candidate.isEligible
    }
}

public enum RepositoryOperatorPresentation {
    public static func primaryName(
        _ candidate: RepositoryCandidate
    ) -> String {
        candidate.canonicalOriginName ?? candidate.displayName
    }

    public static func collidingPaths(
        in candidates: [RepositoryCandidate]
    ) -> Set<String> {
        let grouped = Dictionary(grouping: candidates) {
            primaryName($0)
        }
        return Set(grouped.values.filter { $0.count > 1 }.flatMap {
            $0.map(\.path)
        })
    }

    public static func selectionLabel(
        _ candidate: RepositoryCandidate,
        collidingPaths _: Set<String>
    ) -> String {
        let name = primaryName(candidate)
        guard let location = secondaryLocation(candidate) else {
            return name
        }
        return "\(name) — \(location)"
    }

    public static func confirmationLabel(
        _ candidate: RepositoryCandidate
    ) -> String {
        let name = primaryName(candidate)
        guard let location = secondaryLocation(candidate) else {
            return name
        }
        return "\(name)\n\(location)"
    }

    public static func secondaryLocation(
        _ candidate: RepositoryCandidate
    ) -> String? {
        candidate.presentationLocation ?? safeAbsolutePath(candidate.path)
    }

    public static func canPresent(
        _ candidates: [RepositoryCandidate]
    ) -> Bool {
        guard !candidates.isEmpty,
              candidates.allSatisfy({
                  if $0.isEligible {
                      return $0.hasValidatedOriginIdentity
                  }
                  return $0.blockedReason != nil
              }),
              candidates.allSatisfy({
                  secondaryLocation($0) != nil
              }) else {
            return false
        }
        return Dictionary(grouping: candidates, by: primaryName).values
            .allSatisfy { group in
                guard group.count > 1 else {
                    return true
                }
                let paths = Set(group.map(\.path))
                let locations = Set(group.compactMap(secondaryLocation))
                return paths.count == group.count
                    && locations.count == group.count
            }
    }

    public static func canConfirm(
        _ candidates: [RepositoryCandidate]
    ) -> Bool {
        canPresent(candidates)
            && candidates.allSatisfy(\.isEligible)
            && candidates.allSatisfy(\.hasValidatedOriginIdentity)
    }

    private static func safeAbsolutePath(_ value: String) -> String? {
        guard value.hasPrefix("/"),
              value.utf8.count <= 4_096,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count > 1,
              components[0].isEmpty,
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            return nil
        }
        return value
    }
}

#if SHADOW_SYNC_TESTING
public protocol RepositoryDiscovering: Sendable {
    func discover() throws -> [RepositoryCandidate]
}
#endif

public protocol SelectedRepositoryDiscovering: Sendable {
    func discover(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> [RepositoryCandidate]
}

#if SHADOW_SYNC_TESTING
public struct IsolatedRepositoryDiscovery: RepositoryDiscovering {
    private let candidate: RepositoryCandidate?

    public init(candidate: RepositoryCandidate?) {
        self.candidate = candidate
    }

    public func discover() throws -> [RepositoryCandidate] {
        candidate.map { [$0] } ?? []
    }
}
#endif

public enum M1Selection {
    public static func onlyCandidate(
        in candidates: [RepositoryCandidate]
    ) -> RepositoryCandidate? {
        guard candidates.count == 1 else {
            return nil
        }
        return candidates[0]
    }

    public static func admits(
        request: RepositoryCandidate,
        discovered candidates: [RepositoryCandidate]
    ) -> Bool {
        guard request.isEligible,
              let candidate = onlyCandidate(in: candidates),
              candidate.isEligible else {
            return false
        }
        return request.hasSameAdmissionIdentity(as: candidate)
    }
}

public struct RepositorySelectionState: Equatable, Sendable {
    public let candidates: [RepositoryCandidate]
    public private(set) var selectedPaths: Set<String>

    public init(candidates: [RepositoryCandidate]) {
        self.candidates = candidates
        selectedPaths = []
    }

    public mutating func selectAll() {
        selectedPaths = Set(candidates.filter(\.isEligible).map(\.path))
    }

    public mutating func clearAll() {
        selectedPaths.removeAll()
    }

    public mutating func setSelected(_ selected: Bool, path: String) {
        guard candidates.contains(where: {
            $0.path == path && $0.isEligible
        }) else {
            return
        }
        if selected {
            selectedPaths.insert(path)
        } else {
            selectedPaths.remove(path)
        }
    }

    public var selected: [RepositoryCandidate] {
        candidates.filter {
            $0.isEligible && selectedPaths.contains($0.path)
        }
    }

    public var canReview: Bool {
        !selectedPaths.isEmpty
    }

    public var confirmationTitle: String {
        "Ready to update \(selected.count) repositories"
    }
}

public enum RepositorySelectionAdmission {
    public static func admittedCandidates(
        requests: [RepositoryCandidate],
        discovered: [RepositoryCandidate]
    ) -> [RepositoryCandidate]? {
        guard !requests.isEmpty,
              Set(requests.map(\.path)).count == requests.count,
              Set(discovered.map(\.path)).count == discovered.count,
              requests.allSatisfy(\.isEligible),
              requests.allSatisfy(\.hasValidatedOriginIdentity) else {
            return nil
        }
        let discoveredByPath = Dictionary(
            uniqueKeysWithValues: discovered.map { ($0.path, $0) }
        )
        var admitted: [RepositoryCandidate] = []
        admitted.reserveCapacity(requests.count)
        for request in requests {
            guard let refreshed = discoveredByPath[request.path],
                  refreshed.isEligible,
                  refreshed.hasValidatedOriginIdentity,
                  request.hasSameAdmissionIdentity(as: refreshed) else {
                return nil
            }
            admitted.append(refreshed)
        }
        return admitted
    }

    public static func admits(
        requests: [RepositoryCandidate],
        discovered: [RepositoryCandidate]
    ) -> Bool {
        admittedCandidates(
            requests: requests,
            discovered: discovered
        ) != nil
    }
}

public enum RepositoryPhase: String, Codable, CaseIterable, Sendable {
    case pending
    case checking
    case fetching
    case updating
    case stopping
    case complete
}

public enum ResultClass: String, Codable, CaseIterable, Sendable {
    case success
    case warning
    case failure
    case cancelled
}

public enum WorkerExitPresentationDecision: Equatable, Sendable {
    case preserveCompletedReport
    case presentFailure(status: Int32)

    public static func resolve(
        status: Int32,
        hasValidatedCompleteReport: Bool
    ) -> WorkerExitPresentationDecision {
        hasValidatedCompleteReport
            ? .preserveCompletedReport
            : .presentFailure(status: status)
    }
}

public enum ResultCode: String, Codable, CaseIterable, Sendable {
    case updated = "UPDATED"
    case alreadyCurrent = "ALREADY_CURRENT"
    case updatedBeforeCancellation = "UPDATED_BEFORE_CANCELLATION"
    case skippedAhead = "SKIPPED_AHEAD"
    case skippedDiverged = "SKIPPED_DIVERGED"
    case skippedDirty = "SKIPPED_DIRTY"
    case skippedBusy = "SKIPPED_BUSY"
    case skippedDetachedHead = "SKIPPED_DETACHED_HEAD"
    case skippedPrimaryNotOnMain = "SKIPPED_PRIMARY_NOT_ON_MAIN"
    case skippedMainInLinkedWorktree = "SKIPPED_MAIN_IN_LINKED_WORKTREE"
    case skippedLocalMainMissing = "SKIPPED_LOCAL_MAIN_MISSING"
    case skippedRemoteMainMissing = "SKIPPED_REMOTE_MAIN_MISSING"
    case skippedHiddenIndexState = "SKIPPED_HIDDEN_INDEX_STATE"
    case skippedUnsupportedHookFramework = "SKIPPED_UNSUPPORTED_HOOK_FRAMEWORK"
    case skippedRepositoryRemoved = "SKIPPED_REPOSITORY_REMOVED"
    case skippedOriginChanged = "SKIPPED_ORIGIN_CHANGED"
    case skippedIgnoredFileCollision = "SKIPPED_IGNORED_FILE_COLLISION"
    case updatedWithWarning = "UPDATED_WITH_WARNING"
    case failedInspection = "FAILED_INSPECTION"
    case failedFetchAuthentication = "FAILED_FETCH_AUTHENTICATION"
    case failedFetchNetwork = "FAILED_FETCH_NETWORK"
    case failedFetch = "FAILED_FETCH"
    case failedUpdate = "FAILED_UPDATE"
    case needsAttention = "NEEDS_ATTENTION"
    case cancelledPending = "CANCELLED_PENDING"
    case cancelledDuringFetch = "CANCELLED_DURING_FETCH"
    case cancelledNoUpdate = "CANCELLED_NO_UPDATE"

    public var resultClass: ResultClass {
        switch self {
        case .updated, .alreadyCurrent, .updatedBeforeCancellation:
            return .success
        case .skippedAhead, .skippedDiverged, .skippedDirty, .skippedBusy,
             .skippedDetachedHead, .skippedPrimaryNotOnMain,
             .skippedMainInLinkedWorktree,
             .skippedLocalMainMissing, .skippedRemoteMainMissing,
             .skippedHiddenIndexState, .skippedUnsupportedHookFramework,
             .skippedRepositoryRemoved,
             .skippedOriginChanged, .skippedIgnoredFileCollision,
             .updatedWithWarning:
            return .warning
        case .failedInspection, .failedFetchAuthentication, .failedFetchNetwork,
             .failedFetch, .failedUpdate, .needsAttention:
            return .failure
        case .cancelledPending, .cancelledDuringFetch, .cancelledNoUpdate:
            return .cancelled
        }
    }
}

public enum FetchFailureReason: String, Codable, Sendable {
    case authentication
    case dns
    case transport
    case timeout
    case other
}

public struct RepositoryResult: Codable, Equatable, Sendable {
    public let repository: RepositoryCandidate
    public let operationID: String?
    public let defaultBranch: String?
    public let code: ResultCode
    public let resultClass: ResultClass
    public let fetched: Bool
    public let mainUpdated: Bool
    public let beforeCommit: String?
    public let targetCommit: String?
    public let afterCommit: String?
    public let remoteTrackingBeforeCommit: String?
    public let remoteTrackingAfterCommit: String?
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int64
    public let explanation: String
    public let technicalDetail: String?
    public let failureReason: FetchFailureReason?

    public init(
        repository: RepositoryCandidate,
        operationID: String? = nil,
        defaultBranch: String? = nil,
        code: ResultCode,
        fetched: Bool,
        mainUpdated: Bool,
        beforeCommit: String?,
        targetCommit: String?,
        afterCommit: String?,
        remoteTrackingBeforeCommit: String? = nil,
        remoteTrackingAfterCommit: String? = nil,
        startedAt: String,
        endedAt: String,
        durationMilliseconds: Int64,
        explanation: String,
        technicalDetail: String? = nil,
        failureReason: FetchFailureReason? = nil
    ) {
        self.repository = repository
        self.operationID = operationID
        self.defaultBranch = defaultBranch
        self.code = code
        self.resultClass = code.resultClass
        self.fetched = fetched
        self.mainUpdated = mainUpdated
        self.beforeCommit = beforeCommit
        self.targetCommit = targetCommit
        self.afterCommit = afterCommit
        self.remoteTrackingBeforeCommit = remoteTrackingBeforeCommit
        self.remoteTrackingAfterCommit = remoteTrackingAfterCommit
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.explanation = explanation
        self.technicalDetail = technicalDetail
        self.failureReason = failureReason
    }
}

public enum RunEventType: String, Codable, Sendable {
    case runStarted = "run_started"
    case repositoryPhase = "repository_phase"
    case repositoryResult = "repository_result"
    case runFinished = "run_finished"
    case diagnostic
}

public struct RunEvent: Codable, Equatable, Sendable {
    public let schema: String
    public let run: String
    public let sequence: Int
    public let timestamp: String
    public let type: RunEventType
    public let repositoryID: String?
    public let phase: RepositoryPhase?
    public let result: RepositoryResult?
    public let message: String?

    public init(
        run: String,
        sequence: Int,
        timestamp: String = WallClock.timestamp(),
        type: RunEventType,
        repositoryID: String? = nil,
        phase: RepositoryPhase? = nil,
        result: RepositoryResult? = nil,
        message: String? = nil
    ) {
        self.schema = shadowSyncEventSchema
        self.run = run
        self.sequence = sequence
        self.timestamp = timestamp
        self.type = type
        self.repositoryID = repositoryID
        self.phase = phase
        self.result = result
        self.message = message
    }
}

public enum RunCancellationState: String, Codable, Equatable, Sendable {
    case notCancelled = "not_cancelled"
    case cancelled
}

public struct RunReport: Codable, Equatable, Sendable {
    public let schema: String
    public let run: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int64
    public let cancelled: Bool
    public let cancellationState: RunCancellationState
    public let results: [RepositoryResult]
    public let summaryOverride: String?
    public let repositoryModel: String?

    public init(
        run: String,
        startedAt: String,
        endedAt: String,
        durationMilliseconds: Int64 = 0,
        cancelled: Bool,
        results: [RepositoryResult],
        summaryOverride: String? = nil,
        repositoryModel: String? = nil
    ) {
        self.schema = "shadow-sync-report/v1"
        self.run = run
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.cancelled = cancelled
        self.cancellationState = cancelled ? .cancelled : .notCancelled
        self.results = results
        self.summaryOverride = summaryOverride
        self.repositoryModel = repositoryModel
    }

    public var updatedCount: Int {
        results.filter { $0.mainUpdated }.count
    }

    public var alreadyCurrentCount: Int {
        results.filter { $0.code == .alreadyCurrent }.count
    }

    public var issueCount: Int {
        results.filter { $0.resultClass == .warning || $0.resultClass == .failure }.count
    }

    public var summary: String {
        if let summaryOverride {
            return summaryOverride
        }
        if cancelled {
            let completed = results.filter { $0.resultClass != .cancelled }.count
            let incomplete = results.filter { $0.resultClass == .cancelled }.count
            return "Run cancelled — \(completed) repositories completed before cancellation; \(incomplete) were not run. Completed updates were kept."
        }
        if issueCount > 0 {
            let skipped = results.filter {
                $0.resultClass == .warning && !$0.mainUpdated
            }.count
            let failed = results.filter { $0.resultClass == .failure }.count
            return "Run complete with issues — \(updatedCount) updated, \(skipped) skipped, \(failed) failed. Completed updates were kept."
        }
        return "Run complete — \(updatedCount) updated, \(alreadyCurrentCount) already current."
    }
}

public enum WallClock {
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct MonotonicInstant: Sendable {
    fileprivate let nanoseconds: UInt64

    public static func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    public func milliseconds(since earlier: MonotonicInstant) -> Int64 {
        Int64((nanoseconds - earlier.nanoseconds) / 1_000_000)
    }
}

public struct MonotonicDeadline: Sendable {
    private let deadlineNanoseconds: UInt64

    init(uptimeNanoseconds: UInt64) { deadlineNanoseconds = uptimeNanoseconds }

    public init(seconds: TimeInterval) {
        let now = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(max(0, seconds) * 1_000_000_000)
        let sum = now.addingReportingOverflow(duration)
        deadlineNanoseconds = sum.overflow ? .max : sum.partialValue
    }

    public var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds
    }

    public var remainingMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanoseconds else { return 0 }
        let milliseconds = (deadlineNanoseconds - now) / 1_000_000
        return Int32(min(max(1, milliseconds), UInt64(Int32.max)))
    }
}

/// Wall-clock budget for one owned child process. Production builds enforce the
/// configured value exactly. Testing builds stretch every child budget, and
/// every synthetic hang paired with one, by the same factor: fixture Git on a
/// loaded or swapping host can take several seconds to launch, which must not
/// read as a hung child, while a synthetic hang still outlives its budget.
public enum ChildProcessBudget {
    #if SHADOW_SYNC_TESTING
    public static let testingScale: TimeInterval = 6
    #endif

    public static func seconds(_ configured: TimeInterval) -> TimeInterval {
        #if SHADOW_SYNC_TESTING
        configured * testingScale
        #else
        configured
        #endif
    }
}

#if SHADOW_SYNC_TESTING
// Legacy Foundation convenience belongs to fixtures only, never production custody.
public enum OwnedProcessReaper {
    @discardableResult
    public static func wait(
        for process: Process,
        timeout: TimeInterval,
        terminateGrace: TimeInterval = 2,
        killGrace: TimeInterval = 2
    ) -> Bool {
        var identity = process.isRunning
            ? try? ProcessIdentity.capture(
                processID: process.processIdentifier,
                generation: RunIdentity.make()
            )
            : nil
        if process.isRunning, identity == nil {
            let settlement = MonotonicDeadline(seconds: 0.25)
            while process.isRunning, !settlement.hasExpired {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                identity = try? ProcessIdentity.capture(
                    processID: process.processIdentifier,
                    generation: RunIdentity.make()
                )
            }
        }
        let completion = MonotonicDeadline(seconds: timeout)
        while process.isRunning, !completion.hasExpired {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            guard let identity,
                  identity.isCurrent(requireGroupLeader: false) else {
                return false
            }
            _ = OwnedProcessSignal.send(
                SIGTERM,
                to: identity,
                expectedGeneration: identity.generation
            )
            let termination = MonotonicDeadline(seconds: terminateGrace)
            while process.isRunning, !termination.hasExpired {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                guard identity.isCurrent(requireGroupLeader: false) else {
                    return false
                }
                _ = OwnedProcessSignal.send(
                    SIGKILL,
                    to: identity,
                    expectedGeneration: identity.generation
                )
                let killed = MonotonicDeadline(seconds: killGrace)
                while process.isRunning, !killed.hasExpired {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        return true
    }
}

#endif
