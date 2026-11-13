#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// One command's finite, sealed service protocol. The service host remains the
/// coordinator's child; this single-image target has no spawn or exec operation.
final class SignedInstallationFixtureAdapterChannel: @unchecked Sendable {
    static let inheritedFD: Int32 = 212
    enum Operation: String { case printState = "print", signature, bootstrap, kickstart, bootout }
    private let parent: OwnedFileDescriptor
    private let child: OwnedFileDescriptor
    private let context: SignedInstallationFixtureContext.Request
    private let digest: String
    private let originalDeadline: UInt64
    private let binding: InstallationCommandBinding
    private let operations: [Operation]
    private let service: SignedInstallationFixtureService
    private let lock = NSLock()
    private var work: InstallationFixtureWork?
    private var handed = false
    private var cancelled = false
    init(context: SignedInstallationFixtureContext.Request, digest: String, kind: CustodyCommandKind,
         arguments: [String], binding: InstallationCommandBinding, service: SignedInstallationFixtureService, deadline: UInt64) throws {
        guard CustodyWire.hex(digest, bytes: 32), let transaction = binding.control.transaction,
              transaction.coordinator.process.pid == UInt32(getpid()) else { throw CustodyRecordError.fenced }
        try binding.validate()
        let account = try binding.validationProfile.destinationAccount
        switch kind {
        case .launchctlRead:
            guard arguments == LifecycleLaunchCommand(operation: .kickstart, account: account).printArguments else { throw CustodyRecordError.fenced }
            operations = [.printState]
        case .signatureCheck:
            guard arguments == ["--verify", "--strict", "--verbose=2", account.homeDirectory + "/Applications/ShadowSync.app"] else { throw CustodyRecordError.fenced }
            operations = [.signature]
        case .launchctlMutation:
            let command = try LifecycleLaunchCommand(arguments: arguments, account: account)
            try binding.validateStagedOperation(mode: binding.stagedMode ?? .lifecycleMutation, operation: command.operation)
            guard let operation = Operation(rawValue: command.operation.rawValue) else { throw CustodyRecordError.fenced }
            operations = [.printState, operation, .printState]
        default: throw CustodyRecordError.fenced
        }
        originalDeadline = deadline
        self.context = context; self.digest = digest; self.binding = binding; self.service = service
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CustodyRecordError.persistence(errno) }
        let first = OwnedFileDescriptor(pair[0]), second = OwnedFileDescriptor(pair[1])
        parent = OwnedFileDescriptor(try first.duplicate(minimum: 214))
        child = OwnedFileDescriptor(try second.duplicate(minimum: 214))
        guard first.retireChecked() == .succeeded, second.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
        try InstallationPrecommitTransport.configure(parent.value)
        try InstallationPrecommitTransport.configure(child.value)
    }
    func start() throws {
        try service.enroll(self)
        lock.lock()
        guard work == nil, !cancelled else { lock.unlock(); throw CustodyRecordError.fenced }
        lock.unlock()
        // Root custody retains the work item before it is queued.
        let value = service.work { [self] in try serve() }
        lock.lock(); work = value; lock.unlock()
    }
    private func serve() throws {
        let deadline = MonotonicDeadline(uptimeNanoseconds: originalDeadline)
        var reader = HostControlIO.FrameReader()
        for (index, operation) in operations.enumerated() {
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped, !deadline.hasExpired else { throw CustodyRecordError.fenced }
            let fields: [String: PolicyWireValue] = [
                "schema": .string("shadow-sync-signed-installation-adapter/v1"),
                "request": .string(digest), "step": .unsigned(UInt64(index)), "operation": .string(operation.rawValue),
                "context": try CustodyWire.decode(context.bytes, maximum: 16_384),
                "coordinator": .unsigned(UInt64(binding.control.transaction!.coordinator.process.pid)),
                "deadline": .unsigned(originalDeadline),
                "transaction": .string(binding.control.transaction!.id),
                "binding": .string(try binding.control.bindingDigest()),
            ]
            try HostControlIO.writeFrame(CustodyWire.encode(.object(fields), maximum: 24_576), descriptor: parent.value, deadline: deadline)
            let challenge: PolicyWireValue = .object(["request": .string(digest), "step": .unsigned(UInt64(index)), "operation": .string(operation.rawValue)])
            let challengeBytes = try CustodyWire.encode(challenge, maximum: 4096)
            guard try reader.read(descriptor: parent.value, deadline: deadline) == challengeBytes,
                  !reader.hasBufferedBytes else { throw CustodyRecordError.fenced }
            let result = try service.perform(operation, binding: binding)
            guard result.stdout.count <= 4096, result.stderr.count <= 4096 else { throw CustodyRecordError.fenced }
            let response: PolicyWireValue = .object([
                "request": .string(digest), "step": .unsigned(UInt64(index)), "status": .unsigned(UInt64(result.status)),
                "stdout": .string(result.stdout.base64EncodedString()), "stderr": .string(result.stderr.base64EncodedString()),
            ])
            try HostControlIO.writeFrame(CustodyWire.encode(response, maximum: 16_000), descriptor: parent.value, deadline: deadline)
            guard try reader.read(descriptor: parent.value, deadline: deadline) == challengeBytes,
                  !reader.hasBufferedBytes else { throw CustodyRecordError.fenced }
        }
    }
    func takeChildMapping() throws -> (Int32, OwnedFileDescriptor) {
        lock.lock(); defer { lock.unlock() }
        guard work != nil, !handed, !cancelled else { throw CustodyRecordError.fenced }
        handed = true; return (Self.inheritedFD, child)
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        parent.interruptSocket()
    }
    func joinAndRetire(deadline: MonotonicDeadline) throws {
        lock.lock(); let work = self.work; lock.unlock()
        try work?.join(deadline: deadline)
        guard parent.retireChecked() == .succeeded, child.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
    }
    var retiredSuccessfully: Bool {
        parent.retirementObservation == .succeeded && child.retirementObservation == .succeeded
    }
    /// The helper retains the original endpoint across its finite stages. Each
    /// target receives one fixed copy; no arbitrary descriptor or role is used.
    final class Inherited {
        private let socket: OwnedFileDescriptor
        private let peer: PublisherCodeVerifier.AuditPeerObservation
        private let code: PublisherCodeVerifier.Identity
        private let parent: SignedInstallationFixtureParentChannel.Inherited
        init(parent: SignedInstallationFixtureParentChannel.Inherited, code: PublisherCodeVerifier.Identity) throws {
            self.parent = parent; self.code = code
            guard fcntl(inheritedFD, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.fenced }
            let original = OwnedFileDescriptor(inheritedFD)
            socket = OwnedFileDescriptor(try original.duplicate(minimum: 214))
            guard original.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            peer = try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid())
            guard peer.pid == getppid() else { throw CustodyRecordError.fenced }
            try parent.revalidate()
        }
        func appendTargetMapping(_ actions: inout posix_spawn_file_actions_t?) throws {
            try parent.revalidate()
            guard try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid()) == peer,
                  posix_spawn_file_actions_adddup2(&actions, socket.value, SelfFD.value) == 0 else { throw CustodyRecordError.fenced }
        }
        private enum SelfFD { static let value = SignedInstallationFixtureAdapterChannel.inheritedFD }
    }
}

