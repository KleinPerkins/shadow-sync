import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public enum OutputDisposition: Equatable, Sendable {
        case complete
        case stdoutExceededBound
        case stderrExceededBound
        case stdoutAndStderrExceededBound
    }

    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let outputByteLimit: Int
    public let timedOut: Bool
    public let cancelled: Bool
    public let terminationRequested: Bool
    public let processID: pid_t

    public var exitedSuccessfully: Bool {
        status == 0
    }

    public var succeeded: Bool {
        exitedSuccessfully
            && !timedOut
            && !cancelled
            && outputDisposition == .complete
    }

    public var output: Data {
        var result = stdout
        if !result.isEmpty, !stderr.isEmpty {
            result.append(0x0A)
        }
        result.append(stderr)
        return result
    }

    public var outputDisposition: OutputDisposition {
        switch (stdoutTruncated, stderrTruncated) {
        case (false, false):
            return .complete
        case (true, false):
            return .stdoutExceededBound
        case (false, true):
            return .stderrExceededBound
        case (true, true):
            return .stdoutAndStderrExceededBound
        }
    }

    public var diagnostic: String {
        guard outputDisposition == .complete else {
            return "Command output exceeded the \(outputByteLimit)-byte bound (exit \(status)); captured output omitted."
        }
        return Redactor.subprocessBytes(output)
    }

    public var diagnosticOmittingStdout: String {
        guard outputDisposition == .complete else {
            return diagnostic
        }
        return Redactor.subprocessBytes(stderr)
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var futureChildAdmissionsClosed = false
    private var activeProcess: OwnedDirectChild?
    private var admissionInProgress = false
    private var startGateWrite: Int32?
    private var custodyHandles: [UUID: RetainedCleanupRegistry.Handle] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var areFutureChildAdmissionsClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return futureChildAdmissionsClosed
    }

    func beginChildAdmission(startGateWrite: Int32) throws {
        lock.lock()
        guard !cancelled,
              !futureChildAdmissionsClosed,
              !admissionInProgress,
              activeProcess == nil else {
            lock.unlock()
            throw GitSafetyError.cancelled
        }
        admissionInProgress = true
        self.startGateWrite = startGateWrite
        lock.unlock()
    }

    /// Accept an already transferred original owner without re-adopting its
    /// PID. This path invokes no caller callback under token admission.
    func publishRetainedChild(_ owner: OwnedDirectChild, leaseDescriptor: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard admissionInProgress else { return false }
        admissionInProgress = false; activeProcess = owner
        let gate = startGateWrite; startGateWrite = nil
        defer { if let gate { close(gate) } }
        guard !cancelled, !futureChildAdmissionsClosed,
              fcntl(leaseDescriptor, F_GETFD) >= 0, let gate else {
            cancelled = true; return false
        }
        var byte = UInt8(ascii: "G")
        while true {
            let count = Darwin.write(gate, &byte, 1)
            if count == 1 { return true }
            if count < 0 && errno == EINTR { continue }
            cancelled = true; return false
        }
    }

    /// No caller callback runs under this admission lock. Identity validation
    /// and the deadline check occur under the retained owner's signal lock.
    /// Cancellation and the actual resume syscall have one final local order.
    func resumeRetainedChild(_ owner: OwnedDirectChild, before deadline: MonotonicDeadline) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeProcess === owner, !cancelled, !futureChildAdmissionsClosed,
              !admissionInProgress, !deadline.hasExpired else { return false }
        return owner.resume(before: deadline)
    }

    func childAdmissionFailed() {
        lock.lock()
        admissionInProgress = false
        let gate = startGateWrite
        startGateWrite = nil
        lock.unlock()
        if let gate {
            close(gate)
        }
    }

    func clear(processID: pid_t) {
        lock.lock()
        let owner = activeProcess?.identity.processID == processID ? activeProcess : nil
        lock.unlock()
        guard let owner else { return }
        // Never wait for the child-owner mutex while holding token admission.
        let observation = owner.observation
        lock.lock(); defer { lock.unlock() }
        guard activeProcess === owner else { return }
        if case .reaped = observation { activeProcess = nil }
        else { cancelled = true; futureChildAdmissionsClosed = true }
    }

    /// A custodian remains owned exclusively by its retained registry. Token
    /// cancellation sends control through that registry; it never signals the
    /// helper PID or adopts its direct-child owner.
    func observeCustodyCancellation(_ handle: RetainedCleanupRegistry.Handle) -> UUID {
        let id = UUID()
        lock.lock()
        custodyHandles[id] = handle
        let stop = cancelled || futureChildAdmissionsClosed
        lock.unlock()
        if stop { handle.cancel() }
        return id
    }
    func removeCustodyCancellation(_ id: UUID) {
        lock.lock(); custodyHandles.removeValue(forKey: id); lock.unlock()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        futureChildAdmissionsClosed = true
        let gate = startGateWrite
        startGateWrite = nil
        let process = activeProcess
        let custodians = Array(custodyHandles.values)
        lock.unlock()
        custodians.forEach { $0.cancel() }
        if let gate {
            close(gate)
        }
        if let process {
            _ = process.send(SIGTERM)
        }
    }

    public func closeFutureChildAdmissions() {
        lock.lock()
        futureChildAdmissionsClosed = true
        let gate = startGateWrite
        startGateWrite = nil
        let custodians = Array(custodyHandles.values)
        lock.unlock()
        custodians.forEach { $0.cancel() }
        if let gate {
            close(gate)
        }
    }

    func ownedChild(processID: pid_t) -> OwnedDirectChild? {
        lock.lock()
        defer { lock.unlock() }
        return activeProcess?.identity.processID == processID ? activeProcess : nil
    }

    @discardableResult
    func signalActive(processID: pid_t, signal: Int32) -> Bool {
        // The retained capability, rather than a copied PID identity, performs
        // the final check and syscall under the same mutex as the runner's reap.
        ownedChild(processID: processID)?.send(signal) ?? false
    }

}

public struct ProcessRequest: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryDescriptor: Int32
    public let inheritedLeaseDescriptor: Int32?
    public let frozenConfigDescriptor: Int32?
    public let frozenConfigDirectoryDescriptor: Int32?
    public let timeoutSeconds: TimeInterval
    public let trampolineExecutable: String?
    public let executionSnapshot: RepositoryExecutionSnapshot?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryDescriptor: Int32,
        inheritedLeaseDescriptor: Int32?,
        frozenConfigDescriptor: Int32? = nil,
        frozenConfigDirectoryDescriptor: Int32? = nil,
        timeoutSeconds: TimeInterval,
        trampolineExecutable: String? = nil,
        executionSnapshot: RepositoryExecutionSnapshot? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryDescriptor = workingDirectoryDescriptor
        self.inheritedLeaseDescriptor = inheritedLeaseDescriptor
        self.frozenConfigDescriptor = frozenConfigDescriptor
        self.frozenConfigDirectoryDescriptor = frozenConfigDirectoryDescriptor
        self.timeoutSeconds = timeoutSeconds
        self.trampolineExecutable = trampolineExecutable
        self.executionSnapshot = executionSnapshot
    }
}

public final class DescriptorProcessRunner: @unchecked Sendable {
    public static let gitPath = "/usr/bin/git"
    public static let frozenConfigDirectoryFD: Int32 = 195
    public static let frozenConfigFD: Int32 = 196
    public static let startGateFD: Int32 = 197
    public static let inheritedLeaseFD: Int32 = 198
    public static let trampolineMode = "--shadow-sync-git-child"
    public static let completeRepositoryOutputLimit = 32 * 1024 * 1024

    let audit: CommandAudit?
    let outputLimit: Int
    let repositoryObserver: (@Sendable (RepositoryCommandObservation) -> Bool)?
    private let processObserver: (@Sendable (ProcessIdentity?) -> Bool)?
    #if SHADOW_SYNC_TESTING
    private let testingIdentityCapture:
        (@Sendable (pid_t, String, String) -> ProcessIdentity?)?
    private let beforeGatePublication: (@Sendable ([String]) -> Void)?
    private let afterProcessExit: (@Sendable ([String], Int32) -> Void)?
    private var testingSpawnObserver: (@Sendable (OwnedSpawnAnchor) -> Void)? = nil
    #endif

