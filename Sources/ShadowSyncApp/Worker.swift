import Darwin
import ShadowSyncCatalog
import ShadowSyncCore
import Foundation

struct WorkerRequest: Codable, Sendable {
    let candidates: [RepositoryCandidate]
    let operations: [PlannedOperation]
    let runID: String
    let workerGeneration: String

    #if SHADOW_SYNC_TESTING
    enum OwnershipFault: String, Codable, Sendable {
        case ignoreControl
        case closedControl
        case exitImmediately
        case missingHandshake
    }

    let isolatedRoot: String
    let transportMapping: TransportMapping
    let seededDiagnostic: String?
    let failAfterLoggedRecords: Int?
    let ownershipFault: OwnershipFault?

    init(
        candidate: RepositoryCandidate,
        runID: String,
        workerGeneration: String = RunIdentity.make(),
        isolatedRoot: String,
        transportMapping: TransportMapping,
        seededDiagnostic: String? = nil,
        failAfterLoggedRecords: Int? = nil,
        ownershipFault: OwnershipFault? = nil
    ) {
        self.candidates = [candidate]
        self.operations = []
        self.runID = runID
        self.workerGeneration = workerGeneration
        self.isolatedRoot = isolatedRoot
        self.transportMapping = transportMapping
        self.seededDiagnostic = seededDiagnostic
        self.failAfterLoggedRecords = failAfterLoggedRecords
        self.ownershipFault = ownershipFault
    }

    init(
        operation: PlannedOperation,
        runID: String,
        workerGeneration: String = RunIdentity.make(),
        isolatedRoot: String,
        transportMapping: TransportMapping,
        seededDiagnostic: String? = nil,
        failAfterLoggedRecords: Int? = nil,
        ownershipFault: OwnershipFault? = nil
    ) {
        candidates = [
            operation.target.canonicalClone.sourceSnapshot,
        ]
        operations = [operation]
        self.runID = runID
        self.workerGeneration = workerGeneration
        self.isolatedRoot = isolatedRoot
        self.transportMapping = transportMapping
        self.seededDiagnostic = seededDiagnostic
        self.failAfterLoggedRecords = failAfterLoggedRecords
        self.ownershipFault = ownershipFault
    }
    #else
    init(
        authorizedOperations: [AuthorizedOperationEnvelope],
        runID: String,
        workerGeneration: String = RunIdentity.make()
    ) throws {
        let operations = authorizedOperations.map(\.operation)
        guard !authorizedOperations.isEmpty,
              Set(authorizedOperations.map {
                  $0.scope.selectionGeneration
              }).count == 1,
              Set(authorizedOperations.flatMap {
                  $0.scope.repositoryIDs
              }) == Set(operations.map {
                  $0.target.repository.id
              }) else {
            throw GitSafetyError.unsafeRepository(
                "worker payload lacks one verified selected generation"
            )
        }
        self.operations = operations
        candidates = operations.map {
            $0.target.canonicalClone.sourceSnapshot
        }
        self.runID = runID
        self.workerGeneration = workerGeneration
    }
    #endif

    static func admitsPayload(
        _ candidates: [RepositoryCandidate]
    ) -> Bool {
        !candidates.isEmpty
            && Set(candidates.map(\.path)).count == candidates.count
            && candidates.allSatisfy(\.isEligible)
            && candidates.allSatisfy(\.hasValidatedOriginIdentity)
            && RepositoryOperatorPresentation.canConfirm(candidates)
    }

    static func admitsOperations(
        _ operations: [PlannedOperation]
    ) -> Bool {
        !operations.isEmpty
            && Set(operations.map(\.id)).count == operations.count
            && operations.allSatisfy(\.isSelectable)
    }
}

struct WorkerWireMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ownership
        case childOwnership
        case childReleased
        case repositoryCommand
        case event
        case completion
        case failure
    }

    var repositoryCommand: RepositoryCommandObservation? = nil
    let kind: Kind
    let event: RunEvent?
    let report: RunReport?
    let error: String?
    let workerPID: Int32?
    let workerIdentity: ProcessIdentity?
    let childIdentity: ProcessIdentity?
    let runID: String?

    static func event(_ event: RunEvent) -> WorkerWireMessage {
        WorkerWireMessage(
            kind: .event,
            event: event,
            report: nil,
            error: nil,
            workerPID: nil,
            workerIdentity: nil,
            childIdentity: nil,
            runID: event.run
        )
    }

    static func ownership(
        _ identity: ProcessIdentity,
        runID: String
    ) -> WorkerWireMessage {
        WorkerWireMessage(
            kind: .ownership,
            event: nil,
            report: nil,
            error: nil,
            workerPID: identity.processID,
            workerIdentity: identity,
            childIdentity: nil,
            runID: runID
        )
    }

    static func childOwnership(_ identity: ProcessIdentity) -> WorkerWireMessage {
        WorkerWireMessage(
            kind: .childOwnership,
            event: nil,
            report: nil,
            error: nil,
            workerPID: nil,
            workerIdentity: nil,
            childIdentity: identity,
            runID: nil
        )
    }

    static func repositoryCommand(_ observation: RepositoryCommandObservation) -> WorkerWireMessage {
        var message = WorkerWireMessage(kind: .repositoryCommand, event: nil, report: nil, error: nil,
            workerPID: nil, workerIdentity: nil, childIdentity: nil, runID: nil)
        message.repositoryCommand = observation
        return message
    }

    static func childReleased() -> WorkerWireMessage {
        WorkerWireMessage(
            kind: .childReleased,
            event: nil,
            report: nil,
            error: nil,
            workerPID: nil,
            workerIdentity: nil,
            childIdentity: nil,
            runID: nil
        )
    }

    static func completion(_ report: RunReport) -> WorkerWireMessage {
        WorkerWireMessage(
            kind: .completion,
            event: nil,
            report: report,
            error: nil,
            workerPID: getpid(),
            workerIdentity: nil,
            childIdentity: nil,
            runID: report.run
        )
    }

    static func failure(_ error: Error) -> WorkerWireMessage {
        WorkerWireMessage(
            kind: .failure,
            event: nil,
            report: nil,
            error: Redactor.sanitize(String(describing: error)),
            workerPID: getpid(),
            workerIdentity: nil,
            childIdentity: nil,
            runID: nil
        )
    }
}

