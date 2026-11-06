import Darwin

/// Fresh descriptor-relative metadata for a previously authenticated runtime.
/// Initial capture/signature/ACL validation remains on the full no-follow path.
/// No result or descriptor is retained across a runtime revalidation.
struct PolicyRuntimeBulkDirectory {
    struct Entry {
        let name: String
        let regularFile: stat?
        let length: Int
    }
    static let common: UInt32 = [UInt32(ATTR_CMN_RETURNED_ATTRS), UInt32(ATTR_CMN_ERROR),
        UInt32(ATTR_CMN_NAME), UInt32(ATTR_CMN_DEVID), UInt32(ATTR_CMN_OBJTYPE), UInt32(ATTR_CMN_MODTIME),
        UInt32(ATTR_CMN_CHGTIME), UInt32(ATTR_CMN_OWNERID), UInt32(ATTR_CMN_GRPID), UInt32(ATTR_CMN_ACCESSMASK),
        UInt32(ATTR_CMN_FLAGS), UInt32(ATTR_CMN_FILEID)].reduce(UInt32(0), |)
    static let files = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH)
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private var offset = 0, remaining = 0, total = 0
    private var finished = false

    mutating func next(fd: Int32) throws -> Entry? {
        if finished { return nil }
        if remaining == 0 {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = Self.common; attributes.fileattr = Self.files
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(fd, &attributes, $0.baseAddress, $0.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            }
            guard count >= 0, count <= 4096 - total else { throw PublisherPolicyError.unavailable }
            if count == 0 { finished = true; return nil }
            total += Int(count); remaining = Int(count); offset = 0
        }
        let entry = try buffer.withUnsafeBytes { try Self.decode($0, offset: offset) }
        offset += entry.length; remaining -= 1
        return entry
    }

    /// Darwin attributes are four-byte packed, including 64-bit values. Each
    /// complete record is eight-byte aligned. Invalid requested fields are
    /// packed, but directory records omit the file-only attribute group.
    static func decode(_ bytes: UnsafeRawBufferPointer, offset: Int) throws -> Entry {
        guard offset >= 0, offset % 8 == 0, bytes.count >= 100, offset <= bytes.count - 100 else {
            throw PublisherPolicyError.unavailable
        }
        func u32(_ field: Int) -> UInt32 { bytes.loadUnaligned(fromByteOffset: offset + field, as: UInt32.self) }
        func i32(_ field: Int) -> Int32 { bytes.loadUnaligned(fromByteOffset: offset + field, as: Int32.self) }
        func u64(_ field: Int) -> UInt64 { bytes.loadUnaligned(fromByteOffset: offset + field, as: UInt64.self) }
        func i64(_ field: Int) -> Int64 { bytes.loadUnaligned(fromByteOffset: offset + field, as: Int64.self) }
        let length = Int(u32(0)), returned = u32(4), returnedFile = u32(16)
        guard length >= 100, length % 8 == 0, length <= bytes.count - offset,
              returned & (common & ~UInt32(ATTR_CMN_ERROR)) == common & ~UInt32(ATTR_CMN_ERROR),
              returned & ~common == 0, u32(8) == 0, u32(12) == 0, u32(20) == 0,
              returnedFile & ~files == 0, u32(24) == 0 else { throw PublisherPolicyError.unavailable }
        let relative = Int(i32(28)), nameLength = Int(u32(32)), kind = u32(40)
        guard relative >= 72, relative % 4 == 0, (2...256).contains(nameLength),
              relative <= length - 28, nameLength <= length - 28 - relative,
              kind == VREG.rawValue || kind == VDIR.rawValue || kind == VLNK.rawValue else {
            throw PublisherPolicyError.unavailable
        }
        let start = offset + 28 + relative
        let nameBytes = bytes[start..<(start + nameLength - 1)]
        guard bytes[start + nameLength - 1] == 0,
              nameBytes.allSatisfy({ (32...126).contains($0) && $0 != 47 && $0 != 92 }) else {
            throw PublisherPolicyError.unavailable
        }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard name != ".", name != ".." else { throw PublisherPolicyError.unavailable }
        guard kind == VREG.rawValue else { return Entry(name: name, regularFile: nil, length: length) }
        guard length >= 112, relative >= 84, returnedFile == files,
              let links = UInt16(exactly: u32(100)),
              (0..<1_000_000_000).contains(i64(52)), (0..<1_000_000_000).contains(i64(68)) else {
            throw PublisherPolicyError.unavailable
        }
        var value = stat()
        value.st_dev = i32(36); value.st_ino = u64(92)
        value.st_uid = u32(76); value.st_gid = u32(80)
        // ATTR_CMN_ACCESSMASK promises only permissions; object type is separate.
        guard let permissions = UInt16(exactly: u32(84) & ~UInt32(S_IFMT)) else {
            throw PublisherPolicyError.unavailable
        }
        value.st_mode = permissions | UInt16(S_IFREG)
        value.st_flags = u32(88); value.st_nlink = links; value.st_size = i64(104)
        value.st_mtimespec = timespec(tv_sec: Int(i64(44)), tv_nsec: Int(i64(52)))
        value.st_ctimespec = timespec(tv_sec: Int(i64(60)), tv_nsec: Int(i64(68)))
        return Entry(name: name, regularFile: value, length: length)
    }
}
