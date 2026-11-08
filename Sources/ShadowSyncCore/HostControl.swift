import Darwin
import Foundation

private enum HostControlTiming {
    static let requestTimeout: TimeInterval = 1
    static let maximumFrameBytes = 16_384
}

public struct HostControlRequest: Codable, Equatable, Sendable {
    public static let schemaName = "shadow-sync-host-request/v1"
    public let schema: String
    public let action: HostControlAction
    public let expectedGeneration: String
    public let nonce: String

    public init(
        action: HostControlAction = .activate,
        expectedGeneration: String,
        nonce: String = RunIdentity.make()
    ) {
        schema = Self.schemaName
        self.action = action
        self.expectedGeneration = expectedGeneration
        self.nonce = nonce
    }
}

public struct HostControlResponse: Codable, Equatable, Sendable {
    public static let schemaName = "shadow-sync-host-response/v1"
    public let schema: String
    public let generation: String
    public let nonce: String
    public let accepted: Bool
    public let release: ReleaseIdentity?

    public init(
        generation: String,
        nonce: String,
        accepted: Bool,
        release: ReleaseIdentity? = nil
    ) {
        schema = Self.schemaName
        self.generation = generation
        self.nonce = nonce
        self.accepted = accepted
        self.release = release
    }
}

public enum HostControlAction: String, Codable, Equatable, Sendable {
    case activate
    case readiness
    case lifecycleExit
}

public final class HostControlServer: @unchecked Sendable {
    private static let socketName = "host.sock"
    private let authority: LauncherAuthority
    private let registration: HostRegistration
    private let onActivation: @Sendable () -> Bool
    private let onLifecycleExit: @Sendable () -> Bool
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    private var ownsEndpoint = false
    private var thread: Thread?
#if SHADOW_SYNC_TESTING
    // Installed only before start; the server thread never replaces this owner.
    private var rejectionObservation: M4HostRejectionObservation?

    func observeM4Rejections(_ observation: M4HostRejectionObservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0, thread == nil, !stopped,
              rejectionObservation == nil else { return false }
        rejectionObservation = observation
        return true
    }
#endif

    public init(
        authority: LauncherAuthority,
        executablePath: String,
        releaseIdentity: ReleaseIdentity? = nil,
        generation: String = RunIdentity.make(),
        onActivation: @escaping @Sendable () -> Bool,
        onLifecycleExit: @escaping @Sendable () -> Bool = { false }
    ) throws {
        self.authority = authority
        registration = HostRegistration(
            identity: try ProcessIdentity.capture(
                processID: getpid(),
                generation: generation,
                expectedExecutablePath: executablePath
            ),
            release: releaseIdentity
        )
        self.onActivation = onActivation
        self.onLifecycleExit = onLifecycleExit
    }

