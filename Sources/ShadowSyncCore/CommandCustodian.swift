import Darwin
import Foundation
import Security

/// Fixed signed helper role, entered before application initialization. The
/// process lifetime is the cleanup lifetime; a caller deadline never kills it.
public enum CommandCustodian {
    public static var hasRetainedWork: Bool { RetainedCleanupRegistry.shared.hasRetainedWork }
    public static func dispatch(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--shadow-sync-command-custodian") else { return nil }
        guard arguments.count == 2, arguments[1] == "--shadow-sync-command-custodian" else { return 64 }
        do { return try CustodianLoop(inherited: CustodyInheritedCommand.production()).run() }
        catch { return 70 }
    }
    #if SHADOW_SYNC_TESTING
    public static func testingDispatch(_ arguments: [String]) -> Int32? {
        if arguments.count == 2 && arguments[1] == "--shadow-sync-discovery-custodian-fixture" {
            do { return try CustodianLoop(inherited: CustodyInheritedCommand.testingDiscovery()).run() }
            catch { return 71 }
        }
        if arguments.count == 2 && arguments[1] == "--shadow-sync-custodian-fixture" {
            do { return try CustodianLoop(inherited: CustodyInheritedCommand.testing()).run() }
            catch { return 71 }
        }
        if arguments.count == 3 && arguments[1] == "--shadow-sync-custodian-target-fixture" {
            return targetFixture(arguments[2])
        }
        return nil
    }
    private static func targetFixture(_ mode: String) -> Int32 {
        guard ["complete","fail","wait","resist","overflow","after-admit","before-resume","after-preparation","terminal-delay",
               "trace-complete","trace-overflow","trace-resist","policy-echo","policy-resist",
                    "system-complete","system-missing","system-faildata","system-resist","system-overflow",
               "config-complete","config-resist", "system-multiple-policy-batches", "classification-allow", "classification-protected", "classification-malformed", "classification-nonce", "classification-binding", "classification-code-allow"].contains(mode) else { return 64 }
        if mode == "resist" || mode == "trace-resist" || mode == "policy-resist" || mode == "system-resist" || mode == "config-resist" { signal(SIGTERM, SIG_IGN) }
        if mode.hasPrefix("config-") {
            var info = stat()
            guard fstat(196, &info) == 0, info.st_mode == S_IFREG | 0o600,
                  info.st_nlink == 1, info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= 1_572_864,
                  info.st_flags & UInt32(UF_IMMUTABLE) != 0,
                  fcntl(196, F_GETFL) & O_ACCMODE == O_RDONLY,
                  fcntl(195, F_GETFD) == -1, errno == EBADF,
                  fcntl(198, F_GETFD) >= 0 else { return 76 }
            var bytes = Data(count: Int(info.st_size))
            let readOK = bytes.withUnsafeMutableBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.read(196, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return false }; offset += n
                }
                return true
            }
            guard readOK else { return 77 }
            let proof = Data(("frozen-config:" + CustodyRecordBinding.digest(bytes) + "\n").utf8)
            guard proof.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == proof.count else { return 78 }
            if mode == "config-complete" { return 0 }
            while true { usleep(10_000) }
        }
        if mode.hasPrefix("classification-") {
            // Exercise the real sealed request and strict response decoder. This
            // fixed synthetic classifier is not the publisher/AWA interpreter.
            do {
                var info = stat()
                guard fstat(0, &info) == 0, info.st_mode == S_IFREG | 0o400,
                      info.st_nlink == 0, info.st_uid == geteuid(), info.st_size > 0,
                      info.st_size <= 262_144, fcntl(0, F_GETFL) & O_ACCMODE == O_RDONLY else { return 75 }
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count == info.st_size else { return 75 }
                if mode == "classification-code-allow" {
                    var code = stat()
                    guard fstat(9, &code) == 0, code.st_mode == S_IFREG | 0o400, code.st_nlink == 0,
                          code.st_uid == geteuid(), fcntl(9, F_GETFL) & O_ACCMODE == O_RDONLY,
                          code.st_size == 44,
                          FileHandle(fileDescriptor: 9, closeOnDealloc: false).readDataToEndOfFile()
                            == Data("shadow-sync-fixture-policy-code-offset-zero\n".utf8) else { return 75 }
                }
                let binding = String(repeating: "b", count: 64)
                try PolicyCommandWire.validateRequest(input, bindingSHA256: binding)
                let request = try CustodyWire.decode(input, maximum: 262_144).object(keys: ["schema", "nonce", "binding_sha256", "candidates"])
                let candidates = try CustodyWire.array(request["candidates"])
                let nonce = try CustodyWire.text(request["nonce"])
                if mode == "classification-malformed" {
                    let raw = Data("{\"schema\":\"broken\"}\n".utf8)
                    guard raw.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == raw.count else { return 74 }
                    return 0
                }
                let rows: [[String: Any]] = candidates.indices.map { index in
                    let protected = mode == "classification-protected" && index == candidates.count - 1
                    return ["index": index, "matched": protected,
                            "kind": protected ? "exact_root" : "none", "policy_valid": true]
                }
                let bytes = try JSONSerialization.data(withJSONObject: [
                    "schema": "shadow-sync-policy-batch-response/v1",
                    "nonce": mode == "classification-nonce" ? String(repeating: "f", count: 32) : nonce,
                    "binding_sha256": mode == "classification-binding" ? String(repeating: "f", count: 64) : binding,
                    "policy_sha256": String(repeating: "d", count: 64),
                    "module_sha256": String(repeating: "e", count: 64), "results": rows,
                ], options: [.sortedKeys])
                guard bytes.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == bytes.count else { return 74 }
                return 0
            } catch { return 75 }
        }
        // Synthetic output only: these fixtures never read host Git config.
        if mode == "system-missing" { return 128 }
        if mode == "system-complete" || mode == "system-faildata" || mode == "system-multiple-policy-batches" {
            let path = mode == "system-multiple-policy-batches" ? "/fixture/" + Array(repeating: "nested", count: 70).joined(separator: "/") + "/config" : "/fixture/system-config"
            let bytes = Data(("file:" + path + "\0core.safe\0").utf8)
            guard bytes.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == bytes.count else { return 74 }
            return mode == "system-faildata" ? 7 : 0
        }
        let greeting = Data("target-started:\(getpid())\n".utf8)
        _ = greeting.withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
        if mode.hasPrefix("policy-") {
            // Exercise real immutable stdin/code inheritance without executing
            // caller-provided code. Production classification remains gated on
            // its publisher adapter and qualified interpreter graph.
            do {
                func read(_ fd: Int32) throws -> Data {
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode == S_IFREG | 0o400,
                          info.st_nlink == 0, info.st_uid == geteuid(),
                          fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY,
                          info.st_size > 0, info.st_size <= 262_144 else { throw CustodyResourceError.invalidResource }
                    var bytes = Data(count: Int(info.st_size))
                    try bytes.withUnsafeMutableBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if n < 0 && errno == EINTR { continue }
                            guard n > 0 else { throw CustodyResourceError.invalidResource }; offset += n
                        }
                    }
                    var tail: UInt8 = 0
                    guard Darwin.read(fd, &tail, 1) == 0 else { throw CustodyResourceError.invalidResource }
                    return bytes
                }
                let input = try read(0), code = try read(9)
                let proof = Data(("policy-input:" + CustodyRecordBinding.digest(input)
                    + "\npolicy-code:" + CustodyRecordBinding.digest(code) + "\n").utf8)
                guard proof.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == proof.count else { return 74 }
                if mode == "policy-echo" { return 0 }
            } catch { return 75 }
        }
        if mode.hasPrefix("trace-") {
            // A real inherited third stream, with distinct bytes from standard
            // output/error. The production relay and registry own all drainage.
            let bytes = Data((0..<256).map(UInt8.init))
            let repetitions = mode == "trace-overflow" ? 2048 : 128
            for _ in 0..<repetitions {
                var offset = 0
                while offset < bytes.count {
                    let n = bytes.withUnsafeBytes { Darwin.write(discoveryTraceDescriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return 73 }; offset += n
                }
            }
            if mode == "trace-complete" || mode == "trace-overflow" { return 0 }
            close(1); close(2)
        }
        if mode == "complete" || mode == "terminal-delay" { return 0 }
        if mode == "fail" { return 7 }
        if mode == "overflow" || mode == "system-overflow" {
            let bytes = [UInt8](repeating: 120, count: 4096)
            for _ in 0..<64 { _ = bytes.withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) } }
            return 0
        }
        while true { usleep(10_000) }
    }
    #endif
}

