import Darwin
import Foundation

public enum ProcessOwnershipError: Error, CustomStringConvertible {
    case unavailable(String)
    case identityMismatch
    case invalidRegistration
    case unsafeSocket
    case unverifiedOwner

    public var description: String {
        switch self {
        case let .unavailable(operation):
            return "\(operation) is unavailable"
        case .identityMismatch:
            return "the process identity no longer matches"
        case .invalidRegistration:
            return "the host registration is invalid"
        case .unsafeSocket:
            return "the host control socket is unsafe"
        case .unverifiedOwner:
            return "the active process owner could not be verified"
        }
    }
}

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public let processID: pid_t
    public let processGroupID: pid_t
    public let userID: uid_t
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executablePath: String
    public let generation: String

    public static func capture(
        processID: pid_t,
        generation: String,
        expectedExecutablePath: String? = nil
    ) throws -> ProcessIdentity {
        guard processID > 1, RunIdentity.isValid(generation) else {
            throw ProcessOwnershipError.identityMismatch
        }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard count == MemoryLayout<proc_bsdinfo>.size else {
            throw ProcessOwnershipError.identityMismatch
        }
        var storage = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let pathCount = proc_pidpath(
            processID,
            &storage,
            UInt32(storage.count)
        )
        guard pathCount > 0 else {
            throw ProcessOwnershipError.identityMismatch
        }
        let terminator = storage.firstIndex(of: 0) ?? storage.endIndex
        let executablePath = String(
            decoding: storage[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        if let expectedExecutablePath {
            if executablePath != expectedExecutablePath {
                guard let observedPath = physicalPath(executablePath),
                      let expectedPath = physicalPath(expectedExecutablePath),
                      observedPath == expectedPath else {
                    throw ProcessOwnershipError.identityMismatch
                }
            }
        }
        let groupID = getpgid(processID)
        guard groupID > 1 else {
            throw ProcessOwnershipError.identityMismatch
        }
        return ProcessIdentity(
            processID: processID,
            processGroupID: groupID,
            userID: info.pbi_uid,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec),
            executablePath: executablePath,
            generation: generation
        )
    }

    public func isCurrent(
        expectedGeneration: String? = nil,
        requireGroupLeader: Bool = true
    ) -> Bool {
        if let expectedGeneration, expectedGeneration != generation {
            return false
        }
        guard let observed = try? Self.capture(
            processID: processID,
            generation: generation,
            expectedExecutablePath: executablePath
        ) else {
            return false
        }
        return observed == self
            && (!requireGroupLeader || processGroupID == processID)
    }

    /// The executable may differ only when a caller already holds an immutable
    /// qualified graph. This comparison does not construct signal/reap custody.
    func sameOriginalChild(as original: ProcessIdentity) -> Bool {
        guard processID == original.processID, processGroupID == original.processGroupID,
              processGroupID == processID, userID == original.userID, userID == geteuid(),
              startSeconds == original.startSeconds, startMicroseconds == original.startMicroseconds,
              generation == original.generation else { return false }
        var info = proc_bsdinfo()
        return proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size
            && info.pbi_pid == UInt32(processID) && info.pbi_ppid == UInt32(getpid())
            && info.pbi_uid == userID && UInt64(info.pbi_start_tvsec) == startSeconds
            && UInt64(info.pbi_start_tvusec) == startMicroseconds
    }

    private static func physicalPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

public enum OwnedProcessSignal {
    @discardableResult
    public static func send(
        _ signal: Int32,
        to identity: ProcessIdentity,
        expectedGeneration: String
    ) -> Bool {
        guard identity.isCurrent(expectedGeneration: expectedGeneration) else {
            return false
        }
        return kill(-identity.processGroupID, signal) == 0 || errno == ESRCH
    }
}

public enum WorkerStopOutcome: Equatable, Sendable {
    case cooperative(Int32)
    case terminated(Int32)
    case killed(Int32)
    case alreadyExited(Int32)
    case unverified
    case stillActive
}

public enum ProcessOwnershipTiming {
    public static let cooperativeAcknowledgement: TimeInterval = 2
    public static let termGrace: TimeInterval = 5
    public static let postKillReap: TimeInterval = 2
    public static let handoffSettlement: TimeInterval = 2
    public static let schedulingMargin: TimeInterval = 1

    public static var workerStopMaximum: TimeInterval {
        cooperativeAcknowledgement + termGrace + postKillReap
    }

    public static var ownedChildDrainMaximum: TimeInterval {
        termGrace + postKillReap
    }

    public static var takeoverWatchdogMaximum: TimeInterval {
        workerStopMaximum
            + ownedChildDrainMaximum
            + handoffSettlement
            + schedulingMargin
    }
}

public enum CancellationEscalationAction: Equatable, Sendable {
    case waitForCooperation
    case sendTerm
    case sendKill
    case needsAttention
}

public struct CancellationEscalationStateMachine: Equatable, Sendable {
    private let requestedAt: TimeInterval
    private var termAt: TimeInterval?
    private var killAt: TimeInterval?

    public init(requestedAt: TimeInterval) {
        self.requestedAt = requestedAt
    }

    public mutating func nextAction(
        at now: TimeInterval,
        ownerVerified: Bool
    ) -> CancellationEscalationAction {
        guard ownerVerified else {
            return .needsAttention
        }
        if let killAt {
            return now - killAt >= ProcessOwnershipTiming.postKillReap
                ? .needsAttention
                : .waitForCooperation
        }
        if let termAt {
            if now - termAt >= ProcessOwnershipTiming.termGrace {
                self.killAt = now
                return .sendKill
            }
            return .waitForCooperation
        }
        if now - requestedAt >= ProcessOwnershipTiming.cooperativeAcknowledgement {
            termAt = now
            return .sendTerm
        }
        return .waitForCooperation
    }
}

public final class LauncherAuthority: @unchecked Sendable {
    private let retirementMutex = NSLock()
    public let stateDirectory: SecureStateDirectory
    private let namespace: OwnedFileDescriptor?
    private let lock: OwnedFileDescriptor

    private init(
        state: SecureStateDirectory,
        namespaceDescriptor: Int32?,
        descriptor: Int32
    ) {
        stateDirectory = state
        namespace = namespaceDescriptor.map(OwnedFileDescriptor.init)
        lock = OwnedFileDescriptor(descriptor)
    }

    public static func acquire(at location: StateLocation) throws -> LauncherAuthority {
        let state = try SecureStateDirectory.open(location)
        let namespace = try state.openRegularFile(
            named: "latest.log",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        guard flock(namespace, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(namespace)
            if code == EWOULDBLOCK {
                throw SecureStateError.contention("latest.log")
            }
            throw SecureStateError.systemCall("flock latest.log", code)
        }
        do {
            return try acquireLock(
                state: state,
                namespaceDescriptor: namespace
            )
        } catch {
            close(namespace)
            throw error
        }
    }

    static func acquireWithinLifecycle(at location: StateLocation) throws -> LauncherAuthority {
        let state = try SecureStateDirectory.open(location)
        return try acquireLock(
            state: state,
            namespaceDescriptor: nil
        )
    }

    private static func acquireLock(
        state: SecureStateDirectory,
        namespaceDescriptor: Int32?
    ) throws -> LauncherAuthority {
        try state.requireStableLockFiles()
        let descriptor = try state.openRegularFile(
            named: "launcher.lock",
            flags: O_RDWR,
            create: false,
            repairPermissions: false
        )
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw SecureStateError.contention("launcher.lock")
            }
            throw SecureStateError.systemCall("flock launcher.lock", code)
        }
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            let code = errno
            close(descriptor)
            throw SecureStateError.systemCall("fcntl launcher.lock", code)
        }
        return LauncherAuthority(
            state: state,
            namespaceDescriptor: namespaceDescriptor,
            descriptor: descriptor
        )
    }

    /// Only readiness opening uses the actual admitted state. The original
    /// opening owner enrolls this launcher before any lock/configuration cut.
    static func acquireForReadiness(admission: LifecycleAdmissionAuthority,
        enrolling: (LauncherAuthority) -> Void) throws -> LauncherAuthority {
        guard admission.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        let state = admission.stateDirectory
        try state.requireStableLockFiles()
        let raw = try state.openRegularFile(named: "launcher.lock", flags: O_RDWR,
            create: false, repairPermissions: false)
        let owner = LauncherAuthority(state: state, namespaceDescriptor: nil, descriptor: raw)
        enrolling(owner)
        guard flock(raw, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { throw SecureStateError.contention("launcher.lock") }
            throw SecureStateError.systemCall("flock launcher.lock", code)
        }
        let flags = fcntl(raw, F_GETFD)
        guard flags >= 0, fcntl(raw, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw SecureStateError.systemCall("fcntl launcher.lock", errno)
        }
        guard admission.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        return owner
    }

    /// Read-only check of this actual retained launcher description. Matching
    /// serialized state never constructs, reopens or transfers its authority.
    func validateRetainedInstallation(_ expected: InstallationStateBinding) throws {
        retirementMutex.lock(); defer { retirementMutex.unlock() }
        // Inspect the actual descriptions while excluding this owner's release.
        // No temporary flock alias with an unchecked deferred close is created.
        let held = lock.value, state = stateDirectory.descriptor.value
        guard held >= 0, state >= 0 else { throw CustodyRecordError.fenced }
        let live = try InstallationStateBinding.capture(stateDescriptor: state, uid: stateDirectory.uid)
        let a = expected.directory, b = live.directory
        var named = stat(), descriptor = stat()
        guard a.device == b.device, a.inode == b.inode, a.type == b.type,
              a.uid == b.uid, a.mode == b.mode, a.aclDigest == b.aclDigest,
              a.links > 0, b.links > 0, live.launcher == expected.launcher,
              lstat(stateDirectory.path, &named) == 0,
              UInt64(named.st_dev) == b.device, UInt64(named.st_ino) == b.inode,
              UInt32(named.st_mode) == b.mode, named.st_uid == b.uid,
              fstat(held, &descriptor) == 0, descriptor.st_flags == 0,
              UInt64(descriptor.st_dev) == expected.launcher.device,
              UInt64(descriptor.st_ino) == expected.launcher.inode,
              UInt32(descriptor.st_mode) == expected.launcher.mode,
              descriptor.st_uid == expected.launcher.uid, UInt64(descriptor.st_nlink) == expected.launcher.links,
              CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(held).utf8)) == expected.launcher.aclDigest,
              lock.value >= 0 else { throw CustodyRecordError.fenced }
    }

    /// Used only by the original committed host after its server work and
    /// created nodes have retired. A failed lock close preserves namespace.
    func retireCommittedHostLauncher() -> OwnedFileDescriptor.Retirement {
        retirementMutex.lock(); defer { retirementMutex.unlock() }
        let result = lock.retireChecked()
        guard result == .succeeded else { return result }
        return namespace?.retireChecked() ?? .succeeded
    }

    public func release() {
        retirementMutex.lock(); defer { retirementMutex.unlock() }
        lock.closeNow()
        namespace?.closeNow()
    }
}

