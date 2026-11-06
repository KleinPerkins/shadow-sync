#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import ShadowSyncCore

// Fixed test child: no application lifecycle, repository access or arbitrary command.
enum NativeFixtureChild {
    static let route = "--shadow-sync-native-fixture-child"
    // No other reaper may own this newly spawned direct child. Holding that
    // unreaped relationship excludes PID reuse, including partial exec failures.
    static func reapFailedSpawn(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        var waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { return true }
        guard waited == 0 else { return false }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_pid == UInt32(pid), info.pbi_ppid == UInt32(getpid()), info.pbi_uid == getuid() else { return false }
        _ = kill(pid, SIGKILL)
        let deadline = MonotonicDeadline(seconds: 2)
        repeat {
            waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return true }
            if waited < 0 && errno != EINTR { return false }
            usleep(10_000)
        } while !deadline.hasExpired
        return false
    }

    static func isolationCanary() -> Int32 {
        guard let account = getpwuid(getuid()), let path = account.pointee.pw_dir else { return 70 }
        let homeFD = open(path, O_RDONLY | O_DIRECTORY)
        let homeDenied = homeFD < 0 && errno == EPERM
        if homeFD >= 0 { Darwin.close(homeFD) }
        let temporary = "/private/tmp/shadow-sync-denial-" + UUID().uuidString
        let outsideFD = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        let writesDenied = outsideFD < 0 && errno == EPERM
        if outsideFD >= 0 { Darwin.close(outsideFD); unlink(temporary) }
        let networkFD = socket(AF_INET, SOCK_STREAM, 0)
        var networkDenied = networkFD < 0 && errno == EPERM
        if networkFD >= 0 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(networkFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            networkDenied = result < 0 && errno == EPERM
            Darwin.close(networkFD)
        }
        let pointer = strdup("/usr/bin/true")
        defer { free(pointer) }
        var argv = [pointer, nil]
        var pid: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, "/usr/bin/true", nil, nil, $0.baseAddress, environ)
        }
        if code == 0 { _ = reapFailedSpawn(pid) }
        guard homeDenied, writesDenied, networkDenied, code == EPERM else { return 70 }
        FileHandle.standardOutput.write(Data("{\"home_denied\":true,\"network_denied\":true,\"outside_writes_denied\":true,\"exec_denied\":true}\n".utf8))
        return 0
    }

    static func dispatch(_ arguments: [String]) -> Int32? {
        if arguments.count == 3, arguments[1] == "--shadow-sync-native-fixture-owner-channel",
           let descriptor = Int32(arguments[2]), descriptor > 2 {
            return NativeFixtureProcess.qualifyOwner(descriptor: descriptor)
        }
        if arguments.count == 2, arguments[1] == "--shadow-sync-native-fixture-isolation" {
            return isolationCanary()
        }
        guard arguments.count > 1, arguments[1] == route else { return nil }
        guard arguments.count == 6,
              ["ignore-term", "default-term"].contains(arguments[2]),
              let lease = Int32(arguments[3]), let ready = Int32(arguments[4]),
              lease > 2, ready > 2, lease != ready,
              let lifetime = Int(arguments[5]), (1...30).contains(lifetime),
              getpgrp() == getpid() else { return 64 }
        for descriptor in [lease, ready] {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFIFO else { return 64 }
        }
        guard fcntl(lease, F_GETFL) & O_ACCMODE == O_RDONLY,
              fcntl(ready, F_GETFL) & O_ACCMODE == O_WRONLY else { return 64 }
        guard getuid() != 0, geteuid() != 0 else { return 65 }
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        var observed = rlimit()
        guard setrlimit(RLIMIT_NPROC, &limit) == 0,
              getrlimit(RLIMIT_NPROC, &observed) == 0,
              observed.rlim_cur == 0, observed.rlim_max == 0 else { return 65 }
        var raised = rlimit(rlim_cur: 1, rlim_max: 1)
        guard setrlimit(RLIMIT_NPROC, &raised) == -1, errno == EPERM,
              getrlimit(RLIMIT_NPROC, &observed) == 0,
              observed.rlim_cur == 0, observed.rlim_max == 0 else { return 65 }
        signal(SIGTERM, arguments[2] == "ignore-term" ? SIG_IGN : SIG_DFL)
        // Same allowed executable, malformed closed-helper invocation. If the
        // process limit fails, the child exits before lifecycle or another spawn.
        let values = [arguments[0], route]
        let pointers = values.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        var child: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&child, arguments[0], nil, nil, $0.baseAddress, environ)
        }
        if code == 0 {
            _ = reapFailedSpawn(child)
            return 65
        }
        guard code == EAGAIN else { return 65 }
        // Swift deliberately omits fork from ordinary application APIs. This
        // isolated negative canary calls the fixed system C symbol only after
        // reading back a zero hard limit. An unexpected child immediately exits
        // through the async-signal-safe C entrypoint; it cannot enter Swift work.
        guard let system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL) else { return 65 }
        defer { dlclose(system) }
        guard let symbol = dlsym(system, "fork") else { return 65 }
        let forkCanary = unsafeBitCast(symbol, to: (@convention(c) () -> pid_t).self)
        let forked = forkCanary()
        if forked == 0 { _exit(65) }
        if forked > 0 { _ = reapFailedSpawn(forked); return 65 }
        guard forked == -1, errno == EAGAIN else { return 65 }
        var byte: UInt8 = 1
        guard Darwin.write(ready, &byte, 1) == 1 else { return 66 }
        Darwin.close(ready)
        let deadline = MonotonicDeadline(seconds: Double(lifetime))
        while !deadline.hasExpired {
            var item = pollfd(fd: lease, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&item, 1, 50)
            if result < 0 { if errno == EINTR { continue }; return 67 }
            if result > 0 {
                if item.revents & Int16(POLLNVAL | POLLERR) != 0 { return 67 }
                let count = Darwin.read(lease, &byte, 1)
                if count == 0 { return 0 }
                if count < 0 && errno == EINTR { continue }
                return 67 // Only EOF is valid on the parent-liveness channel.
            }
        }
        return 0
    }
}

