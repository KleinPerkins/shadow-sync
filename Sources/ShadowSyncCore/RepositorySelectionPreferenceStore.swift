import Darwin
import ShadowSyncCatalog
import Foundation

public enum RepositorySelectionPreferenceStatus:
    String, Equatable, Sendable {
    case absent
    case available
    case malformed
    case unsafe
    case unsupportedSchema
}

public struct RepositorySelectionPreferenceSnapshot:
    Equatable, Sendable {
    public let status: RepositorySelectionPreferenceStatus
    public let document: RepositorySelectionPreferenceDocument?
    public let fileIdentity: FileIdentity?
    public let explanation: String?

    public var expectedDocumentID: String? {
        document?.documentID
    }

    public var expectedRevision: UInt64? {
        document?.revision
    }
}

#if SHADOW_SYNC_TESTING
public extension RepositorySelectionPreferenceSnapshot {
    static var testingAbsent:
        RepositorySelectionPreferenceSnapshot {
        RepositorySelectionPreferenceSnapshot(
            status: .absent,
            document: nil,
            fileIdentity: nil,
            explanation: nil
        )
    }
}
#endif

public enum RepositorySelectionPreferenceSaveResult:
    Equatable, Sendable {
    case saved(
        RepositorySelectionPreferenceDocument,
        FileIdentity
    )
    case durabilityUncertain(
        RepositorySelectionPreferenceDocument,
        FileIdentity?
    )

    public var renameLinearized: Bool { true }
}

public enum RepositorySelectionPreferenceStoreError:
    Error, CustomStringConvertible, Equatable {
    case changed
    case malformed
    case unsafe
    case unsupportedSchema
    case revisionExhausted
    case recoverySlotOccupied
    case persistence(String)

    public var description: String {
        switch self {
        case .changed:
            return "saved defaults changed; reload before saving"
        case .malformed:
            return "saved defaults are malformed"
        case .unsafe:
            return "saved defaults have unsafe ownership, type, links, permissions, or size"
        case .unsupportedSchema:
            return "saved defaults use a newer unsupported schema"
        case .revisionExhausted:
            return "saved defaults reached their maximum revision"
        case .recoverySlotOccupied:
            return "the saved-defaults recovery slot already contains preserved bytes"
        case let .persistence(message):
            return Redactor.sanitize(message)
        }
    }
}

#if SHADOW_SYNC_TESTING
public enum RepositorySelectionPreferencePersistenceFault:
    Equatable, Sendable {
    case beforeRename
    case afterRenameBeforeDirectorySync
}
#endif

