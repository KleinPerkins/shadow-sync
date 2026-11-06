import CryptoKit
import Darwin
import Foundation

public let shadowSyncRepositoryAuthoritySchema =
    "shadow-sync-repository-authorities/v1"

public enum RemovalContentEvidence {
    public static func make(
        status: Data,
        index: Data,
        filesystemDigest: String
    ) -> String {
        var value = Data("status\u{0}".utf8)
        value.append(status)
        value.append(Data("\u{0}index\u{0}".utf8))
        value.append(index)
        value.append(
            Data(
                "\u{0}filesystem\u{0}\(filesystemDigest)"
                    .utf8
            )
        )
        return SHA256.hash(data: value).map {
            String(format: "%02x", $0)
        }.joined()
    }

    public static func filesystemDigest(
        rootDescriptor: Int32,
        includeRegularFileContents: Bool = false,
        cancellation: CancellationToken? = nil
    ) throws -> String {
        var hasher = SHA256()
        var count = 0
        var bytes: UInt64 = 0
        try appendDirectory(
            rootDescriptor,
            relativeParent: "",
            hasher: &hasher,
            count: &count,
            bytes: &bytes,
            includeRegularFileContents:
                includeRegularFileContents,
            cancellation: cancellation
        )
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static let maximumEntries = 1_000_000
    private static let maximumBytes: UInt64 =
        17_179_869_184

    private static func appendDirectory(
        _ descriptor: Int32,
        relativeParent: String,
        hasher: inout SHA256,
        count: inout Int,
        bytes: inout UInt64,
        includeRegularFileContents: Bool,
        cancellation: CancellationToken?
    ) throws {
        var directoryBefore = stat()
        guard fstat(descriptor, &directoryBefore) == 0,
              FileIdentity(directoryBefore).isDirectory else {
            throw GitSafetyError.unsafeRepository(
                "worktree content directory is unsafe"
            )
        }
        for name in try directoryNames(descriptor) {
            if cancellation?.isCancelled == true {
                throw GitSafetyError.cancelled
            }
            if relativeParent.isEmpty, name == ".git" {
                continue
            }
            count += 1
            guard count <= maximumEntries else {
                throw GitSafetyError.unsafeRepository(
                    "worktree content evidence exceeds its entry bound"
                )
            }
            let relative = relativeParent.isEmpty
                ? name : relativeParent + "/" + name
            var before = stat()
            guard fstatat(
                descriptor,
                name,
                &before,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree content entry is unavailable"
                )
            }
            appendSnapshot(
                relative,
                info: before,
                hasher: &hasher
            )
            let kind = before.st_mode & S_IFMT
            if kind == S_IFDIR {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY
                        | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree content directory is unavailable"
                    )
                }
                do {
                    try appendDirectory(
                        child,
                        relativeParent: relative,
                        hasher: &hasher,
                        count: &count,
                        bytes: &bytes,
                        includeRegularFileContents:
                            includeRegularFileContents,
                        cancellation: cancellation
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            } else {
                if kind == S_IFREG {
                    if includeRegularFileContents {
                        try appendRegularFile(
                            descriptor,
                            name: name,
                            before: before,
                            hasher: &hasher,
                            bytes: &bytes,
                            cancellation: cancellation
                        )
                    }
                } else if kind == S_IFLNK {
                    var bytes = [UInt8](
                        repeating: 0,
                        count: Int(MAXPATHLEN)
                    )
                    let length = readlinkat(
                        descriptor,
                        name,
                        &bytes,
                        bytes.count
                    )
                    guard length >= 0,
                          length < bytes.count else {
                        throw GitSafetyError
                            .unsafeRepository(
                                "worktree symlink target is unavailable"
                            )
                    }
                    let target = Data(
                        bytes.prefix(length)
                    )
                    hasher.update(
                        data: Data(
                            "\u{0}target:\(target.count):"
                                .utf8
                        )
                    )
                    hasher.update(data: target)
                } else if includeRegularFileContents {
                    throw GitSafetyError.unsafeRepository(
                        "worktree contains an unsupported file type"
                    )
                }
                var after = stat()
                guard fstatat(
                    descriptor,
                    name,
                    &after,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                sameSnapshot(before, after) else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree content changed during inspection"
                    )
                }
            }
        }
        var directoryAfter = stat()
        guard fstat(descriptor, &directoryAfter) == 0,
              sameSnapshot(
                directoryBefore,
                directoryAfter
              ) else {
            throw GitSafetyError.unsafeRepository(
                "worktree directory changed during inspection"
            )
        }
    }

    private static func appendRegularFile(
        _ directory: Int32,
        name: String,
        before: stat,
        hasher: inout SHA256,
        bytes: inout UInt64,
        cancellation: CancellationToken?
    ) throws {
        guard before.st_size >= 0,
              UInt64(before.st_size)
                <= maximumBytes - bytes else {
            throw GitSafetyError.unsafeRepository(
                "worktree content evidence exceeds its byte bound"
            )
        }
        bytes += UInt64(before.st_size)
        let file = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "worktree content file is unavailable"
            )
        }
        defer { Darwin.close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0,
              sameSnapshot(before, opened) else {
            throw GitSafetyError.unsafeRepository(
                "worktree content file changed while opening"
            )
        }
        hasher.update(
            data: Data(
                "\u{0}content:\(before.st_size):".utf8
            )
        )
        var buffer = [UInt8](
            repeating: 0,
            count: 65_536
        )
        while true {
            if cancellation?.isCancelled == true {
                throw GitSafetyError.cancelled
            }
            let count = Darwin.read(
                file,
                &buffer,
                buffer.count
            )
            if count > 0 {
                hasher.update(
                    data: Data(buffer.prefix(count))
                )
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw GitSafetyError.unsafeRepository(
                    "worktree content file cannot be read"
                )
            }
        }
        var after = stat()
        guard fstat(file, &after) == 0,
              sameSnapshot(before, after) else {
            throw GitSafetyError.unsafeRepository(
                "worktree content changed while reading"
            )
        }
    }

    private static func appendSnapshot(
        _ path: String,
        info: stat,
        hasher: inout SHA256
    ) {
        let pathData = Data(path.utf8)
        hasher.update(
            data: Data(
                "path:\(pathData.count):".utf8
            )
        )
        hasher.update(data: pathData)
        let metadata = [
            UInt64(info.st_dev),
            UInt64(info.st_ino),
            UInt64(info.st_mode),
            UInt64(info.st_nlink),
            UInt64(bitPattern: Int64(info.st_size)),
            UInt64(
                bitPattern:
                    Int64(info.st_mtimespec.tv_sec)
            ),
            UInt64(
                bitPattern:
                    Int64(info.st_mtimespec.tv_nsec)
            ),
            UInt64(
                bitPattern:
                    Int64(info.st_ctimespec.tv_sec)
            ),
            UInt64(
                bitPattern:
                    Int64(info.st_ctimespec.tv_nsec)
            ),
        ].map(String.init).joined(separator: ":")
        hasher.update(
            data: Data(
                ":\(metadata)\u{0}".utf8
            )
        )
    }

    private static func sameSnapshot(
        _ left: stat,
        _ right: stat
    ) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_mode == right.st_mode
            && left.st_nlink == right.st_nlink
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec
                == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec
                == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec
                == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec
                == right.st_ctimespec.tv_nsec
    }

    private static func directoryNames(
        _ descriptor: Int32
    ) throws -> [String] {
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY
                | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 {
                Darwin.close(duplicate)
            }
            throw GitSafetyError.unsafeRepository(
                "worktree content directory cannot be enumerated"
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
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0,
              names.count <= maximumEntries else {
            throw GitSafetyError.unsafeRepository(
                "worktree content directory enumeration failed"
            )
        }
        return names.sorted()
    }
}

public enum RepositoryPolicyCategory: String, Codable, Equatable, Sendable {
    case writable
    case repositoryOwnedWorkflow
    case permanentNoTouch
    case reference