enum SignedInstallationFixtureAdapterEntrypoint {
    static func dispatch(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--shadow-sync-signed-installation-adapter") else { return nil }
        guard arguments.count == 3, arguments[1] == "--shadow-sync-signed-installation-adapter",
              let operation = SignedInstallationFixtureAdapterChannel.Operation(rawValue: arguments[2]) else { return 64 }
        do {
            let fd = SignedInstallationFixtureAdapterChannel.inheritedFD
            let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0, size < 65_536 else { throw CustodyRecordError.fenced }
            var rows = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 32)
            let capacity = rows.count * MemoryLayout<proc_fdinfo>.stride
            let count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &rows, Int32(capacity))
            guard count > 0, count < capacity, Int(count) % MemoryLayout<proc_fdinfo>.stride == 0,
                  Set(rows.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd)) == [0, 1, 2, 198, fd] else { throw CustodyRecordError.fenced }
            guard fcntl(198, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.fenced }
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.fenced }
            let socket = OwnedFileDescriptor(fd)
            try InstallationPrecommitTransport.configure(fd)
            let own = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make())
            let (_, code) = try PublisherCodeVerifier.runningCode(path: own.executablePath,
                identifier: LifecyclePublisher.identifier, team: ReleaseIdentity.publisherTeamIdentifier)
            let peer = try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid())
            var reader = HostControlIO.FrameReader()
            let bytes = try reader.read(descriptor: fd, deadline: .init(seconds: 0.750))
            let wire = try CustodyWire.decode(bytes, maximum: 24_576)
            let fields = try wire.object(keys: ["schema", "request", "step", "operation", "context", "coordinator", "transaction", "binding", "deadline"])
            guard fields["schema"] == .string("shadow-sync-signed-installation-adapter/v1"),
                  fields["operation"] == .string(operation.rawValue), !reader.hasBufferedBytes,
                  try CustodyWire.encode(wire, maximum: 24_576) == bytes,
                  try CustodyWire.uint(fields["coordinator"]) == UInt64(peer.pid) else { throw CustodyRecordError.fenced }
            let context = try SignedInstallationFixtureContext.Request.decode(
                CustodyWire.encode(CustodyWire.required(fields["context"]), maximum: 16_384))
            guard own.executablePath == context.root + "/candidate/ShadowSync.app" + LifecyclePublisher.relativeExecutable,
                  RuntimeSuiteGuardian.now < context.deadline else { throw CustodyRecordError.fenced }
            let digest = try CustodyWire.text(fields["request"]), index = try CustodyWire.uint(fields["step"])
            guard CustodyWire.hex(digest, bytes: 32), index < 3,
                  RunIdentity.isValid(try CustodyWire.text(fields["transaction"])),
                  CustodyWire.hex(try CustodyWire.text(fields["binding"]), bytes: 32) else { throw CustodyRecordError.fenced }
            let limit = try CustodyWire.uint(fields["deadline"])
            guard limit <= context.deadline, RuntimeSuiteGuardian.now < limit else { throw CustodyRecordError.fenced }
            let deadline = MonotonicDeadline(uptimeNanoseconds: limit)
            let challenge = try CustodyWire.encode(.object(["request": .string(digest), "step": .unsigned(index), "operation": .string(operation.rawValue)]), maximum: 4096)
            guard try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid()) == peer else { throw CustodyRecordError.fenced }
            try HostControlIO.writeFrame(challenge, descriptor: fd, deadline: deadline)
            let responseBytes = try reader.read(descriptor: fd, deadline: deadline)
            let response = try CustodyWire.decode(responseBytes, maximum: 16_000)
            let result = try response.object(keys: ["request", "step", "status", "stdout", "stderr"])
            guard !reader.hasBufferedBytes, result["request"] == .string(digest), result["step"] == .unsigned(index),
                  try CustodyWire.encode(response, maximum: 16_000) == responseBytes,
                  try PublisherCodeVerifier.livePeer(socket: socket, expected: code, expectedUID: geteuid()) == peer,
                  let output = Data(base64Encoded: try CustodyWire.text(result["stdout"])),
                  let error = Data(base64Encoded: try CustodyWire.text(result["stderr"])), output.count <= 4096, error.count <= 4096 else { throw CustodyRecordError.fenced }
            let status = try CustodyWire.uint(result["status"])
            guard status == 0 || (operation == .printState && status == 113) else { throw CustodyRecordError.fenced }
            try write(output, to: STDOUT_FILENO, deadline: deadline)
            try write(error, to: STDERR_FILENO, deadline: deadline)
            try HostControlIO.writeFrame(challenge, descriptor: fd, deadline: deadline)
            guard socket.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            return Int32(status)
        } catch { return 78 }
    }
    private static func write(_ bytes: Data, to descriptor: Int32, deadline: MonotonicDeadline) throws {
        try bytes.withUnsafeBytes { value in
            var offset = 0
            while offset < value.count {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                let count = Darwin.write(descriptor, value.baseAddress!.advanced(by: offset), value.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && errno == EAGAIN { try HostControlIO.wait(descriptor, events: Int16(POLLOUT), deadline: deadline); continue }
                guard count > 0 else { throw CustodyRecordError.fenced }; offset += count
            }
        }
    }
}
#endif