enum WorkerMain {
    static let mode = "--shadow-sync-worker"
    static let requestFD: Int32 = 3
    static let eventFD: Int32 = 4
    static let controlFD: Int32 = 5
    static let startGateFD: Int32 = 6

    static func dispatch(arguments: [String], executablePath: String) -> Int32? {
        guard arguments.count == 2, arguments[1] == mode else {
            return nil
        }
        signal(SIGPIPE, SIG_IGN)
        do {
            var admission: UInt8 = 0
            guard Darwin.read(startGateFD, &admission, 1) == 1,
                  admission == UInt8(ascii: "G") else {
                return 1
            }
            close(startGateFD)
            let request = try JSONLineChannel.readOne(
                WorkerRequest.self,
                descriptor: requestFD
            )
            guard RunIdentity.isValid(request.runID) else {
                throw GitSafetyError.unsafeRepository("worker request has an invalid run identity")
            }
            guard (
                request.operations.isEmpty
                    ? WorkerRequest.admitsPayload(request.candidates)
                    : WorkerRequest.admitsOperations(request.operations)
            ) else {
                throw GitSafetyError.unsafeRepository(
                    "worker request contains a blocked repository"
                )
            }
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: request.workerGeneration,
                expectedExecutablePath: executablePath
            )
            guard identity.processGroupID == identity.processID else {
                throw ProcessOwnershipError.identityMismatch
            }
            #if SHADOW_SYNC_TESTING
            if let fault = request.ownershipFault {
                if fault == .missingHandshake {
                    try JSONLineChannel.write(
                        WorkerWireMessage.event(RunEvent(
                            run: request.runID,
                            sequence: 1,
                            type: .runStarted
                        )),
                        descriptor: eventFD
                    )
                } else {
                    let mismatched = try ProcessIdentity.capture(
                        processID: getpid(),
                        generation: RunIdentity.make(),
                        expectedExecutablePath: executablePath
                    )
                    try JSONLineChannel.write(
                        WorkerWireMessage.ownership(
                            mismatched,
                            runID: request.runID
                        ),
                        descriptor: eventFD
                    )
                }
                switch fault {
                case .ignoreControl:
                    signal(SIGTERM, SIG_IGN)
                    while true { pause() }
                case .closedControl:
                    close(controlFD)
                    while true { pause() }
                case .exitImmediately:
                    return 0
                case .missingHandshake:
                    signal(SIGTERM, SIG_IGN)
                    while true { pause() }
                }
            }
            #endif
            try JSONLineChannel.write(
                WorkerWireMessage.ownership(identity, runID: request.runID),
                descriptor: eventFD
            )
            let token = CancellationToken()
            let monitor = CancellationChannelMonitor(descriptor: controlFD, token: token)
            monitor.start()
            defer { monitor.stop() }

            let stateLocation: StateLocation
            let account: EffectiveAccount
            let coordinatorConfiguration: CoordinatorConfiguration
            let admittedCandidates: [RepositoryCandidate]
            let admittedOperations: [PlannedOperation]
            #if SHADOW_SYNC_TESTING
            guard request.candidates.count == 1,
                  let candidate = request.candidates.first else {
                throw GitSafetyError.unsafeRepository(
                    "testing worker request must contain one isolated repository"
                )
            }
            let isolatedRoot = try TestIsolation.validateRoot(request.isolatedRoot)
            try TestIsolation.validateContainedDirectory(
                candidate.path,
                root: isolatedRoot
            )
            try TestIsolation.validateContainedDirectory(
                request.transportMapping.localRepositoryPath,
                root: isolatedRoot
            )
            let requestIdentity = GitHubIdentity.parse(candidate.rawOrigin)
            let mappingIdentity = GitHubIdentity.parse(request.transportMapping.logicalURL)
            guard request.transportMapping.containmentRoot == isolatedRoot,
                  candidate.rawOrigin == request.transportMapping.logicalURL,
                  candidate.originIdentity == requestIdentity,
                  requestIdentity?.canonicalName == candidate.id.lowercased(),
                  mappingIdentity?.canonicalName == requestIdentity?.canonicalName else {
                throw GitSafetyError.unsafeRepository(
                    "testing worker request is not isolated"
                )
            }
            stateLocation = try StateLocation.isolated(root: isolatedRoot)
            account = try EffectiveAccount.isolated(
                homeDirectory: URL(fileURLWithPath: isolatedRoot)
                    .appendingPathComponent("home", isDirectory: true).path
            )
            coordinatorConfiguration = CoordinatorConfiguration(
                stateLocation: stateLocation,
                trampolineExecutable: executablePath,
                transportMapping: request.transportMapping,
                seededDiagnostic: request.seededDiagnostic,
                failAfterLoggedRecords: request.failAfterLoggedRecords
            )
            admittedCandidates = request.candidates
            admittedOperations = request.operations
            #else
            stateLocation = try StateLocation.production()
            account = try EffectiveAccount.current()
            let installedAdmission = try LifecycleAdmissionAuthority.acquire(
                at: stateLocation
            )
            defer { installedAdmission.release() }
            _ = try InstalledStateAdmission.verifyRun(
                paths: try InstallationPaths.production(),
                launchAgent: SystemLaunchAgentController(),
                host: SystemInstalledHostController()
            )
            let governedRoot = account.homeDirectory
            let operationEntries = try request.operations.map {
                operation
                    -> RepositorySelectionPreferenceEntry in
                let candidate =
                    operation.target.canonicalClone.sourceSnapshot
                guard candidate.path.hasPrefix(governedRoot + "/") else {
                    throw GitSafetyError.unsafeRepository(
                        "worker operation left the governed root"
                    )
                }
                let relative = String(
                    candidate.path.dropFirst(governedRoot.count + 1)
                )
                return try RepositorySelectionPreferenceEntry(
                    repositoryID: candidate.id,
                    locator: RepositorySelectionLocator(
                        governedRoot: "~",
                        components: relative.split(separator: "/")
                            .map(String.init)
                    )
                )
            }
            let groupedEntries = Dictionary(
                grouping: operationEntries,
                by: \.repositoryID
            )
            let entries = try groupedEntries.keys.sorted().map {
                repositoryID in
                guard let matches = groupedEntries[repositoryID],
                      Set(matches).count == 1,
                      let entry = matches.first else {
                    throw GitSafetyError.unsafeRepository(
                        "worker operations disagree on selected locator"
                    )
                }
                return entry
            }
            let selectedScope = try SelectedRepositoryScopeBinder.withProductionReadPhase(cancellation: token) { binder in
                let currentCatalog = try binder.processFreeCatalog(
                    preferences: nil,
                    generation: 1
                )
                guard currentCatalog.isComplete else {
                    if currentCatalog.degradedReason == .cleanupPending { throw SelectedRepositoryScopeError.cleanupPending }
                    throw GitSafetyError.unsafeRepository(
                        "worker could not bind a complete current catalog"
                    )
                }
                let intent = try RepositorySelectionIntent(
                    catalog: currentCatalog.catalog,
                    entries: entries
                )
                return try binder.bind(intent: intent)
            }
            let inventory = try RepositoryInventoryDiscovery(
                executablePath: executablePath
            ).discoverInventory(scope: selectedScope)
            let verified =
                try SelectedRepositoryHydrator
                    .verifyFreshInventory(
                        scope: selectedScope,
                        inventory: inventory
                    )
            guard let refreshed =
                RepositoryInventorySelection.admit(
                    requests: request.operations,
                    refreshed: inventory
                ),
                  refreshed.allSatisfy({
                      (try? AuthorizedOperationEnvelope(
                          operation: $0,
                          capability: verified.capability
                      )) != nil
                  }) else {
                throw GitSafetyError.unsafeRepository(
                    "production worker selection no longer matches discovery"
                )
            }
            admittedOperations = refreshed
            admittedCandidates = refreshed.map {
                $0.target.canonicalClone.sourceSnapshot
            }
            coordinatorConfiguration = CoordinatorConfiguration(
                stateLocation: stateLocation,
                trampolineExecutable: executablePath,
                governedRootRole: try selectedScope.requireGovernedRootRole()
            )
            #endif

            let coordinator = RunCoordinator(
                configuration: coordinatorConfiguration,
                processObserver: { identity in
                    do {
                        try JSONLineChannel.write(
                            identity.map(WorkerWireMessage.childOwnership)
                                ?? WorkerWireMessage.childReleased(),
                            descriptor: eventFD
                        )
                        return true
                    } catch {
                        return false
                    }
                },
                repositoryObserver: { observation in
                    do {
                        try JSONLineChannel.write(WorkerWireMessage.repositoryCommand(observation), descriptor: eventFD)
                        return true
                    } catch { return false }
                },
                account: account
            )
            let report: RunReport
            if admittedOperations.isEmpty {
                report = try coordinator.run(
                    runID: request.runID,
                    candidates: admittedCandidates,
                    cancellation: token
                ) { event in
                    do {
                        try JSONLineChannel.write(
                            WorkerWireMessage.event(event),
                            descriptor: eventFD
                        )
                    } catch {
                        token.cancel()
                    }
                }
            } else {
                report = try coordinator.run(
                    runID: request.runID,
                    operations: admittedOperations,
                    cancellation: token
                ) { event in
                    do {
                        try JSONLineChannel.write(
                            WorkerWireMessage.event(event),
                            descriptor: eventFD
                        )
                    } catch {
                        token.cancel()
                    }
                }
            }
            if report.hasCleanupPending { throw SelectedRepositoryScopeError.cleanupPending }
            try JSONLineChannel.write(
                WorkerWireMessage.completion(report),
                descriptor: eventFD
            )
            return 0
        } catch {
            try? JSONLineChannel.write(
                WorkerWireMessage.failure(error),
                descriptor: eventFD
            )
            return 1
        }
    }
}