/// Production target authority comes only from the sealed qualification catalog.
/// The synthetic test target remains compile-time isolated from this path.
/// A serial stage is timing/command shape only. The inherited command still
/// supplies authenticated publisher, resource and lease authority.
private enum CustodianStage: Equatable {
    case systemConfiguration, policyClassification, command
    var preflight: DiscoveryGitCommand.Preflight? {
        switch self {
        case .systemConfiguration: .systemConfiguration
        case .policyClassification: .policyClassification
        case .command: nil
        }
    }
}

private final class CustodianTarget {
    let path: String, arguments: [String]
    let environment: [String: String]
    let graph: QualifiedCommandGraph?
    private let fixtureSnapshot: PublisherExecutableSnapshot?
    init(_ inherited: CustodyInheritedCommand, stage: CustodianStage = .command) throws {
        #if SHADOW_SYNC_TESTING
        if let mode = inherited.fixtureMode {
            path = inherited.helper.path
            let targetMode: String
            if mode.hasPrefix("serial-") {
                switch stage {
                case .systemConfiguration:
                    targetMode = ["serial-policy-multiple-batches", "serial-policy-code-batches"].contains(mode) ? "system-multiple-policy-batches" : mode.hasPrefix("serial-system-missing") ? "system-missing" : mode == "serial-system-overflow" ? "system-overflow" : (mode == "serial-system-failure" ? "system-faildata"
                        : (mode == "serial-system-cancel" ? "system-resist" : "system-complete"))
                case .policyClassification:
                    switch mode {
                    case "serial-policy-overflow": targetMode = "overflow"
                    case "serial-policy-failure": targetMode = "fail"
                    case "serial-policy-cancel", "serial-policy-timeout": targetMode = "resist"
                    case "serial-policy-protected": targetMode = "classification-protected"
                    case "serial-policy-malformed": targetMode = "classification-malformed"
                    case "serial-policy-wrong-nonce": targetMode = "classification-nonce"
                    case "serial-policy-wrong-binding": targetMode = "classification-binding"
                    case "serial-policy-code-batches": targetMode = "classification-code-allow"
                    default: targetMode = "classification-allow"
                    }
                case .command:
                    targetMode = mode == "serial-command-cancel" ? "resist" : "complete"
                }
            } else { targetMode = mode == "deadline-before-control" ? "resist" : mode }
            arguments = [path, "--shadow-sync-custodian-target-fixture", targetMode]
            fixtureSnapshot = try PublisherExecutableSnapshot.capture(path: path, owner: geteuid())
            graph = nil; environment = inherited.request.environment; return
        }
        #endif
        let qualified: QualifiedCommandGraph
        let args: [String]
        if let discovery = inherited.discovery {
            try discovery.revalidate()
            switch stage {
            case .systemConfiguration:
                qualified = discovery.systemGraph; args = SystemGitConfigurationCommand.arguments
                var values = SystemGitConfigurationCommand.environment(account: inherited.account)
                #if SHADOW_SYNC_TESTING
                if inherited.testingDiscovery {
                    values["GIT_CONFIG_SYSTEM"] = try DiscoveryFixtureResources.systemConfiguration(home: inherited.account.homeDirectory)
                }
                #endif
                environment = values
            case .policyClassification:
                qualified = discovery.policy.graph; args = PolicyCommandWire.interpreterArguments
                environment = ClosedProcessRunner.environment(account: inherited.account)
            case .command:
                guard discovery.root != nil, discovery.frozen != nil else { throw CustodyResourceError.invalidResource }
                qualified = discovery.gitGraph; args = discovery.command.arguments
                var values = discovery.command.environment(account: inherited.account)
                values["GIT_CONFIG_VALUE_0"] = "/dev/fd/196"
                environment = values
            }
        } else {
            guard stage == .command else { throw CustodyResourceError.invalidResource }
            if inherited.request.kind == .policyClassify {
                guard let policy = inherited.policy else { throw CustodyResourceError.invalidResource }
                try policy.revalidate(); qualified = policy.graph
                args = PolicyCommandWire.interpreterArguments
            } else {
                guard [.launchctlRead, .signatureCheck, .systemGitConfig].contains(inherited.request.kind) else { throw CustodyResourceError.invalidResource }
                qualified = try QualifiedCommandGraph.production(kind: inherited.request.kind, helper: inherited.helper)
                args = inherited.request.arguments
            }
            environment = inherited.request.environment
        }
        graph = qualified; path = qualified.entryPath; arguments = [path] + args
        fixtureSnapshot = nil
    }
    func validate(_ anchor: OwnedSpawnAnchor) throws {
        if let graph { try graph.validateSuspended(anchor); return }
        #if SHADOW_SYNC_TESTING
        guard let fixtureSnapshot, fixtureSnapshot == (try PublisherExecutableSnapshot.capture(path: path, owner: geteuid())) else { throw PublisherPolicyError.unavailable }
        #else
        throw PublisherPolicyError.unavailable
        #endif
    }
}

