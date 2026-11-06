import Darwin
import Foundation

// Trace2 accepts an already-open descriptor in2...9. Avoid reopening /dev/fd
// as a pathname; the spawn boundary retains and maps this exact owned pipe.
let discoveryTraceDescriptor: Int32 = 9

struct DiscoveryGitProbe: Sendable {
    let account: EffectiveAccount
    private let boundRun: (@Sendable (RepositoryCandidate, DiscoveryGitCommand) throws -> CustodyRegistryResult)?
    private let metadata: DiscoveryMetadataAccess?
    #if SHADOW_SYNC_TESTING
    let observer: (@Sendable ([String]) -> Void)?
    let candidateObserver: (@Sendable (String, [String]) -> Void)?
    let processObserver: (@Sendable (ProcessIdentity) -> Void)?
    let injectWaitError: Bool
    #endif

    init(account: EffectiveAccount) {
        self.account = account
        boundRun = nil
        metadata = nil
        #if SHADOW_SYNC_TESTING
        observer = nil
        candidateObserver = nil
        processObserver = nil
        injectWaitError = false
        #endif
    }

    init(account: EffectiveAccount, binder: SelectedRepositoryScopeBinder,
         scope: ValidatedSelectedRepositoryScope, cancellation: CancellationToken) {
        self.account = account
        metadata = DiscoveryMetadataAccess(binder: binder, scope: scope, cancellation: cancellation)
        boundRun = { candidate, command in
            try binder.executeDiscovery(scope: scope, candidate: candidate, command: command, cancellation: cancellation)
        }
        #if SHADOW_SYNC_TESTING
        observer = nil; candidateObserver = nil; processObserver = nil; injectWaitError = false
        #endif
    }

    #if SHADOW_SYNC_TESTING
    init(
        account: EffectiveAccount,
        observer: (@Sendable ([String]) -> Void)?,
        candidateObserver: (@Sendable (String, [String]) -> Void)? = nil,
        processObserver: (@Sendable (ProcessIdentity) -> Void)? = nil,
        injectWaitError: Bool = false
    ) {
        self.account = account
        boundRun = nil
        metadata = nil
        self.observer = observer
        self.candidateObserver = candidateObserver
        self.processObserver = processObserver
        self.injectWaitError = injectWaitError
    }
    #endif

    func validate(
        _ candidate: RepositoryCandidate
    ) throws -> LocalRepositoryInspection {
        let retainedHandle = try open(candidate)
        do {
            try DiscoveryMetadataAccess.withHandle(metadata, retainedHandle, .busy) { try retainedHandle.rejectBusyState() }
        } catch GitSafetyError.busy {
            return LocalRepositoryInspection(
                localMainCommit: nil,
                cachedMainRelation: .unavailable,
                block: .busy
            )
        }
        _ = try validateCloneOrigin(candidate)

        let noLinkedWorktrees =
            try DiscoveryMetadataAccess.withHandle(metadata, retainedHandle, .topology) { try retainedHandle.verifyNoRegisteredLinkedWorktrees() }
        if metadata != nil, !noLinkedWorktrees {
            throw GitSafetyError.unsafeRepository("linked discovery resources require their separate policy admission")
        }
        let inspection = try LocalRepositoryInspection.inspect(
            handle: retainedHandle,
            knownNoLinkedWorktrees: noLinkedWorktrees,
            metadata: metadata
        ) { arguments in
            let result = try run(
                candidate: candidate,
                arguments: arguments
            )
            return LocalRepositoryCommandResult(
                status: result.status,
                stdout: result.stdout,
                stdoutTruncated: false,
                diagnostic: result.diagnostic
            )
        }
        if noLinkedWorktrees {
            guard try DiscoveryMetadataAccess.withHandle(metadata, retainedHandle, .topology, {
                try retainedHandle.verifyNoRegisteredLinkedWorktrees()
            }) else {
                throw GitSafetyError.unsafeRepository(
                    "worktree topology changed during discovery"
                )
            }
        }
        try DiscoveryMetadataAccess.withHandle(metadata, retainedHandle, .identity) { try retainedHandle.revalidate() }
        return inspection
    }

    private func open(_ candidate: RepositoryCandidate) throws -> RepositoryHandle {
        if let metadata {
            return try metadata.withRead(candidate, .identity) {
                let handle = try RepositoryHandle.open(candidate)
                try handle.revalidate()
                return handle
            }
        }
        #if SHADOW_SYNC_TESTING
        let handle = try RepositoryHandle.open(candidate)
        try handle.revalidate()
        return handle
        #else
        throw RepositoryDiscoveryExecutionError.commandAdapterUnavailable
        #endif
    }

