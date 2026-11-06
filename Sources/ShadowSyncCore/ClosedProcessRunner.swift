import Darwin
import Foundation

public struct ClosedProcessCommand: Equatable, Sendable {
    public static let inheritedReadDescriptorNumber:
        Int32 = 9
    public let executable: String
    public let arguments: [String]
    public let logicalExecutable: String
    public let logicalArguments: [String]
    public let inheritedReadDescriptor: Int32?
    /// A separate strict unlinked snapshot mapped to fd 9; exclusive with the legacy linked input.
    public let inheritedReadSnapshotDescriptor: Int32?
    /// An owner-created, unlinked, read-only regular file. The runner borrows it.
    public let standardInputDescriptor: Int32?

    public init(
        executable: String,
        arguments: [String],
        logicalExecutable: String? = nil,
        logicalArguments: [String]? = nil,
        inheritedReadDescriptor: Int32? = nil,
        inheritedReadSnapshotDescriptor: Int32? = nil,
        standardInputDescriptor: Int32? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.logicalExecutable = logicalExecutable ?? executable
        self.logicalArguments = logicalArguments ?? arguments
        self.inheritedReadDescriptor =
            inheritedReadDescriptor
        self.inheritedReadSnapshotDescriptor = inheritedReadSnapshotDescriptor
        self.standardInputDescriptor = standardInputDescriptor
    }
}