    public init(
        audit: CommandAudit? = nil,
        outputLimit: Int = 16_384,
        processObserver: (@Sendable (ProcessIdentity?) -> Bool)? = nil,
        repositoryObserver: (@Sendable (RepositoryCommandObservation) -> Bool)? = nil
    ) {
        self.audit = audit
        self.outputLimit = outputLimit
        self.processObserver = processObserver
        self.repositoryObserver = repositoryObserver
        #if SHADOW_SYNC_TESTING
        testingIdentityCapture = nil
        beforeGatePublication = nil
        afterProcessExit = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        audit: CommandAudit? = nil,
        outputLimit: Int = 16_384,
        beforeGatePublication: @escaping @Sendable () -> Void
    ) {
        self.audit = audit
        self.outputLimit = outputLimit
        processObserver = nil; repositoryObserver = nil
        testingIdentityCapture = nil
        self.beforeGatePublication = { _ in beforeGatePublication() }
        afterProcessExit = nil
    }

    public init(
        audit: CommandAudit? = nil,
        outputLimit: Int = 16_384,
        beforeGatePublicationForRequest: @escaping @Sendable ([String]) -> Void
    ) {
        self.audit = audit
        self.outputLimit = outputLimit
        processObserver = nil; repositoryObserver = nil
        testingIdentityCapture = nil
        beforeGatePublication = beforeGatePublicationForRequest
        afterProcessExit = nil
    }

    public init(
        audit: CommandAudit? = nil,
        outputLimit: Int = 16_384,
        afterProcessExit: @escaping @Sendable ([String], Int32) -> Void
    ) {
        self.audit = audit
        self.outputLimit = outputLimit
        processObserver = nil; repositoryObserver = nil
        testingIdentityCapture = nil
        beforeGatePublication = nil
        self.afterProcessExit = afterProcessExit
    }

    public init(
        audit: CommandAudit? = nil,
        outputLimit: Int = 16_384,
        testingIdentityCapture: @escaping @Sendable (
            pid_t, String, String
        ) -> ProcessIdentity?
    ) {
        self.audit = audit
        self.outputLimit = outputLimit
        processObserver = nil; repositoryObserver = nil
        self.testingIdentityCapture = testingIdentityCapture
        beforeGatePublication = nil
        afterProcessExit = nil
    }
    init(
        testingSpawnObserver: @escaping @Sendable (OwnedSpawnAnchor) -> Void,
        testingIdentityCapture: (@Sendable (pid_t, String, String) -> ProcessIdentity?)? = nil,
        beforeGatePublication: (@Sendable ([String]) -> Void)? = nil
    ) {
        audit = nil; outputLimit = 16_384; processObserver = nil; repositoryObserver = nil
        self.testingIdentityCapture = testingIdentityCapture
        self.beforeGatePublication = beforeGatePublication
        afterProcessExit = nil
        self.testingSpawnObserver = testingSpawnObserver
    }
    #endif

