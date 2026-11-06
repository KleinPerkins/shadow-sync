import Darwin
import ShadowSyncCatalog
import Foundation

public enum RepositoryAuthorityStoreStatus:
    Codable, Equatable, Sendable {
    case absent
    case available
    case unusable
}

public struct RepositoryAuthoritySnapshot: Codable, Equatable, Sendable {
    public let status: RepositoryAuthorityStoreStatus
    public let document: RepositoryAuthorityDocument?
    public let fileIdentity: FileIdentity?
    public let explanation: String?

    public init(
        status: RepositoryAuthorityStoreStatus,
        document: RepositoryAuthorityDocument?,
        fileIdentity: FileIdentity?,
        explanation: String?
    ) {
        self.status = status
        self.document = document
        self.fileIdentity = fileIdentity
        self.explanation = explanation.map(Redactor.sanitize)
    }

    public var usableRecords: [RepositoryAuthorityRecord] {
        status == .available ? document?.records ?? [] : []
    }
}

public enum RepositoryAuthorityCommitResult: Equatable, Sendable {
    case noChange
    case committed(RepositoryAuthorityDocument)

    public var didPersistChange: Bool {
        if case .committed = self {
            return true
        }
        return false
    }
}

public enum RepositoryAuthorityStoreError:
    Error, CustomStringConvertible, Equatable {
    case changed
    case invalidSelection
    case reconfirmationRequired(String)
    case unsafeFile
    case malformedFile

    public var description: String {
        switch self {
        case .changed:
            return "repository authority evidence changed before confirmation"
        case .invalidSelection:
            return "canonical-root selection is no longer valid"
        case let .reconfirmationRequired(repositoryID):
            return "Canonical root needs reconfirmation for \(repositoryID)."
        case .unsafeFile:
            return "repository authority file is unsafe"
        case .malformedFile:
            return "repository authority file is malformed"
        }
    }
}

public final class RepositoryAuthorityStore: @unchecked Sendable {
    public static let filename = "repository-authorities.json"
    private static let maximumBytes = 1_048_576
    private let state: SecureStateDirectory

    public init(state: SecureStateDirectory) {
        self.state = state
    }

    public static func open(at location: StateLocation)
        throws -> RepositoryAuthorityStore {
        RepositoryAuthorityStore(
            state: try SecureStateDirectory.open(location)
        )
    }

    public func snapshot() -> RepositoryAuthoritySnapshot {
        var pathInfo = stat()
        guard fstatat(
            state.descriptor.value,
            Self.filename,
            &pathInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return RepositoryAuthoritySnapshot(
                    status: .absent,
                    document: nil,
                    fileIdentity: nil,
                    explanation: nil
                )
            }
            return RepositoryAuthoritySnapshot(
                status: .unusable,
                document: nil,
                fileIdentity: nil,
                explanation: "The canonical-root record could not be inspected."
            )
        }
        let observed = FileIdentity(pathInfo)
        guard observed.isRegular,
              pathInfo.st_uid == state.uid,
              pathInfo.st_nlink == 1,
              (pathInfo.st_mode & 0o777) == 0o600,
              pathInfo.st_size >= 0,
              pathInfo.st_size <= Self.maximumBytes else {
            return RepositoryAuthoritySnapshot(
                status: .unusable,
                document: nil,
                fileIdentity: observed,
                explanation:
                    "The canonical-root record has unsafe ownership, type, links, permissions, or size."
            )
        }
        do {
            let descriptor = try state.openRegularFile(
                named: Self.filename,
                flags: O_RDONLY,
                create: false,
                repairPermissions: false
            )
            defer { close(descriptor) }
            var openedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0,
                  Self.sameSnapshot(pathInfo, openedInfo) else {
                throw RepositoryAuthorityStoreError.changed
            }
            let data = try Self.readBounded(
                descriptor,
                maximumBytes: Self.maximumBytes
            )
            var finalInfo = stat()
            var namedInfo = stat()
            guard fstat(descriptor, &finalInfo) == 0,
                  fstatat(
                      state.descriptor.value,
                      Self.filename,
                      &namedInfo,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  Self.sameSnapshot(pathInfo, finalInfo),
                  Self.sameSnapshot(pathInfo, namedInfo) else {
                throw RepositoryAuthorityStoreError.changed
            }
            guard try Self.rawDocumentIsSupported(data) else {
                throw RepositoryAuthorityStoreError.malformedFile
            }
            let document = try JSONDecoder().decode(
                RepositoryAuthorityDocument.self,
                from: data
            )
            return RepositoryAuthoritySnapshot(
                status: .available,
                document: document,
                fileIdentity: observed,
                explanation: nil
            )
        } catch {
            return RepositoryAuthoritySnapshot(
                status: .unusable,
                document: nil,
                fileIdentity: observed,
                explanation:
                    "The canonical-root record is malformed or changed while it was read."
            )
        }
    }

