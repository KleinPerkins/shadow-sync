#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum ClosedProcessOwnershipSelfTestRunner {
    private struct Failure: Error { let detail: String }
    private static func check(_ value: Bool, _ text: String) throws {
        if !value { throw Failure(detail: text) }
    }
    private static func barrier(_ id: String) {
        guard RuntimeFixtureSession.guardianProbeTarget() == id else { return }
        print("GUARDIAN PROBE " + id); fflush(stdout)
        guard let registry = try? RuntimeFixtureSession.current() else { return }
        while registry.snapshot().reason == nil { usleep(5_000) }
    }
    public static func runAll(onPass: (String) -> Void) throws {
        let names = ["before-spawn", "crossing-spawn", "transfer-refusal", "validation-refusal",
                     "cancel-before-resume", "terminal-descendant", "backpressure", "assertion-unwind", "deadline-at-resume", "owner-ordering"]
        for name in names {
            let id = "closed-runner-" + name
            try RuntimeFixtureSession.withCase(id) {
                if name == "owner-ordering" { try RunnerOwnerOrderingFixtures.closed(); return }
                let fixture = try Fixture()
                defer { try? fixture.remove() }
                let token = CancellationToken()
                var observed: OwnedSpawnAnchor?
                var phaseObserved = false
                let deadlineEntered = DispatchSemaphore(value: 0)
                let deadlineFinished = DispatchSemaphore(value: 0)
                var deadlineThreadStarted = false
                var hooks = ClosedProcessRunnerTestingHooks()
                hooks.beforeSpawn = { if name == "before-spawn" { barrier(id) } }
                hooks.afterSpawn = { if name == "crossing-spawn" { barrier(id) } }
                hooks.beforeTransfer = { anchor in
                    observed = anchor
                    if name == "transfer-refusal" { barrier(id) }
                }
                hooks.rejectTransfer = name == "transfer-refusal"
                hooks.beforeResume = { _, owner in
                    if name == "cancel-before-resume" { barrier(id); token.cancel() }
                    if name == "deadline-at-resume" {
                        let pause = OwnedDirectChildTestingBarrier(pauseTimeout: 3)
                        owner.testingPauseRuntimeResume(pause)
                        deadlineThreadStarted = true
                        Thread.detachNewThread {
                            if pause.waitUntilEntered() {
                                let expiry = MonotonicDeadline(seconds: ChildProcessBudget.seconds(0.1) + 0.05)
                                while !expiry.hasExpired { usleep(5_000) }
                                deadlineEntered.signal()
                            }
                            pause.release(); deadlineFinished.signal()
                        }
                    }
                }
                hooks.afterResume = { _, _, resumed in
                    if name == "assertion-unwind" { barrier(id) }
                    if name == "assertion-unwind" && resumed { throw Failure(detail: "injected after resume") }
                }
                hooks.duringDrain = { owner, outCount, errCount, outTruncated, errTruncated in
                    guard !phaseObserved else { return }
                    if name == "terminal-descendant", let owner, owner.terminalStatusHeld == 0,
                       let text = try? String(contentsOfFile: fixture.path + "/descendant", encoding: .utf8),
                       let pid = Int32(text),
                       let child = try? ProcessIdentity.capture(processID: pid, generation: RunIdentity.make(),
                           expectedExecutablePath: "/bin/sleep"),
                       child.processGroupID == owner.identity.processID, child.userID == geteuid() {
                        var info = proc_bsdinfo()
                        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                            Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                            info.pbi_status != SZOMB else { return }
                        phaseObserved = true; barrier(id)
                    } else if name == "backpressure", outCount == 64, errCount == 64,
                              outTruncated, errTruncated {
                        phaseObserved = true; barrier(id)
                    }
                }
                let script: String
                switch name {
                case "terminal-descendant": script = "trap '' TERM; /bin/sleep 10 & printf '%s' \"$!\" > \"$2\"; exit 0"
                case "backpressure": script = "i=0; while [ $i -lt 20000 ]; do printf 01234567890123456789012345678901; printf 01234567890123456789012345678901 >&2; i=$((i+1)); done"
                case "assertion-unwind": script = "printf ran > \"$1\"; /bin/sleep 10"
                default: script = "printf ran > \"$1\""
                }
                let runner = ClosedProcessRunner.testing(outputLimit: name == "backpressure" ? 64 : 4096, hooks: hooks)
                let result = Result { try runner.run(
                    command: ClosedProcessCommand(executable: "/bin/bash", arguments: ["-c", script, "fixture", fixture.marker, fixture.path + "/descendant"]),
                    environment: ClosedProcessRunner.environment(account: fixture.account),
                    workingDirectoryDescriptor: fixture.directory, account: fixture.account,
                    timeout: ["terminal-descendant", "deadline-at-resume"].contains(name) ? 0.1 : 5, cancellation: token,
                    validateSuspendedChild: { _ in
                        if name == "validation-refusal" { barrier(id); throw Failure(detail: "publisher refusal fixture") }
                    }) }
                if deadlineThreadStarted {
                    // The owned runner already converged. Join its fixture
                    // control thread before releasing any case resources.
                    deadlineFinished.wait()
                    phaseObserved = deadlineEntered.wait(timeout: .now()) == .success
                }
                if let observed { RuntimeFixtureSession.drain(observed) }
                let registry = try RuntimeFixtureSession.current()
                let snapshot = registry.snapshot()
                let markerAbsent = !FileManager.default.fileExists(atPath: fixture.marker)
                if snapshot.reason != nil {
                    // Actual original-anchor and stream cleanup proof, emitted
                    // before withCase deliberately rejects cancelled completion.
                    try check(snapshot.cleanupComplete && snapshot.spawned == snapshot.reaped, "cancelled runner lost custody")
                    let safety: String
                    if observed == nil {
                        try check(snapshot.spawned == 0 && markerAbsent, "pre-spawn cancellation executed target")
                        safety = "no_spawn"
                    } else if ["before-spawn", "crossing-spawn", "transfer-refusal", "validation-refusal", "cancel-before-resume"].contains(name) {
                        try check(observed!.unexecutedProof() != nil && markerAbsent, "rejected target resumed")
                        safety = "never_resumed"
                    } else {
                        if ["terminal-descendant", "backpressure"].contains(name) {
                            try check(phaseObserved, "named cancellation phase was never observed")
                        }
                        safety = "drained"
                    }
                    let proof: [String: Any] = ["schema": "shadow-sync-closed-runner-probe/v1", "case": id,
                        "reason": snapshot.reason!.rawValue, "safety": safety, "spawned": snapshot.spawned,
                        "reaped": snapshot.reaped, "marker_absent": markerAbsent, "phase_observed": phaseObserved]
                    let bytes = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
                    print("GUARDIAN PROOF " + String(decoding: bytes, as: UTF8.self)); fflush(stdout)
                } else {
                    switch name {
                    case "transfer-refusal", "validation-refusal":
                        guard case .failure = result else { throw Failure(detail: "rejected validation succeeded") }
                        try check(observed?.unexecutedProof() != nil && markerAbsent, "refused original executed")
                    case "cancel-before-resume":
                        let value = try result.get()
                        try check(value.cancelled && value.terminationRequested && !value.succeeded
                            && observed?.unexecutedProof() != nil && markerAbsent, "token cancellation reopened resume")
                    case "deadline-at-resume":
                        let value = try result.get()
                        try check(phaseObserved && value.timedOut && value.terminationRequested
                            && !value.succeeded && observed?.unexecutedProof() != nil && markerAbsent,
                            "expired final resume executed target or lost original child")
                    case "terminal-descendant":
                        let value = try result.get()
                        try check(phaseObserved && value.status == 0 && value.timedOut && value.terminationRequested,
                                  "terminal leader or surviving descendant was discarded")
                    case "backpressure":
                        let value = try result.get()
                        try check(phaseObserved && value.status == 0 && !value.timedOut && value.stdout.count == 64
                            && value.stderr.count == 64 && value.stdoutTruncated && value.stderrTruncated,
                            "bounded capture or actual EOF lost")
                    case "assertion-unwind":
                        guard case .failure(let failure as Failure) = result, failure.detail == "injected after resume" else {
                            throw Failure(detail: "original post-spawn failure was replaced")
                        }
                    default:
                        try check(try result.get().succeeded && !markerAbsent, "normal command failed")
                    }
                    try check(snapshot.spawned == 1 && snapshot.reaped == 1 && snapshot.cleanupComplete,
                              "runner did not retain exactly one original child")
                }
                try fixture.remove()
            }
            onPass(id)
        }
    }

    private final class Fixture {
        let path: String, marker: String
        let directory: Int32
        let account: EffectiveAccount
        private let identity: FileIdentity
        private var removed = false
        init() throws {
            guard let base = ProcessInfo.processInfo.environment["TMPDIR"], base.hasPrefix("/") else {
                throw Failure(detail: "private TMPDIR required")
            }
            var info = stat()
            try check(lstat(base, &info) == 0 && info.st_uid == geteuid()
                && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0, "unsafe fixture base")
            path = base + "/shadow-sync-closed-runner-" + RunIdentity.make()
            try check(mkdir(path, 0o700) == 0, "fixture create")
            directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(directory >= 0 && fstat(directory, &info) == 0, "fixture open")
            identity = FileIdentity(info); marker = path + "/executed"
            account = try EffectiveAccount.isolated(homeDirectory: path)
        }
        func remove() throws {
            if removed { return }
            var named = stat(), opened = stat()
            try check(lstat(path, &named) == 0 && fstat(directory, &opened) == 0
                && FileIdentity(named).matchesStableNode(identity)
                && FileIdentity(opened).matchesStableNode(identity), "fixture cleanup identity")
            try FileManager.default.removeItem(atPath: path); close(directory); removed = true
        }
    }
}
#endif