    public func run(
        _ request: ProcessRequest,
        cancellation: CancellationToken
    ) throws -> ProcessResult {
        #if !SHADOW_SYNC_TESTING
        throw SystemGitConfigurationError.unavailable
        #else
        guard request.executable == Self.gitPath,
              request.trampolineExecutable != nil,
              request.executionSnapshot != nil,
              request.inheritedLeaseDescriptor != nil,
              request.frozenConfigDescriptor != nil,
              request.frozenConfigDirectoryDescriptor != nil else {
            throw GitSafetyError.unsafeRepository("Git child supervision is incomplete")
        }
        try GitCommandPolicy.validate(
            request.arguments,
            expectedCommonDirectory:
                request.executionSnapshot!.repository
                    .commonDirectoryPath,
            expectedWorktreePath:
                request.executionSnapshot!.rootPath
        )
        try validateClosedEnvironment(
            request.environment,
            frozenConfigPath: request.executionSnapshot!.configuration.frozenPath,
            accountUID: uid_t(request.executionSnapshot!.accountUID)
        )
        // Preparation, suspended admission and execution consume one budget.
        let processDeadline = MonotonicDeadline(seconds: ChildProcessBudget.seconds(request.timeoutSeconds))
        let spawnSpec = try makeSpawnSpec(request)
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            closeDescriptors(stdoutPipe + stderrPipe)
            throw SecureStateError.systemCall("pipe Git output", errno)
        }
        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0]
        let stderrWrite = stderrPipe[1]
        defer {
            close(stdoutRead)
            close(stderrRead)
        }
        for descriptor in [stdoutRead, stderrRead] {
            let currentFlags = fcntl(descriptor, F_GETFL)
            guard currentFlags >= 0,
                  fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
                let code = errno
                close(stdoutWrite)
                close(stderrWrite)
                throw SecureStateError.systemCall("fcntl Git output pipe", code)
            }
        }

        let nullFD = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullFD >= 0 else {
            close(stdoutWrite)
            close(stderrWrite)
            throw SecureStateError.systemCall("open /dev/null", errno)
        }
        defer { close(nullFD) }

        audit?.record(CommandInvocation(
            executable: request.executable,
            arguments: request.arguments,
            environmentKeys: request.environment.keys.sorted(),
            spawnArguments: spawnSpec.arguments
        ))
        var startGate: [Int32] = [-1, -1]
        guard pipe(&startGate) == 0 else {
            close(stdoutWrite)
            close(stderrWrite)
            throw SecureStateError.systemCall("pipe child start gate", errno)
        }
        guard fcntl(startGate[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(startGate[1], F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(startGate[0])
            close(startGate[1])
            close(stdoutWrite)
            close(stderrWrite)
            throw SecureStateError.systemCall("fcntl child start gate", code)
        }
        do {
            try cancellation.beginChildAdmission(startGateWrite: startGate[1])
        } catch {
            close(startGate[0])
            close(startGate[1])
            close(stdoutWrite)
            close(stderrWrite)
            throw error
        }
        let streams = CapturedStreams(stdout: stdoutRead, stderr: stderrRead, limit: outputLimit)
        let anchor: OwnedSpawnAnchor
        do {
            guard !processDeadline.hasExpired, !cancellation.isCancelled else {
                throw GitSafetyError.cancelled
            }
            anchor = try spawn(
                executable: spawnSpec.executable,
                arguments: spawnSpec.arguments,
                environment: request.environment,
                workingDirectoryDescriptor: request.workingDirectoryDescriptor,
                standardInput: nullFD,
                standardOutput: stdoutWrite,
                standardError: stderrWrite,
                inheritedLeaseDescriptor: request.inheritedLeaseDescriptor,
                frozenConfigDescriptor: request.frozenConfigDescriptor,
                frozenConfigDirectoryDescriptor: request.frozenConfigDirectoryDescriptor,
                startGateDescriptor: startGate[0], streams: streams
            )
        } catch {
            close(startGate[0]); cancellation.childAdmissionFailed()
            close(stdoutWrite); close(stderrWrite)
            throw error
        }
        // Original custody exists before any callback or identity capture.
        // No later failure may release borrowed authority or streams early.
        let pid = anchor.processID
        close(startGate[0]); close(stdoutWrite); close(stderrWrite)
        #if SHADOW_SYNC_TESTING
        testingSpawnObserver?(anchor)
        beforeGatePublication?(request.arguments)
        #endif
        var childOwner: OwnedDirectChild?
        var published = false, resumed = false
        do {
            let generation = RunIdentity.make()
            #if SHADOW_SYNC_TESTING
            if let testingIdentityCapture {
                let actual = try ProcessIdentity.capture(processID: pid,
                    generation: generation, expectedExecutablePath: spawnSpec.executable)
                guard testingIdentityCapture(pid, generation, spawnSpec.executable) == actual else {
                    throw ProcessOwnershipError.invalidRegistration
                }
            }
            #endif
            let owner = try anchor.transfer(expectedExecutable: spawnSpec.executable,
                generation: generation, reapPolicy: .afterGroupDrain)
            childOwner = owner
            published = cancellation.publishRetainedChild(owner,
                leaseDescriptor: request.inheritedLeaseDescriptor!)
            // The callback sees a retained token owner, outside its mutex. The
            // helper remains suspended even though its start-gate byte exists.
            if published && (processObserver?(owner.identity) ?? true) {
                resumed = cancellation.resumeRetainedChild(owner, before: processDeadline)
            }
        } catch {
            cancellation.childAdmissionFailed()
        }
        if !resumed {
            cancellation.cancel()
            if let childOwner { _ = childOwner.send(SIGKILL) }
            else { _ = anchor.killSuspended() }
        }
        defer {
            cancellation.clear(processID: pid)
            _ = processObserver?(nil)
        }
        var terminationDeadline: MonotonicDeadline?
        var sentKill = !resumed, timedOut = processDeadline.hasExpired
        var waitStatus: Int32?
        var ownershipFailure: Int32?
        var reported = false
        let diagnostic = MonotonicDeadline(seconds: ChildProcessBudget.seconds(request.timeoutSeconds) + 6)
        while waitStatus == nil || !streams.snapshot().complete {
            streams.drain()
            let observed: OwnedDirectChildObservation
            if let childOwner {
                #if SHADOW_SYNC_TESTING
                childOwner.testingBeforeReap()
                #endif
                var value = childOwner.reapAfterGroupDrain(streamsDrained: streams.snapshot().complete)
                if case .running = value, childOwner.terminalStatusHeld != nil {
                    streams.drain()
                    value = childOwner.reapAfterGroupDrain(streamsDrained: streams.snapshot().complete)
                }
                observed = value
            } else {
                switch anchor.poll() {
                case .reaped(let status): observed = .reaped(status)
                case .ownershipFailure(let code): observed = .ownershipFailure(code)
                default: observed = .running
                }
            }
            switch observed {
            case .reaped(let status): waitStatus = status
            case .ownershipFailure(let code): ownershipFailure = ownershipFailure ?? code
            case .running: break
            }
            if waitStatus != nil && streams.snapshot().complete { break }
            if processDeadline.hasExpired { timedOut = true }
            let stopping = cancellation.isCancelled || timedOut || !resumed
                || ownershipFailure != nil || streams.snapshot().failed
            if stopping && terminationDeadline == nil {
                terminationDeadline = MonotonicDeadline(seconds: ProcessOwnershipTiming.termGrace)
                if resumed { _ = childOwner?.send(SIGTERM) }
                else if let childOwner { _ = childOwner.send(SIGKILL) }
                else { _ = anchor.killSuspended() }
            }
            if terminationDeadline?.hasExpired == true && !sentKill {
                _ = childOwner?.send(SIGKILL); sentKill = true
            }
            if diagnostic.hasExpired && !reported {
                fputs("DESCRIPTOR PROCESS CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
            }
            var descriptors = [
                pollfd(fd: stdoutRead, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stderrRead, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            _ = poll(&descriptors, 2, 10)
        }
        let captured = streams.snapshot()
        let status = decodedStatus(waitStatus!)
        #if SHADOW_SYNC_TESTING
        afterProcessExit?(request.arguments, status)
        #endif
        return ProcessResult(
            status: status,
            stdout: captured.stdout, stderr: captured.stderr,
            stdoutTruncated: captured.stdoutTruncated,
            stderrTruncated: captured.stderrTruncated,
            outputByteLimit: outputLimit, timedOut: timedOut,
            cancelled: cancellation.isCancelled,
            terminationRequested: !resumed || terminationDeadline != nil,
            processID: pid
        )
        #endif
    }

    private struct SpawnSpec {
        let executable: String
        let arguments: [String]
    }

    private func makeSpawnSpec(_ request: ProcessRequest) throws -> SpawnSpec {
        guard let trampoline = request.trampolineExecutable,
              request.executable == Self.gitPath,
              let snapshot = request.executionSnapshot else {
            throw GitSafetyError.unsafeRepository("trampoline metadata is incomplete")
        }
        let encoded = try JSONEncoder().encode(snapshot).base64EncodedString()
        return SpawnSpec(
            executable: trampoline,
            arguments: [
                Self.trampolineMode,
                encoded,
                "--",
                request.executable,
            ] + request.arguments
        )
    }

    private func validateClosedEnvironment(
        _ environment: [String: String],
        frozenConfigPath: String,
        accountUID: uid_t
    ) throws {
        let allowed = Set([
            "HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR",
            "GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "SSH_ASKPASS",
            "GIT_NO_REPLACE_OBJECTS", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT",
            "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
            "GIT_GRAFT_FILE", "SSH_AUTH_SOCK",
        ])
        guard Set(environment.keys).isSubset(of: allowed),
              environment["HOME"]?.hasPrefix("/") == true,
              environment["USER"]?.isEmpty == false,
              environment["LOGNAME"] == environment["USER"],
              environment["PATH"] == ClosedGitEnvironment.fixedPath,
              environment["LANG"] == "C",
              environment["LC_ALL"] == "C",
              environment["TMPDIR"] == "/private/tmp",
              environment["GIT_TERMINAL_PROMPT"] == "0",
              environment["GIT_ASKPASS"] == "/usr/bin/false",
              environment["SSH_ASKPASS"] == "/usr/bin/false",
              environment["GIT_NO_REPLACE_OBJECTS"] == "1",
              environment["GIT_CONFIG"] == nil,
              environment["GIT_CONFIG_GLOBAL"] == frozenConfigPath,
              environment["GIT_CONFIG_NOSYSTEM"] == "1",
              environment["GIT_GRAFT_FILE"] == "/dev/null",
              (
                (
                    environment["GIT_SSH_COMMAND"] == nil
                    && environment["GIT_SSH_VARIANT"] == nil
                )
                || (
                    environment["GIT_SSH_COMMAND"] == ClosedGitEnvironment.fixedSSHCommand
                    && environment["GIT_SSH_VARIANT"] == "ssh"
                )
              ),
              (
                environment["SSH_AUTH_SOCK"] == nil
                || (
                    environment["GIT_SSH_COMMAND"] == ClosedGitEnvironment.fixedSSHCommand
                    && ValidatedSSHAgentEnvironment.socketPath(
                        inherited: environment,
                        accountUID: accountUID
                    ) == environment["SSH_AUTH_SOCK"]
                )
              ) else {
            throw GitSafetyError.unsafeRepository("Git child environment is not closed")
        }
    }

    private func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectoryDescriptor: Int32,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        inheritedLeaseDescriptor: Int32?,
        frozenConfigDescriptor: Int32?,
        frozenConfigDirectoryDescriptor: Int32?,
        startGateDescriptor: Int32,
        streams: CapturedStreams
    ) throws -> OwnedSpawnAnchor {
        func duplicateAuthorityDescriptor(
            _ descriptor: Int32?,
            operation: String
        ) throws -> Int32? {
            guard let descriptor else {
                return nil
            }
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 256)
            guard duplicate >= 0 else {
                throw SecureStateError.systemCall(operation, errno)
            }
            return duplicate
        }

        let spawnLease = try duplicateAuthorityDescriptor(
            inheritedLeaseDescriptor,
            operation: "duplicate Git child lease"
        )
        defer {
            if let spawnLease {
                close(spawnLease)
            }
        }
        guard let spawnGate = try duplicateAuthorityDescriptor(
            startGateDescriptor,
            operation: "duplicate Git child start gate"
        ) else {
            throw GitSafetyError.unsafeRepository(
                "Git child start gate is unavailable"
            )
        }
        defer { close(spawnGate) }
        let spawnConfig = try duplicateAuthorityDescriptor(
            frozenConfigDescriptor,
            operation: "duplicate Git child frozen config"
        )
        defer {
            if let spawnConfig {
                close(spawnConfig)
            }
        }
        let spawnConfigDirectory = try duplicateAuthorityDescriptor(
            frozenConfigDirectoryDescriptor,
            operation: "duplicate Git child frozen config directory"
        )
        defer {
            if let spawnConfigDirectory {
                close(spawnConfigDirectory)
            }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw SecureStateError.systemCall("posix_spawn init", errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var actionCode = posix_spawn_file_actions_addfchdir(&actions, workingDirectoryDescriptor)
        if actionCode == 0 {
            actionCode = posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO)
        }
        if actionCode == 0 {
            actionCode = posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO)
        }
        if actionCode == 0 {
            actionCode = posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO)
        }
        if actionCode == 0, let spawnLease {
            actionCode = posix_spawn_file_actions_adddup2(
                &actions,
                spawnLease,
                Self.inheritedLeaseFD
            )
        }
        if actionCode == 0 {
            actionCode = posix_spawn_file_actions_adddup2(
                &actions,
                spawnGate,
                Self.startGateFD
            )
        }
        if actionCode == 0, let spawnConfig {
            actionCode = posix_spawn_file_actions_adddup2(
                &actions,
                spawnConfig,
                Self.frozenConfigFD
            )
        }
        if actionCode == 0, let spawnConfigDirectory {
            actionCode = posix_spawn_file_actions_adddup2(
                &actions,
                spawnConfigDirectory,
                Self.frozenConfigDirectoryFD
            )
        }
        guard actionCode == 0 else {
            throw SecureStateError.systemCall("posix_spawn file action", actionCode)
        }

        let spawnFlags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        var attributeCode = posix_spawnattr_setflags(&attributes, spawnFlags)
        if attributeCode == 0 {
            attributeCode = posix_spawnattr_setpgroup(&attributes, 0)
        }
        guard attributeCode == 0 else {
            throw SecureStateError.systemCall("posix_spawn attributes", attributeCode)
        }

        let argv = [executable] + arguments
        let env = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        return try withCStringArray(argv) { argvPointer in
            try withCStringArray(env) { envPointer in
                #if SHADOW_SYNC_TESTING
                if let registry = try RuntimeFixtureSession.currentIfBound() {
                    return try RuntimeFixtureSpawn.spawn(registry: registry, executable: executable,
                        actions: &actions, attributes: &attributes, arguments: argvPointer,
                        environment: envPointer, streamsDrained: {
                            streams.drain(); return streams.snapshot().complete
                        })
                }
                #endif
                return try OwnedSpawnAnchor.spawn(executable: executable, actions: &actions,
                    attributes: &attributes, arguments: argvPointer, environment: envPointer)
            }
        }
    }

    /// One logical reader owns both streams. All bounded reads and capture
    /// mutations share this mutex; callbacks observe the same actual EOF state.
    private final class CapturedStreams: @unchecked Sendable {
        struct Snapshot {
            let stdout: Data, stderr: Data
            let stdoutTruncated: Bool, stderrTruncated: Bool
            let complete: Bool, failed: Bool
        }
        private struct Capture { var data = Data(); var truncated = false, ended = false, failed = false }
        private let mutex = NSLock()
        private let outFD: Int32, errFD: Int32, limit: Int
        private var out = Capture(), err = Capture()
        init(stdout: Int32, stderr: Int32, limit: Int) { outFD = stdout; errFD = stderr; self.limit = limit }
        func snapshot() -> Snapshot {
            mutex.lock(); defer { mutex.unlock() }
            return Snapshot(stdout: out.data, stderr: err.data, stdoutTruncated: out.truncated,
                stderrTruncated: err.truncated, complete: out.ended && err.ended, failed: out.failed || err.failed)
        }
        func drain() {
            mutex.lock(); defer { mutex.unlock() }
            Self.read(outFD, limit: limit, capture: &out)
            Self.read(errFD, limit: limit, capture: &err)
        }
        private static func read(_ fd: Int32, limit: Int, capture: inout Capture) {
            guard !capture.ended, !capture.failed else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            // Bound each pass even when a child continuously fills its pipes.
            for _ in 0..<16 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    let remaining = max(0, limit - capture.data.count)
                    capture.data.append(contentsOf: bytes.prefix(min(count, remaining)))
                    if count > remaining { capture.truncated = true }
                } else if count == 0 { capture.ended = true; return }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { return }
                else { capture.failed = true; return }
            }
        }
    }

    private func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            close(descriptor)
        }
    }

    private func decodedStatus(_ status: Int32) -> Int32 {
        if (status & 0x7F) == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }
}

