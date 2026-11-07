import Darwin
import Foundation

/// Sealed observations for fixed reservation or drain-prior diagnostics. This wire value is
/// not authority: admission also needs actual inherited leases, a live exact
/// coordinator, its publisher and the matching durable command reservation.
struct InstallationCommandBinding: Equatable {
    let control: InstallationControlRecord
    let controlNode: InstallationNodeIdentity
    let receiptNodes: [String: InstallationNodeIdentity]
    var wire: PolicyWireValue { .object([
        "schema": .string("shadow-sync-installation-command/v1"),
        "control": control.wire, "controlNode": controlNode.wire,
        "receipts": .object(receiptNodes.mapValues(\.wire)),
    ]) }
    func validate() throws {
        try control.validate(); try controlNode.validate()
        let drain = control.step?.action == .drainPrior && control.step?.status == .intent
        guard control.phase == .active,
              drain || (control.step?.action == .reserve && control.step?.status == .complete), control.readinessCommit == nil,
              control.transaction != nil, controlNode.type == .regular,
              controlNode.uid == control.state.directory.uid, controlNode.mode == 0o100600,
              (2...11).contains(receiptNodes.count),
              receiptNodes.keys.filter({ $0.hasPrefix(InstallationStepReceipt.prefix) }).count == (drain ? 3 : 2) else { throw CustodyRecordError.fenced }
        guard let transaction = control.transaction, transaction.priorCommitDigest == nil,
              control.step?.ordinal == (drain ? 2 : 1) else { throw CustodyRecordError.fenced }
        let intent = InstallationStepReceipt(transactionID: transaction.id, ordinal: 1,
            previousReceiptDigest: nil, action: .reserve, status: .intent,
            preimage: transaction.slots, postimage: nil,
            bindingDigest: try transaction.bindingDigest(state: control.state))
        let complete = InstallationStepReceipt(transactionID: transaction.id, ordinal: 1,
            previousReceiptDigest: try intent.digest(uid: controlNode.uid), action: .reserve, status: .complete,
            preimage: transaction.slots, postimage: transaction.slots, bindingDigest: intent.bindingDigest)
        var expected = Set([try intent.filename(uid: controlNode.uid), try complete.filename(uid: controlNode.uid)])
        for slot in [InstallationSlot.stateSource, .stateDestination] {
            for digest in (transaction.slots.images[slot]?.documentReceipts ?? [:]).values.compactMap({ $0 }) {
                expected.insert(InstallationDocumentPreimage.prefix + digest + ".json")
            }
        }
        var latest = complete
        if drain {
            latest = InstallationStepReceipt(transactionID: transaction.id, ordinal: 2,
                previousReceiptDigest: try complete.digest(uid: controlNode.uid), action: .drainPrior, status: .intent,
                preimage: transaction.slots, postimage: nil, bindingDigest: intent.bindingDigest)
            expected.insert(try latest.filename(uid: controlNode.uid))
        }
        guard Set(receiptNodes.keys) == expected, control.step == (try latest.step()),
              control.latestReceiptDigest == (try latest.digest(uid: controlNode.uid)) else { throw CustodyRecordError.fenced }
        for (name, node) in receiptNodes {
            try node.validate()
            guard (name.hasPrefix(InstallationStepReceipt.prefix) || name.hasPrefix(InstallationDocumentPreimage.prefix)), name.hasSuffix(".json"),
                  !name.contains("/"), node.type == .regular, node.mode == 0o100600,
                  node.uid == controlNode.uid else { throw CustodyRecordError.fenced }
        }
    }
    func encode() throws -> Data {
        try validate(); return try CustodyWire.encode(wire, maximum: 65_536)
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 65_536 else { throw CustodyRecordError.fenced }
        // Embedded installation slots have seventeen fixed keys. Reuse the
        // existing installation record parser profile; retain this smaller byte
        // bound, exact schema and canonical equality rather than widening IPC.
        var parser = try PolicyWireParser(bytes, profile: .bundleLayout)
        let v = try parser.parse().object(keys: ["schema", "control", "controlNode", "receipts"])
        guard v["schema"] == .string("shadow-sync-installation-command/v1"),
              case let .object(nodes) = try CustodyWire.required(v["receipts"]) else { throw CustodyRecordError.fenced }
        let control = try InstallationControlRecord.decode(CustodyWire.encode(CustodyWire.required(v["control"]), maximum: 32_768))
        let result = try Self(control: control,
            controlNode: InstallationNodeIdentity(wire: CustodyWire.required(v["controlNode"])),
            receiptNodes: nodes.mapValues { try InstallationNodeIdentity(wire: $0) })
        guard try result.encode() == bytes else { throw CustodyRecordError.fenced }; return result
    }
    func validateParent(_ parent: ProcessIdentity, helper: CustodyHelperExecutable) throws {
        try validate()
        guard parent.processID > 1, let transaction = control.transaction, transaction.boot == (try CustodyBootIdentity.current()),
              transaction.coordinator.process.pid == UInt32(parent.processID),
              transaction.coordinator.process.uid == parent.userID,
              transaction.coordinator.process.startSeconds == parent.startSeconds,
              transaction.coordinator.process.startMicroseconds == parent.startMicroseconds,
              transaction.coordinator.process.generation == parent.generation else { throw CustodyRecordError.fenced }
        try helper.validateInstallationPublisher(transaction)
    }
}
