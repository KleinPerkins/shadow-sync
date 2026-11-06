#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Real-child qualification of the testing adapter. Each body retains its
/// registry until actual cleanup. No outer timeout may terminate this guardian.
public enum RuntimeFixtureOwnershipSelfTestRunner {
    private struct Failure: Error { let message: String }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func eventually(_ body: () -> Bool) throws {
        let limit = MonotonicDeadline(seconds: 4)
        repeat {
            if body() { return }
            usleep(10_000)
        } while !limit.hasExpired
        throw Failure(message: "fixture observation deadline")
    }
    private static func drain(_ registry: RuntimeFixtureCustody) {
        // An unresolved original child is retained, never converted into a
        // bounded-time success or abandoned by throwing from fixture cleanup.
        registry.cancel(.cancelled, now: now)
        var reported = false
        let limit = MonotonicDeadline(seconds: 6)
        while !registry.snapshot().cleanupComplete {
            registry.tick(now: now)
            if limit.hasExpired && !reported {
                fputs("RUNTIME CUSTODY CLEANUP PENDING\n", stderr); fflush(stderr)
                reported = true
            }
            usleep(10_000)
        }
    }
    private static func fixture(_ body: (RuntimeFixtureCustody, String) throws -> Void) throws {
        guard let supplied = ProcessInfo.processInfo.environment["TMPDIR"],
              supplied.hasPrefix("/"), !supplied.utf8.contains(0) else {
            throw Failure(message: "private fixture TMPDIR is required")
        }
        let base = URL(fileURLWithPath: supplied, isDirectory: true).standardizedFileURL
        var baseInfo = stat()
        try check(lstat(base.path, &baseInfo) == 0 && baseInfo.st_mode & S_IFMT == S_IFDIR
            && baseInfo.st_uid == geteuid() && baseInfo.st_mode & 0o077 == 0,
            "fixture TMPDIR is not an owned private directory")
        let root = base.appendingPathComponent("shadow-sync-runtime-owner-" + RunIdentity.make()).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var created = stat()
        try check(lstat(root, &created) == 0 && created.st_mode & S_IFMT == S_IFDIR
            && created.st_uid == geteuid() && created.st_mode & 0o077 == 0,
            "fresh fixture identity unavailable")
        let registry = try RuntimeFixtureCustody(cases: ["fixture"], now: now,
            deadline: now + 10_000_000_000, graceNanoseconds: 200_000_000)
        try registry.beginCase("fixture", now: now)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shadow-sync.runtime-owner.control"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { registry.tick(now: DispatchTime.now().uptimeNanoseconds) }
        timer.resume()
        var failure: Error?
        do { try body(registry, root) } catch { failure = error }
        drain(registry)
        timer.cancel()
        // Cleanup cannot follow a replaced directory or precede actual reap.
        // Preserve the body failure if cleanup itself must be refused.
        var current = stat()
        guard lstat(root, &current) == 0 && current.st_dev == created.st_dev
            && current.st_ino == created.st_ino && current.st_mode & S_IFMT == S_IFDIR
            && current.st_uid == geteuid() && current.st_mode & 0o077 == 0 else {
            throw Failure(message: "fixture cleanup identity refused; body: \(String(describing: failure))")
        }
        do { try FileManager.default.removeItem(atPath: root) }
        catch { throw Failure(message: "fixture cleanup failed: \(error); body: \(String(describing: failure))") }
        if let failure { throw failure }
    }
    private static func barrier(_ name: String, outer: RuntimeFixtureCustody) {
        guard RuntimeFixtureSession.guardianProbeTarget() == name else { return }
        fputs("GUARDIAN PROBE \(name)\n", stdout); fflush(stdout)
        while outer.snapshot().reason == nil { usleep(1_000) }
    }
    private static func proof(_ name: String, outer: RuntimeFixtureCustody,
                              neverResumed: Bool, markerAbsent: Bool) throws {
        guard RuntimeFixtureSession.guardianProbeTarget() == name else { return }
        let snapshot = outer.snapshot()
        try check(snapshot.reason != nil && snapshot.cleanupComplete && snapshot.spawned == snapshot.reaped,
                  "outer cancellation proof before actual original cleanup")
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "shadow-sync-runtime-owner-probe/v1", "case": name,
            "reason": snapshot.reason!.rawValue, "spawned": snapshot.spawned,
            "reaped": snapshot.reaped, "never_resumed": neverResumed, "marker_absent": markerAbsent,
        ], options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("RUNTIME OWNER PROOF ".utf8) + data + Data([10]))
    }
    private enum Mode {
        case asleep, marker, responsive, resistantNested, terminalLeader, immediateExit
        var executable: String { self == .asleep ? "/bin/sleep" : "/bin/bash" }
        func arguments(_ root: String) -> [String] {
            switch self {
            case .asleep: return ["30"]
            case .marker: return ["-c", "echo resumed > \"$1/marker\"; /bin/sleep 30", "fixture", root]
            case .responsive:
                return ["-c", "trap 'exit 0' TERM; echo ready > \"$1/ready\"; while :; do /bin/sleep 1; done", "fixture", root]
            case .resistantNested:
                return ["-c", "trap '' TERM; /bin/sleep 30 & echo $! > \"$1/descendant\"; echo ready > \"$1/ready\"; wait", "fixture", root]
            case .terminalLeader:
                return ["-c", "/bin/sleep 30 & echo $! > \"$1/descendant\"; echo ready > \"$1/ready\"; exit 0", "fixture", root]
            case .immediateExit: return ["-c", "exit 0"]
            }
        }
    }
    private static func spawn(_ registry: RuntimeFixtureCustody, _ root: String,
                              mode: Mode = .asleep, lease: Int32? = nil,
                              beforeRegistration: (() -> Void)? = nil) throws -> OwnedSpawnAnchor {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions) == 0, "fixture file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes) == 0, "fixture spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0, "fixture null streams")
        }
        if let lease {
            try check(posix_spawn_file_actions_adddup2(&actions, lease, 9) == 0, "fixture original lease")
        }
        var defaults = sigset_t(); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var mask = sigset_t(); sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
            && posix_spawnattr_setsigmask(&attributes, &mask) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setflags(&attributes, flags) == 0, "fixture closed spawn attributes")
        let strings = ([mode.executable] + mode.arguments(root)).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try check(strings.allSatisfy { $0 != nil }, "fixture argument allocation")
        var argv = strings + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [nil]
        return try argv.withUnsafeMutableBufferPointer { av in
            try env.withUnsafeMutableBufferPointer { ev in
                try RuntimeFixtureSpawn.spawn(registry: registry, executable: mode.executable,
                    actions: &actions, attributes: &attributes, arguments: av.baseAddress,
                    environment: ev.baseAddress, streamsDrained: { true },
                    beforeRegistration: beforeRegistration)
            }
        }
    }
    private static func transfer(_ anchor: OwnedSpawnAnchor, mode: Mode = .asleep) throws -> OwnedDirectChild {
        try anchor.transfer(expectedExecutable: mode.executable, generation: RunIdentity.make(),
                            reapPolicy: .afterGroupDrain)
    }
    private static func ready(_ root: String) throws {
        try eventually { FileManager.default.fileExists(atPath: root + "/ready") }
    }
    private final class BoolResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        func set(_ value: Bool) { lock.lock(); result = value; lock.unlock() }
        func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return result }
    }
    @discardableResult public static func runAll(onPass: (String) -> Void) throws -> [String] {
        let tests: [(String, () throws -> Void)] = [
            ("runtime-owner-independent-original-drain", {
                try fixture { registry, root in
                    let first = try spawn(registry, root, mode: .marker)
                    let owner = try transfer(first, mode: .marker)
                    first.testingRequestRuntimeDrain()
                    try check(!owner.send(SIGCONT), "normal drain allowed original resume")
                    try eventually { first.testingRuntimeRetired }
                    try check(first.unexecutedProof() != nil && registry.snapshot().reason == nil
                        && !FileManager.default.fileExists(atPath: root + "/marker"), "normal drain executed or cancelled case")
                    let second = try spawn(registry, root, mode: .immediateExit)
                    let next = try transfer(second, mode: .immediateExit)
                    try check(next.send(SIGCONT), "second independent original lost admission")
                    try eventually { next.reapAfterGroupDrain(streamsDrained: true) == .reaped(0) }
                    try eventually { second.testingRuntimeRetired }
                    try check(registry.snapshot().spawned == 2 && registry.snapshot().reaped == 2,
                              "independent originals missing actual reap")
                }
            }),
            ("runtime-owner-injected-failure-original-recovery", {
                try fixture { registry, root in
                    for resume in [false, true] {
                        let anchor = try spawn(registry, root)
                        let owner = try transfer(anchor)
                        if resume { try check(owner.send(SIGCONT), "fixed sleep resume refused") }
                        owner.testingInjectWaitErrors([ECHILD])
                        try check(owner.poll() == .ownershipFailure(ECHILD), "injected failure not observed")
                        let calls = owner.testingWaitSystemCallCount
                        try check(!owner.send(SIGKILL) && !owner.send(SIGCONT)
                            && owner.poll() == .ownershipFailure(ECHILD)
                            && owner.testingWaitSystemCallCount == calls, "poisoned ordinary owner reopened")
                        anchor.testingRequestRuntimeDrain()
                        try eventually { anchor.testingRuntimeRetired }
                        guard case .reaped(let status) = owner.observation else {
                            throw Failure(message: "original injected-error cleanup did not actually reap")
                        }
                        try check(status & 0x7f == SIGKILL, "original injected-error cleanup lost terminal status")
                    }
                    try check(registry.snapshot().reaped == 2 && registry.snapshot().reason == nil,
                              "injected-error cleanup abandoned originals")
                }
            }),
            ("runtime-owner-assertion-unwind-retains-transfer", {
                try fixture { _, root in
                    let outer = try RuntimeFixtureSession.current()
                    var original: OwnedSpawnAnchor?
                    var owner: OwnedDirectChild?
                    var observed = false
                    do {
                        try RuntimeFixtureSession.withNestedAssertionProbe {
                            let inner = try RuntimeFixtureSession.current()
                            let innerOrder = try RuntimeFixtureSession.registrationRegistries(for: inner)
                            let ancestorOrder = try RuntimeFixtureSession.registrationRegistries(for: outer)
                            try check(innerOrder.count == 2 && ancestorOrder.count == 2
                                && innerOrder[0] === outer && innerOrder[1] === inner
                                && ancestorOrder[0] === outer && ancestorOrder[1] === inner,
                                "explicit ancestor inverted nested resume lock order")
                            let unrelated = try RuntimeFixtureCustody(cases: ["ordering"], now: now,
                                deadline: now + 1_000_000_000)
                            let extraOrder = try RuntimeFixtureSession.registrationRegistries(for: unrelated)
                            try check(extraOrder.count == 3 && extraOrder[0] === outer
                                && extraOrder[1] === inner && extraOrder[2] === unrelated,
                                "unrelated registry did not append once after ancestors")
                            let anchor = try spawn(inner, root, mode: .responsive)
                            original = anchor
                            let child = try transfer(anchor, mode: .responsive)
                            owner = child
                            try check(child.send(SIGCONT), "unwind fixture resume refused")
                            try ready(root)
                            barrier("runtime-owner-assertion-unwind-retains-transfer", outer: outer)
                            throw Failure(message: "deliberate assertion unwind")
                        }
                    } catch let failure as Failure {
                        observed = failure.message == "deliberate assertion unwind"
                    }
                    try eventually { original?.testingRuntimeRetired == true }
                    try check(observed && original?.testingRuntimeRetired == true,
                              "assertion unwind lost original transferred custody")
                    guard case .reaped(0) = owner?.observation else {
                        throw Failure(message: "assertion cleanup did not run responsive TERM handler")
                    }
                    let restored = try RuntimeFixtureSession.current()
                    try check(restored === outer, "completed inner assertion failed to restore outer binding")
                    try proof("runtime-owner-assertion-unwind-retains-transfer", outer: outer,
                              neverResumed: original?.unexecutedProof() != nil,
                              markerAbsent: !FileManager.default.fileExists(atPath: root + "/marker"))
                }
            }),
            ("runtime-owner-cancel-before-spawn", {
                try fixture { registry, root in
                    registry.cancel(.callerLost, now: now)
                    var refused = false
                    do { _ = try spawn(registry, root) } catch RuntimeFixtureCustody.Failure.admissionClosed { refused = true }
                    try check(refused && registry.snapshot().spawned == 0 && registry.snapshot().cleanupComplete,
                              "closed admission spawned a child")
                }
            }),
            ("runtime-owner-cancel-crossing-spawn", {
                try fixture { registry, root in
                    let outer = try RuntimeFixtureSession.current()
                    var reservationRetained = false
                    let anchor = try spawn(registry, root, mode: .marker, beforeRegistration: {
                        barrier("runtime-owner-cancel-crossing-spawn", outer: outer)
                        registry.cancel(.callerLost, now: now)
                        reservationRetained = registry.snapshot().reservations == 1 && !registry.snapshot().cleanupComplete
                    })
                    drain(registry)
                    try check(reservationRetained && anchor.unexecutedProof() != nil
                        && registry.snapshot().spawned == 1 && registry.snapshot().reaped == 1,
                        "crossing spawn lost original custody")
                    try check(!FileManager.default.fileExists(atPath: root + "/marker"), "cancelled spawn executed")
                    try eventually { anchor.testingRuntimeRetired }
                    try proof("runtime-owner-cancel-crossing-spawn", outer: outer,
                              neverResumed: anchor.unexecutedProof() != nil,
                              markerAbsent: !FileManager.default.fileExists(atPath: root + "/marker"))
                }
            }),
            ("runtime-owner-transferred-cancel-before-resume", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root, mode: .marker)
                    let owner = try transfer(anchor, mode: .marker)
                    registry.cancel(.callerLost, now: now)
                    try check(!owner.send(SIGCONT), "cancelled transfer resumed")
                    drain(registry)
                    try check(anchor.unexecutedProof() != nil
                        && !FileManager.default.fileExists(atPath: root + "/marker"), "pre-resume cancellation executed code")
                }
            }),
            ("runtime-owner-blocked-resume-independent-cancel", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root, mode: .marker)
                    let owner = try transfer(anchor, mode: .marker)
                    let barrier = OwnedDirectChildTestingBarrier()
                    defer { barrier.release() }
                    owner.testingPauseRuntimeResume(barrier)
                    let result = BoolResult()
                    DispatchQueue(label: "shadow-sync.runtime-owner.resume").async { result.set(owner.send(SIGCONT)) }
                    try check(barrier.waitUntilEntered(), "resume did not enter owned exclusion")
                    let start = now
                    registry.cancel(.callerLost, now: now)
                    try check(now - start < 100_000_000, "cancellation waited for original owner lock")
                    try check(!registry.snapshot().cleanupComplete, "blocked original child disappeared")
                    barrier.release()
                    try eventually { result.get() != nil }
                    try check(result.get() == false, "crossing cancelled resume reached syscall")
                    drain(registry)
                    try check(anchor.unexecutedProof() != nil
                        && !FileManager.default.fileExists(atPath: root + "/marker"), "blocked resume executed")
                }
            }),
            ("runtime-owner-normal-reap-and-no-post-reap-signal", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root, mode: .immediateExit)
                    let owner = try transfer(anchor, mode: .immediateExit)
                    try check(owner.send(SIGCONT), "normal resume refused")
                    try eventually { if case .reaped = owner.reapAfterGroupDrain(streamsDrained: true) { return true }; return false }
                    try check(owner.observation == .reaped(0), "fixed shell did not execute successful exit")
                    try eventually { registry.tick(now: now); return registry.snapshot().cleanupComplete }
                    let calls = owner.testingSignalSystemCallCount
                    try check(!owner.send(SIGTERM) && !owner.send(SIGKILL) && !owner.send(SIGCONT)
                        && owner.testingSignalSystemCallCount == calls, "signal after original reap")
                    try registry.finishCase("fixture", assertionPassed: true, now: now)
                    try registry.finish(now: now)
                    try check(registry.snapshot().succeeded, "complete original child not accounted")
                }
            }),
            ("runtime-owner-responsive-term-drain", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root, mode: .responsive)
                    let owner = try transfer(anchor, mode: .responsive)
                    try check(owner.send(SIGCONT), "responsive resume refused")
                    try ready(root)
                    registry.cancel(.cancelled, now: now)
                    drain(registry)
                    guard case .reaped(let status) = owner.observation else {
                        throw Failure(message: "responsive child not reaped")
                    }
                    try check(status == 0 && registry.snapshot().reaped == 1,
                              "responsive TERM handler did not complete before escalation")
                }
            }),
            ("runtime-owner-resistant-nested-kill-drain", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root, mode: .resistantNested)
                    let owner = try transfer(anchor, mode: .resistantNested)
                    try check(owner.send(SIGCONT), "nested resume refused")
                    try ready(root)
                    guard case .otherMembers = OwnedProcessGroupSnapshot.capture(anchor: anchor.processID) else {
                        throw Failure(message: "nested child was absent")
                    }
                    registry.cancel(.callerLost, now: now)
                    drain(registry)
                    guard case .reaped(let status) = owner.observation else { throw Failure(message: "nested leader not reaped") }
                    try check(status & 0x7f == SIGKILL && registry.snapshot().reaped == 1,
                              "resistant group did not require escalation")
                }
            }),
            ("runtime-owner-terminal-leader-retains-descendant", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root, mode: .terminalLeader)
                    let owner = try transfer(anchor, mode: .terminalLeader)
                    try check(owner.send(SIGCONT), "terminal leader resume refused")
                    try ready(root)
                    try eventually { _ = owner.reapAfterGroupDrain(streamsDrained: true); return owner.terminalStatusHeld != nil }
                    try check(owner.observation == .running && !registry.snapshot().cleanupComplete,
                              "leader released while descendant retained group")
                    drain(registry)
                    try check(registry.snapshot().reaped == 1, "terminal leader drain incomplete")
                }
            }),
            ("runtime-owner-original-lease-until-reap", {
                try fixture { registry, root in
                    let path = root + "/lease"
                    var lease = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                    try check(lease >= 0, "original lease open")
                    defer { if lease >= 0 { close(lease) } }
                    try check(flock(lease, LOCK_EX | LOCK_NB) == 0, "original lease lock")
                    _ = try spawn(registry, root, lease: lease)
                    close(lease); lease = -1
                    let contender = open(path, O_RDWR | O_CLOEXEC)
                    try check(contender >= 0, "contender open")
                    defer { close(contender) }
                    try check(flock(contender, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK,
                              "suspended original failed to retain exact lease")
                    drain(registry)
                    try check(flock(contender, LOCK_EX | LOCK_NB) == 0, "lease held beyond actual child reap")
                }
            }),
            ("runtime-owner-failed-identity-retains-original", {
                try fixture { registry, root in
                    let anchor = try spawn(registry, root)
                    let generation = RunIdentity.make()
                    _ = try ProcessIdentity.capture(processID: anchor.processID, generation: generation,
                                                    expectedExecutablePath: "/bin/sleep")
                    var refused = false
                    do { _ = try anchor.transfer(expectedExecutable: "/bin/sh", generation: generation) }
                    catch ProcessOwnershipError.identityMismatch { refused = true }
                    try check(refused && registry.snapshot().children == 1, "failed identity lost original")
                    drain(registry)
                    try check(anchor.unexecutedProof() != nil && registry.snapshot().reaped == 1,
                              "unvalidated original was not safely reaped")
                }
            })
        ]
        var passed: [String] = []
        for (name, body) in tests { try RuntimeFixtureSession.withCase(name, body); passed.append(name); onPass(name) }
        return passed
    }

    /// Real transport cut points. The executor may cancel or close its control
    /// writer on these bounded readiness lines. Normal execution also runs every
    /// case, so the compiled inventory cannot hide the cancellation fixtures.
    @discardableResult public static func runGuardianProbes(onPass: (String) -> Void) throws -> [String] {
        let names = ["guardian-before-spawn", "guardian-crossing-spawn", "guardian-before-transfer",
                     "guardian-before-resume", "guardian-running-original",
                     "guardian-terminal-leader-live-child", "guardian-original-lease"]
        var completed: [String] = []
        for name in names {
            var root: String?, identity = stat(), failure: Error?
            do {
                try RuntimeFixtureSession.withCase(name) {
                    let registry = try RuntimeFixtureSession.current()
                    let path = try RuntimeFixtureSession.fixturePrefix("shadow-sync-self-tests.") + RunIdentity.make()
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    root = path
                    try check(lstat(path, &identity) == 0 && identity.st_mode & S_IFMT == S_IFDIR
                        && identity.st_uid == geteuid() && identity.st_mode & 0o077 == 0, "guardian fixture root")
                    let target = RuntimeFixtureSession.guardianProbeTarget()
                    func barrier() {
                        fputs("GUARDIAN PROBE \(name)\n", stdout); fflush(stdout)
                        // Explicit selected cuts remain held until the guardian
                        // observes cancellation or its deadline. No timing window
                        // permits the executor to accidentally test a later phase.
                        if target == name {
                            while registry.snapshot().reason == nil { usleep(1_000) }
                        }
                    }
                    func proof(_ safety: String) throws {
                        guard target == name, let reason = registry.snapshot().reason else { return }
                        let snapshot = registry.snapshot()
                        try check(snapshot.cleanupComplete && snapshot.spawned == snapshot.reaped,
                                  "guardian proof before actual cleanup")
                        let data = try JSONSerialization.data(withJSONObject: [
                            "schema": "shadow-sync-runtime-guardian-probe/v1", "case": name,
                            "reason": reason.rawValue, "safety": safety,
                            "spawned": snapshot.spawned, "reaped": snapshot.reaped,
                            "marker_absent": !FileManager.default.fileExists(atPath: path + "/marker"),
                        ], options: [.sortedKeys])
                        FileHandle.standardOutput.write(Data("GUARDIAN PROOF ".utf8) + data + Data([10]))
                    }
                    if name == "guardian-before-spawn" { barrier() }
                    if name == "guardian-before-spawn", registry.snapshot().reason != nil {
                        var refused = false
                        do { let ticket = try registry.reserveSpawn(now: now); try registry.spawnFailed(ticket) }
                        catch RuntimeFixtureCustody.Failure.admissionClosed { refused = true }
                        try check(refused, "cancelled guardian still reserved spawn")
                        try proof("no_spawn"); return
                    }
                    let mode: Mode = name == "guardian-terminal-leader-live-child" ? .terminalLeader
                        : name == "guardian-running-original" ? .responsive : .marker
                    var lease: Int32 = -1
                    if name == "guardian-original-lease" {
                        lease = open(path + "/lease", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                        try check(lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0, "guardian lease acquisition")
                    }
                    defer { if lease >= 0 { close(lease) } }
                    let anchor = try spawn(registry, path, mode: mode, lease: lease < 0 ? nil : lease,
                        beforeRegistration: name == "guardian-crossing-spawn" ? barrier : nil)
                    defer { RuntimeFixtureSession.drain(anchor) }
                    if name == "guardian-before-transfer" { barrier() }
                    if ["guardian-crossing-spawn", "guardian-before-transfer"].contains(name),
                       registry.snapshot().reason != nil {
                        RuntimeFixtureSession.drain(anchor)
                        try check(anchor.unexecutedProof() != nil
                            && !FileManager.default.fileExists(atPath: path + "/marker"),
                            "cancelled original unexpectedly executed")
                        try proof("never_resumed"); return
                    }
                    if name == "guardian-original-lease" {
                        close(lease); lease = -1
                        let contender = open(path + "/lease", O_RDWR | O_CLOEXEC)
                        try check(contender >= 0, "guardian lease contender")
                        defer { close(contender) }
                        try check(flock(contender, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK,
                                  "guardian original lease not held")
                        barrier()
                        RuntimeFixtureSession.drain(anchor)
                        try check(flock(contender, LOCK_EX | LOCK_NB) == 0, "guardian original lease not released after reap")
                        try check(anchor.unexecutedProof() != nil
                            && !FileManager.default.fileExists(atPath: path + "/marker"), "guardian lease child executed")
                        try proof("never_resumed")
                    } else {
                        let owner = try transfer(anchor, mode: mode)
                        if name == "guardian-before-resume" { barrier() }
                        if name == "guardian-before-resume", registry.snapshot().reason != nil {
                            let calls = owner.testingSignalSystemCallCount
                            try check(!owner.send(SIGCONT) && calls == owner.testingSignalSystemCallCount,
                                      "cancelled guardian reached resume syscall")
                            RuntimeFixtureSession.drain(anchor)
                            try check(anchor.unexecutedProof() != nil
                                && !FileManager.default.fileExists(atPath: path + "/marker"), "cancelled original resumed")
                            try proof("never_resumed"); return
                        }
                        try check(owner.send(SIGCONT), "guardian original resume refused")
                        if name == "guardian-terminal-leader-live-child" {
                            try ready(path)
                            try eventually { _ = owner.reapAfterGroupDrain(streamsDrained: true); return owner.terminalStatusHeld != nil }
                            try check(owner.observation == .running && !registry.snapshot().cleanupComplete,
                                      "guardian leader released before descendant")
                            barrier()
                        } else if name == "guardian-running-original" { try ready(path); barrier() }
                        RuntimeFixtureSession.drain(anchor)
                        try proof("drained")
                    }
                }
            } catch { failure = error }
            if let root {
                var current = stat()
                guard lstat(root, &current) == 0 && current.st_dev == identity.st_dev
                    && current.st_ino == identity.st_ino && current.st_uid == geteuid()
                    && current.st_mode & S_IFMT == S_IFDIR && current.st_mode & 0o077 == 0 else {
                    throw Failure(message: "guardian fixture cleanup identity refused")
                }
                try FileManager.default.removeItem(atPath: root)
            }
            if let failure { throw failure }
            completed.append(name); onPass(name)
        }
        return completed
    }
}
#endif