    public func start() throws {
        let state = authority.stateDirectory
        try removeStaleSocket(state: state)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall("socket host control", errno)
        }
        do {
            try bindSocket(descriptor, path: socketPath(state: state))
            guard listen(descriptor, 4) == 0 else {
                throw SecureStateError.systemCall("listen host control", errno)
            }
            try HostRegistrationStore.write(registration, state: state)
        } catch {
            close(descriptor)
            _ = unlink(socketPath(state: state))
            throw error
        }
        lock.lock()
        listener = descriptor
        ownsEndpoint = true
        let thread = Thread { [weak self] in self?.serve() }
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let descriptor = listener
        let removeEndpoint = ownsEndpoint
        listener = -1
        ownsEndpoint = false
        lock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        if removeEndpoint {
            _ = unlink(socketPath(state: authority.stateDirectory))
            try? HostRegistrationStore.remove(state: authority.stateDirectory)
        }
        authority.release()
    }

    private func serve() {
        while true {
            lock.lock()
            let descriptor = listener
            let shouldStop = stopped
            lock.unlock()
            guard !shouldStop, descriptor >= 0 else {
                return
            }
            let peer = accept(descriptor, nil, nil)
            if peer < 0 {
                if errno == EINTR { continue }
                return
            }
#if SHADOW_SYNC_TESTING
            let observedConnection = rejectionObservation?.acceptedConnection()
#endif
            handle(peer)
#if SHADOW_SYNC_TESTING
            rejectionObservation?.completedConnection(observedConnection)
#endif
            close(peer)
        }
    }

    private func handle(_ peer: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
#if SHADOW_SYNC_TESTING
        rejectionObservation?.entered(.peerIdentity)
#endif
        guard getpeereid(peer, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
#if SHADOW_SYNC_TESTING
            rejectionObservation?.rejected()
#endif
            return
        }
        try? HostControlIO.makeNonblocking(peer)
        let request: HostControlRequest
        do {
#if SHADOW_SYNC_TESTING
            if let rejectionObservation {
                request = try HostControlIO.readM4Observed(
                    HostControlRequest.self, descriptor: peer,
                    observation: rejectionObservation
                )
            } else {
                request = try HostControlIO.read(
                    HostControlRequest.self, descriptor: peer
                )
            }
#else
            request = try HostControlIO.read(
                HostControlRequest.self,
                descriptor: peer
            )
#endif
        } catch {
#if SHADOW_SYNC_TESTING
            rejectionObservation?.rejected()
#endif
            try? reject(peer, nonce: RunIdentity.make())
            return
        }
#if SHADOW_SYNC_TESTING
        rejectionObservation?.entered(.requestValidation)
#endif
        guard
              request.schema == HostControlRequest.schemaName,
              request.expectedGeneration == registration.identity.generation,
              RunIdentity.isValid(request.nonce),
              registration.isValid else {
#if SHADOW_SYNC_TESTING
            rejectionObservation?.rejected()
#endif
            try? reject(peer, nonce: request.nonce)
            return
        }
        let accepted: Bool
        switch request.action {
        case .activate:
            accepted = onActivation()
        case .readiness:
            accepted = true
        case .lifecycleExit:
            accepted = onLifecycleExit()
        }
        try? HostControlIO.write(
            HostControlResponse(
                generation: registration.identity.generation,
                nonce: request.nonce,
                accepted: accepted,
                release: registration.release
            ),
            descriptor: peer
        )
    }

    private func reject(_ peer: Int32, nonce: String) throws {
        try HostControlIO.write(
            HostControlResponse(
                generation: registration.identity.generation,
                nonce: RunIdentity.isValid(nonce) ? nonce : RunIdentity.make(),
                accepted: false,
                release: registration.release
            ),
            descriptor: peer
        )
    }

    private func removeStaleSocket(state: SecureStateDirectory) throws {
        var info = stat()
        let result = fstatat(
            state.descriptor.value,
            Self.socketName,
            &info,
            AT_SYMLINK_NOFOLLOW
        )
        if result != 0 {
            guard errno == ENOENT else {
                throw SecureStateError.systemCall("inspect host socket", errno)
            }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == state.uid else {
            throw ProcessOwnershipError.unsafeSocket
        }
        guard try staleSocketIsUnreachable(
            path: socketPath(state: state)
        ) else {
            throw ProcessOwnershipError.unsafeSocket
        }
        guard unlinkat(state.descriptor.value, Self.socketName, 0) == 0 else {
            throw SecureStateError.systemCall("remove stale host socket", errno)
        }
    }

    private func staleSocketIsUnreachable(path: String) throws -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall("socket stale host probe", errno)
        }
        defer { close(descriptor) }
        try HostControlIO.makeNonblocking(descriptor)
        var address = try HostControlIO.address(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 {
            return false
        }
        if errno == ECONNREFUSED || errno == ENOENT {
            return true
        }
        guard errno == EINPROGRESS || errno == EAGAIN else {
            throw ProcessOwnershipError.unsafeSocket
        }
        do {
            try HostControlIO.wait(
                descriptor,
                events: Int16(POLLOUT),
                deadline: MonotonicDeadline(seconds: 0.1)
            )
        } catch {
            throw ProcessOwnershipError.unsafeSocket
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0 else {
            throw ProcessOwnershipError.unsafeSocket
        }
        if socketError == ECONNREFUSED || socketError == ENOENT {
            return true
        }
        guard socketError == 0 else {
            throw ProcessOwnershipError.unsafeSocket
        }
        return false
    }

    private func bindSocket(_ descriptor: Int32, path: String) throws {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ProcessOwnershipError.unsafeSocket
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let code = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard code == 0 else {
            throw SecureStateError.systemCall("bind host control", errno)
        }
        guard chmod(path, 0o600) == 0 else {
            throw SecureStateError.systemCall("chmod host control", errno)
        }
    }

    private func socketPath(state: SecureStateDirectory) -> String {
        URL(fileURLWithPath: state.path).appendingPathComponent(Self.socketName).path
    }

    deinit {
        stop()
    }
}

