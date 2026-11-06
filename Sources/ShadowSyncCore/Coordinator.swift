import Darwin
import Foundation

public struct CoordinatorConfiguration: Sendable {
    public let stateLocation: StateLocation
    public let trampolineExecutable: String?
    let governedRootRole: GovernedRootRole?
    let installationAdmission: (@Sendable () throws -> Void)?
    #if SHADOW_SYNC_TESTING
    // Existing fixture-only callers predate bound host-policy snapshots. Explicit
    // test roles still exercise the production digest check below.
    let usesUnboundTestingRole: Bool
    public let transportMapping: TransportMapping?
    public let seededDiagnostic: String?
    public let failAfterLoggedRecords: Int?
    public let fetchMutationsByRepositoryPath: [String: String]
    public let localTimeoutSeconds: TimeInterval
    public let fetchTimeoutSeconds: TimeInterval
    #endif

    public init(
        stateLocation: StateLocation,
        trampolineExecutable: String?,
        governedRootRole: GovernedRootRole? = nil
    ) {
        self.stateLocation = stateLocation
        self.trampolineExecutable = trampolineExecutable
        self.governedRootRole = governedRootRole
        #if SHADOW_SYNC_TESTING
        installationAdmission = nil
        usesUnboundTestingRole = false
        transportMapping = nil
        seededDiagnostic = nil
        failAfterLoggedRecords = nil
        fetchMutationsByRepositoryPath = [:]
        localTimeoutSeconds = 5
        fetchTimeoutSeconds = 120
        #endif
        #if !SHADOW_SYNC_TESTING
        installationAdmission = {
            _ = try InstalledStateAdmission.verifyRun(
                paths: try InstallationPaths.production(),
                launchAgent: SystemLaunchAgentController(),
                host: SystemInstalledHostController()
            )
        }
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        stateLocation: StateLocation,
        trampolineExecutable: String?,
        transportMapping: TransportMapping,
        seededDiagnostic: String? = nil,
        failAfterLoggedRecords: Int? = nil,
        fetchMutationsByRepositoryPath: [String: String] = [:],
        localTimeoutSeconds: TimeInterval = 5,
        fetchTimeoutSeconds: TimeInterval = 120,
        governedRootRole: GovernedRootRole? = nil
    ) {
        usesUnboundTestingRole = governedRootRole == nil
        self.governedRootRole = governedRootRole ?? .testing()
        self.stateLocation = stateLocation
        self.trampolineExecutable = trampolineExecutable
        self.installationAdmission = nil
        self.transportMapping = transportMapping
        self.seededDiagnostic = seededDiagnostic
        self.failAfterLoggedRecords = failAfterLoggedRecords
        self.fetchMutationsByRepositoryPath = fetchMutationsByRepositoryPath
        self.localTimeoutSeconds = localTimeoutSeconds
        self.fetchTimeoutSeconds = fetchTimeoutSeconds
    }
    #endif
}

private final class EventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let runID: String
    private let log: RunLogWriter
    private let cancellation: CancellationToken
    private let sink: @Sendable (RunEvent) -> Void
    private var sequence = 0
    #if SHADOW_SYNC_TESTING
    private let failAfterLoggedRecords: Int?
    private var loggedRecords = 0
    #endif

    #if SHADOW_SYNC_TESTING
    init(
        runID: String,
        log: RunLogWriter,
        cancellation: CancellationToken,
        failAfterLoggedRecords: Int?,
        sink: @escaping @Sendable (RunEvent) -> Void
    ) {
        self.runID = runID
        self.log = log
        self.cancellation = cancellation
        self.failAfterLoggedRecords = failAfterLoggedRecords
        self.sink = sink
    }
    #else
    init(
        runID: String,
        log: RunLogWriter,
        cancellation: CancellationToken,
        sink: @escaping @Sendable (RunEvent) -> Void
    ) {
        self.runID = runID
        self.log = log
        self.cancellation = cancellation
        self.sink = sink
    }
    #endif

    func emit(
        type: RunEventType,
        phase: RepositoryPhase? = nil,
        result: RepositoryResult? = nil,
        message: String? = nil,
        repositoryID: String? = nil
    ) throws {
        lock.lock()
        sequence += 1
        let event = RunEvent(
            run: runID,
            sequence: sequence,
            type: type,
            repositoryID: repositoryID ?? result?.repository.id,
            phase: phase,
            result: result,
            message: message.map(Redactor.sanitize)
        )
        do {
            #if SHADOW_SYNC_TESTING
            if let failAfterLoggedRecords,
               loggedRecords >= failAfterLoggedRecords {
                throw SecureStateError.systemCall("injected latest.log write", EIO)
            }
            #endif
            try log.append(type: "event", event: event)
            #if SHADOW_SYNC_TESTING
            loggedRecords += 1
            #endif
            lock.unlock()
            sink(event)
        } catch {
            lock.unlock()
            cancellation.cancel()
            throw error
        }
    }
}

