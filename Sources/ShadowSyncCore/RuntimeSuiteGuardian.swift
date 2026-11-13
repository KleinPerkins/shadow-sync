#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation

/// The suite process retains its own original children. The caller controls
/// admission, never acquires a child's ownership or permission to kill this host.
final class RuntimeSuiteGuardian: @unchecked Sendable {
    typealias Reason = RuntimeFixtureCustody.Reason
    enum Failure: Error { case invalidContract, admissionClosed, incomplete }
    static let controlFD: Int32 = 207
    static let statusFD: Int32 = 208
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    private let lock = NSLock()
    private let ioLock = NSLock()
    private let suite: String, nonce: String
    let deadline: UInt64
    let probeTarget: String?
    private let expected: Set<String>
    private var active: (String, RuntimeFixtureCustody)?
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    private var signedSourceContextClaimed = false
    #endif
    private var passed: Set<String> = []
    private var begun: Set<String> = []
    private var reason: Reason?
    private var started = false, terminal = false, closed = false, outputFailed = false
    private var sequence = 0, totalBytes = 0, spawned = 0, reaped = 0, failedSpawns = 0
    private var pending = Data()
    private var timer: DispatchSourceTimer?

    init(suite: String, cases: [String], nonce: String, deadline: UInt64,
         source: String, executable: String, app: String, probeTarget: String?) throws {
        let now = Self.now
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        let signedSource = ((suite == SignedInstallationFixtureContext.suite && cases == [SignedInstallationFixtureContext.sourceCase])
            || (suite == SignedInstallationFixtureContext.installationSuite && cases.count == 1 && SignedInstallationFixtureCase(rawValue: cases[0]) != nil)) && probeTarget == nil
        #else
        let signedSource = false
        #endif
        guard ["m1", "m3", "practical-m3", "m2", "practical-m2", "m4", "m6", "m6-custody-capture", "runtime-guardian", "runtime-custody", "policy-wire", "policy-binding", "policy-projection", "release-identity", "policy-input", "policy-transport", "closed-runner", "identity-history", "policy-authority", "policy-snapshot", "policy-catalog", "policy-catalog-session", "publisher-policy", "runtime-ownership", "discovery-spawn", "discovery-caller", "discovery-bootstrap", "retention-custody", "body1", "body2", "body3", "body4", "v3-preflight", "v4-preflight", "beta-v02-chooser", "beta-v02-device-drift", "beta-v03", "beta-v04", "beta-v05", "beta-v06", "beta-v07", "beta-v08", "beta-v09"].contains(suite) || signedSource, !cases.isEmpty, cases.count <= 2048,
              Set(cases).count == cases.count,
              cases.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256
                  && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }),
              Self.hex(nonce, count: 32), [source, executable, app].allSatisfy({ Self.hex($0, count: 64) }),
              probeTarget == nil || (["runtime-guardian", "closed-runner", "runtime-ownership", "discovery-spawn"].contains(suite) && cases.contains(probeTarget!)),
              deadline > now, deadline - now <= 3_600_000_000_000 else { throw Failure.invalidContract }
        self.suite = suite; self.nonce = nonce; self.deadline = deadline; expected = Set(cases)
        self.probeTarget = probeTarget
        try Self.validateChannels()
        emitLocked("ready", ["expected_cases": cases.count, "source_sha256": source,
            "executable_sha256": executable, "app_sha256": app, "probe": probeTarget ?? "none"])
    }

    static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validateChannels() throws {
        var identities: [(dev_t, ino_t)] = []
        var channelHandles: Set<UInt64> = []
        func pipeHandles(_ fd: Int32) throws -> Set<UInt64> {
            var info = pipe_fdinfo()
            guard proc_pidfdinfo(getpid(), fd, PROC_PIDFDPIPEINFO, &info,
                                Int32(MemoryLayout<pipe_fdinfo>.size)) == MemoryLayout<pipe_fdinfo>.size,
                  info.pipeinfo.pipe_handle != 0 else { throw Failure.invalidContract }
            // Darwin's opposite pipe endpoints have different stat inode values.
            // Compare both actual endpoint handles; a duplicate opposite end can
            // otherwise conceal EOF even though its inode differs.
            return Set([info.pipeinfo.pipe_handle, info.pipeinfo.pipe_peerhandle].filter { $0 != 0 })
        }
        for (fd, access) in [(controlFD, O_RDONLY), (statusFD, O_WRONLY)] {
            var info = stat()
            let flags = fcntl(fd, F_GETFL), descriptor = fcntl(fd, F_GETFD)
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
                  info.st_uid == geteuid(), flags >= 0, flags & O_ACCMODE == access,
                  descriptor >= 0,
                  !identities.contains(where: { $0.0 == info.st_dev && $0.1 == info.st_ino }) else {
                throw Failure.invalidContract
            }
            let handles = try pipeHandles(fd)
            guard handles.count == 2, handles.isDisjoint(with: channelHandles) else { throw Failure.invalidContract }
            channelHandles.formUnion(handles)
            for standard: Int32 in 0...2 {
                var other = stat()
                if fstat(standard, &other) == 0, other.st_dev == info.st_dev, other.st_ino == info.st_ino {
                    throw Failure.invalidContract
                }
            }
            identities.append((info.st_dev, info.st_ino))
            guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) == 0 else { throw Failure.invalidContract }
        }
        // A duplicate control writer hides caller EOF; a duplicate status reader
        // hides peer loss. Validate the entire inherited descriptor table, not
        // only stdio. No other thread receives either channel before this check.
        let stride = MemoryLayout<proc_fdinfo>.stride
        let required = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard required > 0, required <= 65_536 * stride else { throw Failure.invalidContract }
        var rows = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / stride + 64)
        let capacity = rows.count * stride
        let count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &rows, Int32(capacity))
        guard count > 0, count < capacity, Int(count) % stride == 0 else { throw Failure.invalidContract }
        for row in rows.prefix(Int(count) / stride) where row.proc_fd != controlFD && row.proc_fd != statusFD {
            var info = stat()
            if fstat(row.proc_fd, &info) == 0 {
                if identities.contains(where: { $0.0 == info.st_dev && $0.1 == info.st_ino }) {
                    throw Failure.invalidContract
                }
                if info.st_mode & S_IFMT == S_IFIFO,
                   !(try pipeHandles(row.proc_fd)).isDisjoint(with: channelHandles) { throw Failure.invalidContract }
            }
        }
        guard fcntl(statusFD, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.invalidContract }
    }

    /// Hash the already-built artifacts without following aliases. The executor
    /// binds these digests to its source receipt; a supplied source digest alone
    /// is never evidence that a binary was built from those sources.
    static func verifyExecutable(_ path: String, digest: String) throws {
        guard path.hasPrefix("/"), Self.hex(digest, count: 64),
              let resolved = realpath(path, nil) else { throw Failure.invalidContract }
        defer { free(resolved) }
        guard String(cString: resolved) == path else { throw Failure.invalidContract }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalidContract }
        defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_mode & 0o022 == 0,
              before.st_mode & 0o111 != 0, before.st_size > 0,
              before.st_size <= 268_435_456 else { throw Failure.invalidContract }
        var hash = SHA256(), bytes = [UInt8](repeating: 0, count: 65_536), total: Int64 = 0
        while true {
            let n = read(fd, &bytes, bytes.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Failure.invalidContract }
            if n == 0 { break }
            total += Int64(n)
            guard total <= before.st_size else { throw Failure.invalidContract }
            hash.update(data: Data(bytes.prefix(n)))
        }
        guard fstat(fd, &after) == 0, lstat(path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_size == total, after.st_size == total,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw Failure.invalidContract
        }
    }

    private func emitLocked(_ event: String, _ fields: [String: Any] = [:]) {
        guard !outputFailed else { return }
        var record = fields
        record.merge(["schema": "shadow-sync-runtime-guardian/v1", "suite": suite,
                      "nonce": nonce, "sequence": sequence, "event": event]) { _, new in new }
        guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              encoded.count < 2048, pending.count + encoded.count + 1 <= 262_144,
              totalBytes + encoded.count + 1 <= 4_194_304 else {
            outputFailed = true; cancelLocked(.transport); return
        }
        pending.append(encoded); pending.append(10)
        sequence += 1; totalBytes += encoded.count + 1
    }
    private func cancelLocked(_ cause: Reason) {
        guard !terminal, reason == nil else { return }
        // This registry operation takes only its bounded admission mutex; it
        // never waits on owners or invokes drain callbacks. Close spawn/resume
        // admission before publishing the suite cancellation linearization.
        active?.1.cancel(cause, now: Self.now)
        reason = cause; emitLocked("cancelled", ["reason": cause.rawValue])
    }
    func cancel(_ cause: Reason) {
        lock.lock(); cancelLocked(cause); lock.unlock()
    }
    private func expireLocked() { if Self.now >= deadline { cancelLocked(.deadline) } }

    func beginCase(_ id: String, registry: RuntimeFixtureCustody) throws {
        tick()
        lock.lock(); defer { lock.unlock() }; expireLocked()
        guard started, reason == nil, !terminal else { throw Failure.admissionClosed }
        guard active == nil, expected.contains(id), begun.insert(id).inserted else {
            cancelLocked(.assertion); throw Failure.invalidContract
        }
        active = (id, registry); emitLocked("case_start", ["case": id])
        if let reason { registry.cancel(reason, now: Self.now) }
    }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    func claimSignedSourceContext(registry: RuntimeFixtureCustody, caseID: String) throws {
        lock.lock(); defer { lock.unlock() }; expireLocked()
        guard started, reason == nil, !terminal, !signedSourceContextClaimed,
              [SignedInstallationFixtureContext.suite, SignedInstallationFixtureContext.installationSuite].contains(suite),
              SignedInstallationFixtureContext.cases.contains(caseID), active?.0 == caseID,
              active?.1 === registry else { throw Failure.admissionClosed }
        signedSourceContextClaimed = true
    }
    func requireActiveCase(_ id: String, registry: RuntimeFixtureCustody) throws {
        lock.lock(); defer { lock.unlock() }; expireLocked()
        guard started, reason == nil, !terminal, active?.0 == id, active?.1 === registry else {
            throw Failure.admissionClosed
        }
    }
    #endif
    func requireAdmission() throws {
        lock.lock(); defer { lock.unlock() }; expireLocked()
        guard started, reason == nil, !terminal else { throw Failure.admissionClosed }
    }
    func completeCase(_ id: String, snapshot: RuntimeFixtureCustody.Snapshot, success: Bool) throws {
        tick()
        lock.lock(); defer { lock.unlock() }; expireLocked()
        guard active?.0 == id, snapshot.cleanupComplete, snapshot.spawned == snapshot.reaped else {
            cancelLocked(.assertion); throw Failure.incomplete
        }
        spawned += snapshot.spawned; reaped += snapshot.reaped; failedSpawns += snapshot.failedSpawns
        active = nil
        if !success || !snapshot.succeeded { cancelLocked(snapshot.reason ?? .assertion) }
        let accepted = reason == nil && success && snapshot.succeeded
        if accepted { passed.insert(id) }
        emitLocked(accepted ? "case_pass" : "case_failed", ["case": id,
            "spawned": snapshot.spawned, "reaped": snapshot.reaped,
            "failed_spawns": snapshot.failedSpawns, "reservations": snapshot.reservations,
            "children": snapshot.children, "callbacks": snapshot.callbacks])
        if !accepted { throw Failure.admissionClosed }
    }

    // Only this serial control loop performs descriptor I/O. Neither assertion
    // bodies nor child owner callbacks execute on it or under the model mutex.
    private func tick() {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 64)
        let n = read(Self.controlFD, &bytes, bytes.count)
        let readError = errno
        var status = pollfd(fd: Self.statusFD, events: Int16(POLLOUT), revents: 0)
        let peer = poll(&status, 1, 0)
        lock.lock()
        if !terminal {
            expireLocked()
            if peer > 0 && status.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                outputFailed = true; cancelLocked(.transport)
            }
            if n == 0 { cancelLocked(.callerLost) }
            else if n < 0 {
                if readError != EAGAIN && readError != EINTR { cancelLocked(.transport) }
            } else {
                for byte in bytes.prefix(n) {
                    if byte == 82 && !started && reason == nil { started = true }
                    else if byte == 67 { cancelLocked(.cancelled) }
                    else { cancelLocked(.transport) }
                }
            }
        }
        let chunk = pending.prefix(16_384)
        lock.unlock()
        if !chunk.isEmpty {
            let written = chunk.withUnsafeBytes { write(Self.statusFD, $0.baseAddress, $0.count) }
            let error = errno
            lock.lock()
            if written > 0 { pending.removeFirst(written) }
            else if written == 0 || (error != EAGAIN && error != EINTR) {
                outputFailed = true; cancelLocked(.transport)
            }
            lock.unlock()
        }
    }

    func execute(_ body: () throws -> Bool) -> Int32 {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shadow-sync.runtime-guardian.control"))
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { self.tick() }; timer.resume()
        while true {
            lock.lock(); let waiting = !started && reason == nil; lock.unlock()
            if !waiting { break }; Thread.sleep(forTimeInterval: 0.005)
        }
        var success = false
        do { try requireAdmission(); success = try body() } catch { cancel(.assertion) }
        tick()
        lock.lock(); expireLocked()
        if !success || active != nil || passed != expected { cancelLocked(.assertion) }
        // A case cannot return while it retains original children. If a caller
        // violates that contract, retain this guardian; never manufacture reap.
        while active != nil {
            lock.unlock(); Thread.sleep(forTimeInterval: 0.01); lock.lock()
        }
        let complete = reason == nil && success && passed == expected && spawned == reaped
        terminal = true
        emitLocked("terminal", ["outcome": complete ? "passed" : "failed",
            "reason": reason?.rawValue ?? "none", "expected_cases": expected.count,
            "begun_cases": begun.count, "passed_cases": passed.count,
            "spawned": spawned, "reaped": reaped, "failed_spawns": failedSpawns,
            "reservations": 0, "children": 0, "callbacks": 0])
        lock.unlock()
        // This bound applies only after every original child has been reaped.
        let flushUntil = Self.now + 2_000_000_000
        while Self.now < flushUntil {
            lock.lock(); let done = pending.isEmpty || outputFailed; lock.unlock()
            if done { break }; Thread.sleep(forTimeInterval: 0.005)
        }
        timer.cancel()
        ioLock.lock(); closed = true; close(Self.controlFD); close(Self.statusFD); ioLock.unlock()
        self.timer = nil
        lock.lock(); let flushed = pending.isEmpty && !outputFailed; lock.unlock()
        return complete && flushed ? 0 : 1
    }
}

