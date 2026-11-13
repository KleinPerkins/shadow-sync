#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationReadinessWireFixtures {
    struct Failure: Error { let message: String }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() }
        catch is CustodyProtocolError { return }
        catch is PolicyProtocolError { return }
        catch is SecureStateError { return }
        throw Failure(message: "installation readiness malformed frame accepted")
    }
    private static func timesOut(_ body: () throws -> Void) throws {
        do { try body() }
        catch SecureStateError.systemCall("host control timeout", ETIMEDOUT) { return }
        throw Failure(message: "installation readiness deadline not enforced")
    }
    private static func refusesBlocking(_ body: () throws -> Void) throws {
        do { try body() }
        catch SecureStateError.unsafePath("blocking host control descriptor") { return }
        throw Failure(message: "blocking installation descriptor accepted")
    }
    static func message(_ event: InstallationReadinessMessage.Event = .hello) -> InstallationReadinessMessage {
        .init(event: event, transactionID: "00000000-0000-0000-0000-000000000001",
            boot: "00000000-0000-0000-0000-000000000002", controlRevision: 24,
            candidateReleaseDigest: String(repeating: "a", count: 64), stateBindingDigest: String(repeating: "b", count: 64),
            hostGeneration: "00000000-0000-0000-0000-000000000003", sessionNonce: String(repeating: "c", count: 32),
            previousMessageDigest: event == .hello ? nil : String(repeating: "d", count: 64))
    }
    static func roundtrip() throws {
        for event in InstallationReadinessMessage.Event.allCases {
            let expected = message(event), bytes = try expected.encode()
            try check(bytes.count < HostControlIO.maximumFrameBytes, "InstallationReadinessWireFixtures: existing frame bound")
            try check(try InstallationReadinessMessage.decode(bytes) == expected, "readiness observation changed")
            try check(try expected.digest() == CustodyRecordBinding.digest(bytes), "readiness transcript byte binding")
            let hostEvents: [InstallationReadinessMessage.Event] = [.hello, .ready, .normalStarted, .stopped]
            try check(event.sender == (hostEvents.contains(event) ? .host : .coordinator), "readiness message direction")
        }
    }
    static func canonicalRefusals() throws {
        let bytes = try message().encode(), text = String(decoding: bytes, as: UTF8.self)
        for value in [bytes + Data(" ".utf8), bytes + Data("\n".utf8), bytes + bytes, Data(), Data([0xff]),
            Data(text.replacingOccurrences(of: "\"event\":", with: "\"event\":\"hello\",\"event\":").utf8),
            Data(text.replacingOccurrences(of: "\"event\":\"hello\"", with: "\"event\":\"activate\"").utf8),
            Data(text.replacingOccurrences(of: "{", with: "{\"extra\":null,", range: text.startIndex..<text.index(after: text.startIndex)).utf8),
            Data(text.replacingOccurrences(of: ":24,", with: ":24.0,").utf8),
            Data(text.replacingOccurrences(of: ":24,", with: ":-1,").utf8),
            Data(text.replacingOccurrences(of: ":24,", with: ":18446744073709551616,").utf8)] {
            try refuses { _ = try InstallationReadinessMessage.decode(value) }
        }
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object["schema"] = "shadow-sync-host-request/v1"
        try refuses { _ = try InstallationReadinessMessage.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) }
    }
    static func fieldRefusals() throws {
        let original = try JSONSerialization.jsonObject(with: message(.ready).encode()) as! [String: Any]
        let changes: [(String, Any)] = [
            ("transaction", "invalid"), ("boot", ""), ("hostGeneration", "../host"),
            ("revision", 0), ("revision", true), ("candidate", String(repeating: "A", count: 64)),
            ("state", String(repeating: "a", count: 63)), ("nonce", String(repeating: "c", count: 33)),
            ("previous", NSNull()), ("previous", "invalid"),
        ]
        for (field, value) in changes {
            var v = original; v[field] = value
            try refuses { _ = try InstallationReadinessMessage.decode(JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) }
        }
        var v = original; v["event"] = "hello"
        try refuses { _ = try InstallationReadinessMessage.decode(JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) }
        v = original; v.removeValue(forKey: "previous")
        try refuses { _ = try InstallationReadinessMessage.decode(JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) }
    }
    private static func sockets(_ body: (Int32, Int32) throws -> Void) throws {
        var fds: [Int32] = [-1, -1]
        try check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "readiness socket pair")
        defer { fds.forEach { close($0) } }
        for fd in fds {
            try check(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETNOSIGPIPE, 1) == 0, "readiness fixture socket flags")
            // These synchronous fixtures write before reading. Reserve enough
            // kernel space for the largest legal frame; production peers read
            // concurrently and retain the caller's original deadline instead.
            for option in [SO_SNDBUF, SO_RCVBUF] {
                var capacity: Int32 = 65_536
                try check(setsockopt(fd, SOL_SOCKET, option, &capacity,
                    socklen_t(MemoryLayout<Int32>.size)) == 0, "readiness fixture socket capacity")
                var size = socklen_t(MemoryLayout<Int32>.size)
                try check(getsockopt(fd, SOL_SOCKET, option, &capacity, &size) == 0
                    && size == MemoryLayout<Int32>.size && capacity >= 2 * HostControlIO.maximumFrameBytes,
                    "readiness fixture socket capacity readback")
            }
            try HostControlIO.makeNonblocking(fd)
        }
        try body(fds[0], fds[1])
    }
    private static func raw(_ data: Data, to descriptor: Int32) throws {
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        try check(written == data.count, "readiness fixture write incomplete")
    }
    static func challengeExcessBeforeReady() throws {
        let hello = message(), deadline = MonotonicDeadline(seconds: 3)
        var initial = try InstallationPrecommitTranscript(hello: hello)
        try initial.consume(hello, sender: .host, deadline: deadline)
        let challenge = try initial.message(.challenge)
        let frame = try challenge.encode() + Data([10])
        for suffix in [Data(), frame, try message(.commit).encode() + Data([10]), Data([123])] {
            try sockets { coordinator, host in
                let payload = frame + suffix
                // One bounded write and one reader chunk force the relevant
                // coalesced condition rather than relying on stream timing.
                try check(payload.count < 4_096, "challenge fixture exceeds reader chunk")
                try raw(payload, to: coordinator)
                var frames = HostControlIO.FrameReader(), transcript = initial
                let advance = {
                    let observed = try InstallationPrecommitTransport.readChallenge(reader: &frames,
                        descriptor: host, deadline: deadline)
                    try transcript.consume(observed, sender: .coordinator, deadline: deadline)
                    let ready = try transcript.message(.ready)
                    try HostControlIO.writeFrame(ready.encode(), descriptor: host, deadline: deadline)
                }
                if suffix.isEmpty {
                    try advance()
                    var response = HostControlIO.FrameReader()
                    let ready = try InstallationReadinessMessage.decode(response.read(descriptor: coordinator, deadline: deadline))
                    try check(ready.event == .ready, "single challenge did not produce ready")
                } else {
                    try refuses(advance)
                    var byte: UInt8 = 0
                    try check(Darwin.read(coordinator, &byte, 1) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK),
                        "coalesced challenge emitted ready before refusal")
                }
            }
        }
    }
    static func persistentFrames() throws {
        try sockets { writer, reader in
            let first = try message().encode(), next = try message(.challenge).encode()
            try raw(first + Data([10]) + next + Data([10]), to: writer)
            var frames = HostControlIO.FrameReader()
            let deadline = MonotonicDeadline(seconds: 1)
            try check(try frames.read(descriptor: reader, deadline: deadline) == first, "coalesced first readiness frame")
            try check(try frames.read(descriptor: reader, deadline: deadline) == next, "coalesced next readiness frame lost")
            try check(!frames.hasBufferedBytes, "readiness frame residue")
            let third = try message(.ready).encode(), split = third.count / 2
            try raw(third.prefix(split), to: writer); try raw(third.suffix(from: split) + Data([10]), to: writer)
            try check(try frames.read(descriptor: reader, deadline: deadline) == third, "fragmented readiness frame changed")
        }
    }
    static func boundedFrames() throws {
        try sockets { writer, reader in
            let limit = HostControlIO.maximumFrameBytes, good = Data(repeating: 65, count: limit - 1)
            let deadline = MonotonicDeadline(seconds: 1)
            try HostControlIO.writeFrame(good, descriptor: writer, deadline: deadline)
            var frames = HostControlIO.FrameReader()
            try check(try frames.read(descriptor: reader, deadline: deadline) == good, "maximum bounded frame changed")
            for bad in [Data(), Data([10]), Data(repeating: 65, count: limit)] {
                try refuses { try HostControlIO.writeFrame(bad, descriptor: writer, deadline: deadline) }
            }
            try refuses { _ = try InstallationReadinessMessage.decode(Data(repeating: 65, count: limit)) }
            try raw(Data(repeating: 65, count: limit) + Data([10]), to: writer)
            try refuses { _ = try frames.read(descriptor: reader, deadline: deadline) }
        }
        try sockets { writer, reader in
            for fd in [writer, reader] {
                let flags = fcntl(fd, F_GETFL)
                try check(flags >= 0 && fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0, "blocking fixture descriptor")
            }
            let deadline = MonotonicDeadline(seconds: 1)
            try refusesBlocking { try HostControlIO.writeFrame(Data([65]), descriptor: writer, deadline: deadline) }
            try raw(Data([66, 10]), to: writer)
            var frames = HostControlIO.FrameReader()
            try refusesBlocking { _ = try frames.read(descriptor: reader, deadline: deadline) }
            var byte: UInt8 = 0
            try check(Darwin.read(reader, &byte, 1) == 1 && byte == 66, "blocking refusal consumed or emitted bytes")
        }
    }
    static func eofAndEmpty() throws {
        for payload in [Data([10]), Data("{\"partial\":".utf8)] {
            try sockets { writer, reader in
                try raw(payload, to: writer)
                try check(shutdown(writer, SHUT_WR) == 0, "readiness fixture EOF")
                var frames = HostControlIO.FrameReader()
                try refuses { _ = try frames.read(descriptor: reader, deadline: .init(seconds: 1)) }
            }
        }
    }
    static func sharedDeadline() throws {
        try sockets { writer, reader in
            let bytes = try message().encode()
            try raw(bytes + Data([10]) + bytes + Data([10]), to: writer)
            var frames = HostControlIO.FrameReader()
            try check(try frames.read(descriptor: reader, deadline: .init(seconds: 1)) == bytes, "initial readiness frame")
            // An already expired absolute budget is deterministic: neither a
            // buffered frame nor a writable peer may create a replacement one.
            let expired = MonotonicDeadline(uptimeNanoseconds: 0)
            try timesOut { _ = try frames.read(descriptor: reader, deadline: expired) }
            try timesOut { try HostControlIO.writeFrame(bytes, descriptor: reader, deadline: expired) }
            var byte: UInt8 = 0
            try check(Darwin.read(writer, &byte, 1) == -1 && errno == EAGAIN, "expired readiness write emitted bytes")
        }
        try sockets { writer, reader in
            var frames = HostControlIO.FrameReader()
            try timesOut { _ = try frames.read(descriptor: reader, deadline: .init(seconds: 0.05)) }
            // Fill only this private socket's bounded kernel buffer. No worker
            // or delayed callback survives either timeout or fixture cleanup.
            let chunk = Data(repeating: 65, count: 16_384)
            var blocked = false
            for _ in 0..<128 {
                let count = chunk.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { blocked = true; break }
                try check(count > 0, "readiness backpressure fixture write")
            }
            try check(blocked, "readiness fixture buffer bound")
            try timesOut { try HostControlIO.writeFrame(Data([66]), descriptor: writer, deadline: .init(seconds: 0.05)) }
        }
    }
    static func legacyWrappers() throws {
        try sockets { writer, reader in
            let request = HostControlRequest(expectedGeneration: RunIdentity.make())
            try HostControlIO.write(request, descriptor: writer)
            try check(try HostControlIO.read(HostControlRequest.self, descriptor: reader) == request, "existing host-control wrapper changed")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(request)
            try raw(bytes + Data([10]) + bytes + Data([10]), to: writer)
            try refuses { _ = try HostControlIO.read(HostControlRequest.self, descriptor: reader) }
        }
    }
}
#endif
