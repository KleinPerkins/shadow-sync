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
    /// Invoked only by the bundled coordinator before normal CLI dispatch. The
    /// same signed executable is both caller and custodian, retaining exact
    /// parent path/CDHash checks without broadening application bootstrap.
    static func dispatchLifecycle(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--shadow-sync-command-custodian") else { return nil }
        guard arguments.count == 2, arguments[1] == "--shadow-sync-command-custodian" else { return 64 }
        #if SHADOW_SYNC_TESTING
        return 70
        #else
        do { return try CustodianLoop(inherited: CustodyInheritedCommand.lifecycle()).run() }
        catch { return 70 }
        #endif
    }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    static func dispatchSignedInstallation(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--shadow-sync-signed-installation-custodian") else { return nil }
        guard arguments.count == 2, arguments[1] == "--shadow-sync-signed-installation-custodian" else { return 64 }
        do { return try CustodianLoop(inherited: CustodyInheritedCommand.signedInstallation()).run() }
        catch { return 70 }
    }
    #endif
    #if SHADOW_SYNC_TESTING
    public static func testingDispatch(_ arguments: [String]) -> Int32? {
        if arguments.count == 4, arguments[1] == "--shadow-sync-repository-git-worker-fixture" {
            return DiscoveryCallerSelfTestRunner.repositoryWorker(root: arguments[2], phase: arguments[3])
        }
        if arguments.count == 2 && arguments[1] == "--shadow-sync-discovery-custodian-fixture" {
            // Closed testing-only constructor discrimination; no protocol output.
            CustodyInheritedCommand.testingRecordConstructionStage(.helper)
            var failureCode: Int32 = 81
            do {
                let inherited = try CustodyInheritedCommand.testingDiscovery()
                failureCode = 82
                let loop = try CustodianLoop(inherited: inherited)
                failureCode = 83
                return try loop.run()
            } catch {
                return failureCode == 81 ? CustodyInheritedCommand.testingConstructionFailureCode : failureCode
            }
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
        guard ["installation-absent","installation-loaded","installation-foreign","complete","fail","wait","resist","overflow","after-admit","before-resume","after-preparation","terminal-delay",
               "trace-complete","trace-overflow","trace-resist","policy-echo","policy-resist",
                    "system-complete","system-missing","system-faildata","system-resist","system-overflow",
               "config-complete","config-resist-sigterm-fixture", "system-multiple-policy-batches", "classification-allow", "classification-protected", "classification-malformed", "classification-nonce", "classification-binding", "classification-code-allow", "lifecycle-absent", "lifecycle-loaded", "lifecycle-empty", "lifecycle-foreign"].contains(mode) else { return 64 }
        if mode == "resist" || mode == "trace-resist" || mode == "policy-resist" || mode == "system-resist" || mode == "config-resist-sigterm-fixture" { signal(SIGTERM, SIG_IGN) }
        if mode.hasPrefix("lifecycle-") {
            guard let home = ProcessInfo.processInfo.environment["HOME"],
                  let account = try? EffectiveAccount.isolated(homeDirectory: home), fcntl(198, F_GETFD) >= 0 else { return 75 }
            let command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
            if mode == "lifecycle-empty" { return 0 }
            let data = mode == "lifecycle-loaded" ? command.fixtureLoadedOutput : mode == "lifecycle-foreign"
                ? Data("Bad request.\nCould not find service \"com.example.foreign\" in domain for user gui: \(account.uid)\n".utf8)
                : command.fixtureAbsentError
            guard data.withUnsafeBytes({ Darwin.write(mode == "lifecycle-loaded" ? 1 : 2, $0.baseAddress, $0.count) }) == data.count else { return 74 }
            return mode == "lifecycle-loaded" ? 0 : 113
        }
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
        if mode == "installation-loaded" || mode == "installation-foreign" {
            guard let home = ProcessInfo.processInfo.environment["HOME"],
                  let account = try? EffectiveAccount.isolated(homeDirectory: home), fcntl(198, F_GETFD) >= 0 else { return 75 }
            let command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
            let bytes = mode == "installation-loaded" ? command.fixtureLoadedOutput
                : Data("foreign service diagnostic\n".utf8)
            guard bytes.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == bytes.count else { return 74 }
            return 0
        }
        if mode == "installation-absent" {
            let bytes = Data("Bad request.\nCould not find service \"\(InstallationPaths.label)\" in domain for user gui: \(geteuid())\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress!, $0.count) }
            return 113
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
    case repositoryProbe(Int)
    case lifecyclePreflight, lifecycleMutation, lifecyclePostflight
    var isIntermediate: Bool { self != .command && self != .lifecyclePostflight }
    var usesRepository: Bool { if case .repositoryProbe = self { return true }; return self == .command }
    #if SHADOW_SYNC_TESTING
    var repositoryFixturePhase: String? {
        switch self {
        case .systemConfiguration: "system"
        case .policyClassification: "policy"
        case .repositoryProbe(let index): ["root", "origin", "transport"].indices.contains(index) ? ["root", "origin", "transport"][index] : nil
        case .command: "command"
        default: nil
        }
    }
    #endif
    var preflight: DiscoveryGitCommand.Preflight? {
        switch self {
        case .systemConfiguration: .systemConfiguration
        case .policyClassification: .policyClassification
        case .command, .repositoryProbe, .lifecyclePreflight, .lifecycleMutation, .lifecyclePostflight: nil
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
            if let command = inherited.lifecycleCommand {
                switch stage {
                case .lifecyclePreflight:
                    targetMode = mode == "lifecycle-preflight-overflow" ? "overflow" : mode == "lifecycle-preflight-cancel" ? "resist" : mode == "lifecycle-preflight-foreign" ? "lifecycle-foreign"
                        : command.operation == .bootstrap ? "lifecycle-absent" : "lifecycle-loaded"
                case .lifecycleMutation:
                    targetMode = mode == "lifecycle-mutation-cancel" ? "resist" : mode == "lifecycle-mutation-failure" ? "fail" : "lifecycle-empty"
                case .lifecyclePostflight:
                    targetMode = mode == "lifecycle-postflight-overflow" ? "overflow" : ["lifecycle-postflight-cancel", "lifecycle-postflight-timeout"].contains(mode) ? "resist"
                        : command.operation == .bootout || mode == "lifecycle-postflight-absent" ? "lifecycle-absent" : "lifecycle-loaded"
                default: throw CustodyResourceError.invalidResource
                }
            } else if mode.hasPrefix("serial-") {
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
                case .repositoryProbe, .lifecyclePreflight, .lifecycleMutation, .lifecyclePostflight:
                    throw CustodyResourceError.invalidResource
                case .command:
                    targetMode = mode == "serial-command-cancel" ? "resist" : "complete"
                }
            } else if ["state-capture-named", "state-capture-unlinked"].contains(mode) { targetMode = "complete" }
            else { targetMode = mode == "deadline-before-control" ? "resist" : mode }
            arguments = [path, "--shadow-sync-custodian-target-fixture", targetMode]
            fixtureSnapshot = try PublisherExecutableSnapshot.capture(path: path, owner: geteuid())
            graph = nil; environment = inherited.request.environment; return
        }
        #endif
        let qualified: QualifiedCommandGraph
        let args: [String]
        if let lifecycle = inherited.lifecycle {
            try lifecycle.revalidate()
            switch stage {
            case .lifecyclePreflight, .lifecyclePostflight:
                qualified = lifecycle.readGraph; args = lifecycle.command.printArguments
            case .lifecycleMutation:
                qualified = lifecycle.mutationGraph; args = lifecycle.command.arguments
            default: throw CustodyResourceError.invalidResource
            }
            environment = inherited.request.environment
        } else if let repository = inherited.repository {
            try repository.revalidate()
            switch stage {
            case .systemConfiguration:
                qualified = repository.systemGraph; args = SystemGitConfigurationCommand.arguments
                var values = SystemGitConfigurationCommand.environment(account: inherited.account)
                #if SHADOW_SYNC_TESTING
                if inherited.testingDiscovery {
                    values["GIT_CONFIG_SYSTEM"] = try DiscoveryFixtureResources.systemConfiguration(home: inherited.account.homeDirectory)
                }
                #endif
                environment = values
            case .policyClassification:
                qualified = repository.policy.graph; args = PolicyCommandWire.interpreterArguments
                environment = ClosedProcessRunner.environment(account: inherited.account)
            case .repositoryProbe(let index):
                try repository.validateBeforeTarget()
                qualified = repository.gitGraph; args = try repository.probeArguments(index)
                environment = try repository.input.environment(account: inherited.account)
            case .command:
                try repository.validateBeforeTarget()
                qualified = repository.gitGraph; args = repository.arguments
                environment = try repository.input.environment(account: inherited.account)
            default: throw CustodyResourceError.invalidResource
            }
        } else if let retention = inherited.retention {
            try retention.revalidate()
            switch stage {
            case .systemConfiguration:
                qualified = retention.systemGraph; args = SystemGitConfigurationCommand.arguments
                var values = SystemGitConfigurationCommand.environment(account: inherited.account)
                #if SHADOW_SYNC_TESTING
                if inherited.testingDiscovery { values["GIT_CONFIG_SYSTEM"] = try DiscoveryFixtureResources.systemConfiguration(home: inherited.account.homeDirectory) }
                #endif
                environment = values
            case .policyClassification:
                qualified = retention.policy.graph; args = PolicyCommandWire.interpreterArguments
                environment = ClosedProcessRunner.environment(account: inherited.account)
            case .command:
                guard retention.cwd != nil, retention.frozen != nil else { throw CustodyResourceError.invalidResource }
                qualified = retention.archiveGraph; args = inherited.request.arguments
                environment = retention.input.environment(account: inherited.account)
            default: throw CustodyResourceError.invalidResource
            }
        } else if let discovery = inherited.discovery {
            try discovery.revalidate()
            switch stage {
            case .repositoryProbe, .lifecyclePreflight, .lifecycleMutation, .lifecyclePostflight:
                throw CustodyResourceError.invalidResource
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
                qualified = try QualifiedCommandGraph.forHelper(kind: inherited.request.kind, helper: inherited.helper)
                args = inherited.request.arguments
            }
            var values = inherited.request.environment
            #if SHADOW_SYNC_TESTING
            if inherited.testingDiscovery, inherited.request.kind == .systemGitConfig {
                values["GIT_CONFIG_SYSTEM"] = try DiscoveryFixtureResources.systemConfiguration(home: inherited.account.homeDirectory)
            }
            #endif
            environment = values
        }
        graph = qualified; path = qualified.entryPath
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case .signedFixture = inherited.helper.validationProfile {
            guard inherited.signedAdapter != nil else { throw CustodyRecordError.fenced }
            let operation: SignedInstallationFixtureAdapterChannel.Operation
            switch stage {
            case .lifecyclePreflight, .lifecyclePostflight: operation = .printState
            case .lifecycleMutation:
                guard let command = inherited.lifecycleCommand,
                      let value = SignedInstallationFixtureAdapterChannel.Operation(rawValue: command.operation.rawValue) else { throw CustodyRecordError.fenced }
                operation = value
            case .command:
                guard inherited.request.kind == .launchctlRead || inherited.request.kind == .signatureCheck else { throw CustodyRecordError.fenced }
                operation = inherited.request.kind == .launchctlRead ? .printState : .signature
            default: throw CustodyRecordError.fenced
            }
            arguments = [path, "--shadow-sync-signed-installation-adapter", operation.rawValue]
        } else { arguments = [path] + args }
        #else
        arguments = [path] + args
        #endif
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
    private var testingFailureWitness: TestingCustodianFailureWitness?
    private var testingRepositoryFailureEmitted = false
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
    private var lifecyclePostflightComplete = false
    private var lifecyclePreflightState: LaunchAgentState?

    init(inherited: CustodyInheritedCommand) throws {
        self.inherited = inherited
        journal = try CustodyHelperJournal.begin(inherited)
        #if SHADOW_SYNC_TESTING
        inherited.testingPolicyTiming?.mark(.journalClaimFinished)
        #endif
        var serial = inherited.discovery != nil || inherited.retention != nil || inherited.repository != nil
        #if SHADOW_SYNC_TESTING
        serial = serial || inherited.fixtureMode?.hasPrefix("serial-") == true
        #endif
        stages = inherited.lifecycleCommand != nil ? [.lifecyclePreflight, .lifecycleMutation, .lifecyclePostflight]
            : (serial ? [.systemConfiguration, .policyClassification, .command] : [.command])
        discoveryCommand = try inherited.discovery?.command ?? (serial ? DiscoveryGitCommand(
            arguments: ["--no-replace-objects", "--no-lazy-fetch", "symbolic-ref", "--quiet", "--short", "HEAD"],
            captureTransportConfiguration: false, timeoutSeconds: DiscoveryGitCommand.maximumWorkSeconds) : nil)
        stageBudget = try inherited.repository != nil
            ? inherited.request.budget.repositoryPreflight(.systemConfiguration)
            : discoveryCommand.map { try inherited.retention != nil ? inherited.request.budget.retentionPreflight(.systemConfiguration)
                : inherited.request.budget.discoveryPreflight(.systemConfiguration, command: $0) }
                ?? inherited.request.budget
        target = try CustodianTarget(inherited, stage: stages[0])
        state = try CustodyAdmissionState(binding: inherited.request.binding, budget: inherited.request.budget)
        #if SHADOW_SYNC_TESTING
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        if inherited.testingPolicyTiming != nil || (inherited.testingDiscovery && inherited.request.kind == .repositoryGit
            && inherited.repository?.input.testingPausePhase != nil
            && inherited.repository?.input.testingPausePhase != "observe") {
            testingFailureWitness = try? TestingCustodianFailureWitness(
                home: inherited.account.homeDirectory, binding: journal.current.binding)
        }
        #endif
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
        #if SHADOW_SYNC_TESTING
        let firstTimeout = reason == .none && cause == .timeout
        #endif
        if reason == .none { reason = cause }
        #if SHADOW_SYNC_TESTING
        if firstTimeout, inherited.testingPolicyTiming != nil { testingObserveFailure(.policyTimingFailure, error: nil) }
        #endif
        if state.phase != .terminal { try? state.closeAdmission(now: now) }
        if let clipped = try? stageBudget.draining(at: now) { stageBudget = clipped }
        do { try journal.draining(reason: reason) }
        catch {
            persistenceFailed = true
            #if SHADOW_SYNC_TESTING
            testingObserveFailure(.drainingPersistence, error: error)
            #endif
        }
    }
    #if SHADOW_SYNC_TESTING
    private var testingExpiredControlObserved = false
    private var testingRepositoryBusy = DiscoveryFixtureDiagnostic.RepositoryBusyObservation.Snapshot()
    private func testingObserveFailure(_ event: TestingCustodianFailureWitness.Event, error: Error?) {
        let savedErrno = errno
        defer { errno = savedErrno }
        guard event.observes(after: reason) else { return }
        // Explicit closed fixture mode observes one actual throw without creating
        // a witness file, pausing a child, or changing its failure/drain path.
        if inherited.testingDiscovery, inherited.request.kind == .repositoryGit,
           inherited.repository?.input.testingPausePhase == "observe", !testingRepositoryFailureEmitted,
           [TestingCustodianFailureWitness.Event.spawnTargetFailure, .advanceStageFailure,
            .repositoryPostflightFailure].contains(event) {
            testingRepositoryFailureEmitted = true
            let family = TestingCustodianFailureWitness.errorFields(error)["error"] as? String ?? "other"
            let detail = event == .spawnTargetFailure && family == "busy"
                ? testingRepositoryBusy : DiscoveryFixtureDiagnostic.RepositoryBusyObservation.Snapshot()
            fputs("DISCOVERY REPOSITORY CUSTODIAN FIRST FAILURE event=\(event.rawValue) error=\(family)"
                + " transition=\(detail.transition.rawValue) busy_site=\(detail.site.rawValue)\n", stderr)
            fflush(stderr)
        }
        guard let witness = testingFailureWitness else { return }
        if let timing = inherited.testingPolicyTiming {
            // EOF and expected cancellation never consume the actual failure slot.
            guard event != .controlEOF, event != .pendingBoundary else { return }
            var fields = timing.snapshot().fields
            fields["event"] = TestingCustodianFailureWitness.Event.policyTimingFailure.rawValue
            fields["trigger"] = event.rawValue
            fields["reason"] = reason.rawValue
            fields["observed"] = now
            fields["issued"] = inherited.request.budget.issued
            fields["work"] = inherited.request.budget.work
            witness.record(.policyTimingFailure, fields: fields)
            return
        }
        var fields: [String: Any] = [
            "event": event.rawValue, "stage_index": stageIndex,
            "stage": stage.repositoryFixturePhase ?? "other", "reason": reason.rawValue,
            "command_kind": inherited.request.kind.rawValue,
            "journal_phase": journal.current.phase.rawValue, "journal_ordinal": journal.current.ordinal,
            "terminal_stage": journal.testingTerminalStage.rawValue,
            "control_ended": controlEnded, "status_broken": statusBroken,
            "persistence_failed": persistenceFailed, "spawned": spawned, "resumed": resumed,
            "target_drained": targetDrained, "stdout_eof": stdoutEnded, "stderr_eof": stderrEnded,
            "trace_eof": traceEnded, "stdout_broken": stdoutBroken, "stderr_broken": stderrBroken,
            "trace_broken": traceBroken, "stdout_empty": stdoutBuffer.isEmpty,
            "stderr_empty": stderrBuffer.isEmpty, "trace_empty": traceBuffer.isEmpty,
            "uptime": now, "issued": inherited.request.budget.issued,
            "work": inherited.request.budget.work, "term": inherited.request.budget.term,
            "kill": inherited.request.budget.kill, "receipt": inherited.request.budget.receipt,
        ]
        if let owner {
            switch owner.observation {
            case .running: fields["owner"] = "running"
            case .reaped(let status): fields["owner"] = "reaped"; fields["owner_value"] = status
            case .ownershipFailure(let value): fields["owner"] = "ownership-failure"; fields["owner_value"] = value
            }
            fields["graph_retirement_permitted"] = owner.graphRetirementPermitted
            fields["graph_fault"] = owner.hasGraphFault
            fields["terminal_held"] = owner.terminalStatusHeld != nil
            fields["recorded_owner_matches"] = journal.testingRecordedOwnerMatches(owner)
            fields["durable_target_matches"] = (try? CustodyProcessObservation(owner.identity)) == journal.current.target
        } else { fields["owner"] = "absent" }
        for (key, value) in TestingCustodianFailureWitness.errorFields(error) { fields[key] = value }
        // Snapshot-only owner reads above release their mutexes before file I/O.
        // Diagnostic failure cannot change cancellation, persistence or drainage.
        witness.record(event, fields: fields)
    }
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
                #if SHADOW_SYNC_TESTING
                let testingTrueLoss = reason == .none
                let testingEOFUptime = now
                #endif
                do { try decoder.finish() } catch { beginDrain(.protocolFault) }
                #if SHADOW_SYNC_TESTING
                let testingCleanEOF = testingTrueLoss && reason == .none
                #endif
                beginDrain(.cancelled)
                #if SHADOW_SYNC_TESTING
                // Independent EOF slot: expected cancellation cannot hide the
                // first later retirement/persistence refusal.
                testingObserveFailure(.controlEOF, error: nil)
                if testingCleanEOF, inherited.testingDiscovery, stage == .command, resumed,
                   let retention = inherited.retention, retention.input.testingPauseAfterResume,
                   !retention.input.testingPauseBeforeResume, let owner {
                    // Only the actual zero-byte read reaches this seam. HUP,
                    // errors, partial/cancel frames and terminal-held targets
                    // never manufacture positive evidence. A failed sample must
                    // not interrupt the ordinary cancellation/drain transition.
                    do {
                        try retention.testingPublishEOF(request: inherited.request, worker: inherited.parent,
                            helper: inherited.identity, owner: owner, controlFD: fd, eofUptime: testingEOFUptime,
                            before: min(stageBudget.term, inherited.request.budget.term))
                    } catch { /* Missing/invalid witness fails the enclosing fixture. */ }
                }
                #endif
                return
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
                    #if SHADOW_SYNC_TESTING
                    if message.event == .admit { inherited.testingPolicyTiming?.mark(.admitConsumed) }
                    #endif
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
        if stageIndex == 1, ["serial-next-before-spawn", "serial-system-missing-next-before-spawn", "lifecycle-next-before-spawn"].contains(inherited.fixtureMode ?? "") { throw CustodyResourceError.invalidResource }
        #endif
        if journal.current.phase == .prepared {
            #if SHADOW_SYNC_TESTING
            DiscoveryFixtureDiagnostic.RepositoryBusyObservation.transition(.admit)
            #endif
            try journal.admit(deadline: min(state.budget.work, stageBudget.work)) { [self] in
                consumeControl()
                // The original full resource validation above remains intact.
                // Recheck persistence/lease claims without recursively acquiring
                // the catalog guard while another helper owns it.
                try inherited.revalidatePersistenceResources(); try journal.leases.validate()
                guard reason == .none, try state.permitsResume(now: now), controlQuiescent(),
                      now < stageBudget.work else { throw CustodyRecordError.fenced }
            }
            #if SHADOW_SYNC_TESTING
            DiscoveryFixtureDiagnostic.RepositoryBusyObservation.transition(.none)
            #endif
        }
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode == "after-admit" { usleep(200_000) }
        #endif
        consumeControl()
        guard try state.permitsResume(now: now), controlQuiescent() else { throw CustodyRecordError.fenced }
        if inherited.repository != nil, stage.usesRepository {
            try inherited.repository?.validateBeforeTarget()
        }
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
              let cwd = ((stage.usesRepository)
                ? inherited.repository?.root ?? (inherited.retention?.cwd ?? inherited.discovery?.root) : nil) ?? inherited.descriptors[.workingDirectory], posix_spawn_file_actions_addfchdir(&actions,cwd.value) == 0 else { throw CustodyResourceError.invalidResource }
        let policyInputView = try stage == .policyClassification ? configurationPolicyInput?.duplicateReadOnly() : nil
        let policyCodeView = try stage == .policyClassification ? configurationPolicyCode?.duplicateReadOnly() : nil
        defer { policyInputView?.closeNow(); policyCodeView?.closeNow() }
        if stage == .policyClassification {
            guard let policyInputView,
                  posix_spawn_file_actions_adddup2(&actions, policyInputView.value, 0) == 0 else { throw CustodyResourceError.invalidResource }
            if let policyCodeView {
                guard posix_spawn_file_actions_adddup2(&actions, policyCodeView.value, 9) == 0 else { throw CustodyResourceError.invalidResource }
            } else if inherited.discovery != nil || inherited.repository != nil || inherited.retention != nil { throw CustodyResourceError.invalidResource }
        }
        if inherited.request.kind == .policyClassify {
            guard let input = inherited.descriptors[.input], let code = inherited.descriptors[.code],
                  posix_spawn_file_actions_adddup2(&actions, input.value, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, code.value, 9) == 0 else {
                throw CustodyResourceError.invalidResource
            }
        }
        let repositoryConfigView = try stage.usesRepository ? inherited.repository?.frozen?.openTargetReadOnly() : nil
        defer { repositoryConfigView?.closeNow() }
        if inherited.repository != nil, stage.usesRepository {
            guard let repositoryConfigView,
                  posix_spawn_file_actions_adddup2(&actions, repositoryConfigView.value, 196) == 0 else { throw CustodyResourceError.invalidResource }
        } else if stage == .command, let frozen = inherited.discovery?.frozen {
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
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        try inherited.signedAdapter?.appendTargetMapping(&actions)
        #endif
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
        if stageIndex == 1, ["serial-next-after-spawn", "serial-system-missing-next-after-spawn", "lifecycle-next-after-spawn"].contains(inherited.fixtureMode ?? "") { throw CustodyResourceError.invalidResource }
        #endif
        try target.validate(anchor)
        owner = try anchor.transfer(expectedExecutable:target.path,generation:inherited.request.binding.callerGeneration,reapPolicy:.afterGroupDrain,qualifiedGraph:target.graph)
        #if SHADOW_SYNC_TESTING
        if stageIndex == 1, ["serial-next-before-record", "serial-system-missing-next-before-record", "lifecycle-next-before-record"].contains(inherited.fixtureMode ?? "") { throw CustodyResourceError.invalidResource }
        #endif
        #if SHADOW_SYNC_TESTING
        DiscoveryFixtureDiagnostic.RepositoryBusyObservation.transition(.executing)
        #endif
        try journal.executing(owner!)
        #if SHADOW_SYNC_TESTING
        DiscoveryFixtureDiagnostic.RepositoryBusyObservation.transition(.none)
        #endif
        if stage == .lifecycleMutation {
            guard let command = inherited.lifecycleCommand, let preflight = lifecyclePreflightState else { throw CustodyRecordError.fenced }
            try command.validatePreflight(preflight)
        }
        try inherited.revalidateResources(); try inherited.revalidateParent(); try target.validate(anchor)
        #if SHADOW_SYNC_TESTING
        inherited.testingPolicyTiming?.mark(.suspendedVerificationFinished)
        #endif
        guard owner!.prepareGraphSignal() == .ready else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        if inherited.retention?.input.testingPauseBeforeResume == true, stage == .command { try testingAwaitFinalControl() }
        if inherited.fixtureMode == "before-resume" { usleep(200_000) }
        if inherited.fixtureMode == "after-preparation" { try testingAwaitFinalControl() }
        #endif
        if let repository = inherited.repository, stage.usesRepository {
            try repository.validateBeforeTarget()
        }
        // The same serialized loop observes all available cancellation/EOF and
        // enters the final resume transition; no queue callback can race it.
        consumeControl()
        guard try state.permitsResume(now:now), controlQuiescent(),
              now < stageBudget.work,
              owner!.resume(before: MonotonicDeadline(uptimeNanoseconds: min(state.budget.work, stageBudget.work))) else { throw CustodyRecordError.fenced }
        resumed = true
        #if SHADOW_SYNC_TESTING
        inherited.testingPolicyTiming?.mark(.resumed)
        if inherited.retention?.input.testingPauseAfterResume == true, stage == .command { try testingAwaitFinalControl() }
        if let phase = stage.repositoryFixturePhase { try testingRepositoryPause(phase) }

        if inherited.fixtureMode?.hasPrefix("serial-") == true || inherited.lifecycleCommand != nil {
            try testingSerialMarker("resumed", targetPID: owner!.identity.processID)
        }
        #endif
    }
    #if SHADOW_SYNC_TESTING
    /// This fixture publishes the actual final-preparation boundary and waits
    /// for the existing control channel to become readable. It neither consumes
    /// control nor changes admission: the production transition below must do
    /// both. The original suspended child remains owned throughout the pause.
    private func testingRepositoryPause(_ phase: String) throws {
        guard inherited.testingDiscovery, inherited.repository?.input.testingPausePhase == phase else { return }
        guard let control = inherited.descriptors[.control] else { throw CustodyResourceError.invalidResource }
        let bytes = Data(("shadow-sync-fixture-repository-phase:" + phase + "\n").utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(inherited.error.value, $0.baseAddress, $0.count) }) == bytes.count else {
            throw CustodyResourceError.invalidResource
        }
        while now < state.budget.work {
            var item = pollfd(fd: control.value, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let value = poll(&item, 1, 2)
            if value > 0 { return }
            if value < 0 && errno != EINTR { throw CustodyResourceError.invalidResource }
        }
        throw CustodyProtocolError.invalidBudget
    }
    private func testingSerialMarker(_ event: String, targetPID: pid_t) throws {
        // Optional owner-private disposable-fixture output mode. The same three
        // actual children and custody checks run; only test telemetry is quiet.
        if inherited.request.authority.isInstallationStaged {
            let path = inherited.account.homeDirectory + "/.staged-completion-quiet"
            var info = stat()
            if lstat(path, &info) == 0 {
                let marker = try PolicyAuthorityFile.read(path: path, owner: inherited.account.uid, maximumBytes: 32)
                guard marker.bytes == Data("staged-completion-quiet/v1\n".utf8),
                      info.st_mode == S_IFREG | 0o600 else { throw CustodyRecordError.fenced }
                return
            }
            guard errno == ENOENT else { throw CustodyRecordError.fenced }
        }
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
        if !isError, inherited.fixtureMode?.hasPrefix("serial-") == true || inherited.lifecycleCommand != nil,
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
        guard stage == .command || (stage == .lifecyclePostflight && lifecyclePostflightComplete) else { return }
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
        guard stage.isIntermediate, reason == .none, targetDrained,
              let owner, owner.graphRetirementPermitted,
              case .reaped(let raw) = owner.observation else { return false }
        guard now < stageBudget.work else { beginDrain(.timeout); return false }
        if let command = inherited.lifecycleCommand {
            if stage == .lifecyclePreflight {
                lifecyclePreflightState = try journal.retireLifecyclePreflightChild(owner,
                    stdout: stdoutBuffer, stderr: stderrBuffer, streamsDrained: targetDrained)
            } else {
                guard stage == .lifecycleMutation, raw == 0, stdoutBuffer.isEmpty, stderrBuffer.isEmpty else {
                    throw CustodyResourceError.invalidResource
                }
                try journal.retireSerialChild(owner, streamsDrained: targetDrained)
            }
            #if SHADOW_SYNC_TESTING
            if inherited.fixtureMode != nil {
                try testingSerialMarker("retired", targetPID: owner.identity.processID)
                if inherited.fixtureMode == "lifecycle-between-cancel", stageIndex == 0 {
                    guard let control = inherited.descriptors[.control] else { throw CustodyResourceError.invalidResource }
                    while now < state.budget.work {
                        var ready = pollfd(fd: control.value, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                        if poll(&ready, 1, 2) > 0 { break }
                    }
                }
            }
            #endif
            consumeControl()
            guard reason == .none, try state.permitsResume(now: now), controlQuiescent(),
                  stageIndex + 1 < stages.count else { throw CustodyRecordError.fenced }
            try inherited.request.budget.validate(kind: .launchctlMutation, permittedWorkSeconds: 10, now: now)
            if stage == .lifecyclePreflight { try command.validatePreflight(lifecyclePreflightState!) }
            let next = try CustodianTarget(inherited, stage: stages[stageIndex + 1])
            replaceRetiredTarget(next, budget: inherited.request.budget)
            return true
        }
        if case .repositoryProbe(let index) = stage {
            try journal.retireRepositoryProbe(owner, index: index, stdout: stdoutBuffer, stderr: stderrBuffer,
                streamsDrained: targetDrained)
        } else if stage == .systemConfiguration {
            let preflight = try journal.retireSystemConfigurationChild(owner,
                stdout: stdoutBuffer, stderr: stderrBuffer,
                streamsDrained: stdoutEnded && stderrEnded && traceEnded)
            let plan: ConfigurationPolicyPlan
            if let repository = inherited.repository {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account, repository: repository.input)
            } else {
            #if SHADOW_SYNC_TESTING
            if let retention = inherited.retention {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account, retention: retention.input)
            } else if inherited.testingDiscovery, let discovery = inherited.discovery {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account,
                    testingDiscovery: discovery.input, requestID: inherited.request.binding.requestID)
            } else {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account,
                    discovery: inherited.discovery?.input,
                    requestID: inherited.discovery == nil ? nil : inherited.request.binding.requestID)
            }
            #else
            if let retention = inherited.retention {
                plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account, retention: retention.input)
            } else {
            plan = try ConfigurationPolicyPlan(preflight: preflight, account: inherited.account,
                discovery: inherited.discovery?.input,
                requestID: inherited.discovery == nil ? nil : inherited.request.binding.requestID)
            }
            #endif
            }
            configurationPreflight = preflight; configurationPolicyPlan = plan
            let probes = (0..<(inherited.repository?.probeCount ?? 0)).map { CustodianStage.repositoryProbe($0) }
            stages = [.systemConfiguration] + Array(repeating: .policyClassification, count: plan.batches.count) + probes + [.command]
        } else {
            guard raw == 0, let batch = configurationPolicyBatch else { throw CustodyResourceError.invalidResource }
            try batch.validate(stdout: stdoutBuffer, stderr: stderrBuffer)
            try journal.retireSerialChild(owner, streamsDrained: stdoutEnded && stderrEnded && traceEnded)
        }
        // Both paths retain the actual retired owner and exact wait status;
        // an observed PID or decoded journal cannot authorize replacement.
        #if SHADOW_SYNC_TESTING
        if inherited.fixtureMode?.hasPrefix("serial-") == true || inherited.lifecycleCommand != nil {
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
        let nextBudget = try (next.usesRepository && next != .command && inherited.repository != nil)
            ? inherited.request.budget.repositoryProbe()
            : next.preflight.map {
            try inherited.repository != nil ? inherited.request.budget.repositoryPreflight($0)
                : inherited.retention != nil ? inherited.request.budget.retentionPreflight($0)
                : inherited.request.budget.discoveryPreflight($0, command: discoveryCommand)
        } ?? inherited.request.budget
        try nextBudget.validate(kind: next.preflight?.kind ?? inherited.request.kind,
            permittedWorkSeconds: next.preflight?.workSeconds ?? (inherited.repository != nil
                ? CustodyCommandKind.repositoryGit.maximumWorkSeconds : inherited.retention != nil ? 120 : discoveryCommand.workSeconds), now: now)
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
        if let repository = inherited.repository, repository.root == nil, next == .command || next == .repositoryProbe(0) {
            guard let preflight = configurationPreflight else { throw CustodyResourceError.invalidResource }
            consumeControl()
            guard reason == .none, try state.permitsResume(now: now), controlQuiescent() else { throw CustodyRecordError.fenced }
            try inherited.revalidateParent(); try journal.leases.validate()
            try repository.admit(preflight: preflight)
            consumeControl()
            guard reason == .none, try state.permitsResume(now: now), controlQuiescent() else { throw CustodyRecordError.fenced }
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
        if next == .command, let retention = inherited.retention {
            guard let preflight = configurationPreflight else { throw CustodyResourceError.invalidResource }
            consumeControl()
            guard reason == .none, try state.permitsResume(now: now), controlQuiescent() else { throw CustodyRecordError.fenced }
            try inherited.revalidateParent(); try retention.admit(preflight: preflight)
            consumeControl()
            guard reason == .none, try state.permitsResume(now: now), controlQuiescent() else { throw CustodyRecordError.fenced }
        }
        let nextTarget = try CustodianTarget(inherited, stage: next)
        replaceRetiredTarget(nextTarget, budget: nextBudget)
        configurationPolicyBatch = nextPolicyBatch; configurationPolicyInput = nextPolicyInput; configurationPolicyCode = nextPolicyCode
        #if SHADOW_SYNC_TESTING
        serialReadyPublished = false
        #endif
        return true
    }
    private func replaceRetiredTarget(_ nextTarget: CustodianTarget, budget: CustodyBudget) {
        // No predecessor resources are dropped until its graph, pipes and exact
        // wait have converged. Existing leases and original timeline stay held.
        stdoutRead?.closeNow(); stderrRead?.closeNow(); traceRead?.closeNow()
        self.owner = nil; anchor = nil; stdoutRead = nil; stderrRead = nil; traceRead = nil
        stdoutBuffer.removeAll(); stderrBuffer.removeAll(); traceBuffer.removeAll()
        stdoutCount = 0; stderrCount = 0; traceCount = 0
        stdoutEnded = true; stderrEnded = true; traceEnded = true
        stdoutBroken = false; stderrBroken = false; traceBroken = false
        spawned = false; resumed = false; sentTerm = false; sentKill = false
        stageIndex += 1; stageBudget = budget; target = nextTarget
        #if SHADOW_SYNC_TESTING
        serialReadyPublished = false
        #endif
    }
    private func completeLifecyclePostflight() throws {
        guard stage == .lifecyclePostflight, !lifecyclePostflightComplete,
              let command = inherited.lifecycleCommand, let owner,
              targetDrained, owner.graphRetirementPermitted, case .reaped(let raw) = owner.observation else {
            throw CustodyRecordError.fenced
        }
        let observed = try command.state(waitStatus: raw, stdout: stdoutBuffer, stderr: stderrBuffer)
        try command.validatePostflight(observed)
        if command.operation == .bootout, case .loaded(_, let pid) = lifecyclePreflightState, let pid {
            // A successful service removal alone is not proof the prior host
            // exited. Never signal this observed (non-child) process here.
            guard SystemLaunchAgentController().processDisposition(processID: pid,
                expectedProgram: command.executable) == .absent else { throw CustodyRecordError.fenced }
        }
        try inherited.revalidateResources(); try inherited.revalidateParent(); try journal.leases.validate()
        lifecyclePostflightComplete = true
    }
    func run() throws -> Int32 {
        try status(.ready)
        #if SHADOW_SYNC_TESTING
        inherited.testingPolicyTiming?.mark(.readyQueued)
        #endif
        while true {
            if !terminalPublished {
                consumeControl()
                if now >= min(state.budget.work, stageBudget.work) && state.phase != .draining { beginDrain(.timeout) }
                if state.phase == .admitted && !spawned && reason == .none {
                    do {
                        #if SHADOW_SYNC_TESTING
                        try DiscoveryFixtureDiagnostic.RepositoryBusyObservation.observe(
                            enabled: inherited.testingDiscovery && inherited.request.kind == .repositoryGit
                                && inherited.repository?.input.testingPausePhase == "observe",
                            failure: { self.testingRepositoryBusy = $0 }) { try spawnTarget() }
                        #else
                        try spawnTarget()
                        #endif
                        consumeControl()
                    }
                    catch {
                        #if SHADOW_SYNC_TESTING
                        testingObserveFailure(.spawnTargetFailure, error: error)
                        #endif
                        beginDrain(reason == .none ? .invalidResource : reason)
                    }
                }
                relay(false); relay(true); relayTrace(); drainTarget()
                #if SHADOW_SYNC_TESTING
                if targetDrained, spawned { inherited.testingPolicyTiming?.mark(.drained) }
                #endif
                if targetDrained, stage.isIntermediate, reason == .none, spawned {
                    do { if try advanceStage() { continue } }
                    catch {
                        #if SHADOW_SYNC_TESTING
                        testingObserveFailure(.advanceStageFailure, error: error)
                        #endif
                        beginDrain(reason == .none ? .invalidResource : reason)
                    }
                }
                if stage == .lifecyclePostflight, targetDrained, reason == .none, spawned, !lifecyclePostflightComplete {
                    do { try completeLifecyclePostflight() }
                    catch { beginDrain(.invalidResource) }
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
                            if reason == .none, stage == .command, let retention = inherited.retention {
                                do { try retention.revalidate() } catch { beginDrain(.invalidResource) }
                            }
                            if reason == .none, !discoveryPostflightComplete, stage == .command, let discovery = inherited.discovery {
                                // A later control-frame retry must not demand
                                // the frozen files after their verified removal.
                                do { try discovery.revalidate(); discoveryPostflightComplete = true }
                                catch { beginDrain(.invalidResource) }
                            }
                            if reason == .none, stage == .command, let repository = inherited.repository,
                               !repository.postflightComplete, let owner, case .reaped(let raw) = owner.observation {
                                do {
                                    try repository.postflight(waitStatus: raw)
                                    #if SHADOW_SYNC_TESTING
                                    try testingRepositoryPause("postflight")
                                    #endif
                                }
                                catch {
                                    #if SHADOW_SYNC_TESTING
                                    testingObserveFailure(.repositoryPostflightFailure, error: error)
                                    #endif
                                    beginDrain(.invalidResource)
                                }
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
                                #if SHADOW_SYNC_TESTING
                                testingObserveFailure(.resourceRetirement, error: error)
                                #endif
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
                            inherited.testingPolicyTiming?.mark(.terminalCommitted)
                            if inherited.fixtureMode == "terminal-delay" {
                                while now < inherited.request.budget.work + 50_000_000 { usleep(1_000) }
                            }
                            #endif
                            terminalTime = now
                            do { try status(.terminal,terminal:terminal) }
                            catch { return 74 }
                        } catch {
                            persistenceFailed = true
                            #if SHADOW_SYNC_TESTING
                            testingObserveFailure(.terminalPublication, error: error)
                            #endif
                        }
                    }
                }
                if state.phase == .draining && now >= min(state.budget.kill, stageBudget.kill) && !sentPending {
                    sentPending = true
                    #if SHADOW_SYNC_TESTING
                    testingObserveFailure(.pendingBoundary, error: nil)
                    #endif
                    do { try journal.pending(reason:reason == .none ? .ownershipLost : reason); try status(.pending) }
                    catch {
                        persistenceFailed = true
                        #if SHADOW_SYNC_TESTING
                        testingObserveFailure(.pendingPublication, error: error)
                        #endif
                    }
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

#if SHADOW_SYNC_TESTING
/// Bounded testing-only observations survive loss of the worker's pipe reader.
/// These bytes are diagnostics, never custody, retirement or signaling authority.
private final class TestingCustodianFailureWitness {
    enum Event: String {
        case controlEOF, drainingPersistence, resourceRetirement
        case terminalPublication, pendingBoundary, pendingPublication, policyTimingFailure
        case spawnTargetFailure, advanceStageFailure, repositoryPostflightFailure
        func observes(after reason: CustodyReason) -> Bool {
            switch self {
            case .spawnTargetFailure, .advanceStageFailure, .repositoryPostflightFailure:
                // Expected cancellation/expiry can throw through these catches.
                // Keep their first-failure slot available for actual drainage
                // or persistence errors observed after that normal transition.
                return reason != .cancelled && reason != .timeout
            default: return true
            }
        }
        var slot: String {
            switch self {
            case .controlEOF: return "eof"
            case .pendingBoundary: return "pending"
            default: return "failure"
            }
        }
    }
    /// A closed error projection. Associated messages and framework descriptions
    /// can contain paths, arguments or policy input and are never serialized.
    static func errorFields(_ error: Error?) -> [String: Any] {
        guard let error else { return ["error": "none"] }
        var fields: [String: Any] = ["error": "other"]
        if let record = error as? CustodyRecordError {
            switch record {
            case .invalidRecord: fields["error"] = "invalid-record"
            case .invalidTransition: fields["error"] = "invalid-transition"
            case .conflict: fields["error"] = "conflict"
            case .fenced: fields["error"] = "fenced"
            case .busy: fields["error"] = "busy"
            case .unsafeMetadata: fields["error"] = "unsafe-metadata"
            case .persistence(let value): fields["error"] = "persistence"; fields["error_value"] = value
            case .committedCleanupFailure(let value): fields["error"] = "committed-cleanup"; fields["error_value"] = value
            case .injectedFailure: fields["error"] = "injected"
            }
        } else if let resource = error as? CustodyResourceError {
            switch resource {
            case .invalidResource: fields["error"] = "resource-invalid"
            case .closed: fields["error"] = "resource-closed"
            case .limit: fields["error"] = "resource-limit"
            case .systemCall(let value): fields["error"] = "resource-system-call"; fields["error_value"] = value
            }
        } else if let protocolError = error as? CustodyProtocolError {
            switch protocolError {
            case .invalidMessage: fields["error"] = "protocol-message"
            case .invalidBudget: fields["error"] = "protocol-budget"
            case .invalidSequence: fields["error"] = "protocol-sequence"
            }
        } else if let git = error as? GitSafetyError {
            switch git {
            case .repositoryRemoved: fields["error"] = "git-repository-removed"
            case .unsafeRepository: fields["error"] = "git-unsafe-repository"
            case .malformedConfig: fields["error"] = "git-malformed-config"
            case .originChanged: fields["error"] = "git-origin-changed"
            case .customTransport: fields["error"] = "git-custom-transport"
            case .replacementOrGraft: fields["error"] = "git-replacement-or-graft"
            case .busy: fields["error"] = "git-busy"
            case .hiddenIndex: fields["error"] = "git-hidden-index"
            case .dirty: fields["error"] = "git-dirty"
            case .detached: fields["error"] = "git-detached"
            case .primaryNotOnMain: fields["error"] = "git-primary-not-main"
            case .mainInLinkedWorktree: fields["error"] = "git-main-linked"
            case .localMainMissing: fields["error"] = "git-local-main-missing"
            case .remoteMainMissing: fields["error"] = "git-remote-main-missing"
            case .unsupportedHookFramework: fields["error"] = "git-unsupported-hook"
            case .commandFailed(_, let value, _): fields["error"] = "git-command-failed"; fields["error_value"] = value
            case .cancelled: fields["error"] = "git-cancelled"
            }
        } else if let helper = error as? PolicyHelperError {
            switch helper {
            case .unavailable: fields["error"] = "policy-helper-unavailable"
            case .cleanupPending: fields["error"] = "policy-helper-cleanup-pending"
            }
        } else if let policy = error as? PolicyProtocolError {
            switch policy {
            case .invalidRequest: fields["error"] = "policy-invalid-request"
            case .invalidResponse: fields["error"] = "policy-invalid-response"
            }
        } else if error is PublisherPolicyError { fields["error"] = "publisher-unavailable" }
        else if error is HostPolicyBindingError { fields["error"] = "host-policy-unavailable" }
        else if error is PolicyAuthorityFileError { fields["error"] = "policy-file-unavailable" }
        return fields
    }
    private let rootPath: String
    private let rootFD: Int32, homeFD: Int32, fileFD: Int32
    private let rootNode: stat, homeNode: stat, fileNode: stat
    private let rootACL: String, homeACL: String, fileACL: String
    private let filename: String
    private let binding: CustodyRecordBinding
    private var written = 0
    private var seen = Set<String>()
    private var poisoned = false
    // Closed, fixture-only syscall failure seams. The actual helper always uses
    // .none; no caller-selected path, descriptor or authority is injected.
    enum Fault { case none, afterRoot, afterHome, afterFile, initialSync, shortWrite, recordSync }
    enum RejectionStage: String {
        case serialization, bounds, rootHeld, rootNamed, homeHeld, homeNamed
        case fileHeld, fileNamed, rootACL, homeACL, fileACL, write, sync
    }
    struct Rejection {
        let event: Event
        let stage: RejectionStage
        let homeLinksEqual: Bool?
    }
    final class Probe {
        var opened: [Int32] = []; var writeAttempts = 0; var reached: Fault?; var createdFile: stat?
        var firstRejection: Rejection?
    }
    private let fault: Fault
    private let probe: Probe?
    init(home: String, binding: CustodyRecordBinding, fault: Fault = .none, probe: Probe? = nil) throws {
        guard home.hasSuffix("/home"), RunIdentity.isValid(binding.requestID) else { throw CustodyRecordError.fenced }
        let root = String(home.dropLast(5))
        guard root.hasPrefix("/private/tmp/shadow-sync-policy-authority-"),
              (root as NSString).lastPathComponent.count <= 160 else { throw CustodyRecordError.fenced }
        _ = try TestIsolation.validateRoot(root)
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw CustodyRecordError.fenced }
        var keepRoot = false; defer { if !keepRoot { close(rootFD) } }
        probe?.opened.append(rootFD)
        if fault == .afterRoot { probe?.reached = fault; throw CustodyRecordError.injectedFailure }
        let homeFD = openat(rootFD, "home", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeFD >= 0 else { throw CustodyRecordError.fenced }
        var keepHome = false; defer { if !keepHome { close(homeFD) } }
        probe?.opened.append(homeFD)
        if fault == .afterHome { probe?.reached = fault; throw CustodyRecordError.injectedFailure }
        var rootNode = stat(), homeNode = stat(), named = stat()
        guard fstat(rootFD, &rootNode) == 0, fstat(homeFD, &homeNode) == 0,
              Self.safe(rootNode, directory: true), Self.safe(homeNode, directory: true),
              lstat(root, &named) == 0, Self.same(rootNode, named),
              fstatat(rootFD, "home", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(homeNode, named) else { throw CustodyRecordError.fenced }
        let rootACL = try PolicyAuthorityFile.privateStateACL(rootFD)
        let homeACL = try PolicyAuthorityFile.privateStateACL(homeFD)
        let filename = ".shadow-sync-custodian-observation-" + binding.requestID + ".jsonl"
        // The home is private, but not assumed to have a single writer. Account
        // for this exact exclusive creation before replacing its preimage pin.
        let beforeEntries = try Self.homeEntries(homeFD)
        guard beforeEntries[filename] == nil, beforeEntries.count < 64,
              fstat(homeFD, &named) == 0, Self.same(homeNode, named),
              fstatat(rootFD, "home", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(homeNode, named),
              try PolicyAuthorityFile.privateStateACL(homeFD) == homeACL else { throw CustodyRecordError.fenced }
        let fileFD = openat(homeFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else { throw CustodyRecordError.fenced }
        var keepFile = false; defer { if !keepFile { close(fileFD) } }
        probe?.opened.append(fileFD)
        if let probe {
            var created = stat()
            guard fstat(fileFD, &created) == 0 else { throw CustodyRecordError.fenced }
            probe.createdFile = created
        }
        if fault == .afterFile { probe?.reached = fault; throw CustodyRecordError.injectedFailure }
        var fileNode = stat()
        guard fstat(fileFD, &fileNode) == 0, Self.safe(fileNode, directory: false), fileNode.st_size == 0,
              fstatat(homeFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(fileNode, named) else { throw CustodyRecordError.fenced }
        if fault == .initialSync { probe?.reached = fault; throw CustodyRecordError.injectedFailure }
        guard fsync(fileFD) == 0, fsync(homeFD) == 0 else { throw CustodyRecordError.fenced }
        let fileACL = try PolicyAuthorityFile.privateStateACL(fileFD)
        // Pin the checked postcreation metadata BEFORE sampling the entry
        // postimage. Later nlink drift cannot be adopted as the own-create delta.
        var createdHome = stat(), held = stat()
        guard fstat(homeFD, &createdHome) == 0, Self.creationHome(homeNode, createdHome),
              fstatat(rootFD, "home", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(createdHome, named),
              try PolicyAuthorityFile.privateStateACL(homeFD) == homeACL else { throw CustodyRecordError.fenced }
        let afterEntries = try Self.homeEntries(homeFD)
        guard fstat(homeFD, &held) == 0, Self.same(createdHome, held),
              Self.creationEntries(beforeEntries, afterEntries, filename: filename, file: fileNode),
              fstatat(rootFD, "home", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(createdHome, named),
              fstat(rootFD, &held) == 0, Self.same(rootNode, held),
              lstat(root, &named) == 0, Self.same(rootNode, named),
              fstat(fileFD, &held) == 0, Self.same(fileNode, held), held.st_size == 0,
              fstatat(homeFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(fileNode, named), named.st_size == 0,
              try PolicyAuthorityFile.privateStateACL(rootFD) == rootACL,
              try PolicyAuthorityFile.privateStateACL(homeFD) == homeACL,
              try PolicyAuthorityFile.privateStateACL(fileFD) == fileACL,
              fstat(homeFD, &held) == 0, Self.same(createdHome, held) else { throw CustodyRecordError.fenced }
        homeNode = createdHome
        self.rootACL = rootACL; self.homeACL = homeACL; self.fileACL = fileACL
        self.rootPath = root; self.rootFD = rootFD; self.homeFD = homeFD; self.fileFD = fileFD
        self.rootNode = rootNode; self.homeNode = homeNode; self.fileNode = fileNode
        self.filename = filename; self.binding = binding; self.fault = fault; self.probe = probe
        keepRoot = true; keepHome = true; keepFile = true
    }
    deinit { close(fileFD); close(homeFD); close(rootFD) }
    private static func safe(_ node: stat, directory: Bool) -> Bool {
        node.st_uid == geteuid() && node.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600)
            && node.st_flags == 0 && (directory || node.st_nlink == 1)
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_mode == b.st_mode && a.st_flags == b.st_flags && a.st_nlink == b.st_nlink
    }
    // A regular-file creation leaves directory link count unchanged on some
    // filesystems and adds one on others. Only this one accounted entry may be
    // added; all prior entry identities and parent authority fields stay pinned.
    private static func creationHome(_ before: stat, _ after: stat) -> Bool {
        var accounted = before
        guard after.st_nlink == before.st_nlink
            || UInt64(after.st_nlink) == UInt64(before.st_nlink) + 1 else { return false }
        accounted.st_nlink = after.st_nlink
        return safe(after, directory: true) && same(accounted, after)
    }
    private static func creationEntries(_ before: [String: stat], _ after: [String: stat], filename: String, file: stat) -> Bool {
        guard before[filename] == nil, before.count < 64, after.count <= 64,
              Set(after.keys) == Set(before.keys).union([filename]),
              let created = after[filename], same(file, created), created.st_size == 0 else { return false }
        return before.allSatisfy { name, node in
            guard let current = after[name] else { return false }
            return same(node, current) && node.st_size == current.st_size
        }
    }
    private static func homeEntries(_ fd: Int32) throws -> [String: stat] {
        let raw = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.fenced }
        guard let directory = fdopendir(raw) else { close(raw); throw CustodyRecordError.fenced }
        defer { closedir(directory) }
        var result: [String: stat] = [:], reads = 0
        while true {
            // Include dot entries and EOF in the syscall bound, not only unique
            // names. A changing or malformed roster cannot make this unbounded.
            guard reads < 67 else { throw CustodyRecordError.fenced }
            reads += 1; errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw CustodyRecordError.fenced }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name, !name.isEmpty, !name.contains("/"), name.utf8.count <= Int(MAXNAMLEN) else { throw CustodyRecordError.fenced }
            if name == "." || name == ".." { continue }
            var node = stat()
            guard result.count < 64, result[name] == nil,
                  fstatat(fd, name, &node, AT_SYMLINK_NOFOLLOW) == 0 else { throw CustodyRecordError.fenced }
            result[name] = node
        }
    }
    func record(_ event: Event, fields: [String: Any]) {
        guard !poisoned, !seen.contains(event.slot), seen.count < 3 else { return }
        seen.insert(event.slot)
        var rejectionStage = RejectionStage.serialization
        var homeLinksEqual: Bool?
        do {
            var value = fields
            value["schema"] = "shadow-sync-custodian-failure-observation/v1"
            value["marker"] = "CUSTODIAN FIRST FAILURE WITNESS"
            value["request"] = binding.requestID; value["generation"] = binding.generation
            value["nonce_sha256"] = binding.nonceSHA256
            guard JSONSerialization.isValidJSONObject(value) else { throw CustodyRecordError.fenced }
            var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
            rejectionStage = .bounds
            guard bytes.count <= 2048, written + bytes.count <= 6144 else { throw CustodyRecordError.fenced }
            var held = stat(), named = stat()
            rejectionStage = .rootHeld
            guard fstat(rootFD, &held) == 0, Self.same(rootNode, held) else { throw CustodyRecordError.fenced }
            rejectionStage = .rootNamed
            guard lstat(rootPath, &named) == 0, Self.same(rootNode, named) else { throw CustodyRecordError.fenced }
            rejectionStage = .homeHeld
            guard fstat(homeFD, &held) == 0 else { throw CustodyRecordError.fenced }
            homeLinksEqual = homeNode.st_nlink == held.st_nlink
            guard Self.same(homeNode, held) else { throw CustodyRecordError.fenced }
            rejectionStage = .homeNamed
            guard fstatat(rootFD, "home", &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(homeNode, named) else { throw CustodyRecordError.fenced }
            rejectionStage = .fileHeld
            guard fstat(fileFD, &held) == 0, Self.same(fileNode, held), held.st_size == written else { throw CustodyRecordError.fenced }
            rejectionStage = .fileNamed
            guard fstatat(homeFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.same(fileNode, named) else { throw CustodyRecordError.fenced }
            rejectionStage = .rootACL
            guard try PolicyAuthorityFile.privateStateACL(rootFD) == rootACL else { throw CustodyRecordError.fenced }
            rejectionStage = .homeACL
            guard try PolicyAuthorityFile.privateStateACL(homeFD) == homeACL else { throw CustodyRecordError.fenced }
            rejectionStage = .fileACL
            guard try PolicyAuthorityFile.privateStateACL(fileFD) == fileACL else { throw CustodyRecordError.fenced }
            rejectionStage = .write
            probe?.writeAttempts += 1
            let count = bytes.withUnsafeBytes {
                pwrite(fileFD, $0.baseAddress, fault == .shortWrite ? max(1, $0.count / 2) : $0.count, off_t(written))
            }
            guard count == bytes.count else { throw CustodyRecordError.fenced }
            rejectionStage = .sync
            guard fault != .recordSync, fsync(fileFD) == 0 else { throw CustodyRecordError.fenced }
            written += count
        } catch {
            let savedErrno = errno
            defer { errno = savedErrno }
            poisoned = true
            if let probe, probe.firstRejection == nil {
                probe.firstRejection = Rejection(event: event, stage: rejectionStage,
                                                 homeLinksEqual: homeLinksEqual)
            }
        }
    }
}
#endif

#if SHADOW_SYNC_TESTING
/// Actual private witness files only. No command, helper, registry, host state or
/// signing operation is launched; native helper drainage remains a separate gate.
enum CustodianFailureWitnessFixtures {
    static func admission() throws { try TestingCustodianFailureWitness.fixtureAdmission() }
    static func substitution() throws { try TestingCustodianFailureWitness.fixtureSubstitution() }
    static func metadata() throws { try TestingCustodianFailureWitness.fixtureMetadata() }
    static func initialization() throws { try TestingCustodianFailureWitness.fixtureInitialization() }
    static func slots() throws { try TestingCustodianFailureWitness.fixtureSlots() }
    static func io() throws { try TestingCustodianFailureWitness.fixtureIO() }
    static func limits() throws { try TestingCustodianFailureWitness.fixtureLimits() }
}
private extension TestingCustodianFailureWitness {
    struct FixtureFailure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw FixtureFailure(message: message) }
    }
    static func refusal(_ body: () throws -> Void) throws {
        do { try body() } catch is FixtureFailure { throw FixtureFailure(message: "witness fixture setup failed") }
        catch { return }
        throw FixtureFailure(message: "witness unexpectedly admitted")
    }
    // The roster is populated only at fixture-owned creation, never from a
    // post-body directory snapshot. Unknown or substituted names retain all
    // evidence and prevent any cleanup mutation.
    final class FixtureNodes {
        let root: String, home: String
        let parentFD: OwnedFileDescriptor, rootFD: OwnedFileDescriptor, homeFD: OwnedFileDescriptor
        let parentNode: stat
        var nodes: [String: stat]
        init(root: String, original: stat) throws {
            self.root = root; home = root + "/home"
            parentFD = try Self.directory("/private/tmp")
            rootFD = try Self.directory(root); homeFD = try Self.directory(home)
            var parent = stat(), heldRoot = stat(), heldHome = stat()
            try check(fstat(parentFD.value, &parent) == 0 && fstat(rootFD.value, &heldRoot) == 0
                && fstat(homeFD.value, &heldHome) == 0 && Self.stable(original, heldRoot), "witness original directories")
            parentNode = parent; nodes = [root: original, home: heldHome]
            try validate(root, original); try validate(home, heldHome)
        }
        static func directory(_ path: String) throws -> OwnedFileDescriptor {
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(fd >= 0, "witness owned directory descriptor")
            return OwnedFileDescriptor(fd)
        }
        static func stable(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
                && a.st_gid == b.st_gid && a.st_mode == b.st_mode && a.st_flags == b.st_flags
        }
        func parent(_ path: String) throws -> (Int32, stat, String) {
            if path == root { return (parentFD.value, parentNode, (path as NSString).lastPathComponent) }
            if path == home { return (rootFD.value, nodes[root]!, "home") }
            guard (path as NSString).deletingLastPathComponent == home else { throw FixtureFailure(message: "witness fixture path escaped") }
            return (homeFD.value, nodes[home]!, (path as NSString).lastPathComponent)
        }
        func validate(_ path: String, _ expected: stat) throws {
            let (fd, parent, name) = try self.parent(path)
            var held = stat(), named = stat()
            try check(fstat(fd, &held) == 0 && Self.stable(parent, held)
                && fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && Self.stable(expected, named), "witness named/parent identity drift")
        }
        func pin(_ path: String, _ expected: stat) throws {
            try check(nodes[path] == nil, "witness duplicate creation pin")
            try validate(path, expected); nodes[path] = expected
        }
        func pinCreatedLink(_ path: String) throws {
            let (fd, parent, name) = try self.parent(path); var held = stat(), node = stat()
            try check(fstat(fd, &held) == 0 && Self.stable(parent, held)
                && fstatat(fd, name, &node, AT_SYMLINK_NOFOLLOW) == 0, "witness created link identity")
            try pin(path, node)
        }
        func file(_ path: String, data: Data) throws {
            let (fd, parent, name) = try self.parent(path); var held = stat()
            try check(fstat(fd, &held) == 0 && Self.stable(parent, held), "witness file parent identity")
            let raw = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try check(raw >= 0, "witness exclusive fixture file"); defer { close(raw) }
            var node = stat(); try check(fstat(raw, &node) == 0, "witness created file identity")
            try pin(path, node)
            let count = data.withUnsafeBytes { write(raw, $0.baseAddress, $0.count) }
            try check(count == data.count, "witness fixture file bytes")
        }
        func witness(_ binding: CustodyRecordBinding, fault: Fault = .none, probe: Probe? = nil) throws -> TestingCustodianFailureWitness {
            let observed = probe ?? Probe()
            do {
                let value = try TestingCustodianFailureWitness(home: home, binding: binding, fault: fault, probe: observed)
                guard let created = observed.createdFile else { throw FixtureFailure(message: "witness created file observation missing") }
                try pin(path(home, binding), created); return value
            } catch {
                if let created = observed.createdFile, nodes[path(home, binding)] == nil { try pin(path(home, binding), created) }
                throw error
            }
        }
        func remove(_ path: String, expected: stat) throws {
            try validate(path, expected)
            let (fd, _, name) = try parent(path)
            try check(unlinkat(fd, name, expected.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0, "witness exact owned removal")
            nodes.removeValue(forKey: path)
        }
        func substitute(_ path: String, observe: () throws -> Void) throws {
            guard let original = nodes[path] else { throw FixtureFailure(message: "witness unowned substitution") }
            try validate(path, original)
            let (fd, parent, name) = try self.parent(path); let moved = name + "-held"
            try check(renameatx_np(fd, name, fd, moved, UInt32(RENAME_EXCL)) == 0, "witness exclusive substitution rename")
            let isDirectory = original.st_mode & S_IFMT == S_IFDIR
            var replacement = stat(), movedNode = stat(), held = stat()
            if isDirectory {
                try check(mkdirat(fd, name, 0o700) == 0 && fstatat(fd, name, &replacement, AT_SYMLINK_NOFOLLOW) == 0, "witness replacement directory")
            } else {
                let raw = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                try check(raw >= 0, "witness replacement file"); defer { close(raw) }
                try check(fstat(raw, &replacement) == 0, "witness replacement file identity")
            }
            try observe()
            var named = stat()
            try check(fstat(fd, &held) == 0 && Self.stable(parent, held)
                && fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && Self.stable(replacement, named)
                && fstatat(fd, moved, &movedNode, AT_SYMLINK_NOFOLLOW) == 0 && Self.stable(original, movedNode), "witness substitution ownership drift")
            try check(unlinkat(fd, name, isDirectory ? AT_REMOVEDIR : 0) == 0, "witness owned replacement removal")
            // Revalidate the held parent and moved original again at the second mutation.
            try check(fstat(fd, &held) == 0 && Self.stable(parent, held)
                && fstatat(fd, moved, &movedNode, AT_SYMLINK_NOFOLLOW) == 0 && Self.stable(original, movedNode)
                && renameatx_np(fd, moved, fd, name, UInt32(RENAME_EXCL)) == 0, "witness owned original restoration")
            try validate(path, original)
        }
        static func children(_ fd: Int32) throws -> Set<String> {
            let raw = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(raw >= 0, "witness roster descriptor")
            guard let directory = fdopendir(raw) else { close(raw); throw FixtureFailure(message: "witness roster stream") }
            defer { closedir(directory) }; var result = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(directory) else { try check(errno == 0, "witness roster read"); return result }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { result.insert(name) }
                try check(result.count <= 16, "witness roster bound")
            }
        }
        func cleanup() throws {
            guard let rootNode = nodes[root], let homeNode = nodes[home] else { throw FixtureFailure(message: "witness original roster missing") }
            try validate(root, rootNode); try validate(home, homeNode)
            let names = Set(nodes.keys.filter { $0 != root && $0 != home }.map { ($0 as NSString).lastPathComponent })
            try check(try Self.children(rootFD.value) == ["home"] && Self.children(homeFD.value) == names, "witness unknown cleanup roster")
            for (name, expected) in nodes {
                try validate(name, expected)
                if expected.st_mode & S_IFMT == S_IFLNK { continue }
                let (parent, _, component) = try self.parent(name)
                let raw = openat(parent, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                try check(raw >= 0, "witness cleanup held node"); defer { close(raw) }
                var node = stat(); try check(fstat(raw, &node) == 0 && Self.stable(expected, node), "witness cleanup held identity")
                _ = try PolicyAuthorityFile.privateStateACL(raw)
                if expected.st_mode & S_IFMT == S_IFREG {
                    let links = nodes.values.filter { $0.st_dev == expected.st_dev && $0.st_ino == expected.st_ino }.count
                    try check(Int(node.st_nlink) == links, "witness unknown cleanup hardlink")
                }
            }
            for name in nodes.keys.sorted(by: { $0.count > $1.count }) {
                guard let expected = nodes[name] else { throw FixtureFailure(message: "witness cleanup roster drift") }
                try remove(name, expected: expected)
            }
        }
    }
    static func fixture(_ body: (String, String, CustodyRecordBinding, FixtureNodes) throws -> Void) throws {
        var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-authority-") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&template) else { throw FixtureFailure(message: "witness fixture root") }
        let root = String(cString: raw), home = root + "/home"
        var original = stat(); try check(lstat(root, &original) == 0, "witness root identity")
        try check(mkdir(home, 0o700) == 0, "witness fixture home")
        let owned = try FixtureNodes(root: root, original: original)
        let binding = try CustodyRecordBinding(wire: .object([
            "request": .string(RunIdentity.make()), "scope": .string(RunIdentity.make()),
            "nonce_sha256": .string(String(repeating: "a", count: 64)), "generation": .string(RunIdentity.make()),
            "uid": .unsigned(UInt64(geteuid())), "boot": .string(RunIdentity.make()),
            "release": .string(String(repeating: "b", count: 64))]))
        try body(root, home, binding, owned)
        try owned.cleanup()
    }
    static func path(_ home: String, _ binding: CustodyRecordBinding) -> String {
        home + "/.shadow-sync-custodian-observation-" + binding.requestID + ".jsonl"
    }
    static func bytes(_ home: String, _ binding: CustodyRecordBinding) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path(home, binding)))
    }
    static func emit(_ witness: TestingCustodianFailureWitness, _ event: Event) {
        witness.record(event, fields: ["event": event.rawValue, "reason": "cancelled"])
    }
    static func fixtureAdmission() throws {
        for kind in ["file", "symlink", "hardlink"] {
            try fixture { _, home, binding, owned in
                let target = path(home, binding), sentinel = home + "/sentinel"
                try owned.file(sentinel, data: Data("unchanged".utf8))
                if kind == "file" { try owned.file(target, data: Data()) }
                if kind == "symlink" { try check(symlinkat(sentinel, owned.homeFD.value, (target as NSString).lastPathComponent) == 0, "witness symlink setup"); try owned.pinCreatedLink(target) }
                if kind == "hardlink" { try check(linkat(owned.homeFD.value, "sentinel", owned.homeFD.value, (target as NSString).lastPathComponent, 0) == 0, "witness hardlink setup"); try owned.pinCreatedLink(target) }
                guard let targetPin = owned.nodes[target], let sentinelPin = owned.nodes[sentinel] else {
                    throw FixtureFailure(message: "witness admission pins missing")
                }
                try refusal { _ = try TestingCustodianFailureWitness(home: home, binding: binding) }
                try owned.validate(target, targetPin); try owned.validate(sentinel, sentinelPin)
                var after = stat()
                try check(lstat(target, &after) == 0 && after.st_size == targetPin.st_size
                    && after.st_nlink == targetPin.st_nlink
                    && after.st_mtimespec.tv_sec == targetPin.st_mtimespec.tv_sec
                    && after.st_mtimespec.tv_nsec == targetPin.st_mtimespec.tv_nsec
                    && after.st_ctimespec.tv_sec == targetPin.st_ctimespec.tv_sec
                    && after.st_ctimespec.tv_nsec == targetPin.st_ctimespec.tv_nsec, "witness changed existing target metadata")
                try check(try Data(contentsOf: URL(fileURLWithPath: sentinel)) == Data("unchanged".utf8), "witness touched preexisting target")
            }
        }
        try fixture { root, home, binding, owned in
            try refusal { _ = try TestingCustodianFailureWitness(home: root, binding: binding) }
            try check(fchmod(owned.homeFD.value, 0o755) == 0, "witness unsafe home mode")
            try refusal { _ = try TestingCustodianFailureWitness(home: home, binding: binding) }
            try check(fchmod(owned.homeFD.value, 0o700) == 0, "witness restore home mode")
        }
    }
    static func fixtureSubstitution() throws {
        for kind in ["root", "home", "file"] {
            try fixture { root, home, binding, owned in
                let witness = try owned.witness(binding)
                let original = kind == "root" ? root : kind == "home" ? home : path(home, binding)
                try owned.substitute(original) {
                    emit(witness, .controlEOF)
                    try check(witness.poisoned && witness.written == 0, "witness accepted substituted identity")
                }
                emit(witness, .terminalPublication)
                try check(try bytes(home, binding).isEmpty, "witness unpoisoned after restoration")
            }
        }
    }
    static func fixtureMetadata() throws {
        for node in ["root", "home", "file"] {
            for mutation in ["mode", "flags", "acl"] {
                try fixture { root, home, binding, owned in
                    let witness = try owned.witness(binding)
                    let target = node == "root" ? root : node == "home" ? home : path(home, binding)
                    let mode: mode_t = node == "file" ? 0o600 : 0o700
                    let retained = node == "root" ? witness.rootFD : node == "home" ? witness.homeFD : witness.fileFD
                    if mutation == "mode" {
                        try check(fchmod(retained, mode | 0o040) == 0, "witness mode mutation")
                        emit(witness, .controlEOF)
                        try check(fchmod(retained, mode) == 0, "witness mode restoration")
                    } else if mutation == "flags" {
                        try check(fchflags(retained, UInt32(UF_NODUMP)) == 0, "witness flags mutation")
                        emit(witness, .controlEOF)
                        try check(fchflags(retained, 0) == 0, "witness flags restoration")
                    } else {
                        try InstallationOwnershipFixtures.withACLGrant(target) { emit(witness, .controlEOF) }
                    }
                    try check(witness.poisoned && witness.written == 0 && (try bytes(home, binding)).isEmpty, "witness accepted metadata drift")
                }
            }
        }
        try fixture { _, home, binding, owned in
            let witness = try owned.witness(binding)
            let fd = open(path(home, binding), O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            try check(fd >= 0, "witness size mutation open"); defer { close(fd) }
            try check(ftruncate(fd, 1) == 0, "witness size mutation")
            emit(witness, .controlEOF)
            try check(witness.poisoned && witness.written == 0 && (try bytes(home, binding)).count == 1, "witness accepted size drift")
        }
        try fixture { _, home, binding, owned in
            let witness = try owned.witness(binding)
            let alias = home + "/witness-alias"
            try check(linkat(owned.homeFD.value, (path(home, binding) as NSString).lastPathComponent,
                owned.homeFD.value, "witness-alias", 0) == 0, "witness retained hardlink mutation")
            try owned.pinCreatedLink(alias)
            emit(witness, .controlEOF)
            try check(witness.poisoned && witness.written == 0 && (try bytes(home, binding)).isEmpty, "witness accepted retained hardlink")
            guard let aliasNode = owned.nodes[alias] else { throw FixtureFailure(message: "witness alias pin missing") }
            try owned.remove(alias, expected: aliasNode)
        }
        // Unprivileged fixtures cannot chown a real inode to another account.
        // Exercise the exact metadata predicate without claiming native chown.
        var node = stat(); node.st_uid = geteuid() == 0 ? 1 : 0; node.st_mode = S_IFREG | 0o600; node.st_nlink = 1
        try check(!safe(node, directory: false), "witness wrong owner predicate")
    }
    static func fixtureInitialization() throws {
        for fault in [Fault.afterRoot, .afterHome, .afterFile, .initialSync] {
            try fixture { _, home, binding, owned in
                let probe = Probe()
                try refusal { _ = try owned.witness(binding, fault: fault, probe: probe) }
                let expectedCount = fault == .afterRoot ? 1 : fault == .afterHome ? 2 : 3
                try check(probe.reached == fault && probe.opened.count == expectedCount
                    && Set(probe.opened).count == expectedCount, "witness exact init cut not reached")
                for fd in probe.opened {
                    errno = 0
                    try check(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "witness failed init leaked descriptor")
                }
            }
        }
    }
    /// Exercise the real publication helper against the real retained witness.
    /// Synthetic event fields test persistence only, never native EOF or drainage.
    static func fixtureMarkerPublication() throws {
        for mutation in ["none", "late-root-entry", "root-replacement", "root-mode", "root-acl", "witness-unlink"] {
            try fixture { root, home, binding, owned in
                let probe = Probe()
                let markers: RepositoryWorkerMarkerDirectory
                let witness: TestingCustodianFailureWitness
                if mutation == "late-root-entry" {
                    witness = try owned.witness(binding, probe: probe)
                    // Negative control: a real new directory changes the pinned
                    // root link count on both entry-counting and POSIX filesystems.
                    markers = try RepositoryWorkerMarkerDirectory(root: root, create: true)
                } else {
                    markers = try RepositoryWorkerMarkerDirectory(root: root, create: true)
                    witness = try owned.witness(binding, probe: probe)
                }
                let ready = Data("{\"fixture_ready\":true}\n".utf8)
                try markers.publish(ready)
                try check(try markers.read() == ready, "witness marker publication readback")
                if mutation == "root-replacement" {
                    try owned.substitute(root) { emit(witness, .controlEOF) }
                } else if mutation == "root-mode" {
                    try check(fchmod(owned.rootFD.value, 0o750) == 0, "marker witness root mode change")
                    emit(witness, .controlEOF)
                    try check(fchmod(owned.rootFD.value, 0o700) == 0, "marker witness root mode restoration")
                } else if mutation == "root-acl" {
                    try InstallationOwnershipFixtures.withACLGrant(root) { emit(witness, .controlEOF) }
                } else if mutation == "witness-unlink" {
                    let target = path(home, binding)
                    guard let node = owned.nodes[target] else { throw FixtureFailure(message: "marker witness file pin") }
                    try owned.remove(target, expected: node)
                    emit(witness, .controlEOF)
                } else { emit(witness, .controlEOF) }
                emit(witness, .terminalPublication)
                emit(witness, .pendingBoundary)
                if mutation == "none" {
                    var held = stat(), named = stat()
                    try check(fstat(witness.rootFD, &held) == 0 && lstat(root, &named) == 0
                        && same(witness.rootNode, held) && same(witness.rootNode, named), "marker changed pinned witness root")
                    let data = try bytes(home, binding)
                    let records = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
                    try check(!witness.poisoned && probe.firstRejection == nil && probe.writeAttempts == 3
                        && records.count == 3 && witness.written == data.count && data.count <= 6144,
                        "readiness publication suppressed actual witness persistence")
                    try check(records.compactMap { $0?["event"] as? String }
                        == ["controlEOF", "terminalPublication", "pendingBoundary"], "marker witness slots changed")
                    try check(records.allSatisfy { $0?["request"] as? String == binding.requestID
                        && $0?["generation"] as? String == binding.generation
                        && $0?["nonce_sha256"] as? String == binding.nonceSHA256 }, "marker witness binding drift")
                } else {
                    var held = stat()
                    try check(witness.poisoned && witness.written == 0 && probe.writeAttempts == 0
                        && probe.firstRejection != nil && fstat(witness.fileFD, &held) == 0 && held.st_size == 0,
                        "marker publication weakened witness mutation refusal")
                    if mutation == "late-root-entry" {
                        try check(probe.firstRejection?.stage == .rootHeld, "late root entry did not exercise root pin")
                    }
                }
                // Only this fixture's known marker bytes/directory are removed;
                // the existing witness owner still validates its full cleanup roster.
                try markers.remove()
            }
        }
    }
    static func fixtureSlots() throws {
        try fixtureMarkerPublication()
        try fixture { _, home, binding, owned in
            try fixtureTimingCodec(binding)
            let probe = Probe(), witness = try owned.witness(binding, probe: probe)
            for event in [Event.controlEOF, .controlEOF, .terminalPublication, .drainingPersistence, .pendingBoundary, .pendingPublication, .pendingBoundary] { emit(witness, event) }
            let data = try bytes(home, binding)
            let records = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            if records.count != 3 || probe.writeAttempts != 3 || witness.poisoned {
                let rejection = probe.firstRejection
                let homeLinks = rejection.flatMap { $0.homeLinksEqual }.map { $0 ? "equal" : "changed" } ?? "unobserved"
                let line = "M6 WITNESS SLOT FAILURE records=\(records.count) attempts=\(probe.writeAttempts) poisoned=\(witness.poisoned) written=\(witness.written) bytes=\(data.count) stage=\(rejection?.stage.rawValue ?? "none") event=\(rejection?.event.rawValue ?? "none") home_links=\(homeLinks)\n"
                // Fixed fields only; no request, path, identity, error or witness contents.
                if line.utf8.count <= 512 { FileHandle.standardError.write(Data(line.utf8)) }
            }
            try check(records.count == 3 && probe.writeAttempts == 3 && !witness.poisoned, "witness independent slots")
            try check(records.compactMap { $0?["event"] as? String } == ["controlEOF", "terminalPublication", "pendingBoundary"], "witness first failure overwritten")
            try check(records.allSatisfy { $0?["request"] as? String == binding.requestID && $0?["generation"] as? String == binding.generation && $0?["nonce_sha256"] as? String == binding.nonceSHA256 }, "witness binding changed")
            try check(data.count <= 6144 && witness.written == data.count, "witness byte bound")
            // Pure comparator negatives are distinct from live filesystem
            // admission: none of these synthetic values reaches an owner API.
            let parent = witness.homeNode, file = witness.fileNode
            var changed = parent
            changed.st_nlink = parent.st_nlink + 2
            try check(!creationHome(parent, changed), "witness unaccounted parent links")
            changed = parent; changed.st_mode ^= 0o020
            try check(!creationHome(parent, changed), "witness parent authority recaptured")
            let name = witness.filename, prior = ["existing": file]
            let expected = ["existing": file, name: file]
            try check(creationEntries(prior, expected, filename: name, file: file), "witness exact creation comparison")
            var drift = expected; drift["foreign"] = file
            try check(!creationEntries(prior, drift, filename: name, file: file), "witness unknown entry accepted")
            drift = expected; drift.removeValue(forKey: "existing")
            try check(!creationEntries(prior, drift, filename: name, file: file), "witness missing entry accepted")
            var replaced = file; replaced.st_ino ^= 1
            drift = expected; drift["existing"] = replaced
            try check(!creationEntries(prior, drift, filename: name, file: file), "witness replaced entry accepted")
            drift = expected; drift[name] = replaced
            try check(!creationEntries(prior, drift, filename: name, file: file), "witness new file identity accepted")
        }
        for event in [Event.spawnTargetFailure, .advanceStageFailure, .repositoryPostflightFailure] {
            try fixture { _, home, binding, owned in
                let probe = Probe(), witness = try owned.witness(binding, probe: probe)
                // A real error with associated command/output text must retain
                // only its closed case and numeric result in the actual file.
                var fields = errorFields(GitSafetyError.commandFailed("fixture-command-detail", 17,
                    "fixture-output-detail"))
                fields["event"] = event.rawValue
                fields["stage"] = "policy"; fields["stage_index"] = 1
                fields["command_kind"] = "repository-git"
                emit(witness, .controlEOF)
                for reason in [CustodyReason.cancelled, .timeout] {
                    if event.observes(after: reason) { witness.record(event, fields: fields) }
                }
                try check(witness.seen == Set(["eof"]) && probe.writeAttempts == 1,
                    "witness cancellation consumed catch failure slot")
                try check(event.observes(after: .none) && event.observes(after: .invalidResource),
                    "witness actual caught failure suppressed")
                witness.record(event, fields: fields)
                emit(witness, .drainingPersistence); emit(witness, .terminalPublication)
                emit(witness, .pendingBoundary)
                let data = try bytes(home, binding)
                let records = try data.split(separator: 10).map {
                    try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                }
                try check(records.count == 3 && probe.writeAttempts == 3 && !witness.poisoned,
                    "witness catch failure slots")
                try check(records.compactMap { $0?["event"] as? String }
                    == ["controlEOF", event.rawValue, "pendingBoundary"],
                    "witness caught error replaced by drain error")
                try check(records[1]?["error"] as? String == "git-command-failed"
                    && records[1]?["error_value"] as? Int == 17
                    && records[1]?["stage"] as? String == "policy"
                    && records[1]?["stage_index"] as? Int == 1
                    && records[1]?["command_kind"] as? String == "repository-git",
                    "witness caught error detail missing")
                try check(data.range(of: Data("fixture-command-detail".utf8)) == nil
                    && data.range(of: Data("fixture-output-detail".utf8)) == nil,
                    "witness serialized associated error text")
                let unknown = errorFields(NSError(domain: "fixture-private-domain", code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "fixture-private-description"]))
                try check(unknown.count == 1 && unknown["error"] as? String == "other",
                    "witness unknown error reflected")
                try check(records.allSatisfy { $0?["request"] as? String == binding.requestID
                    && $0?["generation"] as? String == binding.generation
                    && $0?["nonce_sha256"] as? String == binding.nonceSHA256 }
                    && data.count <= 6144 && witness.written == data.count,
                    "witness catch binding or bounds changed")
            }
        }
    }
    static func fixtureIO() throws {
        for fault in [Fault.shortWrite, .recordSync] {
            try fixture { _, home, binding, owned in
                let probe = Probe(), witness = try owned.witness(binding, fault: fault, probe: probe)
                emit(witness, .controlEOF)
                let first = try bytes(home, binding)
                emit(witness, .terminalPublication); emit(witness, .pendingBoundary)
                try check(witness.poisoned && witness.written == 0 && probe.writeAttempts == 1 && !first.isEmpty && (try bytes(home, binding)) == first, "witness I/O poison retried or erased partial evidence")
                try check(probe.firstRejection?.event == .controlEOF
                    && probe.firstRejection?.stage == (fault == .shortWrite ? .write : .sync),
                    "witness I/O rejection stage changed")
                // record returned normally; actual helper drainage is separately
                // exercised by the custody fixture, never synthesized here.
            }
        }
    }
    static func fixtureLimits() throws {
        try fixture { _, home, binding, owned in
            let probe = Probe(), witness = try owned.witness(binding, probe: probe)
            witness.record(.controlEOF, fields: ["oversize": String(repeating: "x", count: 2048)])
            emit(witness, .terminalPublication)
            try check(witness.poisoned && probe.writeAttempts == 0 && (try bytes(home, binding)).isEmpty, "witness oversized record written")
        }
        try fixture { _, home, binding, owned in
            let probe = Probe(), witness = try owned.witness(binding, probe: probe)
            witness.record(.controlEOF, fields: ["notJSON": Date()])
            emit(witness, .terminalPublication)
            try check(witness.poisoned && probe.writeAttempts == 0 && (try bytes(home, binding)).isEmpty, "witness invalid serialization retried")
        }
    }
}
#endif

#if SHADOW_SYNC_TESTING
/// Optional snapshot only. This adapter has no custody, signaling or cleanup API.
enum TestingPolicyHelperWitness {
    // Parent cancellation and the already verified helper terminal are separate
    // observations. A target timeout may finish before the parent records one.
    static func shouldObserve(parentReason: CustodyReason?, terminalReason: CustodyReason?) -> Bool {
        parentReason.map({ $0 != CustodyReason.none }) == true || terminalReason == .timeout
    }
    static func observe(_ request: UnvalidatedCustodyRequest) {
        let savedErrno = errno
        defer { errno = savedErrno }
        guard request.kind == .policyClassify, DiscoveryFixtureDiagnostic.takePolicyTimingRead() else { return }
        let snapshot = TestingCustodianFailureWitness.readTiming(request)
        DiscoveryFixtureDiagnostic.recordPolicyTiming(snapshot, issued: request.budget.issued)
    }
}
private extension TestingCustodianFailureWitness {
    static func readTiming(_ request: UnvalidatedCustodyRequest) -> TestingPolicyHelperTiming.Snapshot? {
        // Bounded lexical owners: at most root/home/file, one read, no retry,
        // wait, pathname polling, descriptor probe or asynchronous continuation.
        var descriptors: [Int32] = []
        var result: TestingPolicyHelperTiming.Snapshot?
        do {
            guard let home = request.environment["HOME"], home.hasSuffix("/home") else { throw CustodyRecordError.fenced }
            let root = String(home.dropLast(5))
            let prefix = try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-authority-")
            guard root.hasPrefix(prefix), root.utf8.count == prefix.utf8.count + 6,
                  root.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  try TestIsolation.validateRoot(root) == root else { throw CustodyRecordError.fenced }
            let binding = try CustodyRecordBinding(request.binding)
            let filename = ".shadow-sync-custodian-observation-" + binding.requestID + ".jsonl"
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            func owned(_ fd: Int32) throws -> Int32 {
                guard fd >= 0 else { throw CustodyRecordError.fenced }
                descriptors.append(fd); return fd
            }
            let rootFD = try owned(open(root, flags | O_DIRECTORY))
            let homeFD = try owned(openat(rootFD, "home", flags | O_DIRECTORY))
            let fileFD = try owned(openat(homeFD, filename, flags))
            var rootNode = stat(), homeNode = stat(), fileNode = stat()
            guard fstat(rootFD, &rootNode) == 0, fstat(homeFD, &homeNode) == 0, fstat(fileFD, &fileNode) == 0,
                  safe(rootNode, directory: true), safe(homeNode, directory: true), safe(fileNode, directory: false),
                  fileNode.st_size > 0, fileNode.st_size <= 6144 else { throw CustodyRecordError.fenced }
            let rootACL = try PolicyAuthorityFile.privateStateACL(rootFD)
            let homeACL = try PolicyAuthorityFile.privateStateACL(homeFD)
            let fileACL = try PolicyAuthorityFile.privateStateACL(fileFD)
            func stable(_ a: stat, _ b: stat) -> Bool {
                same(a, b) && a.st_size == b.st_size
                    && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
                    && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
            }
            func validate() throws {
                var held = stat(), named = stat()
                guard fstat(rootFD, &held) == 0, stable(rootNode, held),
                      lstat(root, &named) == 0, stable(rootNode, named),
                      fstat(homeFD, &held) == 0, stable(homeNode, held),
                      fstatat(rootFD, "home", &named, AT_SYMLINK_NOFOLLOW) == 0, stable(homeNode, named),
                      fstat(fileFD, &held) == 0, stable(fileNode, held),
                      fstatat(homeFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0, stable(fileNode, named),
                      try PolicyAuthorityFile.privateStateACL(rootFD) == rootACL,
                      try PolicyAuthorityFile.privateStateACL(homeFD) == homeACL,
                      try PolicyAuthorityFile.privateStateACL(fileFD) == fileACL else { throw CustodyRecordError.fenced }
            }
            try validate()
            var bytes = [UInt8](repeating: 0, count: Int(fileNode.st_size))
            let count = bytes.withUnsafeMutableBytes { pread(fileFD, $0.baseAddress, $0.count, 0) }
            guard count == Int(fileNode.st_size) else { throw CustodyRecordError.fenced }
            try validate()
            result = try parseTiming(Data(bytes.prefix(count)), binding: binding,
                budget: request.budget, observedBefore: DispatchTime.now().uptimeNanoseconds)
        } catch { result = nil }
        // These are scoped close attempts, not kernel retirement capabilities.
        // Any observed error suppresses the observation. Never retry detached FDs.
        for fd in descriptors.reversed() { if close(fd) != 0 { result = nil } }
        return result
    }

    static func parseTiming(_ bytes: Data, binding: CustodyRecordBinding, budget: CustodyBudget,
                            observedBefore: UInt64) throws -> TestingPolicyHelperTiming.Snapshot {
        guard !bytes.isEmpty, bytes.count <= 6144, bytes.last == 10 else { throw CustodyRecordError.fenced }
        let lines = bytes.dropLast().split(separator: 10, omittingEmptySubsequences: false)
        guard (1...3).contains(lines.count) else { throw CustodyRecordError.fenced }
        var result: TestingPolicyHelperTiming.Snapshot?
        let names = TestingPolicyHelperTiming.Snapshot.names
        let keys = Set(names).union(["schema", "marker", "request", "generation", "nonce_sha256",
            "event", "trigger", "reason", "presence", "observed", "issued", "work"])
        for line in lines {
            guard !line.isEmpty, line.count + 1 <= 2048, result == nil else { throw CustodyRecordError.fenced }
            // Existing strict parser rejects duplicate keys, unsupported types,
            // signed/fractional/overflow numbers, trailing values and malformed UTF8.
            // Twenty fixed scalar fields exceed the configuration profile's 16-key cap.
            // The existing larger object profile is still bounded here by 2047 bytes
            // and exact keys; it grants no bundle or filesystem authority.
            var parser = try PolicyWireParser(Data(line), profile: .bundleLayout)
            let value = try parser.parse().object(keys: keys)
            guard try CustodyWire.text(value["schema"]) == "shadow-sync-custodian-failure-observation/v1",
                  try CustodyWire.text(value["marker"]) == "CUSTODIAN FIRST FAILURE WITNESS",
                  try CustodyWire.text(value["request"]) == binding.requestID,
                  try CustodyWire.text(value["generation"]) == binding.generation,
                  try CustodyWire.text(value["nonce_sha256"]) == binding.nonceSHA256,
                  try CustodyWire.text(value["event"]) == Event.policyTimingFailure.rawValue,
                  [Event.policyTimingFailure.rawValue, Event.drainingPersistence.rawValue,
                   Event.resourceRetirement.rawValue, Event.terminalPublication.rawValue,
                   Event.pendingPublication.rawValue, Event.spawnTargetFailure.rawValue,
                   Event.advanceStageFailure.rawValue, Event.repositoryPostflightFailure.rawValue]
                    .contains(try CustodyWire.text(value["trigger"])),
                  CustodyReason(rawValue: try CustodyWire.text(value["reason"])) != nil,
                  try CustodyWire.uint(value["issued"]) == budget.issued,
                  try CustodyWire.uint(value["work"]) == budget.work else { throw CustodyRecordError.fenced }
            let presence = try CustodyWire.uint(value["presence"]), observed = try CustodyWire.uint(value["observed"])
            guard presence <= 255, presence & 3 == 3, budget.issued <= observed, observed <= observedBefore else { throw CustodyRecordError.fenced }
            if try CustodyWire.text(value["trigger"]) == Event.policyTimingFailure.rawValue {
                guard try CustodyWire.text(value["reason"]) == CustodyReason.timeout.rawValue,
                      observed >= budget.work else { throw CustodyRecordError.fenced }
            }
            if let trigger = Event(rawValue: try CustodyWire.text(value["trigger"])),
               [Event.spawnTargetFailure, .advanceStageFailure, .repositoryPostflightFailure].contains(trigger) {
                guard let reason = CustodyReason(rawValue: try CustodyWire.text(value["reason"])),
                      trigger.observes(after: reason) else { throw CustodyRecordError.fenced }
            }
            let stamps = try names.map { try CustodyWire.uint(value[$0]) }
            var previous = budget.issued
            for (index, stamp) in stamps.enumerated() {
                if presence & (UInt64(1) << index) == 0 {
                    guard stamp == 0 else { throw CustodyRecordError.fenced }
                } else {
                    guard stamp >= previous, stamp <= observed else { throw CustodyRecordError.fenced }
                    previous = stamp
                }
            }
            result = TestingPolicyHelperTiming.Snapshot(presence: presence,
                constructorFinished: stamps[0], journalClaimFinished: stamps[1], readyQueued: stamps[2], admitConsumed: stamps[3],
                suspendedVerificationFinished: stamps[4], resumed: stamps[5], drained: stamps[6], terminalCommitted: stamps[7])
        }
        guard let result else { throw CustodyRecordError.fenced }
        return result
    }
}
#endif

#if SHADOW_SYNC_TESTING
private extension TestingCustodianFailureWitness {
    /// Pure codec/activation checks; invoked by the existing witness-slot case.
    /// No synthetic timestamp is passed to the live timing recorder.
    static func fixtureTimingCodec(_ binding: CustodyRecordBinding) throws {
        try check(TestingPolicyHelperWitness.shouldObserve(parentReason: nil, terminalReason: .timeout),
            "verified helper timeout reason lost without parent cancellation")
        try check(TestingPolicyHelperWitness.shouldObserve(parentReason: .timeout, terminalReason: nil),
            "parent timeout observation lost")
        try check(!TestingPolicyHelperWitness.shouldObserve(parentReason: nil, terminalReason: nil)
            && !TestingPolicyHelperWitness.shouldObserve(parentReason: CustodyReason.none, terminalReason: CustodyReason.none)
            && !TestingPolicyHelperWitness.shouldObserve(parentReason: nil, terminalReason: CustodyReason.none)
            && !TestingPolicyHelperWitness.shouldObserve(parentReason: nil, terminalReason: .invalidResource),
            "successful terminal enabled timing observation")
        let budget = try CustodyBudget(wire: .object(["issued": .unsigned(10), "work": .unsigned(100),
            "term": .unsigned(200), "kill": .unsigned(300), "receipt": .unsigned(400)]))
        let snapshot = TestingPolicyHelperTiming.Snapshot(presence: 63,
            constructorFinished: 20, journalClaimFinished: 30, readyQueued: 40, admitConsumed: 50,
            suspendedVerificationFinished: 60, resumed: 70)
        var fields = snapshot.fields
        fields["schema"] = "shadow-sync-custodian-failure-observation/v1"
        fields["marker"] = "CUSTODIAN FIRST FAILURE WITNESS"
        fields["request"] = binding.requestID; fields["generation"] = binding.generation
        fields["nonce_sha256"] = binding.nonceSHA256
        fields["event"] = Event.policyTimingFailure.rawValue; fields["trigger"] = Event.policyTimingFailure.rawValue
        fields["reason"] = CustodyReason.timeout.rawValue; fields["observed"] = UInt64(110)
        fields["issued"] = budget.issued; fields["work"] = budget.work
        func encode(_ value: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); return data
        }
        func parse(_ data: Data) throws -> TestingPolicyHelperTiming.Snapshot {
            try parseTiming(data, binding: binding, budget: budget, observedBefore: 120)
        }
        let good = try encode(fields), decoded = try parse(good)
        try check(decoded.presence == 63 && decoded.values == snapshot.values, "timing codec changed presence")
        try check(decoded.line(issued: 10) == "DISCOVERY POLICY HELPER TIMING presence=63 elapsed_ns=10,20,30,40,50,60,absent,absent\n",
            "timing absent phase became zero")
        try check(good.count <= 2048 && decoded.line(issued: 10).utf8.count <= 512, "timing codec ceilings")
        for (key, value) in [("request", "foreign" as Any), ("generation", "foreign"),
            ("nonce_sha256", String(repeating: "0", count: 64)), ("extra", 1), ("presence", 256),
            ("presence", 1), ("presence", true), ("presence", -1), ("presence", 1.5),
            ("resumed", 39), ("drained", 90), ("ready_queued", 121), ("observed", 99),
            ("observed", 121), ("issued", 11), ("work", 101), ("event", "controlEOF"),
            ("trigger", "controlEOF"), ("reason", "cancelled")] {
            var bad = fields; bad[key] = value
            try refusal { _ = try parse(encode(bad)) }
        }
        // Existing caught-error hooks can win the one-shot slot before timeout.
        // Accept their actual trigger while retaining the same cancellation filter.
        for trigger in [Event.spawnTargetFailure, .advanceStageFailure, .repositoryPostflightFailure] {
            var caught = fields
            caught["trigger"] = trigger.rawValue; caught["reason"] = CustodyReason.none.rawValue
            let caughtSnapshot = try parse(encode(caught))
            try check(caughtSnapshot.presence == snapshot.presence && caughtSnapshot.values == snapshot.values,
                "timing codec changed presence")
            for reason in [CustodyReason.cancelled, .timeout] {
                var refused = caught; refused["reason"] = reason.rawValue
                try refusal { _ = try parse(encode(refused)) }
            }
        }
        var missing = fields; missing.removeValue(forKey: "drained")
        try refusal { _ = try parse(encode(missing)) }
        try refusal { _ = try parse(good + good) }
        try refusal { _ = try parse(Data(good.dropLast())) }
        try refusal { _ = try parse(good + Data("{}\n".utf8)) }
        try refusal { _ = try parse(Data(repeating: 32, count: 6145)) }
        var long = fields; long["marker"] = String(repeating: "x", count: 2048)
        try refusal { _ = try parse(encode(long)) }
        let duplicate = Data(("{\"presence\":63," + String(decoding: good.dropFirst(), as: UTF8.self)).utf8)
        try refusal { _ = try parse(duplicate) }
        let malformed = Data([0xff, 10])
        try refusal { _ = try parse(malformed) }
        let maximum = TestingPolicyHelperTiming.Snapshot(presence: 255,
            constructorFinished: UInt64.max, journalClaimFinished: UInt64.max, readyQueued: UInt64.max,
            admitConsumed: UInt64.max, suspendedVerificationFinished: UInt64.max, resumed: UInt64.max,
            drained: UInt64.max, terminalCommitted: UInt64.max)
        try check(maximum.line(issued: 0).utf8.count <= 512, "maximum timing render exceeds cap")
        try check(TestingPolicyHelperTiming.activation(parentEnabled: true, fixedHelper: true, kind: .policyClassify),
            "fixed policy timing activation missing")
        try check(!TestingPolicyHelperTiming.activation(parentEnabled: false, fixedHelper: true, kind: .policyClassify)
            && !TestingPolicyHelperTiming.activation(parentEnabled: true, fixedHelper: false, kind: .policyClassify)
            && !TestingPolicyHelperTiming.activation(parentEnabled: true, fixedHelper: true, kind: .repositoryGit),
            "timing activation escaped closed helper")
    }
}
#endif