public struct HostRegistration: Codable, Equatable, Sendable {
    public static let schemaName = "shadow-sync-host/v1"
    public let schema: String
    public let identity: ProcessIdentity
    public let release: ReleaseIdentity?

    public init(identity: ProcessIdentity, release: ReleaseIdentity? = nil) {
        schema = Self.schemaName
        self.identity = identity
        self.release = release
    }

    public var hasValidShape: Bool {
        schema == Self.schemaName
            && identity.processID > 1
            && identity.processGroupID > 1
            && identity.userID == geteuid()
            && identity.startSeconds > 0
            && identity.startMicroseconds < 1_000_000
            && identity.executablePath.hasPrefix("/")
            && !identity.executablePath.contains("\n")
            && !identity.executablePath.contains("\0")
            && RunIdentity.isValid(identity.generation)
    }

    public var isValid: Bool {
        hasValidShape
            && identity.isCurrent(
                expectedGeneration: identity.generation,
                requireGroupLeader: false
            )
    }
}

public enum HostRegistrationStore {
    private static let name = "host-owner.json"

    public static func write(
        _ registration: HostRegistration,
        state: SecureStateDirectory
    ) throws {
        guard registration.isValid else {
            throw ProcessOwnershipError.invalidRegistration
        }
        let descriptor = try state.openRegularFile(
            named: name,
            flags: O_WRONLY,
            create: true
        )
        defer { close(descriptor) }
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw SecureStateError.systemCall("truncate host registration", errno)
        }
        var data = try JSONEncoder().encode(registration)
        data.append(0x0A)
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw SecureStateError.systemCall("fsync host registration", errno)
        }
    }

    public static func read(state: SecureStateDirectory) throws -> HostRegistration {
        let value = try readPersisted(state: state)
        guard value.isValid else {
            throw ProcessOwnershipError.invalidRegistration
        }
        return value
    }

    public static func readPersisted(
        state: SecureStateDirectory
    ) throws -> HostRegistration {
        try readPersisted(state: state, named: name)
    }

    static func readPersisted(
        state: SecureStateDirectory,
        named filename: String
    ) throws -> HostRegistration {
        let descriptor = try state.openRegularFile(
            named: filename,
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size > 0,
              info.st_size <= 16_384 else {
            throw ProcessOwnershipError.invalidRegistration
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                break
            }
            return offset
        }
        data.count = count
        while data.last == 0x0A {
            data.removeLast()
        }
        let value = try JSONDecoder().decode(HostRegistration.self, from: data)
        guard value.hasValidShape else {
            throw ProcessOwnershipError.invalidRegistration
        }
        return value
    }

    public static func remove(state: SecureStateDirectory) throws {
        if unlinkat(state.descriptor.value, name, 0) != 0, errno != ENOENT {
            throw SecureStateError.systemCall("unlink host registration", errno)
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw SecureStateError.systemCall("write host registration", errno)
            }
        }
    }
}