enum V2OperationOrdering {
    static func executionOrder(
        _ operations: [PlannedOperation],
        governedRoot: GovernedRootRole
    ) -> [PlannedOperation] {
        operations.enumerated().sorted { left, right in
            let lhs = left.element
            let rhs = right.element
            let leftIsGovernedRoot =
                lhs.target.repository.id == governedRoot.repositoryID
            let rightIsGovernedRoot =
                rhs.target.repository.id == governedRoot.repositoryID
            if leftIsGovernedRoot != rightIsGovernedRoot {
                return !leftIsGovernedRoot
            }
            let repositoryOrder = lhs.target.repository.id
                .localizedStandardCompare(rhs.target.repository.id)
            if repositoryOrder != .orderedSame {
                return repositoryOrder == .orderedAscending
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    static func reportOrder(
        executionResults: [RepositoryResult],
        plannedOperations: [PlannedOperation]
    ) throws -> [RepositoryResult] {
        guard executionResults.count == plannedOperations.count,
              Set(plannedOperations.map(\.id)).count
                == plannedOperations.count else {
            throw GitSafetyError.unsafeRepository(
                "Repository operation report correlation is invalid"
            )
        }
        let plannedIDs = Set(plannedOperations.map(\.id))
        var resultByOperationID: [String: RepositoryResult] = [:]
        for result in executionResults {
            guard let operationID = result.operationID,
                  plannedIDs.contains(operationID),
                  resultByOperationID[operationID] == nil else {
                throw GitSafetyError.unsafeRepository(
                    "Repository operation report correlation is invalid"
                )
            }
            resultByOperationID[operationID] = result
        }
        return try plannedOperations.map { operation in
            guard let result = resultByOperationID[operation.id],
                  result.repository
                    == operation.target.canonicalClone.sourceSnapshot,
                  result.defaultBranch
                    == operation.target.resolvedDefault.name else {
                throw GitSafetyError.unsafeRepository(
                    "Repository operation report correlation is invalid"
                )
            }
            return result
        }
    }
}

public final class RunCoordinator: @unchecked Sendable {
    let configuration: CoordinatorConfiguration
    private let runner: DescriptorProcessRunner
    let account: EffectiveAccount

    public init(
        configuration: CoordinatorConfiguration,
        audit: CommandAudit? = nil,
        processObserver: (@Sendable (ProcessIdentity?) -> Bool)? = nil,
        account: EffectiveAccount
    ) {
        self.configuration = configuration
        runner = DescriptorProcessRunner(
            audit: audit,
            processObserver: processObserver
        )
        self.account = account
    }

    public func run(
        runID: String,
        candidate: RepositoryCandidate,
        cancellation: CancellationToken,
        eventSink: @escaping @Sendable (RunEvent) -> Void
    ) throws -> RunReport {
        try run(
            runID: runID,
            candidates: [candidate],
            cancellation: cancellation,
            eventSink: eventSink
        )
    }

    public func run(
        runID: String,
        operations: [PlannedOperation],
        cancellation: CancellationToken,
        eventSink: @escaping @Sendable (RunEvent) -> Void
    ) throws -> RunReport {
        guard RunIdentity.isValid(runID),
              !operations.isEmpty,
              Set(operations.map(\.id)).count == operations.count,
              Set(operations.map {
                  $0.target.repository.id
              }).count == operations.count,
              operations.allSatisfy(\.isSelectable) else {
            throw GitSafetyError.unsafeRepository(
                "Repository operation selection is invalid"
            )
        }
        guard let governedRootRole = configuration.governedRootRole else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        var requirePolicyBinding = true
        #if SHADOW_SYNC_TESTING
        requirePolicyBinding = !configuration.usesUnboundTestingRole
        #endif
        guard !requirePolicyBinding || operations.allSatisfy({
            $0.target.canonicalClone.sourceSnapshot.policyAdmissionSHA256
                == governedRootRole.policyDigest
        }) else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        let ordered = V2OperationOrdering.executionOrder(
            operations, governedRoot: governedRootRole)
        let candidates = ordered.map {
            $0.target.canonicalClone.sourceSnapshot
        }
        guard Set(candidates.map(\.path)).count == candidates.count else {
            throw GitSafetyError.unsafeRepository(
                "Repository operation canonical roots are duplicated"
            )
        }
        let authority = try RunAuthority.acquireRun(
            at: configuration.stateLocation
        )
        defer { authority.release() }
        try configuration.installationAdmission?()
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let startedAt = WallClock.timestamp()
        let runStarted = MonotonicInstant.now()
        let log = try RunLogWriter(
            authority: authority,
            runID: runID
        )
        try log.append(
            type: "run_intent",
            intent: RunIntent(
                run: runID,
                startedAt: startedAt,
                candidates: candidates,
                repositoryModel: "v2"
            )
        )
        #if SHADOW_SYNC_TESTING
        let emitter = EventEmitter(
            runID: runID,
            log: log,
            cancellation: cancellation,
            failAfterLoggedRecords:
                configuration.failAfterLoggedRecords,
            sink: eventSink
        )
        #else
        let emitter = EventEmitter(
            runID: runID,
            log: log,
            cancellation: cancellation,
            sink: eventSink
        )
        #endif
        try emitter.emit(
            type: .runStarted,
            message: "\(ordered.count) repository operation(s) were admitted."
        )
        #if SHADOW_SYNC_TESTING
        if let seededDiagnostic = configuration.seededDiagnostic {
            try emitter.emit(
                type: .diagnostic,
                message: seededDiagnostic
            )
        }
        let transactionConfiguration: GitTransactionConfiguration
        if let mapping = configuration.transportMapping {
            transactionConfiguration = GitTransactionConfiguration(
                trampolineExecutable:
                    configuration.trampolineExecutable,
                operationLeaseDescriptor: lease,
                transportMapping: mapping,
                fetchMutationsByRepositoryPath:
                    configuration.fetchMutationsByRepositoryPath,
                localTimeoutSeconds:
                    configuration.localTimeoutSeconds,
                fetchTimeoutSeconds:
                    configuration.fetchTimeoutSeconds
            )
        } else {
            transactionConfiguration = GitTransactionConfiguration(
                trampolineExecutable:
                    configuration.trampolineExecutable,
                operationLeaseDescriptor: lease
            )
        }
        #else
        let transactionConfiguration = GitTransactionConfiguration(
            trampolineExecutable: configuration.trampolineExecutable,
            operationLeaseDescriptor: lease
        )
        #endif
        let transaction = FastForwardTransactionV2(
            runner: runner,
            configuration: transactionConfiguration,
            account: account
        )
        let maintenanceTransaction =
            RepositoryMaintenanceTransaction(
                runner: runner,
                configuration: transactionConfiguration,
                account: account
            )
        var results: [RepositoryResult] = []
        var stoppedRepositories: Set<String> = []
        for operation in ordered {
            let candidate =
                operation.target.canonicalClone.sourceSnapshot
            let repositoryResult: RepositoryResult
            if stoppedRepositories.contains(
                operation.target.repository.id
            ) {
                let timestamp = WallClock.timestamp()
                repositoryResult = RepositoryResult(
                    repository: candidate,
                    operationID: operation.id,
                    defaultBranch:
                        operation.target.resolvedDefault.name,
                    code: .needsAttention,
                    fetched: false,
                    mainUpdated: false,
                    beforeCommit: nil,
                    targetCommit: nil,
                    afterCommit: nil,
                    startedAt: timestamp,
                    endedAt: timestamp,
                    durationMilliseconds: 0,
                    explanation:
                        "This operation was not started because an earlier operation for the same repository did not complete successfully.",
                    technicalDetail:
                        "ordered repository sequence stopped after failed revalidation or execution"
                )
            } else if cancellation.isCancelled {
                let timestamp = WallClock.timestamp()
                repositoryResult = RepositoryResult(
                    repository: candidate,
                    operationID: operation.id,
                    defaultBranch:
                        operation.target.resolvedDefault.name,
                    code: .cancelledPending,
                    fetched: false,
                    mainUpdated: false,
                    beforeCommit: nil,
                    targetCommit: nil,
                    afterCommit: nil,
                    startedAt: timestamp,
                    endedAt: timestamp,
                    durationMilliseconds: 0,
                    explanation:
                        "The run was cancelled before this repository operation started.",
                    technicalDetail:
                        "operation admission remained pending"
                )
            } else {
                let phaseSink: @Sendable (
                    RepositoryPhase
                ) throws -> Void = { phase in
                    try emitter.emit(
                        type: .repositoryPhase,
                        phase: phase,
                        repositoryID: candidate.path
                    )
                }
                let checkpointSink: @Sendable (
                    RepositoryCheckpoint
                ) throws -> Void = { checkpoint in
                    try log.append(
                        type: "repository_checkpoint",
                        checkpoint: checkpoint
                    )
                }
                if operation.kind == .fastForward {
                    repositoryResult = transaction.execute(
                        operation: operation,
                        cancellation: cancellation,
                        phase: phaseSink,
                        checkpoint: checkpointSink
                    )
                } else {
                    repositoryResult =
                        maintenanceTransaction.execute(
                            operation: operation,
                            cancellation: cancellation,
                            phase: phaseSink,
                            checkpoint: checkpointSink
                        )
                }
            }
            results.append(repositoryResult)
            if repositoryResult.resultClass != .success {
                stoppedRepositories.insert(
                    operation.target.repository.id
                )
            }
            try emitter.emit(
                type: .repositoryResult,
                phase: .complete,
                result: repositoryResult,
                repositoryID: candidate.path
            )
        }
        let reportResults = try V2OperationOrdering.reportOrder(
            executionResults: results,
            plannedOperations: operations
        )
        let report = RunReport(
            run: runID,
            startedAt: startedAt,
            endedAt: WallClock.timestamp(),
            durationMilliseconds:
                MonotonicInstant.now().milliseconds(
                    since: runStarted
                ),
            cancelled: cancellation.isCancelled,
            results: reportResults,
            repositoryModel: "v2"
        )
        do {
            if cancellation.isCancelled {
                try log.append(type: "control", data: "cancel")
            }
            try log.append(type: "run_finished", report: report)
            try log.append(type: "worker_exit", data: "completed")
        } catch {
            cancellation.cancel()
            throw error
        }
        try emitter.emit(
            type: .runFinished,
            message: report.summary
        )
        do {
            try log.flush()
        } catch {
            cancellation.cancel()
            throw error
        }
        return report
    }

    public func run(
        runID: String,
        candidates: [RepositoryCandidate],
        cancellation: CancellationToken,
        eventSink: @escaping @Sendable (RunEvent) -> Void
    ) throws -> RunReport {
        guard RunIdentity.isValid(runID) else {
            throw GitSafetyError.unsafeRepository("run identity is invalid")
        }
        guard !candidates.isEmpty,
              Set(candidates.map(\.path)).count == candidates.count else {
            throw GitSafetyError.unsafeRepository("repository selection is invalid")
        }
        let authority = try RunAuthority.acquireRun(at: configuration.stateLocation)
        defer { authority.release() }
        try configuration.installationAdmission?()
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let startedAt = WallClock.timestamp()
        let runStarted = MonotonicInstant.now()
        #if SHADOW_SYNC_TESTING
        let repositoryModel: String? = "v2"
        #else
        let repositoryModel: String? = nil
        #endif
        let log = try RunLogWriter(authority: authority, runID: runID)
        try log.append(
            type: "run_intent",
            intent: RunIntent(
                run: runID,
                startedAt: startedAt,
                candidates: candidates,
                repositoryModel: repositoryModel
            )
        )
        #if SHADOW_SYNC_TESTING
        let emitter = EventEmitter(
            runID: runID,
            log: log,
            cancellation: cancellation,
            failAfterLoggedRecords: configuration.failAfterLoggedRecords,
            sink: eventSink
        )
        #else
        let emitter = EventEmitter(
            runID: runID,
            log: log,
            cancellation: cancellation,
            sink: eventSink
        )
        #endif

        try emitter.emit(
            type: .runStarted,
            message: "\(candidates.count) repositories were admitted."
        )
        #if SHADOW_SYNC_TESTING
        if let seededDiagnostic = configuration.seededDiagnostic {
            try emitter.emit(type: .diagnostic, message: seededDiagnostic)
        }
        #endif
        #if SHADOW_SYNC_TESTING
        let transactionConfiguration: GitTransactionConfiguration
        if let mapping = configuration.transportMapping {
            transactionConfiguration = GitTransactionConfiguration(
                trampolineExecutable: configuration.trampolineExecutable,
                operationLeaseDescriptor: lease,
                transportMapping: mapping,
                fetchMutationsByRepositoryPath: configuration.fetchMutationsByRepositoryPath,
                localTimeoutSeconds: configuration.localTimeoutSeconds,
                fetchTimeoutSeconds: configuration.fetchTimeoutSeconds
            )
        } else {
            transactionConfiguration = GitTransactionConfiguration(
                trampolineExecutable: configuration.trampolineExecutable,
                operationLeaseDescriptor: lease
            )
        }
        #else
        let transactionConfiguration = GitTransactionConfiguration(
            trampolineExecutable: configuration.trampolineExecutable,
            operationLeaseDescriptor: lease
        )
        #endif
        let transaction = GitTransaction(
            runner: runner,
            configuration: transactionConfiguration,
            account: account
        )
        var results: [RepositoryResult] = []
        for candidate in candidates {
            let repositoryResult: RepositoryResult
            if cancellation.isCancelled {
                let timestamp = WallClock.timestamp()
                repositoryResult = RepositoryResult(
                    repository: candidate,
                    code: .cancelledPending,
                    fetched: false,
                    mainUpdated: false,
                    beforeCommit: nil,
                    targetCommit: nil,
                    afterCommit: nil,
                    startedAt: timestamp,
                    endedAt: timestamp,
                    durationMilliseconds: 0,
                    explanation: "The run was cancelled before this repository started.",
                    technicalDetail: "repository admission remained pending"
                )
            } else {
                repositoryResult = transaction.execute(
                    candidate: candidate,
                    cancellation: cancellation
                ) { phase in
                    try emitter.emit(
                        type: .repositoryPhase,
                        phase: phase,
                        repositoryID: candidate.path
                    )
                } checkpoint: { checkpoint in
                    try log.append(
                        type: "repository_checkpoint",
                        checkpoint: checkpoint
                    )
                }
            }
            results.append(repositoryResult)
            try emitter.emit(
                type: .repositoryResult,
                phase: .complete,
                result: repositoryResult,
                repositoryID: candidate.path
            )
        }
        let report = RunReport(
            run: runID,
            startedAt: startedAt,
            endedAt: WallClock.timestamp(),
            durationMilliseconds: MonotonicInstant.now().milliseconds(since: runStarted),
            cancelled: cancellation.isCancelled,
            results: results,
            repositoryModel: repositoryModel
        )
        do {
            if cancellation.isCancelled {
                try log.append(type: "control", data: "cancel")
            }
            try log.append(type: "run_finished", report: report)
            try log.append(type: "worker_exit", data: "completed")
        } catch {
            cancellation.cancel()
            throw error
        }
        try emitter.emit(type: .runFinished, message: report.summary)
        do {
            try log.flush()
        } catch {
            cancellation.cancel()
            throw error
        }
        return report
    }
}

public final class CancellationChannelMonitor: @unchecked Sendable {
    private let descriptor: OwnedFileDescriptor
    private let token: CancellationToken
    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?

    public init(descriptor: Int32, token: CancellationToken) {
        self.descriptor = OwnedFileDescriptor(descriptor)
        self.token = token
    }

    public func start() {
        lock.lock()
        guard thread == nil else {
            lock.unlock()
            return
        }
        let thread = Thread { [weak self] in
            self?.monitor()
        }
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        descriptor.closeNow()
    }

    private func monitor() {
        do {
            let message = try JSONLineChannel.readOne(
                WorkerControlMessage.self,
                descriptor: descriptor.value
            )
            lock.lock()
            let shouldStop = stopped
            lock.unlock()
            if !shouldStop,
               message.schema == WorkerControlMessage.schemaName,
               message.command == .cancel {
                token.cancel()
            }
        } catch {
            lock.lock()
            let shouldCancel = !stopped
            lock.unlock()
            if shouldCancel {
                token.cancel()
            }
        }
    }
}

public struct WorkerControlMessage: Codable, Equatable, Sendable {
    public static let schemaName = "shadow-sync-control/v1"

    public enum Command: String, Codable, Sendable {
        case cancel
    }

    public let schema: String
    public let command: Command

    public init(command: Command) {
        schema = Self.schemaName
        self.command = command
    }
}

public enum JSONLineChannel {
    public static func write<T: Encodable>(_ value: T, descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SecureStateError.systemCall("write event channel", errno)
                }
                if count == 0 {
                    throw SecureStateError.systemCall("write event channel", EPIPE)
                }
                offset += count
            }
        }
    }

    public static func readOne<T: Decodable>(
        _ type: T.Type,
        descriptor: Int32,
        maximumBytes: Int = 1_048_576
    ) throws -> T {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximumBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw SecureStateError.systemCall("read channel", errno)
            }
            if count == 0 || byte == 0x0A {
                break
            }
            data.append(byte)
        }
        guard !data.isEmpty, data.count < maximumBytes else {
            throw SecureStateError.unsafePath("channel frame")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