enum OwnershipProtocolEvidence: Equatable, Sendable {
    case complete
    case incomplete
}

enum RecordedChildDrainEvidence: Equatable, Sendable {
    case noneRecorded
    case verified
    case unverified
}

enum RunAuthorityEvidence: Equatable, Sendable {
    case released
    case held
    case unavailable
    case error
}

struct WorkerPostReapEvidence: Equatable, Sendable {
    let workerReaped: Bool
    let ownershipProtocol: OwnershipProtocolEvidence
    let recordedChildDrain: RecordedChildDrainEvidence
    let runAuthority: RunAuthorityEvidence

    var childDrainVerified: Bool {
        switch recordedChildDrain {
        case .verified:
            return true
        case .noneRecorded:
            return ownershipProtocol == .complete && runAuthority == .released
        case .unverified:
            return false
        }
    }

    var authorityReleased: Bool {
        runAuthority == .released
    }
}

final class WorkerSession: @unchecked Sendable {
    private struct StopAttempt {
        let generation: String
        let actionDeadline: MonotonicDeadline
        let publicationDeadline: MonotonicDeadline
    }

    private enum StopExecutionState {
        case idle
        case running(StopAttempt)
        case publicationOverdue(StopAttempt)
        case completed(String, WorkerStopOutcome)
    }