public struct RunIntent: Codable, Equatable, Sendable {
    public let run: String
    public let startedAt: String
    public let candidates: [RepositoryCandidate]
    public let repositoryModel: String?

    public init(
        run: String,
        startedAt: String,
        candidates: [RepositoryCandidate],
        repositoryModel: String? = nil
    ) {
        self.run = run
        self.startedAt = startedAt
        self.candidates = candidates
        self.repositoryModel = repositoryModel
    }
}

public struct RepositoryCheckpoint: Codable, Equatable, Sendable {
    public let repository: RepositoryCandidate
    public let startedAt: String
    public let beforeCommit: String?
    public let targetCommit: String?
    public let fetched: Bool

    public init(
        repository: RepositoryCandidate,
        startedAt: String,
        beforeCommit: String?,
        targetCommit: String?,
        fetched: Bool
    ) {
        self.repository = repository
        self.startedAt = startedAt
        self.beforeCommit = beforeCommit
        self.targetCommit = targetCommit
        self.fetched = fetched
    }
}

public enum InterruptedPostflight: Equatable, Sendable {
    case unchanged(String?)
    case updated(String)
    case ambiguous(String?)
}

public enum InterruptedRunReconstructor {
    public static let summary = "Previous run interrupted — review required"
    public static let operationContentionTitle =
        "Another ShadowSync operation is finishing"
    public static let operationContentionMessage =
        "ShadowSync cannot continue until the other operation finishes."
    public static let operationContentionRecovery =
        "Wait a moment, or close this message and try again shortly."