/// One synchronous event loop per custodian. No callbacks or ownership mutex
/// span target I/O or waits. Pending retains the process, descriptors and journal.
private final class CustodianLoop {
    private let inherited: CustodyInheritedCommand
    private let journal: CustodyHelperJournal
    private var target: CustodianTarget
    private var stages: [CustodianStage]
    private var configurationPolicyPlan: ConfigurationPolicyPlan?
    private var configurationPolicyBatch: ConfigurationPolicyBatch?
    private var configurationPolicyInput: CustodySealedResource?
    private var configurationPolicyCode: CustodySealedResource?
    private var configurationPreflight: GitConfigurationPreflight?
    private let discoveryCommand: DiscoveryGitCommand?
    private var stageIndex = 0
    #if SHADOW_SYNC_TESTING
    private var serialReadyPublished = false
    #endif
    private var stageBudget: CustodyBudget
    private var stage: CustodianStage { stages[stageIndex] }
    private var state: CustodyAdmissionState
    private var decoder = CustodyFrameDecoder()
    private var statusSequence: UInt64 = 0
    private var statusQueue: [Data] = [], statusOffset = 0
    private var reason: CustodyReason = .none
    private var controlEnded = false, statusBroken = false, persistenceFailed = false
    private var spawned = false, resumed = false, sentTerm = false, sentKill = false, sentPending = false
    private var anchor: OwnedSpawnAnchor?, owner: OwnedDirectChild?
    private var stdoutRead: OwnedFileDescriptor?, stderrRead: OwnedFileDescriptor?
    private var traceRead: OwnedFileDescriptor?
    private var stdoutEnded = true, stderrEnded = true
    private var stdoutBuffer = Data(), stderrBuffer = Data()
    private var stdoutCount: UInt64 = 0, stderrCount: UInt64 = 0
    private var stdoutBroken = false, stderrBroken = false
    private var traceEnded = true, traceBroken = false
    private var traceBuffer = Data()
    private var traceCount: UInt64 = 0
    private var terminalPublished = false, terminalTime: UInt64?
    private var discoveryPostflightComplete = false