public final class ClosedProcessRunner: @unchecked Sendable {
    private struct ReadDescriptorSnapshot:
        Equatable {
        let identity: FileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private let outputLimit: Int
    private let audit: CommandAudit?

    public init(
        outputLimit: Int = 16_777_216,
        audit: CommandAudit? = nil
    ) {
        self.outputLimit = outputLimit
        self.audit = audit
    }

    #if SHADOW_SYNC_TESTING
    private var testingHooks: ClosedProcessRunnerTestingHooks?
    static func testing(outputLimit: Int = 16_777_216, hooks: ClosedProcessRunnerTestingHooks) -> ClosedProcessRunner {
        let runner = ClosedProcessRunner(outputLimit: outputLimit)
        runner.testingHooks = hooks
        return runner
    }
    #endif

    public func run(
        command: ClosedProcessCommand,
        environment: [String: String],
        workingDirectoryDescriptor: Int32,
        account: EffectiveAccount,
        timeout: TimeInterval,
        cancellation: CancellationToken,
        validateSuspendedChild: ((pid_t) throws -> Void)? = nil
    ) throws -> ProcessResult {
        guard command.inheritedReadDescriptor == nil || command.inheritedReadSnapshotDescriptor == nil else {
            throw GitSafetyError.unsafeRepository("closed inherited input is ambiguous")
        }
        let inheritedDescriptor = command.inheritedReadSnapshotDescriptor ?? command.inheritedReadDescriptor
        guard inheritedDescriptor == nil || inheritedDescriptor != command.standardInputDescriptor else {
            throw GitSafetyError.unsafeRepository("closed input descriptors overlap")
        }
        func validateInherited(_ descriptor: Int32, requireStart: Bool) throws -> ReadDescriptorSnapshot {
            if command.inheritedReadSnapshotDescriptor != nil {
                return try Self.validateStandardInput(descriptor, owner: account.uid, requireStart: requireStart)
            }
            return try Self.validateReadDescriptor(descriptor, allowedOwners: [0, account.uid])
        }
        let executableIdentity = try Self.validateExecutable(
            command.executable,
            allowedOwners: [0, account.uid]
        )
        let inheritedIdentity = try inheritedDescriptor.map {
            try validateInherited($0, requireStart: true)
        }
        let inputIdentity = try command.standardInputDescriptor.map {
            try Self.validateStandardInput($0, owner: account.uid, requireStart: true)
        }
        try Self.validateEnvironment(environment, account: account)
        guard timeout > 0, timeout <= 300,
              !command.arguments.contains(where: {
                  $0.contains("\0")
              }) else {
            throw GitSafetyError.unsafeRepository(
                "closed process request is invalid"
            )
        }
        let deadline = MonotonicDeadline(seconds: ChildProcessBudget.seconds(timeout))
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        var gate: [Int32] = [-1, -1]
        guard pipe(&out) == 0, pipe(&err) == 0, pipe(&gate) == 0 else {
            Self.close(out + err + gate)
            throw SecureStateError.systemCall(
                "create closed process pipes",
                errno
            )
        }
        let outRead = out[0]
        let outWrite = out[1]
        let errRead = err[0]
        let errWrite = err[1]
        let gateRead = gate[0]
        let gateWrite = gate[1]
        defer {
            Self.close([outRead, errRead, gateRead])
        }
        for descriptor in [outRead, errRead] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                Self.close([outWrite, errWrite, gateWrite])
                throw SecureStateError.systemCall(
                    "configure closed process pipe",
                    errno
                )
            }
        }
        let null = Darwin.open(
            "/dev/null",
            O_RDONLY | O_CLOEXEC
        )
        guard null >= 0 else {
            Self.close([outWrite, errWrite, gateWrite])
            throw SecureStateError.systemCall("open /dev/null", errno)
        }
        defer { Darwin.close(null) }
        do {
            try cancellation.beginChildAdmission(
                startGateWrite: gateWrite
            )
        } catch {
            Self.close([outWrite, errWrite, gateWrite])
            throw error
        }
        audit?.record(CommandInvocation(
            executable: command.logicalExecutable,
            arguments: command.logicalArguments,
            environmentKeys: environment.keys.sorted(),
            spawnArguments: [command.executable] + command.arguments
        ))
        // The single synchronized stream owner is shared with testing cleanup;
        // no second reader or copied descriptor is retained by the guardian.
        let streams = CapturedStreams(stdout: outRead, stderr: errRead, limit: outputLimit)
        let anchor: OwnedSpawnAnchor
        do {
            #if SHADOW_SYNC_TESTING
            try testingHooks?.beforeSpawn?()
            #endif
            guard !deadline.hasExpired, !cancellation.isCancelled else { throw GitSafetyError.cancelled }
            anchor = try spawnSuspended(
                command: command, environment: environment,
                workingDirectoryDescriptor: workingDirectoryDescriptor,
                standardInput: command.standardInputDescriptor ?? null,
                standardOutput: outWrite, standardError: errWrite,
                inheritedReadDescriptor: inheritedDescriptor, streams: streams
            )
        } catch {
            cancellation.childAdmissionFailed()
            Self.close([outWrite, errWrite])
            throw error
        }
        // From this point no error may unwind the original anchor, stream
        // descriptors or borrowed resources before actual terminal convergence.
        let pid = anchor.processID
        Self.close([outWrite, errWrite])
        var childOwner: OwnedDirectChild?
        var admissionError: Error?
        var published = false, resumed = false
        do {
            #if SHADOW_SYNC_TESTING
            try testingHooks?.beforeTransfer?(anchor)
            let transferPath = testingHooks?.rejectTransfer == true ? "/unavailable-fixture-executable" : command.executable
            #else
            let transferPath = command.executable
            #endif
            let owner = try anchor.transfer(expectedExecutable: transferPath,
                generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
            childOwner = owner
            published = cancellation.publishRetainedChild(owner, leaseDescriptor: workingDirectoryDescriptor)
            #if SHADOW_SYNC_TESTING
            try testingHooks?.afterTransfer?(anchor, owner)
            #endif
        } catch { admissionError = error; cancellation.childAdmissionFailed() }
        defer { cancellation.clear(processID: pid) }
        var executableDrift = false, inheritedDescriptorDrift = false, inputDrift = false
        do { executableDrift = try Self.validateExecutable(command.executable, allowedOwners: [0, account.uid]) != executableIdentity }
        catch { executableDrift = true }
        if let descriptor = inheritedDescriptor, let inheritedIdentity {
            do { inheritedDescriptorDrift = try validateInherited(descriptor, requireStart: true) != inheritedIdentity }
            catch { inheritedDescriptorDrift = true }
        }
        if let descriptor = command.standardInputDescriptor, let inputIdentity {
            do { inputDrift = try Self.validateStandardInput(descriptor, owner: account.uid, requireStart: true) != inputIdentity }
            catch { inputDrift = true }
        }
        var childAdmissionRefused = false
        if published && admissionError == nil && !executableDrift && !inheritedDescriptorDrift && !inputDrift {
            do {
                try validateSuspendedChild?(pid)
                #if SHADOW_SYNC_TESTING
                try testingHooks?.beforeResume?(anchor, childOwner!)
                #endif
                resumed = cancellation.resumeRetainedChild(childOwner!, before: deadline)
            } catch { childAdmissionRefused = true; admissionError = error }
        }
        if !resumed {
            // Successful original suspended spawn only. Never CONT a rejected
            // child, and never construct cleanup authority from its PID.
            if let childOwner { _ = childOwner.send(SIGKILL) }
            else { _ = anchor.killSuspended() }
        }
        #if SHADOW_SYNC_TESTING
        do { try testingHooks?.afterResume?(anchor, childOwner, resumed) }
        catch { admissionError = admissionError ?? error; cancellation.cancel() }
        #endif
        var terminationDeadline: MonotonicDeadline?
        var sentKill = !resumed, timedOut = deadline.hasExpired, waitStatus: Int32?
        var reported = false
        let diagnostic = MonotonicDeadline(seconds: ChildProcessBudget.seconds(timeout) + 6)
        while waitStatus == nil || !streams.snapshot().complete {
            streams.drain()
            var observed: OwnedDirectChildObservation
            if let childOwner {
                #if SHADOW_SYNC_TESTING
                childOwner.testingBeforeReap()
                #endif
                observed = childOwner.reapAfterGroupDrain(streamsDrained: streams.snapshot().complete)
                if case .running = observed, childOwner.terminalStatusHeld != nil {
                    // The signal/reap mutex may have been held across terminal
                    // exit after our earlier read. Refresh actual EOF once so
                    // a completed graph settles before another termination
                    // request. Descendants/open streams still retain custody.
                    streams.drain()
                    observed = childOwner.reapAfterGroupDrain(streamsDrained: streams.snapshot().complete)
                }
            } else {
                switch anchor.poll() {
                case .reaped(let status): observed = .reaped(status)
                case .ownershipFailure(let code): observed = .ownershipFailure(code)
                default: observed = .running
                }
            }
            switch observed {
            case .reaped(let status): waitStatus = status
            case .ownershipFailure(let code):
                admissionError = admissionError ?? SecureStateError.systemCall("closed process custody", code)
            case .running: break
            }
            #if SHADOW_SYNC_TESTING
            do {
                let progress = streams.snapshot()
                try testingHooks?.duringDrain?(childOwner, progress.stdout.count, progress.stderr.count,
                    progress.stdoutTruncated, progress.stderrTruncated)
            } catch { admissionError = admissionError ?? error; cancellation.cancel() }
            #endif
            if waitStatus != nil && streams.snapshot().complete { break }
            if deadline.hasExpired { timedOut = true }
            let stopping = cancellation.isCancelled || deadline.hasExpired || !resumed || admissionError != nil || streams.snapshot().failed
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
                fputs("CLOSED PROCESS CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
            }
            var descriptors = [pollfd(fd: outRead, events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: errRead, events: Int16(POLLIN | POLLHUP), revents: 0)]
            _ = poll(&descriptors, 2, 10)
        }
        // Registry callbacks retain the same actual owner. EOF is sticky, so a
        // later callback never reads a descriptor after its enclosing close.
        let captured = streams.snapshot()
        if let admissionError { throw admissionError }
        do {
            executableDrift =
                try Self.validateExecutable(
                    command.executable,
                    allowedOwners: [0, account.uid]
                ) != executableIdentity
        } catch {
            executableDrift = true
        }
        if let descriptor = inheritedDescriptor,
           let inheritedIdentity {
            do {
                inheritedDescriptorDrift =
                    try validateInherited(descriptor, requireStart: false) != inheritedIdentity
            } catch {
                inheritedDescriptorDrift = true
            }
        }
        if let descriptor = command.standardInputDescriptor, let inputIdentity {
            do {
                let observed = try Self.validateStandardInput(
                    descriptor, owner: account.uid, requireStart: false
                )
                inputDrift = inputDrift || observed != inputIdentity
            } catch { inputDrift = true }
        }
        if executableDrift || inheritedDescriptorDrift || inputDrift || childAdmissionRefused {
            throw GitSafetyError.unsafeRepository(
                "closed executable or inherited input identity changed during admission"
            )
        }
        return ProcessResult(
            status: Self.decodedStatus(waitStatus!),
            stdout: captured.stdout,
            stderr: captured.stderr,
            stdoutTruncated: captured.stdoutTruncated,
            stderrTruncated: captured.stderrTruncated,
            outputByteLimit: outputLimit,
            timedOut: timedOut,
            cancelled: cancellation.isCancelled,
            terminationRequested:
                !resumed || terminationDeadline != nil,
            processID: pid
        )
    }