    private static func makeStopAttempt(
        actionTimeout: TimeInterval,
        publicationGrace: TimeInterval
    ) -> StopAttempt {
        let boundedActionTimeout = max(0, actionTimeout)
        return StopAttempt(
            generation: RunIdentity.make(),
            actionDeadline: MonotonicDeadline(
                seconds: boundedActionTimeout
            ),
            publicationDeadline: MonotonicDeadline(
                seconds: boundedActionTimeout + max(0, publicationGrace)
            )
        )
    }

    #if SHADOW_SYNC_TESTING
    struct StopMetrics: Equatable {
        let executionCount: Int
        let cancellationCount: Int
        let termCount: Int
        let killCount: Int
    }
    #endif

    let processID: pid_t
    let identity: ProcessIdentity
    private let controlWrite: Int32
    private let lock = NSLock()
    private var closed = false
    private var activeChild: ProcessIdentity?
    private var repositoryCommands: Set<String> = []
    private let exitCondition = NSCondition()
    private var exitStatus: Int32?
    private var exitOwnershipFailed = false
    let owner: OwnedDirectChild?
    private var exitChildDrainVerified = false
    private let stateLocation: StateLocation?
    private let expectedRunID: String?
    private var ownershipProtocolComplete: Bool
    private let stopExecutionCondition = NSCondition()
    private var stopExecutionState = StopExecutionState.idle
    #if SHADOW_SYNC_TESTING
    private var stopExecutionCount = 0
    private var stopCancellationCount = 0
    private var stopTermCount = 0
    private var stopKillCount = 0
    #endif

    private init(
        processID: pid_t,
        controlWrite: Int32,
        identity: ProcessIdentity,
        owner: OwnedDirectChild?,
        stateLocation: StateLocation? = nil,
        expectedRunID: String? = nil,
        ownershipProtocolComplete: Bool = false
    ) {
        self.processID = processID
        self.owner = owner
        self.controlWrite = controlWrite
        self.identity = identity
        self.stateLocation = stateLocation
        self.expectedRunID = expectedRunID
        self.ownershipProtocolComplete = ownershipProtocolComplete
    }

    // Production sessions can only be created with the spawn caller's owner.
    convenience init(
        owner: OwnedDirectChild,
        controlWrite: Int32,
        stateLocation: StateLocation? = nil,
        expectedRunID: String? = nil
    ) {
        self.init(processID: owner.identity.processID, controlWrite: controlWrite,
                  identity: owner.identity, owner: owner, stateLocation: stateLocation,
                  expectedRunID: expectedRunID)
    }

    #if SHADOW_SYNC_TESTING
    // Synthetic presentation fixtures carry observation only, never signal authority.
    convenience init(
        processID: pid_t, controlWrite: Int32, identity: ProcessIdentity,
        stateLocation: StateLocation? = nil, expectedRunID: String? = nil,
        ownershipProtocolComplete: Bool = false
    ) {
        self.init(processID: processID, controlWrite: controlWrite, identity: identity,
                  owner: nil, stateLocation: stateLocation, expectedRunID: expectedRunID,
                  ownershipProtocolComplete: ownershipProtocolComplete)
    }

