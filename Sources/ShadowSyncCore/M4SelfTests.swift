#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum M4SelfTestRunner {
    public static func runAll(
        onPass: (String) -> Void = { _ in }
    ) throws -> [String] {
        signal(SIGPIPE, SIG_IGN)
        let tests: [(String, () throws -> Void)] = [
            ("m4-lifecycle-plist-bound-contract", testLifecyclePlistContract),
            ("m4-lifecycle-plist-unsafe-input", testLifecyclePlistUnsafe),
            ("m4-lifecycle-plist-read-replacement", testLifecyclePlistReadReplacement),
            ("m4-lifecycle-plist-parent-replacement", testLifecyclePlistParentReplacement),
            ("m4-custody-request-roundtrip", CustodyProtocolSelfTests.roundTrip),
            ("m4-custody-closed-json", CustodyProtocolSelfTests.closedJSON),
            ("m4-custody-request-bindings", CustodyProtocolSelfTests.bindings),
            ("m4-custody-descriptor-manifest", CustodyProtocolSelfTests.descriptorManifest),
            ("m4-custody-resource-bounds", CustodyProtocolSelfTests.resourceBounds),
            ("m4-custody-absolute-budgets", CustodyProtocolSelfTests.absoluteBudgets),
            ("m4-custody-cancellation-budget", CustodyProtocolSelfTests.cancellationBudget),
            ("m4-custody-closed-messages", CustodyProtocolSelfTests.messages),
            ("m4-custody-frame-fragments", CustodyProtocolSelfTests.frameFragments),
            ("m4-custody-frame-refusals", CustodyProtocolSelfTests.frameRefusals),
            ("m4-custody-admission-order", CustodyProtocolSelfTests.admission),
            ("m4-custody-admission-faults", CustodyProtocolSelfTests.admissionFaults),
            ("m4-custody-spawn-closed-flags", CustodyAnchorSelfTests.closedFlags),
            ("m4-custody-failed-identity-retains-anchor", CustodyAnchorSelfTests.failedIdentity),
            ("m4-custody-spawn-transfer-once", CustodyAnchorSelfTests.transferOnce),
            ("m4-custody-transferred-bootstrap-cancel", CustodyAnchorSelfTests.bootstrapCancel),
            ("m4-custody-terminal-hold", CustodyAnchorSelfTests.terminalHold),
            ("m4-custody-terminal-group-drain", CustodyAnchorSelfTests.groupDrain),
            ("m4-custody-enumeration-refuses-incomplete", CustodyAnchorSelfTests.incompleteEnumeration),
            ("m4-custody-held-concurrent-finalizers", CustodyAnchorSelfTests.concurrentFinalizers),
            ("m4-custody-held-ownership-failure", CustodyAnchorSelfTests.ownershipFailure),
            ("m4-custody-held-signal-reap-ordering", CustodyAnchorSelfTests.signalReapOrdering),
            ("m4-lifecycle-closed-forms", { try testLifecycleLaunchContract("forms") }),
            ("m4-lifecycle-status-valid", { try testLifecycleLaunchContract("valid") }),
            ("m4-lifecycle-status-refusals", { try testLifecycleLaunchContract("refusals") }),
            ("m4-lifecycle-command-output", testLifecycleCommandOutput),
            ("m4-lifecycle-command-admission", testLifecycleCommandAdmission),
            ("m4-lifecycle-command-timeout", testLifecycleCommandTimeout),
            ("m4-lifecycle-command-output-bound", testLifecycleCommandOutputBound),
            ("m4-closed-runner-cancellation-ordering", RunnerOwnerOrderingFixtures.closed),
            ("m4-owner-signal-reap-ordering", testOwnedChildSignalReapOrdering),
            ("m4-owner-terminal-publication", testOwnedChildTerminalPublication),
            ("m4-owner-timeout-retains-custody", testOwnedChildTimeoutCustody),
            ("m4-owner-interrupted-wait", testOwnedChildInterruptedWait),
            ("m4-owner-failed-custody", testOwnedChildOwnershipFailure),
            ("m4-owner-adoption-refusals", testOwnedChildAdoptionRefusals),
            ("m4-fixed-cancellation-bounds", testCancellationBounds),
            ("m4-process-identity-signal-proof", testProcessIdentitySignalProof),
            ("m4-term-kill-nested-reap", testTermKillAndNestedReap),
            ("m4-launcher-host-challenge", testLauncherAndHostChallenge),
            ("m4-host-control-rejections", testHostControlRejections),
            ("m4-host-control-client-bounds", testHostControlClientBounds),
            ("m4-stale-socket-refusal", testStaleSocketRefusal),
            ("m4-surviving-operation-recovery-block", testRecoveryBlocking),
            ("m4-interrupted-reconstruction", testInterruptedReconstruction),
            ("m4-log-intent-control-framing", testLogIntentControlFraming),
        ]
        var completed: [String] = []
        for (name, test) in tests {
            do {
                try RuntimeFixtureSession.withCase(name) { try test() }
                completed.append(name)
                onPass(name)
            } catch {
                throw M4SelfTestError.failed(name, String(describing: error))
            }
        }
        return completed
    }


    private static func testLifecycleLaunchContract(_ mode: String) throws {
        try withLifecycleAccount { account, _ in
            func check(_ value: Bool) throws { if !value { throw M4SelfTestError.message("lifecycle closed contract") } }
            func refuses(_ body: () throws -> Void) throws {
                do { try body() } catch { return }
                throw M4SelfTestError.message("unsafe lifecycle input admitted")
            }
            let command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
            if mode == "forms" {
                for operation in LifecycleLaunchCommand.Operation.allCases {
                    let value = LifecycleLaunchCommand(operation: operation, account: account)
                    try check(try LifecycleLaunchCommand(arguments: value.arguments, account: account).operation == operation)
                    for arguments in [value.arguments + ["-k"], ["sudo"] + value.arguments,
                        [operation.rawValue, "system/" + InstallationPaths.label],
                        [operation.rawValue, "gui/0/" + InstallationPaths.label],
                        [operation.rawValue, "gui/\(account.uid)/com.example.foreign"]] {
                        try refuses { _ = try LifecycleLaunchCommand(arguments: arguments, account: account) }
                    }
                }
                try refuses { _ = try LifecycleLaunchCommand(arguments: [], account: account) }
                try refuses { _ = try LifecycleLaunchCommand(arguments: ["enable", command.service], account: account) }
            } else if mode == "valid" {
                try check(try command.state(waitStatus: 0, stdout: command.fixtureLoadedOutput, stderr: Data())
                    == .loaded(program: command.executable, processID: nil))
                try check(try command.state(waitStatus: 113 << 8, stdout: Data(), stderr: command.fixtureAbsentError) == .absent)
                try command.validatePreflight(.absent)
                try command.validatePostflight(.loaded(program: command.executable, processID: nil))
                try refuses { try command.validatePreflight(.loaded(program: command.executable, processID: nil)) }
                try refuses { try command.validatePostflight(.absent) }
            } else {
                let valid = String(decoding: command.fixtureLoadedOutput, as: UTF8.self)
                let invalid = [valid + "extra\n", String(valid.dropLast(2)), valid.replacingOccurrences(of: "program = ", with: "program = /foreign\n\tprogram = "),
                    valid.replacingOccurrences(of: "program = ", with: "program = /foreign"),
                    valid.replacingOccurrences(of: "LaunchAgent", with: "LaunchDaemon"),
                    valid.replacingOccurrences(of: "--managed-host", with: "--unsafe"),
                    valid.replacingOccurrences(of: "arguments = {", with: "arguments = {\nextra"),
                    valid.replacingOccurrences(of: "type = LaunchAgent", with: "pid = 01\n\ttype = LaunchAgent"),
                    valid.replacingOccurrences(of: "type = LaunchAgent", with: "pid = 0\n\ttype = LaunchAgent"),
                    valid.replacingOccurrences(of: "type = LaunchAgent", with: "pid = 22\n\tpid = 23\n\ttype = LaunchAgent"),
                    valid.replacingOccurrences(of: command.service, with: "gui/0/com.example.foreign"),
                    valid.replacingOccurrences(of: "path = ", with: "path = /foreign"), valid + "\0"]
                for value in invalid { try refuses { _ = try command.state(waitStatus: 0, stdout: Data(value.utf8), stderr: Data()) } }
                for error in [command.fixtureAbsentError + Data("permission denied\n".utf8), Data("service not found".utf8), Data([255]), Data(repeating: 32, count: 65_537)] {
                    try refuses { _ = try command.state(waitStatus: 113 << 8, stdout: Data(), stderr: error) }
                }
                for status: Int32 in [0, 1 << 8, SIGKILL, 113] {
                    try refuses { _ = try command.state(waitStatus: status, stdout: Data(), stderr: command.fixtureAbsentError) }
                }
                try refuses { _ = try command.state(waitStatus: 0, stdout: command.fixtureLoadedOutput, stderr: command.fixtureAbsentError) }
            }
        }
    }

    private static func withLifecycleAccount(_ body: (EffectiveAccount, String) throws -> Void) throws {
        let root = try M4TemporaryDirectory()
        let home = root.path + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try body(EffectiveAccount.isolated(homeDirectory: home), root.path)
    }

    private static func withLifecyclePlist(
        _ body: (String, String, [String: Any], Data) throws -> Void
    ) throws {
        var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-m4.") + "XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw M4SelfTestError.message("plist fixture create") }
        let root = String(cString: created), parent = root + "/parent", path = parent + "/fixture.plist"
        var initial = stat()
        guard lstat(root, &initial) == 0, initial.st_uid == geteuid(), initial.st_mode & 0o777 == 0o700 else {
            throw M4SelfTestError.message("plist fixture identity")
        }
        let identity = FileIdentity(initial)
        var failure: Error?
        do {
            try check(mkdir(parent, 0o700) == 0, "plist fixture parent")
            let executable = root + "/ShadowSync.app/Contents/MacOS/ShadowSync"
            let values: [String: Any] = ["Label": InstallationPaths.label,
                "ProgramArguments": [executable, InstallationPaths.managedHostArgument],
                "RunAtLoad": false, "KeepAlive": false, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
            let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try bytes.write(to: URL(fileURLWithPath: path))
            try check(chmod(path, 0o600) == 0, "plist fixture mode")
            try body(path, executable, values, bytes)
        } catch { failure = error }
        do {
            var current = stat()
            try check(lstat(root, &current) == 0 && FileIdentity(current).matchesStableNode(identity),
                      "plist cleanup root changed")
            try FileManager.default.removeItem(atPath: root)
        } catch { throw M4SelfTestError.message("plist fixture body=\(String(describing: failure)); cleanup=\(error)") }
        if let failure { throw failure }
    }
    private static func refusesLifecyclePlist(_ body: () throws -> Void) throws {
        do { try body(); throw M4SelfTestError.message("unsafe launch plist accepted") }
        catch InstallationLifecycleError.invalidLaunchAgent {}
    }
    private static func testLifecyclePlistContract() throws {
        try withLifecyclePlist { path, executable, values, bytes in
            let snapshot = try InstallationLifecycle.testingCaptureLaunchAgent(path, executable: executable)
            try check(snapshot.bytes == bytes && snapshot.hasOwnerPrivateMode, "launch plist lost exact captured bytes")
            try snapshot.revalidate()
            let binary = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try binary.write(to: URL(fileURLWithPath: path))
            _ = try InstallationLifecycle.testingCaptureLaunchAgent(path, executable: executable)
            for change in ["extra", "startup", "arguments", "label"] {
                var altered = values
                if change == "extra" { altered["EnvironmentVariables"] = ["PATH": "/bin"] }
                if change == "startup" { altered["RunAtLoad"] = true }
                if change == "arguments" { altered["ProgramArguments"] = [executable] }
                if change == "label" { altered["Label"] = "com.example.unrelated" }
                try PropertyListSerialization.data(fromPropertyList: altered, format: .xml, options: 0)
                    .write(to: URL(fileURLWithPath: path))
                try refusesLifecyclePlist { _ = try InstallationLifecycle.testingCaptureLaunchAgent(path, executable: executable) }
            }
        }
    }
    private static func testLifecyclePlistUnsafe() throws {
        for fault in ["readable", "writable", "symlink", "hardlink", "fifo", "oversized", "empty", "malformed"] {
            try withLifecyclePlist { path, executable, _, _ in
                switch fault {
                case "readable": try check(chmod(path, 0o644) == 0, "readable fixture mode")
                case "writable": try check(chmod(path, 0o622) == 0, "writable fixture mode")
                case "symlink":
                    try check(rename(path, path + ".retained") == 0 && symlink("fixture.plist.retained", path) == 0, "plist alias fixture")
                case "hardlink": try check(link(path, path + ".retained") == 0, "plist hardlink fixture")
                case "fifo": try check(unlink(path) == 0 && mkfifo(path, 0o600) == 0, "plist fifo fixture")
                case "oversized": try Data(repeating: 65, count: 65_537).write(to: URL(fileURLWithPath: path))
                case "empty": try Data().write(to: URL(fileURLWithPath: path))
                default: try Data("invalid plist".utf8).write(to: URL(fileURLWithPath: path))
                }
                try refusesLifecyclePlist { _ = try InstallationLifecycle.testingCaptureLaunchAgent(path, executable: executable) }
            }
        }
    }
    private static func testLifecyclePlistReadReplacement() throws {
        for fault in ["same-bytes-new-inode", "changed-bytes", "mode"] {
            try withLifecyclePlist { path, executable, _, bytes in
                var changed = false
                try refusesLifecyclePlist {
                    _ = try InstallationLifecycle.testingCaptureLaunchAgent(path, executable: executable) {
                        changed = true
                        if fault == "same-bytes-new-inode" {
                            let replacement = path + ".replacement"
                            try bytes.write(to: URL(fileURLWithPath: replacement))
                            try check(chmod(replacement, 0o600) == 0 && rename(replacement, path) == 0, "replace captured plist")
                        } else if fault == "changed-bytes" { try Data("changed".utf8).write(to: URL(fileURLWithPath: path)) }
                        else { try check(chmod(path, 0o644) == 0, "replace captured mode") }
                    }
                }
                try check(changed, "launch plist post-read replacement was not exercised")
            }
        }
    }
    private static func testLifecyclePlistParentReplacement() throws {
        try withLifecyclePlist { path, executable, _, bytes in
            var changed = false
            try refusesLifecyclePlist {
                _ = try InstallationLifecycle.testingCaptureLaunchAgent(path, executable: executable) {
                    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    try check(rename(parent, parent + ".retained") == 0 && mkdir(parent, 0o700) == 0,
                              "replace captured plist parent")
                    try bytes.write(to: URL(fileURLWithPath: path))
                    try check(chmod(path, 0o600) == 0, "replacement parent plist mode")
                    changed = true
                }
            }
            try check(changed, "launch plist parent replacement was not exercised")
        }
    }

    private static func assertLifecycleChildReaped(_ pid: pid_t) throws {
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        let error = errno
        try check(waited == -1 && error == ECHILD,
                  "lifecycle command returned without reaping its child")
    }

    private static func testLifecycleCommandOutput() throws {
        try withLifecycleAccount { account, _ in
            let result = try LifecycleCommandRunner.testingExecute(
                executable: "/bin/sh", arguments: ["-c", "printf fixture-output; printf fixture-error >&2; exit 7"],
                account: account)
            try check(result.status == 7 && !result.succeeded && !result.timedOut,
                      "nonzero lifecycle status was lost")
            try check(result.stdout == Data("fixture-output".utf8)
                      && result.stderr == Data("fixture-error".utf8)
                      && result.outputDisposition == .complete, "lifecycle streams were lost")
            try assertLifecycleChildReaped(result.processID)
            let success = try LifecycleCommandRunner.testingExecute(
                executable: "/bin/echo", arguments: ["fixture-success"], account: account)
            try check(success.succeeded && success.stdout == Data("fixture-success\n".utf8),
                      "successful lifecycle output was lost")
            try assertLifecycleChildReaped(success.processID)
        }
    }

    private static func testLifecycleCommandAdmission() throws {
        try withLifecycleAccount { account, root in
            let marker = root + "/must-not-execute"
            var observed: ProcessIdentity?
            var custodyVerified = false
            var refused = false
            do {
                _ = try LifecycleCommandRunner.testingExecute(
                    executable: "/bin/sh", arguments: ["-c", ": > \"$1\"", "fixture", marker],
                    account: account, validateSuspendedChild: { pid in
                        let identity = try ProcessIdentity.capture(processID: pid,
                            generation: RunIdentity.make(), expectedExecutablePath: "/bin/sh")
                        observed = identity
                        var info = proc_bsdinfo()
                        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                        custodyVerified = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
                            && info.pbi_ppid == UInt32(getpid())
                            && identity.userID == geteuid() && identity.processGroupID == pid
                        throw M4SelfTestError.message("fixture admission refusal")
                    })
            } catch { refused = true }
            let identity = try require(observed, "lifecycle admission callback was not executed")
            try check(custodyVerified && refused && !FileManager.default.fileExists(atPath: marker),
                      "refused lifecycle command executed")
            try assertLifecycleChildReaped(identity.processID)
        }
    }

    private static func testLifecycleCommandTimeout() throws {
        try withLifecycleAccount { account, _ in
            let started = ProcessInfo.processInfo.systemUptime
            let result = try LifecycleCommandRunner.testingExecute(
                executable: "/bin/sleep", arguments: ["30"], account: account, timeout: 0.05)
            try check(result.timedOut && result.terminationRequested && !result.succeeded
                      && result.status == 128 + SIGTERM,
                      "lifecycle timeout did not terminate the owned group")
            try check(ProcessInfo.processInfo.systemUptime - started < 10,
                      "ordinary lifecycle timeout exceeded its cleanup budget")
            try assertLifecycleChildReaped(result.processID)
            // This interruptible fixture does not qualify an unresolved post-KILL path.
        }
    }

    private static func testLifecycleCommandOutputBound() throws {
        try withLifecycleAccount { account, _ in
            let result = try LifecycleCommandRunner.testingExecute(executable: "/usr/bin/printf",
                arguments: ["%s", String(repeating: "x", count: LifecycleCommandRunner.outputLimit + 1)],
                account: account)
            try check(result.status == 0 && !result.succeeded && !result.timedOut
                      && result.stdout.count == LifecycleCommandRunner.outputLimit
                      && result.outputDisposition == .stdoutExceededBound,
                      "lifecycle output was not bounded or overflow was accepted")
            try assertLifecycleChildReaped(result.processID)
        }
    }

    private final class OwnerResults: @unchecked Sendable {
        let mutex = NSLock()
        private var values: [String: OwnedDirectChildObservation] = [:]
        private var flags: [String: Bool] = [:]
        func record(_ key: String, _ value: OwnedDirectChildObservation) { mutex.lock(); values[key] = value; mutex.unlock() }
        func record(_ key: String, _ value: Bool) { mutex.lock(); flags[key] = value; mutex.unlock() }
        func result(_ key: String) -> OwnedDirectChildObservation? { mutex.lock(); defer { mutex.unlock() }; return values[key] }
        func flag(_ key: String) -> Bool? { mutex.lock(); defer { mutex.unlock() }; return flags[key] }
    }

    /// One fixed sleep or stdin-controlled cat, no descendants or Foundation reaper.
    private static func withOwnedChild(exitOnEOF: Bool = false, _ body: (OwnedDirectChild, () -> Void) throws -> Void) throws {
        let executable = exitOnEOF ? "/bin/cat" : "/bin/sleep"
        var inputFDs: [Int32] = [-1, -1]
        if exitOnEOF && pipe(&inputFDs) != 0 { throw M4SelfTestError.message("owner fixture pipe") }
        defer { for fd in inputFDs where fd >= 0 { close(fd) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw M4SelfTestError.message("owner fixture actions") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw M4SelfTestError.message("owner fixture attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        var code: Int32 = 0
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where code == 0 {
            if fd == STDIN_FILENO && exitOnEOF {
                code = posix_spawn_file_actions_adddup2(&actions, inputFDs[0], STDIN_FILENO)
            } else {
                code = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
            }
        }
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM)
        var mask = sigset_t(); sigemptyset(&mask)
        if code == 0 { code = posix_spawnattr_setsigdefault(&attributes, &defaults) }
        if code == 0 { code = posix_spawnattr_setsigmask(&attributes, &mask) }
        if code == 0 { code = posix_spawnattr_setpgroup(&attributes, 0) }
        if code == 0 { code = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) }
        guard code == 0 else { throw M4SelfTestError.message("owner fixture setup") }
        let arguments = exitOnEOF ? [executable] : [executable, "15"]
        let pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { value in value.withCString { strdup($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            throw M4SelfTestError.message("owner fixture argument allocation")
        }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let registry = try RuntimeFixtureSession.current()
        let anchor = try argv.withUnsafeMutableBufferPointer { args in
            try environment.withUnsafeMutableBufferPointer { env in
                try RuntimeFixtureSpawn.spawn(registry: registry, executable: executable,
                    actions: &actions, attributes: &attributes, arguments: args.baseAddress,
                    environment: env.baseAddress, streamsDrained: { true })
            }
        }
        defer { RuntimeFixtureSession.drain(anchor) }
        if inputFDs[0] >= 0 { close(inputFDs[0]); inputFDs[0] = -1 }
        let owner = try anchor.transfer(expectedExecutable: executable, generation: RunIdentity.make())
        try check(owner.send(SIGCONT), "owned fixture resume refused")
        try body(owner) {
            if inputFDs[1] >= 0 { close(inputFDs[1]); inputFDs[1] = -1 }
        }
    }

    private static func testOwnedChildSignalReapOrdering() throws {
        try withOwnedChild(exitOnEOF: true) { owner, requestExit in
            let barrier = OwnedDirectChildTestingBarrier()
            let results = OwnerResults()
            let group = DispatchGroup()
            let waiterStarted = DispatchSemaphore(value: 0)
            let waiterFinished = DispatchSemaphore(value: 0)
            owner.testingPauseNextSignal(barrier)
            group.enter()
            DispatchQueue.global().async { results.record("signal", owner.send(SIGCONT)); group.leave() }
            guard barrier.waitUntilEntered() else {
                barrier.release(); _ = group.wait(timeout: .now() + 4)
                throw M4SelfTestError.message("owned signal barrier was not reached")
            }
            // Exit is caused by the fixture pipe, outside the ownership mutex.
            // WNOWAIT observes exit without consuming status or releasing the PID anchor.
            requestExit()
            var terminal = false
            let exitDeadline = MonotonicDeadline(seconds: 1)
            repeat {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(owner.identity.processID), &info,
                                    WEXITED | WNOHANG | WNOWAIT)
                terminal = result == 0 && info.si_pid == owner.identity.processID
                    && (info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED)
                if terminal { break }
                usleep(1_000)
            } while !exitDeadline.hasExpired
            guard terminal else {
                barrier.release(); _ = group.wait(timeout: .now() + 4)
                throw M4SelfTestError.message("fixture did not become terminal before competing reap")
            }
            group.enter()
            DispatchQueue.global().async {
                waiterStarted.signal()
                results.record("poll", owner.poll())
                waiterFinished.signal(); group.leave()
            }
            let started = waiterStarted.wait(timeout: .now() + 1) == .success
            let excluded = waiterFinished.wait(timeout: .now() + 0.05) == .timedOut
            barrier.release()
            let joined = group.wait(timeout: .now() + 4) == .success
            try check(started && joined && excluded, "reap crossed the final-check/signal critical section")
            guard let reaped = results.result("poll"), case .reaped = reaped else {
                throw M4SelfTestError.message("competing poll did not reap the terminal child")
            }
            try check(results.flag("signal") != nil && owner.testingSignalSystemCallCount == 1,
                      "signal syscall did not finish before terminal reap")
            try check(!owner.send(SIGCONT) && !owner.send(SIGTERM) && !owner.send(SIGKILL)
                      && owner.testingSignalSystemCallCount == 1, "signal admitted after competing reap")
        }
    }

    private static func testOwnedChildTerminalPublication() throws {
        try withOwnedChild { owner, _ in
            try check(owner.send(SIGKILL), "owned child kill refused")
            let results = OwnerResults(); let group = DispatchGroup()
            for key in ["first", "second"] {
                group.enter()
                DispatchQueue.global().async {
                    results.record(key, (try? owner.wait(timeout: 2)) ?? .ownershipFailure(EINVAL)); group.leave()
                }
            }
            try check(group.wait(timeout: .now() + 3) == .success, "owned terminal waiters did not join")
            guard let result = results.result("first"), case .reaped = result else { throw M4SelfTestError.message("owned terminal status absent") }
            try check(results.result("second") == result, "terminal observers disagreed")
            let calls = owner.testingWaitSystemCallCount
            try check(owner.poll() == result && owner.poll() == result && owner.testingWaitSystemCallCount == calls,
                      "terminal observation repeated waitpid")
            try check(!owner.send(SIGCONT) && !owner.send(SIGTERM) && !owner.send(SIGKILL), "signal admitted after reap")
        }
    }

    private static func testOwnedChildTimeoutCustody() throws {
        try withOwnedChild { owner, _ in
            let initial = try owner.wait(timeout: 0)
            try check(initial == .running, "zero timeout fabricated completion")
            try check(owner.observation == .running && owner.send(SIGKILL), "timeout discarded custody")
            guard case .reaped = try owner.wait(timeout: 2) else { throw M4SelfTestError.message("retained owner did not reap") }
        }
    }

    private static func testOwnedChildInterruptedWait() throws {
        try withOwnedChild { owner, _ in
            owner.testingInjectWaitErrors([EINTR])
            try check(owner.poll() == .running && owner.testingWaitSystemCallCount == 0, "EINTR corrupted ownership")
            try check(owner.send(SIGKILL), "EINTR prevented owned signal")
            guard case .reaped = try owner.wait(timeout: 2) else { throw M4SelfTestError.message("EINTR prevented reap") }
        }
    }

    private static func testOwnedChildOwnershipFailure() throws {
        try withOwnedChild { owner, _ in
            owner.testingInjectWaitErrors([ECHILD])
            try check(owner.poll() == .ownershipFailure(ECHILD), "ECHILD became success")
            try check(!owner.send(SIGKILL) && owner.poll() == .ownershipFailure(ECHILD), "ownership failure reopened signaling")
            try check(owner.testingWaitSystemCallCount == 0, "ownership failure issued a later wait")
        }
    }

    private static func testOwnedChildAdoptionRefusals() throws {
        try withOwnedChild { owner, _ in
            let id = owner.identity
            let invalid = [
                ProcessIdentity(processID: id.processID, processGroupID: id.processGroupID, userID: id.userID + 1, startSeconds: id.startSeconds, startMicroseconds: id.startMicroseconds, executablePath: id.executablePath, generation: id.generation),
                ProcessIdentity(processID: id.processID, processGroupID: id.processGroupID + 1, userID: id.userID, startSeconds: id.startSeconds, startMicroseconds: id.startMicroseconds, executablePath: id.executablePath, generation: id.generation),
                ProcessIdentity(processID: id.processID, processGroupID: id.processGroupID, userID: id.userID, startSeconds: id.startSeconds + 1, startMicroseconds: id.startMicroseconds, executablePath: id.executablePath, generation: id.generation),
                ProcessIdentity(processID: id.processID, processGroupID: id.processGroupID, userID: id.userID, startSeconds: id.startSeconds, startMicroseconds: id.startMicroseconds, executablePath: id.executablePath, generation: "invalid")
            ]
            for value in invalid {
                do {
                    _ = try OwnedDirectChild(adoptingSpawnedChild: id.processID, identity: value)
                    throw M4SelfTestError.message("invalid owner adoption succeeded")
                } catch ProcessOwnershipError.identityMismatch {}
            }
            try check(!owner.send(0) && !owner.send(SIGINT) && owner.observation == .running, "unsupported signal changed ownership")
            do {
                _ = try owner.wait(timeout: .infinity)
                throw M4SelfTestError.message("unbounded wait admitted")
            } catch ProcessOwnershipError.invalidRegistration {}
        }
    }

    private static func testCancellationBounds() throws {
        var machine = CancellationEscalationStateMachine(requestedAt: 100)
        try check(
            machine.nextAction(at: 101.999, ownerVerified: true) == .waitForCooperation,
            "cooperative acknowledgement ended early"
        )
        try check(
            machine.nextAction(at: 102, ownerVerified: true) == .sendTerm,
            "TERM was not sent at two seconds"
        )
        try check(
            machine.nextAction(at: 106.999, ownerVerified: true) == .waitForCooperation,
            "TERM grace ended early"
        )
        try check(
            machine.nextAction(at: 107, ownerVerified: true) == .sendKill,
            "KILL was not sent after five seconds"
        )
        try check(
            machine.nextAction(at: 108.999, ownerVerified: true) == .waitForCooperation,
            "post-KILL reap ended early"
        )
        try check(
            machine.nextAction(at: 109, ownerVerified: true) == .needsAttention,
            "surviving holder did not require attention"
        )
        var unverified = CancellationEscalationStateMachine(requestedAt: 0)
        try check(
            unverified.nextAction(at: 30, ownerVerified: false) == .needsAttention,
            "unverified owner was eligible for signalling"
        )
        let repeated = CancellationToken()
        repeated.cancel()
        repeated.cancel()
        try check(repeated.isCancelled, "repeated cancellation lost terminal state")
    }

    private static func testProcessIdentitySignalProof() throws {
        let readiness = try M4TemporaryDirectory()
        let ready = readiness.path + "/identity-ready"
        let childFixture = try spawnGroup(.responsive, ready: ready)
        let child = childFixture.owner.identity.processID
        defer { RuntimeFixtureSession.drain(childFixture.anchor) }
        try waitForReadiness(at: ready, processID: child)
        let identity = try ProcessIdentity.capture(
            processID: child,
            generation: childFixture.owner.identity.generation
        )
        try check(identity.processGroupID == child, "child is not its group leader")
        try check(
            !childFixture.owner.testingSendVerified(
                SIGTERM,
                identity: identity,
                expectedGeneration: RunIdentity.make()
            ),
            "generation mismatch was signalled"
        )
        try check(kill(child, 0) == 0, "unverified signal changed the unrelated child")
        try check(
            childFixture.owner.testingSendVerified(
                SIGTERM,
                identity: identity,
                expectedGeneration: identity.generation
            ),
            "verified cooperative signal was refused"
        )
        _ = wait(childFixture, timeout: 2)
        try check(
            !identity.isCurrent(expectedGeneration: identity.generation),
            "reaped PID retained stale authority"
        )
    }

    private static func testTermKillAndNestedReap() throws {
        let readiness = try M4TemporaryDirectory()
        let responsiveReady = readiness.path + "/responsive-ready"
        let responsiveFixture = try spawnGroup(.responsiveNested, ready: responsiveReady)
        let responsive = responsiveFixture.owner.identity.processID
        defer { RuntimeFixtureSession.drain(responsiveFixture.anchor) }
        try waitForReadiness(at: responsiveReady, processID: responsive)
        let responsiveIdentity: ProcessIdentity
        do {
            responsiveIdentity = try ProcessIdentity.capture(
                processID: responsive,
                generation: responsiveFixture.owner.identity.generation
            )
        } catch {
            throw M4SelfTestError.message(
                "responsive identity capture failed: \(error)"
            )
        }
        try check(
            responsiveFixture.owner.testingSendVerified(
                SIGTERM,
                identity: responsiveIdentity,
                expectedGeneration: responsiveIdentity.generation
            ),
            "responsive group TERM failed"
        )
        try check(wait(responsiveFixture, timeout: 2) != nil, "responsive group was not reaped")
        try check(groupGone(responsive), "responsive nested group survived")

        let stubbornReady = readiness.path + "/stubborn-ready"
        let stubbornFixture = try spawnGroup(.resistantNested, ready: stubbornReady)
        let stubborn = stubbornFixture.owner.identity.processID
        defer { RuntimeFixtureSession.drain(stubbornFixture.anchor) }
        try waitForReadiness(at: stubbornReady, processID: stubborn)
        let stubbornIdentity: ProcessIdentity
        do {
            stubbornIdentity = try ProcessIdentity.capture(
                processID: stubborn,
                generation: stubbornFixture.owner.identity.generation
            )
        } catch {
            throw M4SelfTestError.message(
                "stubborn identity capture failed: \(error)"
            )
        }
        try check(
            stubbornFixture.owner.testingSendVerified(
                SIGTERM,
                identity: stubbornIdentity,
                expectedGeneration: stubbornIdentity.generation
            ),
            "stubborn group TERM failed"
        )
        usleep(150_000)
        try check(kill(stubborn, 0) == 0, "stubborn group did not exercise escalation")
        let reverified: ProcessIdentity
        do {
            reverified = try ProcessIdentity.capture(
                processID: stubborn,
                generation: stubbornIdentity.generation
            )
        } catch {
            throw M4SelfTestError.message(
                "stubborn identity revalidation failed: \(error)"
            )
        }
        try check(
            reverified.startSeconds == stubbornIdentity.startSeconds
                && reverified.startMicroseconds == stubbornIdentity.startMicroseconds
                && reverified.processGroupID == stubbornIdentity.processGroupID,
            "stubborn group identity changed before KILL"
        )
        try check(
            stubbornFixture.owner.testingSendVerified(
                SIGKILL,
                identity: reverified,
                expectedGeneration: stubbornIdentity.generation
            ),
            "stubborn group KILL failed"
        )
        try check(wait(stubbornFixture, timeout: 2) != nil, "stubborn group was not reaped")
        try check(groupGone(stubborn), "stubborn nested group survived")
    }

    private static func testLauncherAndHostChallenge() throws {
        let temporary = try M4TemporaryDirectory()
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try LauncherAuthority.acquire(at: location)
        do {
            _ = try LauncherAuthority.acquire(at: location)
            throw M4SelfTestError.message("second launcher acquired ownership")
        } catch SecureStateError.contention {
            // Expected.
        }
        let activated = DispatchSemaphore(value: 0)
        let server = try HostControlServer(
            authority: authority,
            executablePath: CommandLine.arguments[0],
            onActivation: {
                activated.signal()
                return true
            }
        )
        try server.start()
        defer { server.stop() }
        try HostControlClient.activate(at: location)
        try check(
            activated.wait(timeout: .now() + 2) == .success,
            "same-UID activation was not routed"
        )
        let state = try SecureStateDirectory.open(location)
        let registration = try HostRegistrationStore.read(state: state)
        try check(registration.isValid, "live host registration was not verified")
    }

    private static func testHostControlRejections() throws {
        let temporary = try M4TemporaryDirectory()
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try LauncherAuthority.acquire(at: location)
        let server = try HostControlServer(
            authority: authority,
            executablePath: CommandLine.arguments[0],
            onActivation: { true }
        )
        let rejectionObservation = M4HostRejectionObservation()
        try check(server.observeM4Rejections(rejectionObservation), "host observation setup")
        try server.start()
        defer { server.stop() }
        let state = try SecureStateDirectory.open(location)
        let registration = try HostRegistrationStore.read(state: state)

        let malformed = try rawHostExchange(
            location: location,
            request: Data("{bad}\n".utf8),
            kind: .malformed
        )
        let malformedResponse = try decodedHostResponse(malformed)
        try check(
            !malformedResponse.accepted,
            "malformed activation lacked a generic rejection"
        )
        rejectionObservation.confirmedResponse(1)

        let wrongRequest = HostControlRequest(
            expectedGeneration: RunIdentity.make()
        )
        var wrongBytes = try JSONEncoder().encode(wrongRequest)
        wrongBytes.append(0x0A)
        let wrong = try decodedHostResponse(
            rawHostExchange(location: location, request: wrongBytes, kind: .wrongGeneration)
        )
        try check(!wrong.accepted, "wrong generation was accepted")
        try check(wrong.nonce == wrongRequest.nonce, "rejection nonce changed")
        rejectionObservation.confirmedResponse(2)

        let partialStarted = MonotonicInstant.now()
        let partial = try rawHostExchange(
            location: location,
            request: Data(#"{"schema":"partial""#.utf8),
            kind: .partial,
            keepWriteOpen: true
        )
        let partialResponse = try decodedHostResponse(partial)
        try check(
            !partialResponse.accepted,
            "partial request was accepted"
        )
        try check(
            MonotonicInstant.now().milliseconds(since: partialStarted) < 2_000,
            "partial request did not complete within its bound"
        )
        rejectionObservation.confirmedResponse(3)

        let oversized = try rawHostExchange(
            location: location,
            request: Data(repeating: UInt8(ascii: "x"), count: 17_000),
            kind: .oversized,
            rejectionObservation: rejectionObservation
        )
        let oversizedResponse = try decodedHostResponse(oversized)
        try check(
            !oversizedResponse.accepted,
            "oversized request was accepted"
        )
        try check(registration.isValid, "rejected request invalidated live host")
    }

    private static func testHostControlClientBounds() throws {
        enum Behavior {
            case silent
            case partial
            case eof
            case oversized
        }
        let descriptorsBefore = openDescriptorCount()
        for behavior in [Behavior.silent, .partial, .eof, .oversized] {
            let temporary = try M4TemporaryDirectory()
            let location = try StateLocation.isolated(root: temporary.path)
            try TestIsolation.initializeState(at: location)
            let authority = try LauncherAuthority.acquire(at: location)
            let state = authority.stateDirectory
            let generation = RunIdentity.make()
            let registration = HostRegistration(
                identity: try ProcessIdentity.capture(
                    processID: getpid(),
                    generation: generation,
                    expectedExecutablePath: CommandLine.arguments[0]
                )
            )
            try HostRegistrationStore.write(registration, state: state)
            let listener = try makeHostListener(
                path: state.path + "/host.sock"
            )
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                defer {
                    close(listener)
                    finished.signal()
                }
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { return }
                defer { close(peer) }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                _ = Darwin.read(peer, &buffer, buffer.count)
                switch behavior {
                case .silent:
                    usleep(1_500_000)
                case .partial:
                    var bytes = Array("{}".utf8)
                    _ = Darwin.write(peer, &bytes, bytes.count)
                case .eof:
                    break
                case .oversized:
                    var bytes = Data(repeating: UInt8(ascii: "x"), count: 17_000)
                    bytes.append(0x0A)
                    bytes.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            _ = Darwin.write(peer, base, raw.count)
                        }
                    }
                }
            }
            let started = MonotonicInstant.now()
            do {
                try HostControlClient.activate(at: location)
                throw M4SelfTestError.message(
                    "invalid host response was accepted"
                )
            } catch M4SelfTestError.message {
                throw M4SelfTestError.message("invalid host response was accepted")
            } catch {
                // Expected.
            }
            try check(
                MonotonicInstant.now().milliseconds(since: started) < 2_000,
                "activation client exceeded its response bound"
            )
            try check(
                finished.wait(timeout: .now() + 2) == .success,
                "fake host listener did not close"
            )
            authority.release()
        }
        try check(
            openDescriptorCount() <= descriptorsBefore + 1,
            "host control tests leaked descriptors"
        )
    }

    private enum HostRejectionKind: String {
        case malformed, wrongGeneration, partial, oversized
    }

    private static func rawHostExchange(
        location: StateLocation,
        request: Data,
        kind: HostRejectionKind,
        keepWriteOpen: Bool = false,
        rejectionObservation: M4HostRejectionObservation? = nil
    ) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw M4SelfTestError.system("host test socket", errno)
        }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw M4SelfTestError.system("host test timeout", errno)
        }
        try connectHostSocket(
            descriptor,
            path: location.path + "/host.sock"
        )
        try request.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                // Acknowledge the frame boundary before offering the oversized
                // tail, so only positive writes establish rejection progress.
                let writeEnd = kind == .oversized && offset < HostControlIO.maximumFrameBytes
                    ? min(raw.count, HostControlIO.maximumFrameBytes) : raw.count
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    writeEnd - offset
                )
                if count < 0, errno == EINTR { continue }
                if count <= 0 {
                    let code = count == 0 ? EPIPE : errno
                    // The server rejects once a full unterminated frame is read;
                    // it need not consume the oversized fixture's remaining tail.
                    // EPIPE alone is never success: the caller must still decode
                    // the server's framed rejection and assert accepted == false.
                    let earlyRejection = count < 0 && code == EPIPE
                        && kind == .oversized && offset >= HostControlIO.maximumFrameBytes
                    fputs("M4 HOST REJECTION DIAGNOSTIC kind=\(kind.rawValue) offset=\(offset) bytes=\(raw.count) errno=\(code) early_rejection=\(earlyRejection)\n", stderr)
                    fflush(stderr)
                    if !earlyRejection { rejectionObservation?.emitFirstFailure() }
                    if earlyRejection { break }
                    throw M4SelfTestError.system("host test write", code)
                }
                offset += count
            }
        }
        if !keepWriteOpen {
            _ = shutdown(descriptor, SHUT_WR)
        }
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while response.count <= 20_000 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                response.append(contentsOf: bytes.prefix(count))
                if response.contains(0x0A) { break }
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return response
    }

    private static func decodedHostResponse(
        _ data: Data
    ) throws -> HostControlResponse {
        guard data.last == 0x0A else {
            throw M4SelfTestError.message("host response lacked newline")
        }
        return try JSONDecoder().decode(
            HostControlResponse.self,
            from: data.dropLast()
        )
    }

    private static func makeHostListener(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw M4SelfTestError.system("fake host socket", errno)
        }
        do {
            try bindHostSocket(descriptor, path: path)
            guard listen(descriptor, 1) == 0 else {
                throw M4SelfTestError.system("fake host listen", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func connectHostSocket(
        _ descriptor: Int32,
        path: String
    ) throws {
        var address = try hostSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw M4SelfTestError.system("fake host connect", errno)
        }
    }

    private static func bindHostSocket(
        _ descriptor: Int32,
        path: String
    ) throws {
        var address = try hostSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0, chmod(path, 0o600) == 0 else {
            throw M4SelfTestError.system("fake host bind", errno)
        }
    }

    private static func hostSocketAddress(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw M4SelfTestError.message("fake host socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return address
    }

    private static func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count)
            ?? 0
    }

    private static func testStaleSocketRefusal() throws {
        let temporary = try M4TemporaryDirectory()
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try LauncherAuthority.acquire(at: location)
        let state = authority.stateDirectory
        let socketPath = state.path + "/host.sock"
        try Data("sentinel".utf8).write(to: URL(fileURLWithPath: socketPath))
        let server = try HostControlServer(
            authority: authority,
            executablePath: CommandLine.arguments[0],
            onActivation: { true }
        )
        do {
            try server.start()
            throw M4SelfTestError.message("regular stale socket path was removed")
        } catch ProcessOwnershipError.unsafeSocket {
            // Expected.
        }
        let retained = try Data(contentsOf: URL(fileURLWithPath: socketPath))
        try check(
            retained == Data("sentinel".utf8),
            "unsafe stale socket bytes changed"
        )
        server.stop()

        let liveTemporary = try M4TemporaryDirectory()
        let liveLocation = try StateLocation.isolated(root: liveTemporary.path)
        try TestIsolation.initializeState(at: liveLocation)
        let liveAuthority = try LauncherAuthority.acquire(at: liveLocation)
        let livePath = liveAuthority.stateDirectory.path + "/host.sock"
        let liveListener = try makeHostListener(path: livePath)
        defer {
            close(liveListener)
            _ = unlink(livePath)
        }
        let liveServer = try HostControlServer(
            authority: liveAuthority,
            executablePath: CommandLine.arguments[0],
            onActivation: { true }
        )
        do {
            try liveServer.start()
            throw M4SelfTestError.message("live unverified socket was replaced")
        } catch ProcessOwnershipError.unsafeSocket {
            // Expected.
        }
        var liveInfo = stat()
        try check(
            lstat(livePath, &liveInfo) == 0
                && (liveInfo.st_mode & S_IFMT) == S_IFSOCK,
            "live unverified socket was unlinked"
        )
        liveServer.stop()

        let deadTemporary = try M4TemporaryDirectory()
        let deadLocation = try StateLocation.isolated(root: deadTemporary.path)
        try TestIsolation.initializeState(at: deadLocation)
        let deadAuthority = try LauncherAuthority.acquire(at: deadLocation)
        let deadPath = deadAuthority.stateDirectory.path + "/host.sock"
        let deadListener = try makeHostListener(path: deadPath)
        close(deadListener)
        let replacement = try HostControlServer(
            authority: deadAuthority,
            executablePath: CommandLine.arguments[0],
            onActivation: { true }
        )
        try replacement.start()
        replacement.stop()
    }

    private static func testRecoveryBlocking() throws {
        let temporary = try M4TemporaryDirectory()
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try RunAuthority.acquireRun(at: location)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        authority.release()
        defer { close(lease) }
        try check(
            RunRecoveryInspector.inspect(at: location) == .operationStillActive,
            "surviving operation lease did not block recovery"
        )
        let lifecycle: RunAuthority?
        do {
            lifecycle = try RunAuthority.acquireLifecycleMutation(at: location)
        } catch {
            lifecycle = nil
        }
        try check(lifecycle == nil, "surviving lease did not block lifecycle mutation")
    }

    private static func testInterruptedReconstruction() throws {
        let candidates = (1...4).map { index in
            RepositoryCandidate(
                id: "fixture-owner/recovery-\(index)",
                displayName: "Recovery \(index)",
                path: "/private/tmp/recovery-\(index)",
                rawOrigin: "https://github.com/fixture-owner/recovery-\(index).git"
            )
        }
        let run = RunIdentity.make()
        let intent = RunIntent(
            run: run,
            startedAt: "2026-09-04T00:00:00.000Z",
            candidates: candidates
        )
        let completed = RepositoryResult(
            repository: candidates[0],
            code: .updated,
            fetched: true,
            mainUpdated: true,
            beforeCommit: "a",
            targetCommit: "b",
            afterCommit: "b",
            startedAt: intent.startedAt,
            endedAt: intent.startedAt,
            durationMilliseconds: 1,
            explanation: "completed"
        )
        var records = [
            LogRecord(run: run, sequence: 1, type: "run_intent", intent: intent),
            LogRecord(
                run: run,
                sequence: 2,
                type: "event",
                event: RunEvent(
                    run: run,
                    sequence: 1,
                    type: .repositoryResult,
                    result: completed
                )
            ),
            LogRecord(
                run: run,
                sequence: 3,
                type: "repository_checkpoint",
                checkpoint: RepositoryCheckpoint(
                    repository: candidates[1],
                    startedAt: intent.startedAt,
                    beforeCommit: "before-0",
                    targetCommit: nil,
                    fetched: false
                )
            ),
        ]
        for (offset, candidate) in candidates.dropFirst().dropLast().enumerated() {
            records.append(LogRecord(
                run: run,
                sequence: records.count + 1,
                type: "repository_checkpoint",
                checkpoint: RepositoryCheckpoint(
                    repository: candidate,
                    startedAt: intent.startedAt,
                    beforeCommit: "before-\(offset)",
                    targetCommit: "target-\(offset)",
                    fetched: true
                )
            ))
        }
        let report = try require(InterruptedRunReconstructor.reconstruct(
            records: records
        ) { checkpoint in
            checkpoint.repository == candidates[1]
                ? .updated(checkpoint.targetCommit!)
                : .ambiguous("different")
        }, "interrupted run was not reconstructed")
        try check(
            report.summary == InterruptedRunReconstructor.summary,
            "interrupted aggregate copy changed"
        )
        try check(
            report.results.map(\.code)
                == [.updated, .updatedBeforeCancellation, .needsAttention, .cancelledPending],
            "completed/updated/ambiguous/pending outcomes changed"
        )
        try check(report.results[0] == completed, "completed result was rolled back")

        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let current = String(
            decoding: try fixture.gitOutput(["rev-parse", "refs/heads/main"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let actualRun = RunIdentity.make()
        let actualStartedAt = WallClock.timestamp()
        do {
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            let writer = try RunLogWriter(authority: authority, runID: actualRun)
            try writer.append(
                type: "run_intent",
                intent: RunIntent(
                    run: actualRun,
                    startedAt: actualStartedAt,
                    candidates: [fixture.candidate],
                    repositoryModel: "v2"
                )
            )
            try writer.append(
                type: "repository_checkpoint",
                checkpoint: RepositoryCheckpoint(
                    repository: fixture.candidate,
                    startedAt: actualStartedAt,
                    beforeCommit: current,
                    targetCommit: nil,
                    fetched: false
                )
            )
            try writer.flush()
            authority.release()
        }
        guard case let .previousReport(actualReport) =
                RunRecoveryInspector.inspect(at: fixture.stateLocation) else {
            throw M4SelfTestError.message("descriptor-safe postflight did not reconstruct")
        }
        try check(
            actualReport.results.map(\.code) == [.cancelledNoUpdate],
            "descriptor-safe unchanged postflight was misclassified"
        )
    }

    private static func testLogIntentControlFraming() throws {
        let temporary = try M4TemporaryDirectory()
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try RunAuthority.acquireRun(at: location)
        defer { authority.release() }
        let run = RunIdentity.make()
        let candidate = RepositoryCandidate(
            id: "fixture-owner/log",
            displayName: "Log",
            path: "/private/tmp/log",
            rawOrigin: "https://github.com/fixture-owner/log.git"
        )
        let writer = try RunLogWriter(authority: authority, runID: run)
        try writer.append(
            type: "run_intent",
            intent: RunIntent(
                run: run,
                startedAt: WallClock.timestamp(),
                candidates: [candidate]
            )
        )
        try writer.append(
            type: "control",
            data: "cancel\n{\"type\":\"run_finished\",\"token\":\"ghp_abcdefghijklmnopqrstuvwxyz\"}"
        )
        try writer.flush()
        let records = try RunLogReader.records(state: authority.stateDirectory)
        try check(records.count == 2, "forged newline changed record framing")
        try check(
            records[1].data?.contains("ghp_abcdefghijklmnopqrstuvwxyz") == false,
            "seeded token survived redaction"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: writer.path)
        try check(
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600,
            "latest log mode is not private"
        )
    }

    private struct GroupFixture {
        let anchor: OwnedSpawnAnchor
        let owner: OwnedDirectChild
    }
    private enum GroupFixtureKind {
        case responsive, responsiveNested, resistantNested
        var script: String {
            switch self {
            case .responsive:
                return "trap 'exit 0' TERM; : > \"$1\"; while :; do /bin/sleep 1; done"
            case .responsiveNested:
                return "trap 'exit 0' TERM; /bin/sleep 30 & : > \"$1\"; while :; do /bin/sleep 1; done"
            case .resistantNested:
                return "trap '' TERM; /bin/sleep 30 & : > \"$1\"; wait"
            }
        }
    }
    private static func spawnGroup(_ kind: GroupFixtureKind, ready: String) throws -> GroupFixture {
        let registry = try RuntimeFixtureSession.current()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions) == 0, "group fixture file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes) == 0, "group fixture attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0, "group null streams")
        }
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM)
        var mask = sigset_t(); sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
            && posix_spawnattr_setsigmask(&attributes, &mask) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0, "group closed flags")
        let strings = (["/bin/bash", "-c", kind.script, "fixture", ready] as [String]).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try check(strings.allSatisfy { $0 != nil }, "group argument allocation")
        var argv = strings + [nil]; var env: [UnsafeMutablePointer<CChar>?] = [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in
            try env.withUnsafeMutableBufferPointer { ev in
                try RuntimeFixtureSpawn.spawn(registry: registry, executable: "/bin/bash", actions: &actions,
                    attributes: &attributes, arguments: av.baseAddress, environment: ev.baseAddress,
                    streamsDrained: { true })
            }
        }
        let owner = try anchor.transfer(expectedExecutable: "/bin/bash", generation: RunIdentity.make(),
                                        reapPolicy: .afterGroupDrain)
        try check(owner.send(SIGCONT), "group fixture resume refused")
        return GroupFixture(anchor: anchor, owner: owner)
    }

    private static func waitForReadiness(
        at path: String,
        processID: pid_t,
        timeout: TimeInterval = 5
    ) throws {
        let deadline = MonotonicDeadline(seconds: timeout)
        while !deadline.hasExpired {
            var info = stat()
            if lstat(path, &info) == 0 {
                try check(
                    (info.st_mode & S_IFMT) == S_IFREG
                        && info.st_uid == geteuid(),
                    "process readiness marker is unsafe"
                )
                return
            }
            guard errno == ENOENT else {
                throw M4SelfTestError.system("inspect process readiness", errno)
            }
            guard kill(processID, 0) == 0 else {
                throw M4SelfTestError.message(
                    "process exited before publishing readiness"
                )
            }
            usleep(10_000)
        }
        throw M4SelfTestError.message("process readiness timed out")
    }

    private static func wait(_ fixture: GroupFixture, timeout: TimeInterval) -> Int32? {
        let deadline = MonotonicDeadline(seconds: timeout)
        repeat {
            switch fixture.owner.reapAfterGroupDrain(streamsDrained: true) {
            case .reaped(let status): return status
            case .ownershipFailure: return nil
            case .running: break
            }
            usleep(10_000)
        } while !deadline.hasExpired
        return nil
    }

    private static func groupGone(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw M4SelfTestError.message(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw M4SelfTestError.message(message) }
        return value
    }
}