enum GitChildRootIdentity {
    static func validate(
        expectedDescriptor: Int32,
        currentDescriptor: Int32,
        snapshotRoot: FileIdentity,
        allowDescendant: Bool = false
    ) throws {
        var expectedStat = stat()
        var currentStat = stat()
        guard fstat(expectedDescriptor, &expectedStat) == 0,
              fstat(currentDescriptor, &currentStat) == 0,
              FileIdentity(expectedStat).isDirectory,
              FileIdentity(currentStat).isDirectory,
              expectedStat.st_uid == geteuid(),
              currentStat.st_uid == geteuid() else {
            throw GitSafetyError.unsafeRepository("governed root owner or type changed")
        }
        let expectedIdentity = RepositoryDirectoryIdentity(FileIdentity(expectedStat))
        let currentIdentity = RepositoryDirectoryIdentity(FileIdentity(currentStat))
        let snapshotIdentity = RepositoryDirectoryIdentity(snapshotRoot)
        guard currentIdentity == snapshotIdentity else {
            throw GitSafetyError.unsafeRepository("Git child root identity changed")
        }
        if currentIdentity == expectedIdentity {
            return
        }
        guard allowDescendant else {
            throw GitSafetyError.unsafeRepository("Git child root identity changed")
        }
        var cursor = fcntl(currentDescriptor, F_DUPFD_CLOEXEC, 0)
        guard cursor >= 0 else {
            throw GitSafetyError.unsafeRepository("Git child ancestry cannot be inspected")
        }
        defer { close(cursor) }
        for _ in 0..<32 {
            let parent = openat(
                cursor,
                "..",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard parent >= 0 else {
                throw GitSafetyError.unsafeRepository("Git child ancestry cannot be opened")
            }
            var parentStat = stat()
            guard fstat(parent, &parentStat) == 0,
                  FileIdentity(parentStat).isDirectory,
                  parentStat.st_uid == geteuid() else {
                close(parent)
                throw GitSafetyError.unsafeRepository("Git child ancestry is unsafe")
            }
            let parentIdentity = RepositoryDirectoryIdentity(FileIdentity(parentStat))
            if parentIdentity == expectedIdentity {
                close(parent)
                return
            }
            var cursorStat = stat()
            guard fstat(cursor, &cursorStat) == 0 else {
                close(parent)
                throw GitSafetyError.unsafeRepository("Git child ancestry changed")
            }
            if parentIdentity == RepositoryDirectoryIdentity(FileIdentity(cursorStat)) {
                close(parent)
                break
            }
            close(cursor)
            cursor = parent
        }
        throw GitSafetyError.unsafeRepository("Git child is outside the governed root")
    }
}

public enum GitChildTrampoline {
    public static func dispatch(arguments: [String]) -> Int32? {
        guard arguments.count >= 5, arguments[1] == DescriptorProcessRunner.trampolineMode else {
            return nil
        }
        #if !SHADOW_SYNC_TESTING
        // Decoded snapshots and inherited descriptors do not create a typed
        // configuration preflight or repository command authority.
        writeError("ShadowSync repository command custody is unavailable.\n")
        return 125
        #else
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        guard waitForStartAdmission(),
              let snapshotData = Data(base64Encoded: arguments[2]),
              let snapshot = try? JSONDecoder().decode(
                  RepositoryExecutionSnapshot.self,
                  from: snapshotData
              ),
              arguments[3] == "--",
              arguments[4] == DescriptorProcessRunner.gitPath,
              fcntl(DescriptorProcessRunner.inheritedLeaseFD, F_GETFD) >= 0,
              fcntl(DescriptorProcessRunner.frozenConfigDirectoryFD, F_GETFD) >= 0,
              fcntl(DescriptorProcessRunner.frozenConfigFD, F_GETFD) >= 0 else {
            writeError("ShadowSync refused an invalid Git child request.\n")
            return 125
        }
        defer {
            if getppid() != snapshot.configuration.frozenOwnerPID {
                try? RepositoryHandle.cleanupFrozenConfiguration(
                    descriptor: DescriptorProcessRunner.frozenConfigFD,
                    directoryDescriptor: DescriptorProcessRunner.frozenConfigDirectoryFD,
                    snapshot: snapshot.configuration
                )
            }
        }
        do {
            let usesTestTransport = try GitCommandPolicy.validate(
                Array(arguments.dropFirst(5)),
                expectedCommonDirectory:
                    snapshot.repository.commonDirectoryPath,
                expectedWorktreePath: snapshot.rootPath
            )
            try validateCurrentRoot(snapshot: snapshot, testTransport: usesTestTransport)
            #if SHADOW_SYNC_TESTING
            if Array(arguments.dropFirst(5)).contains(GitCommandPolicy.fdAuditMarker) {
                for descriptor in Int32(3)...Int32(256)
                where descriptor != DescriptorProcessRunner.inheritedLeaseFD
                    && descriptor != DescriptorProcessRunner.frozenConfigDirectoryFD
                    && descriptor != DescriptorProcessRunner.frozenConfigFD {
                    if fcntl(descriptor, F_GETFD) >= 0 {
                        throw GitSafetyError.unsafeRepository(
                            "authority descriptor leaked into Git trampoline"
                        )
                    }
                }
            }
            #endif
            let account = EffectiveAccount(
                uid: uid_t(snapshot.accountUID),
                username: snapshot.accountUsername,
                homeDirectory: snapshot.accountHome
            )
            let environment = ProcessInfo.processInfo.environment
            guard snapshot.accountUID == UInt32(geteuid()),
                  environment["HOME"] == snapshot.accountHome,
                  environment["USER"] == snapshot.accountUsername,
                  environment["LOGNAME"] == snapshot.accountUsername else {
                throw GitSafetyError.unsafeRepository("child effective account changed")
            }
            if let socket = environment["SSH_AUTH_SOCK"],
               ValidatedSSHAgentEnvironment.socketPath(
                   inherited: ["SSH_AUTH_SOCK": socket],
                   accountUID: uid_t(snapshot.accountUID)
               ) != socket {
                throw GitSafetyError.unsafeRepository("SSH agent socket changed before Git")
            }
            try RepositoryHandle.validateFrozenConfiguration(
                descriptor: DescriptorProcessRunner.frozenConfigFD,
                directoryDescriptor: DescriptorProcessRunner.frozenConfigDirectoryFD,
                snapshot: snapshot.configuration
            )
            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account)
            if let admission = snapshot.admission {
                try validateAdmission(
                    admission,
                    snapshot: snapshot,
                    account: account,
                    environment: environment
                )
            }
            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account)
            var gitArguments = Array(arguments.dropFirst(5))
            #if SHADOW_SYNC_TESTING
            var finalMutation: String?
            if let index = gitArguments.firstIndex(where: {
                $0 == GitCommandPolicy.finalConfigMutationMarker
                    || $0 == GitCommandPolicy.finalGraphMutationMarker
                    || $0 == GitCommandPolicy.finalFrozenSwapMarker
                    || $0 == GitCommandPolicy.finalRefMutationMarker
            }) {
                finalMutation = gitArguments.remove(at: index)
            }
            if let finalMutation {
                try applyFinalMutation(
                    finalMutation,
                    account: account,
                    rootPath: snapshot.rootPath,
                    snapshot: snapshot.configuration
                )
                if finalMutation == GitCommandPolicy.finalGraphMutationMarker {
                    try RepositoryHandle.validateExecutionSnapshot(
                        snapshot,
                        account: account
                    )
                }
            }
            if let index = gitArguments.firstIndex(where: {
                GitCommandPolicy.syntheticFetchMarkers.contains($0)
            }) {
                let marker = gitArguments.remove(at: index)
                if marker == GitCommandPolicy.syntheticOwnerExitMarker {
                    // A fixed, descendant-free exit for the real runner race test.
                    Thread.sleep(forTimeInterval: 1)
                    return 0
                }
                if marker == GitCommandPolicy.syntheticFetchTimeoutMarker {
                    Thread.sleep(
                        forTimeInterval: ChildProcessBudget.seconds(10)
                    )
                    return 128
                }
                let diagnostic: String
                switch marker {
                case GitCommandPolicy.syntheticFetchAuthenticationMarker:
                    diagnostic = "fatal: authentication failed"
                case GitCommandPolicy.syntheticFetchDNSMarker:
                    diagnostic = "fatal: could not resolve host"
                case GitCommandPolicy.syntheticFetchTransportMarker:
                    diagnostic = "fatal: connection refused"
                default:
                    diagnostic = "fatal: controlled fetch failure"
                }
                writeError(diagnostic + "\n")
                return 128
            }
            if let index = gitArguments.firstIndex(where: {
                GitCommandPolicy.syntheticUpdateMarkers.contains($0)
            }) {
                let marker = gitArguments.remove(at: index)
                if marker == GitCommandPolicy.syntheticUpdateFailureMarker {
                    writeError("fatal: controlled update failure\n")
                    return 1
                }
                let updateStatus = try superviseGit(
                    arguments: gitArguments,
                    environment: environment
                )
                guard updateStatus == 0 else {
                    return updateStatus
                }
                if marker == GitCommandPolicy.syntheticUpdateAmbiguousMarker {
                    guard snapshot.rootPath.hasPrefix("/private/tmp/") else {
                        throw GitSafetyError.unsafeRepository(
                            "test update mutation escaped its temporary root"
                        )
                    }
                    try Data("ambiguous\n".utf8).write(
                        to: URL(fileURLWithPath: snapshot.rootPath)
                            .appendingPathComponent(".git/refs/heads/main")
                    )
                }
                writeError("warning: controlled post-update failure\n")
                return 1
            }
            #endif
            let deletedBranch =
                GitCommandPolicy.ordinaryBranchDeletionName(
                    gitArguments,
                    expectedWorktreePath:
                        snapshot.rootPath
                )
            let repositoryConfigurationBefore =
                try deletedBranch.map { _ in
                    try RepositoryHandle
                        .captureRepositoryConfiguration(
                            snapshot
                        )
                }
            let status = try superviseGit(
                arguments: gitArguments,
                environment: environment
            )
            let permitsWorktreeMarkerChange =
                GitCommandPolicy.isMovedWorktreeRepair(
                    gitArguments,
                    expectedCommonDirectory:
                        snapshot.repository.commonDirectoryPath,
                    expectedWorktreePath: snapshot.rootPath
                )
            let permitsTargetRemoval =
                GitCommandPolicy.isWorktreeRemoval(
                    gitArguments,
                    expectedCommonDirectory:
                        snapshot.repository.commonDirectoryPath,
                    expectedWorktreePath: snapshot.rootPath
                )
            try RepositoryHandle.validateFrozenConfiguration(
                descriptor: DescriptorProcessRunner.frozenConfigFD,
                directoryDescriptor: DescriptorProcessRunner.frozenConfigDirectoryFD,
                snapshot: snapshot.configuration
            )
            if let deletedBranch,
               let repositoryConfigurationBefore {
                try RepositoryHandle
                    .validateBranchDeletionSnapshot(
                        snapshot,
                        account: account,
                        branchName: deletedBranch,
                        configurationBefore:
                            repositoryConfigurationBefore,
                        commandSucceeded: status == 0
                    )
            } else if permitsTargetRemoval {
                try RepositoryHandle
                    .validateCommonExecutionSnapshot(
                        snapshot,
                        account: account,
                        requirePackedIdentity: false
                    )
            } else {
                try RepositoryHandle.validateExecutionSnapshot(
                    snapshot,
                    account: account,
                    requirePackedIdentity: false,
                    requireWorktreeMarkerIdentity:
                        !permitsWorktreeMarkerChange
                )
            }
            return status
        } catch {
            #if SHADOW_SYNC_TESTING
            writeError(
                "ShadowSync refused changed repository metadata: "
                    + Redactor.sanitize(String(describing: error))
                    + "\n"
            )
            #else
            writeError("ShadowSync refused changed repository metadata.\n")
            #endif
            return 125
        }
        #endif
    }

    #if SHADOW_SYNC_TESTING
    private static func applyFinalMutation(
        _ marker: String,
        account: EffectiveAccount,
        rootPath: String,
        snapshot: GitConfigurationSnapshot
    ) throws {
        guard rootPath.hasPrefix("/private/tmp/"),
              account.homeDirectory.hasPrefix("/private/tmp/") else {
            throw GitSafetyError.unsafeRepository("test mutation escaped its temporary root")
        }
        if marker == GitCommandPolicy.finalConfigMutationMarker {
            let path = URL(fileURLWithPath: account.homeDirectory)
                .appendingPathComponent(".gitconfig").path
            // Keep this testing-only mutation atomic without Foundation's
            // ambient temporary-directory selection. Both names are confined
            // to the already validated disposable account home.
            let staging = URL(fileURLWithPath: account.homeDirectory)
                .appendingPathComponent(".shadow-sync-final-config-" + RunIdentity.make()).path
            try Data(
                """
                [url "https://github.com/retargeted/retargeted.git"]
                    insteadOf = git@github.com:fixture-owner/fixture-repo.git
                """.utf8
            ).write(to: URL(fileURLWithPath: staging), options: .withoutOverwriting)
            defer { _ = unlink(staging) }
            guard chmod(staging, 0o600) == 0, rename(staging, path) == 0 else {
                throw SecureStateError.systemCall("test final config atomic replacement", errno)
            }
            return
        }
        if marker == GitCommandPolicy.finalFrozenSwapMarker {
            let movedFile = snapshot.frozenPath + ".swap"
            guard rename(snapshot.frozenPath, movedFile) != 0 else {
                _ = rename(movedFile, snapshot.frozenPath)
                throw GitSafetyError.unsafeRepository(
                    "immutable frozen Git config file was replaceable"
                )
            }
            let movedDirectory = snapshot.frozenDirectoryPath + ".swap"
            guard rename(snapshot.frozenDirectoryPath, movedDirectory) != 0 else {
                _ = rename(movedDirectory, snapshot.frozenDirectoryPath)
                throw GitSafetyError.unsafeRepository(
                    "immutable frozen Git config directory was replaceable"
                )
            }
            throw GitSafetyError.unsafeRepository(
                "final frozen Git config swap attempt was refused"
            )
        }
        if marker == GitCommandPolicy.finalRefMutationMarker {
            let head = try Data(
                contentsOf: URL(fileURLWithPath: rootPath)
                    .appendingPathComponent(".git/HEAD")
            )
            let value = String(decoding: head, as: UTF8.self)
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()
            guard (value.count == 40 || value.count == 64),
                  value.allSatisfy({
                      $0.isNumber
                        || ("a"..."f").contains(
                            $0.lowercased()
                        )
                  }) else {
                throw GitSafetyError.unsafeRepository(
                    "final ref mutation target is invalid"
                )
            }
            try Data("\(value)\n".utf8).write(
                to: URL(fileURLWithPath: rootPath)
                    .appendingPathComponent(
                        ".git/refs/heads/main"
                    )
            )
            return
        }
        guard marker == GitCommandPolicy.finalGraphMutationMarker else {
            throw GitSafetyError.unsafeRepository("unknown test mutation")
        }
        let alternate = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(".git/objects/info/alternates")
        try Data("/private/tmp/nonexistent-object-store\n".utf8).write(to: alternate)
    }
    #endif

    #if SHADOW_SYNC_TESTING
    private static func waitForStartAdmission() -> Bool {
        defer { close(DescriptorProcessRunner.startGateFD) }
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(DescriptorProcessRunner.startGateFD, &byte, 1)
            if count == 1 {
                return byte == UInt8(ascii: "G")
            }
            if count < 0, errno == EINTR {
                continue
            }
            return false
        }
    }

    private static func validateAdmission(
        _ admission: GitAdmissionSnapshot,
        snapshot: RepositoryExecutionSnapshot,
        account: EffectiveAccount,
        environment: [String: String]
    ) throws {
        let probes: [([String], (Int32, Data) throws -> Void)] = [
            (
                [
                    "--no-replace-objects", "--no-lazy-fetch",
                    "rev-parse", "--show-toplevel",
                ],
                { status, output in
                    guard status == 0,
                          RepositoryRootPathIdentity.matches(
                              path: String(decoding: output, as: UTF8.self)
                                  .trimmingCharacters(in: .whitespacesAndNewlines),
                              expected: snapshot.repository.root
                          ) else {
                        throw GitSafetyError.unsafeRepository(
                            "effective Git top-level does not match the retained root"
                        )
                    }
                }
            ),
            (
                [
                    "--no-replace-objects", "--no-lazy-fetch",
                    "remote", "get-url", "--all", "origin",
                ],
                { status, output in
                    let lines = String(decoding: output, as: UTF8.self)
                        .split(whereSeparator: \.isNewline)
                        .map(String.init)
                    #if SHADOW_SYNC_TESTING
                    let expectedURL = admission.mappedTestURL ?? admission.effectiveURL
                    #else
                    let expectedURL = admission.effectiveURL
                    #endif
                    guard status == 0,
                          lines == [expectedURL],
                          GitHubIdentity.parse(admission.effectiveURL)?.transport
                            == admission.transport else {
                        #if SHADOW_SYNC_TESTING
                        throw GitSafetyError.unsafeRepository(
                            "frozen origin probe mismatch expected=\(expectedURL) observed=\(lines)"
                        )
                        #else
                        throw GitSafetyError.originChanged
                        #endif
                    }
                }
            ),
            (
                ["--no-replace-objects", "--no-lazy-fetch"]
                    + EffectiveTransportConfiguration.queryArguments,
                { status, output in
                    try EffectiveTransportConfiguration.validate(
                        status: status,
                        output: output,
                        transport: admission.transport,
                        operation: "Git child transport config probe"
                    )
                }
            ),
        ]
        for (arguments, validate) in probes {
            try RepositoryHandle.validateFrozenConfiguration(
                descriptor: DescriptorProcessRunner.frozenConfigFD,
                directoryDescriptor: DescriptorProcessRunner.frozenConfigDirectoryFD,
                snapshot: snapshot.configuration
            )
            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account)
            let result = try probeGit(arguments: arguments, environment: environment)
            try validate(result.status, result.output)
            try RepositoryHandle.validateFrozenConfiguration(
                descriptor: DescriptorProcessRunner.frozenConfigFD,
                directoryDescriptor: DescriptorProcessRunner.frozenConfigDirectoryFD,
                snapshot: snapshot.configuration
            )
            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account)
        }
    }

    private static func probeGit(
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: Data) {
        var outputPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else {
            throw SecureStateError.systemCall("pipe Git child preflight", errno)
        }
        let readFD = outputPipe[0]
        let writeFD = outputPipe[1]
        defer { close(readFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(writeFD)
            throw SecureStateError.systemCall("Git child preflight init", errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        var code = posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        if code == 0 {
            code = posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)
        }
        guard code == 0 else {
            close(writeFD)
            throw SecureStateError.systemCall("Git child preflight output", code)
        }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        code = posix_spawnattr_setsigdefault(&attributes, &defaults)
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)
        if code == 0 {
            code = posix_spawnattr_setflags(&attributes, flags)
        }
        guard code == 0 else {
            close(writeFD)
            throw SecureStateError.systemCall("Git child preflight attributes", code)
        }
        var child: pid_t = 0
        code = withCStringArray([DescriptorProcessRunner.gitPath] + arguments) { argv in
            withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }) { envp in
                posix_spawn(
                    &child,
                    DescriptorProcessRunner.gitPath,
                    &actions,
                    &attributes,
                    argv,
                    envp
                )
            }
        }
        close(writeFD)
        guard code == 0 else {
            throw SecureStateError.systemCall("posix_spawn Git child preflight", code)
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while data.count < 65_536 {
            let count = Darwin.read(readFD, &bytes, min(bytes.count, 65_536 - data.count))
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        if data.count == 65_536 {
            _ = kill(child, SIGKILL)
            while Darwin.read(readFD, &bytes, bytes.count) > 0 {}
            var overflowStatus: Int32 = 0
            while waitpid(child, &overflowStatus, 0) < 0, errno == EINTR {}
            throw GitSafetyError.unsafeRepository("Git child preflight output exceeded its bound")
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno == EINTR {
                continue
            }
            throw SecureStateError.systemCall("waitpid Git child preflight", errno)
        }
        let decoded = (status & 0x7F) == 0
            ? (status >> 8) & 0xFF
            : 128 + (status & 0x7F)
        return (decoded, data)
    }

    private static func validateCurrentRoot(
        snapshot: RepositoryExecutionSnapshot,
        testTransport: Bool
    ) throws {
        let expectedPath: String
        #if SHADOW_SYNC_TESTING
        if testTransport {
            let isolatedRoot = URL(fileURLWithPath: snapshot.accountHome)
                .deletingLastPathComponent().path
            _ = try TestIsolation.validateRoot(isolatedRoot)
            try TestIsolation.validateContainedDirectory(snapshot.rootPath, root: isolatedRoot)
            expectedPath = snapshot.rootPath
        } else {
            expectedPath = snapshot.rootPath
        }
        #else
        guard !testTransport else {
            throw GitSafetyError.unsafeRepository("test transport is absent from production")
        }
        expectedPath = snapshot.rootPath
        #endif

        let expectedDescriptor = Darwin.open(
            expectedPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard expectedDescriptor >= 0 else {
            throw GitSafetyError.unsafeRepository("fixed M1 root cannot be opened")
        }
        defer { close(expectedDescriptor) }
        let currentDescriptor = Darwin.open(
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else {
            throw GitSafetyError.unsafeRepository("child worktree cannot be opened")
        }
        defer { close(currentDescriptor) }

        try GitChildRootIdentity.validate(
            expectedDescriptor: expectedDescriptor,
            currentDescriptor: currentDescriptor,
            snapshotRoot: snapshot.repository.root,
            allowDescendant: false
        )
    }

    private static func superviseGit(
        arguments: [String],
        environment: [String: String]
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw SecureStateError.systemCall("Git supervisor init", errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var code: Int32 = 0
        for descriptor in [
            STDIN_FILENO,
            STDOUT_FILENO,
            STDERR_FILENO,
        ] where code == 0 {
            code = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        guard code == 0 else {
            throw SecureStateError.systemCall("Git supervisor descriptors", code)
        }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard code == 0 else {
            throw SecureStateError.systemCall("Git supervisor signal defaults", code)
        }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
        )
        code = posix_spawnattr_setflags(&attributes, flags)
        if code == 0 {
            code = posix_spawnattr_setpgroup(&attributes, getpgrp())
        }
        guard code == 0 else {
            throw SecureStateError.systemCall("Git supervisor attributes", code)
        }

        var child: pid_t = 0
        code = withCStringArray([DescriptorProcessRunner.gitPath] + arguments) { argv in
            withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }) { envp in
                posix_spawn(
                    &child,
                    DescriptorProcessRunner.gitPath,
                    &actions,
                    &attributes,
                    argv,
                    envp
                )
            }
        }
        guard code == 0 else {
            throw SecureStateError.systemCall("posix_spawn /usr/bin/git", code)
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno == EINTR {
                continue
            }
            throw SecureStateError.systemCall("waitpid /usr/bin/git", errno)
        }
        if (status & 0x7F) == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    #endif

    private static func writeError(_ value: String) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = Darwin.write(STDERR_FILENO, base, raw.count)
            }
        }
    }
}