    public static func environment(
        account: EffectiveAccount,
        frozenConfigPath: String = "/dev/null"
    ) -> [String: String] {
        [
            "HOME": account.homeDirectory,
            "USER": account.username,
            "LOGNAME": account.username,
            "PATH": ClosedGitEnvironment.fixedPath,
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": "/private/tmp",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_CONFIG_GLOBAL": frozenConfigPath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_GRAFT_FILE": "/dev/null",
        ]
    }

    public static func awaEnvironment(
        account: EffectiveAccount
    ) -> [String: String] {
        var result = environment(account: account)
        result["AWA_POLICY"] =
            account.homeDirectory
                + "/dev/_ops/policy/worktree-policy.yml"
        result["AWA_GOVERNED_ROOT"] =
            account.homeDirectory + "/dev"
        return result
    }

    private static func validateEnvironment(
        _ environment: [String: String],
        account: EffectiveAccount
    ) throws {
        let required = Self.environment(account: account)
        let baseKeys = Set(required.keys)
        let awaKeys = Set([
            "AWA_POLICY",
            "AWA_GOVERNED_ROOT",
        ])
        let observedKeys = Set(environment.keys)
        let hasClosedAWAOverlay =
            observedKeys == baseKeys.union(awaKeys)
                && environment["AWA_POLICY"]
                    == account.homeDirectory
                        + "/dev/_ops/policy/worktree-policy.yml"
                && environment["AWA_GOVERNED_ROOT"]
                    == account.homeDirectory + "/dev"
        guard (
                observedKeys == baseKeys
                    || hasClosedAWAOverlay
              ),
              environment["HOME"] == account.homeDirectory,
              environment["USER"] == account.username,
              environment["LOGNAME"] == account.username,
              environment["PATH"] == ClosedGitEnvironment.fixedPath,
              environment["LANG"] == "C",
              environment["LC_ALL"] == "C",
              environment["TMPDIR"] == "/private/tmp",
              environment["GIT_TERMINAL_PROMPT"] == "0",
              environment["GIT_ASKPASS"] == "/usr/bin/false",
              environment["SSH_ASKPASS"] == "/usr/bin/false",
              environment["GIT_CONFIG_NOSYSTEM"] == "1",
              environment["GIT_NO_REPLACE_OBJECTS"] == "1",
              environment["GIT_GRAFT_FILE"] == "/dev/null",
              environment["GIT_CONFIG_GLOBAL"]?.hasPrefix("/") == true else {
            throw GitSafetyError.unsafeRepository(
                "closed process environment is invalid"
            )
        }
    }

