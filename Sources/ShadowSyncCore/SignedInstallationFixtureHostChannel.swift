#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// Direct coordinator-to-host bootstrap only. It carries no ready/started/stop
/// result. Those observations still require the installation session. The host
/// authenticates its real direct parent with kernel/Security evidence before it
/// reads context or opens the isolated root. FD 213 is disjoint from helper and
/// adapter roles; native socketpair token behavior remains unqualified.
final class SignedInstallationFixtureHostChannel {
    static let inheritedFD: Int32 = 213
    private let parent: OwnedFileDescriptor
    private let child: OwnedFileDescriptor
    private var handed = false
    init(request: SignedInstallationFixtureContext.Request, binding: InstallationCommandBinding) throws {
        try binding.validateStagedOperation(mode: .installationStagedStart, operation: .kickstart)
        guard let transaction = binding.control.transaction,
              transaction.coordinator.process.pid == UInt32(getpid()),
              RuntimeSuiteGuardian.now < request.deadline else { throw CustodyRecordError.fenced }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CustodyRecordError.persistence(errno) }
        let first = OwnedFileDescriptor(pair[0]), second = OwnedFileDescriptor(pair[1])
        parent = OwnedFileDescriptor(try first.duplicate(minimum: 214))
        child = OwnedFileDescriptor(try second.duplicate(minimum: 214))
        guard first.retireChecked() == .succeeded, second.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
        try InstallationPrecommitTransport.configure(parent.value)
        try InstallationPrecommitTransport.configure(child.value)
        let frame = try CustodyWire.encode(.object([
            "schema": .string("shadow-sync-signed-installation-host/v1"),
            "context": try CustodyWire.decode(request.bytes, maximum: 16_384),
            "transaction": .string(transaction.id),
            "binding": .string(try binding.control.bindingDigest()),
        ]), maximum: 24_576)
        try HostControlIO.writeFrame(frame, descriptor: parent.value,
            deadline: .init(uptimeNanoseconds: request.deadline))
    }
    func takeChildMapping() throws -> (Int32, OwnedFileDescriptor) {
        guard !handed else { throw CustodyRecordError.fenced }
        handed = true; return (Self.inheritedFD, child)
    }
    func retireChildAfterSpawn() throws {
        guard handed, child.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
    }
    /// Invoked only after the actual child owner has joined/reaped. Closing this
    /// bootstrap socket is never reported as host or installation retirement.
    func retireAfterHostReaped() throws {
        guard child.retireChecked() == .succeeded, parent.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
    }
    final class Inherited {
        private let socket: OwnedFileDescriptor
        private let peer: PublisherCodeVerifier.AuditPeerObservation
        private let code: PublisherCodeVerifier.Identity
        let request: SignedInstallationFixtureContext.Request
        let transactionID: String
        let bindingDigest: String
        private init(socket: OwnedFileDescriptor, peer: PublisherCodeVerifier.AuditPeerObservation,
                     code: PublisherCodeVerifier.Identity, request: SignedInstallationFixtureContext.Request,
                     transactionID: String, bindingDigest: String) {
            self.socket = socket; self.peer = peer; self.code = code; self.request = request
            self.transactionID = transactionID; self.bindingDigest = bindingDigest
        }
        static func consume() throws -> Inherited {
            let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0, size < 65_536 else { throw CustodyRecordError.fenced }
            var rows = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 32)
            let capacity = rows.count * MemoryLayout<proc_fdinfo>.stride
            let count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &rows, Int32(capacity))
            guard count > 0, count < capacity, Int(count) % MemoryLayout<proc_fdinfo>.stride == 0,
                  Set(rows.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd)) == [0, 1, 2, inheritedFD] else {
                throw CustodyRecordError.fenced
            }
            guard fcntl(inheritedFD, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.fenced }
            let socket = OwnedFileDescriptor(inheritedFD)
            var node = stat(), kind: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard fstat(socket.value, &node) == 0, node.st_mode & S_IFMT == S_IFSOCK,
                  node.st_uid == geteuid(), getuid() == geteuid(), geteuid() != 0,
                  getsockopt(socket.value, SOL_SOCKET, SO_TYPE, &kind, &length) == 0,
                  length == MemoryLayout<Int32>.size, kind == SOCK_STREAM else { throw CustodyRecordError.fenced }
            try InstallationPrecommitTransport.configure(socket.value)
            let appPath = Bundle.main.bundleURL.path
            let (_, app) = try PublisherCodeVerifier.runningApplication(path: appPath)
            let (_, helper) = try PublisherCodeVerifier.verifiedStatic(path: appPath + LifecyclePublisher.relativeExecutable,
                identifier: LifecyclePublisher.identifier, team: app.team)
            let peer = try PublisherCodeVerifier.livePeer(socket: socket, expected: helper, expectedUID: geteuid())
            guard peer.pid == getppid(), peer.pid > 1 else { throw CustodyRecordError.fenced }
            var reader = HostControlIO.FrameReader()
            let bytes = try reader.read(descriptor: socket.value, deadline: .init(seconds: 0.750))
            let wire = try CustodyWire.decode(bytes, maximum: 24_576)
            let fields = try wire.object(keys: ["schema", "context", "transaction", "binding"])
            guard !reader.hasBufferedBytes, fields["schema"] == .string("shadow-sync-signed-installation-host/v1"),
                  try CustodyWire.encode(wire, maximum: 24_576) == bytes else { throw CustodyRecordError.fenced }
            let request = try SignedInstallationFixtureContext.Request.decode(
                CustodyWire.encode(CustodyWire.required(fields["context"]), maximum: 16_384))
            let transaction = try CustodyWire.text(fields["transaction"]), binding = try CustodyWire.text(fields["binding"])
            guard RunIdentity.isValid(transaction), CustodyWire.hex(binding, bytes: 32),
                  appPath == request.root + "/home/Applications/ShadowSync.app" else { throw CustodyRecordError.fenced }
            let result = Inherited(socket: socket, peer: peer, code: helper, request: request,
                transactionID: transaction, bindingDigest: binding)
            try result.revalidate(); return result
        }
        func revalidate() throws {
            guard RuntimeSuiteGuardian.now < request.deadline, getppid() == peer.pid,
                  try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid()) == peer else {
                throw CustodyRecordError.fenced
            }
            try InstallationPrecommitTransport.requireQuiet(socket)
        }
        func validate(_ control: InstallationControlRecord) throws {
            try revalidate()
            guard control.transaction?.id == transactionID, try control.bindingDigest() == bindingDigest,
                  control.transaction?.coordinator.process.pid == UInt32(peer.pid) else { throw CustodyRecordError.fenced }
            // PID consistency is checked only after kernel-token authentication.
            guard let process = control.transaction?.coordinator.process else { throw CustodyRecordError.fenced }
            let actual = try ProcessIdentity.capture(processID: peer.pid, generation: process.generation,
                expectedExecutablePath: request.root + "/candidate/ShadowSync.app" + LifecyclePublisher.relativeExecutable)
            guard actual.startSeconds == process.startSeconds, actual.startMicroseconds == process.startMicroseconds,
                  actual.userID == process.uid else { throw CustodyRecordError.fenced }
            try revalidate()
        }
    }
}
#endif
