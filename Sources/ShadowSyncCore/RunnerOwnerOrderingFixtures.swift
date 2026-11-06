#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Exercises the production token and runner, not a separate fixture reaper.
private enum RunnerOrderingError: Error { case message(String) }

enum RunnerOwnerOrderingFixtures {
    private final class Results: @unchecked Sendable {
        private let mutex = NSLock()
        private var identity: ProcessIdentity?
        private var value: Result<ProcessResult, Error>?
        private var cancellationFinished = false
        func publish(_ identity: ProcessIdentity) { mutex.lock(); self.identity = identity; mutex.unlock() }
        func finish(_ value: Result<ProcessResult, Error>) { mutex.lock(); self.value = value; mutex.unlock() }
        func finishCancellation() { mutex.lock(); cancellationFinished = true; mutex.unlock() }
        var published: ProcessIdentity? { mutex.lock(); defer { mutex.unlock() }; return identity }
        var result: Result<ProcessResult, Error>? { mutex.lock(); defer { mutex.unlock() }; return value }
        var cancellationDone: Bool { mutex.lock(); defer { mutex.unlock() }; return cancellationFinished }
    }

    static func closed() throws {
        let fixture = try M1TemporaryDirectory()
        defer { fixture.remove() }
        let directory = Darwin.open(fixture.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw RunnerOrderingError.message("closed ordering directory") }
        defer { close(directory) }
        let token = CancellationToken()
        let results = Results()
        let home = fixture.path + "/home"
        guard mkdir(home, 0o700) == 0 else { throw RunnerOrderingError.message("closed ordering home") }
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let environment = ClosedProcessRunner.environment(account: account)
        try exercise(token: token, results: results, resumesSuspendedChild: true) {
            try ClosedProcessRunner().run(
                command: ClosedProcessCommand(executable: "/bin/sleep", arguments: ["1"]),
                environment: environment,
                workingDirectoryDescriptor: directory,
                account: account,
                timeout: 5,
                cancellation: token,
                validateSuspendedChild: { pid in
                    guard let owner = token.ownedChild(processID: pid) else {
                        throw RunnerOrderingError.message("closed runner did not publish custody")
                    }
                    results.publish(owner.identity)
                }
            )
        }
    }

