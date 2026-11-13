import Darwin
import Foundation

/// Fresh data only. Neither this value nor its reader grants creation, peer
/// admission, repair, retirement, or namespace authority (ADR 0009).
/// Readiness consumers use this observation under their original retained owners.
/// Other endpoint consumers and native qualification remain separate gates.
struct InstallationNamedSocketObservation: Equatable {
    enum Endpoint: String, CaseIterable {
        case installation = "installation.sock"
        case host = "host.sock"
    }

    /// Exact immutable UTF-8 address, with the actual sockaddr_un byte bound.
    /// Construction validates spelling only, never location or writer authority.
    struct Address {
        let bytes: Data
        func socketAddress() -> sockaddr_un {
            var result = sockaddr_un()
            result.sun_family = sa_family_t(AF_UNIX)
            result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &result.sun_path) { destination in
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                bytes.copyBytes(to: destination)
            }
            return result
        }
        let parentComponents: [String]
        let endpoint: Endpoint
        var path: String { String(decoding: bytes, as: UTF8.self) }
        init(canonicalParent: String, endpoint: Endpoint) throws {
            let parts = canonicalParent.utf8.split(separator: 47, omittingEmptySubsequences: false)
            guard parts.first?.isEmpty == true, (2...64).contains(parts.count),
                  parts.dropFirst().allSatisfy({ !$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46, 46]) }),
                  !canonicalParent.utf8.contains(0), !canonicalParent.utf8.contains(92),
                  canonicalParent.precomposedStringWithCanonicalMapping.utf8.elementsEqual(canonicalParent.utf8),
                  canonicalParent.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw CustodyRecordError.unsafeMetadata
            }
            let bytes = Data((canonicalParent + "/" + endpoint.rawValue).utf8)
            let address = sockaddr_un()
            guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw CustodyRecordError.unsafeMetadata
            }
            self.bytes = bytes; self.endpoint = endpoint
            parentComponents = parts.dropFirst().map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Full common stat fields. Timestamps are observations, not generation IDs.
    struct Metadata: Equatable {
        let device: Int32, inode: UInt64, uid: UInt32, gid: UInt32
        let mode: UInt16, links: UInt16, flags: UInt32, generation: UInt32
        let specialDevice: Int32, size: Int64, blocks: Int64, blockSize: Int32
        let accessedSeconds: Int, accessedNanoseconds: Int
        let modifiedSeconds: Int, modifiedNanoseconds: Int
        let changedSeconds: Int, changedNanoseconds: Int
        let createdSeconds: Int, createdNanoseconds: Int
        init(_ s: stat) {
            device = s.st_dev; inode = s.st_ino; uid = s.st_uid; gid = s.st_gid
            mode = s.st_mode; links = s.st_nlink; flags = s.st_flags; generation = s.st_gen
            specialDevice = s.st_rdev; size = s.st_size; blocks = s.st_blocks; blockSize = s.st_blksize
            accessedSeconds = s.st_atimespec.tv_sec; accessedNanoseconds = s.st_atimespec.tv_nsec
            modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanoseconds = s.st_mtimespec.tv_nsec
            changedSeconds = s.st_ctimespec.tv_sec; changedNanoseconds = s.st_ctimespec.tv_nsec
            createdSeconds = s.st_birthtimespec.tv_sec; createdNanoseconds = s.st_birthtimespec.tv_nsec
        }
        fileprivate func requireSocket(uid: uid_t, unpublished: Bool = false) throws {
            guard device > 0, inode > 0, self.uid == uid, mode & S_IFMT == S_IFSOCK,
                  unpublished ? mode & 0o7000 == 0 : mode == S_IFSOCK | 0o600,
                  links == 1, flags == 0 else { throw CustodyRecordError.unsafeMetadata }
        }
    }
    struct Parent: Equatable {
        let device: Int32, inode: UInt64, uid: UInt32, gid: UInt32, mode: UInt16, flags: UInt32
        let acl: String
        init(_ s: stat, acl: String) {
            device = s.st_dev; inode = s.st_ino; uid = s.st_uid; gid = s.st_gid
            mode = s.st_mode; flags = s.st_flags; self.acl = acl
        }
        // Unrelated children may change link counts and directory timestamps.
        // Compare stable identity/security; require a live directory separately.
        func matches(_ s: stat) -> Bool {
            s.st_nlink > 0 && s.st_mode & S_IFMT == S_IFDIR
                && self == Parent(s, acl: acl)
        }
    }
    let addressBytes: Data
    let metadata: Metadata
    let aclSHA256: String
    var nodeIdentity: InstallationNodeIdentity {
        // Preserve the existing outer digest over the UTF-8 ACL digest string.
        InstallationNodeIdentity(device: UInt64(metadata.device), inode: metadata.inode, type: .socket,
            uid: metadata.uid, mode: UInt32(metadata.mode), links: UInt64(metadata.links),
            aclDigest: CustodyRecordBinding.digest(Data(aclSHA256.utf8)))
    }

    // Cross-observation generation comparison uses the durable slot's exact
    // identity/protection plus the additional stable native identity fields.
    // atime/mtime/ctime remain fully compared inside each read sandwich; they
    // are observations, not generation IDs (ADR 0009). Fixture restoration does
    // not reconstruct an owner or authorize an observer to change metadata.
    func matchesNamedGeneration(_ other: Self) -> Bool {
        let a = metadata, b = other.metadata
        return addressBytes == other.addressBytes && nodeIdentity == other.nodeIdentity
            && a.gid == b.gid && a.flags == b.flags && a.generation == b.generation
            && a.specialDevice == b.specialDevice && a.size == b.size
            && a.blocks == b.blocks && a.blockSize == b.blockSize
            && a.createdSeconds == b.createdSeconds && a.createdNanoseconds == b.createdNanoseconds
    }

    // Compare every captured field except the deliberate mode and chmod ctime
    // transition. This is causal creator postflight, never an observer repair.
    func sameUnpublishedGeneration(afterMode other: Self) -> Bool {
        let a = metadata, b = other.metadata
        return addressBytes == other.addressBytes && aclSHA256 == other.aclSHA256
            && a.device == b.device && a.inode == b.inode && a.uid == b.uid && a.gid == b.gid
            && b.mode == S_IFSOCK | 0o600 && a.links == b.links && a.flags == b.flags
            && a.generation == b.generation && a.specialDevice == b.specialDevice
            && a.size == b.size && a.blocks == b.blocks && a.blockSize == b.blockSize
            && a.accessedSeconds == b.accessedSeconds && a.accessedNanoseconds == b.accessedNanoseconds
            && a.modifiedSeconds == b.modifiedSeconds && a.modifiedNanoseconds == b.modifiedNanoseconds
            && a.createdSeconds == b.createdSeconds && a.createdNanoseconds == b.createdNanoseconds
            && (b.changedSeconds > a.changedSeconds || (b.changedSeconds == a.changedSeconds
                && b.changedNanoseconds >= a.changedNanoseconds))
    }

    /// Borrow the caller's actual retained chain: /, each exact component, P.
    /// No descriptors are opened, duplicated or closed here. Holding an object
    /// reference does not serialize another caller's retireChecked(). Integration
    /// must retain real owners and continuously exclude cooperating path/metadata
    /// writers AND local closes/callbacks; snapshots cannot establish exclusion,
    /// detect every ABA, or rehabilitate a lost owner. No boolean/token asserts it.
    /// `expected` is comparison data only, never an adopted creator capability.
    static func read(address: Address, retainedAncestors: [OwnedFileDescriptor], uid: uid_t,
                     deadline: MonotonicDeadline, expected: Self? = nil) throws -> Self {
        try readImpl(address: address, retainedAncestors: retainedAncestors, uid: uid,
                     deadline: deadline, expected: expected, unpublishedCreator: nil, afterFirstRead: nil)
    }

    // Only the actual pre-enrolled, bound, unpublished creator can enter this
    // initial-mode observation. This grants read permission only; strict ACL,
    // identity, single-link, flags, parent and deadline checks are unchanged.
    static func readUnpublishedCreator(_ creator: InstallationReadinessEndpoint,
                                      address: Address, retainedAncestors: [OwnedFileDescriptor],
                                      uid: uid_t, deadline: MonotonicDeadline) throws -> Self {
        try creator.validateUnpublishedObservation(address: address, ancestors: retainedAncestors)
        let observed = try readImpl(address: address, retainedAncestors: retainedAncestors, uid: uid,
            deadline: deadline, expected: nil, unpublishedCreator: creator, afterFirstRead: nil)
        try creator.validateUnpublishedObservation(address: address, ancestors: retainedAncestors)
        return observed
    }

    private static func readImpl(address: Address, retainedAncestors: [OwnedFileDescriptor], uid: uid_t,
                                 deadline: MonotonicDeadline, expected: Self?,
                                 unpublishedCreator: InstallationReadinessEndpoint?,
                                 afterFirstRead: (() throws -> Void)?) throws -> Self {
        func budget() throws { if deadline.hasExpired { throw CustodyRecordError.busy } }
        try budget()
        guard uid != 0, retainedAncestors.count == address.parentComponents.count + 1 else {
            throw CustodyRecordError.unsafeMetadata
        }
        // Retain the original objects for this entire synchronous observation.
        // Concurrent retirement is forbidden by the owning caller contract.
        let originals = retainedAncestors
        let fds = originals.map(\.value)
        guard fds.allSatisfy({ $0 >= 0 }), Set(fds).count == fds.count else {
            throw CustodyRecordError.unsafeMetadata
        }
        func parents() throws -> [Parent] {
            try Self.parents(address: address, retainedAncestors: originals, uid: uid, deadline: deadline)
        }
        let initialParents = try parents()
        func named() throws -> Self {
            try budget()
            var before = stat(), after = stat()
            guard fstatat(fds.last!, address.endpoint.rawValue, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw CustodyRecordError.unsafeMetadata
            }
            let metadata = Metadata(before); try metadata.requireSocket(uid: uid, unpublished: unpublishedCreator != nil)
            let reply = try strictReply(parent: fds.last!, endpoint: address.endpoint, deadline: deadline)
            let acl = try decodeStrictReply(reply.bytes, result: reply.result, metadata: metadata, deadline: deadline)
            try budget()
            guard fstatat(fds.last!, address.endpoint.rawValue, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata == Metadata(after) else {
                throw CustodyRecordError.conflict
            }
            return Self(addressBytes: address.bytes, metadata: metadata, aclSHA256: acl)
        }
        let first = try named()
        try afterFirstRead?()
        guard try parents() == initialParents else { throw CustodyRecordError.conflict }
        let second = try named()
        guard first == second, try parents() == initialParents,
              expected == nil || expected == second else { throw CustodyRecordError.conflict }
        if unpublishedCreator == nil { try second.nodeIdentity.validate() }; try budget()
        return second
    }

    static func parents(address: Address, retainedAncestors: [OwnedFileDescriptor], uid: uid_t,
                        deadline: MonotonicDeadline) throws -> [Parent] {
        func budget() throws { if deadline.hasExpired { throw CustodyRecordError.busy } }
        let originals = retainedAncestors, fds = retainedAncestors.map(\.value)
        guard uid != 0, originals.count == address.parentComponents.count + 1,
              fds.allSatisfy({ $0 >= 0 }), Set(fds).count == fds.count else { throw CustodyRecordError.unsafeMetadata }

        var result: [Parent] = []
        for index in fds.indices {
            try budget()
            guard originals[index].value == fds[index] else { throw CustodyRecordError.fenced }
            var held = stat(), named = stat(), after = stat()
            guard fstat(fds[index], &held) == 0, held.st_mode & S_IFMT == S_IFDIR,
                  held.st_nlink > 0, held.st_dev > 0, held.st_ino > 0,
                  held.st_uid == 0 || held.st_uid == uid,
                  held.st_mode & 0o022 == 0 || (held.st_uid == 0 && held.st_mode & S_ISVTX != 0) else {
                throw CustodyRecordError.unsafeMetadata
            }
            let last = index == fds.count - 1
            if last {
                guard held.st_uid == uid, held.st_mode == S_IFDIR | 0o700, held.st_flags == 0 else {
                    throw CustodyRecordError.unsafeMetadata
                }
            }
            let acl = try PolicyAuthorityFile.socketObservationDirectoryACL(fds[index], privateState: last, deadline: deadline)
            try budget()
            let item = Parent(held, acl: acl)
            let namedResult = index == 0 ? lstat("/", &named)
                : fstatat(fds[index - 1], address.parentComponents[index - 1], &named, AT_SYMLINK_NOFOLLOW)
            guard namedResult == 0, fstat(fds[index], &after) == 0,
                  item.matches(named), item.matches(after), originals[index].value == fds[index] else {
                throw CustodyRecordError.conflict
            }
            result.append(item)
        }
        try budget(); return result
    }

    // Closed 64-bit Darwin layout, four-byte packed, in documented attr order:
    // length4, dev4, type4, mtime16, ctime16, uid4, gid4, access4, flags4,
    // security-reference8, full-width fileid8, links4; then sole variable ACL.
    // attrreference is relative to its OWN offset60, never the buffer base.
    private static let strictFixedSize = 80
    private static let nativeHeaderSize = 44, nativeEntrySize = 24, maximumEntries = 128
    private static let strictCapacity = strictFixedSize + nativeHeaderSize + maximumEntries * nativeEntrySize

    private static func strictReply(parent: Int32, endpoint: Endpoint, deadline: MonotonicDeadline)
        throws -> (bytes: Data, result: Int32) {
        guard !deadline.hasExpired, MemoryLayout<Int>.size == 8 else { throw CustodyRecordError.busy }
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME
            | ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS
            | ATTR_CMN_EXTENDED_SECURITY | ATTR_CMN_FILEID)
        request.fileattr = UInt32(ATTR_FILE_LINKCOUNT)
        // No RETURNED_ATTRS, PACK_INVAL_ATTRS, volume, directory or fork request.
        // XNU restores requested active bits at vfs_attrlist.c:3459; strict
        // ALL_SUPPORTED failure returns EINVAL before success. Only complete
        // supported-null packing proves absence. Kernel-normalized backing
        // security is not inaccessible raw-storage integrity evidence.
        var bytes = Data(repeating: 0xa5, count: strictCapacity)
        let result = bytes.withUnsafeMutableBytes { storage in
            endpoint.rawValue.withCString {
                getattrlistat(parent, $0, &request, storage.baseAddress, storage.count,
                              UInt(FSOPT_NOFOLLOW | FSOPT_REPORT_FULLSIZE))
            }
        }
        // One bounded allocation/call, no size retry and no deadline restart.
        // This check cannot interrupt a blocking syscall.
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        return (bytes, result)
    }

    private static func decodeStrictReply(_ bytes: Data, result: Int32, metadata: Metadata,
                                          deadline: MonotonicDeadline) throws -> String {
        func budget() throws { if deadline.hasExpired { throw CustodyRecordError.busy } }
        try budget()
        guard result == 0, bytes.count >= strictFixedSize, bytes.count <= strictCapacity else {
            throw PolicyAuthorityFileError.unavailable
        }
        // Copy into aligned local integers; never unaligned typed loads or
        // pointer arithmetic on an unvalidated signed attrreference.
        func word<T: FixedWidthInteger>(_ offset: Int, _: T.Type) throws -> T {
            guard offset >= 0, offset <= bytes.count - MemoryLayout<T>.size else {
                throw PolicyAuthorityFileError.unavailable
            }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size)) }
            return value
        }
        let length = Int(try word(0, UInt32.self))
        guard length >= strictFixedSize, length <= bytes.count,
              try word(4, Int32.self) == metadata.device,
              try word(8, UInt32.self) == UInt32(VSOCK.rawValue),
              try word(12, Int64.self) == Int64(metadata.modifiedSeconds),
              try word(20, Int64.self) == Int64(metadata.modifiedNanoseconds),
              try word(28, Int64.self) == Int64(metadata.changedSeconds),
              try word(36, Int64.self) == Int64(metadata.changedNanoseconds),
              try word(44, UInt32.self) == metadata.uid,
              try word(48, UInt32.self) == metadata.gid,
              // ACCESSMASK documents only permissions; type has its own field.
              try word(52, UInt32.self) & ~UInt32(S_IFMT) == UInt32(metadata.mode & ~S_IFMT),
              try word(56, UInt32.self) == metadata.flags,
              try word(68, UInt64.self) == metadata.inode,
              try word(76, UInt32.self) == UInt32(metadata.links) else {
            throw CustodyRecordError.conflict
        }
        let offset = Int(try word(60, Int32.self))
        let count = Int(try word(64, UInt32.self))
        let (start, offsetOverflow) = 60.addingReportingOverflow(offset)
        let (end, endOverflow) = start.addingReportingOverflow(count)
        guard !offsetOverflow, !endOverflow, start == strictFixedSize, start % 4 == 0,
              end == length, end <= bytes.count else { throw PolicyAuthorityFileError.unavailable }
        try budget()
        if count == 0 { return CustodyRecordBinding.digest(Data()) }
        guard count >= nativeHeaderSize, try word(start, UInt32.self) == 0x012c_c16d else {
            throw PolicyAuthorityFileError.unavailable
        }
        let entries = Int(try word(start + 36, UInt32.self))
        let flags = try word(start + 40, UInt32.self)
        let (aceBytes, multiplyOverflow) = entries.multipliedReportingOverflow(by: nativeEntrySize)
        let (extent, extentOverflow) = nativeHeaderSize.addingReportingOverflow(aceBytes)
        // NOACL (UINT32_MAX) is not the supported-null encoding here. The
        // documented low16 filesystem-private flags must survive round trips;
        // only the two documented high flags are understood.
        guard entries <= maximumEntries, !multiplyOverflow, !extentOverflow, extent == count,
              flags & ~UInt32(0x0003_ffff) == 0 else { throw PolicyAuthorityFileError.unavailable }
        for index in 0..<entries {
            try budget()
            let ace = start + nativeHeaderSize + index * nativeEntrySize
            let flags = try word(ace + 16, UInt32.self), rights = try word(ace + 20, UInt32.self)
            // Deny only; inherited denials survive. Unknown kinds, flags,
            // rights and all grants refuse before the lengthless native API.
            guard flags & 0xf == 2, flags & ~UInt32(0x0000_01ff) == 0,
                  rights & ~UInt32(0x01f0_3ffe) == 0 else { throw PolicyAuthorityFileError.unavailable }
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<UInt64>.alignment)
        defer { storage.deallocate() }
        bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: storage, count: count), from: start..<end)
        try budget()
        guard let acl = acl_copy_int_native(storage) else { throw PolicyAuthorityFileError.unavailable }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try budget()
        return try PolicyAuthorityFile.privateStateObservedACL(acl, deadline: deadline)
    }

    #if SHADOW_SYNC_TESTING
    // Decoder fault sources are not kernel unsupported-attribute qualification.
    static func testingStrictReply(parent: Int32, endpoint: Endpoint, deadline: MonotonicDeadline) throws -> Data {
        let reply = try strictReply(parent: parent, endpoint: endpoint, deadline: deadline)
        guard reply.result == 0 else { throw PolicyAuthorityFileError.unavailable }
        return reply.bytes
    }
    static func testingDecodeStrictReply(_ bytes: Data, result: Int32, metadata: Metadata,
                                         deadline: MonotonicDeadline) throws -> String {
        try decodeStrictReply(bytes, result: result, metadata: metadata, deadline: deadline)
    }

    /// Synchronous, instance-scoped fault cut; no test syscall substitutes.
    static func testingRead(address: Address, retainedAncestors: [OwnedFileDescriptor], uid: uid_t,
                            deadline: MonotonicDeadline, expected: Self? = nil,
                            afterFirstRead: @escaping () throws -> Void) throws -> Self {
        try readImpl(address: address, retainedAncestors: retainedAncestors, uid: uid,
                     deadline: deadline, expected: expected, unpublishedCreator: nil, afterFirstRead: afterFirstRead)
    }
    #endif
}