/// Closed test-only entry. The compiled caller supplies the registered case
/// inventory and one suite function; arguments cannot name a script or command.
public enum RuntimeSuiteGuardianEntrypoint {
    public static func dispatch(_ arguments: [String], catalog: [String: [String]],
                                run: (String, String) throws -> Bool) -> Int32? {
        guard arguments.dropFirst().contains("--shadow-sync-runtime-guardian") else { return nil }
        do {
            guard arguments.count == 10, arguments[1] == "--shadow-sync-runtime-guardian",
                  ["m1", "m3", "practical-m3", "m2", "practical-m2", "m4", "m6", "m6-custody-capture", "runtime-guardian", "runtime-custody", "policy-wire", "policy-binding", "policy-projection", "release-identity", "policy-input", "policy-transport", "closed-runner", "identity-history", "policy-authority", "policy-snapshot", "policy-catalog", "policy-catalog-session", "publisher-policy", "runtime-ownership", "discovery-spawn", "discovery-caller", "discovery-bootstrap", "retention-custody", "body1", "body2", "body3", "body4", "v3-preflight", "v4-preflight", "beta-v02-chooser", "beta-v02-device-drift", "beta-v03", "beta-v04", "beta-v05", "beta-v06", "beta-v07", "beta-v08", "beta-v09"].contains(arguments[2]), let cases = catalog[arguments[2]],
                  let deadline = UInt64(arguments[5]), String(deadline) == arguments[5],
                  ProcessInfo.processInfo.environment["SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE"] == arguments[4] else {
                throw RuntimeSuiteGuardian.Failure.invalidContract
            }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
            guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else {
                throw RuntimeSuiteGuardian.Failure.invalidContract
            }
            let ownPath = String(cString: buffer)
            try RuntimeSuiteGuardian.verifyExecutable(ownPath, digest: arguments[7])
            try RuntimeSuiteGuardian.verifyExecutable(arguments[3], digest: arguments[8])
            let guardian = try RuntimeSuiteGuardian(suite: arguments[2], cases: cases,
                nonce: arguments[4], deadline: deadline, source: arguments[6],
                executable: arguments[7], app: arguments[8],
                probeTarget: arguments[9] == "none" ? nil : arguments[9])
            try RuntimeFixtureSession.installGuardian(guardian)
            defer { RuntimeFixtureSession.removeGuardian(guardian) }
            return guardian.execute { try run(arguments[2], arguments[3]) }
        } catch { return 64 }
    }
}
#endif
