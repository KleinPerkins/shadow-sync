#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// The original coordinator owns the service host. An adapter command never
/// spawns a host or hands a descendant out of its qualified command graph.
final class SignedInstallationFixtureService: LaunchAgentControlling, InstalledHostControlling,
    SignedInstallationFixtureServiceCustody, @unchecked Sendable {
    private let context: SignedInstallationFixtureContext
    private let rootCustody: InstallationReadinessFixtureCustody
    private let runtime: RuntimeFixtureCustody
    private let lock = NSLock()
    private var working = false
    private var closing = false
    private var registered = false
    private var startAttempted = false
    private var anchor: OwnedSpawnAnchor?
    private var child: OwnedDirectChild?
    private var hostChannel: SignedInstallationFixtureHostChannel?
    private var streams: Streams?
    private var handoffs: [SignedInstallationFixtureAdapterChannel] = []
    init(context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody) throws {
        try context.revalidate()
        self.context = context; rootCustody = custody
        runtime = try RuntimeFixtureSession.current()
    }
    func enroll(_ channel: SignedInstallationFixtureAdapterChannel) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw CustodyRecordError.fenced }
        handoffs.append(channel)
    }
    func work(_ body: @escaping @Sendable () throws -> Void) -> InstallationFixtureWork {
        rootCustody.startWork(body)
    }
    private func turn<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        guard !working, !closing else { lock.unlock(); throw CustodyRecordError.busy }
        working = true; lock.unlock()
        defer { lock.lock(); working = false; lock.unlock() }
        try context.revalidate()
        let value = try body()
        try context.revalidate()
        lock.lock(); let admitted = !closing; lock.unlock()
        guard admitted else { throw CustodyRecordError.fenced }
        return value
    }
    struct Reply {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }
    func perform(_ operation: SignedInstallationFixtureAdapterChannel.Operation,
                 binding: InstallationCommandBinding) throws -> Reply {
        try turn {
            guard binding.validationProfile == context.profile else { throw CustodyRecordError.fenced }
            try binding.validate()
            switch operation {
            case .printState:
                return try diagnostic()
            case .signature:
                let artifact = try context.profile.inspectBundle(context.paths.app)
                guard let candidate = binding.control.transaction?.candidate,
                      artifact.release == candidate.release, artifact.canonicalSHA256 == candidate.bundleDigest else { throw CustodyRecordError.fenced }
            case .bootstrap:
                try binding.validateStagedOperation(mode: .installationStagedStart, operation: .bootstrap)
                guard !registered, !startAttempted, child == nil else { throw CustodyRecordError.fenced }
                registered = true
            case .kickstart:
                try binding.validateStagedOperation(mode: .installationStagedStart, operation: .kickstart)
                guard registered, !startAttempted, child == nil else { throw CustodyRecordError.fenced }
                startAttempted = true
                try launch(binding)
            case .bootout:
                try binding.validateStagedOperation(mode: .installationStagedStop, operation: .bootout)
                guard registered else { throw CustodyRecordError.fenced }
                // A stopped acknowledgment is not a reap. Only the original
                // direct-child owner and real EOF can retire this service.
                if let child, let streams {
                    guard streams.drained(), case .reaped = child.reapAfterGroupDrain(streamsDrained: true) else { throw CustodyRecordError.busy }
                }
                registered = false
            }
            return Reply(status: 0, stdout: Data(), stderr: Data())
        }
    }
    private func diagnostic() throws -> Reply {
        let account = try context.destinationAccount
        guard registered else {
            return Reply(status: 113, stdout: Data(), stderr: Data("Bad request.\nCould not find service \"\(InstallationPaths.label)\" in domain for user gui: \(account.uid)\n".utf8))
        }
        var processLine = ""
        if let child {
            guard child.observation == .running,
                  child.identity.isCurrent(expectedGeneration: child.identity.generation) else { throw CustodyRecordError.fenced }
            processLine = "\tpid = \(child.identity.processID)\n"
        }
        let command = LifecycleLaunchCommand(operation: .kickstart, account: account)
        // Every dynamic value comes from this retained registration and original
        // child; this is the closed parser's format, not launchd qualification.
        let text = "\(command.service) = {\n\tpath = \(context.paths.launchAgent)\n\ttype = LaunchAgent\n\tprogram = \(context.paths.executable)\n\targuments = {\n\t\t\(context.paths.executable)\n\t\t\(InstallationPaths.managedHostArgument)\n\t}\n\(processLine)}\n"
        return Reply(status: 0, stdout: Data(text.utf8), stderr: Data())
    }
    private final class Streams: @unchecked Sendable {
        let output: CustodyPipe, error: CustodyPipe
        private let lock = NSLock()
        private var outputEnded = false, errorEnded = false, failure = false
        private var outputSource: OwnedFileDescriptor?, errorSource: OwnedFileDescriptor?
        func takeOutput() throws -> OwnedFileDescriptor {
            let value = try output.take(writing: true); outputSource = value; return value
        }
        func takeError() throws -> OwnedFileDescriptor {
            let value = try error.take(writing: true); errorSource = value; return value
        }
        init() throws { output = try CustodyPipe(); error = try CustodyPipe() }
        func drained() -> Bool {
            lock.lock(); defer { lock.unlock() }
            // Bounded nonblocking reads. The real pipe EOF, never elapsed time,
            // determines drainage. Payload is not interpreted as authority.
            for (pipe, isError) in [(output, false), (error, true)] {
                if isError ? errorEnded : outputEnded { continue }
                do {
                    for _ in 0..<16 {
                        switch try pipe.read(maximum: 16_384) {
                        case .end: if isError { errorEnded = true } else { outputEnded = true }
                        case .bytes: continue
                        case .wouldBlock: break
                        }
                        break
                    }
                } catch { failure = true }
            }
            return !failure && outputEnded && errorEnded
        }
        func closeWriters() { outputSource?.closeNow(); errorSource?.closeNow(); output.closeWriter(); error.closeWriter() }
        func retire() throws {
            guard drained() else { throw CustodyRecordError.busy }
            output.closeAll(); error.closeAll()
            guard output.retiredSuccessfully, error.retiredSuccessfully else { throw CustodyRecordError.fenced }
        }
    }
    private func launch(_ binding: InstallationCommandBinding) throws {
        guard case let .signedFixture(profile) = context.profile else { throw CustodyRecordError.fenced }
        let channel = try profile.makeHostChannel(binding: binding)
        hostChannel = channel
        let streams = try Streams(); self.streams = streams
        defer { streams.closeWriters() }
        let out = try streams.takeOutput(), err = try streams.takeError()
        let mapping = try channel.takeChildMapping()
        let home = try context.retainHostHome()
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CustodyRecordError.fenced }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CustodyRecordError.fenced }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, out.value, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, err.value, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addfchdir(&actions, home.value) == 0,
              posix_spawn_file_actions_adddup2(&actions, mapping.1.value, mapping.0) == 0 else { throw CustodyRecordError.fenced }
        var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigemptyset(&defaults)
        for value in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, value) }
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        guard posix_spawnattr_setflags(&attributes, flags) == 0, posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &empty) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { throw CustodyRecordError.fenced }
        let account = try context.destinationAccount
        let values = ClosedProcessRunner.environment(account: account)
        let allocated = [context.paths.executable, InstallationPaths.managedHostArgument].map { strdup($0) }
        let environment = values.keys.sorted().map { strdup($0 + "=" + values[$0]!) }
        defer { (allocated + environment).forEach { free($0) } }
        guard (allocated + environment).allSatisfy({ $0 != nil }) else { throw CustodyRecordError.fenced }
        var argv = allocated + [nil], env = environment + [nil]
        try context.revalidate()
        let spawned = try argv.withUnsafeMutableBufferPointer { a in try env.withUnsafeMutableBufferPointer { e in
            try RuntimeFixtureSpawn.spawn(registry: runtime, executable: context.paths.executable,
                actions: &actions, attributes: &attributes, arguments: a.baseAddress, environment: e.baseAddress,
                streamsDrained: { streams.drained() })
        } }
        anchor = spawned
        try channel.retireChildAfterSpawn()
        let (_, code) = try PublisherCodeVerifier.verifiedStatic(path: context.paths.app,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
        try PublisherCodeVerifier.suspendedChild(spawned.processID, expected: code)
        let owned = try spawned.transfer(expectedExecutable: context.paths.executable,
            generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
        child = owned
        try context.revalidate()
        guard owned.resume(before: context.deadline), owned.identity.isCurrent(expectedGeneration: owned.identity.generation) else { throw CustodyRecordError.fenced }
    }
    func requireSuccessfulHostExit(deadline: MonotonicDeadline) throws {
        try turn {
            guard let child, let streams else { throw CustodyRecordError.fenced }
            while !deadline.hasExpired {
                let drained = streams.drained()
                switch child.reapAfterGroupDrain(streamsDrained: drained) {
                case .reaped(let raw):
                    guard drained, raw == 0 else { throw CustodyRecordError.fenced }; return
                case .ownershipFailure: throw CustodyRecordError.fenced
                case .running: Thread.sleep(forTimeInterval: 0.005)
                }
            }
            throw CustodyRecordError.busy
        }
    }
    func closeFixtureService(deadline: MonotonicDeadline) throws {
        lock.lock(); closing = true; let channels = handoffs, busy = working; lock.unlock()
        for channel in channels { channel.cancel() }
        guard !busy else { throw CustodyRecordError.busy }
        if let anchor {
            anchor.testingRequestRuntimeDrain()
            guard anchor.testingRuntimeRetired else { throw CustodyRecordError.busy }
        }
        for channel in channels { try channel.joinAndRetire(deadline: deadline) }
        if let streams { try streams.retire() }
        try hostChannel?.retireAfterHostReaped()
    }
    // These protocol methods support retained slot observation only. Mutations
    // are possible exclusively through the sealed command handoff above.
    func state(label: String) -> LaunchAgentState {
        guard label == InstallationPaths.label else { return .queryFailure }
        do { return try turn {
            guard registered else { return .absent }
            if let child {
                guard child.identity.isCurrent(expectedGeneration: child.identity.generation) else { return .queryFailure }
                return .loaded(program: context.paths.executable, processID: child.identity.processID)
            }
            return .loaded(program: context.paths.executable, processID: nil)
        } } catch { return .queryFailure }
    }
    func processDisposition(processID: pid_t, expectedProgram: String) -> LaunchAgentProcessDisposition {
        do { return try turn {
            guard let child, child.identity.processID == processID, expectedProgram == context.paths.executable else { return .mismatch }
            return child.identity.isCurrent(expectedGeneration: child.identity.generation) ? .matching : .absent
        } } catch { return .mismatch }
    }
    func bootstrap(label: String, plist: String, expectedProgram: String) throws { throw CustodyRecordError.fenced }
    func kickstart(label: String, expectedProgram: String) throws { throw CustodyRecordError.fenced }
    func bootout(label: String, expectedProgram: String) throws { throw CustodyRecordError.fenced }
    func requestExit(location: StateLocation, executable: String, release: ReleaseIdentity) throws {
        guard location == context.paths.state, executable == context.paths.executable, release == context.source.candidate.release else { throw CustodyRecordError.fenced }
        _ = try HostControlClient.requestLifecycleExit(at: location, expectedExecutablePath: executable, expectedRelease: release)
    }
    func isReady(location: StateLocation, executable: String, release: ReleaseIdentity, timeout: TimeInterval) -> Bool {
        readyIdentity(location: location, executable: executable, release: release, timeout: timeout) != nil
    }
    func readyIdentity(location: StateLocation, executable: String, release: ReleaseIdentity, timeout: TimeInterval) -> ProcessIdentity? {
        guard location == context.paths.state, executable == context.paths.executable, release == context.source.candidate.release,
              let value = try? HostControlClient.readiness(at: location, expectedExecutablePath: executable, expectedRelease: release) else { return nil }
        return (try? turn { child?.identity == value ? value : nil }) ?? nil
    }
}
#endif