    public static func reconstruct(
        records: [LogRecord],
        postflight: (RepositoryCheckpoint) -> InterruptedPostflight
    ) -> RunReport? {
        guard let intentRecord = records.first(where: {
            $0.type == "run_intent" && $0.intent != nil
        }), let intent = intentRecord.intent,
              RunIdentity.isValid(intent.run) else {
            return nil
        }
        if let completed = RunLogReader.completedReport(
            in: records,
            matching: intent.run
        ) {
            return completed
        }
        var completedByPath: [String: RepositoryResult] = [:]
        for record in records where record.run == intent.run {
            if let result = record.event?.result {
                completedByPath[result.repository.path] = result
            }
        }
        var checkpoints: [String: RepositoryCheckpoint] = [:]
        for record in records where record.run == intent.run {
            if let checkpoint = record.checkpoint {
                checkpoints[checkpoint.repository.path] = checkpoint
            }
        }
        let endedAt = WallClock.timestamp()
        let results = intent.candidates.map { candidate -> RepositoryResult in
            if let completed = completedByPath[candidate.path] {
                return completed
            }
            guard let checkpoint = checkpoints[candidate.path] else {
                return RepositoryResult(
                    repository: candidate,
                    code: .cancelledPending,
                    fetched: false,
                    mainUpdated: false,
                    beforeCommit: nil,
                    targetCommit: nil,
                    afterCommit: nil,
                    startedAt: endedAt,
                    endedAt: endedAt,
                    durationMilliseconds: 0,
                    explanation: "The previous run ended before this repository started."
                )
            }
            let observed = postflight(checkpoint)
            let code: ResultCode
            let updated: Bool
            let after: String?
            let explanation: String
            switch observed {
            case let .unchanged(commit):
                code = .cancelledNoUpdate
                updated = false
                after = commit
                explanation = "The interrupted operation did not update local main."
            case let .updated(commit):
                code = .updatedBeforeCancellation
                updated = true
                after = commit
                explanation = "The update completed before the previous run ended."
            case let .ambiguous(commit):
                code = .needsAttention
                updated = false
                after = commit
                explanation = "The interrupted operation could not be verified safely."
            }
            return RepositoryResult(
                repository: candidate,
                code: code,
                fetched: checkpoint.fetched,
                mainUpdated: updated,
                beforeCommit: checkpoint.beforeCommit,
                targetCommit: checkpoint.targetCommit,
                afterCommit: after,
                startedAt: checkpoint.startedAt,
                endedAt: endedAt,
                durationMilliseconds: 0,
                explanation: explanation
            )
        }
        return RunReport(
            run: intent.run,
            startedAt: intent.startedAt,
            endedAt: endedAt,
            cancelled: true,
            results: results,
            summaryOverride: summary,
            repositoryModel: "v2"
        )
    }
}

