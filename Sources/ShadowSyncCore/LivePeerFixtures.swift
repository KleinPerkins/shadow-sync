#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

// These are refusals against the actual verifier, never a Developer ID positive
// or authenticated readiness proof. No credential or installed state is read.
enum LivePeerFixtures {
    typealias H = InstallationStorageFixtures
    static let expected = PublisherCodeVerifier.Identity(team: "FIXTURE123",
        identifier: "fixture-owner.peer-auth", codeDirectory: Data(repeating: 0, count: 20))
    static func refuses(_ descriptor: OwnedFileDescriptor, uid: uid_t = geteuid()) throws {
        do { _ = try PublisherCodeVerifier.livePeer(socket: descriptor, expected: expected, expectedUID: uid) }
        catch PublisherPolicyError.unavailable { return }
        throw H.Failure(message: "unqualified socket peer authenticated")
    }
    static func invalid(_ kind: String) throws {
        let raw: Int32
        switch kind {
        case "closed": raw = -1
        case "regular": raw = open("/dev/null", O_RDONLY | O_CLOEXEC)
        case "unconnected": raw = socket(AF_UNIX, SOCK_STREAM, 0)
        default: throw H.Failure(message: "unknown peer fixture")
        }
        if kind != "closed" { try H.check(raw >= 0, "peer fixture descriptor") }
        let descriptor = OwnedFileDescriptor(raw)
        defer { descriptor.closeNow() }
        try refuses(descriptor)
        if raw >= 0 { try H.check(fcntl(raw, F_GETFD) >= 0, "verifier closed caller descriptor") }
    }
    static func pair(datagram: Bool, wrongUID: Bool = false) throws {
        var pair: [Int32] = [-1, -1]
        try H.check(socketpair(AF_UNIX, datagram ? SOCK_DGRAM : SOCK_STREAM, 0, &pair) == 0, "peer fixture socketpair")
        let descriptor = OwnedFileDescriptor(pair[0]); defer { descriptor.closeNow(); close(pair[1]) }
        try refuses(descriptor, uid: wrongUID ? geteuid() ^ 1 : geteuid())
        try H.check(fcntl(pair[0], F_GETFD) >= 0, "peer duplicate closed caller socket")
    }
}
#endif