public enum HostControlClient {
    public static func activate(at location: StateLocation) throws {
        _ = try request(.activate, at: location)
    }

    public static func readiness(
        at location: StateLocation,
        expectedExecutablePath: String,
        expectedRelease: ReleaseIdentity
    ) throws -> ProcessIdentity {
        let (identity, release) = try request(.readiness, at: location)
        guard identity.executablePath == expectedExecutablePath
                || (
                    URL(fileURLWithPath: identity.executablePath).resolvingSymlinksInPath().path
                        == URL(fileURLWithPath: expectedExecutablePath).resolvingSymlinksInPath().path
                ) else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        guard release == expectedRelease else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        return identity
    }

    public static func requestLifecycleExit(
        at location: StateLocation,
        expectedExecutablePath: String,
        expectedRelease: ReleaseIdentity
    ) throws -> ProcessIdentity {
        let (identity, release) = try request(.lifecycleExit, at: location)
        guard identity.executablePath == expectedExecutablePath
                || URL(fileURLWithPath: identity.executablePath)
                    .resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: expectedExecutablePath)
                    .resolvingSymlinksInPath().path,
              release == expectedRelease else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        return identity
    }

    private static func request(
        _ action: HostControlAction,
        at location: StateLocation
    ) throws -> (ProcessIdentity, ReleaseIdentity?) {
        let state = try SecureStateDirectory.openExisting(location)
        let registration = try HostRegistrationStore.read(state: state)
        guard registration.isValid else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall("socket activation client", errno)
        }
        defer { close(descriptor) }
        try HostControlIO.makeNonblocking(descriptor)
        try connectSocket(
            descriptor,
            path: URL(fileURLWithPath: state.path)
                .appendingPathComponent("host.sock").path
        )
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerPID,
            &peerPIDLength
        ) == 0,
              peerPID == registration.identity.processID else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        let request = HostControlRequest(
            action: action,
            expectedGeneration: registration.identity.generation
        )
        try HostControlIO.write(request, descriptor: descriptor)
        let response = try HostControlIO.read(
            HostControlResponse.self,
            descriptor: descriptor
        )
        guard response.schema == HostControlResponse.schemaName,
              response.accepted,
              response.generation == registration.identity.generation,
              response.nonce == request.nonce,
              response.release == registration.release,
              registration.isValid else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        return (registration.identity, response.release)
    }

    private static func connectSocket(_ descriptor: Int32, path: String) throws {
        var address = try HostControlIO.address(path: path)
        let code = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if code == 0 {
            return
        }
        guard errno == EINPROGRESS || errno == EAGAIN else {
            throw SecureStateError.systemCall("connect host control", errno)
        }
        try HostControlIO.wait(
            descriptor,
            events: Int16(POLLOUT),
            deadline: MonotonicDeadline(seconds: HostControlTiming.requestTimeout)
        )
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0 else {
            throw SecureStateError.systemCall("inspect host connection", errno)
        }
        guard socketError == 0 else {
            throw SecureStateError.systemCall("connect host control", socketError)
        }
    }
}

/// Socket mechanics only. Installation callers must authenticate the retained
/// peer and supply the SAME absolute session deadline for every frame.
enum HostControlIO {
    static let maximumFrameBytes = HostControlTiming.maximumFrameBytes
    static func address(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ProcessOwnershipError.unsafeSocket
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return address
    }

    static func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SecureStateError.systemCall("configure host control", errno)
        }
    }

    static func write<T: Encodable>(
        _ value: T,
        descriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let deadline = MonotonicDeadline(seconds: HostControlTiming.requestTimeout)
        try writeFrame(encoder.encode(value), descriptor: descriptor, deadline: deadline)
    }

    static func writeFrame(_ payload: Data, descriptor: Int32,
                           deadline: MonotonicDeadline) throws {
        try requireNonblocking(descriptor)
        guard !payload.isEmpty, payload.count < maximumFrameBytes,
              !payload.contains(0x0A) else {
            throw SecureStateError.unsafePath("host control frame")
        }
        var data = payload
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                try requireTime(deadline)
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                throw SecureStateError.systemCall(
                    "write host control",
                    count == 0 ? EPIPE : errno
                )
            }
        }
        try requireTime(deadline)
    }

    static func read<T: Decodable>(
        _ type: T.Type,
        descriptor: Int32
    ) throws -> T {
        let deadline = MonotonicDeadline(seconds: HostControlTiming.requestTimeout)
        var reader = FrameReader()
        let data = try reader.read(descriptor: descriptor, deadline: deadline)
        // Existing activation requests remain one frame per connection. The
        // installation session retains its own reader across multiple frames.
        guard !reader.hasBufferedBytes else {
            throw SecureStateError.unsafePath("host control frame")
        }
        return try JSONDecoder().decode(type, from: data)
    }