    public var operatorLabel: String {
        switch self {
        case .writable:
            return "Writable"
        case .repositoryOwnedWorkflow:
            return "Repository-owned workflow"
        case .permanentNoTouch:
            return "Permanent no-touch"
        case .reference:
            return "Reference"
        }
    }
}

public struct RemoteDefaultBranch: Codable, Equatable, Sendable {
    public let name: String
    public let localRef: String
    public let remoteTrackingRef: String
    public let advertisedOID: String
    public let observedAt: String

    public init(
        name: String,
        advertisedOID: String,
        observedAt: String = WallClock.timestamp()
    ) throws {
        guard GitReferenceSyntax.isValidBranchName(name),
              Self.validOID(advertisedOID) else {
            throw GitSafetyError.unsafeRepository(
                "remote default branch response is invalid"
            )
        }
        self.name = name
        localRef = "refs/heads/\(name)"
        remoteTrackingRef = "refs/remotes/origin/\(name)"
        self.advertisedOID = advertisedOID.lowercased()
        self.observedAt = observedAt
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

public struct RemoteRepository: Codable, Equatable, Sendable {
    public let id: String
    public let origins: [String]
    public let policyCategory: RepositoryPolicyCategory
    public let resolvedDefault: RemoteDefaultBranch?
    public let defaultUnavailableReason: String?

    public init(
        id: String,
        origins: [String],
        policyCategory: RepositoryPolicyCategory,
        resolvedDefault: RemoteDefaultBranch?,
        defaultUnavailableReason: String?
    ) throws {
        guard Self.isNormalizedRepositoryID(id),
              !origins.isEmpty,
              origins.allSatisfy({
                  GitHubIdentity.parse($0)?.canonicalName == id
              }),
              resolvedDefault == nil
                || defaultUnavailableReason == nil else {
            throw GitSafetyError.unsafeRepository(
                "logical repository identity is invalid"
            )
        }
        self.id = id
        self.origins = Array(Set(origins)).sorted()
        self.policyCategory = policyCategory
        self.resolvedDefault = resolvedDefault
        self.defaultUnavailableReason = defaultUnavailableReason.map(
            Redactor.sanitize
        )
    }

    private static func isNormalizedRepositoryID(_ value: String) -> Bool {
        value == value.lowercased()
            && GitHubIdentity.parse(
                "git@github.com:\(value).git"
            )?.canonicalName == value
    }
}

public enum LocalCloneKind: String, Codable, Equatable, Sendable {
    case primaryCheckout
    case readOnlyReference
    case protected
}

public enum WorktreeLocationKind: String, Codable, Equatable, Sendable {
    case canonicalPrimary
    case dev
    case cursorManaged
    case awaManaged
    case external
}

public enum WorktreeCleanliness: String, Codable, Equatable, Sendable {
    case clean
    case dirty
    case unknown
}

public enum WorktreeVerification: String, Codable, Equatable, Sendable {
    case verified
    case unavailable
}

public enum UpstreamRelationKind:
    String, Codable, Equatable, Sendable {
    case equal
    case ahead
    case behind
    case diverged
    case unavailable
}

public struct BranchUpstream: Codable, Equatable, Sendable {
    public let fullRef: String
    public let localOID: String?
    public let upstreamOID: String?
    public let relation: UpstreamRelationKind
    public let aheadCount: Int?
    public let behindCount: Int?

    public init(
        fullRef: String,
        localOID: String?,
        upstreamOID: String?,
        relation: UpstreamRelationKind,
        aheadCount: Int?,
        behindCount: Int?
    ) {
        self.fullRef = fullRef
        self.localOID = localOID?.lowercased()
        self.upstreamOID = upstreamOID?.lowercased()
        self.relation = relation
        self.aheadCount = aheadCount
        self.behindCount = behindCount
    }
}

public struct Worktree: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let cloneID: String
    public let path: String
    public let rootIdentity: RepositoryDirectoryIdentity?
    public let registrationIdentity: RepositoryDirectoryIdentity?
    public let attachedBranchRef: String?
    public let detachedOID: String?
    public let isPrimary: Bool
    public let isLocked: Bool
    public let locationKind: WorktreeLocationKind
    public let verification: WorktreeVerification
    public let cleanliness: WorktreeCleanliness
    public let fileState: WorktreeFileState?
    public let contentEvidenceDigest: String?
    public let relationToDefault: DefaultBranchRelation?
    public let tipCommitDate: String?
    public let awaEvidence: AWAEvidence?
    public let purpose: PurposeAssessment?
    public let activity: ActivityBand?
    public let currentSession: Bool?
    public let removalPreview: RemovalPreview?
    public let warning: String?

    public init(
        id: String,
        cloneID: String,
        path: String,
        rootIdentity: RepositoryDirectoryIdentity?,
        registrationIdentity: RepositoryDirectoryIdentity?,
        attachedBranchRef: String?,
        detachedOID: String?,
        isPrimary: Bool,
        isLocked: Bool = false,
        locationKind: WorktreeLocationKind,
        verification: WorktreeVerification = .verified,
        cleanliness: WorktreeCleanliness = .unknown,
        fileState: WorktreeFileState? = nil,
        contentEvidenceDigest: String? = nil,
        relationToDefault: DefaultBranchRelation? = nil,
        tipCommitDate: String? = nil,
        awaEvidence: AWAEvidence? = nil,
        purpose: PurposeAssessment? = nil,
        activity: ActivityBand? = nil,
        currentSession: Bool? = nil,
        removalPreview: RemovalPreview? = nil,
        warning: String? = nil
    ) throws {
        guard id.hasPrefix("worktree:"),
              cloneID.hasPrefix("clone:"),
              path.hasPrefix("/"),
              (verification == .verified) == (rootIdentity != nil),
              attachedBranchRef == nil
                || GitReferenceSyntax.isValidLocalBranchRef(attachedBranchRef!),
              detachedOID == nil || Self.validOID(detachedOID!),
              relationToDefault?.isValid != false,
              tipCommitDate == nil
                || PullRequestRecord.parseTimestamp(
                    tipCommitDate!
                ) != nil,
              attachedBranchRef == nil || detachedOID == nil else {
            throw GitSafetyError.unsafeRepository(
                "worktree association is invalid"
            )
        }
        self.id = id
        self.cloneID = cloneID
        self.path = path
        self.rootIdentity = rootIdentity
        self.registrationIdentity = registrationIdentity
        self.attachedBranchRef = attachedBranchRef
        self.detachedOID = detachedOID
        self.isPrimary = isPrimary
        self.isLocked = isLocked
        self.locationKind = locationKind
        self.verification = verification
        self.cleanliness = cleanliness
        self.fileState = fileState
        self.contentEvidenceDigest = contentEvidenceDigest
        self.relationToDefault = relationToDefault
        self.tipCommitDate = tipCommitDate
        self.awaEvidence = awaEvidence
        self.purpose = purpose
        self.activity = activity
        self.currentSession = currentSession
        self.removalPreview = removalPreview
        self.warning = warning.map(Redactor.sanitize)
    }

    public var isVerifiedClean: Bool {
        verification == .verified && cleanliness == .clean
    }

    public var evidenceDigest: String {
        V2EvidenceDigest.make([
            id,
            cloneID,
            path,
            rootIdentity.map { "\($0.device):\($0.inode)" } ?? "unavailable",
            registrationIdentity.map { "\($0.device):\($0.inode)" }
                ?? "primary-or-unavailable",
            attachedBranchRef ?? "detached",
            detachedOID ?? "none",
            isLocked ? "locked" : "unlocked",
            verification.rawValue,
            cleanliness.rawValue,
            fileState.map {
                "\($0.trackedChanges):\($0.untrackedFiles):\($0.ignoredFiles):\($0.hiddenIndexState):\($0.operationState.rawValue)"
            } ?? "file-state-unavailable",
            contentEvidenceDigest ?? "content-evidence-unavailable",
            relationToDefault.map {
                "\($0.kind.rawValue):\($0.aheadCount.map(String.init) ?? "none"):\($0.behindCount.map(String.init) ?? "none")"
            } ?? "relation-unavailable",
            tipCommitDate ?? "commit-date-unavailable",
            awaEvidence?.state.rawValue ?? "awa-unavailable",
            currentSession.map(String.init)
                ?? "current-session-unknown",
        ])
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

public struct Branch: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let cloneID: String
    public let fullRef: String
    public let name: String
    public let tipOID: String?
    public let claimingWorktreeIDs: [String]
    public let relationToDefault: DefaultBranchRelation?
    public let upstream: BranchUpstream?
    public let commitDate: String?
    public let pullRequests: [PullRequestRecord]?
    public let pullRequestAvailability: PullRequestAvailability?
    public let purpose: PurposeAssessment?
    public let activity: ActivityBand?
    public let removalPreview: RemovalPreview?

    public init(
        cloneID: String,
        fullRef: String,
        tipOID: String?,
        claimingWorktreeIDs: [String],
        relationToDefault: DefaultBranchRelation? = nil,
        upstream: BranchUpstream? = nil,
        commitDate: String? = nil,
        pullRequests: [PullRequestRecord]? = nil,
        pullRequestAvailability: PullRequestAvailability? = nil,
        purpose: PurposeAssessment? = nil,
        activity: ActivityBand? = nil,
        removalPreview: RemovalPreview? = nil
    ) throws {
        guard GitReferenceSyntax.isValidLocalBranchRef(fullRef),
              tipOID == nil || Self.validOID(tipOID!),
              Set(claimingWorktreeIDs).count == claimingWorktreeIDs.count,
              claimingWorktreeIDs.allSatisfy({
                  $0.hasPrefix("worktree:")
              }),
              relationToDefault?.isValid != false,
              commitDate == nil
                || PullRequestRecord.parseTimestamp(commitDate!) != nil else {
            throw GitSafetyError.unsafeRepository(
                "branch association is invalid"
            )
        }
        id = "branch:\(cloneID):\(fullRef)"
        self.cloneID = cloneID
        self.fullRef = fullRef
        name = String(fullRef.dropFirst("refs/heads/".count))
        self.tipOID = tipOID?.lowercased()
        self.claimingWorktreeIDs = claimingWorktreeIDs.sorted()
        self.relationToDefault = relationToDefault
        self.upstream = upstream
        self.commitDate = commitDate
        self.pullRequests = pullRequests?.sorted { $0.number < $1.number }
        self.pullRequestAvailability = pullRequestAvailability
        self.purpose = purpose
        self.activity = activity
        self.removalPreview = removalPreview
    }

    public var evidenceDigest: String {
        let relation = relationToDefault.map {
            "\($0.kind.rawValue):\($0.aheadCount.map(String.init) ?? "none"):\($0.behindCount.map(String.init) ?? "none")"
        } ?? "relation-unavailable"
        let upstream = upstream.map {
            "\($0.fullRef):\($0.localOID ?? "none"):\($0.upstreamOID ?? "none"):\($0.relation.rawValue):\($0.aheadCount.map(String.init) ?? "none"):\($0.behindCount.map(String.init) ?? "none")"
        } ?? "upstream-unavailable"
        let pullRequestEvidence = (pullRequests ?? []).map {
            "\($0.number):\($0.repositoryID):\($0.state.rawValue):\($0.headRefName):\($0.headRefOID ?? "none"):\($0.isCrossRepository):\($0.updatedAt):\($0.closedAt ?? "none"):\($0.mergedAt ?? "none")"
        }.joined(separator: "|")
        return V2EvidenceDigest.make([
            id,
            cloneID,
            fullRef,
            tipOID ?? "tip-unavailable",
            claimingWorktreeIDs.joined(separator: ","),
            relation,
            upstream,
            commitDate ?? "commit-date-unavailable",
            pullRequestAvailability?.rawValue
                ?? "pull-request-availability-unavailable",
            pullRequestEvidence,
            purpose?.purpose.rawValue ?? "purpose-unavailable",
            activity?.rawValue ?? "activity-unavailable",
            removalPreview?.recommendation.rawValue
                ?? "recommendation-unavailable",
            removalPreview?.permission.rawValue
                ?? "permission-unavailable",
            removalPreview?.explanation
                ?? "explanation-unavailable",
        ])
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

public struct LocalClone: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repositoryID: String
    public let primaryRoot: String
    public let rootIdentity: RepositoryDirectoryIdentity
    public let commonDirectoryIdentity: RepositoryDirectoryIdentity
    public let rawOrigin: String
    public let effectiveOrigin: String
    public let originParityVerified: Bool
    public let policyCategory: RepositoryPolicyCategory
    public let kind: LocalCloneKind
    public let worktrees: [Worktree]
    public let branches: [Branch]
    public let warnings: [String]
    public let sourceSnapshot: RepositoryCandidate

    public init(
        repositoryID: String,
        sourceSnapshot: RepositoryCandidate,
        effectiveOrigin: String,
        originParityVerified: Bool,
        policyCategory: RepositoryPolicyCategory,
        kind: LocalCloneKind,
        worktrees: [Worktree],
        branches: [Branch],
        warnings: [String]
    ) throws {
        guard let rootIdentity = sourceSnapshot.rootIdentity,
              let commonDirectoryIdentity =
                sourceSnapshot.commonDirectoryIdentity,
              sourceSnapshot.originIdentity?.canonicalName == repositoryID,
              GitHubIdentity.parse(effectiveOrigin)?.canonicalName
                == repositoryID else {
            throw GitSafetyError.unsafeRepository(
                "local clone identity is incomplete"
            )
        }
        id = Self.id(for: commonDirectoryIdentity)
        self.repositoryID = repositoryID
        primaryRoot = sourceSnapshot.path
        self.rootIdentity = rootIdentity
        self.commonDirectoryIdentity = commonDirectoryIdentity
        rawOrigin = sourceSnapshot.rawOrigin
        self.effectiveOrigin = effectiveOrigin
        self.originParityVerified = originParityVerified
        self.policyCategory = policyCategory
        self.kind = kind
        self.worktrees = worktrees.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        self.branches = branches.sorted {
            $0.fullRef.localizedStandardCompare($1.fullRef)
                == .orderedAscending
        }
        self.warnings = warnings.map(Redactor.sanitize)
        self.sourceSnapshot = sourceSnapshot
    }

    public static func id(
        for commonDirectoryIdentity: RepositoryDirectoryIdentity
    ) -> String {
        "clone:\(commonDirectoryIdentity.device):\(commonDirectoryIdentity.inode)"
    }

    public var isWritable: Bool {
        policyCategory == .writable
    }

    public var isAuthorityEligible: Bool {
        isWritable && originParityVerified && warnings.isEmpty
    }

    public var authorityEvidenceDigest: String {
        V2EvidenceDigest.make([
            repositoryID,
            primaryRoot,
            String(rootIdentity.device),
            String(rootIdentity.inode),
            String(commonDirectoryIdentity.device),
            String(commonDirectoryIdentity.inode),
            rawOrigin,
            effectiveOrigin,
            originParityVerified ? "verified" : "unverified",
            policyCategory.rawValue,
            sourceSnapshot.configIdentity.map {
                "\($0.identity.device):\($0.identity.inode):\($0.size):\($0.modifiedSeconds):\($0.modifiedNanoseconds)"
            } ?? "missing-config",
            sourceSnapshot.policyAdmissionSHA256 ?? "missing-policy",
        ])
    }
}

public struct RepositoryAuthorityRecord: Codable, Equatable, Sendable {
    public let repositoryID: String
    public let canonicalRoot: String
    public let rootIdentity: RepositoryDirectoryIdentity
    public let commonDirectoryIdentity: RepositoryDirectoryIdentity
    public let updatedAt: String

    public init(clone: LocalClone, updatedAt: String = WallClock.timestamp()) {
        repositoryID = clone.repositoryID
        canonicalRoot = clone.primaryRoot
        rootIdentity = clone.rootIdentity
        commonDirectoryIdentity = clone.commonDirectoryIdentity
        self.updatedAt = updatedAt
    }

    init(
        repositoryID: String,
        canonicalRoot: String,
        rootIdentity: FileIdentity,
        commonDirectoryIdentity: FileIdentity,
        updatedAt: String = WallClock.timestamp()
    ) {
        self.repositoryID = repositoryID
        self.canonicalRoot = canonicalRoot
        self.rootIdentity = RepositoryDirectoryIdentity(
            rootIdentity
        )
        self.commonDirectoryIdentity = RepositoryDirectoryIdentity(
            commonDirectoryIdentity
        )
        self.updatedAt = updatedAt
    }

    public func matches(_ clone: LocalClone) -> Bool {
        clone.isAuthorityEligible
            && repositoryID == clone.repositoryID
            && canonicalRoot == clone.primaryRoot
            && rootIdentity == clone.rootIdentity
            && commonDirectoryIdentity == clone.commonDirectoryIdentity
            && GitHubIdentity.parse(clone.rawOrigin)?.canonicalName
                == repositoryID
            && GitHubIdentity.parse(clone.effectiveOrigin)?.canonicalName
                == repositoryID
    }

    public func matchesExceptDevice(
        _ clone: LocalClone
    ) -> Bool {
        clone.isAuthorityEligible
            && repositoryID == clone.repositoryID
            && canonicalRoot == clone.primaryRoot
            && rootIdentity.inode == clone.rootIdentity.inode
            && commonDirectoryIdentity.inode
                == clone.commonDirectoryIdentity.inode
            && (
                rootIdentity.device != clone.rootIdentity.device
                    || commonDirectoryIdentity.device
                        != clone.commonDirectoryIdentity.device
            )
            && GitHubIdentity.parse(clone.rawOrigin)?.canonicalName
                == repositoryID
            && GitHubIdentity.parse(clone.effectiveOrigin)?.canonicalName
                == repositoryID
    }
}

public struct RepositoryAuthorityDocument: Codable, Equatable, Sendable {
    public let schema: String
    public let revision: UInt64
    public let records: [RepositoryAuthorityRecord]

    public init(
        revision: UInt64,
        records: [RepositoryAuthorityRecord]
    ) throws {
        guard Set(records.map(\.repositoryID)).count == records.count,
              records.allSatisfy({
                  $0.repositoryID == $0.repositoryID.lowercased()
                    && GitHubIdentity.parse(
                        "git@github.com:\($0.repositoryID).git"
                    )?.canonicalName == $0.repositoryID
                    && $0.canonicalRoot.hasPrefix("/")
                    && !$0.canonicalRoot.contains("\n")
                    && !$0.canonicalRoot.contains("\r")
                    && !$0.canonicalRoot.contains("\0")
                    && !$0.updatedAt.isEmpty
              }) else {
            throw GitSafetyError.unsafeRepository(
                "repository authority records are invalid"
            )
        }
        schema = shadowSyncRepositoryAuthoritySchema
        self.revision = revision
        self.records = records.sorted {
            $0.repositoryID.localizedStandardCompare($1.repositoryID)
                == .orderedAscending
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case revision
        case records
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(String.self, forKey: .schema)
        guard schema == shadowSyncRepositoryAuthoritySchema else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: values,
                debugDescription: "unsupported repository authority schema"
            )
        }
        try self.init(
            revision: values.decode(UInt64.self, forKey: .revision),
            records: values.decode(
                [RepositoryAuthorityRecord].self,
                forKey: .records
            )
        )
    }
}

public enum CanonicalAuthorityStatus: String, Codable, Equatable, Sendable {
    case usable
    case missing
    case ambiguous
    case stale
    case unavailable
    case notApplicable
}

public struct CanonicalAuthorityState: Codable, Equatable, Sendable {
    public let status: CanonicalAuthorityStatus
    public let record: RepositoryAuthorityRecord?
    public let explanation: String

    public init(
        status: CanonicalAuthorityStatus,
        record: RepositoryAuthorityRecord?,
        explanation: String
    ) {
        self.status = status
        self.record = record
        self.explanation = Redactor.sanitize(explanation)
    }
}

public enum DefaultBranchRelationKind:
    String, Codable, Equatable, Sendable {
    case equal
    case behind
    case ahead
    case diverged
    case unavailable
}

public enum DefaultBranchRelationUnavailableReason:
    String, Codable, Equatable, Sendable {
    case remoteChangedSinceLastFetch
}

public struct DefaultBranchRelation: Codable, Equatable, Sendable {
    public let kind: DefaultBranchRelationKind
    public let aheadCount: Int?
    public let behindCount: Int?
    public let unavailableReason:
        DefaultBranchRelationUnavailableReason?

    public init(
        kind: DefaultBranchRelationKind,
        aheadCount: Int?,
        behindCount: Int?,
        unavailableReason:
            DefaultBranchRelationUnavailableReason? = nil
    ) {
        self.kind = kind
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.unavailableReason = unavailableReason
    }

    public static let unavailable = DefaultBranchRelation(
        kind: .unavailable,
        aheadCount: nil,
        behindCount: nil
    )

    public static let remoteChangedSinceLastFetch =
        DefaultBranchRelation(
            kind: .unavailable,
            aheadCount: nil,
            behindCount: nil,
            unavailableReason: .remoteChangedSinceLastFetch
        )

    public var isValid: Bool {
        switch kind {
        case .equal:
            return aheadCount == 0 && behindCount == 0
        case .behind:
            return aheadCount == 0 && (behindCount ?? 0) > 0
        case .ahead:
            return (aheadCount ?? 0) > 0 && behindCount == 0
        case .diverged:
            return (aheadCount ?? 0) > 0 && (behindCount ?? 0) > 0
        case .unavailable:
            return aheadCount == nil && behindCount == nil
        }
    }

    public var operatorLabel: String {
        switch kind {
        case .equal:
            return "Equal · ahead 0 · behind 0"
        case .behind:
            return "Behind \(behindCount ?? 0) · ahead \(aheadCount ?? 0)"
        case .ahead:
            return "Ahead \(aheadCount ?? 0) · behind \(behindCount ?? 0)"
        case .diverged:
            return "Diverged · ahead \(aheadCount ?? 0) · behind \(behindCount ?? 0)"
        case .unavailable:
            return unavailableReason == .remoteChangedSinceLastFetch
                ? "Remote changed since last fetch · exact comparison pending"
                : "Unavailable"
        }
    }
}

public enum DefaultBranchUpdateMode: String, Codable, Equatable, Sendable {
    case checkedOut
    case refOnly
    case refOnlyUnavailable
    case metadataMaintenance
    case initializeAbsent
}

public struct DefaultBranchUpdateTarget:
    Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repository: RemoteRepository
    public let canonicalClone: LocalClone
    public let resolvedDefault: RemoteDefaultBranch
    public let expectedLocalOID: String?
    public let expectedFetchedOID: String
    public let operationHookSHA256: String?
    public let registrationSetSHA256: String?
    public let preservationSHA256: String?
    public let mode: DefaultBranchUpdateMode
    public let worktreeID: String?
    public let relation: DefaultBranchRelation

    public init(
        repository: RemoteRepository,
        canonicalClone: LocalClone,
        resolvedDefault: RemoteDefaultBranch,
        expectedLocalOID: String?,
        expectedFetchedOID: String,
        operationHookSHA256: String? = nil,
        registrationSetSHA256: String? = nil,
        preservationSHA256: String? = nil,
        mode: DefaultBranchUpdateMode,
        worktreeID: String?,
        relation: DefaultBranchRelation
    ) throws {
        let claims = canonicalClone.branches.first {
            $0.fullRef == resolvedDefault.localRef
        }?.claimingWorktreeIDs ?? []
        guard repository.id == canonicalClone.repositoryID,
              repository.resolvedDefault == resolvedDefault,
              expectedFetchedOID.lowercased()
                == resolvedDefault.advertisedOID,
              expectedLocalOID == nil
                || Self.validOID(expectedLocalOID!),
              operationHookSHA256 == nil
                || Self.validSHA256(operationHookSHA256!),
              registrationSetSHA256 == nil
                || Self.validSHA256(registrationSetSHA256!),
              preservationSHA256 == nil
                || Self.validSHA256(preservationSHA256!),
              relation.isValid,
              mode != .checkedOut
                || (
                    worktreeID != nil
                        && claims == [worktreeID!]
                        && canonicalClone.worktrees.contains(where: {
                            $0.id == worktreeID
                                && $0.attachedBranchRef
                                    == resolvedDefault.localRef
                        })
                ),
              mode != .refOnly
                || (
                    worktreeID == nil
                        && expectedLocalOID != nil
                        && operationHookSHA256 != nil
                        && registrationSetSHA256 != nil
                        && preservationSHA256 != nil
                        && claims.isEmpty
                ),
              mode != .refOnlyUnavailable || worktreeID == nil,
              (mode == .checkedOut) == (worktreeID != nil),
              mode != .initializeAbsent || expectedLocalOID == nil else {
            throw GitSafetyError.unsafeRepository(
                "default branch update target is invalid"
            )
        }
        id = "default:\(repository.id):\(canonicalClone.id):\(resolvedDefault.name)"
        self.repository = repository
        self.canonicalClone = canonicalClone
        self.resolvedDefault = resolvedDefault
        self.expectedLocalOID = expectedLocalOID?.lowercased()
        self.expectedFetchedOID = expectedFetchedOID.lowercased()
        self.operationHookSHA256 =
            operationHookSHA256?.lowercased()
        self.registrationSetSHA256 =
            registrationSetSHA256?.lowercased()
        self.preservationSHA256 =
            preservationSHA256?.lowercased()
        self.mode = mode
        self.worktreeID = worktreeID
        self.relation = relation
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }

    public var worktree: Worktree? {
        guard let worktreeID else { return nil }
        return canonicalClone.worktrees.first { $0.id == worktreeID }
    }
}

public enum PlannedOperationKind: String, Codable, Equatable, Sendable {
    case fastForward
    case repairPruneRegistrations
    case repairMovedWorktree
    case initializeDefaultBranch
}

public struct PrunableRegistrationEvidence:
    Codable, Equatable, Sendable {
    public let registrationID: String
    public let expectedWorktreePath: String
    public let branchRef: String
    public let branchOID: String
    public let registrationIdentity: RepositoryDirectoryIdentity
    public let gitdirIdentity: RepositoryMetadataFileIdentity
    public let headIdentity: RepositoryMetadataFileIdentity
    public let commondirIdentity: RepositoryMetadataFileIdentity

    public init(
        registrationID: String,
        expectedWorktreePath: String,
        branchRef: String,
        branchOID: String,
        registrationIdentity: RepositoryDirectoryIdentity,
        gitdirIdentity: RepositoryMetadataFileIdentity,
        headIdentity: RepositoryMetadataFileIdentity,
        commondirIdentity: RepositoryMetadataFileIdentity
    ) throws {
        guard !registrationID.isEmpty,
              !registrationID.contains("/"),
              !registrationID.contains("\0"),
              expectedWorktreePath.hasPrefix("/"),
              GitReferenceSyntax.isValidLocalBranchRef(branchRef),
              Self.validOID(branchOID) else {
            throw GitSafetyError.unsafeRepository(
                "prunable worktree evidence is invalid"
            )
        }
        self.registrationID = registrationID
        self.expectedWorktreePath = expectedWorktreePath
        self.branchRef = branchRef
        self.branchOID = branchOID.lowercased()
        self.registrationIdentity = registrationIdentity
        self.gitdirIdentity = gitdirIdentity
        self.headIdentity = headIdentity
        self.commondirIdentity = commondirIdentity
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

public struct MovedWorktreeEvidence: Codable, Equatable, Sendable {
    public let registrationID: String
    public let previousPath: String
    public let verifiedPath: String
    public let branchRef: String
    public let branchOID: String
    public let rootIdentity: RepositoryDirectoryIdentity
    public let markerIdentity: RepositoryMetadataFileIdentity
    public let registrationIdentity: RepositoryDirectoryIdentity
    public let gitdirIdentity: RepositoryMetadataFileIdentity
    public let headIdentity: RepositoryMetadataFileIdentity
    public let commondirIdentity: RepositoryMetadataFileIdentity
    public let registrationSetDigest: String
    public let payloadDigest: String
    public let payloadFileCount: Int
    public let payloadByteCount: Int64
    public let awaLeaseID: String?

    public init(
        registrationID: String,
        previousPath: String,
        verifiedPath: String,
        branchRef: String,
        branchOID: String,
        rootIdentity: RepositoryDirectoryIdentity,
        markerIdentity: RepositoryMetadataFileIdentity,
        registrationIdentity: RepositoryDirectoryIdentity,
        gitdirIdentity: RepositoryMetadataFileIdentity,
        headIdentity: RepositoryMetadataFileIdentity,
        commondirIdentity: RepositoryMetadataFileIdentity,
        registrationSetDigest: String,
        payloadDigest: String,
        payloadFileCount: Int,
        payloadByteCount: Int64,
        awaLeaseID: String? = nil
    ) throws {
        guard !registrationID.isEmpty,
              !registrationID.contains("/"),
              previousPath.hasPrefix("/"),
              verifiedPath.hasPrefix("/"),
              previousPath != verifiedPath,
              GitReferenceSyntax.isValidLocalBranchRef(branchRef),
              Self.validOID(branchOID),
              registrationSetDigest.count == 64,
              registrationSetDigest.allSatisfy({
                  $0.isNumber
                    || ("a"..."f").contains($0.lowercased())
              }),
              payloadDigest.count == 64,
              payloadDigest.allSatisfy({
                  $0.isNumber
                    || ("a"..."f").contains($0.lowercased())
              }),
              payloadFileCount >= 0,
              payloadFileCount <= 10_001,
              payloadByteCount >= 0,
              payloadByteCount <= 67_108_864 else {
            throw GitSafetyError.unsafeRepository(
                "moved worktree evidence is invalid"
            )
        }
        self.registrationID = registrationID
        self.previousPath = previousPath
        self.verifiedPath = verifiedPath
        self.branchRef = branchRef
        self.branchOID = branchOID.lowercased()
        self.rootIdentity = rootIdentity
        self.markerIdentity = markerIdentity
        self.registrationIdentity = registrationIdentity
        self.gitdirIdentity = gitdirIdentity
        self.headIdentity = headIdentity
        self.commondirIdentity = commondirIdentity
        self.registrationSetDigest =
            registrationSetDigest.lowercased()
        self.payloadDigest = payloadDigest.lowercased()
        self.payloadFileCount = payloadFileCount
        self.payloadByteCount = payloadByteCount
        self.awaLeaseID = awaLeaseID
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

public enum RepositoryMaintenanceEvidence:
    Codable, Equatable, Sendable {
    case prune([PrunableRegistrationEvidence])
    case repairMoved(MovedWorktreeEvidence)
    case initializeDefault

    var digestFields: [String] {
        switch self {
        case let .prune(registrations):
            return ["prune"] + registrations.flatMap {
                [
                    $0.registrationID,
                    $0.expectedWorktreePath,
                    $0.branchRef,
                    $0.branchOID,
                    "\($0.registrationIdentity.device):\($0.registrationIdentity.inode)",
                    "\($0.gitdirIdentity.identity.device):\($0.gitdirIdentity.identity.inode):\($0.gitdirIdentity.size):\($0.gitdirIdentity.modifiedSeconds):\($0.gitdirIdentity.modifiedNanoseconds)",
                    "\($0.headIdentity.identity.device):\($0.headIdentity.identity.inode):\($0.headIdentity.size):\($0.headIdentity.modifiedSeconds):\($0.headIdentity.modifiedNanoseconds)",
                    "\($0.commondirIdentity.identity.device):\($0.commondirIdentity.identity.inode):\($0.commondirIdentity.size):\($0.commondirIdentity.modifiedSeconds):\($0.commondirIdentity.modifiedNanoseconds)",
                ]
            }
        case let .repairMoved(evidence):
            return [
                "repair-moved",
                evidence.registrationID,
                evidence.previousPath,
                evidence.verifiedPath,
                evidence.branchRef,
                evidence.branchOID,
                "\(evidence.rootIdentity.device):\(evidence.rootIdentity.inode)",
                "\(evidence.markerIdentity.identity.device):\(evidence.markerIdentity.identity.inode):\(evidence.markerIdentity.size):\(evidence.markerIdentity.modifiedSeconds):\(evidence.markerIdentity.modifiedNanoseconds)",
                "\(evidence.registrationIdentity.device):\(evidence.registrationIdentity.inode)",
                "\(evidence.gitdirIdentity.identity.device):\(evidence.gitdirIdentity.identity.inode):\(evidence.gitdirIdentity.size):\(evidence.gitdirIdentity.modifiedSeconds):\(evidence.gitdirIdentity.modifiedNanoseconds)",
                "\(evidence.headIdentity.identity.device):\(evidence.headIdentity.identity.inode):\(evidence.headIdentity.size):\(evidence.headIdentity.modifiedSeconds):\(evidence.headIdentity.modifiedNanoseconds)",
                "\(evidence.commondirIdentity.identity.device):\(evidence.commondirIdentity.identity.inode):\(evidence.commondirIdentity.size):\(evidence.commondirIdentity.modifiedSeconds):\(evidence.commondirIdentity.modifiedNanoseconds)",
                evidence.registrationSetDigest,
                evidence.payloadDigest,
                String(evidence.payloadFileCount),
                String(evidence.payloadByteCount),
                evidence.awaLeaseID ?? "no-awa-lease",
            ]
        case .initializeDefault:
            return ["initialize-default"]
        }
    }
}

public enum PlannedOperationStatus: String, Codable, Equatable, Sendable {
    case planned
    case refused
}

public struct PlannedOperation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: PlannedOperationKind
    public let target: DefaultBranchUpdateTarget
    public let dependencies: [String]
    public let evidenceDigest: String
    public let consequence: String
    public let status: PlannedOperationStatus
    public let refusalReason: String?
    public let maintenanceEvidence: RepositoryMaintenanceEvidence?

    public init(
        target: DefaultBranchUpdateTarget,
        capability: VerifiedRepositoryAuthorityCapability,
        status: PlannedOperationStatus = .planned,
        refusalReason: String? = nil
    ) throws {
        guard capability.admits(target) else {
            throw GitSafetyError.unsafeRepository(
                "planned operation lacks verified selected authority"
            )
        }
        self.init(
            unverifiedTarget: target,
            status: status,
            refusalReason: refusalReason
        )
    }

    #if SHADOW_SYNC_TESTING
    public init(
        target: DefaultBranchUpdateTarget,
        status: PlannedOperationStatus = .planned,
        refusalReason: String? = nil
    ) {
        self.init(
            unverifiedTarget: target,
            status: status,
            refusalReason: refusalReason
        )
    }
    #endif

    private init(
        unverifiedTarget target: DefaultBranchUpdateTarget,
        status: PlannedOperationStatus,
        refusalReason: String?
    ) {
        id = "operation:fast-forward:\(target.id)"
        kind = .fastForward
        self.target = target
        dependencies = []
        evidenceDigest = V2EvidenceDigest.make([
            target.id,
            target.repository.id,
            target.canonicalClone.authorityEvidenceDigest,
            target.resolvedDefault.localRef,
            target.resolvedDefault.remoteTrackingRef,
            target.expectedLocalOID ?? "missing",
            target.expectedFetchedOID,
            target.operationHookSHA256
                ?? "operation-hook-unavailable",
            target.registrationSetSHA256
                ?? "registration-set-unavailable",
            target.preservationSHA256
                ?? "preservation-unavailable",
            target.relation.kind.rawValue,
            String(target.relation.aheadCount ?? -1),
            String(target.relation.behindCount ?? -1),
            target.mode.rawValue,
            target.worktreeID ?? "none",
            target.worktree?.evidenceDigest ?? "no-worktree",
        ])
        consequence = target.mode == .refOnly
            ? "Fetch only the resolved default branch, then compare-and-swap its existing unclaimed local ref when it is Behind. No checkout, index, or worktree is changed."
            : "Fetch only the resolved default branch, then fast-forward its verified clean checked-out worktree when it is Behind."
        self.status = status
        self.refusalReason = refusalReason.map(Redactor.sanitize)
        maintenanceEvidence = nil
    }

    public init(
        kind: PlannedOperationKind,
        target: DefaultBranchUpdateTarget,
        maintenanceEvidence: RepositoryMaintenanceEvidence,
        capability: VerifiedRepositoryAuthorityCapability,
        status: PlannedOperationStatus = .planned,
        refusalReason: String? = nil
    ) throws {
        guard capability.admits(target) else {
            throw GitSafetyError.unsafeRepository(
                "planned maintenance operation lacks verified selected authority"
            )
        }
        try self.init(
            unverifiedKind: kind,
            target: target,
            maintenanceEvidence: maintenanceEvidence,
            status: status,
            refusalReason: refusalReason
        )
    }

    #if SHADOW_SYNC_TESTING
    public init(
        kind: PlannedOperationKind,
        target: DefaultBranchUpdateTarget,
        maintenanceEvidence: RepositoryMaintenanceEvidence,
        status: PlannedOperationStatus = .planned,
        refusalReason: String? = nil
    ) throws {
        try self.init(
            unverifiedKind: kind,
            target: target,
            maintenanceEvidence: maintenanceEvidence,
            status: status,
            refusalReason: refusalReason
        )
    }
    #endif

    private init(
        unverifiedKind kind: PlannedOperationKind,
        target: DefaultBranchUpdateTarget,
        maintenanceEvidence: RepositoryMaintenanceEvidence,
        status: PlannedOperationStatus,
        refusalReason: String?
    ) throws {
        guard kind != .fastForward,
              Self.evidenceMatches(
                  kind: kind,
                  target: target,
                  evidence: maintenanceEvidence
              ) else {
            throw GitSafetyError.unsafeRepository(
                "repository maintenance operation is invalid"
            )
        }
        id = "operation:\(kind.rawValue):\(target.id):"
            + String(V2EvidenceDigest.make(
                maintenanceEvidence.digestFields
            ).prefix(16))
        self.kind = kind
        self.target = target
        switch maintenanceEvidence {
        case .prune:
            dependencies = []
            consequence =
                "Repair can remove Git's selected stale registrations for missing non-default worktrees. Branches and commits stay in place. The shared lock cannot exclude arbitrary external filesystem deletion in the final sub-second gap; unexpected poststate requires review."
        case .repairMoved:
            dependencies = []
            consequence =
                "Repair can reconnect one clean moved feature worktree to its existing Git registration. Files, index bytes, and branch refs will not be changed."
        case .initializeDefault:
            dependencies = []
            consequence =
                "Initialize can create the missing local actual-default branch at the verified fetched commit. No worktree will be switched."
        }
        evidenceDigest = V2EvidenceDigest.make([
            id,
            target.id,
            target.repository.id,
            target.canonicalClone.authorityEvidenceDigest,
            target.resolvedDefault.localRef,
            target.resolvedDefault.remoteTrackingRef,
            target.expectedLocalOID ?? "missing",
            target.expectedFetchedOID,
            target.mode.rawValue,
        ] + maintenanceEvidence.digestFields)
        self.status = status
        self.refusalReason = refusalReason.map(Redactor.sanitize)
        self.maintenanceEvidence = maintenanceEvidence
    }

    public var isSelectable: Bool {
        guard isStructurallyValid,
              status == .planned,
              target.repository.policyCategory == .writable,
              target.canonicalClone.isAuthorityEligible else {
            return false
        }
        switch kind {
        case .fastForward:
            guard maintenanceEvidence == nil,
                  target.expectedLocalOID != nil else {
                return false
            }
            if target.mode == .checkedOut {
                return target.worktree?.isVerifiedClean == true
                    && (
                        target.relation.kind == .equal
                            || target.relation.kind == .behind
                            || target.relation.kind == .unavailable
                    )
            }
            return target.mode == .refOnly
                && (
                    target.relation.kind == .equal
                        || target.relation.kind == .behind
                )
                && target.worktree == nil
                && target.operationHookSHA256 != nil
                && target.registrationSetSHA256 != nil
                && target.preservationSHA256 != nil
                && target.canonicalClone.branches
                    .first {
                        $0.fullRef
                            == target.resolvedDefault.localRef
                    }?
                    .claimingWorktreeIDs.isEmpty == true
        case .repairPruneRegistrations:
            guard case let .prune(items)? = maintenanceEvidence else {
                return false
            }
            return target.mode == .metadataMaintenance
                && !items.isEmpty
        case .repairMovedWorktree:
            guard case .repairMoved? = maintenanceEvidence else {
                return false
            }
            return target.mode == .metadataMaintenance
        case .initializeDefaultBranch:
            guard case .initializeDefault? = maintenanceEvidence else {
                return false
            }
            return target.mode == .initializeAbsent
                && target.expectedLocalOID == nil
                && (
                    target.canonicalClone.branches.first {
                        $0.fullRef
                            == target.resolvedDefault.localRef
                    }?.claimingWorktreeIDs.isEmpty != false
                )
        }
    }

    public var isStructurallyValid: Bool {
        do {
            let remoteDefault = try RemoteDefaultBranch(
                name: target.resolvedDefault.name,
                advertisedOID: target.resolvedDefault.advertisedOID,
                observedAt: target.resolvedDefault.observedAt
            )
            guard remoteDefault == target.resolvedDefault else {
                return false
            }
            let repository = try RemoteRepository(
                id: target.repository.id,
                origins: target.repository.origins,
                policyCategory: target.repository.policyCategory,
                resolvedDefault: target.repository.resolvedDefault,
                defaultUnavailableReason:
                    target.repository.defaultUnavailableReason
            )
            guard repository == target.repository else {
                return false
            }
            let clone = target.canonicalClone
            let worktreeIDs = Set(clone.worktrees.map(\.id))
            let primaryWorktrees = clone.worktrees.filter(\.isPrimary)
            let verifiedWorktreeIDs = Set(clone.worktrees.compactMap {
                worktree -> String? in
                guard let root = worktree.rootIdentity else {
                    return worktree.verification == .unavailable
                        ? worktree.id : nil
                }
                let expected =
                    "worktree:\(clone.id):\(root.device):\(root.inode)"
                return worktree.verification == .verified
                        && worktree.id == expected
                    ? worktree.id : nil
            })
            guard worktreeIDs.count == clone.worktrees.count,
                  verifiedWorktreeIDs.count == clone.worktrees.count,
                  primaryWorktrees.count == 1,
                  primaryWorktrees[0].path == clone.sourceSnapshot.path,
                  primaryWorktrees[0].rootIdentity == clone.rootIdentity,
                  clone.worktrees.allSatisfy({
                      $0.cloneID == clone.id
                  }),
                  clone.branches.allSatisfy({
                      $0.cloneID == clone.id
                          && Set($0.claimingWorktreeIDs)
                            .isSubset(of: worktreeIDs)
                  }),
                  clone.worktrees.compactMap(\.attachedBranchRef)
                    .allSatisfy({ reference in
                        clone.branches.contains {
                            $0.fullRef == reference
                        }
                    }) else {
                return false
            }
            let worktrees = try clone.worktrees.map {
                try Worktree(
                    id: $0.id,
                    cloneID: $0.cloneID,
                    path: $0.path,
                    rootIdentity: $0.rootIdentity,
                    registrationIdentity: $0.registrationIdentity,
                    attachedBranchRef: $0.attachedBranchRef,
                    detachedOID: $0.detachedOID,
                    isPrimary: $0.isPrimary,
                    isLocked: $0.isLocked,
                    locationKind: $0.locationKind,
                    verification: $0.verification,
                    cleanliness: $0.cleanliness,
                    fileState: $0.fileState,
                    contentEvidenceDigest:
                        $0.contentEvidenceDigest,
                    relationToDefault:
                        $0.relationToDefault,
                    tipCommitDate: $0.tipCommitDate,
                    awaEvidence: $0.awaEvidence,
                    purpose: $0.purpose,
                    activity: $0.activity,
                    currentSession:
                        $0.currentSession,
                    removalPreview: $0.removalPreview,
                    warning: $0.warning
                )
            }
            let branches = try clone.branches.map {
                try Branch(
                    cloneID: $0.cloneID,
                    fullRef: $0.fullRef,
                    tipOID: $0.tipOID,
                    claimingWorktreeIDs: $0.claimingWorktreeIDs,
                    relationToDefault: $0.relationToDefault,
                    upstream: $0.upstream,
                    commitDate: $0.commitDate,
                    pullRequests: $0.pullRequests,
                    pullRequestAvailability:
                        $0.pullRequestAvailability,
                    purpose: $0.purpose,
                    activity: $0.activity,
                    removalPreview: $0.removalPreview
                )
            }
            let rebuiltClone = try LocalClone(
                repositoryID: clone.repositoryID,
                sourceSnapshot: clone.sourceSnapshot,
                effectiveOrigin: clone.effectiveOrigin,
                originParityVerified: clone.originParityVerified,
                policyCategory: clone.policyCategory,
                kind: clone.kind,
                worktrees: worktrees,
                branches: branches,
                warnings: clone.warnings
            )
            guard rebuiltClone == clone else {
                return false
            }
            let rebuiltTarget = try DefaultBranchUpdateTarget(
                repository: repository,
                canonicalClone: rebuiltClone,
                resolvedDefault: remoteDefault,
                expectedLocalOID: target.expectedLocalOID,
                expectedFetchedOID: target.expectedFetchedOID,
                operationHookSHA256:
                    target.operationHookSHA256,
                registrationSetSHA256:
                    target.registrationSetSHA256,
                preservationSHA256:
                    target.preservationSHA256,
                mode: target.mode,
                worktreeID: target.worktreeID,
                relation: target.relation
            )
            guard rebuiltTarget == target else {
                return false
            }
            if kind == .fastForward {
                return PlannedOperation(
                    unverifiedTarget: rebuiltTarget,
                    status: status,
                    refusalReason: refusalReason
                ) == self
            }
            guard let maintenanceEvidence,
                  let rebuilt = try? PlannedOperation(
                      unverifiedKind: kind,
                      target: rebuiltTarget,
                      maintenanceEvidence: maintenanceEvidence,
                      status: status,
                      refusalReason: refusalReason
                  ) else {
                return false
            }
            return rebuilt == self
        } catch {
            return false
        }
    }

    private static func evidenceMatches(
        kind: PlannedOperationKind,
        target: DefaultBranchUpdateTarget,
        evidence: RepositoryMaintenanceEvidence
    ) -> Bool {
        switch (kind, evidence) {
        case (.repairPruneRegistrations, let .prune(items)):
            return target.mode == .metadataMaintenance
                && !items.isEmpty
                && Set(items.map(\.registrationID)).count
                    == items.count
                && items.allSatisfy {
                    $0.branchRef
                        != target.resolvedDefault.localRef
                }
        case (.repairMovedWorktree, let .repairMoved(item)):
            return target.mode == .metadataMaintenance
                && item.branchRef
                    != target.resolvedDefault.localRef
        case (.initializeDefaultBranch, .initializeDefault):
            return target.mode == .initializeAbsent
                && target.expectedLocalOID == nil
        default:
            return false
        }
    }
}

public struct RepositoryCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repository: RemoteRepository
    public let authority: CanonicalAuthorityState
    public let clones: [LocalClone]
    public let relation: DefaultBranchRelation
    public let fastForward: PlannedOperation?
    public let fastForwardRefusal: String?
    public let maintenanceOperations: [PlannedOperation]
    public let maintenanceRefusals: [String]
    public let maintenanceDiagnostics: [String]?
    public let originHeadExplanation: String?

    public init(
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
        capability: VerifiedRepositoryAuthorityCapability
    ) throws {
        guard capability.admits(
            repository: repository,
            clones: clones
        ),
        fastForward.map(capability.admits) ?? true,
        maintenanceOperations.allSatisfy(capability.admits) else {
            throw GitSafetyError.unsafeRepository(
                "repository card lacks verified selected authority"
            )
        }
        try self.init(
            unverifiedRepository: repository,
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
    }

    #if SHADOW_SYNC_TESTING
    public init(
        repository: RemoteRepository,
        authority: CanonicalAuthorityState,
        clones: [LocalClone],
        relation: DefaultBranchRelation,
        fastForward: PlannedOperation?,
        fastForwardRefusal: String?,
        maintenanceOperations: [PlannedOperation] = [],
        maintenanceRefusals: [String] = [],
        maintenanceDiagnostics: [String]? = nil,
        originHeadExplanation: String? = nil
    ) throws {
        try self.init(
            unverifiedRepository: repository,
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
    }
    #endif

    private init(
        unverifiedRepository repository: RemoteRepository,
        authority: CanonicalAuthorityState,
        clones: [LocalClone],
        relation: DefaultBranchRelation,
        fastForward: PlannedOperation?,
        fastForwardRefusal: String?,
        maintenanceOperations: [PlannedOperation],
        maintenanceRefusals: [String],
        maintenanceDiagnostics: [String]?,
        originHeadExplanation: String?
    ) throws {
        guard !clones.isEmpty,
              clones.allSatisfy({ $0.repositoryID == repository.id }),
              fastForward == nil
                || fastForward?.target.repository.id == repository.id,
              maintenanceOperations.allSatisfy({
                  $0.target.repository.id == repository.id
                      && $0.kind != .fastForward
              }),
              Set(maintenanceOperations.map(\.id)).count
                == maintenanceOperations.count else {
            throw GitSafetyError.unsafeRepository(
                "repository card aggregate is invalid"
            )
        }
        id = repository.id
        self.repository = repository
        self.authority = authority
        self.clones = clones.sorted {
            $0.primaryRoot.localizedStandardCompare($1.primaryRoot)
                == .orderedAscending
        }
        self.relation = relation
        self.fastForward = fastForward
        self.fastForwardRefusal = fastForwardRefusal.map(Redactor.sanitize)
        self.maintenanceOperations = maintenanceOperations.sorted {
            $0.id.localizedStandardCompare($1.id)
                == .orderedAscending
        }
        self.maintenanceRefusals =
            maintenanceRefusals.map(Redactor.sanitize)
        self.maintenanceDiagnostics =
            maintenanceDiagnostics?.map(
                Redactor.sanitize
            )
        self.originHeadExplanation =
            originHeadExplanation.map(Redactor.sanitize)
    }

    public var isWritable: Bool {
        repository.policyCategory == .writable
    }

    public var isProtected: Bool {
        repository.policyCategory == .repositoryOwnedWorkflow
            || repository.policyCategory == .permanentNoTouch
    }

    public var isReference: Bool {
        repository.policyCategory == .reference
    }

    public var isOperationReady: Bool {
        fastForward?.isSelectable == true
            || maintenanceOperations.contains(where: \.isSelectable)
    }

    public func replacingClones(
        _ clones: [LocalClone],
        capability: VerifiedRepositoryAuthorityCapability
    ) throws -> RepositoryCard {
        try RepositoryCard(
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
}

public struct CanonicalAuthorityProposal:
    Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repositoryID: String
    public let canonicalRoot: String
    public let cloneEvidenceDigest: String

    public init(clone: LocalClone) {
        id = clone.repositoryID
        repositoryID = clone.repositoryID
        canonicalRoot = clone.primaryRoot
        cloneEvidenceDigest = clone.authorityEvidenceDigest
    }

    public func matches(_ clone: LocalClone) -> Bool {
        clone.isAuthorityEligible
            && clone.repositoryID == repositoryID
            && clone.primaryRoot == canonicalRoot
            && clone.authorityEvidenceDigest == cloneEvidenceDigest
    }
}

public struct RepositoryInventory: Codable, Equatable, Sendable {
    public let cards: [RepositoryCard]
    public let onboardingProposals: [CanonicalAuthorityProposal]
    public let authorityFileIdentity: FileIdentity?

    public init(
        cards: [RepositoryCard],
        onboardingProposals: [CanonicalAuthorityProposal],
        authorityFileIdentity: FileIdentity?
    ) {
        self.cards = cards.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        self.onboardingProposals = onboardingProposals.sorted {
            $0.repositoryID.localizedStandardCompare($1.repositoryID)
                == .orderedAscending
        }
        self.authorityFileIdentity = authorityFileIdentity
    }

    public var writableCards: [RepositoryCard] {
        cards.filter(\.isWritable)
    }

    public var protectedCards: [RepositoryCard] {
        cards.filter(\.isProtected)
    }

    public var referenceCards: [RepositoryCard] {
        cards.filter(\.isReference)
    }

    public var selectableOperations: [PlannedOperation] {
        cards.flatMap { card in
            ([card.fastForward].compactMap { $0 }
                + card.maintenanceOperations)
                .filter(\.isSelectable)
        }
    }

    public func operation(id: String) -> PlannedOperation? {
        selectableOperations.first { $0.id == id }
    }
}

public enum RepositoryInventorySelection {
    public static func selectAll(_ inventory: RepositoryInventory)
        -> [PlannedOperation] {
        inventory.selectableOperations
    }

    public static func admit(
        requests: [PlannedOperation],
        refreshed: RepositoryInventory
    ) -> [PlannedOperation]? {
        guard !requests.isEmpty,
              Set(requests.map(\.id)).count == requests.count else {
            return nil
        }
        let byID = Dictionary(
            uniqueKeysWithValues: refreshed.selectableOperations.map {
                ($0.id, $0)
            }
        )
        var admitted: [PlannedOperation] = []
        for request in requests {
            guard let operation = byID[request.id],
                  operation.evidenceDigest == request.evidenceDigest else {
                return nil
            }
            admitted.append(operation)
        }
        return admitted
    }
}

public enum LegacyRunPresentation {
    public static let label = "Legacy run — clone-based model"

    public static func isLegacy(_ report: RunReport) -> Bool {
        HistoricalLogIdentity.isV1Report(report.schema)
            && report.repositoryModel == nil
    }
}

public enum GitReferenceSyntax {
    public static func isValidBranchName(_ value: String) -> Bool {
        isValidLocalBranchRef("refs/heads/\(value)")
    }

    public static func isValidLocalBranchRef(_ value: String) -> Bool {
        let prefix = "refs/heads/"
        guard value.hasPrefix(prefix) else { return false }
        let branch = String(value.dropFirst(prefix.count))
        let forbidden = CharacterSet(charactersIn: #"~^:?*[\\"#)
        return !branch.isEmpty
            && branch != "@"
            && !branch.hasPrefix("-")
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

    public static func isValidRemoteTrackingRef(_ value: String) -> Bool {
        let prefix = "refs/remotes/"
        guard value.hasPrefix(prefix) else { return false }
        let remainder = String(value.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: "/") else {
            return false
        }
        let remote = String(remainder[..<separator])
        let branch = String(remainder[
            remainder.index(after: separator)...
        ])
        return !remote.isEmpty
            && !remote.hasPrefix("-")
            && remote.allSatisfy {
                $0.isLetter || $0.isNumber
                    || $0 == "-" || $0 == "_" || $0 == "."
            }
            && isValidBranchName(branch)
    }
}

enum V2EvidenceDigest {
    static func make(_ fields: [String]) -> String {
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) {
                data.append(contentsOf: $0)
            }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