    private static func validateExecutable(
        _ path: String,
        allowedOwners: Set<uid_t>
    ) throws -> FileIdentity {
        guard path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "closed executable path is invalid"
            )
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open closed executable",
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var observed = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(path, &observed) == 0,
              FileIdentity(opened).isRegular,
              opened.st_dev == observed.st_dev,
              opened.st_ino == observed.st_ino,
              (
                opened.st_uid == 0
                    ? opened.st_nlink >= 1
                    : opened.st_nlink == 1
              ),
              allowedOwners.contains(opened.st_uid),
              (opened.st_mode & 0o022) == 0,
              (opened.st_mode & 0o111) != 0 else {
            throw GitSafetyError.unsafeRepository(
                "closed executable identity is unsafe"
            )
        }
        return FileIdentity(opened)
    }

    private static func validateReadDescriptor(
        _ descriptor: Int32,
        allowedOwners: Set<uid_t>
    ) throws -> ReadDescriptorSnapshot {
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 0,
              flags >= 0,
              flags & O_ACCMODE == O_RDONLY,
              fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              allowedOwners.contains(info.st_uid),
              (
                info.st_uid == 0
                    ? info.st_nlink >= 1
                    : info.st_nlink == 1
              ),
              (info.st_mode & 0o022) == 0,
              info.st_size >= 0,
              info.st_size <= 16_777_216 else {
            throw GitSafetyError.unsafeRepository(
                "closed inherited input is unsafe"
            )
        }
        return ReadDescriptorSnapshot(
            identity: FileIdentity(info),
            size: Int64(info.st_size),
            modifiedSeconds:
                Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds:
                Int64(info.st_mtimespec.tv_nsec),
            changedSeconds:
                Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds:
                Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func validateStandardInput(
        _ descriptor: Int32,
        owner: uid_t,
        requireStart: Bool
    ) throws -> ReadDescriptorSnapshot {
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor > STDERR_FILENO,
              flags >= 0, flags & O_ACCMODE == O_RDONLY,
              fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == owner, info.st_nlink == 0,
              info.st_mode & 0o777 == 0o400,
              info.st_size > 0, info.st_size <= Int64(ClosedProcessInput.maximumBytes),
              !requireStart || lseek(descriptor, 0, SEEK_CUR) == 0 else {
            throw GitSafetyError.unsafeRepository("closed standard input is unsafe")
        }
        return ReadDescriptorSnapshot(
            identity: FileIdentity(info), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func spawnSuspended(
        command: ClosedProcessCommand,
        environment: [String: String],
        workingDirectoryDescriptor: Int32,
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        inheritedReadDescriptor: Int32?, streams: CapturedStreams
    ) throws -> OwnedSpawnAnchor {
        // Keep the borrowed source above every fixed child destination. In
        // particular fd 9 must receive a real dup2 action: mapping a CLOEXEC
        // source onto itself can leave the child's sealed input closed.
        var normalizedReadDescriptor: Int32?
        if let inheritedReadDescriptor {
            let duplicate = fcntl(inheritedReadDescriptor, F_DUPFD_CLOEXEC, 10)
            guard duplicate >= 10 else {
                throw SecureStateError.systemCall("duplicate closed inherited input", errno)
            }
            normalizedReadDescriptor = duplicate
        }
        defer { if let normalizedReadDescriptor { Darwin.close(normalizedReadDescriptor) } }
        #if SHADOW_SYNC_TESTING
        if inheritedReadDescriptor == ClosedProcessCommand.inheritedReadDescriptorNumber {
            print("METRIC closed-input-source9-normalized")
        }
        #endif
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw SecureStateError.systemCall(
                "initialize closed process spawn",
                errno
            )
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        var code = posix_spawn_file_actions_addfchdir(
            &actions,
            workingDirectoryDescriptor
        )
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                standardInput,
                STDIN_FILENO
            )
        }
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                standardOutput,
                STDOUT_FILENO
            )
        }
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                standardError,
                STDERR_FILENO
            )
        }
        if code == 0,
           let normalizedReadDescriptor {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                normalizedReadDescriptor,
                ClosedProcessCommand
                    .inheritedReadDescriptorNumber
            )
        }
        guard code == 0 else {
            throw SecureStateError.systemCall(
                "configure closed process spawn",
                code
            )
        }
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_START_SUSPENDED
        )
        code = posix_spawnattr_setflags(&attributes, flags)
        if code == 0 {
            code = posix_spawnattr_setpgroup(&attributes, 0)
        }
        guard code == 0 else {
            throw SecureStateError.systemCall(
                "configure closed process group",
                code
            )
        }
        let argv = [command.executable] + command.arguments
        let env = environment.keys.sorted().map {
            "\($0)=\(environment[$0]!)"
        }
        return try Self.withCStringArray(argv) { arguments in
            try Self.withCStringArray(env) { environment in
                #if SHADOW_SYNC_TESTING
                if let registry = try RuntimeFixtureSession.currentIfBound() {
                    return try RuntimeFixtureSpawn.spawn(registry: registry, executable: command.executable,
                        actions: &actions, attributes: &attributes, arguments: arguments, environment: environment,
                        streamsDrained: { streams.drain(); return streams.snapshot().complete },
                        beforeRegistration: testingHooks?.afterSpawn)
                }
                #endif
                return try OwnedSpawnAnchor.spawn(executable: command.executable, actions: &actions,
                    attributes: &attributes, arguments: arguments, environment: environment)
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

    private static func decodedStatus(_ status: Int32) -> Int32 {
        if (status & 0x7F) == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    private static func close(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private static func withCStringArray<T>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<
            UnsafeMutablePointer<CChar>?
        >) throws -> T
    ) rethrows -> T {
        var storage = values.map { strdup($0) }
        storage.append(nil)
        defer {
            for pointer in storage where pointer != nil {
                free(pointer)
            }
        }
        return try storage.withUnsafeMutableBufferPointer {
            try body($0.baseAddress!)
        }
    }
}