final class NativeFixtureProcess: @unchecked Sendable {
    enum Behavior: String { case ignoreTerm = "ignore-term", defaultTerm = "default-term" }
    private struct Event: Encodable {
        let schema = "shadow-sync-native-fixture/v1"
        let event: String
        let role: String
        let identity: ProcessIdentity
        let status: Int32?
    }
    let processID: pid_t
    let identity: ProcessIdentity
    let owner: OwnedDirectChild
    private let lock = NSLock()
    private var lease: Int32
    private var status: Int32?
    private var evidenceValid = true
    private let journal: Int32
    private let role: String

    private static func awaitReadiness(_ descriptor: Int32, seconds: Double) -> Bool {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let deadline = MonotonicDeadline(seconds: seconds)
        while !deadline.hasExpired {
            let result = poll(&item, 1, 20)
            if result < 0 && errno == EINTR { continue }
            if result > 0 {
                var byte: UInt8 = 0
                return Darwin.read(descriptor, &byte, 1) == 1 && byte == 1
            }
            if result < 0 { return false }
        }
        return false
    }

    static func qualifyOwner(descriptor: Int32) -> Int32 {
        struct Request: Decodable { let schema: String; let testRoot: String }
        do {
            let request = try JSONLineChannel.readOne(Request.self, descriptor: descriptor)
            guard request.schema == "shadow-sync-native-fixture-owner/v1" else { return 64 }
            let root = try TestIsolation.validateRoot(request.testRoot)
            let readiness = try pipePair()
            defer { readiness.forEach { Darwin.close($0) } }
            let timeout = !awaitReadiness(readiness[0], seconds: 0.02)
            var byte: UInt8 = 2
            guard Darwin.write(readiness[1], &byte, 1) == 1 else { return 1 }
            let malformed = !awaitReadiness(readiness[0], seconds: 0.02)
            byte = 1
            guard Darwin.write(readiness[1], &byte, 1) == 1 else { return 1 }
            let ready = awaitReadiness(readiness[0], seconds: 0.02)
            var parentLimit = rlimit()
            guard getrlimit(RLIMIT_NPROC, &parentLimit) == 0 else { return 1 }
            let first = try NativeFixtureProcess(root: root, role: "worker-stop", behavior: .ignoreTerm)
            defer { first.close() }
            let second = try NativeFixtureProcess(root: root, role: "takeover", behavior: .defaultTerm)
            defer { second.close() }
            let closed = first.close() && first.wait(seconds: 0) == 0
            let unrelatedAlive = second.identity.isCurrent()
            let noSignalAfterReap = !first.send(SIGKILL)
            let secondClosed = second.close() && second.wait(seconds: 0) == 0
            var afterLimit = rlimit()
            let parentUnchanged = getrlimit(RLIMIT_NPROC, &afterLimit) == 0
                && parentLimit.rlim_cur == afterLimit.rlim_cur && parentLimit.rlim_max == afterLimit.rlim_max
            let result = ["parentProcessLimitPreserved": parentUnchanged, "readinessTimeout": timeout, "malformedReadiness": malformed,
                          "validReadiness": ready, "leaseEOFReaped": closed,
                          "otherLeaseNotInherited": unrelatedAlive,
                          "signalAfterReapRefused": noSignalAfterReap, "secondChildReaped": secondClosed]
            try JSONLineChannel.write(result, descriptor: descriptor)
            return result.values.allSatisfy { $0 } ? 0 : 1
        } catch { return 1 }
    }