    static func descriptor(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let handle = try RepositoryHandle.open(fixture.candidate)
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let frozen = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        let request = ProcessRequest(
            executable: DescriptorProcessRunner.gitPath,
            arguments: ["-c", GitCommandPolicy.testRootMarker,
                        GitCommandPolicy.syntheticOwnerExitMarker,
                        "--no-replace-objects", "--no-lazy-fetch",
                        "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            environment: fixture.closedEnvironment(frozenConfigPath: frozen.snapshot.frozenPath),
            workingDirectoryDescriptor: handle.worktreeDescriptor,
            inheritedLeaseDescriptor: lease,
            frozenConfigDescriptor: frozen.descriptor,
            frozenConfigDirectoryDescriptor: frozen.directoryDescriptor,
            timeoutSeconds: 5,
            trampolineExecutable: executable,
            executionSnapshot: try handle.executionSnapshot(
                account: fixture.account, frozenConfiguration: frozen, admission: nil
            )
        )
        let token = CancellationToken()
        let results = Results()
        let runner = DescriptorProcessRunner(processObserver: { identity in
            // Never reenter the token from its publication callback.
            if let identity { results.publish(identity) }
            return true
        })
        try exercise(token: token, results: results, resumesSuspendedChild: false) {
            try runner.run(request, cancellation: token)
        }
    }

    private static func exercise(
        token: CancellationToken,
        results: Results,
        resumesSuspendedChild: Bool,
        run: @escaping @Sendable () throws -> ProcessResult
    ) throws {
        let barrier = OwnedDirectChildTestingBarrier(pauseTimeout: ChildProcessBudget.seconds(3))
        let reapBarrier = OwnedDirectChildTestingBarrier(pauseTimeout: ChildProcessBudget.seconds(3))
        var owner: OwnedDirectChild?
        var cancellationStarted = false
        Thread.detachNewThread { results.finish(Result { try run() }) }
        defer {
            // Release the bounded signal seam before cleanup; join both owned
            // test threads before borrowed descriptors or fixture roots close.
            reapBarrier.release()
            barrier.release()
            if results.result == nil {
                token.cancel()
                _ = owner?.send(SIGKILL)
            }
            let diagnostic = MonotonicDeadline(seconds: 10)
            var reported = false
            while results.result == nil || (cancellationStarted && !results.cancellationDone) {
                if diagnostic.hasExpired && !reported {
                    fputs("RUNNER ORDERING CLEANUP PENDING\n", stderr); fflush(stderr)
                    reported = true
                }
                // The original production runner remains the sole reaper.
                // Do not abort the suite or release borrowed fixture resources
                // while either owned thread still has unresolved custody.
                usleep(10_000)
            }
        }
        try check(waitUntil(seconds: 3) { results.published != nil || results.result != nil }, "runner publication timed out")
        guard let identity = results.published,
              let adopted = token.ownedChild(processID: identity.processID) else {
            throw RunnerOrderingError.message("runner exited without publishing its direct-child owner")
        }
        owner = adopted
        if resumesSuspendedChild {
            try check(waitUntil(seconds: 1) { adopted.testingSuspendedSpawnHasResumed }, "closed runner never resumed its child")
        }
        adopted.testingPauseNextReap(reapBarrier)
        try check(reapBarrier.waitUntilEntered(), "runner did not reach its next reap boundary")
        let priorSignals = adopted.testingSignalSystemCallCount
        adopted.testingPauseNextSignal(barrier)
        cancellationStarted = true
        Thread.detachNewThread { token.cancel(); results.finishCancellation() }
        try check(barrier.waitUntilEntered(), "cancellation did not reach final-check signal barrier")
        try check(try waitUntil(seconds: ChildProcessBudget.seconds(2)) { try terminalWithoutReaping(identity.processID) }, "fixed child did not exit while cancellation held custody")
        // Force the runner into its reap attempt only after terminal exit.
        // Otherwise it could block in a second cancellation signal instead.
        reapBarrier.release()
        // More than two normal 50 ms runner poll intervals. The exact PID must
        // remain waitable and the actual runner must not publish completion.
        usleep(150_000)
        try check(try terminalWithoutReaping(identity.processID), "runner reaped while cancellation still held the signal anchor")
        try check(results.result == nil, "runner completed across a paused signal")
        barrier.release()
        try check(waitUntil(seconds: 5) { results.result != nil && results.cancellationDone }, "runner did not settle after signal release")
        let result = try results.result!.get()
        try check(result.status == 0 && result.cancelled && !result.timedOut, "runner fabricated terminal/cancellation status")
        try check(adopted.observation == .reaped(0), "runner did not cache the exact natural exit")
        try check(adopted.testingSignalSystemCallCount == priorSignals + 1, "signal syscall escaped serialized custody: expected \(priorSignals + 1), observed \(adopted.testingSignalSystemCallCount)")
        try check(token.ownedChild(processID: identity.processID) == nil, "terminal token owner was not cleared")
        let calls = adopted.testingSignalSystemCallCount
        try check(!adopted.send(SIGTERM) && !adopted.send(SIGKILL), "reaped owner allowed another signal")
        token.cancel()
        try check(adopted.testingSignalSystemCallCount == calls, "later cancellation signaled a reaped child")
        var status: Int32 = 0
        try check(waitpid(identity.processID, &status, WNOHANG) == -1 && errno == ECHILD, "runner did not exclusively reap its exact child")
    }

    private static func terminalWithoutReaping(_ pid: pid_t) throws -> Bool {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result != 0 {
            let code = errno
            if code == EINTR { return false }
            throw RunnerOrderingError.message("runner lost unreaped child custody: errno=\(code)")
        }
        if info.si_pid == 0 { return false }
        guard info.si_pid == pid, info.si_code == CLD_EXITED, info.si_status == 0 else {
            throw RunnerOrderingError.message("unexpected child terminal observation: pid=\(info.si_pid),code=\(info.si_code),status=\(info.si_status)")
        }
        return true
    }

    private static func waitUntil(seconds: TimeInterval, _ predicate: () throws -> Bool) rethrows -> Bool {
        let deadline = MonotonicDeadline(seconds: seconds)
        repeat {
            if try predicate() { return true }
            usleep(5_000)
        } while !deadline.hasExpired
        return try predicate()
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RunnerOrderingError.message(message) }
    }
}
#endif
