import CryptoKit
import Darwin
import Foundation

enum PolicyAuthorityFileError: Error, CustomStringConvertible {
    case unavailable
    var description: String { "Repository policy configuration is unavailable." }
}

/// A bounded snapshot of configuration, not permission to inspect a repository.
/// The caller supplies only its fixed configuration locator or verified binding.
struct PolicyAuthorityFile: Equatable, Sendable {
    private static let absentACLSHA256 = hex(SHA256.hash(data: Data()))

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    let bytes: Data
    let sha256: String
    private let path: String
    private let owner: uid_t
    private let maximumBytes: Int
    private let allowRootOwner: Bool
    private let identity: Node
    private let ancestors: [DirectoryNode]

    /// The mode belongs to the captured no-follow file, not a later pathname
    /// observation. Revalidation still binds its bytes, identity and ancestors.
    var hasOwnerPrivateMode: Bool { identity.directory.mode & 0o077 == 0 }

    private struct DirectoryNode: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let owner: UInt32
        let group: UInt32
        let mode: UInt16
        let aclSHA256: String

        init(_ value: stat, aclSHA256: String) {
            device = value.st_dev; inode = value.st_ino
            owner = value.st_uid; group = value.st_gid; mode = value.st_mode
            self.aclSHA256 = aclSHA256
        }
    }

    private struct Node: Codable, Equatable, Sendable {
        let directory: DirectoryNode
        let links: UInt16
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat, aclSHA256: String) {
            directory = DirectoryNode(value, aclSHA256: aclSHA256)
            links = value.st_nlink; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    /// A cross-process integrity commitment, never access authority. Bind the
    /// actual file and every traversed ancestor, including ACL observations.
    /// UTF-8 path bytes are encoded as Data so Unicode-equivalent spellings
    /// cannot collapse into a single name. Directory timestamps intentionally
    /// stay out: unrelated sibling creation must not revoke a stable parent.
    func identityCommitment() throws -> String {
        struct Binding: Encodable {
            let schema: String
            let path: Data
            let content: String
            let owner: UInt32
            let maximumBytes: Int
            let allowRootOwner: Bool
            let file: Node
            let ancestors: [DirectoryNode]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.hex(SHA256.hash(data: try encoder.encode(Binding(
            schema: "shadow-sync-policy-file-identity/v1", path: Data(path.utf8),
            content: sha256, owner: owner, maximumBytes: maximumBytes,
            allowRootOwner: allowRootOwner, file: identity, ancestors: ancestors))))
    }

    static func read(
        path: String, owner: uid_t, maximumBytes: Int,
        allowRootOwner: Bool = false
    ) throws -> Self {
        // POSIX separators are bytes, not extended grapheme clusters. Otherwise
        // slash + combining mark could reach openat as an unchecked intermediate path.
        let parts = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard path.utf8.first == 47, path.utf8.count <= 4096,
              (2...65).contains(parts.count), parts.first == "",
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(92),
              path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              (1...1_048_576).contains(maximumBytes) else {
            throw PolicyAuthorityFileError.unavailable
        }
        let names = Array(parts.dropFirst())
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var directories: [Int32] = []
        var ancestorNodes: [DirectoryNode] = []
        var payload: Int32 = -1
        defer {
            if payload >= 0 { close(payload) }
            for descriptor in directories.reversed() { close(descriptor) }
        }
        func appendDirectory(_ descriptor: Int32) throws {
            guard descriptor >= 0 else { throw PolicyAuthorityFileError.unavailable }
            directories.append(descriptor)
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == owner,
                  info.st_mode & 0o022 == 0
                    || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else {
                throw PolicyAuthorityFileError.unavailable
            }
            ancestorNodes.append(DirectoryNode(info,
                aclSHA256: try safeACL(descriptor)))
        }
        try appendDirectory(Darwin.open("/", flags | O_DIRECTORY))
        for name in names.dropLast() {
            try appendDirectory(openat(directories.last!, name, flags | O_DIRECTORY))
        }
        payload = openat(directories.last!, names.last!, flags)
        var before = stat()
        guard payload >= 0, fstat(payload, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == owner || (allowRootOwner && before.st_uid == 0),
              before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_size > 0, before.st_size <= maximumBytes else {
            throw PolicyAuthorityFileError.unavailable
        }
        let beforeNode = Node(before, aclSHA256: try safeACL(payload))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let amount = min(buffer.count, maximumBytes + 1 - data.count)
            let count = Darwin.read(payload, &buffer, amount)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PolicyAuthorityFileError.unavailable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard data.count == before.st_size, data.count <= maximumBytes,
              fstat(payload, &after) == 0,
              fstatat(directories.last!, names.last!, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PolicyAuthorityFileError.unavailable
        }
        let afterACL = try safeACL(payload)
        let afterNode = Node(after, aclSHA256: afterACL)
        guard beforeNode == afterNode,
              afterNode == Node(named, aclSHA256: afterACL) else {
            throw PolicyAuthorityFileError.unavailable
        }
        // Prove each retained directory is still named by its retained parent.
        // File-only checks cannot detect replacing a parent around the same inode.
        for index in directories.indices {
            var descriptorInfo = stat()
            let acl = try safeACL(directories[index])
            guard fstat(directories[index], &descriptorInfo) == 0,
                  DirectoryNode(descriptorInfo, aclSHA256: acl) == ancestorNodes[index] else {
                throw PolicyAuthorityFileError.unavailable
            }
            if index > 0 {
                var namedInfo = stat()
                guard fstatat(directories[index - 1], names[index - 1],
                              &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                      DirectoryNode(namedInfo, aclSHA256: acl) == ancestorNodes[index] else {
                    throw PolicyAuthorityFileError.unavailable
                }
            }
        }
        return Self(bytes: data, sha256: hex(SHA256.hash(data: data)), path: path, owner: owner, maximumBytes: maximumBytes,
        allowRootOwner: allowRootOwner, identity: afterNode, ancestors: ancestorNodes)
    }

    /// POSIX mode bits do not describe macOS ACL grants. Use the retained
    /// descriptor and permit only read/search allow entries; deny-only entries
    /// (including the normal home-directory delete denial) are harmless.
    /// Unknown metadata, rights or ACL retrieval failures refuse the snapshot.
    static func safeACL(_ descriptor: Int32) throws -> String {
        try checkedACL(descriptor, allowingReadGrants: true)
    }

    /// Private application state permits restrictive denies but no ACL grants.
    static func privateStateACL(_ descriptor: Int32) throws -> String {
        try checkedACL(descriptor, allowingReadGrants: false)
    }

    /// Retain the stat already filled by the ACL security query. This is a
    /// fresh observation, not a cache; callers still check names and the full
    /// batch postflight after every payload has been read.
    private static func safeACLObservation(_ descriptor: Int32) throws -> (info: stat, acl: String) {
        var info = stat()
        let acl = try checkedACL(descriptor, allowingReadGrants: true, observedStat: &info)
        return (info, acl)
    }

    /// The named reader checks its original budget inside ancestor ACL traversal.
    /// Existing descriptor APIs retain the no-op default and identical policy.
    static func socketObservationDirectoryACL(_ descriptor: Int32, privateState: Bool,
                                               deadline: MonotonicDeadline) throws -> String {
        try checkedACL(descriptor, allowingReadGrants: !privateState) {
            if deadline.hasExpired { throw CustodyRecordError.busy }
        }
    }

    private static func checkedACL(_ descriptor: Int32, allowingReadGrants: Bool,
                                   observedStat: UnsafeMutablePointer<stat>? = nil,
                                   checkBudget: () throws -> Void = {}) throws -> String {
        try checkBudget()
        // acl_get_fd_np returns nil/ENOENT for an absent ACL as well as other
        // failures. Prove absence from a successful descriptor security read
        // instead of interpreting an errno as permission to continue.
        guard let security = filesec_init() else {
            throw PolicyAuthorityFileError.unavailable
        }
        defer { filesec_free(security) }
        var info = stat()
        guard fstatx_np(descriptor, &info, security) == 0 else {
            throw PolicyAuthorityFileError.unavailable
        }
        let acl = try checkedSecurityACL(security, allowingReadGrants: allowingReadGrants, checkBudget: checkBudget)
        observedStat?.pointee = info
        return acl
    }

    /// Named strict-getter callers validate native bytes and own this ACL.
    /// Descriptor callers retain their original filesec absence interpretation.
    static func privateStateObservedACL(_ acl: acl_t, deadline: MonotonicDeadline) throws -> String {
        try checkedDecodedACL(acl, allowingReadGrants: false) {
            if deadline.hasExpired { throw CustodyRecordError.busy }
        }
    }

    private static func checkedSecurityACL(_ security: filesec_t, allowingReadGrants: Bool,
                                           checkBudget: () throws -> Void = {}) throws -> String {
        try checkBudget()
        var present: Int32 = 0
        guard filesec_query_property(security, FILESEC_ACL, &present) == 0 else {
            throw PolicyAuthorityFileError.unavailable
        }
        try checkBudget()
        if present == 0 {
            return absentACLSHA256
        }
        var value: acl_t?
        guard present > 0, filesec_get_property(security, FILESEC_ACL, &value) == 0,
              let acl = value else { throw PolicyAuthorityFileError.unavailable }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return try checkedDecodedACL(acl, allowingReadGrants: allowingReadGrants, checkBudget: checkBudget)
    }

    private static func checkedDecodedACL(_ acl: acl_t, allowingReadGrants: Bool,
                                          checkBudget: () throws -> Void) throws -> String {
        guard acl_valid(acl) == 0 else { throw PolicyAuthorityFileError.unavailable }
        let readOnly = [ACL_READ_DATA, ACL_EXECUTE, ACL_READ_ATTRIBUTES,
                        ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_SYNCHRONIZE]
            .reduce(UInt64(0)) { $0 | UInt64($1.rawValue) }
        var ended = false
        for index in 0..<1024 {
            try checkBudget()
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, Int32(index), &entry)
            if result == -1 && errno == EINVAL { ended = true; break }
            guard result == 0, let entry else { throw PolicyAuthorityFileError.unavailable }
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset_mask_np(entry, &permissions) == 0,
                  tag == ACL_EXTENDED_DENY
                    || (allowingReadGrants && tag == ACL_EXTENDED_ALLOW && permissions & ~readOnly == 0) else {
                throw PolicyAuthorityFileError.unavailable
            }
        }
        try checkBudget()
        let size = acl_size(acl)
        guard ended, (1...65_536).contains(size) else {
            throw PolicyAuthorityFileError.unavailable
        }
        var serialized = Data(count: size)
        let copied = serialized.withUnsafeMutableBytes {
            acl_copy_ext($0.baseAddress, acl, size)
        }
        guard copied == size else { throw PolicyAuthorityFileError.unavailable }
        try checkBudget()
        return hex(SHA256.hash(data: serialized))
    }

    func revalidate() throws {
        try Self.revalidate([self])
    }

    /// One fresh read transaction, never a cache or a grant to inspect a target.
    /// Share only ancestors opened by this call; reread every payload and prove
    /// all retained file/name/ancestor bindings again before returning success.
    static func revalidate(_ files: [Self]) throws {
        try Revalidation().run(files)
    }

    #if SHADOW_SYNC_TESTING
    /// Synchronous fixture fault cut; absent from production and never global.
    static func testingRevalidate(_ files: [Self], afterRead: @escaping (Int) throws -> Void) throws {
        let operation = Revalidation()
        operation.afterRead = afterRead
        try operation.run(files)
    }
    #endif

    private final class Revalidation {
        #if SHADOW_SYNC_TESTING
        var afterRead: ((Int) throws -> Void)?
        #endif

        func run(_ files: [PolicyAuthorityFile]) throws {
            guard (1...64).contains(files.count) else { throw PolicyAuthorityFileError.unavailable }
            struct Directory {
                let descriptor: Int32, parent: Int32?
                let name: String
                let identity: DirectoryNode
            }
            struct Payload {
                let descriptor: Int32, parent: Int32
                let name: String
                let identity: Node
            }
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            var descriptors: [Int32] = [], directories: [Directory] = [], payloads: [Payload] = []
            var directoryIndex: [Data: Int] = [:]
            defer { for descriptor in descriptors.reversed() { close(descriptor) } }
            func directory(key: Data, name: String, parent: Int32?, expected: DirectoryNode) throws -> Int32 {
                if let index = directoryIndex[key] {
                    guard directories[index].identity == expected else { throw PolicyAuthorityFileError.unavailable }
                    return directories[index].descriptor
                }
                guard directories.count < 4096 else { throw PolicyAuthorityFileError.unavailable }
                let descriptor = parent.map { openat($0, name, flags | O_DIRECTORY) }
                    ?? Darwin.open("/", flags | O_DIRECTORY)
                guard descriptor >= 0 else { throw PolicyAuthorityFileError.unavailable }
                descriptors.append(descriptor)
                let observed = try PolicyAuthorityFile.safeACLObservation(descriptor)
                guard DirectoryNode(observed.info, aclSHA256: observed.acl) == expected else {
                    throw PolicyAuthorityFileError.unavailable
                }
                directoryIndex[key] = directories.count
                directories.append(Directory(descriptor: descriptor, parent: parent, name: name, identity: expected))
                return descriptor
            }
            for (fileIndex, file) in files.enumerated() {
                // Captured locators already passed the closed byte grammar in read.
                // Data keys preserve exact UTF-8 instead of Unicode equivalence.
                let names = file.path.utf8.split(separator: 47, omittingEmptySubsequences: false)
                    .dropFirst().map { String(decoding: $0, as: UTF8.self) }
                guard names.count == file.ancestors.count, let leaf = names.last else {
                    throw PolicyAuthorityFileError.unavailable
                }
                var key = Data([47])
                var parent = try directory(key: key, name: "", parent: nil, expected: file.ancestors[0])
                for (index, name) in names.dropLast().enumerated() {
                    key.append(contentsOf: name.utf8); key.append(47)
                    parent = try directory(key: key, name: name, parent: parent, expected: file.ancestors[index + 1])
                }
                let descriptor = openat(parent, leaf, flags)
                guard descriptor >= 0 else { throw PolicyAuthorityFileError.unavailable }
                descriptors.append(descriptor)
                let before = try PolicyAuthorityFile.safeACLObservation(descriptor)
                guard Node(before.info, aclSHA256: before.acl) == file.identity else {
                    throw PolicyAuthorityFileError.unavailable
                }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
                while bytes.count <= file.maximumBytes {
                    let amount = min(buffer.count, file.maximumBytes + 1 - bytes.count)
                    let count = Darwin.read(descriptor, &buffer, amount)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw PolicyAuthorityFileError.unavailable }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                // Exact bytes imply the captured digest; do not recompute a digest
                // or construct a second snapshot just to compare identical bytes.
                guard bytes == file.bytes else { throw PolicyAuthorityFileError.unavailable }
                payloads.append(Payload(descriptor: descriptor, parent: parent, name: leaf, identity: file.identity))
                #if SHADOW_SYNC_TESTING
                try afterRead?(fileIndex)
                #endif
            }
            // Span the entire batch, including files read before a later sibling.
            for payload in payloads {
                var named = stat()
                let opened = try PolicyAuthorityFile.safeACLObservation(payload.descriptor)
                guard fstatat(payload.parent, payload.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      Node(opened.info, aclSHA256: opened.acl) == payload.identity,
                      Node(named, aclSHA256: opened.acl) == payload.identity else { throw PolicyAuthorityFileError.unavailable }
            }
            for directory in directories {
                var named = stat()
                let opened = try PolicyAuthorityFile.safeACLObservation(directory.descriptor)
                guard DirectoryNode(opened.info, aclSHA256: opened.acl) == directory.identity else {
                    throw PolicyAuthorityFileError.unavailable
                }
                if let parent = directory.parent {
                    guard fstatat(parent, directory.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          DirectoryNode(named, aclSHA256: opened.acl) == directory.identity else {
                        throw PolicyAuthorityFileError.unavailable
                    }
                }
            }
        }
    }
}