private final class M4TemporaryDirectory {
    let path: String

    init() throws {
        var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-m4.") + "XXXXXX").utf8CString)
        guard let result = mkdtemp(&template) else {
            throw M4SelfTestError.system("mkdtemp", errno)
        }
        path = String(cString: result)
        guard chmod(path, 0o700) == 0 else {
            throw M4SelfTestError.system("chmod test root", errno)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private enum M4SelfTestError: Error {
    case failed(String, String)
    case message(String)
    case system(String, Int32)
}


enum CustodyAnchorSelfTests {
    private struct Failure: Error { let message: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    private static let requiredFlags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
        | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)

    private static func spawn(_ executable: String = "/bin/sleep", _ args: [String] = ["12"],
                              flags: Int16 = requiredFlags) throws -> OwnedSpawnAnchor {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure(message: "fixture actions") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure(message: "fixture attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0,
                      "fixture null streams")
        }
        var defaults = sigset_t(); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var mask = sigset_t(); sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
            && posix_spawnattr_setsigmask(&attributes, &mask) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setflags(&attributes, flags) == 0, "fixture attributes")
        let strings = ([executable] + args).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw Failure(message: "fixture allocation") }
        var argv = strings + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [nil]
        return try argv.withUnsafeMutableBufferPointer { av in
            try env.withUnsafeMutableBufferPointer { ev in
                try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(),
                    executable: executable, actions: &actions, attributes: &attributes,
                    arguments: av.baseAddress, environment: ev.baseAddress, streamsDrained: { true })
            }
        }
    }

    private static func withFixture(_ args: [String]? = nil,
                                    body: (OwnedSpawnAnchor, String) throws -> OwnedDirectChild?) throws {
        let root = try RuntimeFixtureSession.fixturePrefix("shadow-sync-custody-anchor-") + RunIdentity.make()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var created = stat()
        try check(lstat(root, &created) == 0 && created.st_mode & S_IFMT == S_IFDIR
            && created.st_uid == geteuid(), "custody fixture identity unavailable")
        var anchor: OwnedSpawnAnchor?
        var failure: Error?
        do {
            let child = try args.map { try spawn("/bin/bash", $0 + [root + "/descendant"]) } ?? spawn()
            anchor = child
            // The original anchor retains the transferred owner even if this
            // body's later assertion throws; no PID-keyed adoption ledger.
            _ = try body(child, root)
        } catch { failure = error }
        if let anchor {
            RuntimeFixtureSession.drain(anchor)
            try check(anchor.testingRuntimeRetired, "original custody not retired after actual reap")
        }
        var current = stat()
        guard lstat(root, &current) == 0 && current.st_dev == created.st_dev
            && current.st_ino == created.st_ino && current.st_mode & S_IFMT == S_IFDIR
            && current.st_uid == geteuid() && current.st_mode & 0o077 == 0 else {
            throw Failure(message: "custody fixture cleanup identity refused; body=\(String(describing: failure))")
        }
        do { try FileManager.default.removeItem(atPath: root) }
        catch { throw Failure(message: "custody fixture cleanup failed: \(error); body=\(String(describing: failure))") }
        if let failure { throw failure }
    }

    private static func transfer(_ anchor: OwnedSpawnAnchor, executable: String = "/bin/sleep",
                                 policy: OwnedDirectChildReapPolicy = .afterGroupDrain) throws -> OwnedDirectChild {
        try anchor.transfer(expectedExecutable: executable, generation: RunIdentity.make(), reapPolicy: policy)
    }

    private static func awaitHeld(_ owner: OwnedDirectChild) throws {
        let deadline = MonotonicDeadline(seconds: 3)
        while owner.terminalStatusHeld == nil && !deadline.hasExpired {
            _ = owner.poll(); usleep(1_000)
        }
        try check(owner.terminalStatusHeld != nil && owner.observation == .running,
                  "terminal child was not retained")
    }

    static func closedFlags() throws {
        for flags in [requiredFlags & ~Int16(POSIX_SPAWN_START_SUSPENDED),
                      requiredFlags & ~Int16(POSIX_SPAWN_CLOEXEC_DEFAULT),
                      requiredFlags | Int16(POSIX_SPAWN_SETEXEC)] {
            // Invalid executable keeps a broken SETEXEC validator from replacing
            // this test process; correct code rejects flags before attempting it.
            do {
                let unexpected = try spawn("/dev/null", [], flags: flags)
                _ = unexpected.killSuspended(); _ = try unexpected.wait(timeout: 3)
                throw Failure(message: "unsafe spawn flags accepted")
            } catch ProcessOwnershipError.invalidRegistration {}
        }
    }

    static func failedIdentity() throws {
        try withFixture { anchor, _ in
            do {
                _ = try anchor.transfer(expectedExecutable: "/bin/echo", generation: RunIdentity.make())
                throw Failure(message: "wrong executable accepted")
            } catch ProcessOwnershipError.identityMismatch {}
            try check(try anchor.wait(timeout: 0) == .suspended, "failed identity lost suspended custody")
            try check(anchor.killSuspended(), "failed identity could not be terminated")
            guard case .reaped(let raw) = try anchor.wait(timeout: 3) else { throw Failure(message: "failed identity not reaped") }
            try check(raw & 0x7f == SIGKILL && !anchor.killSuspended(), "bootstrap terminal signaling reopened")
            return nil
        }
    }

    static func transferOnce() throws {
        try withFixture { anchor, _ in
            let owner = try transfer(anchor, policy: .immediate)
            try check(anchor.observation == .transferred && anchor.poll() == .transferred
                && !anchor.killSuspended(), "bootstrap custody survived transfer")
            do {
                _ = try anchor.transfer(expectedExecutable: "/bin/sleep", generation: RunIdentity.make())
                throw Failure(message: "second transfer accepted")
            } catch ProcessOwnershipError.invalidRegistration {}
            try check(owner.send(SIGCONT) && owner.send(SIGKILL), "transferred owner could not signal")
            guard case .reaped = try owner.wait(timeout: 3) else { throw Failure(message: "transferred owner did not reap") }
            return owner
        }
    }

    static func terminalHold() throws {
        try withFixture(["-c", "exit 7", "fixture"]) { anchor, _ in
            let owner = try transfer(anchor, executable: "/bin/bash")
            try check(owner.send(SIGCONT), "held child resume refused")
            try awaitHeld(owner)
            try check(owner.terminalStatusHeld == 7 << 8 && owner.poll() == .running,
                      "terminal status did not preserve unreaped anchor")
            try check(try owner.wait(timeout: 0) == .running
                && owner.reapAfterGroupDrain(streamsDrained: false) == .running,
                "timeout or missing EOF released terminal anchor")
            try check(!owner.send(SIGCONT), "terminal-held child resumed")
            try check(owner.reapAfterGroupDrain(streamsDrained: true) == .reaped(7 << 8),
                      "qualified sole anchor not reaped")
            try check(!owner.send(SIGKILL) && !owner.send(SIGTERM), "signal followed final reap")
            return owner
        }
    }

    static func bootstrapCancel() throws {
        try withFixture(["-c", ": > \"$1\"", "fixture"]) { anchor, root in
            let owner = try transfer(anchor, executable: "/bin/bash")
            try check(owner.poll() == .running && owner.terminalStatusHeld == nil,
                      "initial suspension was mistaken for terminal loss")
            try check(!owner.send(SIGTERM) && owner.send(SIGKILL), "bootstrap cancellation lost exact child")
            try check(!owner.send(SIGCONT), "cancelled bootstrap admission reopened")
            guard case .reaped(let raw) = try owner.wait(timeout: 3) else {
                throw Failure(message: "never-resumed child not reaped")
            }
            try check(raw & 0x7f == SIGKILL && !owner.send(SIGCONT), "bootstrap terminal result was invalid")
            try check(!FileManager.default.fileExists(atPath: root + "/descendant"),
                      "cancelled bootstrap executed target code")
            return owner
        }
    }

    static func groupDrain() throws {
        let script = "trap '' TERM; /bin/sleep 12 & printf '%s' \"$!\" > \"$1\"; exit 0"
        try withFixture(["-c", script, "fixture"]) { anchor, root in
            let owner = try transfer(anchor, executable: "/bin/bash")
            try check(owner.send(SIGCONT), "group fixture resume refused")
            try awaitHeld(owner)
            let pidText = try String(contentsOfFile: root + "/descendant", encoding: .utf8)
            guard let descendant = Int32(pidText), descendant > 1 else { throw Failure(message: "descendant receipt absent") }
            try check(OwnedProcessGroupSnapshot.capture(anchor: anchor.processID) == .otherMembers(1),
                      "live descendant not enumerated with terminal leader")
            try check(owner.reapAfterGroupDrain(streamsDrained: true) == .running,
                      "leader reaped while descendant remained")
            _ = owner.send(SIGTERM)
            try check(OwnedProcessGroupSnapshot.capture(anchor: anchor.processID) == .otherMembers(1),
                      "TERM-resistant descendant unexpectedly absent")
            try check(owner.send(SIGKILL), "terminal-held group kill refused")
            let deadline = MonotonicDeadline(seconds: 3)
            var result = owner.observation
            repeat {
                result = owner.reapAfterGroupDrain(streamsDrained: true)
                if case .reaped = result { break }; usleep(5_000)
            } while !deadline.hasExpired
            try check(result == .reaped(0), "descendant drainage did not permit exact leader reap")
            try check(kill(descendant, 0) == -1 && errno == ESRCH,
                      "fixture descendant remained after group receipt")
            return owner
        }
    }

    static func incompleteEnumeration() throws {
        let leader: pid_t = 201
        let width = MemoryLayout<pid_t>.stride
        let oversizedEstimate = Int32((OwnedProcessGroupSnapshot.maximumPIDs + 100) * width)
        try check(OwnedProcessGroupSnapshot.initialCapacity(estimatedBytes: oversizedEstimate, error: 0)
                    == OwnedProcessGroupSnapshot.maximumPIDs,
                  "system-wide advisory estimate rejected a potentially small group")
        for (bytes, error) in [(Int32(0), Int32(0)), (Int32(-4), Int32(0)),
                              (Int32(3), Int32(0)), (Int32(width), EACCES)] {
            try check(OwnedProcessGroupSnapshot.initialCapacity(estimatedBytes: bytes, error: error) == nil,
                      "invalid advisory estimate accepted")
        }
        var largeStorage = [pid_t](repeating: 0, count: OwnedProcessGroupSnapshot.maximumPIDs)
        largeStorage[0] = leader
        try check(OwnedProcessGroupSnapshot.validate(anchor: leader, storage: largeStorage,
            bytesWritten: width, error: 0) == .onlyAnchor, "complete small group refused with capped allocation")
        for (values, bytes, error) in [([leader, 0], 0, Int32(0)), ([leader, 0], width, EACCES),
            ([leader], width, Int32(0)), ([leader, 0], 3, Int32(0)), ([202, 0], width, Int32(0)),
            ([leader, leader, 0], width * 2, Int32(0)), ([leader, 0, 0], width * 2, Int32(0))] {
            try check(OwnedProcessGroupSnapshot.validate(anchor: leader, storage: values, bytesWritten: bytes, error: error) == .unavailable,
                      "incomplete kernel group observation accepted")
        }
        try check(OwnedProcessGroupSnapshot.validate(anchor: leader, storage: [leader, 0], bytesWritten: width, error: 0) == .onlyAnchor,
                  "complete anchor observation refused")
    }

    private final class Results: @unchecked Sendable {
        private let mutex = NSLock(); private var values: [OwnedDirectChildObservation] = []
        func add(_ value: OwnedDirectChildObservation) { mutex.lock(); values.append(value); mutex.unlock() }
        var snapshot: [OwnedDirectChildObservation] { mutex.lock(); defer { mutex.unlock() }; return values }
    }

    static func concurrentFinalizers() throws {
        try withFixture(["-c", "exit 0", "fixture"]) { anchor, _ in
            let owner = try transfer(anchor, executable: "/bin/bash")
            try check(owner.send(SIGCONT), "finalizer resume refused"); try awaitHeld(owner)
            let values = Results(); let group = DispatchGroup()
            for _ in 0..<2 {
                group.enter(); DispatchQueue.global().async {
                    values.add(owner.reapAfterGroupDrain(streamsDrained: true)); group.leave()
                }
            }
            try check(group.wait(timeout: .now() + 3) == .success, "finalizers did not join")
            try check(values.snapshot == [.reaped(0), .reaped(0)], "finalizers disagreed")
            let calls = owner.testingWaitSystemCallCount
            try check(owner.reapAfterGroupDrain(streamsDrained: true) == .reaped(0)
                && owner.poll() == .reaped(0) && owner.testingWaitSystemCallCount == calls,
                "terminal finalizer performed another wait")
            return owner
        }
    }

    static func ownershipFailure() throws {
        try withFixture { anchor, _ in
            let owner = try transfer(anchor)
            // Never resumed: no descendant can exist in this injected-error test.
            owner.testingInjectWaitErrors([ECHILD])
            try check(owner.poll() == .ownershipFailure(ECHILD), "held ECHILD became success")
            let calls = owner.testingWaitSystemCallCount
            try check(!owner.send(SIGKILL) && !owner.send(SIGCONT)
                && owner.reapAfterGroupDrain(streamsDrained: true) == .ownershipFailure(ECHILD)
                && owner.testingWaitSystemCallCount == calls, "poisoned held custody issued syscalls")
            return owner
        }
    }

    static func signalReapOrdering() throws {
        try withFixture(["-c", "exit 0", "fixture"]) { anchor, _ in
            let owner = try transfer(anchor, executable: "/bin/bash")
            try check(owner.send(SIGCONT), "ordering resume refused"); try awaitHeld(owner)
            let initialSignals = owner.testingSignalSystemCallCount
            let barrier = OwnedDirectChildTestingBarrier(); let attempt = OwnedDirectChildTestingPollAttempt()
            let values = Results(); let group = DispatchGroup()
            owner.testingPauseNextSignal(barrier)
            group.enter(); DispatchQueue.global().async { _ = owner.send(SIGTERM); group.leave() }
            guard barrier.waitUntilEntered() else {
                barrier.release(); _ = group.wait(timeout: .now() + 4)
                throw Failure(message: "held signal boundary not reached")
            }
            owner.testingObserveNextPoll(attempt)
            group.enter(); DispatchQueue.global().async {
                values.add(owner.reapAfterGroupDrain(streamsDrained: true)); group.leave()
            }
            let contended = attempt.waitUntilContended()
            barrier.release()
            let joined = group.wait(timeout: .now() + 4) == .success
            try check(contended && joined && values.snapshot == [.reaped(0)], "finalizer crossed held signal exclusion")
            try check(owner.testingSignalSystemCallCount == initialSignals + 1
                && !owner.send(SIGKILL) && owner.testingSignalSystemCallCount == initialSignals + 1,
                "held signal count or post-reap refusal incorrect")
            return owner
        }
    }
}
#endif

