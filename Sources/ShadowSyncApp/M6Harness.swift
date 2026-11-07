#if SHADOW_SYNC_TESTING
import CryptoKit
import ShadowSyncCatalog
import ShadowSyncCore
import Darwin
import Foundation

private struct M6LifecycleRequest: Codable {
    static let schemaName = "shadow-sync-m6-lifecycle/v1"
    let schema: String
    let testRoot: String
    let sourceN: String
    let sourceEquivalent: String
    let sourceN1: String
    let sourceHostN: String?
    let sourceHostN1: String?
    let sourcePredecessor: String?
    let operation: String?
    let faultStage: String?
}

private struct M6LifecycleResult: Codable {
    let schema: String
    let passed: [String]
    let launchctlInvocations: [String]
    let latestLogSHA256: String

    init(
        passed: [String],
        launchctlInvocations: [String],
        latestLogSHA256: String
    ) {
        schema = "shadow-sync-m6-lifecycle-result/v1"
        self.passed = passed
        self.launchctlInvocations = launchctlInvocations
        self.latestLogSHA256 = latestLogSHA256
    }
}

private final class M6TransactionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLayout: String?
    private var storedError: String?
    private var storedLaunchAuditCount: Int?

    func capture(launchAuditCount: Int? = nil, _ operation: () throws -> String) {
        lock.withLock {
            storedLaunchAuditCount = launchAuditCount
            do {
                storedLayout = try operation()
            } catch {
                storedError = String(describing: error)
            }
        }
    }

    var snapshot: (layout: String?, error: String?, launchAuditCount: Int?) {
        lock.withLock { (storedLayout, storedError, storedLaunchAuditCount) }
    }
}

private final class RecordingLaunchAgent: LaunchAgentControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var program: String?
    private var invocations: [String] = []
    private var failNextBootstrap = false
    private var queryFails = false
    private var stateOverride: LaunchAgentState?
    private var stopped = false

    func state(label: String) -> LaunchAgentState {
        lock.withLock {
            if queryFails { return .queryFailure }
            if let stateOverride { return stateOverride }
            return program.map {
                LaunchAgentState.loaded(
                    program: $0,
                    processID: stopped ? nil : getpid()
                )
            } ?? LaunchAgentState.absent
        }
    }

    func processDisposition(
        processID: pid_t,
        expectedProgram: String
    ) -> LaunchAgentProcessDisposition {
        if processID == getpid() { return .matching }
        return SystemLaunchAgentController().processDisposition(
            processID: processID,
            expectedProgram: expectedProgram
        )
    }

    func bootstrap(label: String, plist: String, expectedProgram: String) throws {
        let dictionary = NSDictionary(contentsOfFile: plist) as? [String: Any]
        let arguments = dictionary?["ProgramArguments"] as? [String]
        try lock.withLock {
            invocations.append("bootstrap:\(label)")
            if failNextBootstrap {
                failNextBootstrap = false
                throw M6HarnessError.message("injected bootstrap failure")
            }
            guard arguments == [
                expectedProgram, InstallationPaths.managedHostArgument,
            ] || arguments == [expectedProgram] else {
                throw M6HarnessError.message("bootstrap program mismatch")
            }
            program = expectedProgram
            stopped = false
        }
    }

    func kickstart(label: String, expectedProgram: String) throws {
        try lock.withLock {
            invocations.append("kickstart:\(label)")
            guard program == expectedProgram else {
                throw M6HarnessError.message("kickstart program mismatch")
            }
        }
    }

    func bootout(label: String, expectedProgram: String) throws {
        try lock.withLock {
            invocations.append("bootout:\(label)")
            if let program, program != expectedProgram {
                throw M6HarnessError.message("bootout program mismatch")
            }
            program = nil
            stopped = false
        }
    }

    func failBootstrapOnce() {
        lock.withLock { failNextBootstrap = true }
    }

    func setQueryFailure(_ value: Bool) {
        lock.withLock { queryFails = value }
    }

    func setStateOverride(_ value: LaunchAgentState?) {
        lock.withLock { stateOverride = value }
    }

    func setStopped(_ value: Bool) {
        lock.withLock { stopped = value }
    }

    var audit: [String] {
        lock.withLock { invocations }
    }
}

private final class RecordingHost: InstalledHostControlling, @unchecked Sendable {
    private let launcher: RecordingLaunchAgent
    private let lock = NSLock()
    private var exits = 0
    private var failNextReadiness = false

    init(launcher: RecordingLaunchAgent) {
        self.launcher = launcher
    }

    func requestExit(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity
    ) throws {
        lock.withLock { exits += 1 }
    }