    init(inherited: CustodyInheritedCommand) throws {
        self.inherited = inherited
        journal = try CustodyHelperJournal.begin(inherited)
        var serial = inherited.discovery != nil
        #if SHADOW_SYNC_TESTING
        serial = serial || inherited.fixtureMode?.hasPrefix("serial-") == true
        #endif
        stages = serial ? [.systemConfiguration, .policyClassification, .command] : [.command]
        discoveryCommand = try inherited.discovery?.command ?? (serial ? DiscoveryGitCommand(
            arguments: ["--no-replace-objects", "--no-lazy-fetch", "symbolic-ref", "--quiet", "--short", "HEAD"],
            captureTransportConfiguration: false, timeoutSeconds: DiscoveryGitCommand.maximumWorkSeconds) : nil)
        stageBudget = try discoveryCommand.map {
            try inherited.request.budget.discoveryPreflight(.systemConfiguration, command: $0)
        } ?? inherited.request.budget
        target = try CustodianTarget(inherited, stage: stages[0])
        state = try CustodyAdmissionState(binding: inherited.request.binding, budget: inherited.request.budget)
    }
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func status(_ event: CustodyMessage.Event, terminal: CustodyJournal? = nil) throws {
        let message = CustodyMessage(binding: inherited.request.binding, sequence: statusSequence, event: event,
            outcome: terminal.flatMap { CustodyMessage.Outcome(rawValue: $0.outcome!.rawValue) },
            waitStatus: terminal?.waitStatus, receiptSHA256: try terminal.map { CustodyRecordBinding.digest(try $0.encode()) })
        let frame = try CustodyFrameDecoder.frame(message.encode())
        guard statusQueue.count < 3 else { throw CustodyProtocolError.invalidSequence }
        try state.accept(message, now: now); statusSequence += 1
        statusQueue.append(frame)
    }
    private func beginDrain(_ cause: CustodyReason) {
        if reason == .none { reason = cause }
        if state.phase != .terminal { try? state.closeAdmission(now: now) }
        if let clipped = try? stageBudget.draining(at: now) { stageBudget = clipped }
        do { try journal.draining(reason: reason) }
        catch { persistenceFailed = true }
    }
    #if SHADOW_SYNC_TESTING
    private var testingExpiredControlObserved = false
    #endif
    private func consumeControl() {
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode == "deadline-before-control", resumed, !testingExpiredControlObserved,
           let fd = inherited.descriptors[.control]?.value {
            testingExpiredControlObserved = true
            // Hold this fixture until the parent's deadline-triggered cancel is
            // readable. The ordinary transition below must retain timeout.
            while now < inherited.request.budget.work { usleep(1_000) }
            var readable = false
            while now < inherited.request.budget.term {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 2) > 0, descriptor.revents & Int16(POLLIN) != 0 { readable = true; break }
            }
            if readable { stderrBuffer.append(Data("shadow-sync-fixture-expired-control\n".utf8)) }
            else { beginDrain(.invalidResource) }
        }
        #endif
        // Deadline observation precedes a newly observed control frame. The
        // parent also sends cancel at expiry; that wakeup must not relabel a
        // timeout. Previously recorded cancellation/failure remains first.
        if reason == .none, now >= min(inherited.request.budget.work, stageBudget.work) { beginDrain(.timeout) }
        guard !controlEnded, let fd = inherited.descriptors[.control]?.value else { return }
        var bytes = [UInt8](repeating: 0, count: 16_388)
        // Bounded reads per iteration; final resume never occurs if bytes remain
        // after the bound (level-triggered poll below must report quiescence).
        for _ in 0..<4 {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n == 0 {
                controlEnded = true
                do { try decoder.finish() } catch { beginDrain(.protocolFault) }
                beginDrain(.cancelled); return
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                controlEnded = true; beginDrain(.ioFailure); return
            }
            do {
                for bytes in try decoder.append(Data(bytes.prefix(n))) {
                    let message = try CustodyMessage.decode(bytes, expected: inherited.request.binding, channel: .control)
                    try state.accept(message, now: now)
                    if message.event == .cancel { beginDrain(.cancelled) }
                }
            } catch { beginDrain(.protocolFault) }
        }
    }
    private func controlQuiescent() -> Bool {
        guard !controlEnded, let fd = inherited.descriptors[.control]?.value else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let rc = poll(&descriptor, 1, 0)
        return rc == 0 && descriptor.revents == 0
    }
    private func pipe() throws -> (OwnedFileDescriptor, OwnedFileDescriptor) {
        var fds: [Int32] = [-1,-1]
        guard Darwin.pipe(&fds) == 0 else { throw CustodyResourceError.systemCall(errno) }
        let originals = fds.map(OwnedFileDescriptor.init); defer { originals.forEach { $0.closeNow() } }
        let copies = try originals.map { OwnedFileDescriptor(try $0.duplicate(minimum: 201)) }
        // Target stdout/stderr stay blocking; only the custodian reader polls.
        let flags = fcntl(copies[0].value,F_GETFL)
        guard flags >= 0, fcntl(copies[0].value,F_SETFL,flags | O_NONBLOCK) == 0 else { throw CustodyResourceError.systemCall(errno) }
        guard fcntl(copies[1].value,F_SETNOSIGPIPE,1) == 0 else { throw CustodyResourceError.systemCall(errno) }
        return (copies[0],copies[1])
    }
    private func spawnTarget() throws {
        try inherited.revalidateResources(); try inherited.revalidateParent(); try journal.leases.validate()
        guard try state.permitsResume(now: now), controlQuiescent() else { consumeControl(); throw CustodyRecordError.fenced }
        guard now < stageBudget.work else { throw CustodyProtocolError.invalidBudget }
        #if SHADOW_SYNC_TESTING
        if stageIndex == 1, ["serial-next-before-spawn", "serial-system-missing-next-before-spawn"].contains(inherited.fixtureMode ?? "") { throw CustodyResourceError.invalidResource }
        #endif
        if journal.current.phase == .prepared { try journal.admit() }
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode == "after-admit" { usleep(200_000) }
        #endif
        consumeControl()
        guard try state.permitsResume(now: now), controlQuiescent() else { throw CustodyRecordError.fenced }
        let out = try pipe(), err = try pipe()
        let trace = stage == .command && inherited.request.traceLimit > 0 ? try pipe() : nil
        stdoutRead = out.0; stderrRead = err.0; stdoutEnded = false; stderrEnded = false
        traceRead = trace?.0; traceEnded = trace == nil
        defer { out.1.closeNow(); err.1.closeNow(); trace?.1.closeNow() }
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CustodyResourceError.invalidResource }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attr) == 0 else { throw CustodyResourceError.invalidResource }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawn_file_actions_adddup2(&actions,out.1.value,1) == 0,
              posix_spawn_file_actions_adddup2(&actions,err.1.value,2) == 0,
              posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0) == 0,
              let cwd = (stage == .command ? inherited.discovery?.root : nil) ?? inherited.descriptors[.workingDirectory], posix_spawn_file_actions_addfchdir(&actions,cwd.value) == 0 else { throw CustodyResourceError.invalidResource }
        let policyInputView = try stage == .policyClassification ? configurationPolicyInput?.duplicateReadOnly() : nil
        let policyCodeView = try stage == .policyClassification ? configurationPolicyCode?.duplicateReadOnly() : nil
        defer { policyInputView?.closeNow(); policyCodeView?.closeNow() }
        if stage == .policyClassification {
            guard let policyInputView,
                  posix_spawn_file_actions_adddup2(&actions, policyInputView.value, 0) == 0 else { throw CustodyResourceError.invalidResource }
            if let policyCodeView {
                guard posix_spawn_file_actions_adddup2(&actions, policyCodeView.value, 9) == 0 else { throw CustodyResourceError.invalidResource }
            } else if inherited.discovery != nil { throw CustodyResourceError.invalidResource }
        }
        if inherited.request.kind == .policyClassify {
            guard let input = inherited.descriptors[.input], let code = inherited.descriptors[.code],
                  posix_spawn_file_actions_adddup2(&actions, input.value, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, code.value, 9) == 0 else {
                throw CustodyResourceError.invalidResource
            }
        }
        if stage == .command, let frozen = inherited.discovery?.frozen {
            try frozen.revalidate()
            guard inherited.request.kind == .discoveryGit, let descriptor = frozen.descriptor,
                  posix_spawn_file_actions_adddup2(&actions, descriptor, 196) == 0 else {
                throw CustodyResourceError.invalidResource
            }
        } else if stage == .command, let frozen = inherited.frozenConfiguration {
            try frozen.revalidate()
            guard inherited.request.kind == .discoveryGit,
                  posix_spawn_file_actions_adddup2(&actions, frozen.targetReadOnly.value, 196) == 0 else {
                throw CustodyResourceError.invalidResource
            }
        }
        if let operation = inherited.descriptors[.operation] {
            guard posix_spawn_file_actions_adddup2(&actions,operation.value,198) == 0 else { throw CustodyResourceError.invalidResource }
        }
        if let trace {
            guard inherited.request.kind == .discoveryGit,
                  posix_spawn_file_actions_adddup2(&actions, trace.1.value, discoveryTraceDescriptor) == 0 else {
                throw CustodyResourceError.invalidResource
            }
        }
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigemptyset(&defaults)
        sigaddset(&defaults,SIGTERM); sigaddset(&defaults,SIGINT); sigaddset(&defaults,SIGPIPE)
        guard posix_spawnattr_setflags(&attr,flags) == 0, posix_spawnattr_setpgroup(&attr,0) == 0,
              posix_spawnattr_setsigmask(&attr,&empty) == 0, posix_spawnattr_setsigdefault(&attr,&defaults) == 0 else { throw CustodyResourceError.invalidResource }
        let a = target.arguments.map { strdup($0) }, e = target.environment.keys.sorted().map { strdup($0+"="+target.environment[$0]!) }
        defer { (a+e).forEach { free($0) } }
        guard (a+e).allSatisfy({ $0 != nil }) else { throw CustodyResourceError.limit }
        var argv = a + [nil], env = e + [nil]
        anchor = try argv.withUnsafeMutableBufferPointer { av in try env.withUnsafeMutableBufferPointer { ev in
            try OwnedSpawnAnchor.spawn(executable:target.path,actions:&actions,attributes:&attr,arguments:av.baseAddress,environment:ev.baseAddress)
        } }
        spawned = true
        guard let anchor else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        if stageIndex == 1, ["serial-next-after-spawn", "serial-system-missing-next-after-spawn"].contains(inherited.fixtureMode ?? "") { throw CustodyResourceError.invalidResource }
        #endif
        try target.validate(anchor)
        owner = try anchor.transfer(expectedExecutable:target.path,generation:inherited.request.binding.callerGeneration,reapPolicy:.afterGroupDrain,qualifiedGraph:target.graph)
        #if SHADOW_SYNC_TESTING
        if stageIndex == 1, ["serial-next-before-record", "serial-system-missing-next-before-record"].contains(inherited.fixtureMode ?? "") { throw CustodyResourceError.invalidResource }
        #endif
        try journal.executing(owner!)
        try inherited.revalidateResources(); try inherited.revalidateParent(); try target.validate(anchor)
        guard owner!.prepareGraphSignal() == .ready else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode == "before-resume" { usleep(200_000) }
        if inherited.fixtureMode == "after-preparation" { try testingAwaitFinalControl() }
        #endif
        // The same serialized loop observes all available cancellation/EOF and
        // enters the final resume transition; no queue callback can race it.
        consumeControl()
        guard try state.permitsResume(now:now), controlQuiescent(),
              now < stageBudget.work,
              owner!.resume(before: MonotonicDeadline(uptimeNanoseconds: min(state.budget.work, stageBudget.work))) else { throw CustodyRecordError.fenced }
        resumed = true
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode?.hasPrefix("serial-") == true {
            try testingSerialMarker("resumed", targetPID: owner!.identity.processID)
        }
        #endif
    }
    #if SHADOW_SYNC_TESTING
    /// This fixture publishes the actual final-preparation boundary and waits
    /// for the existing control channel to become readable. It neither consumes
    /// control nor changes admission: the production transition below must do
    /// both. The original suspended child remains owned throughout the pause.
    private func testingSerialMarker(_ event: String, targetPID: pid_t) throws {
        let bytes = Data("shadow-sync-fixture-serial:\(stageIndex):\(event):\(targetPID)\n".utf8)
        let n = bytes.withUnsafeBytes { Darwin.write(inherited.error.value, $0.baseAddress, $0.count) }
        guard n == bytes.count else { throw CustodyResourceError.invalidResource }
    }
    private func testingAwaitFinalControl() throws {
        guard let control = inherited.descriptors[.control] else { throw CustodyResourceError.invalidResource }
        let marker = Data("shadow-sync-fixture-final-preparation\n".utf8)
        var offset = 0
        while offset < marker.count {
            guard now < state.budget.work else { throw CustodyRecordError.fenced }
            let written = marker.withUnsafeBytes {
                Darwin.write(inherited.error.value, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0 && errno == EINTR { continue }
            guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { throw CustodyResourceError.invalidResource }
            var output = pollfd(fd: inherited.error.value, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
            _ = poll(&output, 1, 2)
        }
        while now < state.budget.work {
            var ready = pollfd(fd: control.value, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = poll(&ready, 1, 2)
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw CustodyResourceError.invalidResource }
        }
        throw CustodyRecordError.fenced
    }
    #endif
    private func drainTarget() {
        if let owner {
            _ = owner.poll()
            if !resumed && !sentKill { sentKill = true; _ = owner.send(SIGKILL) }
            else if state.phase == .draining {
                if !sentTerm && owner.prepareGraphSignal() == .ready { sentTerm = owner.send(SIGTERM) }
                if now >= min(state.budget.term, stageBudget.term) && !sentKill && owner.prepareGraphSignal() == .ready { sentKill = owner.send(SIGKILL) }
            }
            if owner.hasGraphFault { beginDrain(.identityFailure) }
            _ = owner.reapAfterGroupDrain(streamsDrained:stdoutEnded && stderrEnded && traceEnded)
        } else if let anchor {
            if !sentKill { sentKill = true; _ = anchor.killSuspended() }
            _ = anchor.poll()
        }
    }
    private func relay(_ isError: Bool) {
        let readFD = isError ? stderrRead : stdoutRead
        guard let readFD else { return }
        let requested = isError ? inherited.request.stderrLimit : inherited.request.stdoutLimit
        let limit = stage == .command ? requested : min(requested, 65_536)
        // Bounded buffers allow drainage even after the caller disappears.
        if !(isError ? stderrEnded : stdoutEnded) {
            var bytes = [UInt8](repeating:0,count:16_384)
            let n = Darwin.read(readFD.value,&bytes,bytes.count)
            if n == 0 { if isError { stderrEnded = true } else { stdoutEnded = true } }
            else if n < 0 {
                if ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) { beginDrain(.ioFailure) }
            } else {
                let count = isError ? stderrCount : stdoutCount
                if count > limit || UInt64(n) > limit-count { beginDrain(.outputLimit) }
                let bounded = min(UInt64(n),limit > count ? limit-count : 0)
                if isError {
                    stderrCount = min(limit+1,count+UInt64(n))
                    if !stderrBroken { stderrBuffer.append(contentsOf:bytes.prefix(Int(bounded))) }
                } else {
                    stdoutCount = min(limit+1,count+UInt64(n))
                    if !stdoutBroken { stdoutBuffer.append(contentsOf:bytes.prefix(Int(bounded))) }
                }
            }
        }
        #if SHADOW_SYNC_TESTING
        if !isError, inherited.fixtureMode?.hasPrefix("serial-") == true,
           !serialReadyPublished, let owner,
           stdoutBuffer.starts(with: Data("target-started:".utf8)), stdoutBuffer.contains(10) {
            // The actual target wrote this after installing its TERM handler.
            // A resumed-process observation alone does not prove readiness.
            do { try testingSerialMarker("ready", targetPID: owner.identity.processID); serialReadyPublished = true }
            catch { beginDrain(.ioFailure) }
        }
        #endif
        // Preflight output is consumed inside this custodian and never mixed
        // with the final command's public streams. Counts still enforce bounds.
        guard stage == .command else { return }
        let data = isError ? stderrBuffer : stdoutBuffer
        guard !data.isEmpty else { return }
        let fd = isError ? inherited.error.value : inherited.output.value
        let n = data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,$0.count) }
        if n > 0 { if isError { stderrBuffer.removeFirst(n) } else { stdoutBuffer.removeFirst(n) } }
        else if n < 0 && ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) {
            if isError { stderrBroken = true; stderrBuffer.removeAll() } else { stdoutBroken = true; stdoutBuffer.removeAll() }
            beginDrain(.ioFailure)
        }
    }
    private func flushStatus() {
        guard !statusBroken, !statusQueue.isEmpty, let fd = inherited.descriptors[.status]?.value else { return }
        let data = statusQueue[0]
        let n = data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!.advanced(by:statusOffset),$0.count-statusOffset) }
        if n > 0 { statusOffset += n; if statusOffset == data.count { statusQueue.removeFirst(); statusOffset = 0 } }
        else if n < 0 && ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) {
            statusBroken = true; statusQueue.removeAll(); statusOffset = 0
            if !terminalPublished { beginDrain(.ioFailure) }
        }
    }
    private func relayTrace() {
        guard let readFD = traceRead, let destination = inherited.descriptors[.traceOutput] else { return }
        let limit = inherited.request.traceLimit
        if !traceEnded {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let n = Darwin.read(readFD.value, &bytes, bytes.count)
            if n == 0 { traceEnded = true }
            else if n < 0 {
                if ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) { beginDrain(.ioFailure) }
            } else {
                if traceCount > limit || UInt64(n) > limit - traceCount { beginDrain(.outputLimit) }
                let retained = min(UInt64(n), limit > traceCount ? limit - traceCount : 0)
                traceCount = min(limit + 1, traceCount + UInt64(n))
                if !traceBroken { traceBuffer.append(contentsOf: bytes.prefix(Int(retained))) }
            }
        }
        guard !traceBuffer.isEmpty else { return }
        let n = traceBuffer.withUnsafeBytes { Darwin.write(destination.value, $0.baseAddress, $0.count) }
        if n > 0 { traceBuffer.removeFirst(n) }
        else if n < 0 && ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) {
            traceBroken = true; traceBuffer.removeAll(); beginDrain(.ioFailure)
        }
    }
    private var targetDrained: Bool {
        if let owner { if case .reaped = owner.observation { return stdoutEnded && stderrEnded && traceEnded }; return false }
        if let anchor { return anchor.unexecutedProof() != nil && stdoutEnded && stderrEnded && traceEnded }
        return !spawned && stdoutEnded && stderrEnded && traceEnded
    }
    private func advanceStage() throws -> Bool {
        guard stage != .command, reason == .none, targetDrained,
              let owner, owner.graphRetirementPermitted,
              case .reaped(let raw) = owner.observation else { return false }
        guard now < stageBudget.work else { beginDrain(.timeout); return false }
        if stage == .systemConfiguration {
            let preflight = try journal.retireSystemConfigurationChild(owner,
                stdout: stdoutBuffer, stderr: stderrBuffer,
                streamsDrained: stdoutEnded && stderrEnded && traceEnded)
            let plan: ConfigurationPolicyPlan
            #if SHADOW_SYNC_TESTING
            if inherited.testingDiscovery, let discovery = inherited.discovery {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account,
                    testingDiscovery: discovery.input, requestID: inherited.request.binding.requestID)
            } else {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account,
                    discovery: inherited.discovery?.input,
                    requestID: inherited.discovery == nil ? nil : inherited.request.binding.requestID)
            }
            #else
            plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account,
                discovery: inherited.discovery?.input,
                requestID: inherited.discovery == nil ? nil : inherited.request.binding.requestID)
            #endif
            configurationPreflight = preflight; configurationPolicyPlan = plan
            stages = [.systemConfiguration] + Array(repeating: .policyClassification, count: plan.batches.count) + [.command]
        } else {
            guard raw == 0, let batch = configurationPolicyBatch else { throw CustodyResourceError.invalidResource }
            try batch.validate(stdout: stdoutBuffer, stderr: stderrBuffer)
            try journal.retireSerialChild(owner, streamsDrained: stdoutEnded && stderrEnded && traceEnded)
        }
        // Both paths retain the actual retired owner and exact wait status;
        // an observed PID or decoded journal cannot authorize replacement.
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode?.hasPrefix("serial-") == true {
            try testingSerialMarker("retired", targetPID: owner.identity.processID)
            if inherited.fixtureMode == "serial-between-cancel", stageIndex == 0 {
                // Pause only this fixture before the next spawn. The production
                // control transition below must observe cancellation/EOF.
                guard let control = inherited.descriptors[.control] else { throw CustodyResourceError.invalidResource }
                while now < state.budget.work {
                    var ready = pollfd(fd: control.value, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                    let value = poll(&ready, 1, 2)
                    if value > 0 { break }
                    if value < 0 && errno != EINTR { throw CustodyResourceError.invalidResource }
                }
            }
        }
        #endif
        consumeControl()
        guard reason == .none, try state.permitsResume(now: now), controlQuiescent(),
              let discoveryCommand, stageIndex + 1 < stages.count else { throw CustodyRecordError.fenced }
        let next = stages[stageIndex + 1]
        let nextBudget = try next.preflight.map {
            try inherited.request.budget.discoveryPreflight($0, command: discoveryCommand)
        } ?? inherited.request.budget
        try nextBudget.validate(kind: next.preflight?.kind ?? .discoveryGit,
            permittedWorkSeconds: next.preflight?.workSeconds ?? discoveryCommand.workSeconds, now: now)
        var nextPolicyBatch: ConfigurationPolicyBatch?, nextPolicyInput: CustodySealedResource?, nextPolicyCode: CustodySealedResource?
        if next == .policyClassification {
            guard let plan = configurationPolicyPlan else { throw CustodyResourceError.invalidResource }
            // Each response is bound to a fresh nonce, even for equal-sized
            // batches; an earlier batch cannot satisfy a later one.
            var random = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CustodyResourceError.invalidResource }
            let nonce = random.map { String(format: "%02x", $0) }.joined()
            let binding: String, policy: String, module: String
            if let authority = inherited.policy {
                try authority.revalidate()
                binding = authority.snapshot.bindingSHA256
                policy = authority.snapshot.binding.policy.sha256
                module = authority.snapshot.binding.module.sha256
            } else {
                #if SHADOW_SYNC_TESTING
                guard inherited.fixtureMode?.hasPrefix("serial-") == true else { throw CustodyResourceError.invalidResource }
                binding = String(repeating: "b", count: 64)
                policy = String(repeating: "d", count: 64)
                module = String(repeating: "e", count: 64)
                #else
                throw CustodyResourceError.invalidResource
                #endif
            }
            let batch = try plan.bind(index: stageIndex, nonce: nonce, bindingSHA256: binding,
                                      policySHA256: policy, moduleSHA256: module)
            nextPolicyBatch = batch
            nextPolicyInput = try CustodySealedResource.bytes(batch.input, role: .input, leases: journal.leases)
            if let authority = inherited.policy {
                let code = try PolicyCommandWire.resources(adapter: authority.publisher.adapter, contract: authority.publisher.contract)
                try authority.validate(input: batch.input, code: code)
                // Each interpreter receives a fresh description starting at byte
                // zero; duplicating one consumed code fd would share its offset.
                nextPolicyCode = try CustodySealedResource.bytes(code, role: .code, leases: journal.leases)
            }
            #if SHADOW_SYNC_TESTING
            if inherited.fixtureMode == "serial-policy-code-batches" {
                nextPolicyCode = try CustodySealedResource.bytes(Data("shadow-sync-fixture-policy-code-offset-zero\n".utf8),
                                                                role: .code, leases: journal.leases)
            }
            #endif
        }
        if next == .command, let discovery = inherited.discovery {
            guard let preflight = configurationPreflight else { throw CustodyResourceError.invalidResource }
            try discovery.admit(preflight: preflight, journal: journal) { [weak self] in
                guard let self else { throw CustodyRecordError.fenced }
                self.consumeControl()
                guard self.reason == .none, try self.state.permitsResume(now: self.now),
                      self.controlQuiescent(), self.now < self.state.budget.work else { throw CustodyRecordError.fenced }
                try self.inherited.revalidateParent()
                try self.inherited.policy?.revalidate()
                try self.journal.leases.validate()
            }
        }
        let nextTarget = try CustodianTarget(inherited, stage: next)
        // No predecessor resources are dropped until its graph, pipes and exact
        // wait have converged. Existing leases and original timeline stay held.
        stdoutRead?.closeNow(); stderrRead?.closeNow(); traceRead?.closeNow()
        self.owner = nil; anchor = nil; stdoutRead = nil; stderrRead = nil; traceRead = nil
        stdoutBuffer.removeAll(); stderrBuffer.removeAll(); traceBuffer.removeAll()
        stdoutCount = 0; stderrCount = 0; traceCount = 0
        stdoutEnded = true; stderrEnded = true; traceEnded = true
        stdoutBroken = false; stderrBroken = false; traceBroken = false
        spawned = false; resumed = false; sentTerm = false; sentKill = false
        stageIndex += 1; stageBudget = nextBudget; target = nextTarget
        configurationPolicyBatch = nextPolicyBatch; configurationPolicyInput = nextPolicyInput; configurationPolicyCode = nextPolicyCode
        #if SHADOW_SYNC_TESTING
        serialReadyPublished = false
        #endif
        return true
    }
    func run() throws -> Int32 {
        try status(.ready)
        while true {
            if !terminalPublished {
                consumeControl()
                if now >= min(state.budget.work, stageBudget.work) && state.phase != .draining { beginDrain(.timeout) }
                if state.phase == .admitted && !spawned && reason == .none {
                    do { try spawnTarget() }
                    catch { beginDrain(reason == .none ? .invalidResource : reason) }
                }
                relay(false); relay(true); relayTrace(); drainTarget()
                if targetDrained, stage != .command, reason == .none, spawned {
                    do { if try advanceStage() { continue } }
                    catch { beginDrain(reason == .none ? .invalidResource : reason) }
                }
                if stage != .command && reason != .none && targetDrained {
                    // Refused preflight data is not final-command output.
                    stdoutBuffer.removeAll(); stderrBuffer.removeAll(); traceBuffer.removeAll()
                }
                if targetDrained && (state.phase == .draining || spawned) {
                    // EOF is independent of buffered delivery. Do not claim full
                    // output if the caller stopped reading while still alive.
                    if stdoutBuffer.isEmpty && stderrBuffer.isEmpty && traceBuffer.isEmpty {
                        do {
                            if reason == .none, !discoveryPostflightComplete, stage == .command, let discovery = inherited.discovery {
                                // A later control-frame retry must not demand
                                // the frozen files after their verified removal.
                                do { try discovery.revalidate(); discoveryPostflightComplete = true }
                                catch { beginDrain(.invalidResource) }
                            }
                            #if SHADOW_SYNC_TESTING
                            if reason == .none, inherited.fixtureMode?.hasPrefix("serial-postflight-") == true {
                                guard let control = inherited.descriptors[.control], let owner else { throw CustodyResourceError.invalidResource }
                                try testingSerialMarker("postflight", targetPID: owner.identity.processID)
                                // The actual final child has already reaped/EOF.
                                // Hold only this fixture's postflight to exercise
                                // the shared terminal transition after it returns.
                                while now < state.budget.work {
                                    var descriptor = pollfd(fd: control.value, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                                    let result = poll(&descriptor, 1, 2)
                                    if result > 0 { break }
                                    if result < 0 && errno != EINTR { throw CustodyResourceError.invalidResource }
                                }
                            }
                            #endif
                            do {
                                try journal.retireDiscoveryResource(owner: owner, unexecuted: anchor?.unexecutedProof(),
                                    noSuccessfulSpawn: !spawned, reason: reason, streamsDrained: targetDrained)
                            } catch {
                                // Close admission and report pending on the existing
                                // budget. Keep the resource owner and leases alive.
                                beginDrain(.ioFailure); throw error
                            }
                            // Postflight can perform bounded filesystem/security
                            // work. Observe cancellation/EOF and the ORIGINAL
                            // deadline again before selecting a terminal result.
                            if reason == .none && now >= inherited.request.budget.work { beginDrain(.timeout) }
                            consumeControl()
                            if reason == .none && now >= inherited.request.budget.work { beginDrain(.timeout) }
                            if reason == .none && !controlQuiescent() { continue }
                            let terminal = try journal.terminal(owner:owner,unexecuted:anchor?.unexecutedProof(),
                                noSuccessfulSpawn:!spawned,reason:reason,admitted:state.admitted)
                            // The commit is final even if notification fails or
                            // crosses the work deadline. Never advance it again.
                            terminalPublished = true
                            #if SHADOW_SYNC_TESTING
                            if inherited.fixtureMode == "terminal-delay" {
                                while now < inherited.request.budget.work + 50_000_000 { usleep(1_000) }
                            }
                            #endif
                            terminalTime = now
                            do { try status(.terminal,terminal:terminal) }
                            catch { return 74 }
                        } catch { persistenceFailed = true }
                    }
                }
                if state.phase == .draining && now >= min(state.budget.kill, stageBudget.kill) && !sentPending {
                    sentPending = true
                    do { try journal.pending(reason:reason == .none ? .ownershipLost : reason); try status(.pending) }
                    catch { persistenceFailed = true }
                }
            }
            flushStatus()
            if terminalPublished {
                if statusQueue.isEmpty || statusBroken { return 0 }
                // Terminal is already durable and no child remains. A bounded
                // delivery failure leaves caller retirement fenced, not success.
                if let terminalTime, now-terminalTime > 1_000_000_000 { return 74 }
            }
            // Persistence/ownership failure retains this responsible custodian
            // and the journal; no timeout is translated into successful cleanup.
            usleep(sentPending || persistenceFailed ? 50_000 : 5_000)
        }
    }
}