public enum GitCommandPolicy {
    #if SHADOW_SYNC_TESTING
    static let testRootMarker = "shadowSync.m1TestRoot=true"
    static let fdAuditMarker = "shadowSync.m1FDAudit=true"
    static let finalConfigMutationMarker = "--shadow-sync-test-final-mutation=config"
    static let finalGraphMutationMarker = "--shadow-sync-test-final-mutation=graph"
    static let finalFrozenSwapMarker = "--shadow-sync-test-final-mutation=frozen-swap"
    static let finalRefMutationMarker = "--shadow-sync-test-final-mutation=ref"
    static let syntheticFetchAuthenticationMarker = "--shadow-sync-test-fetch=authentication"
    static let syntheticFetchDNSMarker = "--shadow-sync-test-fetch=dns"
    static let syntheticFetchTransportMarker = "--shadow-sync-test-fetch=transport"
    static let syntheticFetchOtherMarker = "--shadow-sync-test-fetch=other"
    static let syntheticOwnerExitMarker = "--shadow-sync-test-owner-exit"
    static let syntheticFetchTimeoutMarker = "--shadow-sync-test-fetch=timeout"
    static let syntheticFetchMarkers = Set([
        syntheticFetchAuthenticationMarker,
        syntheticFetchDNSMarker,
        syntheticFetchTransportMarker,
        syntheticFetchOtherMarker,
        syntheticFetchTimeoutMarker,
        syntheticOwnerExitMarker,
    ])
    static let syntheticUpdateFailureMarker = "--shadow-sync-test-update=failure"
    static let syntheticUpdateAdvanceFailureMarker = "--shadow-sync-test-update=advanced-failure"
    static let syntheticUpdateAmbiguousMarker = "--shadow-sync-test-update=ambiguous"
    static let syntheticUpdateMarkers = Set([
        syntheticUpdateFailureMarker,
        syntheticUpdateAdvanceFailureMarker,
        syntheticUpdateAmbiguousMarker,
    ])
    #endif