#if SHADOW_SYNC_TESTING
    // Same read/decode operations as read(_:descriptor:); only this fixture's
    // original server supplies an observation. No new frame or wire field.
    static func readM4Observed<T: Decodable>(
        _ type: T.Type, descriptor: Int32,
        observation: M4HostRejectionObservation
    ) throws -> T {
        let deadline = MonotonicDeadline(seconds: HostControlTiming.requestTimeout)
        var reader = FrameReader()
        reader.m4Observation = observation
        let data = try reader.read(descriptor: descriptor, deadline: deadline)
        observation.entered(.extraBufferedBytes)
        guard !reader.hasBufferedBytes else {
            throw SecureStateError.unsafePath("host control frame")
        }
        observation.entered(.decode)
        return try JSONDecoder().decode(type, from: data)
    }
#endif

    struct FrameReader {
        private var buffered = Data()
#if SHADOW_SYNC_TESTING
        var m4Observation: M4HostRejectionObservation?
#endif
        var hasBufferedBytes: Bool { !buffered.isEmpty }

        mutating func read(descriptor: Int32, deadline: MonotonicDeadline) throws -> Data {
#if SHADOW_SYNC_TESTING
            m4Observation?.entered(.nonblocking)
#endif
            try HostControlIO.requireNonblocking(descriptor)
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while true {
                // Buffered data does not renew the shared session budget.
#if SHADOW_SYNC_TESTING
                m4Observation?.entered(.deadline, bytes: buffered.count)
#endif
                try HostControlIO.requireTime(deadline)
                if let newline = buffered.firstIndex(of: 0x0A) {
                    let length = buffered.distance(from: buffered.startIndex, to: newline)
#if SHADOW_SYNC_TESTING
                    m4Observation?.entered(.newlineBounds)
#endif
                    guard length > 0, length < HostControlIO.maximumFrameBytes else {
                        throw SecureStateError.unsafePath("host control frame")
                    }
                    let frame = Data(buffered[..<newline])
                    buffered.removeSubrange(...newline)
                    return frame
                }
#if SHADOW_SYNC_TESTING
                m4Observation?.entered(.frameLimit)
#endif
                guard buffered.count < HostControlIO.maximumFrameBytes else {
                    throw SecureStateError.unsafePath("host control frame")
                }
                // At most one bounded frame plus one fixed read chunk is held.
#if SHADOW_SYNC_TESTING
                m4Observation?.entered(.wait)
#endif
                try HostControlIO.wait(descriptor, events: Int16(POLLIN | POLLHUP), deadline: deadline)
#if SHADOW_SYNC_TESTING
                m4Observation?.entered(.read)
#endif
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 { buffered.append(contentsOf: bytes.prefix(count)); continue }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if count == 0 { throw SecureStateError.systemCall("read host control", ECONNRESET) }
                throw SecureStateError.systemCall("read host control", errno)
            }
        }
    }

    private static func requireNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw SecureStateError.systemCall("inspect host control", errno)
        }
        guard flags & O_NONBLOCK != 0 else {
            throw SecureStateError.unsafePath("blocking host control descriptor")
        }
    }

    private static func requireTime(_ deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired else {
            throw SecureStateError.systemCall("host control timeout", ETIMEDOUT)
        }
    }

    static func wait(
        _ descriptor: Int32,
        events: Int16,
        deadline: MonotonicDeadline
    ) throws {
        while true {
            let remaining = deadline.remainingMilliseconds
            guard remaining > 0 else {
                throw SecureStateError.systemCall("host control timeout", ETIMEDOUT)
            }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, remaining)
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else {
                    throw SecureStateError.systemCall("poll host control", EBADF)
                }
                return
            }
            if result < 0, errno == EINTR {
                continue
            }
            if result == 0 {
                throw SecureStateError.systemCall("host control timeout", ETIMEDOUT)
            }
            throw SecureStateError.systemCall("poll host control", errno)
        }
    }
}
