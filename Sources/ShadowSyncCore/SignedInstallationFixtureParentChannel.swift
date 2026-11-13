#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// A fixed inherited AF_UNIX bootstrap channel, distinct from command pipes and
/// installation/host sockets. Its parent end is retained by the actual command
/// resources until checked retirement. No path, PID or environment is authority.
/// LOCAL_PEERTOKEN on socketpair remains a native qualification prerequisite;
/// unsupported or unexpected kernel observations refuse without a PID fallback.
final class SignedInstallationFixtureParentChannel: @unchecked Sendable {
    static let inheritedFD: Int32 = 211
    private let parent: OwnedFileDescriptor
    let child: OwnedFileDescriptor
    private let parentNode: FileIdentity
    private let childNode: FileIdentity
    private let mutex = NSLock()
    private var transferred = false

    init(request: SignedInstallationFixtureContext.Request, requestDigest: String) throws {
        guard CustodyWire.hex(requestDigest, bytes: 32), RuntimeSuiteGuardian.now < request.deadline else {
            throw CustodyRecordError.fenced
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CustodyRecordError.persistence(errno) }
        let first = OwnedFileDescriptor(pair[0]), second = OwnedFileDescriptor(pair[1])
        // All mappings originate above fixed inherited roles. Keep the original
        // socket descriptions while setting CLOEXEC atomically on each copy.
        parent = OwnedFileDescriptor(try first.duplicate(minimum: 214))
        child = OwnedFileDescriptor(try second.duplicate(minimum: 214))
        guard first.retireChecked() == .succeeded, second.retireChecked() == .succeeded else {
            throw CustodyRecordError.fenced
        }
        try InstallationPrecommitTransport.configure(parent.value)
        try InstallationPrecommitTransport.configure(child.value)
        parentNode = try Self.capture(parent)
        childNode = try Self.capture(child)
        let envelope = try CustodyWire.encode(.object([
            "schema": .string("shadow-sync-signed-installation-parent/v1"),
            "request": .string(requestDigest),
            "context": try CustodyWire.decode(request.bytes, maximum: 16_384),
        ]), maximum: 24_576)
        // One bounded pre-spawn frame. A full send buffer refuses under the
        // original suite budget; it does not create a fresh helper deadline.
        try HostControlIO.writeFrame(envelope, descriptor: parent.value,
            deadline: .init(uptimeNanoseconds: request.deadline))
        try validate()
    }
    private static func capture(_ socket: OwnedFileDescriptor) throws -> FileIdentity {
        try socket.withOriginalSocket { fd in
            var info = stat(), kind: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == geteuid(), fcntl(fd, F_GETFD) & FD_CLOEXEC != 0,
                  fcntl(fd, F_GETFL) & O_NONBLOCK != 0,
                  getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0,
                  length == MemoryLayout<Int32>.size, kind == SOCK_STREAM else { throw CustodyRecordError.fenced }
            return FileIdentity(info)
        }
    }
    func validate() throws {
        guard try Self.capture(parent).matchesStableNode(parentNode) else { throw CustodyRecordError.fenced }
        switch child.retirementObservation {
        case .notAttempted:
            guard try Self.capture(child).matchesStableNode(childNode) else { throw CustodyRecordError.fenced }
        case .succeeded:
            mutex.lock(); let handed = transferred; mutex.unlock()
            guard handed else { throw CustodyRecordError.fenced }
        default: throw CustodyRecordError.fenced
        }
    }
    func takeChildMapping() throws -> (Int32, OwnedFileDescriptor) {
        try validate()
        mutex.lock(); defer { mutex.unlock() }
        guard !transferred else { throw CustodyRecordError.fenced }
        transferred = true
        return (Self.inheritedFD, child)
    }
    func retire() { parent.closeNow(); child.closeNow() }
    var retiredSuccessfully: Bool {
        parent.retirementObservation == .succeeded && child.retirementObservation == .succeeded
    }

    /// Only the original inherited endpoint can form this value. Authentication
    /// precedes parsing context, opening its root, or importing command leases.
    final class Inherited {
        private let socket: OwnedFileDescriptor
        private let peer: PublisherCodeVerifier.AuditPeerObservation
        private let code: PublisherCodeVerifier.Identity
        let request: SignedInstallationFixtureContext.Request
        let requestDigest: String
        private init(socket: OwnedFileDescriptor, peer: PublisherCodeVerifier.AuditPeerObservation,
                     code: PublisherCodeVerifier.Identity, request: SignedInstallationFixtureContext.Request,
                     requestDigest: String) {
            self.socket = socket; self.peer = peer; self.code = code
            self.request = request; self.requestDigest = requestDigest
        }
        static func consume() throws -> Inherited {
            let socket = OwnedFileDescriptor(inheritedFD)
            try InstallationPrecommitTransport.configure(socket.value)
            _ = try SignedInstallationFixtureParentChannel.capture(socket)
            let own = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make())
            guard own.executablePath.hasSuffix(LifecyclePublisher.relativeExecutable),
                  own.userID == geteuid(), getuid() == geteuid(), geteuid() != 0 else { throw CustodyRecordError.fenced }
            let (_, code) = try PublisherCodeVerifier.runningCode(path: own.executablePath,
                identifier: LifecyclePublisher.identifier, team: ReleaseIdentity.publisherTeamIdentifier)
            let peer = try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid())
            guard peer.pid == getppid(), peer.pid > 1 else { throw CustodyRecordError.fenced }
            // The bootstrap frame is already queued before successful spawn.
            // Never wait on unauthenticated caller-supplied deadlines.
            var reader = HostControlIO.FrameReader()
            let bytes = try reader.read(descriptor: socket.value, deadline: .init(seconds: 0.750))
            guard !reader.hasBufferedBytes else { throw CustodyRecordError.fenced }
            let wire = try CustodyWire.decode(bytes, maximum: 24_576)
            let fields = try wire.object(keys: ["schema", "request", "context"])
            guard try CustodyWire.text(fields["schema"]) == "shadow-sync-signed-installation-parent/v1",
                  try CustodyWire.encode(wire, maximum: 24_576) == bytes else { throw CustodyRecordError.fenced }
            let request = try SignedInstallationFixtureContext.Request.decode(
                CustodyWire.encode(CustodyWire.required(fields["context"]), maximum: 16_384))
            let digest = try CustodyWire.text(fields["request"])
            guard CustodyWire.hex(digest, bytes: 32),
                  own.executablePath == request.root + "/candidate/ShadowSync.app" + LifecyclePublisher.relativeExecutable else {
                throw CustodyRecordError.fenced
            }
            let result = Inherited(socket: socket, peer: peer, code: code, request: request, requestDigest: digest)
            try result.revalidate(); return result
        }
        func revalidate() throws {
            guard RuntimeSuiteGuardian.now < request.deadline, getppid() == peer.pid,
                  try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid()) == peer else {
                throw CustodyRecordError.fenced
            }
            try InstallationPrecommitTransport.requireQuiet(socket)
        }
        func authenticateParent(generation: String, executable: String) throws -> ProcessIdentity {
            try revalidate()
            let observation = try ProcessIdentity.capture(processID: peer.pid, generation: generation,
                expectedExecutablePath: executable)
            guard observation.userID == peer.uid else { throw CustodyRecordError.fenced }
            try revalidate(); return observation
        }
    }
}
#endif
