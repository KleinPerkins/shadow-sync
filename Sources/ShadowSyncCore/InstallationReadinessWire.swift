import Foundation

/// Closed observations on the installation socket. Decoding, a matching nonce,
/// and transcript hashes confer NO peer, owner, command or startup authority.
/// The live authenticated session must validate each observation against its
/// current durable control and enforce message order before any transition.
struct InstallationReadinessMessage: Equatable {
    enum Endpoint: Equatable { case host, coordinator }
    enum Event: String, CaseIterable {
        case hello, challenge, ready, commit
        case normalStarted = "normal-started"
        case stop, stopped
        var sender: Endpoint {
            switch self {
            case .hello, .ready, .normalStarted, .stopped: .host
            case .challenge, .commit, .stop: .coordinator
            }
        }
    }
    static let schema = "shadow-sync-installation-readiness/v1"
    // The existing socket frame bound includes its single newline terminator.
    static let maximumBytes = HostControlIO.maximumFrameBytes - 1
    let event: Event
    let transactionID: String
    let boot: String
    let controlRevision: UInt64
    let candidateReleaseDigest: String
    let stateBindingDigest: String
    let hostGeneration: String
    let sessionNonce: String
    let previousMessageDigest: String?

    func validate() throws {
        guard [transactionID, boot, hostGeneration].allSatisfy(RunIdentity.isValid),
              controlRevision > 0,
              CustodyWire.hex(candidateReleaseDigest, bytes: 32),
              CustodyWire.hex(stateBindingDigest, bytes: 32),
              CustodyWire.hex(sessionNonce, bytes: 16),
              (event == .hello ? previousMessageDigest == nil
                : previousMessageDigest.map { CustodyWire.hex($0, bytes: 32) } == true) else {
            throw CustodyProtocolError.invalidMessage
        }
    }
    private var wire: PolicyWireValue { .object([
        "schema": .string(Self.schema), "event": .string(event.rawValue),
        "transaction": .string(transactionID), "boot": .string(boot),
        "revision": .unsigned(controlRevision), "candidate": .string(candidateReleaseDigest),
        "state": .string(stateBindingDigest), "hostGeneration": .string(hostGeneration),
        "nonce": .string(sessionNonce), "previous": previousMessageDigest.map(PolicyWireValue.string) ?? .null,
    ]) }
    func encode() throws -> Data {
        try validate()
        return try CustodyWire.encode(wire, maximum: Self.maximumBytes)
    }
    func digest() throws -> String { try CustodyRecordBinding.digest(encode()) }
    static func decode(_ data: Data) throws -> Self {
        let v = try CustodyWire.decode(data, maximum: maximumBytes).object(keys: [
            "schema", "event", "transaction", "boot", "revision", "candidate", "state", "hostGeneration", "nonce", "previous",
        ])
        guard v["schema"] == .string(schema),
              let event = Event(rawValue: try CustodyWire.text(v["event"])) else {
            throw CustodyProtocolError.invalidMessage
        }
        let message = try Self(event: event, transactionID: CustodyWire.text(v["transaction"]),
            boot: CustodyWire.text(v["boot"]), controlRevision: CustodyWire.uint(v["revision"]),
            candidateReleaseDigest: CustodyWire.text(v["candidate"]), stateBindingDigest: CustodyWire.text(v["state"]),
            hostGeneration: CustodyWire.text(v["hostGeneration"]), sessionNonce: CustodyWire.text(v["nonce"]),
            previousMessageDigest: CustodyWire.optionalText(v["previous"]))
        try message.validate()
        return message
    }
}