#if SHADOW_SYNC_TESTING
private enum CustodyProtocolSelfTests {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func refuses(_ body: () throws -> Void) throws {
        var refused = false
        do { try body() } catch is CustodyProtocolError { refused = true }
        try check(refused, "custody protocol accepted invalid input")
    }
    static let identity = CustodyBinding(
        requestID: "00000000-0000-4000-8000-000000000001", scopeID: "00000000-0000-4000-8000-000000000002",
        nonce: String(repeating: "a", count: 32), callerGeneration: "00000000-0000-4000-8000-000000000003",
        trustedUID: 501, bootID: "00000000-0000-4000-8000-000000000004", releaseSHA256: String(repeating: "b", count: 64))
    static let start: UInt64 = 100
    static func request(arguments: [String] = ["status", "--porcelain"], kind: CustodyCommandKind = .repositoryGit,
                        mode: CustodyAuthorityMode = .read) throws -> UnvalidatedCustodyRequest {
        var roles: [CustodyDescriptorClaim.Role] = [.request, .control, .status, .state, .namespace, .lifecycle, .workingDirectory]
        if mode.needsOperation { roles.append(.operation) }
        let descriptors = roles.sorted { $0.number < $1.number }.map {
            CustodyDescriptorClaim(role: $0, device: 1, inode: $0.number, uid: 501, mode: 0o100600, links: 1, access: .read)
        }
        return UnvalidatedCustodyRequest(binding: identity, kind: kind, authority: mode, arguments: arguments,
            environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"], budget: try CustodyBudget.make(kind: kind, workSeconds: 1, now: start),
            stdoutLimit: 16_384, stderrLimit: 16_384, inputSHA256: nil, resourcesSHA256: String(repeating: "c", count: 64), descriptors: descriptors)
    }
    static func decode(_ data: Data) throws -> UnvalidatedCustodyRequest {
        try UnvalidatedCustodyRequest.decode(data, expected: identity, permittedWorkSeconds: 1, now: start)
    }
    static func edit(_ data: Data, _ body: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try body(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func message(_ event: CustodyMessage.Event, sequence: UInt64 = 0,
                        outcome: CustodyMessage.Outcome? = nil, status: UInt32? = nil) -> CustodyMessage {
        CustodyMessage(binding: identity, sequence: sequence, event: event, outcome: outcome, waitStatus: status,
                       receiptSHA256: event == .terminal ? String(repeating: "d", count: 64) : nil)
    }
    static func state() throws -> CustodyAdmissionState {
        try CustodyAdmissionState(binding: identity, budget: request().budget)
    }

    static func roundTrip() throws {
        let candidate = try request(arguments: ["status", "quoted\"path", "a\nb", "é", "e\u{301}", "a/b\\c"])
        let data = try candidate.encode()
        let decoded = try decode(data)
        try check(decoded == candidate && (try decoded.encode()) == data, "request bytes changed")
        try check(Array(decoded.arguments[3].utf8) != Array(decoded.arguments[4].utf8), "path normalization lost exact bytes")
        for kind in CustodyCommandKind.allCases {
            let mode: CustodyAuthorityMode = kind == .launchctlMutation ? .lifecycleMutation : .read
            let request = try request(kind: kind, mode: mode)
            try check(try decode(request.encode()) == request, "closed kind roundtrip failed")
        }
        for kind in [CustodyCommandKind.launchctlRead, .signatureCheck] {
            let request = try request(kind: kind, mode: .observation)
            try check(try decode(request.encode()) == request, "observation scope representation failed")
        }
    }
    static func closedJSON() throws {
        let good = try request().encode()
        let text = String(decoding: good, as: UTF8.self)
        let bad = [Data(), Data([0xff]), good + Data("\n".utf8), Data((" " + text).utf8),
                   Data(text.replacingOccurrences(of: "\"schema\":", with: "\"schema\":false,\"schema\":").utf8),
                   Data(text.replacingOccurrences(of: "\"schema\":", with: "\"\\u0073chema\":").utf8),
                   Data(text.replacingOccurrences(of: "\"stdout\":16384", with: "\"stdout\":1e4").utf8),
                   Data(text.replacingOccurrences(of: "\"stdout\":16384", with: "\"stdout\":-1").utf8),
                   Data(text.replacingOccurrences(of: "\"stdout\":16384", with: "\"stdout\":true").utf8),
                   try edit(good) { $0["unknown"] = 1 }, try edit(good) { $0.removeValue(forKey: "limits") },
                   try edit(good) { $0["schema"] = "shadow-sync-custody-request/v2" }]
        for data in bad { try refuses { _ = try decode(data) } }
    }
    static func bindings() throws {
        let good = try request().encode()
        for key in ["request", "scope", "nonce", "generation", "uid", "boot", "release"] {
            let bad = try edit(good) { root in
                var v = root["binding"] as! [String: Any]
                v[key] = key == "uid" ? 502 : String(repeating: "e", count: key == "nonce" ? 32 : key == "release" ? 64 : 36)
                root["binding"] = v
            }
            try refuses { _ = try decode(bad) }
        }
        for key in ["kind", "authority", "resources", "input"] {
            try refuses { _ = try decode(edit(good) { root in
                var v = root["command"] as! [String: Any]; v[key] = "unknown"; root["command"] = v
            }) }
        }
    }
    static func descriptorManifest() throws {
        let good = try request().encode()
        for fault in 0..<7 {
            try refuses { _ = try decode(edit(good) { root in
                var rows = root["descriptors"] as! [[String: Any]]
                switch fault {
                case 0: rows.append(rows[0])
                case 1: rows.removeFirst()
                case 2: rows[0]["fd"] = 195
                case 3: rows[0]["role"] = "extra"
                case 4: rows[0]["mode"] = 65536
                case 5: rows.reverse()
                default: rows.removeAll { $0["role"] as? String == "operation" }
                }
                root["descriptors"] = rows
            }) }
        }
        try refuses { _ = try request(kind: .repositoryGit, mode: .observation).encode() }
        try refuses { _ = try request(kind: .launchctlMutation, mode: .read).encode() }
    }
    static func resourceBounds() throws {
        let good = try request().encode()
        for fault in 0..<7 {
            try refuses { _ = try decode(edit(good) { root in
                var c = root["command"] as! [String: Any]
                switch fault {
                case 0: c["arguments"] = Array(repeating: "x", count: 257)
                case 1: c["arguments"] = [String(repeating: "x", count: 65_537)]
                case 2: c["arguments"] = ["x\u{0}y"]
                case 3: c["environment"] = [["key": "X", "value": "a"], ["key": "X", "value": "b"]]
                case 4: c["environment"] = [["key": "BAD=KEY", "value": "x"]]
                case 5: root["limits"] = ["stdout": 0, "stderr": 1]
                default: root["limits"] = ["stdout": 33_554_433, "stderr": 1]
                }
                root["command"] = c
            }) }
        }
        try refuses { _ = try decode(Data(repeating: 32, count: 1_048_577)) }
    }
    static func absoluteBudgets() throws {
        let budget = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 5, now: start)
        try budget.validate(kind: .repositoryGit, permittedWorkSeconds: 5, now: budget.work - 1)
        try check(budget.work == start + UInt64(ChildProcessBudget.seconds(5) * 1e9), "work limit changed")
        for n in [0, -1, TimeInterval.nan, .infinity, TimeInterval.leastNonzeroMagnitude, 121] {
            try refuses { _ = try CustodyBudget.make(kind: .repositoryGit, workSeconds: n, now: start) }
        }
        try refuses { _ = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 1, now: UInt64.max) }
        try refuses { try budget.validate(kind: .repositoryGit, permittedWorkSeconds: 1, now: start) }
        try refuses { try budget.validate(kind: .repositoryGit, permittedWorkSeconds: 5, now: start - 1) }
        try refuses { try budget.validate(kind: .repositoryGit, permittedWorkSeconds: 5, now: budget.work) }
        let good = try request().encode()
        for key in ["work", "term", "kill", "receipt"] {
            try refuses { _ = try decode(edit(good) { root in
                var b = root["budget"] as! [String: Any]; b[key] = UInt64.max; root["budget"] = b
            }) }
        }
    }
    static func cancellationBudget() throws {
        let budget = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 120, now: start)
        let cancelled = try budget.draining(at: start + 1)
        try check(cancelled.work == start + 1 && cancelled.term < budget.term && cancelled.receipt < budget.receipt,
                  "early cancellation did not clip cleanup")
        try check(try cancelled.draining(at: cancelled.receipt + 1) == cancelled, "retry renewed cleanup budget")
        try check(try budget.draining(at: budget.receipt + 1) == budget, "late drain extended deadline")
        try refuses { _ = try budget.draining(at: start - 1) }
        let short = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 120,
            termSeconds: 0.1, killSeconds: 0.2, receiptSeconds: 0.3, now: start)
        try short.validate(kind: .repositoryGit, permittedWorkSeconds: 120,
            permittedTermSeconds: 0.1, permittedKillSeconds: 0.2, permittedReceiptSeconds: 0.3, now: start)
        let drained = try short.draining(at: start + 1)
        try check(drained.term - drained.work == short.term - short.work
            && drained.kill - drained.term == short.kill - short.term
            && drained.receipt - drained.kill == short.receipt - short.kill,
            "cancellation widened caller cleanup intervals")
        try check(try drained.draining(at: drained.receipt + 1) == drained, "short retry extended cleanup")
        let zero = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 1,
            termSeconds: 0, killSeconds: 0, receiptSeconds: 0, now: start)
        try check(zero.work == zero.receipt, "zero grace expanded")
        for n in [-1, TimeInterval.nan, .infinity, 3] {
            try refuses { _ = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 1, termSeconds: n, now: start) }
            try refuses { _ = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 1, killSeconds: n, now: start) }
            try refuses { _ = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 1, receiptSeconds: n, now: start) }
            try refuses { try short.validate(kind: .repositoryGit, permittedWorkSeconds: 120, permittedTermSeconds: n, now: start) }
            try refuses { try short.validate(kind: .repositoryGit, permittedWorkSeconds: 120, permittedKillSeconds: n, now: start) }
            try refuses { try short.validate(kind: .repositoryGit, permittedWorkSeconds: 120, permittedReceiptSeconds: n, now: start) }
        }
        let encoded = try request().encode()
        try refuses { _ = try UnvalidatedCustodyRequest.decode(encoded, expected: identity,
            permittedWorkSeconds: 1, permittedTermSeconds: 0.1, now: start) }
        try refuses { _ = try UnvalidatedCustodyRequest.decode(encoded, expected: identity,
            permittedWorkSeconds: 1, permittedKillSeconds: 0.1, now: start) }
        try refuses { _ = try UnvalidatedCustodyRequest.decode(encoded, expected: identity,
            permittedWorkSeconds: 1, permittedReceiptSeconds: 0.1, now: start) }
    }
    static func messages() throws {
        for event in [CustodyMessage.Event.ready, .admit, .cancel, .pending] {
            let candidate = message(event)
            try check(try CustodyMessage.decode(candidate.encode(), expected: identity, channel: candidate.channel) == candidate,
                      "control/status roundtrip failed")
            try refuses { _ = try CustodyMessage.decode(candidate.encode(), expected: identity,
                                                       channel: candidate.channel == .control ? .status : .control) }
        }
        for outcome in [CustodyMessage.Outcome.completed, .failed, .refused, .cancelled, .timedOut] {
            let m = message(.terminal, outcome: outcome, status: outcome == .completed ? 0 : outcome == .failed ? 256 : nil)
            try check(try CustodyMessage.decode(m.encode(), expected: identity, channel: .status) == m, "terminal frame failed")
        }
        try refuses { _ = try message(.ready, outcome: .completed, status: 0).encode() }
        try refuses { _ = try message(.terminal, outcome: .completed, status: 1).encode() }
        // Command exit zero does not erase a transaction-level output/I/O fault;
        // the real helper journal and exact reaping still authorize retirement.
        let failedZero = message(.terminal, outcome: .failed, status: 0)
        try check(try CustodyMessage.decode(failedZero.encode(), expected: identity, channel: .status) == failedZero,
                  "transaction failure lost successful raw command status")
        try refuses { _ = try message(.terminal, outcome: .failed).encode() }
        let refusedSuspended = message(.terminal, outcome: .refused, status: UInt32(SIGKILL))
        try check(try CustodyMessage.decode(refusedSuspended.encode(), expected: identity, channel: .status) == refusedSuspended,
                  "never-resumed target KILL status refused")
        for invalid in [UInt32(0x7f), 0xffff, 0x1_0000] {
            try refuses { _ = try message(.terminal, outcome: .failed, status: invalid).encode() }
        }
        try refuses { _ = try message(.terminal, outcome: .refused, status: 0).encode() }
        try refuses { _ = try message(.terminal).encode() }
        try refuses { _ = try message(.admit, sequence: UInt64.max).encode() }
    }
    static func frameFragments() throws {
        let payload = try message(.ready).encode()
        let framed = try CustodyFrameDecoder.frame(payload)
        for split in 0...framed.count {
            var decoder = CustodyFrameDecoder()
            let a = try decoder.append(Data(framed.prefix(split)))
            let b = try decoder.append(Data(framed.dropFirst(split)))
            try check(a + b == [payload], "fragmented frame changed bytes")
            try decoder.finish()
        }
        var decoder = CustodyFrameDecoder()
        try check(try decoder.append(framed + framed) == [payload, payload], "coalesced frames lost")
        try decoder.finish()
        var maximum = CustodyFrameDecoder()
        let full = Data(repeating: 65, count: 16_384)
        try check(try maximum.append(CustodyFrameDecoder.frame(full)) == [full], "maximum frame refused")
        try maximum.finish()
    }
    static func frameRefusals() throws {
        for bad in [Data([0, 0, 0, 0]), Data([0, 0, 64, 1]), Data([255, 255, 255, 255]), Data(repeating: 0, count: 16_389)] {
            var decoder = CustodyFrameDecoder()
            try refuses { _ = try decoder.append(bad) }
            try refuses { _ = try decoder.append(Data()) }
            try refuses { try decoder.finish() }
        }
        let frame = try CustodyFrameDecoder.frame(message(.ready).encode())
        for prefix in 1..<frame.count {
            var decoder = CustodyFrameDecoder()
            _ = try decoder.append(Data(frame.prefix(prefix)))
            try refuses { try decoder.finish() }
        }
        var closed = CustodyFrameDecoder(); try closed.finish()
        try refuses { _ = try closed.append(frame) }
    }
    static func admission() throws {
        var s = try state()
        try check(try !s.permitsResume(now: start), "target allowed before ready")
        try s.accept(message(.ready), now: start)
        try check(try !s.permitsResume(now: start), "target allowed before admit")
        try s.accept(message(.admit), now: start)
        try check(try s.permitsResume(now: start), "valid admit refused")
        try s.accept(message(.terminal, sequence: 1, outcome: .completed, status: 0), now: start)
        try check(s.phase == .terminal && (try !s.permitsResume(now: start)), "terminal reopened")
        try refuses { try s.accept(message(.admit, sequence: 1), now: start) }
        var early = try state()
        try early.accept(message(.terminal, outcome: .refused), now: start)
        try check(early.phase == .terminal && !early.admitted, "bootstrap refusal rejected")
    }
    static func admissionFaults() throws {
        for cut in 0..<3 {
            var s = try state()
            if cut > 0 { try s.accept(message(.ready), now: start) }
            if cut > 1 { try s.accept(message(.admit), now: start) }
            try s.closeAdmission(now: start) // EOF or cancellation, including before resume.
            try check(try !s.permitsResume(now: start), "EOF allowed target execution")
            let controlSequence: UInt64 = cut > 1 ? 1 : 0
            try refuses { try s.accept(message(.admit, sequence: controlSequence), now: start) }
            try check(s.phase == .draining, "invalid admission escaped drainage")
        }
        var replay = try state(); try replay.accept(message(.ready), now: start)
        try refuses { try replay.accept(message(.ready), now: start) }
        try check(replay.phase == .draining, "replay did not poison admission")
        var expired = try state(); try expired.accept(message(.ready), now: start)
        try expired.accept(message(.admit), now: start)
        try check(try !expired.permitsResume(now: expired.budget.work), "expired request resumed")
        var cancel = try state(); try cancel.accept(message(.cancel), now: start)
        try cancel.accept(message(.pending), now: start)
        try check(cancel.phase == .draining, "pending treated as terminal")
        try cancel.accept(message(.terminal, sequence: 1, outcome: .cancelled), now: start)
        try check(cancel.phase == .terminal, "cancelled drain terminal refused")
        var wrongSequence = try state()
        try refuses { try wrongSequence.accept(message(.ready, sequence: 1), now: start) }
        try check(try !wrongSequence.permitsResume(now: start), "bad sequence allowed resume")
    }
}
// Fixed observation for the four sequential requests of one owned fixture server.
// This is causal fixture attribution, never kernel descriptor-pair identity.
final class M4HostRejectionObservation: @unchecked Sendable {
    enum Stage: String {
        case unobserved, peerIdentity, nonblocking, deadline, newlineBounds
        case frameLimit, wait, read, extraBufferedBytes, decode, requestValidation
    }
    private let lock = NSLock()
    private var accepted = 0
    private var completed = 0
    private var confirmed = 0
    private var active = 0
    private var ambiguous = false
    private var emitted = false
    private var stage: Stage = .unobserved
    private var frameBytes = 0
    private var wasRejected = false