    private static func sameSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }

    private static func rawDocumentIsSupported(
        _ data: Data
    ) throws -> Bool {
        guard let object =
                try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
              Set(object.keys)
                == Set(["schema", "revision", "records"]),
              object["schema"] as? String
                == shadowSyncRepositoryAuthoritySchema,
              let revision = object["revision"] as? NSNumber,
              CFGetTypeID(revision)
                != CFBooleanGetTypeID(),
              revision.int64Value >= 0,
              let records =
                object["records"] as? [[String: Any]] else {
            return false
        }
        let recordKeys = Set([
            "repositoryID", "canonicalRoot",
            "rootIdentity", "commonDirectoryIdentity",
            "updatedAt",
        ])
        let identityKeys = Set(["device", "inode"])
        return records.allSatisfy { record in
            guard Set(record.keys) == recordKeys,
                  let root =
                    record["rootIdentity"] as? [String: Any],
                  let common =
                    record["commonDirectoryIdentity"]
                        as? [String: Any],
                  Set(root.keys) == identityKeys,
                  Set(common.keys) == identityKeys else {
                return false
            }
            return [root, common].allSatisfy {
                identity in
                identity.values.allSatisfy {
                    guard let number = $0 as? NSNumber else {
                        return false
                    }
                    return CFGetTypeID(number)
                        != CFBooleanGetTypeID()
                        && number.int64Value >= 0
                }
            }
        }
    }

    public func confirmOnboarding(
        proposals: [CanonicalAuthorityProposal],
        selectedRepositoryIDs: Set<String>,
        freshClones: [LocalClone],
        expectedFileIdentity: FileIdentity?
    ) throws -> RepositoryAuthorityCommitResult {
        guard !selectedRepositoryIDs.isEmpty else {
            return .noChange
        }
        guard Set(proposals.map(\.repositoryID)).count
                == proposals.count else {
            throw RepositoryAuthorityStoreError.invalidSelection
        }
        let proposalByID = Dictionary(
            uniqueKeysWithValues: proposals.map { ($0.repositoryID, $0) }
        )
        guard selectedRepositoryIDs.isSubset(
            of: Set(proposalByID.keys)
        ) else {
            throw RepositoryAuthorityStoreError.invalidSelection
        }
        let writableByRepository = Dictionary(
            grouping: freshClones.filter(\.isAuthorityEligible),
            by: \.repositoryID
        )
        var selectedRecords: [RepositoryAuthorityRecord] = []
        for repositoryID in selectedRepositoryIDs.sorted() {
            guard let proposal = proposalByID[repositoryID],
                  let matches = writableByRepository[repositoryID],
                  matches.count == 1,
                  let clone = matches.first,
                  proposal.matches(clone),
                  (try? Self.revalidate(clone)) != nil else {
                throw RepositoryAuthorityStoreError.invalidSelection
            }
            selectedRecords.append(
                RepositoryAuthorityRecord(clone: clone)
            )
        }
        let current = snapshot()
        try requireExpectedIdentity(
            expectedFileIdentity,
            current: current
        )
        var records = current.status == .available
            ? current.usableRecords.filter {
                !selectedRepositoryIDs.contains($0.repositoryID)
            }
            : []
        records.append(contentsOf: selectedRecords)
        let revision = (current.document?.revision ?? 0) + 1
        let document = try RepositoryAuthorityDocument(
            revision: revision,
            records: records
        )
        try replace(
            document,
            expectedFileIdentity: expectedFileIdentity
        )
        return .committed(document)
    }

    public func confirmCanonicalRoot(
        clone: LocalClone,
        freshClones: [LocalClone],
        expectedFileIdentity: FileIdentity?
    ) throws -> RepositoryAuthorityCommitResult {
        let matches = freshClones.filter {
            $0.authorityEvidenceDigest == clone.authorityEvidenceDigest
        }
        guard clone.isAuthorityEligible,
              matches.count == 1,
              (try? Self.revalidate(clone)) != nil else {
            throw RepositoryAuthorityStoreError.invalidSelection
        }
        let current = snapshot()
        try requireExpectedIdentity(
            expectedFileIdentity,
            current: current
        )
        guard current.status != .unusable else {
            throw RepositoryAuthorityStoreError.malformedFile
        }
        var records = current.document?.records.filter {
            $0.repositoryID != clone.repositoryID
        } ?? []
        records.append(RepositoryAuthorityRecord(clone: clone))
        let document = try RepositoryAuthorityDocument(
            revision: (current.document?.revision ?? 0) + 1,
            records: records
        )
        try replace(
            document,
            expectedFileIdentity: expectedFileIdentity
        )
        return .committed(document)
    }

    public func confirmCatalogCanonicalRoot(
        repositoryID: String,
        canonicalRoot: String,
        rootIdentity: RepositorySelectionCatalogIdentity,
        commonDirectoryIdentity:
            RepositorySelectionCatalogIdentity,
        rawOrigin: String,
        expectedFileIdentity: FileIdentity?
    ) throws -> RepositoryAuthorityCommitResult {
        guard GitHubIdentity.parse(rawOrigin)?.canonicalName
                == repositoryID else {
            throw RepositoryAuthorityStoreError.invalidSelection
        }
        var rootInfo = stat()
        var gitInfo = stat()
        guard lstat(canonicalRoot, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              UInt64(rootInfo.st_dev) == rootIdentity.device,
              UInt64(rootInfo.st_ino) == rootIdentity.inode,
              UInt32(rootInfo.st_uid) == rootIdentity.owner,
              lstat(canonicalRoot + "/.git", &gitInfo) == 0,
              (gitInfo.st_mode & S_IFMT) == S_IFDIR,
              gitInfo.st_uid == geteuid(),
              UInt64(gitInfo.st_dev)
                == commonDirectoryIdentity.device,
              UInt64(gitInfo.st_ino)
                == commonDirectoryIdentity.inode,
              UInt32(gitInfo.st_uid)
                == commonDirectoryIdentity.owner else {
            throw RepositoryAuthorityStoreError.invalidSelection
        }
        let current = snapshot()
        try requireExpectedIdentity(
            expectedFileIdentity,
            current: current
        )
        guard current.status != .unusable else {
            throw RepositoryAuthorityStoreError.malformedFile
        }
        var records = current.document?.records.filter {
            $0.repositoryID != repositoryID
        } ?? []
        records.append(
            RepositoryAuthorityRecord(
                repositoryID: repositoryID,
                canonicalRoot: canonicalRoot,
                rootIdentity: FileIdentity(rootInfo),
                commonDirectoryIdentity: FileIdentity(gitInfo)
            )
        )
        let document = try RepositoryAuthorityDocument(
            revision: (current.document?.revision ?? 0) + 1,
            records: records
        )
        try replace(
            document,
            expectedFileIdentity: expectedFileIdentity
        )
        return .committed(document)
    }

    public func refreshSelectedDeviceDrift(
        selectedRepositoryIDs: Set<String>,
        freshClones: [LocalClone],
        expectedFileIdentity: FileIdentity?
    ) throws -> RepositoryAuthoritySnapshot {
        let current = snapshot()
        try requireExpectedIdentity(
            expectedFileIdentity,
            current: current
        )
        guard current.status == .available,
              let currentDocument = current.document else {
            throw RepositoryAuthorityStoreError.malformedFile
        }
        let grouped = Dictionary(
            grouping: freshClones,
            by: \.repositoryID
        )
        var refreshedRecords = currentDocument.records
        var changed = false
        for repositoryID in selectedRepositoryIDs.sorted() {
            guard let record = current.usableRecords.first(where: {
                $0.repositoryID == repositoryID
            }),
            let clones = grouped[repositoryID] else {
                throw RepositoryAuthorityStoreError
                    .reconfirmationRequired(repositoryID)
            }
            if clones.filter(record.matches).count == 1 {
                continue
            }
            let deviceOnly = clones.filter {
                record.matchesExceptDevice($0)
            }
            guard deviceOnly.count == 1,
                  let clone = deviceOnly.first,
                  (try? Self.revalidate(clone)) != nil else {
                throw RepositoryAuthorityStoreError
                    .reconfirmationRequired(repositoryID)
            }
            var rootInfo = stat()
            var gitInfo = stat()
            guard lstat(record.canonicalRoot, &rootInfo) == 0,
                  (rootInfo.st_mode & S_IFMT) == S_IFDIR,
                  rootInfo.st_uid == geteuid(),
                  UInt64(rootInfo.st_ino)
                    == record.rootIdentity.inode,
                  lstat(
                      record.canonicalRoot + "/.git",
                      &gitInfo
                  ) == 0,
                  (gitInfo.st_mode & S_IFMT) == S_IFDIR,
                  gitInfo.st_uid == geteuid(),
                  UInt64(gitInfo.st_ino)
                    == record.commonDirectoryIdentity.inode else {
                throw RepositoryAuthorityStoreError
                    .reconfirmationRequired(repositoryID)
            }
            refreshedRecords.removeAll {
                $0.repositoryID == repositoryID
            }
            refreshedRecords.append(
                RepositoryAuthorityRecord(clone: clone)
            )
            changed = true
        }
        guard changed else { return current }
        let refreshed = try RepositoryAuthorityDocument(
            revision: currentDocument.revision + 1,
            records: refreshedRecords
        )
        try replace(
            refreshed,
            expectedFileIdentity: expectedFileIdentity
        )
        let installed = snapshot()
        guard installed.status == .available,
              installed.document == refreshed else {
            throw RepositoryAuthorityStoreError.changed
        }
        return installed
    }

    private func requireExpectedIdentity(
        _ expected: FileIdentity?,
        current: RepositoryAuthoritySnapshot
    ) throws {
        guard current.fileIdentity == expected,
              (expected != nil || current.status == .absent) else {
            throw RepositoryAuthorityStoreError.changed
        }
    }

    private static func revalidate(_ clone: LocalClone) throws {
        let handle = try RepositoryHandle.open(
            clone.sourceSnapshot
        )
        try handle.revalidate()
        guard handle.githubIdentity.canonicalName
                == clone.repositoryID,
              handle.rawOrigin == clone.rawOrigin,
              clone.rootIdentity
                == clone.sourceSnapshot.rootIdentity,
              clone.commonDirectoryIdentity
                == clone.sourceSnapshot.commonDirectoryIdentity else {
            throw RepositoryAuthorityStoreError.invalidSelection
        }
    }

    private func replace(
        _ document: RepositoryAuthorityDocument,
        expectedFileIdentity: FileIdentity?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(document)
        bytes.append(0x0A)
        guard bytes.count <= Self.maximumBytes else {
            throw RepositoryAuthorityStoreError.malformedFile
        }

        let temporary =
            ".repository-authorities.\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = openat(
            state.descriptor.value,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard temporaryDescriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open authority temporary file",
                errno
            )
        }
        var temporaryExists = true
        defer {
            close(temporaryDescriptor)
            if temporaryExists {
                _ = unlinkat(state.descriptor.value, temporary, 0)
            }
        }
        guard fchmod(temporaryDescriptor, 0o600) == 0 else {
            throw SecureStateError.systemCall(
                "fchmod authority temporary file",
                errno
            )
        }
        try Self.writeAll(bytes, to: temporaryDescriptor)
        guard fsync(temporaryDescriptor) == 0 else {
            throw SecureStateError.systemCall(
                "fsync authority temporary file",
                errno
            )
        }

        let current = snapshot()
        try requireExpectedIdentity(
            expectedFileIdentity,
            current: current
        )
        if let expectedFileIdentity {
            guard renameatx_np(
                state.descriptor.value,
                temporary,
                state.descriptor.value,
                Self.filename,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "swap repository authority file",
                    errno
                )
            }
            var replacedInfo = stat()
            guard fstatat(
                state.descriptor.value,
                temporary,
                &replacedInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  FileIdentity(replacedInfo) == expectedFileIdentity else {
                _ = renameatx_np(
                    state.descriptor.value,
                    temporary,
                    state.descriptor.value,
                    Self.filename,
                    UInt32(RENAME_SWAP)
                )
                throw RepositoryAuthorityStoreError.changed
            }
            guard unlinkat(state.descriptor.value, temporary, 0) == 0 else {
                throw SecureStateError.systemCall(
                    "unlink replaced authority file",
                    errno
                )
            }
            temporaryExists = false
        } else {
            guard renameatx_np(
                state.descriptor.value,
                temporary,
                state.descriptor.value,
                Self.filename,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == EEXIST {
                    throw RepositoryAuthorityStoreError.changed
                }
                throw SecureStateError.systemCall(
                    "install repository authority file",
                    errno
                )
            }
            temporaryExists = false
        }
        guard fsync(state.descriptor.value) == 0 else {
            throw SecureStateError.systemCall(
                "fsync repository authority directory",
                errno
            )
        }
        let installed = snapshot()
        guard installed.status == .available,
              installed.document == document else {
            throw RepositoryAuthorityStoreError.changed
        }
    }

    private static func readBounded(
        _ descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
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
            guard count == 0, data.count <= maximumBytes else {
                throw RepositoryAuthorityStoreError.malformedFile
            }
            return data
        }
        throw RepositoryAuthorityStoreError.malformedFile
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw SecureStateError.systemCall(
                        "write repository authority file",
                        count < 0 ? errno : EIO
                    )
                }
                offset += count
            }
        }
    }
}