public final class RepositorySelectionPreferenceStore:
    @unchecked Sendable {
    public static let filename = "selection-preferences.json"
    public static let recoveryFilename =
        "selection-preferences.recovery"
    public static let maximumBytes = 1_048_576

    private let state: SecureStateDirectory
    #if SHADOW_SYNC_TESTING
    private let persistenceFault:
        RepositorySelectionPreferencePersistenceFault?
    #endif

    public init(state: SecureStateDirectory) {
        self.state = state
        #if SHADOW_SYNC_TESTING
        persistenceFault = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        state: SecureStateDirectory,
        persistenceFault:
            RepositorySelectionPreferencePersistenceFault
    ) {
        self.state = state
        self.persistenceFault = persistenceFault
    }
    #endif

    public static func open(at location: StateLocation)
        throws -> RepositorySelectionPreferenceStore {
        RepositorySelectionPreferenceStore(
            state: try SecureStateDirectory.open(location)
        )
    }

    public func snapshot() -> RepositorySelectionPreferenceSnapshot {
        var named = stat()
        guard fstatat(
            state.descriptor.value,
            Self.filename,
            &named,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return RepositorySelectionPreferenceSnapshot(
                status: errno == ENOENT ? .absent : .unsafe,
                document: nil,
                fileIdentity: nil,
                explanation: errno == ENOENT
                    ? nil : "Saved defaults could not be inspected."
            )
        }
        let identity = FileIdentity(named)
        guard identity.isRegular,
              named.st_uid == state.uid,
              named.st_nlink == 1,
              (named.st_mode & 0o777) == 0o600,
              named.st_size >= 0,
              named.st_size <= Self.maximumBytes else {
            return RepositorySelectionPreferenceSnapshot(
                status: .unsafe,
                document: nil,
                fileIdentity: identity,
                explanation:
                    "Saved defaults have unsafe ownership, type, links, permissions, or size."
            )
        }
        do {
            let bytes = try readCurrent(expected: identity)
            if let schema = try rawSchema(bytes),
               schema != shadowSyncSelectionPreferenceSchema {
                return RepositorySelectionPreferenceSnapshot(
                    status: .unsupportedSchema,
                    document: nil,
                    fileIdentity: identity,
                    explanation:
                        "Saved defaults were written by a newer version."
                )
            }
            let document = try JSONDecoder().decode(
                RepositorySelectionPreferenceDocument.self,
                from: bytes
            )
            return RepositorySelectionPreferenceSnapshot(
                status: .available,
                document: document,
                fileIdentity: identity,
                explanation: document.revision == UInt64.max
                    ? "Saved defaults are read-only because their revision is exhausted."
                    : nil
            )
        } catch {
            return RepositorySelectionPreferenceSnapshot(
                status: .malformed,
                document: nil,
                fileIdentity: identity,
                explanation:
                    "Saved defaults are malformed or changed while being read."
            )
        }
    }

    public func save(
        entries: [RepositorySelectionPreferenceEntry],
        expected: RepositorySelectionPreferenceSnapshot
    ) throws -> RepositorySelectionPreferenceSaveResult {
        guard expected.status == .absent
                || expected.status == .available else {
            throw error(for: expected.status)
        }
        let current = snapshot()
        try requireCAS(expected: expected, current: current)
        let document: RepositorySelectionPreferenceDocument
        if let prior = expected.document {
            guard prior.revision < UInt64.max else {
                throw RepositorySelectionPreferenceStoreError
                    .revisionExhausted
            }
            document = try RepositorySelectionPreferenceDocument(
                documentID: prior.documentID,
                revision: prior.revision + 1,
                entries: entries.sorted()
            )
        } else {
            document = try RepositorySelectionPreferenceDocument(
                documentID: UUID().uuidString.lowercased(),
                revision: 1,
                entries: entries.sorted()
            )
        }
        return try replace(
            document,
            expectedIdentity: expected.fileIdentity,
            expectedDocumentID: expected.expectedDocumentID,
            expectedRevision: expected.expectedRevision,
            allowMalformedExpected: false
        )
    }

    public func recover(
        entries: [RepositorySelectionPreferenceEntry],
        expected: RepositorySelectionPreferenceSnapshot
    ) throws -> RepositorySelectionPreferenceSaveResult {
        guard expected.status == .malformed,
              let identity = expected.fileIdentity else {
            throw RepositorySelectionPreferenceStoreError.changed
        }
        let bytes = try readCurrent(expected: identity)
        try preserveRecovery(bytes)
        let document = try RepositorySelectionPreferenceDocument(
            documentID: UUID().uuidString.lowercased(),
            revision: 1,
            entries: entries.sorted()
        )
        return try replace(
            document,
            expectedIdentity: identity,
            expectedDocumentID: nil,
            expectedRevision: nil,
            allowMalformedExpected: true
        )
    }

    private func requireCAS(
        expected: RepositorySelectionPreferenceSnapshot,
        current: RepositorySelectionPreferenceSnapshot
    ) throws {
        guard current.fileIdentity == expected.fileIdentity,
              current.status == expected.status,
              current.expectedDocumentID == expected.expectedDocumentID,
              current.expectedRevision == expected.expectedRevision else {
            throw RepositorySelectionPreferenceStoreError.changed
        }
    }

    private func replace(
        _ document: RepositorySelectionPreferenceDocument,
        expectedIdentity: FileIdentity?,
        expectedDocumentID: String?,
        expectedRevision: UInt64?,
        allowMalformedExpected: Bool
    ) throws -> RepositorySelectionPreferenceSaveResult {
        var bytes = try encoded(document)
        bytes.append(0x0A)
        let temporary =
            ".selection-preferences."
            + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(
            state.descriptor.value,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw persistence("open preference temporary file")
        }
        var temporaryExists = true
        defer {
            close(descriptor)
            if temporaryExists {
                _ = unlinkat(state.descriptor.value, temporary, 0)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw persistence("secure preference temporary file")
        }
        try writeAll(bytes, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw persistence("fsync preference temporary file")
        }

        let current = snapshot()
        if allowMalformedExpected {
            guard current.status == .malformed,
                  current.fileIdentity == expectedIdentity else {
                throw RepositorySelectionPreferenceStoreError.changed
            }
        } else {
            guard current.fileIdentity == expectedIdentity,
                  current.expectedDocumentID == expectedDocumentID,
                  current.expectedRevision == expectedRevision,
                  current.status == (
                    expectedIdentity == nil ? .absent : .available
                  ) else {
                throw RepositorySelectionPreferenceStoreError.changed
            }
        }

        #if SHADOW_SYNC_TESTING
        if persistenceFault == .beforeRename {
            throw persistence("injected pre-rename preference cut")
        }
        #endif
        if let expectedIdentity {
            guard renameatx_np(
                state.descriptor.value,
                temporary,
                state.descriptor.value,
                Self.filename,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw persistence("swap saved defaults")
            }
            var replaced = stat()
            guard fstatat(
                state.descriptor.value,
                temporary,
                &replaced,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  FileIdentity(replaced) == expectedIdentity else {
                _ = renameatx_np(
                    state.descriptor.value,
                    temporary,
                    state.descriptor.value,
                    Self.filename,
                    UInt32(RENAME_SWAP)
                )
                throw RepositorySelectionPreferenceStoreError.changed
            }
            guard unlinkat(
                state.descriptor.value,
                temporary,
                0
            ) == 0 else {
                throw persistence("remove replaced saved defaults")
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
                    throw RepositorySelectionPreferenceStoreError.changed
                }
                throw persistence("install saved defaults")
            }
            temporaryExists = false
        }

        #if SHADOW_SYNC_TESTING
        if persistenceFault == .afterRenameBeforeDirectorySync {
            let installed = snapshot()
            return .durabilityUncertain(
                document,
                installed.fileIdentity
            )
        }
        #endif
        let directorySynced = fsync(state.descriptor.value) == 0
        let installed = snapshot()
        let identity = installed.fileIdentity
        let matches = installed.status == .available
            && installed.document == document
        if directorySynced, matches, let identity {
            return .saved(document, identity)
        }
        return .durabilityUncertain(document, identity)
    }

    private func preserveRecovery(_ bytes: Data) throws {
        var existing = stat()
        guard fstatat(
            state.descriptor.value,
            Self.recoveryFilename,
            &existing,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw RepositorySelectionPreferenceStoreError
                .recoverySlotOccupied
        }
        let temporary =
            ".selection-preferences-recovery."
            + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(
            state.descriptor.value,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw persistence("open saved-defaults recovery file")
        }
        var exists = true
        defer {
            close(descriptor)
            if exists {
                _ = unlinkat(state.descriptor.value, temporary, 0)
            }
        }
        try writeAll(bytes, to: descriptor)
        guard fsync(descriptor) == 0,
              renameatx_np(
                  state.descriptor.value,
                  temporary,
                  state.descriptor.value,
                  Self.recoveryFilename,
                  UInt32(RENAME_EXCL)
              ) == 0 else {
            throw persistence("preserve saved-defaults recovery")
        }
        exists = false
        guard fsync(state.descriptor.value) == 0 else {
            throw persistence("fsync saved-defaults recovery")
        }
    }

    private func readCurrent(expected: FileIdentity) throws -> Data {
        let descriptor = try state.openRegularFile(
            named: Self.filename,
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              FileIdentity(opened) == expected else {
            throw RepositorySelectionPreferenceStoreError.changed
        }
        let bytes = try readBounded(descriptor)
        var final = stat()
        var named = stat()
        guard fstat(descriptor, &final) == 0,
              fstatat(
                  state.descriptor.value,
                  Self.filename,
                  &named,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              FileIdentity(final) == expected,
              FileIdentity(named) == expected else {
            throw RepositorySelectionPreferenceStoreError.changed
        }
        return bytes
    }

    private func readBounded(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= Self.maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else if count == 0, data.count <= Self.maximumBytes {
                return data
            } else {
                break
            }
        }
        throw RepositorySelectionPreferenceStoreError.malformed
    }

    private func encoded(
        _ document: RepositorySelectionPreferenceDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        let bytes = try encoder.encode(document)
        guard bytes.count <= Self.maximumBytes else {
            throw RepositorySelectionPreferenceStoreError.malformed
        }
        return bytes
    }

    private func rawSchema(_ bytes: Data) throws -> String? {
        guard let object = try JSONSerialization
            .jsonObject(with: bytes) as? [String: Any] else {
            return nil
        }
        return object["schema"] as? String
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw persistence("write saved defaults")
                }
                offset += count
            }
        }
    }

    private func error(
        for status: RepositorySelectionPreferenceStatus
    ) -> RepositorySelectionPreferenceStoreError {
        switch status {
        case .malformed:
            return .malformed
        case .unsafe:
            return .unsafe
        case .unsupportedSchema:
            return .unsupportedSchema
        case .absent, .available:
            return .changed
        }
    }

    private func persistence(
        _ operation: String
    ) -> RepositorySelectionPreferenceStoreError {
        .persistence(
            "\(operation) failed: \(String(cString: strerror(errno)))"
        )
    }
}
