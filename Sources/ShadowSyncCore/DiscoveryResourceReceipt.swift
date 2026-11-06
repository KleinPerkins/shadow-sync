import Darwin
import Foundation

/// A bounded observation of one helper-owned resource, never a filesystem or
/// cleanup capability. Only the live owner may derive a transition from an
/// observed operation; decoding this record does not adopt its descriptors.
struct DiscoveryResourceReceipt: Equatable, Sendable {
    enum Phase: String, Sendable {
        case planned, intent, directoryCreated = "directory-created", fileCreated = "file-created"
        case sealed, fileRemoved = "file-removed", directoryRemoved = "directory-removed", retired
    }
    static let maximumBytes = 4_096
    let binding: CustodyRecordBinding
    let ordinal: UInt64
    let phase: Phase
    let directory: FileIdentity?
    let file: FileIdentity?
    let contentSHA256: String?
    let size: UInt64?

    // A fixed, lexical UUID namespace distinct from legacy six-character
    // snapshots. Callers must policy-classify these exact paths and ancestors
    // before the owner opens the temporary root or creates an entry.
    static func directoryName(requestID: String) throws -> String {
        guard RunIdentity.isValid(requestID) else { throw CustodyRecordError.invalidRecord }
        return "shadow-sync-discovery-config." + requestID
    }
    static func resourcePaths(requestID: String) throws -> [String] {
        let directory = "/private/tmp/" + (try directoryName(requestID: requestID))
        return [directory, directory + "/config"]
    }
    init(planned binding: CustodyRecordBinding) throws {
        self.binding = binding; ordinal = 0; phase = .planned
        directory = nil; file = nil; contentSHA256 = nil; size = nil
        try validate()
    }
    func capturing(contentSHA256: String, size: UInt64) throws -> Self {
        guard phase == .planned else { throw CustodyRecordError.invalidTransition }
        return try Self(binding: binding, contentSHA256: contentSHA256, size: size)
    }
    init(binding: CustodyRecordBinding, contentSHA256: String, size: UInt64) throws {
        self.binding = binding; self.contentSHA256 = contentSHA256; self.size = size
        ordinal = 1; phase = .intent; directory = nil; file = nil
        try validate()
    }
    private init(binding: CustodyRecordBinding, ordinal: UInt64, phase: Phase,
                 directory: FileIdentity?, file: FileIdentity?, contentSHA256: String?, size: UInt64?) {
        self.binding = binding; self.ordinal = ordinal; self.phase = phase
        self.directory = directory; self.file = file; self.contentSHA256 = contentSHA256; self.size = size
    }
    func advancing(to next: Phase, directory observedDirectory: FileIdentity? = nil,
                   file observedFile: FileIdentity? = nil) throws -> Self {
        guard ordinal < UInt64.max else { throw CustodyRecordError.invalidTransition }
        switch (phase, next) {
        case (.intent, .directoryCreated):
            guard observedDirectory != nil, observedFile == nil else { throw CustodyRecordError.invalidTransition }
        case (.directoryCreated, .fileCreated):
            guard observedDirectory == nil, observedFile != nil else { throw CustodyRecordError.invalidTransition }
        case (.fileCreated, .sealed), (.fileCreated, .fileRemoved), (.sealed, .fileRemoved),
             (.directoryCreated, .directoryRemoved), (.fileRemoved, .directoryRemoved),
             (.directoryRemoved, .retired), (.intent, .retired), (.planned, .retired):
            guard observedDirectory == nil, observedFile == nil else { throw CustodyRecordError.invalidTransition }
        default: throw CustodyRecordError.invalidTransition
        }
        let next = Self(binding: binding, ordinal: ordinal + 1, phase: next,
            directory: observedDirectory ?? directory, file: observedFile ?? file,
            contentSHA256: contentSHA256, size: size)
        try next.validate(); return next
    }
    /// Compare-and-replace admission for the durable store. Identity evidence
    /// can only be acquired once and is retained even after owned deletion.
    func validateSuccessor(_ next: Self) throws {
        if phase == .planned, next.phase == .intent {
            guard let digest = next.contentSHA256, let size = next.size,
                  try capturing(contentSHA256: digest, size: size) == next else { throw CustodyRecordError.conflict }
            return
        }
        let expected = try advancing(to: next.phase,
            directory: phase == .intent && next.phase == .directoryCreated ? next.directory : nil,
            file: phase == .directoryCreated && next.phase == .fileCreated ? next.file : nil)
        guard expected == next else { throw CustodyRecordError.conflict }
    }
    func validate() throws {
        try binding.validate()
        if phase == .planned || (phase == .retired && ordinal == 1) {
            guard contentSHA256 == nil, size == nil else { throw CustodyRecordError.invalidRecord }
        } else {
            guard let contentSHA256, let size, CustodyWire.hex(contentSHA256, bytes: 32),
                  size <= 1_572_864 else { throw CustodyRecordError.invalidRecord }
        }
        if let directory {
            guard directory.device > 0, directory.inode > 0, directory.owner == binding.uid,
                  directory.mode == UInt16(S_IFDIR | 0o700), directory.linkCount > 0 else {
                throw CustodyRecordError.invalidRecord
            }
        }
        if let file {
            guard let directory, file.device == directory.device, file.inode > 0,
                  file.inode != directory.inode, file.owner == binding.uid,
                  file.mode == UInt16(S_IFREG | 0o600), file.linkCount == 1 else {
                throw CustodyRecordError.invalidRecord
            }
        }
        // Exact possible ordinals prevent invented intermediate histories.
        switch phase {
        case .planned: guard ordinal == 0, directory == nil, file == nil else { throw CustodyRecordError.invalidRecord }
        case .intent: guard ordinal == 1, directory == nil, file == nil else { throw CustodyRecordError.invalidRecord }
        case .directoryCreated: guard ordinal == 2, directory != nil, file == nil else { throw CustodyRecordError.invalidRecord }
        case .fileCreated: guard ordinal == 3, directory != nil, file != nil else { throw CustodyRecordError.invalidRecord }
        case .sealed: guard ordinal == 4, directory != nil, file != nil else { throw CustodyRecordError.invalidRecord }
        case .fileRemoved: guard [4, 5].contains(ordinal), directory != nil, file != nil else { throw CustodyRecordError.invalidRecord }
        case .directoryRemoved:
            guard directory != nil, file == nil ? ordinal == 3 : [5, 6].contains(ordinal) else {
                throw CustodyRecordError.invalidRecord
            }
        case .retired:
            guard directory == nil ? ([1, 2].contains(ordinal) && file == nil)
                : (file == nil ? ordinal == 4 : [6, 7].contains(ordinal)) else {
                throw CustodyRecordError.invalidRecord
            }
        }
    }
    private static func wire(_ node: FileIdentity?) -> PolicyWireValue {
        guard let node else { return .null }
        return .object(["device": .unsigned(node.device), "inode": .unsigned(node.inode),
            "uid": .unsigned(UInt64(node.owner)), "mode": .unsigned(UInt64(node.mode)),
            "links": .unsigned(UInt64(node.linkCount))])
    }
    private static func node(_ value: PolicyWireValue?) throws -> FileIdentity? {
        guard let value else { throw CustodyRecordError.invalidRecord }
        if value == .null { return nil }
        let v = try value.object(keys: ["device", "inode", "uid", "mode", "links"])
        let device = try CustodyWire.uint(v["device"]), inode = try CustodyWire.uint(v["inode"])
        guard let deviceValue = dev_t(exactly: device), let inodeValue = ino_t(exactly: inode),
              let uid = uid_t(exactly: try CustodyWire.uint(v["uid"])),
              let mode = mode_t(exactly: try CustodyWire.uint(v["mode"])),
              let links = nlink_t(exactly: try CustodyWire.uint(v["links"])) else {
            throw CustodyRecordError.invalidRecord
        }
        var info = stat(); info.st_dev = deviceValue; info.st_ino = inodeValue
        info.st_uid = uid; info.st_mode = mode; info.st_nlink = links
        return FileIdentity(info)
    }
    var wire: PolicyWireValue { .object([
        "schema": .string("shadow-sync-discovery-resource/v2"), "binding": binding.wire,
        "transition": .unsigned(ordinal), "phase": .string(phase.rawValue),
        "directory": Self.wire(directory), "file": Self.wire(file),
        "sha256": contentSHA256.map(PolicyWireValue.string) ?? .null, "size": size.map(PolicyWireValue.unsigned) ?? .null,
    ]) }
    func encode() throws -> Data { try validate(); return try CustodyWire.encode(wire, maximum: Self.maximumBytes) }
    static func decode(_ bytes: Data) throws -> Self {
        let v = try CustodyWire.decode(bytes, maximum: maximumBytes).object(keys:
            ["schema", "binding", "transition", "phase", "directory", "file", "sha256", "size"])
        guard try CustodyWire.text(v["schema"]) == "shadow-sync-discovery-resource/v2",
              let phase = Phase(rawValue: try CustodyWire.text(v["phase"])), let binding = v["binding"] else {
            throw CustodyRecordError.invalidRecord
        }
        let value = Self(binding: try CustodyRecordBinding(wire: binding),
            ordinal: try CustodyWire.uint(v["transition"]), phase: phase,
            directory: try node(v["directory"]), file: try node(v["file"]),
            contentSHA256: v["sha256"] == .null ? nil : try CustodyWire.text(v["sha256"]),
            size: v["size"] == .null ? nil : try CustodyWire.uint(v["size"]))
        try value.validate()
        guard try value.encode() == bytes else { throw CustodyRecordError.invalidRecord }
        return value
    }
}