    func acceptedConnection() -> Int {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock()
        defer { lock.unlock() }
        if accepted >= 4 || active != 0 || completed != accepted {
            ambiguous = true
        }
        accepted = min(accepted + 1, 5)
        active = accepted
        stage = .unobserved
        frameBytes = 0
        wasRejected = false
        return active
    }

    func entered(_ next: Stage, bytes: Int? = nil) {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock()
        defer { lock.unlock() }
        guard active > 0, active <= 4 else { ambiguous = true; return }
        stage = next
        if let bytes {
            guard bytes >= 0, bytes <= HostControlIO.maximumFrameBytes + 4_096 else {
                ambiguous = true
                return
            }
            frameBytes = bytes
        }
    }

    func rejected() {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock()
        defer { lock.unlock() }
        wasRejected = true
    }

    func completedConnection(_ ordinal: Int?) {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock()
        defer { lock.unlock() }
        guard let ordinal, ordinal == active, ordinal == completed + 1 else {
            ambiguous = true
            return
        }
        completed = min(ordinal, 5)
        active = 0
    }

    // Called only after each original framed response and its original checks.
    func confirmedResponse(_ ordinal: Int) {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock()
        defer { lock.unlock() }
        guard ordinal == confirmed + 1, ordinal <= 3 else {
            ambiguous = true
            return
        }
        confirmed = ordinal
    }

    func emitFirstFailure() {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock()
        guard !emitted else { lock.unlock(); return }
        emitted = true
        let bound = !ambiguous && accepted == 4 && completed == 4
            && confirmed == 3 && active == 0 && wasRejected
        let binding = bound ? "sequential-fixture" : "unbound"
        let observedStage = bound ? stage.rawValue : Stage.unobserved.rawValue
        let observedBytes = bound ? frameBytes : -1
        let counts = (accepted, completed, confirmed)
        lock.unlock()
        fputs("M4 SERVER REJECTION FIRST FAILURE binding=\(binding) stage=\(observedStage) frame_bytes=\(observedBytes) accepted=\(counts.0) completed=\(counts.1) responses=\(counts.2)\n", stderr)
        fflush(stderr)
    }
}

#endif