    @discardableResult
    public static func validate(
        _ rawArguments: [String],
        expectedCommonDirectory: String? = nil,
        expectedWorktreePath: String? = nil
    ) throws -> Bool {
        var arguments = rawArguments
        var usesTestTransport = false
        #if SHADOW_SYNC_TESTING
        if arguments.count >= 2, arguments[0] == "-c" {
            guard arguments[1] == testRootMarker
                    || arguments[1] == fdAuditMarker
                    || validTestMapping(arguments[1]) else {
                throw GitSafetyError.unsafeRepository("invalid test-only Git transport mapping")
            }
            usesTestTransport = true
            arguments.removeFirst(2)
        }
        if let first = arguments.first,
           first == finalConfigMutationMarker
            || first == finalGraphMutationMarker
            || first == finalFrozenSwapMarker
            || first == finalRefMutationMarker
            || syntheticFetchMarkers.contains(first)
            || syntheticUpdateMarkers.contains(first) {
            usesTestTransport = true
            arguments.removeFirst()
        }
        #endif
        guard arguments.first == "--no-replace-objects" else {
            throw GitSafetyError.unsafeRepository("Git ordinary-object mode is required")
        }
        let usesLazyFetchGuard = arguments.dropFirst().first == "--no-lazy-fetch"
        var command = Array(
            arguments.dropFirst(usesLazyFetchGuard ? 2 : 1)
        )
        var hasVerifiedGitDirectory = false
        if let first = command.first,
           first.hasPrefix("--git-dir=") {
            guard let expectedCommonDirectory,
                  first == "--git-dir=\(expectedCommonDirectory)" else {
                throw GitSafetyError.unsafeRepository(
                    "maintenance Git directory is not the verified common directory"
                )
            }
            hasVerifiedGitDirectory = true
            command.removeFirst()
        }
        let fixed: [[String]] = [
            ["remote", "get-url", "--all", "origin"],
            EffectiveTransportConfiguration.queryArguments,
            ["rev-parse", "--show-toplevel"],
            ["worktree", "list", "--porcelain", "-z"],
            [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(upstream)%00%(committerdate:iso-strict)%00",
                "refs/heads/",
            ],
            [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00",
                "refs/heads/main",
                "refs/remotes/origin/main",
            ],
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            ["show-ref", "--verify", "--quiet", "refs/heads/main"],
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            [
                "status", "--porcelain=v2", "-z", "--branch",
                "--untracked-files=all",
            ],
            [
                "status", "--porcelain=v1", "-z",
                "--untracked-files=all", "--ignored=matching",
            ],
            ["ls-files", "-v", "-z"],
            ["ls-files", "--stage", "-v", "-z"],
            ["rev-parse", "--verify", "refs/heads/main^{commit}"],
            ["rev-parse", "--verify", "refs/remotes/origin/main^{commit}"],
            ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"],
            ["rev-parse", "--verify", "HEAD^{commit}"],
        ]
        let inspectionRelationPrefix =
            "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track,nobracket)%00%(ahead-behind:"
        let inspectionRelationSuffix = ")%00"
        if usesLazyFetchGuard,
           !hasVerifiedGitDirectory,
           command.count == 4,
           command[0] == "for-each-ref",
           command[1].hasPrefix(inspectionRelationPrefix),
           command[1].hasSuffix(inspectionRelationSuffix),
           command[2] == "refs/heads/",
           command[3] == "refs/remotes/" {
            let comparison = String(
                command[1]
                    .dropFirst(inspectionRelationPrefix.count)
                    .dropLast(inspectionRelationSuffix.count)
            )
            guard comparison == "HEAD" || validOID(comparison) else {
                throw GitSafetyError.unsafeRepository(
                    "bulk relation comparison is invalid"
                )
            }
            return usesTestTransport
        }
        if usesLazyFetchGuard, fixed.contains(command) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 4,
           command[0] == "show-ref",
           command[1] == "--verify",
           command[2] == "--quiet",
           GitReferenceSyntax.isValidLocalBranchRef(command[3]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           !hasVerifiedGitDirectory,
           command == [
               "for-each-ref",
               "--format=%(refname)%00%(objectname)%00",
               "refs/",
           ] {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           !hasVerifiedGitDirectory,
           command == [
               "symbolic-ref", "--quiet",
               "refs/remotes/origin/HEAD",
           ] {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           !hasVerifiedGitDirectory,
           command == ["rev-parse", "--show-object-format"] {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           hasVerifiedGitDirectory,
           command == [
               "worktree", "prune", "--dry-run",
               "--verbose", "--expire=now",
           ] {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           hasVerifiedGitDirectory,
           command == [
               "worktree", "prune",
               "--verbose", "--expire=now",
           ] {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           hasVerifiedGitDirectory,
           command.count == 3,
           command[0] == "worktree",
           command[1] == "repair",
           command[2] == expectedWorktreePath,
           command[2].hasPrefix("/"),
           !command[2].contains("\0"),
           !command[2].contains("\n"),
           !command[2].contains("\r") {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           hasVerifiedGitDirectory,
           command.count == 4,
           command[0] == "update-ref",
           GitReferenceSyntax.isValidLocalBranchRef(command[1]),
           validOID(command[2]),
           validOID(command[3]),
           command[3].count == command[2].count {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           hasVerifiedGitDirectory,
           command.count >= 3,
           command.count <= 5,
           command[0] == "worktree",
           command[1] == "remove",
           command.last == expectedWorktreePath,
           command.last?.hasPrefix("/") == true,
           Array(command.dropFirst(2).dropLast())
                .allSatisfy({ $0 == "--force" }),
           command.dropFirst(2).dropLast().count <= 2 {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           !hasVerifiedGitDirectory,
           command.count == 5,
           command[0] == "-C",
           command[1] == expectedWorktreePath,
           command[2] == "branch",
           command[3] == "-d",
           GitReferenceSyntax.isValidBranchName(
               command[4]
           ) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           hasVerifiedGitDirectory,
           command.count == 4,
           command[0] == "update-ref",
           command[1] == "-d",
           GitReferenceSyntax.isValidLocalBranchRef(command[2]),
           validOID(command[3]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 3,
           command[0] == "rev-parse",
           command[1] == "--verify",
           validCommitExpression(command[2]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 4,
           command[0] == "rev-parse",
           command[1] == "--verify",
           command[2] == "--quiet",
           validCommitExpression(command[3]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 3,
           command[0] == "cat-file",
           command[1] == "-e",
           validOIDCommitExpression(command[2]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 4,
           command[0] == "show",
           command[1] == "-s",
           command[2] == "--format=%cI",
           validOID(command[3]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 4,
           command[0] == "merge-base",
           command[1] == "--is-ancestor",
           validOID(command[2]),
           validOID(command[3]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 4,
           command[0] == "rev-list",
           command[1] == "--left-right",
           command[2] == "--count",
           validOIDRange(command[3]) {
            return usesTestTransport
        }
        if usesLazyFetchGuard,
           command.count == 5,
           Array(command.prefix(4)) == [
               "merge", "--ff-only", "--no-overwrite-ignore", "--no-autostash",
           ],
           validOID(command[4]) {
            return usesTestTransport
        }
        if !usesLazyFetchGuard,
           command == ["ls-remote", "--symref", "origin", "HEAD"] {
            return usesTestTransport
        }
        if !usesLazyFetchGuard,
           validDefaultBranchFetch(command) {
            return usesTestTransport
        }
        throw GitSafetyError.unsafeRepository(
            "Git command is outside the closed ShadowSync command set"
        )
    }

    static func isMovedWorktreeRepair(
        _ rawArguments: [String],
        expectedCommonDirectory: String,
        expectedWorktreePath: String
    ) -> Bool {
        var arguments = rawArguments
        #if SHADOW_SYNC_TESTING
        if arguments.count >= 2, arguments[0] == "-c" {
            arguments.removeFirst(2)
        }
        if let first = arguments.first,
           first == finalConfigMutationMarker
            || first == finalGraphMutationMarker
            || first == finalFrozenSwapMarker
            || first == finalRefMutationMarker
            || syntheticFetchMarkers.contains(first)
            || syntheticUpdateMarkers.contains(first) {
            arguments.removeFirst()
        }
        #endif
        return arguments == [
            "--no-replace-objects",
            "--no-lazy-fetch",
            "--git-dir=\(expectedCommonDirectory)",
            "worktree",
            "repair",
            expectedWorktreePath,
        ]
    }

    static func isWorktreeRemoval(
        _ rawArguments: [String],
        expectedCommonDirectory: String,
        expectedWorktreePath: String
    ) -> Bool {
        var arguments = rawArguments
        #if SHADOW_SYNC_TESTING
        if arguments.count >= 2, arguments[0] == "-c" {
            arguments.removeFirst(2)
        }
        #endif
        guard arguments.starts(with: [
            "--no-replace-objects",
            "--no-lazy-fetch",
            "--git-dir=\(expectedCommonDirectory)",
            "worktree",
            "remove",
        ]),
        arguments.last == expectedWorktreePath else {
            return false
        }
        let force = arguments.dropFirst(5).dropLast()
        return force.count <= 2
            && force.allSatisfy { $0 == "--force" }
    }

    static func ordinaryBranchDeletionName(
        _ rawArguments: [String],
        expectedWorktreePath: String
    ) -> String? {
        var arguments = rawArguments
        #if SHADOW_SYNC_TESTING
        if arguments.count >= 2,
           arguments[0] == "-c" {
            arguments.removeFirst(2)
        }
        #endif
        let prefix = [
            "--no-replace-objects",
            "--no-lazy-fetch",
            "-C",
            expectedWorktreePath,
            "branch",
            "-d",
        ]
        guard arguments.count == prefix.count + 1,
              Array(arguments.prefix(prefix.count))
                == prefix else {
            return nil
        }
        let name = arguments[prefix.count]
        guard GitReferenceSyntax.isValidLocalBranchRef(
            "refs/heads/\(name)"
        ) else {
            return nil
        }
        return name
    }

    private static func validCommitExpression(_ value: String) -> Bool {
        guard value.hasSuffix("^{commit}") else { return false }
        let reference = String(value.dropLast("^{commit}".count))
        return GitReferenceSyntax.isValidLocalBranchRef(reference)
            || GitReferenceSyntax.isValidRemoteTrackingRef(reference)
            || reference == "HEAD"
    }

    private static func validOIDCommitExpression(_ value: String) -> Bool {
        value.hasSuffix("^{commit}")
            && validOID(String(value.dropLast("^{commit}".count)))
    }

    private static func validOIDRange(_ value: String) -> Bool {
        let fields = value.components(separatedBy: "...")
        return fields.count == 2 && fields.allSatisfy(validOID)
    }

    private static func validDefaultBranchFetch(_ command: [String]) -> Bool {
        let prefix = [
            "fetch", "--porcelain", "--verbose", "--no-write-fetch-head",
            "--no-tags", "--no-prune", "--no-recurse-submodules",
            "--no-auto-maintenance", "origin",
        ]
        guard command.count == prefix.count + 1,
              Array(command.prefix(prefix.count)) == prefix else {
            return false
        }
        let fields = command[prefix.count].components(separatedBy: ":")
        guard fields.count == 2,
              fields[0].hasPrefix("refs/heads/"),
              fields[1].hasPrefix("refs/remotes/origin/") else {
            return false
        }
        let localName = String(fields[0].dropFirst("refs/heads/".count))
        let remoteName = String(
            fields[1].dropFirst("refs/remotes/origin/".count)
        )
        return localName == remoteName
            && GitReferenceSyntax.isValidBranchName(localName)
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy { character in
                character.isNumber || ("a"..."f").contains(character)
            }
    }

    #if SHADOW_SYNC_TESTING
    private static func validTestMapping(_ value: String) -> Bool {
        guard value.hasPrefix("url.file://"),
              let separator = value.range(of: ".insteadOf=") else {
            return false
        }
        let local = String(value[value.index(value.startIndex, offsetBy: 4)..<separator.lowerBound])
        let logical = String(value[separator.upperBound...])
        return (local.hasPrefix("file:///private/tmp/") || local.hasPrefix("file:///tmp/"))
            && GitHubIdentity.parse(logical) != nil
    }
    #endif
}

private func withCStringArray<T>(
    _ values: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> T
) rethrows -> T {
    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    var mutable = pointers
    mutable.append(nil)
    return try mutable.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress)
    }
}