    convenience init(controlWrite: Int32, testingFixture: NativeFixtureProcess) {
        self.init(owner: testingFixture.owner, controlWrite: controlWrite)
    }
    #endif

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        let delivered: Bool
        do {
            try JSONLineChannel.write(
                WorkerControlMessage(command: .cancel),
                descriptor: controlWrite
            )
            delivered = true
        } catch {
            delivered = false
        }
        close(controlWrite)
        closed = true
        lock.unlock()
        return delivered
    }

    func closeControl() {
        lock.lock()
        if !closed {
            close(controlWrite)
            closed = true
        }
        lock.unlock()
    }

    func recordRepositoryCommand(_ event: RepositoryCommandObservation) -> Bool {
        guard RunIdentity.isValid(event.requestID) else { return false }
        lock.lock(); defer { lock.unlock() }
        switch event.phase {
        case .admission: return repositoryCommands.insert(event.requestID).inserted
        case .retired: return repositoryCommands.remove(event.requestID) != nil
        }
    }

    func recordChild(_ identity: ProcessIdentity?) {
        lock.lock()
        activeChild = identity
        lock.unlock()
    }

    func markOwnershipProtocolComplete(
        workerIdentity: ProcessIdentity,
        runID: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let expectedRunID,
              runID == expectedRunID,
              workerIdentity == identity,
              workerIdentity.isCurrent(
                  expectedGeneration: identity.generation
              ) else {
            return false
        }
        ownershipProtocolComplete = true
        return true
    }

    func ownershipProtocolIsComplete(
        workerIdentity: ProcessIdentity,
        runID: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownershipProtocolComplete
            && expectedRunID == runID
            && workerIdentity == identity
    }

    private func drainRecordedChildAfterWorkerLoss() -> Bool? {
        lock.lock()
        let child = activeChild
        lock.unlock()
        guard let child else { return nil }
        guard child.isCurrent(expectedGeneration: child.generation),
              OwnedProcessSignal.send(
                  SIGTERM,
                  to: child,
                  expectedGeneration: child.generation
              ) else {
            return !child.isCurrent(expectedGeneration: child.generation)
        }
        if waitUntilGone(child, timeout: ProcessOwnershipTiming.termGrace) {
            recordChild(nil)
            return true
        }
        guard child.isCurrent(expectedGeneration: child.generation),
              OwnedProcessSignal.send(
                  SIGKILL,
                  to: child,
                  expectedGeneration: child.generation
              ) else {
            return !child.isCurrent(expectedGeneration: child.generation)
        }
        let drained = waitUntilGone(
            child,
            timeout: ProcessOwnershipTiming.postKillReap
        )
        if drained {
            recordChild(nil)
        }
        return drained
    }

    func verifySafetyAfterWorkerReap() -> WorkerPostReapEvidence {
        if let owner, case .reaped = owner.observation {
            // The retained owner proves the worker's exact terminal reap.
        } else if owner != nil {
            return WorkerPostReapEvidence(workerReaped: false,
                ownershipProtocol: .incomplete, recordedChildDrain: .unverified,
                runAuthority: .unavailable)
        }
        let recordedChildDrained = drainRecordedChildAfterWorkerLoss()
        lock.lock()
        let protocolComplete = ownershipProtocolComplete
        let repositoryPending = !repositoryCommands.isEmpty
        lock.unlock()
        let childEvidence: RecordedChildDrainEvidence
        switch repositoryPending ? .some(false) : recordedChildDrained {
        case .some(true):
            childEvidence = .verified
        case .some(false):
            childEvidence = .unverified
        case .none:
            childEvidence = .noneRecorded
        }
        let authorityEvidence: RunAuthorityEvidence
        guard let stateLocation else {
            return WorkerPostReapEvidence(
                workerReaped: true,
                ownershipProtocol: protocolComplete ? .complete : .incomplete,
                recordedChildDrain: childEvidence,
                runAuthority: .unavailable
            )
        }
        do {
            let proof = try RunAuthority.acquireRun(at: stateLocation)
            proof.release()
            authorityEvidence = .released
        } catch SecureStateError.contention {
            authorityEvidence = .held
        } catch {
            authorityEvidence = .error
        }
        return WorkerPostReapEvidence(
            workerReaped: true,
            ownershipProtocol: protocolComplete ? .complete : .incomplete,
            recordedChildDrain: childEvidence,
            runAuthority: authorityEvidence
        )
    }

    private func waitUntilGone(
        _ identity: ProcessIdentity,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = MonotonicDeadline(seconds: timeout)
        while !deadline.hasExpired {
            if !identity.isCurrent(expectedGeneration: identity.generation) {
                return true
            }
            usleep(20_000)
        }
        return !identity.isCurrent(expectedGeneration: identity.generation)
    }

    @discardableResult
    func markExited(_ status: Int32, childDrainVerified: Bool) -> Bool {
        if let owner {
            guard case let .reaped(rawStatus) = owner.observation,
                  Self.exitCode(rawStatus) == status else { return false }
        }
        exitCondition.lock()
        defer { exitCondition.unlock() }
        guard exitStatus == nil, !exitOwnershipFailed else { return false }
        exitStatus = status
        exitChildDrainVerified = childDrainVerified
        exitCondition.broadcast()
        return true
    }

    @discardableResult
    func markReapOwnershipFailed() -> Bool {
        exitCondition.lock()
        defer { exitCondition.unlock() }
        guard exitStatus == nil, !exitOwnershipFailed else { return false }
        exitOwnershipFailed = true
        exitCondition.broadcast()
        return true
    }

    static func exitCode(_ rawStatus: Int32) -> Int32 {
        (rawStatus & 0x7F) == 0 ? (rawStatus >> 8) & 0xFF : 128 + (rawStatus & 0x7F)
    }

    func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = MonotonicDeadline(seconds: timeout)
        exitCondition.lock()
        defer { exitCondition.unlock() }
        while exitStatus == nil, !exitOwnershipFailed, !deadline.hasExpired {
            _ = exitCondition.wait(until: Date().addingTimeInterval(0.1))
        }
        return exitStatus
    }

    private func childDrainWasVerified() -> Bool {
        exitCondition.lock()
        let verified = exitStatus != nil && exitChildDrainVerified
        exitCondition.unlock()
        return verified
    }

    func stopSafely(
        cooperativeTimeout: TimeInterval = ProcessOwnershipTiming.cooperativeAcknowledgement,
        termTimeout: TimeInterval = ProcessOwnershipTiming.termGrace,
        killTimeout: TimeInterval = ProcessOwnershipTiming.postKillReap
    ) -> WorkerStopOutcome {
        stopExecutionCondition.lock()
        while true {
            switch stopExecutionState {
            case .idle:
                let attempt = Self.makeStopAttempt(
                    actionTimeout: cooperativeTimeout
                        + termTimeout
                        + killTimeout,
                    publicationGrace:
                        ProcessOwnershipTiming.schedulingMargin
                        + ProcessOwnershipTiming.handoffSettlement
                )
                stopExecutionState = .running(attempt)
                #if SHADOW_SYNC_TESTING
                stopExecutionCount += 1
                #endif
                stopExecutionCondition.unlock()
                let outcome = performStopSafely(
                    cooperativeTimeout: cooperativeTimeout,
                    termTimeout: termTimeout,
                    killTimeout: killTimeout
                )
                stopExecutionCondition.lock()
                let published = publishStopOutcomeLocked(
                    outcome,
                    generation: attempt.generation
                )
                stopExecutionCondition.unlock()
                return published
            case let .running(attempt):
                if attempt.publicationDeadline.hasExpired {
                    stopExecutionState = .publicationOverdue(attempt)
                    stopExecutionCondition.broadcast()
                    stopExecutionCondition.unlock()
                    return .unverified
                }
                let activeDeadline = attempt.actionDeadline.hasExpired
                    ? attempt.publicationDeadline
                    : attempt.actionDeadline
                let waitMilliseconds = min(
                    activeDeadline.remainingMilliseconds,
                    100
                )
                _ = stopExecutionCondition.wait(
                    until: Date().addingTimeInterval(
                        TimeInterval(waitMilliseconds) / 1_000
                    )
                )
            case .publicationOverdue:
                stopExecutionCondition.unlock()
                return .unverified
            case let .completed(_, outcome):
                stopExecutionCondition.unlock()
                return outcome
            }
        }
    }

    private func publishStopOutcomeLocked(
        _ outcome: WorkerStopOutcome,
        generation: String
    ) -> WorkerStopOutcome {
        switch stopExecutionState {
        case let .running(current)
            where current.generation == generation:
            stopExecutionState = .completed(generation, outcome)
            stopExecutionCondition.broadcast()
            return outcome
        case let .publicationOverdue(current)
            where current.generation == generation:
            stopExecutionState = .completed(generation, outcome)
            stopExecutionCondition.broadcast()
            return outcome
        case let .completed(_, published):
            return published
        case .idle, .running, .publicationOverdue:
            return .unverified
        }
    }

    private func performStopSafely(
        cooperativeTimeout: TimeInterval,
        termTimeout: TimeInterval,
        killTimeout: TimeInterval
    ) -> WorkerStopOutcome {
        #if SHADOW_SYNC_TESTING
        recordStopCancellation()
        #endif
        let delivered = cancel()
        if let status = waitForExit(timeout: cooperativeTimeout) {
            guard childDrainWasVerified() else { return .unverified }
            return delivered ? .cooperative(status) : .alreadyExited(status)
        }
        guard identity.isCurrent(expectedGeneration: identity.generation) else {
            return .unverified
        }
        guard sendOwnedSignal(
            SIGTERM,
            to: identity,
            expectedGeneration: identity.generation
        ) else {
            return .unverified
        }
        if let status = waitForExit(timeout: termTimeout) {
            guard childDrainWasVerified() else { return .unverified }
            return .terminated(status)
        }
        guard identity.isCurrent(expectedGeneration: identity.generation),
              sendOwnedSignal(
                SIGKILL,
                to: identity,
                expectedGeneration: identity.generation
              ) else {
            return .unverified
        }
        if let status = waitForExit(timeout: killTimeout) {
            guard childDrainWasVerified() else { return .unverified }
            return .killed(status)
        }
        return .stillActive
    }

    private func sendOwnedSignal(
        _ signal: Int32,
        to identity: ProcessIdentity,
        expectedGeneration: String
    ) -> Bool {
        #if SHADOW_SYNC_TESTING
        stopExecutionCondition.lock()
        if signal == SIGTERM {
            stopTermCount += 1
        } else if signal == SIGKILL {
            stopKillCount += 1
        }
        stopExecutionCondition.unlock()
        #endif
        guard identity == self.identity, expectedGeneration == self.identity.generation,
              let owner else { return false }
        return owner.send(signal)
    }

    #if SHADOW_SYNC_TESTING
    private func recordStopCancellation() {
        stopExecutionCondition.lock()
        stopCancellationCount += 1
        stopExecutionCondition.unlock()
    }

    var testingStopMetrics: StopMetrics {
        stopExecutionCondition.lock()
        defer { stopExecutionCondition.unlock() }
        return StopMetrics(
            executionCount: stopExecutionCount,
            cancellationCount: stopCancellationCount,
            termCount: stopTermCount,
            killCount: stopKillCount
        )
    }

    func testingAbandonStopAttempt(
        actionTimeout: TimeInterval,
        publicationGrace: TimeInterval
    ) -> Bool {
        stopExecutionCondition.lock()
        defer { stopExecutionCondition.unlock() }
        guard case .idle = stopExecutionState else { return false }
        stopExecutionState = .running(
            Self.makeStopAttempt(
                actionTimeout: actionTimeout,
                publicationGrace: publicationGrace
            )
        )
        return true
    }

    func testingPublishStopOutcome(
        _ outcome: WorkerStopOutcome
    ) -> WorkerStopOutcome {
        stopExecutionCondition.lock()
        defer { stopExecutionCondition.unlock() }
        switch stopExecutionState {
        case let .running(attempt):
            return publishStopOutcomeLocked(
                outcome,
                generation: attempt.generation
            )
        case let .publicationOverdue(attempt):
            return publishStopOutcomeLocked(
                outcome,
                generation: attempt.generation
            )
        case let .completed(_, published):
            return published
        case .idle:
            return .unverified
        }
    }
    #endif

    deinit {
        closeControl()
    }
}

