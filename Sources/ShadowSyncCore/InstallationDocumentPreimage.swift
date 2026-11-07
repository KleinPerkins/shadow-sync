import Foundation

/// Private recoverable content, deliberately separate from installation control
/// and step metadata. No path, policy payload or document bytes enter those records.
/// The complete source is retained or capture refuses; never truncate a log.
struct InstallationDocumentPreimage: Equatable {
    static let prefix = "installation-document-"
    // Existing durable readers permit 4 MiB Body3 logs and 1 MiB authority,
    // selection and recovery documents. These bounds do not narrow that state.
    static func maximumContentBytes(for document: InstallationDocument) -> Int {
        document == .latestLog ? 4_194_304 : 1_048_576
    }
    static let maximumBytes = 5_600_000
    let transactionID: String
    let slot: InstallationSlot
    let document: InstallationDocument
    let namespace: InstallationNodeIdentity
    let node: InstallationNodeIdentity
    let bytes: Data

    private var metadata: PolicyWireValue { .object([
        "schema": .string("shadow-sync-installation-document/v1"),
        "transactionID": .string(transactionID), "slot": .string(slot.rawValue),
        "document": .string(document.rawValue), "namespace": namespace.wire,
        "node": node.wire, "bytes": .string(""),
    ]) }
    func validate(uid: UInt32) throws {
        guard RunIdentity.isValid(transactionID), slot.isNamespace,
              namespace.type == .directory, namespace.mode == 0o040700, namespace.uid == uid,
              node.type == .regular, node.mode == 0o100600, node.uid == uid,
              bytes.count <= Self.maximumContentBytes(for: document) else { throw CustodyRecordError.unsafeMetadata }
        try namespace.validate(); try node.validate()
    }
    func encode(uid: UInt32) throws -> Data {
        try validate(uid: uid)
        let prefix = Data("{\"bytes\":\"".utf8)
        let header = try CustodyWire.encode(metadata, maximum: 4096)
        guard header.starts(with: prefix) else { throw CustodyRecordError.unsafeMetadata }
        // Foundation's base64 encoder emits only canonical ASCII without JSON
        // escaping. Encode the small metadata once, retaining identical sorted
        // JSON bytes without a second multi-MiB scalar walk in the wire encoder.
        var encoded = prefix
        encoded.append(contentsOf: bytes.base64EncodedString().utf8)
        encoded.append(header.dropFirst(prefix.count))
        guard encoded.count <= Self.maximumBytes else { throw CustodyRecordError.unsafeMetadata }
        return encoded
    }
    func digest(uid: UInt32) throws -> String { try CustodyRecordBinding.digest(encode(uid: uid)) }
    func filename(uid: UInt32) throws -> String { try Self.prefix + digest(uid: uid) + ".json" }
    static func decode(_ bytes: Data, uid: UInt32) throws -> Self {
        // The first canonical key is bytes. Peel ONLY its bounded base64 scalar
        // before applying the existing strict metadata parser; never widen the
        // general IPC/configuration grammar or let JSON discard duplicate keys.
        let prefix = Data("{\"bytes\":\"".utf8)
        guard bytes.count <= maximumBytes, bytes.starts(with: prefix),
              let end = bytes[prefix.count...].firstIndex(of: 34),
              let text = String(data: bytes[prefix.count..<end], encoding: .ascii),
              let content = Data(base64Encoded: text), content.base64EncodedString() == text else {
            throw CustodyRecordError.unsafeMetadata
        }
        var metadata = prefix; metadata.append(bytes[end...])
        guard metadata.count <= 4096 else { throw CustodyRecordError.unsafeMetadata }
        var parser = try PolicyWireParser(metadata)
        let wire = try parser.parse()
        let v = try wire.object(keys: ["schema", "transactionID", "slot", "document", "namespace", "node", "bytes"])
        guard v["schema"] == .string("shadow-sync-installation-document/v1"), v["bytes"] == .string("") else {
            throw CustodyRecordError.unsafeMetadata
        }
        guard let slot = InstallationSlot(rawValue: try CustodyWire.text(v["slot"])),
              let document = InstallationDocument(rawValue: try CustodyWire.text(v["document"])) else {
            throw CustodyRecordError.unsafeMetadata
        }
        let result = try Self(transactionID: CustodyWire.text(v["transactionID"]),
            slot: slot, document: document,
            namespace: InstallationNodeIdentity(wire: CustodyWire.required(v["namespace"])),
            node: InstallationNodeIdentity(wire: CustodyWire.required(v["node"])), bytes: content)
        try result.validate(uid: uid)
        guard try CustodyWire.encode(wire, maximum: 4096) == metadata else { throw CustodyRecordError.unsafeMetadata }
        return result
    }
}

// One immutable observation per guarded scan. No across-call authority cache:
// each admission rereads bytes and revalidates node/ACL/content under the guard.
extension InstallationDocumentPreimage {
    struct CanonicalObservation {
        let receipt: InstallationDocumentPreimage
        let bytes: Data
        let digest: String
        var filename: String { InstallationDocumentPreimage.prefix + digest + ".json" }
        init(_ receipt: InstallationDocumentPreimage, uid: UInt32) throws {
            self.receipt = receipt; bytes = try receipt.encode(uid: uid)
            digest = CustodyRecordBinding.digest(bytes)
        }
        init(decoding bytes: Data, uid: UInt32) throws {
            receipt = try InstallationDocumentPreimage.decode(bytes, uid: uid)
            self.bytes = bytes; digest = CustodyRecordBinding.digest(bytes)
        }
    }
}