    func isReady(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> Bool {
        let fail = lock.withLock { () -> Bool in
            if failNextReadiness, timeout > 0 {
                failNextReadiness = false
                return true
            }
            return false
        }
        if fail { return false }
        return launcher.state(label: InstallationPaths.label)
            == .loaded(program: executable, processID: getpid())
    }

    func readyIdentity(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> ProcessIdentity? {
        guard isReady(
            location: location,
            executable: executable,
            release: release,
            timeout: timeout
        ) else {
            return nil
        }
        return try? ProcessIdentity.capture(
            processID: getpid(),
            generation: RunIdentity.make()
        )
    }

    func failReadinessOnce() {
        lock.withLock { failNextReadiness = true }
    }
}

private final class ManagedStartupLaunchAgent:
    LaunchAgentControlling, @unchecked Sendable
{
    private let program: String
    private let publishedAfterStateCalls: Int
    private let publishedProcessID: pid_t
    private let releaseLauncherAtStateCall: Int?
    private let lock = NSLock()
    private var heldLauncher: LauncherAuthority?
    private var stateCallCount = 0
    private var kickstartCount = 0
    private var releasedLauncherCount = 0

    init(
        program: String,
        publishedAfterStateCalls: Int,
        publishedProcessID: pid_t = getpid(),
        heldLauncher: LauncherAuthority? = nil,
        releaseLauncherAtStateCall: Int? = nil
    ) {
        self.program = program
        self.publishedAfterStateCalls = publishedAfterStateCalls
        self.publishedProcessID = publishedProcessID
        self.heldLauncher = heldLauncher
        self.releaseLauncherAtStateCall = releaseLauncherAtStateCall
    }

    func state(label: String) -> LaunchAgentState {
        let snapshot = lock.withLock {
            stateCallCount += 1
            let launcher: LauncherAuthority?
            if stateCallCount == releaseLauncherAtStateCall {
                launcher = heldLauncher
                heldLauncher = nil
                releasedLauncherCount += launcher == nil ? 0 : 1
            } else {
                launcher = nil
            }
            return (
                stateCallCount > publishedAfterStateCalls,
                launcher
            )
        }
        snapshot.1?.release()
        return .loaded(
            program: program,
            processID: snapshot.0 ? publishedProcessID : nil
        )
    }

    func processDisposition(
        processID: pid_t,
        expectedProgram: String
    ) -> LaunchAgentProcessDisposition {
        processID == publishedProcessID && expectedProgram == program
            ? .matching
            : .mismatch
    }

    func bootstrap(label: String, plist: String, expectedProgram: String) throws {
        throw M6HarnessError.message("managed startup unexpectedly bootstrapped")
    }

    func kickstart(label: String, expectedProgram: String) throws {
        guard expectedProgram == program else {
            throw M6HarnessError.message("managed startup program changed")
        }
        lock.withLock { kickstartCount += 1 }
    }

    func bootout(label: String, expectedProgram: String) throws {
        throw M6HarnessError.message("managed startup unexpectedly booted out")
    }

    var kickstarts: Int {
        lock.withLock { kickstartCount }
    }

    var stateCalls: Int {
        lock.withLock { stateCallCount }
    }

    var launcherReleases: Int {
        lock.withLock { releasedLauncherCount }
    }

    deinit {
        let launcher = lock.withLock { () -> LauncherAuthority? in
            defer { heldLauncher = nil }
            return heldLauncher
        }
        launcher?.release()
    }
}

private final class NeverReadyHost: InstalledHostControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var queryCount = 0

    func requestExit(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity
    ) throws {
        throw M6HarnessError.message("pending launch unexpectedly requested exit")
    }

    func isReady(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> Bool {
        lock.withLock { queryCount += 1 }
        return false
    }

    func readyIdentity(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> ProcessIdentity? {
        lock.withLock { queryCount += 1 }
        return nil
    }

    var queries: Int {
        lock.withLock { queryCount }
    }
}

private final class DelayedReadyHost: InstalledHostControlling, @unchecked Sendable {
    private let delegate: any InstalledHostControlling
    private let readyAfterQueries: Int
    private let lock = NSLock()
    private var queryCount = 0

    init(delegate: any InstalledHostControlling, readyAfterQueries: Int) {
        self.delegate = delegate
        self.readyAfterQueries = readyAfterQueries
    }

    func requestExit(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity
    ) throws {
        try delegate.requestExit(
            location: location,
            executable: executable,
            release: release
        )
    }

    func isReady(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> Bool {
        readyIdentity(
            location: location,
            executable: executable,
            release: release,
            timeout: timeout
        ) != nil
    }

    func readyIdentity(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> ProcessIdentity? {
        let query = lock.withLock {
            queryCount += 1
            return queryCount
        }
        guard query > readyAfterQueries else { return nil }
        return delegate.readyIdentity(
            location: location,
            executable: executable,
            release: release,
            timeout: timeout
        )
    }
}

private final class HostStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() -> Bool {
        lock.withLock { stopped = true }
        return true
    }
    var value: Bool { lock.withLock { stopped } }
}

private struct M6PersistedLaunchState: Codable {
    let program: String
    let identity: ProcessIdentity?
}

private struct M6DeadHostIdentity: Codable {
    let processID: pid_t
    let processGroupID: pid_t
    let userID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
    let generation: String
}

private struct M6DeadHostRegistration: Codable {
    let schema: String
    let identity: M6DeadHostIdentity
    let release: ReleaseIdentity
}

private enum M6PostKickstartObservation: Equatable {
    case nilPID
    case stalePID
    case matchingPID
    case conflictingPID
    case queryFailure
}

private enum M6HostExitMode: String, Sendable {
    case clean
    case stale
}

private struct M6HostExitBehavior: Sendable {
    let delay: TimeInterval
    let mode: M6HostExitMode

    static let immediate = M6HostExitBehavior(delay: 0, mode: .clean)
}

private final class ProcessLaunchAgent: LaunchAgentControlling, @unchecked Sendable {
    private let root: String
    private let statePath: String
    private let lock = NSLock()
    private var program: String?
    private var identity: ProcessIdentity?
    private var process: Process?
    private var stateOverride: LaunchAgentState?
    private var kickstartCount = 0
    private var nextPostKickstartObservations: [M6PostKickstartObservation] = []
    private var postKickstartObservations: [M6PostKickstartObservation] = []
    private var consumedPostKickstartObservations: [M6PostKickstartObservation] = []
    private var nextHostExitBehavior = M6HostExitBehavior.immediate
    private var returnFromBootoutBeforeDrain = false

    init(root: String) {
        self.root = root
        statePath = root + "/simulated-launchd.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let persisted = try? JSONDecoder().decode(
               M6PersistedLaunchState.self,
               from: data
           ) {
            program = persisted.program
            identity = persisted.identity
        }
    }

    func state(label: String) -> LaunchAgentState {
        lock.withLock {
            if let stateOverride { return stateOverride }
            guard let program else { return .absent }
            if !postKickstartObservations.isEmpty {
                let observation = postKickstartObservations.removeFirst()
                consumedPostKickstartObservations.append(observation)
                switch observation {
                case .nilPID:
                    return .loaded(program: program, processID: nil)
                case .stalePID:
                    return .loaded(program: program, processID: 999_999)
                case .matchingPID:
                    return .loaded(
                        program: program,
                        processID: identity?.processID
                    )
                case .conflictingPID:
                    return .loaded(program: program, processID: getpid())
                case .queryFailure:
                    return .queryFailure
                }
            }
            let pid = identity?.isCurrent(requireGroupLeader: false) == true
                ? identity?.processID
                : nil
            return .loaded(program: program, processID: pid)
        }
    }

    func processDisposition(
        processID: pid_t,
        expectedProgram: String
    ) -> LaunchAgentProcessDisposition {
        if processID == getpid() { return .matching }
        return SystemLaunchAgentController().processDisposition(
            processID: processID,
            expectedProgram: expectedProgram
        )
    }

    func setStateOverride(_ value: LaunchAgentState?) {
        lock.withLock { stateOverride = value }
    }

    func configurePostKickstartObservations(
        _ observations: [M6PostKickstartObservation]
    ) {
        lock.withLock {
            nextPostKickstartObservations = observations
            postKickstartObservations = []
            consumedPostKickstartObservations = []
        }
    }

    func clearPostKickstartObservations() {
        lock.withLock {
            nextPostKickstartObservations = []
            postKickstartObservations = []
            consumedPostKickstartObservations = []
        }
    }

    var consumedPostKickstartStates: [M6PostKickstartObservation] {
        lock.withLock { consumedPostKickstartObservations }
    }

    func configureNextHostExit(
        delay: TimeInterval,
        mode: M6HostExitMode
    ) {
        lock.withLock {
            nextHostExitBehavior = M6HostExitBehavior(
                delay: delay,
                mode: mode
            )
        }
    }

    func setReturnFromBootoutBeforeDrain(_ value: Bool) {
        lock.withLock { returnFromBootoutBeforeDrain = value }
    }

    func bootstrap(label: String, plist: String, expectedProgram: String) throws {
        guard let dictionary = NSDictionary(contentsOfFile: plist) as? [String: Any],
              dictionary["ProgramArguments"] as? [String] == [
                expectedProgram, InstallationPaths.managedHostArgument,
              ],
              dictionary["RunAtLoad"] as? Bool == false else {
            throw M6HarnessError.message("bootstrap arguments mismatch")
        }
        lock.withLock {
            program = expectedProgram
            identity = nil
            process = nil
        }
        try persist()
    }

    private func start(expectedProgram: String) throws {
        let exitBehavior = lock.withLock {
            defer { nextHostExitBehavior = .immediate }
            return nextHostExitBehavior
        }
        let ready = root + "/host-ready-\(RunIdentity.make())"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: expectedProgram)
        child.arguments = [
            "--shadow-sync-m6-host-helper",
            root,
            ready,
            String(exitBehavior.delay),
            exitBehavior.mode.rawValue,
        ]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let launchGeneration = RunIdentity.make()
        var launchIdentity = try ProcessIdentity.capture(
            processID: child.processIdentifier,
            generation: launchGeneration,
            expectedExecutablePath: expectedProgram
        )
        let identitySettlement = MonotonicDeadline(seconds: 0.5)
        var identitySettled = false
        repeat {
            Thread.sleep(forTimeInterval: 0.01)
            let observed = try ProcessIdentity.capture(
                processID: child.processIdentifier,
                generation: launchGeneration,
                expectedExecutablePath: expectedProgram
            )
            if observed == launchIdentity {
                identitySettled = true
                break
            }
            launchIdentity = observed
        } while !identitySettlement.hasExpired
        guard identitySettled else {
            throw M6HarnessError.message(
                "simulated launchd process identity did not settle"
            )
        }
        lock.withLock {
            program = expectedProgram
            identity = launchIdentity
            process = child
        }
        try persist()
        let deadline = MonotonicDeadline(seconds: 5)
        while !FileManager.default.fileExists(atPath: ready),
              child.isRunning,
              !deadline.hasExpired {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: ready),
              child.isRunning else {
            _ = OwnedProcessReaper.wait(for: child, timeout: 0)
            throw M6HarnessError.message(
                "isolated installed host missed its readiness deadline"
            )
        }
        try? FileManager.default.removeItem(atPath: ready)
        let state = try SecureStateDirectory.openExisting(
            StateLocation.isolated(root: root)
        )
        let registration = try HostRegistrationStore.read(state: state)
        lock.withLock {
            identity = registration.identity
        }
        try persist()
    }

    func kickstart(label: String, expectedProgram: String) throws {
        lock.withLock { kickstartCount += 1 }
        guard case let .loaded(program, processID) = state(label: label),
              program == expectedProgram else {
            throw M6HarnessError.message("kickstart state mismatch")
        }
        if let processID,
           processDisposition(
               processID: processID,
               expectedProgram: expectedProgram
           ) != .absent {
            throw M6HarnessError.message("kickstart state mismatch")
        }
        if let stopped = lock.withLock({ process }), !stopped.isRunning {
            stopped.waitUntilExit()
            lock.withLock {
                process = nil
                stateOverride = nil
            }
        } else {
            lock.withLock { stateOverride = nil }
        }
        try start(expectedProgram: expectedProgram)
        lock.withLock {
            postKickstartObservations = nextPostKickstartObservations
            nextPostKickstartObservations = []
        }
    }

    var kickstarts: Int {
        lock.withLock { kickstartCount }
    }

    func bootout(label: String, expectedProgram: String) throws {
        let snapshot = lock.withLock { (process, identity, program) }
        guard snapshot.2 == nil || snapshot.2 == expectedProgram else {
            throw M6HarnessError.message("bootout program mismatch")
        }
        if lock.withLock({ returnFromBootoutBeforeDrain }),
           snapshot.1?.isCurrent(requireGroupLeader: false) == true {
            lock.withLock { program = nil }
            return
        }
        let deadline = MonotonicDeadline(seconds: 5)
        while snapshot.1?.isCurrent(requireGroupLeader: false) == true,
              !deadline.hasExpired {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let identity = snapshot.1,
           identity.isCurrent(requireGroupLeader: false) {
            _ = OwnedProcessSignal.send(
                SIGTERM,
                to: identity,
                expectedGeneration: identity.generation
            )
            let termDeadline = MonotonicDeadline(seconds: 2)
            while identity.isCurrent(requireGroupLeader: false),
                  !termDeadline.hasExpired {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !identity.isCurrent(requireGroupLeader: false) else {
                throw M6HarnessError.message("simulated launchd host did not exit")
            }
        }
        if let child = snapshot.0,
           !OwnedProcessReaper.wait(for: child, timeout: 0) {
            throw M6HarnessError.message("simulated launchd host was not reaped")
        }
        lock.withLock {
            process = nil
            program = nil
            identity = nil
        }
        try? FileManager.default.removeItem(atPath: statePath)
    }

    func waitForCurrentHostExit(timeout: TimeInterval) -> Bool {
        guard let identity = lock.withLock({ identity }) else { return true }
        let deadline = MonotonicDeadline(seconds: timeout)
        while identity.isCurrent(requireGroupLeader: false),
              !deadline.hasExpired {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !identity.isCurrent(requireGroupLeader: false)
    }

    @discardableResult
    func terminateWithoutCleanup(expectedProgram: String) throws -> pid_t {
        let snapshot = lock.withLock { (process, identity, program) }
        guard snapshot.2 == expectedProgram,
              let child = snapshot.0,
              let identity = snapshot.1,
              identity.executablePath == expectedProgram,
              identity.isCurrent(requireGroupLeader: false) else {
            throw M6HarnessError.message(
                "could not verify the isolated host before abrupt termination"
            )
        }
        guard kill(identity.processID, SIGTERM) == 0 else {
            throw M6HarnessError.message("could not terminate the isolated host")
        }
        let termination = MonotonicDeadline(seconds: 2)
        while identity.isCurrent(requireGroupLeader: false),
              !termination.hasExpired {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if identity.isCurrent(requireGroupLeader: false) {
            guard kill(identity.processID, SIGKILL) == 0 else {
                throw M6HarnessError.message("could not kill the isolated host")
            }
            let killed = MonotonicDeadline(seconds: 2)
            while identity.isCurrent(requireGroupLeader: false),
                  !killed.hasExpired {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard !identity.isCurrent(requireGroupLeader: false) else {
            throw M6HarnessError.message("isolated host survived abrupt termination")
        }
        child.waitUntilExit()
        lock.withLock { process = nil }
        return identity.processID
    }

    deinit {
        let snapshot = lock.withLock { (process, identity) }
        if snapshot.0 != nil,
           let identity = snapshot.1,
           identity.isCurrent(requireGroupLeader: false) {
            _ = OwnedProcessSignal.send(
                SIGTERM,
                to: identity,
                expectedGeneration: identity.generation
            )
        }
        if let child = snapshot.0 {
            _ = OwnedProcessReaper.wait(for: child, timeout: 0)
        }
    }

    private func persist() throws {
        let snapshot = lock.withLock { (program, identity) }
        guard let program = snapshot.0 else {
            throw M6HarnessError.message("simulated launchd state is incomplete")
        }
        var data = try JSONEncoder().encode(
            M6PersistedLaunchState(
                program: program,
                identity: snapshot.1
            )
        )
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        guard chmod(statePath, 0o600) == 0 else {
            throw M6HarnessError.message("could not secure simulated launchd state")
        }
    }
}

enum M6AppDriver {
    private static let mode = "--shadow-sync-m6-lifecycle-channel"

    static func dispatch(arguments: [String]) -> Int32? {
        if arguments.count == 3, arguments[1] == "--shadow-sync-m6-cleanup-root" {
            return cleanupRoot(arguments[2])
        }
        if arguments.count == 6, arguments[1] == "--shadow-sync-m6-lock-contender" {
            return lockContender(
                kind: arguments[2],
                root: arguments[3],
                gate: Int32(arguments[4]) ?? -1,
                result: Int32(arguments[5]) ?? -1
            )
        }
        if arguments.count == 6, arguments[1] == "--shadow-sync-m6-host-helper",
           let delay = TimeInterval(arguments[4]),
           delay >= 0,
           delay <= 6,
           let mode = M6HostExitMode(rawValue: arguments[5]) {
            return hostHelper(
                root: arguments[2],
                ready: arguments[3],
                exitDelay: delay,
                exitMode: mode
            )
        }
        guard arguments.count >= 2, arguments[1] == mode else { return nil }
        guard arguments.count == 3,
              let descriptor = Int32(arguments[2]),
              descriptor >= 0,
              fcntl(descriptor, F_GETFD) >= 0 else {
            return 2
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            return 2
        }
        do {
            let request = try JSONLineChannel.readOne(
                M6LifecycleRequest.self,
                descriptor: descriptor
            )
            guard request.schema == M6LifecycleRequest.schemaName else {
                throw M6HarnessError.message("invalid M6 request schema")
            }
            let root = try TestIsolation.validateRoot(request.testRoot)
            for bundle in [request.sourceN, request.sourceEquivalent, request.sourceN1] {
                guard bundle.hasPrefix(root + "/"), !bundle.contains("..") else {
                    throw M6HarnessError.message("source bundle escaped the test root")
                }
                for bundle in [
                    request.sourceHostN,
                    request.sourceHostN1,
                    request.sourcePredecessor,
                ].compactMap({ $0 }) {
                    guard bundle.hasPrefix(root + "/"), !bundle.contains("..") else {
                        throw M6HarnessError.message("host source escaped the test root")
                    }
                }
            }
            let result: M6LifecycleResult
            switch request.operation ?? "suite" {
            case "suite":
                result = try run(
                    root: root,
                    sourceN: request.sourceN,
                    sourceEquivalent: request.sourceEquivalent,
                    sourceN1: request.sourceN1
                )
            case "v4-migration":
                result = try v4Migration(
                    root: root,
                    sourceN: request.sourceN,
                    sourceN1: request.sourceN1
                )
            case "crash":
                guard let stage = request.faultStage else {
                    throw M6HarnessError.message("crash operation requires a fault stage")
                }
                try crash(
                    root: root,
                    sourceN: request.sourceN,
                    sourceN1: request.sourceN1,
                    stage: stage
                )
                throw M6HarnessError.message("crash fault did not terminate")
            case "repair-crash":
                guard let stage = request.faultStage else {
                    throw M6HarnessError.message("repair-crash operation requires a fault stage")
                }
                try repairCrash(
                    root: root,
                    sourceN: request.sourceN,
                    sourceN1: request.sourceN1,
                    stage: stage
                )
                throw M6HarnessError.message("repair crash fault did not terminate")
            case "first-crash":
                guard let stage = request.faultStage else {
                    throw M6HarnessError.message("first-crash operation requires a fault stage")
                }
                try firstCrash(
                    root: root,
                    sourceN1: request.sourceN1,
                    stage: stage
                )
                throw M6HarnessError.message("first-install crash fault did not terminate")
            case "recover":
                result = try recover(
                    root: root,
                    sourceN1: request.sourceN1
                )
            case "admission":
                let paths = try InstallationPaths.isolated(root: root)
                let launcher = ProcessLaunchAgent(root: root)
                do {
                    _ = try InstalledStateAdmission.verifyStatic(
                        paths: paths,
                        launchAgent: launcher,
                        allowedProcessID: nil
                    )
                    result = M6LifecycleResult(
                        passed: ["admission-succeeded"],
                        launchctlInvocations: [],
                        latestLogSHA256: ""
                    )
                } catch InstallationLifecycleError.unexpectedResidue {
                    result = M6LifecycleResult(
                        passed: ["lifecycle-residue-admission-refused"],
                        launchctlInvocations: [],
                        latestLogSHA256: ""
                    )
                } catch InstallationLifecycleError.launchAgentMismatch {
                    result = M6LifecycleResult(
                        passed: ["launchd-incomplete-admission-refused"],
                        launchctlInvocations: [],
                        latestLogSHA256: ""
                    )
                } catch InstallationLifecycleError.invalidSignature {
                    if FileManager.default.fileExists(atPath: paths.app)
                        || FileManager.default.fileExists(atPath: paths.launchAgent) {
                        result = M6LifecycleResult(
                            passed: ["invalid-signature-admission-refused"],
                            launchctlInvocations: [],
                            latestLogSHA256: ""
                        )
                    } else {
                        result = M6LifecycleResult(
                            passed: ["product-absent-admission-refused"],
                            launchctlInvocations: [],
                            latestLogSHA256: ""
                        )
                    }
                }
            case "real-host":
                guard let sourceHostN = request.sourceHostN,
                      let sourceHostN1 = request.sourceHostN1 else {
                    throw M6HarnessError.message("real-host operation requires host sources")
                }
                result = try realHost(
                    root: root,
                    sourceN: sourceHostN,
                    sourceN1: sourceHostN1
                )
            case "compatibility":
                guard let sourceHostN1 = request.sourceHostN1,
                      let sourcePredecessor = request.sourcePredecessor else {
                    throw M6HarnessError.message(
                        "compatibility operation requires current and predecessor sources"
                    )
                }
                result = try predecessorCompatibility(
                    root: root,
                    sourceCurrent: sourceHostN1,
                    sourcePredecessor: sourcePredecessor
                )
            case "recovery-pairing":
                guard let sourceHostN1 = request.sourceHostN1,
                      let sourcePredecessor = request.sourcePredecessor else {
                    throw M6HarnessError.message(
                        "recovery-pairing operation requires current "
                            + "and predecessor sources"
                    )
                }
                result = try recoveryPairing(
                    root: root,
                    sourceCurrent: sourceHostN1,
                    sourcePredecessor: sourcePredecessor
                )
            case "stopped-job":
                guard let sourceHostN = request.sourceHostN else {
                    throw M6HarnessError.message(
                        "stopped-job operation requires a host source"
                    )
                }
                result = try stoppedJob(
                    root: root,
                    sourceN: sourceHostN
                )
            case "post-start-convergence":
                guard let sourceHostN = request.sourceHostN else {
                    throw M6HarnessError.message(
                        "post-start-convergence requires a host source"
                    )
                }
                result = try postStartConvergence(
                    root: root,
                    sourceN: sourceHostN
                )
            case "rollback-drain":
                guard let sourceHostN = request.sourceHostN,
                      let sourceHostN1 = request.sourceHostN1 else {
                    throw M6HarnessError.message(
                        "rollback-drain operation requires host sources"
                    )
                }
                result = try rollbackDrain(
                    root: root,
                    sourceN: sourceHostN,
                    sourceN1: sourceHostN1
                )
            case "uninstall-crash":
                guard let stage = request.faultStage else {
                    throw M6HarnessError.message("uninstall-crash requires a fault stage")
                }
                try uninstallCrash(root: root, sourceN: request.sourceN, stage: stage)
                throw M6HarnessError.message("uninstall crash fault did not terminate")
            case "uninstall-recover":
                result = try uninstallRecover(root: root)
            case "install-only":
                let paths = try InstallationPaths.isolated(root: root)
                try TestIsolation.initializeState(at: paths.state)
                let launcher = RecordingLaunchAgent()
                let host = RecordingHost(launcher: launcher)
                _ = try InstallationLifecycle(
                    paths: paths,
                    launchAgent: launcher,
                    host: host
                ).install(sourceBundle: request.sourceN)
                result = M6LifecycleResult(
                    passed: ["concurrent-promotion-winner"],
                    launchctlInvocations: launcher.audit,
                    latestLogSHA256: ""
                )
            default:
                throw M6HarnessError.message("unknown M6 operation")
            }
            try JSONLineChannel.write(result, descriptor: descriptor)
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("M6 harness failed: \(Redactor.sanitize(String(describing: error)))\n".utf8)
            )
            return 2
        }
    }

    private static func cleanupRoot(_ requestedRoot: String) -> Int32 {
        do {
            let root = try TestIsolation.validateRoot(requestedRoot)
            let enumerator = FileManager.default.enumerator(atPath: root)
            while let relative = enumerator?.nextObject() as? String {
                guard relative.hasSuffix("/simulated-launchd.json")
                        || relative == "simulated-launchd.json" else {
                    continue
                }
                let path = root + "/" + relative
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let persisted = try JSONDecoder().decode(
                    M6PersistedLaunchState.self,
                    from: data
                )
                guard let identity = persisted.identity else {
                    try? FileManager.default.removeItem(
                        atPath: path
                    )
                    continue
                }
                guard identity.executablePath.hasPrefix(root + "/") else {
                    throw M6HarnessError.message("cleanup identity escaped test root")
                }
                if identity.isCurrent(requireGroupLeader: false) {
                    _ = OwnedProcessSignal.send(
                        SIGTERM,
                        to: identity,
                        expectedGeneration: identity.generation
                    )
                    let deadline = MonotonicDeadline(seconds: 2)
                    while identity.isCurrent(requireGroupLeader: false),
                          !deadline.hasExpired {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                if identity.isCurrent(requireGroupLeader: false) {
                    _ = OwnedProcessSignal.send(
                        SIGKILL,
                        to: identity,
                        expectedGeneration: identity.generation
                    )
                    let deadline = MonotonicDeadline(seconds: 2)
                    while identity.isCurrent(requireGroupLeader: false),
                          !deadline.hasExpired {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                guard !identity.isCurrent(requireGroupLeader: false) else {
                    throw M6HarnessError.message("owned helper did not exit")
                }
                try? FileManager.default.removeItem(atPath: path)
            }
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("M6 cleanup failed: \(error)\n".utf8)
            )
            return 2
        }
    }

    private static func lockContender(
        kind: String,
        root: String,
        gate: Int32,
        result: Int32
    ) -> Int32 {
        guard gate >= 0, result >= 0 else { return 2 }
        var byte: UInt8 = 0
        guard Darwin.read(gate, &byte, 1) == 1,
              byte == UInt8(ascii: "G") else { return 2 }
        do {
            let location = try StateLocation.isolated(
                root: TestIsolation.validateRoot(root)
            )
            switch kind {
            case "lifecycle":
                let authority = try RunAuthority.acquireLifecycleMutation(at: location)
                try writeRaceResult("S", to: result)
                Thread.sleep(forTimeInterval: 0.5)
                authority.release()
            case "run":
                let authority = try RunAuthority.acquireRun(at: location)
                try writeRaceResult("S", to: result)
                Thread.sleep(forTimeInterval: 0.5)
                authority.release()
            case "launcher":
                let authority = try LauncherAuthority.acquire(at: location)
                try writeRaceResult("S", to: result)
                Thread.sleep(forTimeInterval: 0.5)
                authority.release()
            default:
                return 2
            }
            return 0
        } catch SecureStateError.contention {
            try? writeRaceResult("C", to: result)
            return 0
        } catch {
            try? writeRaceResult("F", to: result)
            return 2
        }
    }

    private static func writeRaceResult(_ value: Character, to descriptor: Int32) throws {
        var byte = value.asciiValue!
        guard Darwin.write(descriptor, &byte, 1) == 1 else {
            throw M6HarnessError.message("could not write race result")
        }
    }

    private static func hostHelper(
        root: String,
        ready: String,
        exitDelay: TimeInterval,
        exitMode: M6HostExitMode
    ) -> Int32 {
        do {
            let root = try TestIsolation.validateRoot(root)
            guard ready.hasPrefix(root + "/"), !ready.contains("..") else {
                throw M6HarnessError.message("host ready marker escaped test root")
            }
            let paths = try InstallationPaths.isolated(root: root)
            let executable = paths.app + "/Contents/MacOS/ShadowSync"
            let release = try ReleaseIdentity.load(bundlePath: paths.app)
            let launchStatePath = root + "/simulated-launchd.json"
            let launchDeadline = MonotonicDeadline(seconds: 5)
            var launchState: M6PersistedLaunchState?
            repeat {
                if let data = try? Data(
                    contentsOf: URL(fileURLWithPath: launchStatePath)
                ),
                   let decoded = try? JSONDecoder().decode(
                    M6PersistedLaunchState.self,
                    from: data
                   ) {
                    if decoded.program == executable,
                       let identity = decoded.identity,
                       identity.processID == getpid(),
                       identity.isCurrent(requireGroupLeader: false) {
                        launchState = decoded
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.01)
            } while !launchDeadline.hasExpired
            guard launchState != nil else {
                throw M6HarnessError.message(
                    "simulated launchd did not publish the isolated host identity"
                )
            }
            let authority = try InstalledStateAdmission.admitHost(
                paths: paths,
                launchAgent: ProcessLaunchAgent(root: root),
                processID: getpid()
            )
            let flag = HostStopFlag()
            let server = try HostControlServer(
                authority: authority,
                executablePath: executable,
                releaseIdentity: release,
                onActivation: { true },
                onLifecycleExit: flag.stop
            )
            try server.start()
            try Data("ready\n".utf8).write(to: URL(fileURLWithPath: ready))
            while !flag.value {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if exitDelay > 0 {
                Thread.sleep(forTimeInterval: exitDelay)
            }
            if exitMode == .stale {
                _exit(0)
            }
            server.stop()
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("M6 isolated host failed: \(error)\n".utf8)
            )
            return 2
        }
    }

    private static func realHost(
        root: String,
        sourceN: String,
        sourceN1: String
    ) throws -> M6LifecycleResult {
        let paths = try InstallationPaths.isolated(root: root)
        try TestIsolation.initializeState(at: paths.state)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )
        _ = try lifecycle.install(sourceBundle: sourceN)
        _ = try lifecycle.doctor()
        let installedExecutable = paths.app + "/Contents/MacOS/ShadowSync"
        let tamper = try FileHandle(
            forWritingTo: URL(fileURLWithPath: installedExecutable)
        )
        try tamper.seekToEnd()
        try tamper.write(contentsOf: Data([0x00]))
        try tamper.close()
        try expectFailure("real-host reconcile replaced a corrupted app") {
            _ = try lifecycle.install(sourceBundle: sourceN1)
        }
        _ = try lifecycle.install(sourceBundle: sourceN1, intent: .repair)
        _ = try lifecycle.doctor()
        try lifecycle.uninstall()
        let stopped = try stoppedJob(root: root, sourceN: sourceN)
        let rollbackRoot = root + "/rollback-drain"
        try FileManager.default.createDirectory(
            atPath: rollbackRoot + "/home",
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rollback = try rollbackDrain(
            root: rollbackRoot,
            sourceN: sourceN,
            sourceN1: sourceN1
        )
        return M6LifecycleResult(
            passed: [
                "real-host-lock-socket-readiness",
                "real-host-n-to-n-plus-one-handoff",
                "real-host-corrupted-bundle-repair",
                "real-host-verified-uninstall",
            ] + stopped.passed + rollback.passed,
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func predecessorCompatibility(
        root: String,
        sourceCurrent: String,
        sourcePredecessor: String
    ) throws -> M6LifecycleResult {
        let predecessorRelease = try ReleaseIdentity.load(
            bundlePath: sourcePredecessor
        )
        let currentRelease = try ReleaseIdentity.load(
            bundlePath: sourceCurrent
        )
        try check(
            predecessorRelease.sourceRevision
                == "783fa0587cccdb2c88a6a8b246c1ed0ed536e60b"
                && predecessorRelease.sourceInputSHA256
                    == "0aaaad83bb080e6ed0db71de2df9b9010d63a79ceb78dfee73785cfe218ffa7c"
                && predecessorRelease.releaseContractSHA256
                    == "08d13f1f8425e952a2aa6d8662eebc846066d135fec806f82b14ba44b9175b5f",
            "predecessor fixture did not use the live-main release identity"
        )
        var passed: [String] = []

        func prepare(_ name: String) throws -> (
            InstallationPaths,
            RecordingLaunchAgent,
            RecordingHost,
            InstallationLifecycle,
            String,
            String
        ) {
            let caseRoot = root + "/" + name
            try FileManager.default.createDirectory(
                atPath: caseRoot + "/home",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let paths = try InstallationPaths.isolated(root: caseRoot)
            try TestIsolation.initializeState(at: paths.state)
            let launcher = RecordingLaunchAgent()
            let host = RecordingHost(launcher: launcher)
            let lifecycle = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host
            )
            _ = try lifecycle.install(sourceBundle: sourcePredecessor)
            try renderLaunchAgent(
                template: sourcePredecessor
                    + "/Contents/Resources/com.kleinperkins.shadow-sync.plist.template",
                destination: paths.launchAgent,
                executable: paths.app + "/Contents/MacOS/ShadowSync",
                managedHost: false
            )
            return (
                paths,
                launcher,
                host,
                lifecycle,
                try sha256(paths.app + "/Contents/MacOS/ShadowSync"),
                try sha256(paths.launchAgent)
            )
        }

        do {
            let (_, launcher, _, lifecycle, _, _) = try prepare("healthy")
            let upgraded = try lifecycle.install(sourceBundle: sourceCurrent)
            _ = try lifecycle.doctor()
            let auditCount = launcher.audit.count
            let repeated = try lifecycle.install(sourceBundle: sourceCurrent)
            try check(
                upgraded.release == repeated.release
                    && launcher.audit.count == auditCount,
                "current-contract reconcile was not idempotent after migration"
            )
            try lifecycle.uninstall()
            passed.append("predecessor-healthy-default-migrated")
            passed.append("current-contract-reconcile-idempotent")
            passed.append("successful-migration-current-contract-only")
        }

        do {
            let (paths, launcher, _, lifecycle, appBefore, plistBefore) =
                try prepare("stopped")
            launcher.setStopped(true)
            try expectFailure("stopped predecessor migrated without repair") {
                _ = try lifecycle.install(sourceBundle: sourceCurrent)
            }
            try check(
                try sha256(paths.app + "/Contents/MacOS/ShadowSync") == appBefore
                    && sha256(paths.launchAgent) == plistBefore,
                "refused stopped predecessor changed installed bytes"
            )
            _ = try lifecycle.install(
                sourceBundle: sourceCurrent,
                intent: .repair
            )
            _ = try lifecycle.doctor()
            try lifecycle.uninstall()
            passed.append("predecessor-stopped-required-repair")
        }

        for drift in ["extra-key", "wrong-label", "wrong-program"] {
            let (paths, _, _, lifecycle, appBefore, _) =
                try prepare("drift-\(drift)")
            guard var object = NSDictionary(
                contentsOfFile: paths.launchAgent
            ) as? [String: Any] else {
                throw M6HarnessError.message("could not read predecessor plist")
            }
            switch drift {
            case "extra-key":
                object["EnvironmentVariables"] = ["UNSAFE": "1"]
            case "wrong-label":
                object["Label"] = InstallationPaths.label + ".other"
            case "wrong-program":
                object["ProgramArguments"] = [
                    paths.app + "/Contents/MacOS/ShadowSync.other",
                ]
            default:
                throw M6HarnessError.message("unknown drift fixture")
            }
            let data = try PropertyListSerialization.data(
                fromPropertyList: object,
                format: .xml,
                options: 0
            )
            try data.write(to: URL(fileURLWithPath: paths.launchAgent))
            guard chmod(paths.launchAgent, 0o600) == 0 else {
                throw M6HarnessError.message("could not secure drift fixture")
            }
            let driftedPlist = try sha256(paths.launchAgent)
            try expectFailure("predecessor \(drift) was accepted") {
                _ = try lifecycle.install(sourceBundle: sourceCurrent)
            }
            try check(
                try sha256(paths.app + "/Contents/MacOS/ShadowSync") == appBefore
                    && sha256(paths.launchAgent) == driftedPlist,
                "predecessor \(drift) refusal changed installed bytes"
            )
            passed.append("predecessor-\(drift)-refused")
        }

        do {
            let (paths, _, _, lifecycle, _, plistBefore) =
                try prepare("signature")
            let executable = paths.app + "/Contents/MacOS/ShadowSync"
            let handle = try FileHandle(
                forWritingTo: URL(fileURLWithPath: executable)
            )
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            let tampered = try sha256(executable)
            try expectFailure("invalid predecessor signature was accepted") {
                _ = try lifecycle.install(sourceBundle: sourceCurrent)
            }
            try check(
                try sha256(executable) == tampered
                    && sha256(paths.launchAgent) == plistBefore,
                "signature refusal changed predecessor bytes"
            )
            passed.append("predecessor-invalid-signature-refused")
        }

        do {
            let (paths, launcher, host, _, appBefore, plistBefore) =
                try prepare("rollback")
            let failing = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host,
                fault: { stage in
                    if stage == "after-bootstrap" {
                        throw M6HarnessError.message("migration fault")
                    }
                }
            )
            try expectFailure("migration fault was not observed") {
                _ = try failing.install(sourceBundle: sourceCurrent)
            }
            let executable = paths.app + "/Contents/MacOS/ShadowSync"
            let ready = host.readyIdentity(
                location: paths.state,
                executable: executable,
                release: predecessorRelease,
                timeout: 0
            )
            try check(
                try sha256(executable) == appBefore
                    && sha256(paths.launchAgent) == plistBefore
                    && ready == nil
                    && launcher.state(label: InstallationPaths.label) == .absent,
                "failed migration did not restore exact stopped predecessor"
            )
            _ = try InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host
            ).install(sourceBundle: sourceCurrent, intent: .repair)
            passed.append("failed-migration-restored-stopped-predecessor")
        }

        let installedLayout: @Sendable (InstallationPaths) throws -> String = {
            paths in
            let app: String
            if FileManager.default.fileExists(atPath: paths.app) {
                let release = try ReleaseIdentity.load(bundlePath: paths.app)
                if release == predecessorRelease {
                    app = "old"
                } else if release == currentRelease {
                    app = "new"
                } else {
                    app = "other"
                }
            } else {
                app = "missing"
            }
            let plist: String
            if let dictionary = NSDictionary(
                contentsOfFile: paths.launchAgent
            ) as? [String: Any] {
                let executable = paths.app + "/Contents/MacOS/ShadowSync"
                let arguments = dictionary["ProgramArguments"] as? [String]
                if arguments == [executable] {
                    plist = "old"
                } else if arguments == [
                    executable, InstallationPaths.managedHostArgument,
                ] {
                    plist = "new"
                } else {
                    plist = "other"
                }
            } else {
                plist = "missing"
            }
            return "\(app)/\(plist)"
        }

        let transactionWindows: [(String, String)] = [
            ("after-gates", "old/old"),
            ("after-drain", "old/old"),
            ("before-promotion", "old/old"),
            ("after-app-backup", "missing/old"),
            ("after-plist-backup", "missing/missing"),
            ("after-app-promotion", "new/missing"),
            ("after-plist-promotion", "new/new"),
            ("after-bootstrap", "new/new"),
            ("after-kickstart", "new/new"),
            ("after-readiness", "new/new"),
        ]
        for (stage, expectedLayout) in transactionWindows {
            let (paths, launcher, host, _, appBefore, plistBefore) =
                try prepare("window-\(stage)")
            let observation = M6TransactionObservation()
            let failing = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host,
                fault: { observed in
                    guard observed == stage else { return }
                    observation.capture(launchAuditCount: launcher.audit.count) {
                        try installedLayout(paths)
                    }
                    throw M6HarnessError.message(
                        "transaction-window-\(stage)"
                    )
                }
            )
            try expectFailure("transaction cut \(stage) was not observed") {
                _ = try failing.install(sourceBundle: sourceCurrent)
            }
            let observed = observation.snapshot
            if let error = observed.error {
                throw M6HarnessError.message(error)
            }
            try check(
                observed.layout == expectedLayout,
                "transaction cut \(stage) exposed \(observed.layout ?? "none"), "
                    + "expected \(expectedLayout)"
            )
            try check(
                observed.layout != "new/old",
                "transaction cut \(stage) exposed unsupported new/old"
            )
            try check(
                try sha256(paths.app + "/Contents/MacOS/ShadowSync")
                    == appBefore
                    && sha256(paths.launchAgent) == plistBefore
                    && installedLayout(paths) == "old/old"
                    && launcher.state(label: InstallationPaths.label) == .absent
                    && !host.isReady(
                        location: paths.state,
                        executable: paths.executable,
                        release: predecessorRelease,
                        timeout: 0
                    ),
                "transaction cut \(stage) did not restore exact stopped old/old"
            )
            guard let auditStart = observed.launchAuditCount else {
                throw M6HarnessError.message("transaction cut did not record launch audit")
            }
            try check(
                !launcher.audit.dropFirst(auditStart).contains {
                    $0.hasPrefix("bootstrap:") || $0.hasPrefix("kickstart:")
                },
                "transaction cut \(stage) reactivated the predecessor during recovery"
            )
        }
        passed.append("predecessor-transaction-windows-no-new-old")

        fputs(
            "GREEN predecessor-compatibility: exact live-main contract migrated; "
                + "stopped predecessor required repair; drift/signature refused; "
                + "rollback restored predecessor; no new/old stable window; "
                + "current postconditions strict\n",
            stderr
        )
        return M6LifecycleResult(
            passed: passed,
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func recoveryPairing(
        root: String,
        sourceCurrent: String,
        sourcePredecessor: String
    ) throws -> M6LifecycleResult {
        let predecessorRelease = try ReleaseIdentity.load(
            bundlePath: sourcePredecessor
        )
        try check(
            predecessorRelease.sourceRevision
                == "783fa0587cccdb2c88a6a8b246c1ed0ed536e60b",
            "recovery pairing did not use the pinned predecessor"
        )
        let fileManager = FileManager.default
        var passed: [String] = []

        func backupPaths(_ paths: InstallationPaths) -> (String, String) {
            (
                URL(fileURLWithPath: paths.app)
                    .deletingLastPathComponent().path
                    + "/.ShadowSync.app.previous",
                URL(fileURLWithPath: paths.launchAgent)
                    .deletingLastPathComponent().path
                    + "/.com.kleinperkins.shadow-sync.plist.previous"
            )
        }

        func prepare(
            _ name: String,
            source: String,
            legacyPlist: Bool
        ) throws -> (
            InstallationPaths,
            RecordingLaunchAgent,
            RecordingHost,
            InstallationLifecycle
        ) {
            let caseRoot = root + "/" + name
            try fileManager.createDirectory(
                atPath: caseRoot + "/home",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let paths = try InstallationPaths.isolated(root: caseRoot)
            try TestIsolation.initializeState(at: paths.state)
            let launcher = RecordingLaunchAgent()
            let host = RecordingHost(launcher: launcher)
            let lifecycle = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host
            )
            do {
                _ = try lifecycle.install(sourceBundle: source)
            } catch {
                throw M6HarnessError.message(
                    "recovery pairing \(name) setup failed: \(error)"
                )
            }
            if legacyPlist {
                try renderLaunchAgent(
                    template: sourcePredecessor
                        + "/Contents/Resources/"
                        + "com.kleinperkins.shadow-sync.plist.template",
                    destination: paths.launchAgent,
                    executable: paths.app + "/Contents/MacOS/ShadowSync",
                    managedHost: false
                )
            }
            try launcher.bootout(
                label: InstallationPaths.label,
                expectedProgram: paths.app + "/Contents/MacOS/ShadowSync"
            )
            return (paths, launcher, host, lifecycle)
        }

        do {
            let (paths, _, _, lifecycle) = try prepare(
                "predecessor-resume",
                source: sourcePredecessor,
                legacyPlist: true
            )
            let (appBackup, plistBackup) = backupPaths(paths)
            let predecessorApp = try sha256(
                paths.app + "/Contents/MacOS/ShadowSync"
            )
            let predecessorPlist = try sha256(paths.launchAgent)
            try fileManager.moveItem(atPath: paths.app, toPath: appBackup)
            try fileManager.moveItem(
                atPath: paths.launchAgent,
                toPath: plistBackup
            )
            try fileManager.copyItem(atPath: sourceCurrent, toPath: paths.app)
            try fileManager.removeItem(atPath: paths.app)
            try fileManager.moveItem(atPath: appBackup, toPath: paths.app)
            try check(
                !fileManager.fileExists(atPath: appBackup)
                    && fileManager.fileExists(atPath: plistBackup)
                    && !fileManager.fileExists(atPath: paths.launchAgent)
                    && sha256(paths.app + "/Contents/MacOS/ShadowSync")
                        == predecessorApp,
                "interrupted recovery state was not predecessor/no-app-backup/"
                    + "legacy-plist-backup"
            )
            _ = try lifecycle.install(
                sourceBundle: sourceCurrent,
                intent: .repair
            )
            _ = try lifecycle.doctor()
            try check(
                !fileManager.fileExists(atPath: appBackup)
                    && !fileManager.fileExists(atPath: plistBackup)
                    && sha256(paths.launchAgent) != predecessorPlist,
                "second recovery did not finish at the current contract"
            )
            try lifecycle.uninstall()
            passed.append("predecessor-recovery-resumed-after-app-promotion")
        }

        do {
            let (paths, _, _, lifecycle) = try prepare(
                "current-resume",
                source: sourceCurrent,
                legacyPlist: false
            )
            let (_, plistBackup) = backupPaths(paths)
            try fileManager.moveItem(
                atPath: paths.launchAgent,
                toPath: plistBackup
            )
            _ = try lifecycle.install(
                sourceBundle: sourceCurrent,
                intent: .repair
            )
            _ = try lifecycle.doctor()
            try lifecycle.uninstall()
            passed.append("current-recovery-resumed-after-app-promotion")
        }

        do {
            let caseRoot = root + "/first-install-no-app"
            try fileManager.createDirectory(
                atPath: caseRoot + "/home/Library/LaunchAgents",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let paths = try InstallationPaths.isolated(root: caseRoot)
            try TestIsolation.initializeState(at: paths.state)
            let (_, plistBackup) = backupPaths(paths)
            try renderLaunchAgent(
                template: sourcePredecessor
                    + "/Contents/Resources/"
                    + "com.kleinperkins.shadow-sync.plist.template",
                destination: plistBackup,
                executable: paths.app + "/Contents/MacOS/ShadowSync",
                managedHost: false
            )
            let launcher = RecordingLaunchAgent()
            let lifecycle = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: RecordingHost(launcher: launcher)
            )
            try expectFailure("legacy first-install residue was accepted") {
                _ = try lifecycle.install(
                    sourceBundle: sourceCurrent,
                    intent: .repair
                )
            }
            try check(
                fileManager.fileExists(atPath: plistBackup)
                    && !fileManager.fileExists(atPath: paths.app),
                "legacy first-install refusal did not preserve residue"
            )
            passed.append("first-install-legacy-plist-backup-refused")
        }

        do {
            let (paths, _, _, lifecycle) = try prepare(
                "current-target-legacy-plist",
                source: sourceCurrent,
                legacyPlist: false
            )
            let (_, plistBackup) = backupPaths(paths)
            try fileManager.moveItem(
                atPath: paths.launchAgent,
                toPath: plistBackup
            )
            try renderLaunchAgent(
                template: sourcePredecessor
                    + "/Contents/Resources/"
                    + "com.kleinperkins.shadow-sync.plist.template",
                destination: plistBackup,
                executable: paths.app + "/Contents/MacOS/ShadowSync",
                managedHost: false
            )
            let targetBefore = try sha256(
                paths.app + "/Contents/MacOS/ShadowSync"
            )
            try expectFailure("current target accepted legacy plist backup") {
                _ = try lifecycle.install(
                    sourceBundle: sourceCurrent,
                    intent: .repair
                )
            }
            try check(
                fileManager.fileExists(atPath: plistBackup)
                    && sha256(paths.app + "/Contents/MacOS/ShadowSync")
                        == targetBefore,
                "target mismatch refusal did not preserve current target"
            )
            passed.append("current-target-legacy-plist-backup-refused")
        }

        do {
            let (paths, _, _, lifecycle) = try prepare(
                "legacy-plist-drift",
                source: sourcePredecessor,
                legacyPlist: true
            )
            let (_, plistBackup) = backupPaths(paths)
            try fileManager.moveItem(
                atPath: paths.launchAgent,
                toPath: plistBackup
            )
            var object = NSDictionary(contentsOfFile: plistBackup) as! [String: Any]
            object["Unexpected"] = true
            try (object as NSDictionary).write(
                to: URL(fileURLWithPath: plistBackup)
            )
            try expectFailure("arbitrary legacy-shaped drift was accepted") {
                _ = try lifecycle.install(
                    sourceBundle: sourceCurrent,
                    intent: .repair
                )
            }
            try check(
                fileManager.fileExists(atPath: plistBackup),
                "legacy drift refusal consumed its backup"
            )
            passed.append("predecessor-target-legacy-plist-drift-refused")
        }

        for target in ["current", "predecessor", "missing", "invalid"] {
            let (paths, _, _, lifecycle) = try prepare(
                "corrupt-app-backup-\(target)",
                source: sourcePredecessor,
                legacyPlist: true
            )
            let (appBackup, plistBackup) = backupPaths(paths)
            try fileManager.moveItem(atPath: paths.app, toPath: appBackup)
            try fileManager.moveItem(
                atPath: paths.launchAgent,
                toPath: plistBackup
            )
            let corrupt = try FileHandle(
                forWritingTo: URL(
                    fileURLWithPath: appBackup
                        + "/Contents/MacOS/ShadowSync"
                )
            )
            try corrupt.seekToEnd()
            try corrupt.write(contentsOf: Data([0]))
            try corrupt.close()
            if target == "current" || target == "invalid" {
                try fileManager.copyItem(
                    atPath: sourceCurrent,
                    toPath: paths.app
                )
            } else if target == "predecessor" {
                try fileManager.copyItem(
                    atPath: sourcePredecessor,
                    toPath: paths.app
                )
            }
            if target == "invalid" {
                let invalid = try FileHandle(
                    forWritingTo: URL(
                        fileURLWithPath: paths.app
                            + "/Contents/MacOS/ShadowSync"
                    )
                )
                try invalid.seekToEnd()
                try invalid.write(contentsOf: Data([0]))
                try invalid.close()
            }
            try expectFailure(
                "corrupt app backup with \(target) target was accepted"
            ) {
                _ = try lifecycle.install(
                    sourceBundle: sourceCurrent,
                    intent: .repair
                )
            }
            try check(
                fileManager.fileExists(atPath: appBackup)
                    && fileManager.fileExists(atPath: plistBackup),
                "corrupt backup refusal mutated \(target) residue"
            )
            passed.append("corrupt-app-backup-\(target)-target-refused")
        }

        return M6LifecycleResult(
            passed: passed,
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func rollbackDrain(
        root: String,
        sourceN: String,
        sourceN1: String
    ) throws -> M6LifecycleResult {
        let cases: [(String, TimeInterval, M6HostExitMode, Bool)] = [
            ("delayed", 0.35, .clean, false),
            ("immediate", 0, .clean, false),
            ("stale", 0, .stale, false),
            ("timeout", 5.5, .clean, true),
        ]
        var passed: [String] = []
        for (name, delay, mode, expectTimeout) in cases {
            fputs("rollback-order case=\(name) begin\n", stderr)
            let caseRoot = root + "/" + name
            try FileManager.default.createDirectory(
                atPath: caseRoot + "/home",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let paths = try InstallationPaths.isolated(root: caseRoot)
            try TestIsolation.initializeState(at: paths.state)
            let launcher = ProcessLaunchAgent(root: caseRoot)
            let host = SystemInstalledHostController()
            let lifecycle = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host
            )
            var validationLauncher = launcher
            var validationLifecycle = lifecycle
            let original = try lifecycle.install(sourceBundle: sourceN)
            fputs("rollback-order case=\(name) initial-ready\n", stderr)
            let executable = paths.app + "/Contents/MacOS/ShadowSync"
            let appBefore = try sha256(executable)
            let plistBefore = try sha256(paths.launchAgent)
            launcher.configureNextHostExit(delay: delay, mode: mode)
            launcher.setReturnFromBootoutBeforeDrain(true)
            let failing = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host,
                fault: { stage in
                    if stage == "after-kickstart" {
                        throw M6HarnessError.message("fault:after-kickstart")
                    }
                }
            )
            var failure: Error?
            do {
                _ = try failing.install(sourceBundle: sourceN1)
            } catch {
                failure = error
            }
            guard let failure else {
                throw M6HarnessError.message(
                    "rollback \(name) fixture did not inject a failure"
                )
            }
            fputs(
                "rollback-order case=\(name) injected=\(failure)\n",
                stderr
            )
            let appBackup = URL(fileURLWithPath: paths.app)
                .deletingLastPathComponent().path
                + "/.ShadowSync.app.previous"
            let plistBackup = URL(fileURLWithPath: paths.launchAgent)
                .deletingLastPathComponent().path
                + "/.com.kleinperkins.shadow-sync.plist.previous"

            if expectTimeout {
                try check(
                    String(describing: failure).contains(
                        "the verified launcher did not exit"
                    ),
                    "rollback exit refusal did not reach the bounded drain timeout"
                )
                try check(
                    FileManager.default.fileExists(atPath: appBackup)
                        && FileManager.default.fileExists(atPath: plistBackup)
                        && sha256(executable) != appBefore,
                    "rollback timeout destroyed its recoverable backups"
                )
                try check(
                    launcher.waitForCurrentHostExit(timeout: 2),
                    "timed-out rollback host did not complete its delayed exit"
                )
                let recoveryLauncher = ProcessLaunchAgent(root: caseRoot)
                let recoveryLifecycle = InstallationLifecycle(
                    paths: paths,
                    launchAgent: recoveryLauncher,
                    host: host
                )
                let recovered = try recoveryLifecycle.install(
                    sourceBundle: sourceN,
                    intent: .repair
                )
                try check(
                    recovered.release == original.release,
                    "rollback timeout recovery restored the wrong release"
                )
                validationLauncher = recoveryLauncher
                validationLifecycle = recoveryLifecycle
                passed.append("rollback-exit-timeout-fail-closed")
                passed.append("rollback-timeout-remained-recoverable")
            } else {
                guard try sha256(executable) == appBefore,
                      try sha256(paths.launchAgent) == plistBefore,
                      !FileManager.default.fileExists(atPath: appBackup),
                      !FileManager.default.fileExists(atPath: plistBackup) else {
                    fputs(
                        "RED rollback-order: \(name) replacement host blocked "
                            + "backup restoration before drain: \(failure)\n",
                        stderr
                    )
                    throw M6HarnessError.message(
                        "rollback \(name) did not restore backups after host drain"
                    )
                }
                switch name {
                case "immediate":
                    passed.append("rollback-immediate-exit-restored-backups")
                case "delayed":
                    passed.append("rollback-delayed-exit-restored-backups")
                case "stale":
                    passed.append("rollback-stale-registration-cleaned-after-drain")
                default:
                    throw M6HarnessError.message("unknown rollback fixture")
                }
            }

            fputs("rollback-order case=\(name) backups-restored\n", stderr)
            let observedState = validationLauncher.state(
                label: InstallationPaths.label
            )
            let observedReady = host.readyIdentity(
                location: paths.state,
                executable: executable,
                release: original.release,
                timeout: 0
            )
            let observedDisposition = observedReady.map {
                validationLauncher.processDisposition(
                    processID: $0.processID,
                    expectedProgram: executable
                )
            }
            fputs(
                "rollback-order case=\(name) state=\(observedState) "
                    + "ready=\(String(describing: observedReady?.processID)) "
                    + "disposition=\(String(describing: observedDisposition))\n",
                stderr
            )
            if expectTimeout {
                // The timeout case invoked explicit repair above. Its newly
                // requested activation must still converge on the exact host.
                guard case let .loaded(program, processID) = observedState else {
                    throw M6HarnessError.message("explicit rollback repair did not load the host")
                }
                try check(program == executable && processID == observedReady?.processID
                    && observedDisposition == .matching,
                    "explicit rollback repair did not converge on the verified host")
            } else {
                try check(observedState == .absent && observedReady == nil
                    && launcher.kickstarts == 2,
                    "rollback \(name) restarted or registered the prior host")
                try expectFailure("stopped rollback was reported ready") {
                    _ = try validationLifecycle.doctor()
                }
            }
            try check(sha256(executable) == appBefore && sha256(paths.launchAgent) == plistBefore,
                "rollback \(name) did not preserve the original release")
            try validationLifecycle.uninstall()
            fputs("rollback-order case=\(name) PASS\n", stderr)
        }
        fputs(
            "GREEN rollback-order: immediate/delayed/stale exits restored "
                + "backups after drain; delayed exit timed out fail-closed "
                + "and remained recoverable\n",
            stderr
        )
        return M6LifecycleResult(
            passed: passed,
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func stoppedJob(
        root: String,
        sourceN: String
    ) throws -> M6LifecycleResult {
        let paths = try InstallationPaths.isolated(root: root)
        try TestIsolation.initializeState(at: paths.state)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )
        _ = try lifecycle.install(sourceBundle: sourceN)
        _ = try lifecycle.doctor()
        let executable = paths.app + "/Contents/MacOS/ShadowSync"
        let appBefore = try sha256(executable)
        let plistBefore = try sha256(paths.launchAgent)
        let release = try ReleaseIdentity.load(bundlePath: paths.app)
        let marker = InstallationPaths.managedHostArgument
        try check(
            try InstalledStateAdmission.invocationRole(
                arguments: [executable]
            ) == .manual,
            "ordinary app launch did not select the manual role"
        )
        try check(
            try InstalledStateAdmission.invocationRole(
                arguments: [executable, "-psn_0_fixture"]
            ) == .manual,
            "marker-free app argument did not retain the manual role"
        )
        try check(
            try InstalledStateAdmission.invocationRole(
                arguments: [executable, marker]
            ) == .managedHost,
            "exact LaunchAgent argument did not select the managed role"
        )
        for arguments in [
            [executable, marker, "--extra"],
            [executable, "--extra", marker],
            [executable, marker, marker],
        ] {
            try expectFailure("ambiguous managed-host marker was accepted") {
                _ = try InstalledStateAdmission.invocationRole(
                    arguments: arguments
                )
            }
        }
        let managedProbeHost = NeverReadyHost()
        try expectFailure("forged managed marker joined a live host") {
            _ = try InstalledStateAdmission.enterInstalledApplication(
                arguments: [executable, marker],
                paths: paths,
                launchAgent: launcher,
                host: managedProbeHost,
                processID: getpid(),
                managedAdmissionTimeout: 0
            )
        }
        try check(
            managedProbeHost.queries == 0,
            "forged managed marker entered readiness routing"
        )
        guard case let .loaded(program, liveProcessID?) = launcher.state(
            label: InstallationPaths.label
        ), program == executable else {
            throw M6HarnessError.message("live route fixture had no managed PID")
        }
        let liveKickstarts = launcher.kickstarts
        launcher.setStateOverride(.loaded(program: executable, processID: nil))
        try check(
            host.readyIdentity(
                location: paths.state,
                executable: executable,
                release: release,
                timeout: 0
            )?.processID == liveProcessID,
            "nil-PID route fixture host was not independently ready"
        )
        do {
            try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
                paths: paths,
                launchAgent: launcher,
                host: host,
                callerProcessID: getpid(),
                startupObservationTimeout: 0.05
            )
        } catch {
            if launcher.kickstarts != liveKickstarts {
                fputs(
                    "RED manual-routing: verified ready host with nil launchd "
                        + "PID was kickstarted before readiness\n",
                    stderr
                )
            } else {
                fputs(
                    "RED manual-routing: verified ready host with nil launchd "
                        + "PID was refused before readiness\n",
                    stderr
                )
            }
            throw error
        }
        try check(
            launcher.kickstarts == liveKickstarts,
            "ready host with nil launchd PID was kickstarted"
        )
        launcher.setStateOverride(
            .loaded(program: executable, processID: 999_999)
        )
        try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
            paths: paths,
            launchAgent: launcher,
            host: host,
            callerProcessID: getpid(),
            startupObservationTimeout: 0.05
        )
        try check(
            launcher.kickstarts == liveKickstarts,
            "ready host with stale launchd PID was kickstarted"
        )
        launcher.setStateOverride(.loaded(program: executable, processID: nil))
        let delayedReady = DelayedReadyHost(
            delegate: host,
            readyAfterQueries: 2
        )
        try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
            paths: paths,
            launchAgent: launcher,
            host: delayedReady,
            callerProcessID: getpid(),
            startupObservationTimeout: 0.2
        )
        try check(
            launcher.kickstarts == liveKickstarts,
            "host becoming ready during observation was kickstarted"
        )
        launcher.setStateOverride(nil)
        let publishing = ManagedStartupLaunchAgent(
            program: executable,
            publishedAfterStateCalls: 2,
            publishedProcessID: liveProcessID
        )
        let readyAfterPublication = DelayedReadyHost(
            delegate: host,
            readyAfterQueries: 1
        )
        try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
            paths: paths,
            launchAgent: publishing,
            host: readyAfterPublication,
            callerProcessID: getpid(),
            startupObservationTimeout: 0.2
        )
        try check(
            publishing.kickstarts == 0,
            "matching managed PID followed by readiness was kickstarted"
        )
        let wrongReadyIdentity = ManagedStartupLaunchAgent(
            program: executable,
            publishedAfterStateCalls: 0,
            publishedProcessID: liveProcessID + 10_000
        )
        try expectFailure("wrong ready identity was accepted") {
            try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
                paths: paths,
                launchAgent: wrongReadyIdentity,
                host: host,
                callerProcessID: getpid(),
                startupObservationTimeout: 0.05
            )
        }
        try check(
            wrongReadyIdentity.kickstarts == 0,
            "wrong ready identity caused a kickstart"
        )
        launcher.setStateOverride(.loaded(program: executable, processID: nil))
        _ = try lifecycle.install(sourceBundle: sourceN, intent: .repair)
        try check(
            launcher.kickstarts == liveKickstarts,
            "repair kickstarted a ready host with nil launchd PID"
        )
        launcher.setStateOverride(
            .loaded(program: executable, processID: 999_999)
        )
        _ = try lifecycle.install(sourceBundle: sourceN, intent: .repair)
        try check(
            launcher.kickstarts == liveKickstarts,
            "repair kickstarted a ready host with stale launchd PID"
        )
        launcher.setStateOverride(nil)
        let liveManual = try InstalledStateAdmission.enterInstalledApplication(
            arguments: [executable],
            paths: paths,
            launchAgent: launcher,
            host: host,
            processID: getpid()
        )
        try check(liveManual == nil, "manual launch became the live host")
        try launcher.terminateWithoutCleanup(expectedProgram: executable)
        guard launcher.state(label: InstallationPaths.label)
                == .loaded(program: executable, processID: nil),
              !host.isReady(
                location: paths.state,
                executable: executable,
                release: release,
                timeout: 0
              ) else {
            throw M6HarnessError.message(
                "abrupt clean-quit fixture did not retain a stopped registration"
            )
        }
        try expectFailure("forged managed marker restarted a stopped job") {
            _ = try InstalledStateAdmission.enterInstalledApplication(
                arguments: [executable, marker],
                paths: paths,
                launchAgent: launcher,
                host: managedProbeHost,
                processID: getpid(),
                managedAdmissionTimeout: 0.05
            )
        }
        try check(
            launcher.state(label: InstallationPaths.label)
                == .loaded(program: executable, processID: nil)
                && managedProbeHost.queries == 0,
            "forged managed marker changed the stopped job"
        )
        do {
            let published = ManagedStartupLaunchAgent(
                program: executable,
                publishedAfterStateCalls: 0
            )
            guard let authority = try InstalledStateAdmission
                .enterInstalledApplication(
                    arguments: [executable, marker],
                    paths: paths,
                    launchAgent: published,
                    host: managedProbeHost,
                    processID: getpid(),
                    managedAdmissionTimeout: 0
                ) else {
                throw M6HarnessError.message(
                    "published managed startup was routed as manual"
                )
            }
            authority.release()
            try check(
                published.stateCalls >= 2
                    && published.kickstarts == 0
                    && managedProbeHost.queries == 0,
                "published managed startup used manual routing"
            )
        }
        do {
            let contended = try LauncherAuthority.acquire(at: paths.state)
            let releasing = ManagedStartupLaunchAgent(
                program: executable,
                publishedAfterStateCalls: 0,
                heldLauncher: contended,
                releaseLauncherAtStateCall: 3
            )
            guard let authority = try InstalledStateAdmission
                .enterInstalledApplication(
                    arguments: [executable, marker],
                    paths: paths,
                    launchAgent: releasing,
                    host: managedProbeHost,
                    processID: getpid(),
                    managedAdmissionTimeout: 0.5
                ) else {
                throw M6HarnessError.message(
                    "contended managed startup was routed as manual"
                )
            }
            authority.release()
            try check(
                releasing.launcherReleases == 1
                    && releasing.kickstarts == 0
                    && managedProbeHost.queries == 0,
                "managed launcher contention entered manual routing"
            )
        }
        do {
            let publishing = ManagedStartupLaunchAgent(
                program: executable,
                publishedAfterStateCalls: 1
            )
            guard let authority = try InstalledStateAdmission
                .enterInstalledApplication(
                    arguments: [executable, marker],
                    paths: paths,
                    launchAgent: publishing,
                    host: managedProbeHost,
                    processID: getpid(),
                    managedAdmissionTimeout: 0.5
                ) else {
                throw M6HarnessError.message(
                    "unpublished managed startup was routed as manual"
                )
            }
            authority.release()
            try check(
                publishing.stateCalls >= 3
                    && publishing.kickstarts == 0
                    && managedProbeHost.queries == 0,
                "unpublished managed startup self-kickstarted or waited for readiness"
            )
        }
        do {
            let pendingManagedStart = ManagedStartupLaunchAgent(
                program: executable,
                publishedAfterStateCalls: 3,
                publishedProcessID: getpid() + 10_000
            )
            try expectFailure("pending managed startup unexpectedly became ready") {
                try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
                    paths: paths,
                    launchAgent: pendingManagedStart,
                    host: managedProbeHost,
                    callerProcessID: getpid()
                )
            }
            guard pendingManagedStart.kickstarts == 0 else {
                fputs(
                    "RED manual-startup: nil launchd PID triggered a duplicate "
                        + "kickstart before managed PID publication\n",
                    stderr
                )
                throw M6HarnessError.message(
                    "manual launch double-kickstarted a pending managed host"
                )
            }
        }
        do {
            let stoppedJob = ManagedStartupLaunchAgent(
                program: executable,
                publishedAfterStateCalls: .max,
                publishedProcessID: getpid() + 10_001
            )
            try expectFailure("persistently stopped job unexpectedly became ready") {
                try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
                    paths: paths,
                    launchAgent: stoppedJob,
                    host: managedProbeHost,
                    callerProcessID: getpid(),
                    startupObservationTimeout: 0.05
                )
            }
            try check(
                stoppedJob.kickstarts == 1 && stoppedJob.stateCalls >= 3,
                "persistently nil launchd PID was not kickstarted exactly once"
            )
        }
        try expectFailure("an uncorrelated manual process became the host") {
            let authority = try InstalledStateAdmission.admitHost(
                paths: paths,
                launchAgent: launcher,
                processID: getpid()
            )
            authority.release()
        }
        for state in [
            LaunchAgentState.absent,
            .queryFailure,
            .loaded(program: executable + ".other", processID: nil),
            .loaded(program: executable, processID: 1),
        ] {
            launcher.setStateOverride(state)
            try expectFailure("unsafe stopped launch state was routed") {
                _ = try InstalledStateAdmission.enterInstalledApplication(
                    arguments: [executable],
                    paths: paths,
                    launchAgent: launcher,
                    host: host,
                    processID: getpid()
                )
            }
            if state != .absent {
                try expectFailure("unsafe stopped launch state was repaired") {
                    _ = try lifecycle.install(
                        sourceBundle: sourceN,
                        intent: .repair
                    )
                }
            }
            try check(
                try sha256(executable) == appBefore
                    && sha256(paths.launchAgent) == plistBefore,
                "refused stopped launch state changed installed bytes"
            )
        }
        launcher.setStateOverride(nil)
        launcher.setStateOverride(
            .loaded(program: executable, processID: getpid())
        )
        try expectFailure("a manual process became the managed host") {
            _ = try InstalledStateAdmission.enterInstalledApplication(
                arguments: [executable],
                paths: paths,
                launchAgent: launcher,
                host: host,
                processID: getpid()
            )
        }
        launcher.setStateOverride(nil)
        fputs(
            "GREEN startup-role: explicit managed admission covered published, "
                + "pre-publication, and launcher-contention states without "
                + "kickstart/readiness routing\n",
            stderr
        )
        try expectFailure("an invalid caller PID was routed") {
            _ = try InstalledStateAdmission.enterInstalledApplication(
                arguments: [executable],
                paths: paths,
                launchAgent: launcher,
                host: host,
                processID: 1
            )
        }
        let stoppedManual = try InstalledStateAdmission.enterInstalledApplication(
            arguments: [executable],
            paths: paths,
            launchAgent: launcher,
            host: host,
            processID: getpid()
        )
        try check(stoppedManual == nil, "stopped-job manual launch became host")
        let repeatedManual = try InstalledStateAdmission.enterInstalledApplication(
            arguments: [executable],
            paths: paths,
            launchAgent: launcher,
            host: host,
            processID: getpid()
        )
        try check(repeatedManual == nil, "live-host manual launch became host")
        let staleManualPID = try launcher.terminateWithoutCleanup(
            expectedProgram: executable
        )
        launcher.setStateOverride(
            .loaded(program: executable, processID: staleManualPID)
        )
        let staleManual = try InstalledStateAdmission.enterInstalledApplication(
            arguments: [executable],
            paths: paths,
            launchAgent: launcher,
            host: host,
            processID: getpid()
        )
        try check(staleManual == nil, "stale-PID manual launch became host")
        launcher.setStateOverride(nil)
        _ = try lifecycle.doctor()
        guard try sha256(executable) == appBefore,
              try sha256(paths.launchAgent) == plistBefore,
              case let .loaded(manualProgram, manualProcessID) =
                launcher.state(label: InstallationPaths.label),
              manualProgram == executable,
              manualProcessID != nil else {
            throw M6HarnessError.message(
                "manual launch routing changed bytes or missed managed readiness"
            )
        }
        let staleRepairPID = try launcher.terminateWithoutCleanup(
            expectedProgram: executable
        )
        launcher.setStateOverride(
            .loaded(program: executable, processID: staleRepairPID)
        )
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        launcher.setStateOverride(nil)
        _ = try lifecycle.doctor()
        guard try sha256(executable) == appBefore,
              try sha256(paths.launchAgent) == plistBefore,
              case let .loaded(program, processID) =
                launcher.state(label: InstallationPaths.label),
              program == executable,
              processID != nil else {
            throw M6HarnessError.message(
                "stopped-job recovery changed bytes or missed managed readiness"
            )
        }
        try lifecycle.uninstall()
        return M6LifecycleResult(
            passed: [
                "startup-role-exact-marker-contract",
                "managed-start-published-pid-admitted",
                "managed-start-pre-publication-admitted",
                "managed-start-launcher-contention-retried",
                "managed-start-no-self-kickstart-or-readiness-wait",
                "manual-start-ready-nil-pid-no-kickstart",
                "manual-start-ready-stale-pid-no-kickstart",
                "manual-start-became-ready-during-observation",
                "manual-start-matching-pid-then-ready-no-kickstart",
                "manual-start-observed-managed-pid-without-kickstart",
                "manual-start-persistent-nil-kickstarted-once",
                "manual-start-wrong-ready-identity-refused",
                "repair-ready-nil-or-stale-pid-no-kickstart",
                "forged-managed-marker-refused",
                "stopped-job-manual-launch-routed",
                "live-host-manual-launch-routed",
                "manual-launch-never-became-host",
                "pid-mismatch-reuse-refused",
                "stale-pid-manual-launch-restarted",
                "stale-pid-repair-restarted",
                "stopped-job-repair-restarted",
                "stopped-job-bytes-unchanged",
            ],
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func postStartConvergence(
        root: String,
        sourceN: String
    ) throws -> M6LifecycleResult {
        typealias Fixture = (
            paths: InstallationPaths,
            launcher: ProcessLaunchAgent,
            host: SystemInstalledHostController,
            lifecycle: InstallationLifecycle,
            executable: String
        )
        func prepare(_ name: String) throws -> Fixture {
            let caseRoot = root + "/" + name
            try FileManager.default.createDirectory(
                atPath: caseRoot + "/home",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let paths = try InstallationPaths.isolated(root: caseRoot)
            try TestIsolation.initializeState(at: paths.state)
            let launcher = ProcessLaunchAgent(root: caseRoot)
            let host = SystemInstalledHostController()
            let lifecycle = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host
            )
            _ = try lifecycle.install(sourceBundle: sourceN)
            let executable = paths.app + "/Contents/MacOS/ShadowSync"
            _ = try launcher.terminateWithoutCleanup(
                expectedProgram: executable
            )
            return (paths, launcher, host, lifecycle, executable)
        }

        func runManual(
            _ name: String,
            observations: [M6PostKickstartObservation],
            timeout: TimeInterval,
            succeeds: Bool
        ) throws {
            let fixture = try prepare(name)
            let initialKickstarts =
                fixture.launcher.kickstarts
            fixture.launcher.configurePostKickstartObservations(observations)
            if succeeds {
                try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
                    paths: fixture.paths,
                    launchAgent: fixture.launcher,
                    host: fixture.host,
                    callerProcessID: getpid(),
                    startupObservationTimeout: timeout
                )
            } else {
                try expectFailure("\(name) unexpectedly converged") {
                    try InstalledStateAdmission.routeManualLaunchToRegisteredHost(
                        paths: fixture.paths,
                        launchAgent: fixture.launcher,
                        host: fixture.host,
                        callerProcessID: getpid(),
                        startupObservationTimeout: timeout
                    )
                }
            }
            try check(
                fixture.launcher.kickstarts
                    == initialKickstarts + 1,
                "\(name) did not kickstart exactly once"
            )
            let consumed = fixture.launcher.consumedPostKickstartStates
            try check(
                !consumed.isEmpty && consumed[0] == observations[0],
                "\(name) did not expose its first post-start observation"
            )
            if succeeds, observations.count > 1 {
                try check(
                    consumed.starts(with: observations),
                    "\(name) did not converge across the scripted lag"
                )
            }
            fixture.launcher.clearPostKickstartObservations()
            try fixture.lifecycle.uninstall()
        }

        try runManual(
            "manual-nil-matching",
            observations: [.nilPID, .matchingPID],
            timeout: 0.1,
            succeeds: true
        )
        fputs(
            "RED post-kickstart one-shot: ready host first observed nil PID; "
                + "bounded convergence required\n",
            stderr
        )
        try runManual(
            "manual-stale-matching",
            observations: [.stalePID, .matchingPID],
            timeout: 0.1,
            succeeds: true
        )
        fputs(
            "RED post-kickstart one-shot: ready host first observed stale PID; "
                + "bounded convergence required\n",
            stderr
        )
        try runManual(
            "manual-matching",
            observations: [.matchingPID],
            timeout: 0.1,
            succeeds: true
        )
        try runManual(
            "manual-nil-deadline",
            observations: Array(repeating: .nilPID, count: 12),
            timeout: 0.05,
            succeeds: false
        )
        try runManual(
            "manual-conflicting-pid",
            observations: [.conflictingPID],
            timeout: 0.1,
            succeeds: false
        )
        try runManual(
            "manual-query-failure",
            observations: [.queryFailure],
            timeout: 0.1,
            succeeds: false
        )

        do {
            let fixture = try prepare("repair-nil-matching")
            let initialKickstarts =
                fixture.launcher.kickstarts
            fixture.launcher.configurePostKickstartObservations([
                .nilPID, .matchingPID,
            ])
            _ = try fixture.lifecycle.install(
                sourceBundle: sourceN,
                intent: .repair
            )
            try check(
                fixture.launcher.kickstarts
                    == initialKickstarts + 1,
                "repair convergence kickstarted more than once"
            )
            fixture.launcher.clearPostKickstartObservations()
            try fixture.lifecycle.uninstall()
        }
        do {
            let fixture = try prepare("repair-nil-deadline")
            let initialKickstarts =
                fixture.launcher.kickstarts
            fixture.launcher.configurePostKickstartObservations(
                Array(repeating: .nilPID, count: 48)
            )
            try expectFailure("repair nil PID unexpectedly converged") {
                _ = try fixture.lifecycle.install(
                    sourceBundle: sourceN,
                    intent: .repair
                )
            }
            try check(
                fixture.launcher.kickstarts
                    == initialKickstarts + 1,
                "failed repair convergence kickstarted more than once"
            )
            fixture.launcher.clearPostKickstartObservations()
            try fixture.lifecycle.uninstall()
        }

        return M6LifecycleResult(
            passed: [
                "post-start-managed-child-admitted-before-lag",
                "post-kickstart-nil-then-matching-converged",
                "post-kickstart-stale-then-matching-converged",
                "post-kickstart-matching-immediate",
                "post-kickstart-nil-deadline-refused",
                "post-kickstart-conflicting-pid-refused",
                "post-kickstart-query-failure-refused",
                "post-kickstart-no-duplicate-restart",
                "post-kickstart-manual-repair-parity",
            ],
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func uninstallCrash(
        root: String,
        sourceN: String,
        stage: String
    ) throws {
        let paths = try InstallationPaths.isolated(root: root)
        try TestIsolation.initializeState(at: paths.state)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        _ = try InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        ).install(sourceBundle: sourceN)
        try InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { observed in
                if observed == stage { _exit(86) }
            }
        ).uninstall()
    }

    private static func uninstallRecover(root: String) throws -> M6LifecycleResult {
        let paths = try InstallationPaths.isolated(root: root)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )
        try lifecycle.uninstall()
        try lifecycle.uninstall()
        guard !FileManager.default.fileExists(atPath: paths.app),
              !FileManager.default.fileExists(atPath: paths.launchAgent) else {
            throw M6HarnessError.message("repeated uninstall left product residue")
        }
        return M6LifecycleResult(
            passed: ["uninstall-crash-recovered", "repeated-uninstall-verified"],
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func v4Migration(
        root: String,
        sourceN: String,
        sourceN1: String
    ) throws -> M6LifecycleResult {
        let paths = try InstallationPaths.isolated(root: root)
        let launcher = RecordingLaunchAgent()
        let host = RecordingHost(launcher: launcher)
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )
        for directory in [
            URL(fileURLWithPath: paths.app).deletingLastPathComponent().path,
            URL(fileURLWithPath: paths.launchAgent)
                .deletingLastPathComponent().path,
        ] {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        func stagePredecessor() throws {
            // Each case stages a fresh installation after uninstall removes
            // its control files; production admission never creates them.
            try TestIsolation.initializeState(at: paths.state)
            try makePredecessorBundle(
                source: sourceN,
                destination: paths.predecessorApp
            )
            try renderLaunchAgent(
                template: sourceN
                    + "/Contents/Resources/"
                    + "com.kleinperkins.shadow-sync.plist.template",
                destination: paths.launchAgent,
                executable: paths.predecessorExecutable
            )
            try launcher.bootstrap(
                label: InstallationPaths.label,
                plist: paths.launchAgent,
                expectedProgram: paths.predecessorExecutable
            )
        }

        try stagePredecessor()
        let migrated = try lifecycle.install(sourceBundle: sourceN1)
        let migratedPlist = NSDictionary(
            contentsOfFile: paths.launchAgent
        ) as? [String: Any]
        try check(
            migrated.launcherRunning
                && FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(atPath: paths.predecessorApp)
                && migratedPlist?["ProgramArguments"] as? [String]
                    == [paths.executable, InstallationPaths.managedHostArgument],
            "predecessor migration did not converge to one ShadowSync owner"
        )
        let firstAudit = launcher.audit
        guard let oldBootout = firstAudit.firstIndex(
            of: "bootout:\(InstallationPaths.label)"
        ),
        let newBootstrap = firstAudit.lastIndex(
            of: "bootstrap:\(InstallationPaths.label)"
        ),
        oldBootout < newBootstrap else {
            throw M6HarnessError.message(
                "predecessor and ShadowSync launch order was not serialized"
            )
        }
        try makePredecessorBundle(
            source: sourceN,
            destination: paths.predecessorApp
        )
        fputs("v4 dual-canonical doctor begin\n", stderr)
        let dualDoctor = try lifecycle.doctor()
        fputs("v4 dual-canonical doctor PASS\n", stderr)
        try check(
            dualDoctor.release == migrated.release,
            "dual-canonical doctor did not identify ShadowSync as owner"
        )
        let dualRepair = try lifecycle.install(
            sourceBundle: sourceN1,
            intent: .repair
        )
        fputs("v4 dual-canonical repair PASS\n", stderr)
        try check(
            dualRepair.release == migrated.release
                && FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(
                    atPath: paths.predecessorApp
                ),
            "dual-canonical repair did not remove verified predecessor residue"
        )
        try makePredecessorBundle(
            source: sourceN,
            destination: paths.predecessorApp
        )
        fputs("v4 dual-canonical uninstall begin\n", stderr)
        try lifecycle.uninstall()
        fputs("v4 dual-canonical uninstall PASS\n", stderr)
        try check(
            !FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(
                    atPath: paths.predecessorApp
                ),
            "dual-canonical uninstall left an application owner"
        )

        try stagePredecessor()
        launcher.setStopped(true)
        try writeDeadHostCoordination(
            paths: paths,
            release: try ReleaseIdentity.load(
                bundlePath: paths.predecessorApp
            ),
            executable: paths.predecessorExecutable
        )
        let stoppedPredecessorRepair = try lifecycle.install(
            sourceBundle: sourceN1,
            intent: .repair
        )
        try check(
            stoppedPredecessorRepair.launcherRunning
                && FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(
                    atPath: paths.predecessorApp
                )
                && coordinationResidueIsAbsent(paths),
            "stopped predecessor repair did not retire dead legacy coordination"
        )
        try lifecycle.uninstall()

        try stagePredecessor()
        host.failReadinessOnce()
        try expectFailure("failed migration readiness was accepted") {
            _ = try lifecycle.install(sourceBundle: sourceN1)
        }
        let restoredPlist = NSDictionary(
            contentsOfFile: paths.launchAgent
        ) as? [String: Any]
        try check(
            FileManager.default.fileExists(atPath: paths.predecessorApp)
                && !FileManager.default.fileExists(atPath: paths.app)
                && restoredPlist?["ProgramArguments"] as? [String]
                    == [paths.predecessorExecutable, InstallationPaths.managedHostArgument]
                && launcher.state(label: InstallationPaths.label) == .absent,
            "failed migration did not restore predecessor without launchd registration"
        )
        _ = try lifecycle.install(sourceBundle: sourceN1, intent: .repair)
        try lifecycle.uninstall()

        let rollbackCuts = [
            "after-gates",
            "after-drain",
            "before-promotion",
            "after-app-backup",
            "after-plist-backup",
            "after-app-promotion",
            "after-plist-promotion",
            "after-bootstrap",
            "after-kickstart",
            "after-readiness",
        ]
        let committedCuts = [
            "after-commit",
            "install-cleanup-app-quarantined",
            "after-cleanup",
        ]
        for stage in rollbackCuts + committedCuts {
            do {
                try stagePredecessor()
                let faulted = InstallationLifecycle(
                    paths: paths,
                    launchAgent: launcher,
                    host: host,
                    fault: { observed in
                        if observed == stage {
                            throw M6HarnessError.message(
                                "injected v4 migration fault"
                            )
                        }
                    }
                )
                try expectFailure("v4 migration fault was accepted at \(stage)") {
                    _ = try faulted.install(sourceBundle: sourceN1)
                }
                let plist = NSDictionary(
                    contentsOfFile: paths.launchAgent
                ) as? [String: Any]
                if rollbackCuts.contains(stage) {
                    try check(
                        FileManager.default.fileExists(
                            atPath: paths.predecessorApp
                        )
                            && !FileManager.default.fileExists(atPath: paths.app)
                            && plist?["ProgramArguments"] as? [String]
                                == [
                                    paths.predecessorExecutable,
                                    InstallationPaths.managedHostArgument,
                                ]
                            && launcher.state(label: InstallationPaths.label) == .absent,
                        "migration cut did not restore stopped predecessor at \(stage)"
                    )
                } else {
                    try check(
                        FileManager.default.fileExists(atPath: paths.app)
                            && plist?["ProgramArguments"] as? [String]
                                == [
                                    paths.executable,
                                    InstallationPaths.managedHostArgument,
                                ],
                        "committed migration cut lost ShadowSync at \(stage)"
                    )
                }
                _ = try lifecycle.install(
                    sourceBundle: sourceN1,
                    intent: .repair
                )
                try lifecycle.uninstall()
            } catch {
                throw M6HarnessError.message(
                    "v4 migration cut \(stage) failed: \(error)"
                )
            }
        }
        try check(
            !FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(atPath: paths.predecessorApp)
                && !FileManager.default.fileExists(atPath: paths.launchAgent),
            "dual-generation uninstall left an application owner"
        )

        let parent = URL(fileURLWithPath: paths.app).deletingLastPathComponent().path
        let currentBackup = parent + "/.ShadowSync.app.predecessor.previous"
        let historicalBackup = parent + "/.Dev Main Sync.app.previous"
        let historicalPlist = URL(fileURLWithPath: paths.launchAgent)
            .deletingLastPathComponent().path
            + "/.com.kleinperkins.shadow-sync.plist.previous"
        try stagePredecessor()
        let predecessorIdentity = try durableIdentity(paths.predecessorApp, isDirectory: true)
        let backupObservation = M6TransactionObservation()
        let observeBackup = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { stage in
                if stage == "after-app-backup" {
                    backupObservation.capture {
                        try check(nodeExists(currentBackup) && !nodeExists(historicalBackup),
                                  "new transaction wrote a historical backup name")
                        return try durableIdentity(currentBackup, isDirectory: true)
                    }
                    throw M6HarnessError.message("injected backup-name observation")
                }
            }
        )
        try expectFailure("backup-name fault was not observed") {
            _ = try observeBackup.install(sourceBundle: sourceN1)
        }
        try check(backupObservation.snapshot.error == nil
                    && backupObservation.snapshot.layout == predecessorIdentity
                    && launcher.state(label: InstallationPaths.label) == .absent,
                  "new backup identity or stopped rollback changed")
        _ = try lifecycle.install(sourceBundle: sourceN1, intent: .repair)
        try lifecycle.uninstall()

        func stageHistoricalBackup() throws {
            try stagePredecessor()
            try launcher.bootout(label: InstallationPaths.label,
                                 expectedProgram: paths.predecessorExecutable)
            try FileManager.default.moveItem(atPath: paths.predecessorApp,
                                             toPath: historicalBackup)
            try FileManager.default.moveItem(atPath: paths.launchAgent,
                                             toPath: historicalPlist)
        }

        try stageHistoricalBackup()
        _ = try lifecycle.install(sourceBundle: sourceN1, intent: .repair)
        try check(!nodeExists(historicalBackup) && !nodeExists(currentBackup)
                    && !nodeExists(paths.predecessorApp) && nodeExists(paths.app),
                  "historical backup repair did not converge to current identity")
        try lifecycle.uninstall()

        try stageHistoricalBackup()
        let uninstallAuditCount = launcher.audit.count
        try lifecycle.uninstall()
        try check(!nodeExists(historicalBackup) && !nodeExists(historicalPlist)
                    && !nodeExists(paths.predecessorApp) && !nodeExists(paths.app)
                    && launcher.state(label: InstallationPaths.label) == .absent
                    && !launcher.audit.dropFirst(uninstallAuditCount).contains {
                        $0.hasPrefix("bootstrap:") || $0.hasPrefix("kickstart:")
                    }, "historical backup uninstall reactivated or retained an owner")

        try stageHistoricalBackup()
        let quarantineAuditCount = launcher.audit.count
        let interruptedUninstall = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { stage in
                if stage == "uninstall-recovery-cleanup-app-quarantined" {
                    throw M6HarnessError.message("injected historical quarantine interruption")
                }
            }
        )
        try expectFailure("historical quarantine interruption was not observed") {
            try interruptedUninstall.uninstall()
        }
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: parent)
            .filter { $0.hasPrefix(".ShadowSync.app.quarantine.") }
        try check(quarantines.count == 1 && !nodeExists(historicalBackup)
                    && nodeExists(historicalPlist)
                    && launcher.state(label: InstallationPaths.label) == .absent,
                  "interrupted historical cleanup did not preserve its verified recovery pair")
        try lifecycle.uninstall()
        try check(!nodeExists(historicalPlist) && !nodeExists(paths.predecessorApp)
                    && !nodeExists(paths.app) && !nodeExists(parent + "/" + quarantines[0])
                    && !launcher.audit.dropFirst(quarantineAuditCount).contains {
                        $0.hasPrefix("bootstrap:") || $0.hasPrefix("kickstart:")
                    }, "historical quarantine recovery restarted or retained an owner")

        try stageHistoricalBackup()
        try FileManager.default.copyItem(atPath: historicalBackup, toPath: currentBackup)
        let retainedPaths = [historicalBackup, currentBackup, historicalPlist]
            + ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock"]
                .map { paths.state.path + "/" + $0 }
        func collisionSnapshot() throws -> [String] {
            try retainedPaths.map { try nodeIdentity($0) + ":" + pathDigest($0) }
                + [FileManager.default.contentsOfDirectory(atPath: parent).sorted().joined(separator: "|")]
        }
        let beforeCollision = try collisionSnapshot()
        let beforeAudit = launcher.audit
        for action in ["repair", "uninstall", "doctor"] {
            try expectFailure("ambiguous backup namespaces were accepted by " + action) {
                switch action {
                case "repair": _ = try lifecycle.install(sourceBundle: sourceN1, intent: .repair)
                case "uninstall": try lifecycle.uninstall()
                default: _ = try lifecycle.doctor()
                }
            }
            try check(try collisionSnapshot() == beforeCollision
                        && launcher.audit == beforeAudit,
                      "ambiguous backups were changed before refusal")
        }
        return M6LifecycleResult(
            passed: [
                "v4-predecessor-forward-migration",
                "v4-old-new-no-overlap",
                "v4-stopped-predecessor-dead-coordination-repair",
                "v4-predecessor-readiness-rollback",
                "v4-migration-fault-cuts-12",
                "v4-dual-generation-uninstall",
                "v4-current-backup-namespace",
                "v4-historical-backup-repair",
                "v4-historical-backup-uninstall-stopped",
                "v4-historical-quarantine-uninstall-stopped",
                "v4-ambiguous-backups-refused",
            ],
            launchctlInvocations: launcher.audit,
            latestLogSHA256: ""
        )
    }

    private static func run(
        root: String,
        sourceN: String,
        sourceEquivalent: String,
        sourceN1: String
    ) throws -> M6LifecycleResult {
        let paths = try InstallationPaths.isolated(root: root)
        let launcher = RecordingLaunchAgent()
        let host = RecordingHost(launcher: launcher)
        var passed: [String] = []
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )

        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.app).deletingLastPathComponent().path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.launchAgent).deletingLastPathComponent().path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        passed.append(
            contentsOf: try v4Migration(
                root: root,
                sourceN: sourceN,
                sourceN1: sourceN1
            ).passed
        )

        try TestIsolation.initializeState(at: paths.state)

        guard symlink(sourceN, paths.app) == 0 else {
            throw M6HarnessError.message("could not create app symlink fixture")
        }
        try expectFailure("symlink app target was accepted") {
            _ = try lifecycle.install(sourceBundle: sourceN)
        }
        var linkInfo = stat()
        try check(
            lstat(paths.app, &linkInfo) == 0 && (linkInfo.st_mode & S_IFMT) == S_IFLNK,
            "symlink refusal changed the target"
        )
        try FileManager.default.removeItem(atPath: paths.app)
        passed.append("symlink-target-refusal")

        let hardlinkSource = root + "/hardlinked-agent.plist"
        try renderLaunchAgent(
            template: sourceN
                + "/Contents/Resources/com.kleinperkins.shadow-sync.plist.template",
            destination: hardlinkSource,
            executable: paths.app + "/Contents/MacOS/ShadowSync"
        )
        guard link(hardlinkSource, paths.launchAgent) == 0 else {
            throw M6HarnessError.message("could not create hardlinked plist fixture")
        }
        try expectFailure("hardlinked LaunchAgent was accepted") {
            _ = try lifecycle.install(sourceBundle: sourceN)
        }
        var hardInfo = stat()
        try check(
            lstat(paths.launchAgent, &hardInfo) == 0 && hardInfo.st_nlink == 2,
            "hardlink refusal changed the target"
        )
        try FileManager.default.removeItem(atPath: paths.launchAgent)
        try FileManager.default.removeItem(atPath: hardlinkSource)
        passed.append("hardlinked-target-refusal")

        let first = try lifecycle.install(sourceBundle: sourceN)
        try check(first.launcherLoaded && first.launcherRunning, "first install was not ready")
        passed.append("first-install")
        let durableState = try SecureStateDirectory.openExisting(
            paths.state
        )
        let legacyFixture = try Data(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Tests/ShadowSyncSelfTests/Fixtures/legacy-v1-latest.log"
                )
        )
        try V2Body4SelfTestRunner.installLifecycleEvidence(
            state: durableState,
            legacyLog: legacyFixture
        )
        let preferenceEntry =
            try RepositorySelectionPreferenceEntry(
                repositoryID: "fixture/repository",
                locator: RepositorySelectionLocator(
                    governedRoot: "~",
                    components: ["dev", "personal", "repository"]
                )
            )
        _ = try RepositorySelectionPreferenceStore(
            state: durableState
        ).save(
            entries: [preferenceEntry],
            expected: .testingAbsent
        )
        let preferencePath =
            paths.state.path + "/"
            + RepositorySelectionPreferenceStore.filename
        let preferenceRecoveryPath =
            paths.state.path + "/"
            + RepositorySelectionPreferenceStore.recoveryFilename
        try Data("preserved malformed preference bytes\n".utf8)
            .write(to: URL(fileURLWithPath: preferenceRecoveryPath))
        guard chmod(preferenceRecoveryPath, 0o600) == 0 else {
            throw M6HarnessError.message(
                "could not secure preference recovery fixture"
            )
        }
        let authorityPath =
            paths.state.path + "/"
            + RepositoryAuthorityStore.filename
        let retentionManifestPath =
            paths.state.path
            + "/retention/ret-body4-fixture/manifest.json"
        let retentionBundlePath =
            paths.state.path
            + "/retention/ret-body4-fixture/branch.bundle"
        let durableDirectories = [
            paths.state.path + "/retention",
            paths.state.path
                + "/retention/ret-body4-fixture",
        ]
        let durableHashes = [
            paths.state.path + "/latest.log":
                try sha256(paths.state.path + "/latest.log"),
            authorityPath: try sha256(authorityPath),
            preferencePath: try sha256(preferencePath),
            preferenceRecoveryPath:
                try sha256(preferenceRecoveryPath),
            retentionManifestPath:
                try sha256(retentionManifestPath),
            retentionBundlePath:
                try sha256(retentionBundlePath),
        ]
        let durableIdentities = try Dictionary(
            uniqueKeysWithValues: durableHashes.keys.map {
                ($0, try durableIdentity($0))
            }
        )
        let durableDirectoryIdentities = try Dictionary(
            uniqueKeysWithValues: durableDirectories.map {
                ($0, try durableIdentity($0, isDirectory: true))
            }
        )
        func durableEvidenceIsExact() throws -> Bool {
            let filesAreExact = try durableHashes.allSatisfy {
                try sha256($0.key) == $0.value
                    && durableIdentity($0.key)
                        == durableIdentities[$0.key]
            }
            let directoriesAreExact =
                try durableDirectoryIdentities.allSatisfy {
                    try durableIdentity(
                        $0.key,
                        isDirectory: true
                    ) == $0.value
                }
            return filesAreExact && directoriesAreExact
        }

        let installedExecutable =
            paths.app + "/Contents/MacOS/ShadowSync"
        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: first.release
        )
        let historicalInstall = try lifecycle.install(
            sourceBundle: sourceN1
        )
        try check(
            historicalInstall.release.sourceInputSHA256
                != first.release.sourceInputSHA256,
            "absent-launchd historical install did not promote replacement"
        )
        _ = try lifecycle.doctor()
        try check(
            coordinationResidueIsAbsent(paths),
            "ordinary historical install left coordination slots"
        )
        passed.append(
            "historical-label-absent-launchd-install"
        )

        _ = try lifecycle.install(sourceBundle: sourceN)
        _ = try lifecycle.install(sourceBundle: sourceN1)
        let appPrevious =
            URL(fileURLWithPath: paths.app)
                .deletingLastPathComponent().path
            + "/.ShadowSync.app.previous"
        let plistPrevious =
            URL(fileURLWithPath: paths.launchAgent)
                .deletingLastPathComponent().path
            + "/.com.kleinperkins.shadow-sync.plist.previous"
        try FileManager.default.copyItem(
            atPath: sourceN,
            toPath: appPrevious
        )
        try renderLaunchAgent(
            template: sourceN
                + "/Contents/Resources/"
                + "com.kleinperkins.shadow-sync.plist.template",
            destination: plistPrevious,
            executable: installedExecutable
        )
        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: first.release
        )
        let repaired = try lifecycle.install(
            sourceBundle: sourceN1,
            intent: .repair
        )
        try check(
            repaired.release.sourceInputSHA256
                == historicalInstall.release.sourceInputSHA256,
            "previous-release coordination repair changed current source"
        )
        _ = try lifecycle.doctor()
        try check(
            !FileManager.default.fileExists(atPath: appPrevious)
                && !FileManager.default.fileExists(
                    atPath: plistPrevious
                )
                && coordinationResidueIsAbsent(paths),
            "previous-release repair left slots or coordination"
        )
        passed.append(
            "previous-release-absent-launchd-repair"
        )

        _ = try lifecycle.install(sourceBundle: sourceN)
        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: first.release
        )
        let rollbackPaths = [
            paths.app,
            paths.launchAgent,
            paths.state.path + "/latest.log",
            paths.state.path + "/host-owner.json",
            paths.state.path + "/host.sock",
        ]
        let rollbackIdentities = try Dictionary(
            uniqueKeysWithValues: rollbackPaths.map {
                ($0, try nodeIdentity($0))
            }
        )
        let rollbackHashes = try Dictionary(
            uniqueKeysWithValues: rollbackPaths.dropLast().map {
                ($0, try pathDigest($0))
            }
        )
        host.failReadinessOnce()
        try expectFailure(
            "dead-coordination readiness failure was accepted"
        ) {
            _ = try lifecycle.install(sourceBundle: sourceN1)
        }
        try check(
            try rollbackPaths.allSatisfy {
                try nodeIdentity($0) == rollbackIdentities[$0]
            }
                && rollbackHashes.allSatisfy {
                    try pathDigest($0.key) == $0.value
                },
            "dead-coordination rollback changed prior identities or bytes"
        )
        passed.append(
            "dead-coordination-readiness-rollback"
        )
        _ = try lifecycle.install(
            sourceBundle: sourceN1,
            intent: .repair
        )
        _ = try lifecycle.install(sourceBundle: sourceN)

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        let foreignRelease = try ReleaseIdentity.load(
            bundlePath: sourceN1
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: foreignRelease
        )
        let foreignOwner =
            try pathDigest(
                paths.state.path + "/host-owner.json"
            )
        try expectFailure(
            "foreign dead coordination was accepted"
        ) {
            _ = try lifecycle.install(
                sourceBundle: sourceN1,
                intent: .repair
            )
        }
        try check(
            try pathDigest(
                paths.state.path + "/host-owner.json"
            ) == foreignOwner,
            "foreign coordination refusal changed owner bytes"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append(
            "foreign-dead-coordination-refusal"
        )

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: first.release
        )
        let racedOwner =
            paths.state.path + "/host-owner.json"
        let racing = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { stage in
                if stage == "after-dead-coordination-preview" {
                    let bytes = try Data(
                        contentsOf: URL(
                            fileURLWithPath: racedOwner
                        )
                    )
                    try bytes.write(
                        to: URL(fileURLWithPath: racedOwner),
                        options: .atomic
                    )
                    guard chmod(racedOwner, 0o600) == 0 else {
                        throw M6HarnessError.message(
                            "could not secure raced owner"
                        )
                    }
                }
            }
        )
        try expectFailure(
            "coordination identity race was accepted"
        ) {
            _ = try racing.install(
                sourceBundle: sourceN1,
                intent: .repair
            )
        }
        try check(
            FileManager.default.fileExists(atPath: racedOwner),
            "coordination race refusal removed raced owner"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append(
            "dead-coordination-preview-race-refusal"
        )

        let firstAuditCount = launcher.audit.count
        let second = try lifecycle.install(sourceBundle: sourceEquivalent)
        try check(second.release == first.release, "same-source no-op changed provenance")
        try check(
            launcher.audit.count == firstAuditCount,
            "same-source no-op changed launcher process state"
        )
        try check(
            try durableEvidenceIsExact(),
            "same-source update changed durable evidence"
        )
        passed.append("same-source-no-op")

        let canonicalPlist = try Data(
            contentsOf: URL(fileURLWithPath: paths.launchAgent)
        )
        var extraPlist = try PropertyListSerialization.propertyList(
            from: canonicalPlist,
            options: [],
            format: nil
        ) as! [String: Any]
        extraPlist["EnvironmentVariables"] = ["UNSAFE": "1"]
        let extraData = try PropertyListSerialization.data(
            fromPropertyList: extraPlist,
            format: .xml,
            options: 0
        )
        try extraData.write(to: URL(fileURLWithPath: paths.launchAgent))
        guard chmod(paths.launchAgent, 0o600) == 0 else {
            throw M6HarnessError.message("could not secure extra-key plist")
        }
        try expectFailure("LaunchAgent extra key was accepted") {
            _ = try lifecycle.doctor()
        }
        try canonicalPlist.write(to: URL(fileURLWithPath: paths.launchAgent))
        guard chmod(paths.launchAgent, 0o600) == 0 else {
            throw M6HarnessError.message("could not restore canonical plist")
        }
        _ = try lifecycle.doctor()
        passed.append("launchagent-extra-key-refusal")

        let expectedProgram = paths.app + "/Contents/MacOS/ShadowSync"
        for arguments in [
            [expectedProgram],
            [expectedProgram, InstallationPaths.managedHostArgument, "--extra"],
            [expectedProgram, "--other-role"],
        ] {
            var rolePlist = try PropertyListSerialization.propertyList(
                from: canonicalPlist,
                options: [],
                format: nil
            ) as! [String: Any]
            rolePlist["ProgramArguments"] = arguments
            let roleData = try PropertyListSerialization.data(
                fromPropertyList: rolePlist,
                format: .xml,
                options: 0
            )
            try roleData.write(to: URL(fileURLWithPath: paths.launchAgent))
            guard chmod(paths.launchAgent, 0o600) == 0 else {
                throw M6HarnessError.message(
                    "could not secure role-marker plist"
                )
            }
            try expectFailure("LaunchAgent role marker drift was accepted") {
                _ = try lifecycle.doctor()
            }
        }
        try canonicalPlist.write(to: URL(fileURLWithPath: paths.launchAgent))
        guard chmod(paths.launchAgent, 0o600) == 0 else {
            throw M6HarnessError.message("could not restore role-marker plist")
        }
        _ = try lifecycle.doctor()
        passed.append("launchagent-exact-managed-role")

        launcher.setQueryFailure(true)
        try expectFailure("launchd query failure was treated as absent") {
            _ = try lifecycle.doctor()
        }
        launcher.setQueryFailure(false)
        _ = try lifecycle.doctor()
        passed.append("launchd-query-failure-refusal")

        for (name, state) in [
            ("absent", LaunchAgentState.absent),
            (
                "program-drift",
                .loaded(program: expectedProgram + ".other", processID: getpid())
            ),
            ("missing-pid", .loaded(program: expectedProgram, processID: nil)),
            ("invalid-pid", .loaded(program: expectedProgram, processID: 1)),
            ("pid-drift", .loaded(program: expectedProgram, processID: getpid() + 1)),
        ] {
            launcher.setStateOverride(state)
            try expectFailure("final launchd admission accepted \(name)") {
                _ = try lifecycle.doctor()
            }
        }
        launcher.setStateOverride(nil)
        _ = try lifecycle.doctor()
        passed.append("final-launchd-state-and-pid-refusals")

        let runLock = paths.state.path + "/run.lock"
        guard chmod(runLock, 0o644) == 0 else {
            throw M6HarnessError.message("could not alter run-lock mode fixture")
        }
        try expectFailure("doctor repaired or accepted an unsafe run lock") {
            _ = try lifecycle.doctor()
        }
        var unsafeRunLock = stat()
        try check(
            lstat(runLock, &unsafeRunLock) == 0
                && mode_t(unsafeRunLock.st_mode) & 0o777 == 0o644,
            "doctor mutated the unsafe run-lock mode"
        )
        guard chmod(runLock, 0o600) == 0 else {
            throw M6HarnessError.message("could not restore run-lock mode fixture")
        }
        _ = try lifecycle.doctor()
        passed.append("doctor-read-only-all-lock-validation")

        let tamper = try FileHandle(forWritingTo: URL(fileURLWithPath: installedExecutable))
        try tamper.seekToEnd()
        try tamper.write(contentsOf: Data([0x00]))
        try tamper.close()
        let tamperedDigest = try sha256(installedExecutable)
        try expectFailure("ordinary reconcile replaced a tampered bundle") {
            _ = try lifecycle.install(sourceBundle: sourceN1)
        }
        try check(
            try sha256(installedExecutable) == tamperedDigest,
            "reconcile changed the refused tampered target"
        )
        _ = try lifecycle.install(sourceBundle: sourceN, intent: .repair)
        _ = try lifecycle.doctor()
        passed.append("explicit-repair-only-for-tampered-bundle")

        let run = try RunAuthority.acquireRun(at: paths.state)
        try expectFailure("uninstall overlapped an active run") {
            try lifecycle.uninstall()
        }
        run.release()
        _ = try lifecycle.doctor()
        passed.append("uninstall-contention-no-change")

        _ = try lifecycle.doctor()

        func requireStoppedRollback(_ reason: String) throws {
            let restored = try ReleaseIdentity.load(bundlePath: paths.app)
            try check(restored == first.release
                && launcher.state(label: InstallationPaths.label) == .absent
                && !host.isReady(location: paths.state, executable: installedExecutable,
                                 release: first.release, timeout: 0),
                "\(reason) did not restore stopped preimages")
            try expectFailure("\(reason) reported stopped rollback ready") {
                _ = try lifecycle.doctor()
            }
        }

        for stage in [
            "after-gates",
            "after-drain",
            "before-promotion",
            "after-app-backup",
            "after-plist-backup",
            "after-app-promotion",
            "after-plist-promotion",
            "after-bootstrap",
            "after-kickstart",
            "after-readiness",
            "after-commit",
            "after-cleanup",
        ] {
            let injected = InstallationLifecycle(
                paths: paths,
                launchAgent: launcher,
                host: host,
                fault: { observed in
                    if observed == stage {
                        throw M6HarnessError.message("fault:\(stage)")
                    }
                }
            )
            try expectFailure("fault \(stage) was not observed") {
                _ = try injected.install(sourceBundle: sourceN1)
            }
            if stage == "after-commit" || stage == "after-cleanup" {
                _ = try lifecycle.install(sourceBundle: sourceN1)
                let retained = try lifecycle.doctor()
                try check(
                    retained.release.sourceInputSHA256
                        != first.release.sourceInputSHA256,
                    "post-commit fault \(stage) rolled back N+1"
                )
                _ = try lifecycle.install(sourceBundle: sourceN)
            } else if stage == "after-gates" {
                // Refusal before drainage leaves the untouched current host.
                let restored = try lifecycle.doctor()
                try check(
                    restored.release.sourceInputSHA256 == first.release.sourceInputSHA256,
                    "fault \(stage) did not restore N"
                )
            } else {
                try requireStoppedRollback("fault \(stage)")
            }
            try check(
                try durableEvidenceIsExact(),
                "fault \(stage) changed durable state evidence"
            )
            passed.append("rollback-\(stage)")
            if stage != "after-gates" && stage != "after-commit" && stage != "after-cleanup" {
                _ = try lifecycle.install(sourceBundle: sourceN, intent: .repair)
            }
        }

        launcher.failBootstrapOnce()
        try expectFailure("bootstrap failure was accepted") {
            _ = try lifecycle.install(sourceBundle: sourceN1)
        }
        try requireStoppedRollback("launch failure")
        try check(
            try durableEvidenceIsExact(),
            "launch rollback changed durable state evidence"
        )
        passed.append("launch-failure-rollback")
        _ = try lifecycle.install(sourceBundle: sourceN, intent: .repair)

        host.failReadinessOnce()
        try expectFailure("readiness failure was accepted") {
            _ = try lifecycle.install(sourceBundle: sourceN1)
        }
        try requireStoppedRollback("readiness failure")
        try check(
            try durableEvidenceIsExact(),
            "readiness rollback changed durable state evidence"
        )
        passed.append("readiness-failure-rollback")
        _ = try lifecycle.install(sourceBundle: sourceN, intent: .repair)

        let currentRelease = try ReleaseIdentity.load(
            bundlePath: paths.app
        )
        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        let interruptedUninstall = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { stage in
                if stage
                    == "uninstall-after-staged-coordination-recovery" {
                    throw M6HarnessError.message(
                        "fault:\(stage)"
                    )
                }
            }
        )
        try expectFailure(
            "staged coordination uninstall interruption was accepted"
        ) {
            try interruptedUninstall.uninstall()
        }
        try check(
            FileManager.default.fileExists(atPath: paths.app)
                && FileManager.default.fileExists(
                    atPath: paths.launchAgent
                )
                && coordinationResidueIsAbsent(paths)
                && (try durableEvidenceIsExact()),
            "interrupted staged uninstall reported false removal"
        )
        try lifecycle.uninstall()
        try check(
            !FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(
                    atPath: paths.launchAgent
                )
                && coordinationResidueIsAbsent(paths)
                && (try durableEvidenceIsExact()),
            "staged-only uninstall recovery left product residue"
        )
        passed.append("staged-only-coordination-uninstall")
        passed.append("staged-uninstall-interruption-recovery")

        _ = try lifecycle.install(sourceBundle: sourceN)
        _ = try lifecycle.install(sourceBundle: sourceN1)
        try FileManager.default.copyItem(
            atPath: sourceN,
            toPath: appPrevious
        )
        try renderLaunchAgent(
            template: sourceN
                + "/Contents/Resources/"
                + "com.kleinperkins.shadow-sync.plist.template",
            destination: plistPrevious,
            executable: installedExecutable
        )
        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        let promotedRelease = try ReleaseIdentity.load(
            bundlePath: paths.app
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: promotedRelease
        )
        try lifecycle.uninstall()
        try check(
            !FileManager.default.fileExists(atPath: paths.app)
                && !FileManager.default.fileExists(
                    atPath: paths.launchAgent
                )
                && !FileManager.default.fileExists(atPath: appPrevious)
                && !FileManager.default.fileExists(atPath: plistPrevious)
                && coordinationResidueIsAbsent(paths)
                && (try durableEvidenceIsExact()),
            "paired staged uninstall recovery left lifecycle residue"
        )
        passed.append("paired-staged-coordination-uninstall")

        _ = try lifecycle.install(sourceBundle: sourceN)
        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        let foreignStagedRelease = try ReleaseIdentity.load(
            bundlePath: sourceN1
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: foreignStagedRelease
        )
        let stagedOwner =
            paths.state.path + "/.host-owner.json.previous"
        let stagedSocket =
            paths.state.path + "/.host.sock.previous"
        let refusedStagedIdentities = [
            try nodeIdentity(paths.app),
            try nodeIdentity(paths.launchAgent),
            try nodeIdentity(stagedOwner),
            try nodeIdentity(stagedSocket),
        ]
        try expectFailure("foreign staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        try check(
            [
                try nodeIdentity(paths.app),
                try nodeIdentity(paths.launchAgent),
                try nodeIdentity(stagedOwner),
                try nodeIdentity(stagedSocket),
            ] == refusedStagedIdentities
                && (try durableEvidenceIsExact()),
            "foreign staged refusal changed product state"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("foreign-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        try Data("{}\n".utf8).write(
            to: URL(fileURLWithPath: stagedOwner),
            options: .atomic
        )
        guard chmod(stagedOwner, 0o600) == 0 else {
            throw M6HarnessError.message(
                "could not secure malformed staged owner"
            )
        }
        let malformedStagedOwner = try pathDigest(stagedOwner)
        try expectFailure("malformed staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        try check(
            try pathDigest(stagedOwner) == malformedStagedOwner
                && nodeExists(stagedSocket)
                && FileManager.default.fileExists(atPath: paths.app),
            "malformed staged refusal changed product state"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("malformed-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        guard chmod(stagedOwner, 0o640) == 0 else {
            throw M6HarnessError.message(
                "could not alter staged owner mode"
            )
        }
        try expectFailure("wrong-mode staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        var wrongModeStagedOwner = stat()
        try check(
            lstat(stagedOwner, &wrongModeStagedOwner) == 0
                && mode_t(wrongModeStagedOwner.st_mode) & 0o777
                    == 0o640
                && nodeExists(stagedSocket),
            "wrong-mode staged refusal changed coordination"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("wrong-mode-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        let stagedHardlink = paths.home + "/staged-owner-hardlink"
        guard link(stagedOwner, stagedHardlink) == 0 else {
            throw M6HarnessError.message(
                "could not hardlink staged owner"
            )
        }
        try expectFailure("hardlinked staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        var hardlinkedStagedOwner = stat()
        try check(
            lstat(stagedOwner, &hardlinkedStagedOwner) == 0
                && hardlinkedStagedOwner.st_nlink == 2
                && nodeExists(stagedSocket),
            "hardlinked staged refusal changed coordination"
        )
        guard unlink(stagedHardlink) == 0 else {
            throw M6HarnessError.message(
                "could not remove staged owner hardlink"
            )
        }
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("hardlinked-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        let stagedSymlinkTarget = paths.home + "/staged-symlink-target"
        try Data("target".utf8).write(
            to: URL(fileURLWithPath: stagedSymlinkTarget)
        )
        try FileManager.default.removeItem(atPath: stagedOwner)
        guard symlink(stagedSymlinkTarget, stagedOwner) == 0 else {
            throw M6HarnessError.message(
                "could not symlink staged owner"
            )
        }
        try expectFailure("symlinked staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        var symlinkedStagedOwner = stat()
        try check(
            lstat(stagedOwner, &symlinkedStagedOwner) == 0
                && mode_t(symlinkedStagedOwner.st_mode) & S_IFMT
                    == S_IFLNK
                && nodeExists(stagedSocket),
            "symlinked staged refusal changed coordination"
        )
        try removeDeadHostCoordination(paths)
        try FileManager.default.removeItem(atPath: stagedSymlinkTarget)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("symlinked-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        let liveStagedProcess = Process()
        let liveStagedInput = Pipe()
        liveStagedProcess.executableURL = URL(
            fileURLWithPath: installedExecutable
        )
        liveStagedProcess.arguments = [mode, "0"]
        liveStagedProcess.standardInput = liveStagedInput
        liveStagedProcess.standardOutput = FileHandle.nullDevice
        liveStagedProcess.standardError = FileHandle.nullDevice
        try liveStagedProcess.run()
        defer {
            try? liveStagedInput.fileHandleForWriting.close()
            if liveStagedProcess.isRunning {
                liveStagedProcess.terminate()
                liveStagedProcess.waitUntilExit()
            }
        }
        let liveGeneration =
            "33333333-3333-4333-8333-333333333333"
        let liveIdentity = try ProcessIdentity.capture(
            processID: liveStagedProcess.processIdentifier,
            generation: liveGeneration,
            expectedExecutablePath: installedExecutable
        )
        var liveRegistration = try JSONEncoder().encode(
            HostRegistration(
                identity: liveIdentity,
                release: currentRelease
            )
        )
        liveRegistration.append(0x0A)
        try liveRegistration.write(
            to: URL(fileURLWithPath: stagedOwner),
            options: .atomic
        )
        guard chmod(stagedOwner, 0o600) == 0 else {
            throw M6HarnessError.message(
                "could not secure live staged owner"
            )
        }
        try expectFailure("live staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        try check(
            liveStagedProcess.isRunning
                && nodeExists(stagedOwner)
                && nodeExists(stagedSocket)
                && FileManager.default.fileExists(atPath: paths.app),
            "live staged refusal changed product state"
        )
        try liveStagedInput.fileHandleForWriting.close()
        liveStagedProcess.waitUntilExit()
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("live-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try writeDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        try FileManager.default.moveItem(
            atPath: paths.state.path + "/host-owner.json",
            toPath: stagedOwner
        )
        let unpairedOwner = try nodeIdentity(stagedOwner)
        let unpairedSocket =
            try nodeIdentity(paths.state.path + "/host.sock")
        try expectFailure("unpaired staged coordination was uninstalled") {
            try lifecycle.uninstall()
        }
        try check(
            try nodeIdentity(stagedOwner)
                == unpairedOwner
                && (try nodeIdentity(paths.state.path + "/host.sock"))
                    == unpairedSocket
                && (try durableEvidenceIsExact()),
            "unpaired staged refusal partially deleted coordination"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("unpaired-staged-uninstall-refusal")

        try launcher.bootout(
            label: InstallationPaths.label,
            expectedProgram: installedExecutable
        )
        try stageDeadHostCoordination(
            paths: paths,
            release: currentRelease
        )
        let racingUninstall = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { stage in
                if stage
                    == "uninstall-after-staged-coordination-preview" {
                    let bytes = try Data(
                        contentsOf: URL(fileURLWithPath: stagedOwner)
                    )
                    try bytes.write(
                        to: URL(fileURLWithPath: stagedOwner),
                        options: .atomic
                    )
                    guard chmod(stagedOwner, 0o600) == 0 else {
                        throw M6HarnessError.message(
                            "could not secure raced staged owner"
                        )
                    }
                }
            }
        )
        try expectFailure("staged coordination race was uninstalled") {
            try racingUninstall.uninstall()
        }
        try check(
            nodeExists(stagedOwner)
                && nodeExists(stagedSocket)
                && FileManager.default.fileExists(atPath: paths.app)
                && FileManager.default.fileExists(
                    atPath: paths.launchAgent
                )
                && (try durableEvidenceIsExact()),
            "staged coordination race refusal changed product state"
        )
        try removeDeadHostCoordination(paths)
        _ = try lifecycle.install(
            sourceBundle: sourceN,
            intent: .repair
        )
        passed.append("raced-staged-uninstall-refusal")

        let unknown = paths.state.path + "/unknown"
        try Data("unknown".utf8).write(to: URL(fileURLWithPath: unknown))
        guard chmod(unknown, 0o600) == 0 else {
            throw M6HarnessError.message("could not secure unknown-state fixture")
        }
        try expectFailure("uninstall removed unverifiable state") {
            try lifecycle.uninstall()
        }
        try check(
            FileManager.default.fileExists(atPath: unknown),
            "uninstall deleted unknown state"
        )
        try expectFailure("doctor accepted unknown state") {
            _ = try lifecycle.doctor()
        }
        try FileManager.default.removeItem(atPath: unknown)
        _ = try lifecycle.doctor()
        passed.append("uninstall-unknown-state-no-change")

        let logPath = paths.state.path + "/latest.log"
        let beforeLog = try sha256(logPath)
        try lifecycle.uninstall()
        let afterLog = try sha256(logPath)
        try check(beforeLog == afterLog, "uninstall changed latest.log")
        try check(
            try durableEvidenceIsExact(),
            "uninstall changed durable state evidence"
        )
        try check(!FileManager.default.fileExists(atPath: paths.app), "uninstall left app")
        try check(
            !FileManager.default.fileExists(atPath: paths.launchAgent),
            "uninstall left LaunchAgent"
        )
        let stateEntries = Set(
            try FileManager.default.contentsOfDirectory(
                atPath: paths.state.path
            )
        )
        try check(
            stateEntries == [
                "latest.log", RepositoryAuthorityStore.filename,
                RepositorySelectionPreferenceStore.filename,
                RepositorySelectionPreferenceStore.recoveryFilename,
                "retention",
            ],
            "uninstall did not preserve exactly the log, "
                + "canonical-root authority, saved defaults, "
                + "and recovery artifacts"
        )
        passed.append(
            "verified-uninstall-durable-state"
        )
        passed.append(
            "durable-state-update-repair-rollback-uninstall"
        )

        return M6LifecycleResult(
            passed: passed,
            launchctlInvocations: launcher.audit,
            latestLogSHA256: afterLog
        )
    }

    private static func crash(
        root: String,
        sourceN: String,
        sourceN1: String,
        stage: String
    ) throws {
        let paths = try InstallationPaths.isolated(root: root)
        try TestIsolation.initializeState(at: paths.state)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )
        _ = try lifecycle.install(sourceBundle: sourceN)
        let crashing = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { observed in
                if observed == stage {
                    _exit(86)
                }
            }
        )
        _ = try crashing.install(sourceBundle: sourceN1)
    }

    private static func repairCrash(
        root: String,
        sourceN: String,
        sourceN1: String,
        stage: String
    ) throws {
        let paths = try InstallationPaths.isolated(root: root)
        try TestIsolation.initializeState(at: paths.state)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        _ = try InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        ).install(sourceBundle: sourceN)
        let executable = paths.app + "/Contents/MacOS/ShadowSync"
        let tamper = try FileHandle(forWritingTo: URL(fileURLWithPath: executable))
        try tamper.seekToEnd()
        try tamper.write(contentsOf: Data([0x00]))
        try tamper.close()
        let crashing = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { observed in
                if observed == stage {
                    _exit(86)
                }
            }
        )
        _ = try crashing.install(sourceBundle: sourceN1, intent: .repair)
    }

    private static func recover(
        root: String,
        sourceN1: String
    ) throws -> M6LifecycleResult {
        let paths = try InstallationPaths.isolated(root: root)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        let lifecycle = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host
        )
        let installed = try lifecycle.install(
            sourceBundle: sourceN1,
            intent: .repair
        )
        let doctor = try lifecycle.doctor()
        try check(
            installed.release == doctor.release,
            "crash recovery doctor disagreed with installed N+1"
        )
        try lifecycle.uninstall()
        return M6LifecycleResult(
            passed: ["crash-recovered", "crash-recovery-uninstalled"],
            launchctlInvocations: [],
            latestLogSHA256: ""
        )
    }

    private static func firstCrash(
        root: String,
        sourceN1: String,
        stage: String
    ) throws {
        let paths = try InstallationPaths.isolated(root: root)
        try TestIsolation.initializeState(at: paths.state)
        let launcher = ProcessLaunchAgent(root: root)
        let host = SystemInstalledHostController()
        let crashing = InstallationLifecycle(
            paths: paths,
            launchAgent: launcher,
            host: host,
            fault: { observed in
                if observed == stage {
                    _exit(86)
                }
            }
        )
        _ = try crashing.install(sourceBundle: sourceN1)
    }

    private static func sha256(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func inode(_ path: String) throws -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw M6HarnessError.message("missing stable lock \(path)")
        }
        return UInt64(info.st_ino)
    }

    private static func durableIdentity(
        _ path: String,
        isDirectory: Bool = false
    ) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0,
            (info.st_mode & S_IFMT)
                == (isDirectory ? S_IFDIR : S_IFREG),
            isDirectory || info.st_nlink == 1
        else {
            throw M6HarnessError.message(
                "durable evidence identity is unsafe"
            )
        }
        return [
            String(UInt64(info.st_dev)),
            String(UInt64(info.st_ino)),
            String(UInt32(info.st_uid)),
            String(UInt32(info.st_mode)),
            String(UInt64(info.st_nlink)),
        ].joined(separator: ":")
    }

    private static func makePredecessorBundle(
        source: String,
        destination: String
    ) throws {
        try FileManager.default.copyItem(
            atPath: source,
            toPath: destination
        )
        let predecessorExecutable =
            destination + "/Contents/MacOS/ShadowSync"
        guard chmod(predecessorExecutable, 0o700) == 0 else {
            throw M6HarnessError.message(
                "could not secure predecessor executable fixture"
            )
        }
        let infoPath = destination + "/Contents/Info.plist"
        guard var info = NSDictionary(
            contentsOfFile: infoPath
        ) as? [String: Any] else {
            throw M6HarnessError.message(
                "could not read predecessor Info.plist fixture"
            )
        }
        info["CFBundleDisplayName"] = "Dev Main Sync"
        info["CFBundleName"] = "Dev Main Sync"
        info["CFBundleExecutable"] = "ShadowSync"
        info["ShadowSyncSourceRevision"] =
            "783fa0587cccdb2c88a6a8b246c1ed0ed536e60b"
        info["ShadowSyncSourceInputSHA256"] =
            "0aaaad83bb080e6ed0db71de2df9b9010d63a79ceb78dfee73785cfe218ffa7c"
        info["ShadowSyncReleaseContractSHA256"] =
            "08d13f1f8425e952a2aa6d8662eebc846066d135fec806f82b14ba44b9175b5f"
        info["ShadowSyncBuildMode"] = "production"
        let rendered = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try rendered.write(to: URL(fileURLWithPath: infoPath))
        guard chmod(infoPath, 0o600) == 0 else {
            throw M6HarnessError.message(
                "could not secure predecessor Info.plist fixture"
            )
        }
        try runFixtureTool(
            "/usr/bin/codesign",
            [
                "--force", "--sign", "-", "--timestamp=none",
                "--identifier", "com.kleinperkins.shadow-sync",
                destination,
            ]
        )
        try runFixtureTool("/usr/bin/xattr", ["-cr", destination])
        try runFixtureTool(
            "/usr/bin/codesign",
            ["--verify", "--strict", destination]
        )
    }

    private static func runFixtureTool(
        _ executable: String,
        _ arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard OwnedProcessReaper.wait(for: process, timeout: 15),
              process.terminationStatus == 0 else {
            throw M6HarnessError.message(
                "predecessor fixture tool failed"
            )
        }
    }

    private static func renderLaunchAgent(
        template: String,
        destination: String,
        executable: String,
        managedHost: Bool = true
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: template))
        guard var object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw M6HarnessError.message("invalid LaunchAgent fixture template")
        }
        object["ProgramArguments"] = managedHost
            ? [executable, InstallationPaths.managedHostArgument]
            : [executable]
        let rendered = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        try rendered.write(to: URL(fileURLWithPath: destination))
        guard chmod(destination, 0o600) == 0 else {
            throw M6HarnessError.message("could not secure LaunchAgent fixture")
        }
    }

    private static func writeDeadHostCoordination(
        paths: InstallationPaths,
        release: ReleaseIdentity,
        executable: String? = nil
    ) throws {
        let state = try SecureStateDirectory.openExisting(paths.state)
        let owner = state.path + "/host-owner.json"
        let socketPath = state.path + "/host.sock"
        guard !nodeExists(owner),
              !nodeExists(socketPath) else {
            throw M6HarnessError.message(
                "dead coordination fixture collided"
            )
        }
        let registration = M6DeadHostRegistration(
            schema: HostRegistration.schemaName,
            identity: M6DeadHostIdentity(
                processID: 999_999,
                processGroupID: 999_999,
                userID: geteuid(),
                startSeconds: 1,
                startMicroseconds: 0,
                executablePath: executable ?? paths.executable,
                generation:
                    "22222222-2222-4222-8222-222222222222"
            ),
            release: release
        )
        var bytes = try JSONEncoder().encode(registration)
        bytes.append(0x0A)
        // This is a create-only dead-host fixture, fully prepared before
        // lifecycle observation. Keep Foundation staging inside isolation.
        try bytes.write(
            to: URL(fileURLWithPath: owner),
            options: .withoutOverwriting
        )
        guard chmod(owner, 0o600) == 0 else {
            throw M6HarnessError.message(
                "could not secure dead host owner"
            )
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw M6HarnessError.message(
                "could not create dead host socket"
            )
        }
        defer { close(descriptor) }
        var address = try hostSocketAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        let bindError = result == 0 ? 0 : errno
        guard result == 0 else {
            throw M6HarnessError.message(
                "could not bind dead host socket: "
                    + "errno=\(bindError) path-length="
                    + "\(socketPath.utf8.count)"
            )
        }
        guard chmod(socketPath, 0o600) == 0 else {
            throw M6HarnessError.message(
                "could not secure dead host socket"
            )
        }
    }

    private static func stageDeadHostCoordination(
        paths: InstallationPaths,
        release: ReleaseIdentity
    ) throws {
        try writeDeadHostCoordination(
            paths: paths,
            release: release
        )
        try FileManager.default.moveItem(
            atPath: paths.state.path + "/host-owner.json",
            toPath: paths.state.path + "/.host-owner.json.previous"
        )
        do {
            try FileManager.default.moveItem(
                atPath: paths.state.path + "/host.sock",
                toPath: paths.state.path + "/.host.sock.previous"
            )
        } catch {
            try? FileManager.default.moveItem(
                atPath:
                    paths.state.path + "/.host-owner.json.previous",
                toPath: paths.state.path + "/host-owner.json"
            )
            throw error
        }
    }

    private static func removeDeadHostCoordination(
        _ paths: InstallationPaths
    ) throws {
        for name in [
            "host-owner.json",
            "host.sock",
            ".host-owner.json.previous",
            ".host.sock.previous",
        ] {
            let path = paths.state.path + "/" + name
            if nodeExists(path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static func coordinationResidueIsAbsent(
        _ paths: InstallationPaths
    ) -> Bool {
        [
            "host-owner.json",
            "host.sock",
            ".host-owner.json.previous",
            ".host.sock.previous",
        ].allSatisfy {
            !nodeExists(paths.state.path + "/" + $0)
        }
    }

    private static func nodeExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func hostSocketAddress(
        path: String
    ) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count
                <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw M6HarnessError.message(
                "dead host socket path is too long"
            )
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(
            MemoryLayout<sockaddr_un>.size
        )
        withUnsafeMutableBytes(of: &address.sun_path) {
            destination in
            destination.initializeMemory(
                as: UInt8.self,
                repeating: 0
            )
            pathBytes.withUnsafeBytes {
                destination.copyBytes(from: $0)
            }
        }
        return address
    }

    private static func nodeIdentity(
        _ path: String
    ) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw M6HarnessError.message(
                "lifecycle node disappeared"
            )
        }
        return [
            String(UInt64(info.st_dev)),
            String(UInt64(info.st_ino)),
            String(UInt32(info.st_uid)),
            String(UInt32(info.st_mode)),
            String(UInt64(info.st_nlink)),
        ].joined(separator: ":")
    }

    private static func pathDigest(
        _ path: String
    ) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw M6HarnessError.message(
                "lifecycle digest path disappeared"
            )
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return try BundleArtifactIdentity.inspect(
                bundlePath: path,
                requireProduction: true
            ).canonicalSHA256
        }
        return try sha256(path)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw M6HarnessError.message(message) }
    }

    private static func expectFailure(
        _ message: String,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw M6HarnessError.message(message)
    }
}

private enum M6HarnessError: Error {
    case message(String)
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
#endif