enum WorkerClientError: Error {
    case pipe(String)
    case spawn(Int32)
    case sessionAssignment
    case reapOwnership(Int32)
}

enum WorkerEnvironment {
    static func make(
        account: EffectiveAccount,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var environment = [
            "HOME=\(account.homeDirectory)",
            "USER=\(account.username)",
            "LOGNAME=\(account.username)",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG=C",
            "LC_ALL=C",
            "TMPDIR=/private/tmp",
        ]
        if let socket = ValidatedSSHAgentEnvironment.socketPath(
            inherited: inherited,
            accountUID: account.uid
        ) {
            environment.append("SSH_AUTH_SOCK=\(socket)")
        }
        return environment
    }
}

final class WorkerClient {
    private let executablePath: String

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func start(
        request: WorkerRequest,
        stateLocation: StateLocation?,
        installSession: (WorkerSession) -> Bool,
        onOwnershipFailure: @escaping @Sendable () -> Void,
        onMessage: @escaping @Sendable (WorkerWireMessage) -> Void,
        onExit: @escaping @Sendable (Int32, WorkerPostReapEvidence) -> Void
    ) throws -> WorkerSession {
        var requestPipe: [Int32] = [-1, -1]
        var eventPipe: [Int32] = [-1, -1]
        var controlPipe: [Int32] = [-1, -1]
        var startGate: [Int32] = [-1, -1]
        guard pipe(&requestPipe) == 0 else {
            throw WorkerClientError.pipe("request")
        }
        guard pipe(&eventPipe) == 0 else {
            close(requestPipe[0])
            close(requestPipe[1])
            throw WorkerClientError.pipe("event")
        }
        guard pipe(&controlPipe) == 0 else {
            close(requestPipe[0])
            close(requestPipe[1])
            close(eventPipe[0])
            close(eventPipe[1])
            throw WorkerClientError.pipe("control")
        }
        guard pipe(&startGate) == 0 else {
            closeAll(requestPipe + eventPipe + controlPipe)
            throw WorkerClientError.pipe("start gate")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closeAll(requestPipe + eventPipe + controlPipe + startGate)
            throw WorkerClientError.spawn(errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var code = posix_spawn_file_actions_adddup2(&actions, requestPipe[0], WorkerMain.requestFD)
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(&actions, eventPipe[1], WorkerMain.eventFD)
        }
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(&actions, controlPipe[0], WorkerMain.controlFD)
        }
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                startGate[0],
                WorkerMain.startGateFD
            )
        }
        guard code == 0 else {
            closeAll(requestPipe + eventPipe + controlPipe + startGate)
            throw WorkerClientError.spawn(code)
        }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        code = posix_spawnattr_setflags(&attributes, flags)
        if code == 0 {
            code = posix_spawnattr_setpgroup(&attributes, 0)
        }
        guard code == 0 else {
            closeAll(requestPipe + eventPipe + controlPipe + startGate)
            throw WorkerClientError.spawn(code)
        }

        let arguments = [executablePath, WorkerMain.mode]
        #if SHADOW_SYNC_TESTING
        let account = try EffectiveAccount.isolated(
            homeDirectory: URL(fileURLWithPath: request.isolatedRoot)
                .appendingPathComponent("home", isDirectory: true).path
        )
        #else
        let account = try EffectiveAccount.current()
        #endif
        let environment = WorkerEnvironment.make(account: account)
        var processID: pid_t = 0
        code = withCStringArray(arguments) { argv in
            withCStringArray(environment) { env in
                posix_spawn(&processID, executablePath, &actions, &attributes, argv, env)
            }
        }
        guard code == 0 else {
            closeAll(requestPipe + eventPipe + controlPipe + startGate)
            throw WorkerClientError.spawn(code)
        }

        close(requestPipe[0])
        close(eventPipe[1])
        close(controlPipe[0])
        close(startGate[0])
        let identity: ProcessIdentity
        let owner: OwnedDirectChild
        do {
            identity = try ProcessIdentity.capture(
                processID: processID,
                generation: request.workerGeneration,
                expectedExecutablePath: executablePath
            )
            owner = try OwnedDirectChild(adoptingSpawnedChild: processID, identity: identity)
        } catch {
            close(requestPipe[1])
            close(eventPipe[0])
            close(controlPipe[1])
            close(startGate[1])
            var status: Int32 = 0
            _ = waitpid(processID, &status, 0)
            throw error
        }
        let session = WorkerSession(
            owner: owner,
            controlWrite: controlPipe[1],
            stateLocation: stateLocation,
            expectedRunID: request.runID
        )
        guard installSession(session) else {
            close(requestPipe[1])
            close(eventPipe[0])
            close(startGate[1])
            guard case .reaped = Self.awaitReap(owner) else {
                session.markReapOwnershipFailed()
                throw WorkerClientError.reapOwnership(ECHILD)
            }
            throw WorkerClientError.sessionAssignment
        }
        do {
            try JSONLineChannel.write(request, descriptor: requestPipe[1])
        } catch {
            close(requestPipe[1])
            close(eventPipe[0])
            close(startGate[1])
            guard case .reaped = Self.awaitReap(owner) else {
                session.markReapOwnershipFailed()
                throw WorkerClientError.reapOwnership(ECHILD)
            }
            throw error
        }
        close(requestPipe[1])
        var admission = UInt8(ascii: "G")
        guard Darwin.write(startGate[1], &admission, 1) == 1 else {
            close(eventPipe[0])
            close(startGate[1])
            guard case .reaped = Self.awaitReap(owner) else {
                session.markReapOwnershipFailed()
                throw WorkerClientError.reapOwnership(ECHILD)
            }
            throw WorkerClientError.pipe("start gate publication")
        }
        close(startGate[1])

        let eventRead = eventPipe[0]
        Thread.detachNewThread {
            var acceptedOwnership = false
            var ownershipFailureReported = false
            func reportOwnershipFailure() {
                guard !ownershipFailureReported else { return }
                ownershipFailureReported = true
                onOwnershipFailure()
            }
            while true {
                do {
                    let message = try JSONLineChannel.readOne(
                        WorkerWireMessage.self,
                        descriptor: eventRead
                    )
                    if !acceptedOwnership {
                        guard message.kind == .ownership,
                              let workerIdentity = message.workerIdentity,
                              let runID = message.runID,
                              session.markOwnershipProtocolComplete(
                                  workerIdentity: workerIdentity,
                                  runID: runID
                              ) else {
                            reportOwnershipFailure()
                            break
                        }
                        acceptedOwnership = true
                    } else if message.kind == .ownership {
                        guard let workerIdentity = message.workerIdentity,
                              let runID = message.runID,
                              session.markOwnershipProtocolComplete(
                                  workerIdentity: workerIdentity,
                                  runID: runID
                              ) else {
                            reportOwnershipFailure()
                            break
                        }
                        continue
                    } else if message.kind == .repositoryCommand {
                        guard let event = message.repositoryCommand, session.recordRepositoryCommand(event) else {
                            reportOwnershipFailure(); break
                        }
                    } else if message.kind == .childOwnership,
                       let child = message.childIdentity {
                        session.recordChild(child)
                    } else if message.kind == .childReleased {
                        session.recordChild(nil)
                    }
                    onMessage(message)
                } catch {
                    break
                }
            }
            close(eventRead)
            Self.finishReadingWorker(session: session,
                onOwnershipFailure: reportOwnershipFailure, onExit: onExit)
        }
        return session
    }

    // This wait has no second reaper. Bounded retained cleanup is a separate
    // OWNER-02 gate; an ownership failure cannot manufacture exit status zero.
    static func awaitReap(_ owner: OwnedDirectChild) -> OwnedDirectChildObservation {
        while true {
            #if SHADOW_SYNC_TESTING
            owner.testingBeforeReap()
            #endif
            let observation = owner.poll()
            if observation != .running { return observation }
            usleep(10_000)
        }
    }

    static func finishReadingWorker(
        session: WorkerSession,
        onOwnershipFailure: () -> Void,
        onExit: (Int32, WorkerPostReapEvidence) -> Void
    ) {
        guard let owner = session.owner,
              case let .reaped(status) = awaitReap(owner) else {
            session.closeControl()
            if session.markReapOwnershipFailed() { onOwnershipFailure() }
            return
        }
        session.closeControl()
        let safety = session.verifySafetyAfterWorkerReap()
        let exitCode = WorkerSession.exitCode(status)
        guard session.markExited(exitCode, childDrainVerified: safety.childDrainVerified) else { return }
        onExit(exitCode, safety)
    }

    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            close(descriptor)
        }
    }
}

private func withCStringArray<T>(
    _ values: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> T
) -> T {
    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    var mutable = pointers
    mutable.append(nil)
    return mutable.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress)
    }
}