    private static func pipePair() throws -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw ProcessOwnershipError.unavailable("fixture pipe") }
        defer { pair.forEach { Darwin.close($0) } }
        let readEnd = fcntl(pair[0], F_DUPFD_CLOEXEC, 10)
        let writeEnd = fcntl(pair[1], F_DUPFD_CLOEXEC, 10)
        guard readEnd >= 10, writeEnd >= 10 else {
            if readEnd >= 0 { Darwin.close(readEnd) }
            if writeEnd >= 0 { Darwin.close(writeEnd) }
            throw ProcessOwnershipError.unavailable("fixture descriptor isolation")
        }
        return [readEnd, writeEnd]
    }

    init(root: String, role: String, behavior: Behavior) throws {
        let root = try TestIsolation.validateRoot(root)
        guard ["worker-stop", "takeover", "owner-ordering", "owner-custody-loss"].contains(role) else {
            throw ProcessOwnershipError.invalidRegistration
        }
        self.role = role
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ProcessOwnershipError.unsafeSocket }
        defer { Darwin.close(rootFD) }
        let journalFD = openat(rootFD, "native-fixture.jsonl", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard journalFD >= 0 else { throw ProcessOwnershipError.unsafeSocket }
        var succeeded = false
        defer { if !succeeded { Darwin.close(journalFD) } }
        var info = stat()
        guard fstat(journalFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, info.st_size <= 32768 else {
            throw ProcessOwnershipError.unsafeSocket
        }
        journal = journalFD
        let liveness = try Self.pipePair()
        defer { Darwin.close(liveness[0]); if !succeeded { Darwin.close(liveness[1]) } }
        let readiness = try Self.pipePair()
        defer { readiness.forEach { Darwin.close($0) } }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProcessOwnershipError.invalidRegistration }
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProcessOwnershipError.invalidRegistration }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, liveness[0], 3) == 0,
              posix_spawn_file_actions_adddup2(&actions, readiness[1], 4) == 0 else {
            throw ProcessOwnershipError.invalidRegistration
        }
        for fd: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_addinherit_np(&actions, fd) == 0 else {
                throw ProcessOwnershipError.invalidRegistration
            }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let values = [executable, NativeFixtureChild.route, behavior.rawValue, "3", "4", "30"]
        let pointers = values.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        var pid: pid_t = 0
        let code = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, values[0], &actions, &attributes, $0.baseAddress, environ)
        }
        guard code == 0 else { throw ProcessOwnershipError.unavailable("fixture spawn") }
        processID = pid
        // Until this initializer succeeds there is no other reaper; the unreaped
        // direct child cannot be PID-reused, including failed/partial exec.
        var adoptedOwner: OwnedDirectChild?
        defer {
            if !succeeded {
                if let adoptedOwner {
                    _ = adoptedOwner.send(SIGKILL)
                    _ = try? adoptedOwner.wait(timeout: 2)
                } else {
                    _ = NativeFixtureChild.reapFailedSpawn(pid)
                }
            }
        }
        guard Self.awaitReadiness(readiness[0], seconds: 2) else { throw ProcessOwnershipError.unavailable("fixture readiness") }
        identity = try ProcessIdentity.capture(processID: pid, generation: RunIdentity.make(), expectedExecutablePath: executable)
        owner = try OwnedDirectChild(adoptingSpawnedChild: pid, identity: identity)
        adoptedOwner = owner
        lease = liveness[1]
        try append("spawn", status: nil)
        succeeded = true
    }

    private func append(_ event: String, status: Int32?) throws {
        guard flock(journal, LOCK_EX | LOCK_NB) == 0 else { throw ProcessOwnershipError.invalidRegistration }
        defer { flock(journal, LOCK_UN) }
        var info = stat()
        guard fstat(journal, &info) == 0, info.st_size <= 32768 else { throw ProcessOwnershipError.invalidRegistration }
        var bytes = try JSONEncoder().encode(Event(event: event, role: role, identity: identity, status: status))
        bytes.append(10)
        guard bytes.count < 4096 else { throw ProcessOwnershipError.invalidRegistration }
        let written = bytes.withUnsafeBytes { Darwin.write(journal, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(journal) == 0 else { throw ProcessOwnershipError.invalidRegistration }
    }

    // Journal writes are serialized here; the shared owner serializes reap and signal.
    func wait(seconds: Double) -> Int32? {
        let deadline = MonotonicDeadline(seconds: seconds)
        repeat {
            lock.lock()
            if status == nil {
                switch owner.poll() {
                case let .reaped(result):
                    status = result
                    do { try append("reap", status: result) } catch { evidenceValid = false }
                case .ownershipFailure: evidenceValid = false
                case .running: break
                }
            }
            let result = evidenceValid ? status : nil
            lock.unlock()
            if let result { return result }
            usleep(10_000)
        } while !deadline.hasExpired
        return nil
    }

    func send(_ signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard status == nil, evidenceValid, signal == SIGTERM || signal == SIGKILL else { return false }
        return owner.send(signal)
    }

    // Deliberately violate the owner contract without sending any signal. The
    // exact terminal direct child is reaped here to test ECHILD refusal. This is
    // never used by a normal fixture or production reader.
    func testingReapOutsideOwner() -> Int32? {
        releaseLease()
        let deadline = MonotonicDeadline(seconds: 2)
        repeat {
            lock.lock()
            var value: Int32 = -1
            let waited = waitpid(processID, &value, WNOHANG)
            if waited == processID {
                status = value
                do { try append("reap", status: value) } catch { evidenceValid = false }
            }
            let result = evidenceValid ? status : nil
            lock.unlock()
            if let result { return result }
            if waited < 0 && errno != EINTR { return nil }
            usleep(10_000)
        } while !deadline.hasExpired
        return nil
    }

    func releaseLease() {
        lock.lock()
        if lease >= 0 { Darwin.close(lease); lease = -1 }
        lock.unlock()
    }

    @discardableResult func close() -> Bool {
        releaseLease()
        if wait(seconds: 1) != nil { return true }
        _ = send(SIGKILL)
        return wait(seconds: 2) != nil
    }

    deinit { _ = close(); Darwin.close(journal) }
}

/// Exercises WorkerSession stopping and WorkerClient's actual terminal reader.
/// Synthetic direct children only; no repository or installed-state access.
enum WorkerOwnerOrderingFixtures {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var exits: [Int32] = []
        private var failures = 0
        private var reapedEvidence = false
        func exit(_ status: Int32, _ evidence: WorkerPostReapEvidence) {
            lock.lock(); defer { lock.unlock() }
            exits.append(status); reapedEvidence = evidence.workerReaped
        }
        func failed() { lock.lock(); failures += 1; lock.unlock() }
        var snapshot: (exits: [Int32], failures: Int, reaped: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (exits, failures, reapedEvidence)
        }
    }

    private static func terminalWithoutReap(_ pid: pid_t) throws -> Bool {
        var info = siginfo_t()
        let value = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if value < 0 {
            if errno == EINTR { return false }
            throw ProcessOwnershipError.unavailable("worker lost unreaped child custody: errno=\(errno)")
        }
        if info.si_pid == 0 { return false }
        guard info.si_pid == pid, info.si_code == CLD_EXITED, info.si_status == 0 else {
            throw ProcessOwnershipError.unavailable("unexpected worker fixture terminal status")
        }
        return true
    }

    static func signalReapOrdering(root: String) -> Bool {
        do {
            let fixture = try NativeFixtureProcess(root: root, role: "owner-ordering", behavior: .defaultTerm)
            defer { fixture.close() }
            var control: [Int32] = [-1, -1]
            guard pipe(&control) == 0 else { return false }
            defer { Darwin.close(control[0]) }
            let session = WorkerSession(owner: fixture.owner, controlWrite: control[1])
            let signal = OwnedDirectChildTestingBarrier(pauseTimeout: 18)
            let reap = OwnedDirectChildTestingBarrier(pauseTimeout: 18)
            let pollAttempt = OwnedDirectChildTestingPollAttempt()
            fixture.owner.testingPauseNextSignal(signal)
            fixture.owner.testingPauseNextReap(reap)
            let threads = DispatchGroup()
            defer {
                signal.release(); reap.release()
                // Barriers and the fixed child are bounded; join before fixture teardown.
                guard threads.wait(timeout: .now() + 30) == .success else {
                    FileHandle.standardError.write(Data("worker fixture thread join failed\n".utf8))
                    // Stop this test process; the outer harness must establish
                    // helper absence and cannot accept this as successful cleanup.
                    _exit(70)
                }
            }
            let results = ResultBox()
            threads.enter()
            Thread.detachNewThread {
                WorkerClient.finishReadingWorker(session: session,
                    onOwnershipFailure: { results.failed() },
                    onExit: { results.exit($0, $1) })
                threads.leave()
            }
            guard reap.waitUntilEntered() else { return false }
            threads.enter()
            Thread.detachNewThread {
                _ = session.stopSafely(cooperativeTimeout: 0, termTimeout: 12, killTimeout: 1)
                threads.leave()
            }
            guard signal.waitUntilEntered() else { return false }
            fixture.releaseLease()
            let terminalDeadline = MonotonicDeadline(seconds: 12)
            var terminal = try terminalWithoutReap(fixture.processID)
            while !terminal, !terminalDeadline.hasExpired {
                usleep(10_000)
                terminal = try terminalWithoutReap(fixture.processID)
            }
            guard terminal else { return false }
            fixture.owner.testingObserveNextPoll(pollAttempt)
            reap.release()
            guard pollAttempt.waitUntilContended(),
                  try terminalWithoutReap(fixture.processID), results.snapshot.exits.isEmpty else { return false }
            signal.release()
            guard threads.wait(timeout: .now() + 5) == .success,
                  fixture.owner.observation == .reaped(0), fixture.wait(seconds: 0) == 0,
                  session.waitForExit(timeout: 0) == 0 else { return false }
            // Repeated reader completion must preserve the one callback/status.
            WorkerClient.finishReadingWorker(session: session,
                onOwnershipFailure: { results.failed() }, onExit: { results.exit($0, $1) })
            let observed = results.snapshot
            let signals = fixture.owner.testingSignalSystemCallCount
            guard !fixture.owner.send(SIGKILL), signals == 1,
                  fixture.owner.testingSignalSystemCallCount == signals,
                  observed.exits == [0], observed.failures == 0, observed.reaped else { return false }
            var status: Int32 = -1
            return waitpid(fixture.processID, &status, WNOHANG) == -1 && errno == ECHILD
        } catch {
            FileHandle.standardError.write(Data("worker ownership ordering: \(error)\n".utf8))
            return false
        }
    }

    static func failedCustody(root: String) -> Bool {
        do {
            let fixture = try NativeFixtureProcess(root: root, role: "owner-custody-loss", behavior: .defaultTerm)
            defer { fixture.close() }
            var control: [Int32] = [-1, -1]
            guard pipe(&control) == 0 else { return false }
            defer { Darwin.close(control[0]) }
            let session = WorkerSession(owner: fixture.owner, controlWrite: control[1])
            guard !session.markExited(0, childDrainVerified: true),
                  fixture.testingReapOutsideOwner() == 0 else { return false }
            let results = ResultBox()
            for _ in 0..<2 {
                WorkerClient.finishReadingWorker(session: session,
                    onOwnershipFailure: { results.failed() }, onExit: { results.exit($0, $1) })
            }
            let observed = results.snapshot
            return fixture.owner.observation == .ownershipFailure(ECHILD)
                && observed.exits.isEmpty && observed.failures == 1
                && session.waitForExit(timeout: 0) == nil
                && !session.markExited(0, childDrainVerified: true)
                && session.stopSafely(cooperativeTimeout: 0, termTimeout: 0, killTimeout: 0) == .unverified
                && !fixture.owner.send(SIGTERM) && fixture.owner.testingSignalSystemCallCount == 0
                && !session.verifySafetyAfterWorkerReap().workerReaped
        } catch { return false }
    }
}
#endif
