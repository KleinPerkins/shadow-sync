#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum PolicyInputSelfTestRunner {
    private enum Failure: Error { case assertion(String) }

    public static func runAll(onPass: (String) -> Void) throws {
        let payload = Data("{\"candidate\":\"/fixture-private/never-in-argv\"}\n".utf8)
        try RuntimeFixtureSession.withCase("POLICY-INPUT-T01-bounded-stdin-and-private-argv") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            for size in [payload.count, 262_144] {
                let bytes = size == payload.count ? payload : Data(repeating: 65, count: size)
                let snapshot = try ClosedProcessInput(data: bytes, directory: fixture.directory,
                                                      owner: geteuid())
                let input = snapshot.descriptor
                let audit = CommandAudit()
                let result = try withExtendedLifetime(snapshot) { try fixture.run(input, audit: audit) }
                try require(result.status == 0 && result.stdout == bytes && result.stderr.isEmpty
                    && !result.stdoutTruncated && !result.timedOut && !result.cancelled,
                    "stdin payload was not read exactly")
                try require(audit.invocations.count == 1
                    && audit.invocations[0].arguments.isEmpty
                    && audit.invocations[0].spawnArguments == ["/bin/cat"],
                    "input escaped into process arguments")
                try require(fcntl(input, F_GETFD) >= 0, "runner closed its borrowed input")
                try require(waitpid(result.processID, nil, WNOHANG) == -1 && errno == ECHILD,
                    "completed child was not reaped")
            }
            try fixture.remove()
        }
        onPass("POLICY-INPUT-T01-bounded-stdin-and-private-argv")
        try RuntimeFixtureSession.withCase("POLICY-INPUT-T02-invalid-descriptors-refuse-before-spawn") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let variations: [(String, (Int32) throws -> Void)] = [
                ("offset", { try require(lseek($0, 1, SEEK_SET) == 1, "seek fixture") }),
                ("mode", { try require(fchmod($0, 0o600) == 0, "chmod fixture") }),
                ("closed", { close($0) }),
            ]
            for (name, change) in variations {
                let input = try fixture.input(payload)
                defer { if name != "closed" { close(input) } }
                try change(input)
                try refuseBeforeSpawn { audit in try fixture.run(input, audit: audit) }
            }
            for size in [0, 262_145] {
                let input = try fixture.input(Data(repeating: 65, count: size))
                defer { close(input) }
                try refuseBeforeSpawn { audit in try fixture.run(input, audit: audit) }
            }
            try fixture.remove()
        }
        onPass("POLICY-INPUT-T02-invalid-descriptors-refuse-before-spawn")
        try RuntimeFixtureSession.withCase("POLICY-INPUT-T03-linked-writable-and-pipe-refusal") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let linked = try fixture.input(payload, unlink: false)
            defer { close(linked) }
            try refuseBeforeSpawn { audit in try fixture.run(linked, audit: audit) }
            let writable = try fixture.input(payload, readOnly: false)
            defer { close(writable) }
            try refuseBeforeSpawn { audit in try fixture.run(writable, audit: audit) }
            var pipeFDs: [Int32] = [-1, -1]
            try require(pipe(&pipeFDs) == 0, "pipe fixture")
            defer { close(pipeFDs[0]); close(pipeFDs[1]) }
            try refuseBeforeSpawn { audit in try fixture.run(pipeFDs[0], audit: audit) }
            try fixture.remove()
        }
        onPass("POLICY-INPUT-T03-linked-writable-and-pipe-refusal")
        try RuntimeFixtureSession.withCase("POLICY-INPUT-T04-cancelled-admission") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let cancelledInput = try fixture.input(payload)
            defer { close(cancelledInput) }
            let cancelled = CancellationToken(); cancelled.cancel()
            try refuseBeforeSpawn { audit in
                try fixture.run(cancelledInput, audit: audit, cancellation: cancelled)
            }
            try fixture.remove()
        }
        onPass("POLICY-INPUT-T04-cancelled-admission")
        try RuntimeFixtureSession.withCase("POLICY-INPUT-T05-timeout-and-reaping") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let timedInput = try fixture.input(payload)
            defer { close(timedInput) }
            let started = DispatchTime.now().uptimeNanoseconds
            let timed = try fixture.run(timedInput, executable: "/bin/sleep",
                                        arguments: ["5"], timeout: 0.1)
            try require(timed.timedOut && timed.status != 0 && timed.terminationRequested,
                        "deadline did not terminate the owned child")
            try require(DispatchTime.now().uptimeNanoseconds - started < 4_000_000_000,
                        "deadline cleanup exceeded its bound")
            try require(waitpid(timed.processID, nil, WNOHANG) == -1 && errno == ECHILD,
                        "timed child was not reaped")
            try fixture.remove()
        }
        onPass("POLICY-INPUT-T05-timeout-and-reaping")
        try RuntimeFixtureSession.withCase("POLICY-INPUT-T06-snapshot-size-and-private-scratch") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            for size in [0, ClosedProcessInput.maximumBytes + 1] {
                var refused = false
                do {
                    _ = try ClosedProcessInput(data: Data(repeating: 65, count: size),
                                               directory: fixture.directory, owner: geteuid())
                } catch { refused = true }
                try require(refused, "snapshot accepted an invalid size")
            }
            try require(fchmod(fixture.directory, 0o750) == 0, "scratch mode fixture")
            var unsafeScratchRefused = false
            do {
                _ = try ClosedProcessInput(data: payload, directory: fixture.directory, owner: geteuid())
            } catch { unsafeScratchRefused = true }
            try require(fchmod(fixture.directory, 0o700) == 0, "restore scratch mode")
            try require(unsafeScratchRefused, "snapshot accepted shared scratch")
            try fixture.remove()
        }
        onPass("POLICY-INPUT-T06-snapshot-size-and-private-scratch")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    private static func refuseBeforeSpawn(
        _ operation: (CommandAudit) throws -> ProcessResult
    ) throws {
        let audit = CommandAudit()
        var refused = false
        do { _ = try operation(audit) } catch { refused = true }
        try require(refused && audit.invocations.isEmpty, "unsafe input reached child admission")
    }

    private final class Fixture {
        let path: String
        let directory: Int32
        let account: EffectiveAccount
        let identity: FileIdentity
        private var removed = false

        init() throws {
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-input-") + "XXXXXX").utf8CString)
            guard let created = mkdtemp(&template) else { throw Failure.assertion("mkdtemp") }
            path = String(cString: created)
            directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var info = stat()
            guard directory >= 0, fstat(directory, &info) == 0,
                  info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw Failure.assertion("fixture directory")
            }
            identity = FileIdentity(info)
            account = EffectiveAccount(uid: geteuid(), username: "fixture", homeDirectory: path)
        }

        func input(_ data: Data, unlink: Bool = true, readOnly: Bool = true) throws -> Int32 {
            let name = UUID().uuidString
            let writer = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard writer >= 0 else { throw Failure.assertion("fixture input create") }
            defer { close(writer) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = write(writer, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.assertion("fixture input write") }
                    offset += count
                }
            }
            try require(fchmod(writer, 0o400) == 0, "fixture input mode")
            let descriptor = readOnly
                ? openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) : dup(writer)
            guard descriptor >= 0 else { throw Failure.assertion("fixture input open") }
            if unlink { try require(unlinkat(directory, name, 0) == 0, "fixture input unlink") }
            _ = lseek(descriptor, 0, SEEK_SET)
            return descriptor
        }

        func run(_ input: Int32, audit: CommandAudit? = nil,
                 cancellation: CancellationToken = CancellationToken(),
                 executable: String = "/bin/cat", arguments: [String] = [],
                 timeout: TimeInterval = 2) throws -> ProcessResult {
            try ClosedProcessRunner(outputLimit: 262_144, audit: audit).run(
                command: ClosedProcessCommand(executable: executable, arguments: arguments,
                                              standardInputDescriptor: input),
                environment: ClosedProcessRunner.environment(account: account),
                workingDirectoryDescriptor: directory, account: account,
                timeout: timeout, cancellation: cancellation)
        }

        func remove() throws {
            if removed { return }
            var info = stat()
            var opened = stat()
            // Directory link counts change as owned fixture entries are created.
            // Keep the device/inode/owner/mode checks, including descriptor parity.
            try require(lstat(path, &info) == 0 && fstat(directory, &opened) == 0
                && FileIdentity(info).matchesStableNode(identity)
                && FileIdentity(opened).matchesStableNode(identity), "fixture cleanup identity")
            try FileManager.default.removeItem(atPath: path)
            close(directory)
            removed = true
        }
    }
}
#endif