public enum RunRecoveryState: Equatable, Sendable {
    case none
    case previousReport(RunReport)
    case operationStillActive
    case needsAttention
}

public enum RunRecoveryInspector {
    public static func inspect(at location: StateLocation) -> RunRecoveryState {
        let authority: RunAuthority
        do {
            authority = try RunAuthority.acquireRun(at: location)
        } catch let SecureStateError.contention(name)
            where name == "operation.lock" || name == "run.lock" {
            return .operationStillActive
        } catch {
            return .needsAttention
        }
        defer { authority.release() }
        do {
            let read = try RunLogReader.snapshot(
                state: authority.stateDirectory
            )
            if case .incompatible = read.disposition {
                return .needsAttention
            }
            let records = read.records
            guard !records.isEmpty else {
                return .none
            }
            if case .legacy = read.disposition {
                if let legacy =
                    RunLogReader.completedLegacyReport(
                        in: records
                    ) {
                    return .previousReport(legacy)
                }
                return .needsAttention
            }
            if let lastIntent = records.last(where: { $0.intent != nil })?.intent,
               let completed = RunLogReader.completedReport(
                   in: records,
                   matching: lastIntent.run
               ) {
                return .previousReport(completed)
            }
            guard let report = InterruptedRunReconstructor.reconstruct(
                records: records,
                postflight: inspectCheckpoint
            ) else {
                return .needsAttention
            }
            return .previousReport(report)
        } catch let SecureStateError.systemCall(_, code) where code == ENOENT {
            return .none
        } catch {
            return .needsAttention
        }
    }

    private static func inspectCheckpoint(
        _ checkpoint: RepositoryCheckpoint
    ) -> InterruptedPostflight {
        do {
            let handle = try RepositoryHandle.open(checkpoint.repository)
            let current = try handle.readOnlyMainCommit()
            if let target = checkpoint.targetCommit, current == target {
                return .updated(target)
            }
            if current == checkpoint.beforeCommit {
                return .unchanged(current)
            }
            return .ambiguous(current)
        } catch {
            return .ambiguous(nil)
        }
    }
}