    func validateCloneOrigin(
        _ candidate: RepositoryCandidate
    ) throws -> String {
        let retainedHandle = try open(candidate)
        guard let rawIdentity = GitHubIdentity.parse(candidate.rawOrigin),
              candidate.originIdentity == rawIdentity,
              candidate.id.lowercased() == rawIdentity.canonicalName else {
            throw GitSafetyError.originChanged
        }
        let effectiveURL = try run(
            candidate: candidate,
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "remote", "get-url", "--all", "origin",
            ],
            captureTransportConfiguration: true
        )
        guard effectiveURL.status == 0 else {
            throw GitSafetyError.commandFailed(
                "discovery Git probe",
                effectiveURL.status,
                effectiveURL.diagnostic
            )
        }
        guard let effectiveText = String(
            data: effectiveURL.stdout,
            encoding: .utf8
        ), !effectiveText.contains("\r") else {
            throw GitSafetyError.unsafeRepository(
                "discovery Git output is malformed"
            )
        }
        let effectiveLines = effectiveText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard effectiveLines.count == 1,
              let effectiveIdentity = GitHubIdentity.parse(effectiveLines[0]),
              effectiveIdentity.canonicalName == rawIdentity.canonicalName else {
            throw GitSafetyError.originChanged
        }
        try EffectiveTransportConfiguration.validate(
            status: effectiveURL.transportConfiguration.isEmpty ? 1 : 0,
            output: effectiveURL.transportConfiguration,
            transport: effectiveIdentity.transport,
            operation: "discovery Git transport config probe",
            diagnostic: effectiveURL.diagnostic
        )
        try DiscoveryMetadataAccess.withHandle(metadata, retainedHandle, .identity) { try retainedHandle.revalidate() }
        return effectiveLines[0]
    }

    struct Result {
        let status: Int32
        let stdout: Data
        let transportConfiguration: Data
        let diagnostic: String
    }

    func run(
        candidate: RepositoryCandidate,
        workingPath: String? = nil,
        arguments: [String],
        timeoutSeconds: TimeInterval = 5,
        captureTransportConfiguration: Bool = false
    ) throws -> Result {
        let command = try DiscoveryGitCommand(arguments: arguments,
            captureTransportConfiguration: captureTransportConfiguration,
            timeoutSeconds: timeoutSeconds)
        #if SHADOW_SYNC_TESTING
        observer?(command.arguments)
        candidateObserver?(candidate.path, command.arguments)
        #endif
        if let boundRun {
            guard workingPath == nil || workingPath == candidate.path else { throw SelectedRepositoryScopeError.changed }
            let result = try boundRun(candidate, command)
            guard result.phase == .finished, result.reason == nil || result.reason == CustodyReason.none,
                  let journal = result.journal, journal.phase == .terminal, journal.kind == .discoveryGit,
                  journal.reason == CustodyReason.none, let raw = journal.waitStatus, raw & 0x7f == 0,
                  journal.outcome == (raw == 0 ? .completed : .commandFailed),
                  result.stdout.count <= DiscoveryGitCommand.stdoutLimit,
                  result.stderr.count <= DiscoveryGitCommand.stderrLimit,
                  result.trace.count <= (command.capturesTransportConfiguration ? DiscoveryGitCommand.traceLimit : 0) else {
                throw GitSafetyError.unsafeRepository("discovery command did not complete under retained custody")
            }
            return Result(status: Int32((raw >> 8) & 0xff), stdout: result.stdout,
                transportConfiguration: command.capturesTransportConfiguration
                    ? try transportConfigurationOutput(from: result.trace) : Data(),
                diagnostic: Redactor.sanitize(String(decoding: result.stderr, as: UTF8.self)))
        }
        #if SHADOW_SYNC_TESTING
        let environment = command.environment(account: account)
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var tracePipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0,
              pipe(&stderrPipe) == 0,
              pipe(&tracePipe) == 0 else {
            closeDiscoveryDescriptors(stdoutPipe + stderrPipe + tracePipe)
            throw SecureStateError.systemCall("pipe discovery Git output", errno)
        }
        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0]
        let stderrWrite = stderrPipe[1]
        let traceRead = tracePipe[0]
        let traceWrite = tracePipe[1]
        defer {
            close(stdoutRead)
            close(stderrRead)
            close(traceRead)
        }
        for descriptor in [stdoutRead, stderrRead, traceRead] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                let code = errno
                close(stdoutWrite)
                close(stderrWrite)
                close(traceWrite)
                throw SecureStateError.systemCall(
                    "fcntl discovery Git output",
                    code
                )
            }
        }
        let retainedHandle = try RepositoryHandle.open(candidate)
        let requestedWorkingPath = workingPath ?? candidate.path
        let expectedWorkingIdentity: RepositoryDirectoryIdentity
        if let workingPath {
            expectedWorkingIdentity = try retainedHandle
                .verifyWorktreeClaim(path: workingPath).rootIdentity
        } else if let rootIdentity = candidate.rootIdentity {
            expectedWorkingIdentity = rootIdentity
        } else {
            throw GitSafetyError.unsafeRepository(
                "discovery working root lacks identity"
            )
        }
        let directoryDescriptor = try RepositoryRootPathIdentity
            .withVerifiedDirectory(
                path: requestedWorkingPath,
                expected: expectedWorkingIdentity
            ) { opened -> Int32 in
                let retained = fcntl(
                    opened.descriptor,
                    F_DUPFD_CLOEXEC,
                    0
                )
                guard retained >= 0 else {
                    throw SecureStateError.systemCall(
                        "retain discovery Git directory",
                        errno
                    )
                }
                return retained
            }
        guard directoryDescriptor >= 0 else {
            close(stdoutWrite)
            close(stderrWrite)
            close(traceWrite)
            throw SecureStateError.systemCall("open discovery Git directory", errno)
        }
        defer { close(directoryDescriptor) }
        let nullDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            close(stdoutWrite)
            close(stderrWrite)
            close(traceWrite)
            throw SecureStateError.systemCall("open discovery Git stdin", errno)
        }
        defer { close(nullDescriptor) }
        var startGate: [Int32] = [-1, -1]
        guard pipe(&startGate) == 0,
              fcntl(startGate[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(startGate[1], F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            closeDiscoveryDescriptors(startGate)
            close(stdoutWrite)
            close(stderrWrite)
            close(traceWrite)
            throw SecureStateError.systemCall("pipe discovery Git start gate", code)
        }

        let streams = DiscoveryFixtureStreams(stdout: stdoutRead, stderr: stderrRead, trace: traceRead)
        let anchor: OwnedSpawnAnchor
        do {
            anchor = try spawnDiscoveryGitFixture(
                arguments: command.arguments, environment: environment,
                directoryDescriptor: directoryDescriptor, inputDescriptor: nullDescriptor,
                outputDescriptor: stdoutWrite, errorDescriptor: stderrWrite,
                traceDescriptor: traceWrite, startGateDescriptor: startGate[0],
                streamsDrained: { streams.drain(); return streams.snapshot().complete })
        } catch {
            closeDiscoveryDescriptors(startGate)
            close(stdoutWrite); close(stderrWrite); close(traceWrite)
            throw error
        }
        // Original custody is retained before transfer or observers can fail.
        // Close every parent writer before an independent drain seeks EOF.
        closeDiscoveryDescriptors(startGate)
        close(stdoutWrite); close(stderrWrite); close(traceWrite)
        defer { RuntimeFixtureSession.drain(anchor) }
        let owner = try anchor.transfer(expectedExecutable: discoveryFixtureGitExecutable,
            generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
        processObserver?(owner.identity)
        guard owner.send(SIGCONT) else { throw RuntimeFixtureCustody.Failure.admissionClosed }
        if injectWaitError {
            // Preserve the legacy wait-error scenario and classification while
            // the original anchor, rather than a borrowed PID, owns cleanup.
            throw SecureStateError.systemCall("waitpid discovery Git", EIO)
        }
        let registry = try RuntimeFixtureSession.current()
        let deadline = MonotonicDeadline(seconds: ChildProcessBudget.seconds(command.workSeconds))
        var waitStatus: Int32 = 0
        while true {
            streams.drain()
            let output = streams.snapshot()
            if registry.snapshot().reason != nil { throw RuntimeFixtureCustody.Failure.admissionClosed }
            if output.failed { throw GitSafetyError.unsafeRepository("discovery Git output read failed") }
            if case .reaped(let status) = owner.reapAfterGroupDrain(streamsDrained: output.complete) {
                waitStatus = status
                break
            }
            if case .ownershipFailure(let code) = owner.poll() {
                throw SecureStateError.systemCall("waitpid discovery Git", code)
            }
            if deadline.hasExpired {
                throw GitSafetyError.commandFailed("discovery Git timeout", 124, "")
            }
            var descriptors = [
                pollfd(fd: stdoutRead, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stderrRead, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: traceRead, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            _ = poll(&descriptors, 3, 2)
        }
        let output = streams.snapshot()
        guard output.complete, !output.failed, !output.overflow else {
            throw GitSafetyError.unsafeRepository("discovery Git output exceeded its bound")
        }
        try retainedHandle.revalidate()
        if let workingPath {
            _ = try retainedHandle.verifyWorktreeClaim(path: workingPath)
        }
        return Result(
            status: decodedDiscoveryStatus(waitStatus),
            stdout: output.stdout,
            transportConfiguration:
                command.capturesTransportConfiguration
                    ? try transportConfigurationOutput(from: output.trace)
                    : Data(),
            diagnostic: Redactor.sanitize(
                String(decoding: output.stderr, as: UTF8.self)
            )
        )
        #else
        throw RepositoryDiscoveryExecutionError.commandAdapterUnavailable
        #endif
    }
}

private func transportConfigurationOutput(from trace: Data) throws -> Data {
    guard !trace.isEmpty, trace.last == 0x0A else {
        throw GitSafetyError.malformedConfig(
            "effective transport trace is incomplete"
        )
    }
    var observedVersion = false
    var names: Set<String> = []
    for line in trace.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard let value = try JSONSerialization.jsonObject(with: Data(line))
                as? [String: Any],
              let event = value["event"] as? String else {
            throw GitSafetyError.malformedConfig(
                "effective transport trace is malformed"
            )
        }
        if event == "version" {
            observedVersion = true
        }
        guard event == "def_param" else { continue }
        guard let parameter = value["param"] as? String else {
            throw GitSafetyError.malformedConfig(
                "effective transport trace parameter is malformed"
            )
        }
        let normalized = parameter.lowercased()
        if normalized == "remote.origin.uploadpack"
            || normalized == "core.sshcommand" {
            names.insert(normalized)
        }
    }
    guard observedVersion else {
        throw GitSafetyError.malformedConfig(
            "effective transport trace was not activated"
        )
    }
    var output = Data()
    for name in names.sorted() {
        output.append(Data(name.utf8))
        output.append(0)
    }
    return output
}

#if SHADOW_SYNC_TESTING
#if SHADOW_SYNC_TESTING
// Local native fixture identity is independently bound by the executor. This
// direct developer tool avoids an unqualified launcher exec transition.
let discoveryFixtureGitExecutable = "/Library/Developer/CommandLineTools/usr/bin/git"

/// Same descriptor configuration as production, with original suspended-child
/// custody before any fallible identity validation. No PID adoption entrypoint.
func spawnDiscoveryGitFixture(
    arguments: [String],
    environment: [String: String],
    directoryDescriptor: Int32,
    inputDescriptor: Int32,
    outputDescriptor: Int32,
    errorDescriptor: Int32,
    traceDescriptor: Int32,
    startGateDescriptor: Int32,
    streamsDrained: @escaping @Sendable () -> Bool,
    useQualifiedLauncherFixture: Bool = false
) throws -> OwnedSpawnAnchor {
    let executable = useQualifiedLauncherFixture ? "/usr/bin/git" : discoveryFixtureGitExecutable
    let registry = try RuntimeFixtureSession.current()
    return try withDiscoverySpawnConfiguration(
        arguments: arguments, environment: environment,
        directoryDescriptor: directoryDescriptor, inputDescriptor: inputDescriptor,
        outputDescriptor: outputDescriptor, errorDescriptor: errorDescriptor,
        traceDescriptor: traceDescriptor, startGateDescriptor: startGateDescriptor, executable: executable, suspended: true
    ) { actions, attributes, argv, envp in
        try RuntimeFixtureSpawn.spawn(registry: registry, executable: executable,
            actions: &actions, attributes: &attributes, arguments: argv,
            environment: envp, streamsDrained: streamsDrained)
    }
}
#endif

private func withDiscoverySpawnConfiguration<Value>(
    arguments: [String],
    environment: [String: String],
    directoryDescriptor: Int32,
    inputDescriptor: Int32,
    outputDescriptor: Int32,
    errorDescriptor: Int32,
    traceDescriptor: Int32,
    startGateDescriptor: Int32,
    executable: String,
    suspended: Bool,
    spawn: (inout posix_spawn_file_actions_t?, inout posix_spawnattr_t?,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
) throws -> Value {
    // File actions execute in order. Preserve every source above the fixed
    // child destinations before any dup2 can replace another action's input.
    // This mirrors ProcessRunner's protected descriptor allocation boundary.
    var remapSources: [Int32] = []
    defer {
        for descriptor in remapSources { close(descriptor) }
    }
    for descriptor in [inputDescriptor, outputDescriptor, errorDescriptor,
                       startGateDescriptor, traceDescriptor] {
        let retained = fcntl(descriptor, F_DUPFD_CLOEXEC, 256)
        guard retained >= 0 else {
            throw SecureStateError.systemCall("retain discovery spawn source", errno)
        }
        remapSources.append(retained)
    }
    var actions: posix_spawn_file_actions_t?
    let actionsCode = posix_spawn_file_actions_init(&actions)
    guard actionsCode == 0 else {
        throw SecureStateError.systemCall("posix_spawn discovery Git actions", actionsCode)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    let attributesCode = posix_spawnattr_init(&attributes)
    guard attributesCode == 0 else {
        throw SecureStateError.systemCall("posix_spawn discovery Git attributes", attributesCode)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    var code = posix_spawn_file_actions_addfchdir(&actions, directoryDescriptor)
    if code == 0 {
        code = posix_spawn_file_actions_adddup2(
            &actions, remapSources[0], STDIN_FILENO
        )
    }
    if code == 0 {
        code = posix_spawn_file_actions_adddup2(
            &actions, remapSources[1], STDOUT_FILENO
        )
    }
    if code == 0 {
        code = posix_spawn_file_actions_adddup2(
            &actions, remapSources[2], STDERR_FILENO
        )
    }
    if code == 0 {
        code = posix_spawn_file_actions_adddup2(
            &actions,
            remapSources[3],
            197
        )
    }
    if code == 0 {
        code = posix_spawn_file_actions_adddup2(
            &actions,
            remapSources[4],
            discoveryTraceDescriptor
        )
    }
    guard code == 0 else {
        throw SecureStateError.systemCall(
            "posix_spawn discovery Git file action",
            code
        )
    }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        | (suspended ? Int16(POSIX_SPAWN_START_SUSPENDED) : 0)
    code = posix_spawnattr_setflags(&attributes, flags)
    if code == 0 {
        code = posix_spawnattr_setpgroup(&attributes, 0)
    }
    guard code == 0 else {
        throw SecureStateError.systemCall(
            "posix_spawn discovery Git attributes",
            code
        )
    }
    return try withDiscoveryCStringArray([executable] + arguments) { argv in
        try withDiscoveryCStringArray(
            environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        ) { envp in
            try spawn(&actions, &attributes, argv, envp)
        }
    }
}

#if SHADOW_SYNC_TESTING
/// One synchronized reader per stream, shared by the command and guardian.
/// Readers stay owned until EOF and original process-group retirement converge.
private final class DiscoveryFixtureStreams: @unchecked Sendable {
    struct Snapshot {
        let stdout: Data, stderr: Data, trace: Data
        let complete: Bool, failed: Bool, overflow: Bool
    }
    private struct Capture {
        let descriptor: Int32, limit: Int
        var data = Data()
        var ended = false, failed = false, overflow = false
    }
    private let lock = NSLock()
    private var out: Capture, err: Capture, trace: Capture
    init(stdout: Int32, stderr: Int32, trace: Int32) {
        out = Capture(descriptor: stdout, limit: DiscoveryGitCommand.stdoutLimit)
        err = Capture(descriptor: stderr, limit: DiscoveryGitCommand.stderrLimit)
        self.trace = Capture(descriptor: trace, limit: DiscoveryGitCommand.traceLimit)
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(stdout: out.data, stderr: err.data, trace: trace.data,
            complete: out.ended && err.ended && trace.ended,
            failed: out.failed || err.failed || trace.failed,
            overflow: out.overflow || err.overflow || trace.overflow)
    }
    func drain() {
        lock.lock(); defer { lock.unlock() }
        Self.read(&out); Self.read(&err); Self.read(&trace)
    }
    private static func read(_ capture: inout Capture) {
        guard !capture.ended, !capture.failed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Bounded passes let cancellation and the other streams make progress.
        for _ in 0..<16 {
            let count = Darwin.read(capture.descriptor, &bytes, bytes.count)
            if count > 0 {
                let remaining = max(0, capture.limit - capture.data.count)
                capture.data.append(contentsOf: bytes.prefix(min(count, remaining)))
                if count > remaining { capture.overflow = true }
            } else if count == 0 { capture.ended = true; return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN { return }
            else { capture.failed = true; return }
        }
    }
}
#endif

private func decodedDiscoveryStatus(_ status: Int32) -> Int32 {
    if (status & 0x7F) == 0 {
        return (status >> 8) & 0xFF
    }
    return 128 + (status & 0x7F)
}

private func closeDiscoveryDescriptors(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 {
        close(descriptor)
    }
}

private func withDiscoveryCStringArray<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
) rethrows -> T {
    let pointers = strings.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    var mutable = pointers + [nil]
    return try mutable.withUnsafeMutableBufferPointer {
        try body($0.baseAddress!)
    }
}

#endif
