#if SHADOW_SYNC_TESTING
import AppKit
import Darwin
import ShadowSyncCore
import Foundation

private struct M1HarnessRequest: Codable {
    static let schemaName = "shadow-sync-m1-harness/v1"

    let schema: String
    let testRoot: String
    let repositoryPath: String
    let logicalOrigin: String
    let localBareRemote: String
    let seededDiagnostic: String?
}

private struct M1HarnessResponse: Encodable {
    let schema: String
    let report: RunReport
    let events: [RunEvent]
    let workerPID: Int32
    let logPath: String
    let summary: String

    init(report: RunReport, events: [RunEvent], workerPID: Int32, logPath: String) {
        schema = "shadow-sync-m1-harness-result/v1"
        self.report = report
        self.events = events
        self.workerPID = workerPID
        self.logPath = logPath
        summary = report.summary
    }
}

enum M1Harness {
    private static let channelMode = "--shadow-sync-m1-test-channel"
    private static let lockHolderMode = "--shadow-sync-m1-lock-holder"
    private static let orphanSnapshotMode = "--shadow-sync-m1-orphan-snapshot"

    static func dispatch(arguments: [String], executablePath: String) -> Int32? {
        guard arguments.count >= 2 else {
            return nil
        }
        if arguments[1] == lockHolderMode {
            return holdRunLock(arguments: arguments)
        }
        if arguments[1] == orphanSnapshotMode {
            return makeOrphanSnapshot(arguments: arguments)
        }
        guard arguments[1] == channelMode else {
            return nil
        }
        guard arguments.count == 3,
              let descriptor = Int32(arguments[2]),
              descriptor >= 0,
              fcntl(descriptor, F_GETFD) >= 0 else {
            writeError("M1 test channel is invalid.\n")
            return 2
        }
        do {
            let request = try JSONLineChannel.readOne(
                M1HarnessRequest.self,
                descriptor: descriptor
            )
            try validate(request)
            let candidate = try RepositoryHandle.testingBoundCandidate(
                path: request.repositoryPath,
                id: "fixture-owner/fixture-repo",
                displayName: "M1 Fixture",
                rawOrigin: request.logicalOrigin,
                presentationLocation: "~/dev"
            )
            let mapping = try TransportMapping(
                logicalURL: request.logicalOrigin,
                localRepositoryPath: request.localBareRemote,
                containmentRoot: request.testRoot
            )
            let workerRequest = WorkerRequest(
                candidate: candidate,
                runID: RunIdentity.make(),
                isolatedRoot: request.testRoot,
                transportMapping: mapping,
                seededDiagnostic: request.seededDiagnostic
            )
            let completed = DispatchSemaphore(value: 0)
            let box = HarnessResultBox()
            let client = WorkerClient(executablePath: executablePath)
            try TestIsolation.initializeState(at: StateLocation.isolated(root: request.testRoot))
            var installedSession: WorkerSession?
            let session = try client.start(
                request: workerRequest,
                stateLocation: try StateLocation.isolated(root: request.testRoot),
                installSession: {
                    installedSession = $0
                    return true
                },
                onOwnershipFailure: {
                    completed.signal()
                },
                onMessage: { message in
                    box.accept(message)
                },
                onExit: { status, _ in
                    box.finish(status)
                    completed.signal()
                }
            )
            guard installedSession === session else {
                throw WorkerClientError.sessionAssignment
            }
            guard completed.wait(timeout: .now() + 150) == .success else {
                session.cancel()
                if session.waitForExit(timeout: 6) == nil {
                    _ = session.stopSafely(cooperativeTimeout: 0, termTimeout: 0, killTimeout: 2)
                    _ = session.waitForExit(timeout: 2)
                }
                writeError("M1 test worker timed out.\n")
                return 1
            }
            let snapshot = box.snapshot()
            guard snapshot.exitCode == 0,
                  let report = snapshot.report,
                  let workerPID = snapshot.workerPID else {
                writeError("M1 test worker failed: \(snapshot.error ?? "no report").\n")
                return 1
            }
            let response = M1HarnessResponse(
                report: report,
                events: snapshot.events,
                workerPID: workerPID,
                logPath: URL(fileURLWithPath: request.testRoot)
                    .appendingPathComponent("state/shadow-sync/latest.log").path
            )
            try JSONLineChannel.write(response, descriptor: descriptor)
            return 0
        } catch {
            writeError("M1 test harness refused: \(Redactor.sanitize(String(describing: error))).\n")
            return 2
        }
    }

    private static func makeOrphanSnapshot(arguments: [String]) -> Int32 {
        guard arguments.count == 4,
              arguments[2].hasPrefix("/private/tmp/"),
              arguments[3].hasPrefix("/private/tmp/") else {
            return 2
        }
        do {
            let candidate = try RepositoryHandle.fixedCandidate(path: arguments[2])
            let handle = try RepositoryHandle.open(candidate)
            let account = try EffectiveAccount.isolated(homeDirectory: arguments[3])
            let frozen = try handle.freezeConfiguration(account: account)
            withExtendedLifetime(frozen) {
                _exit(0)
            }
        } catch {
            return 2
        }
    }

    private static func holdRunLock(arguments: [String]) -> Int32 {
        guard arguments.count == 5,
              let readyDescriptor = Int32(arguments[3]),
              let releaseDescriptor = Int32(arguments[4]),
              readyDescriptor >= 0,
              releaseDescriptor >= 0,
              fcntl(readyDescriptor, F_GETFD) >= 0,
              fcntl(releaseDescriptor, F_GETFD) >= 0 else {
            writeError("M1 lock-holder channel is invalid.\n")
            return 2
        }
        defer {
            close(readyDescriptor)
            close(releaseDescriptor)
        }
        do {
            let root = try validatedTestRoot(arguments[2])
            let authority = try RunAuthority.acquireRun(at: .isolated(root: root))
            defer { authority.release() }
            var ready: UInt8 = 1
            guard Darwin.write(readyDescriptor, &ready, 1) == 1 else {
                throw SecureStateError.systemCall("write lock-holder readiness", errno)
            }
            var release: UInt8 = 0
            while true {
                let count = Darwin.read(releaseDescriptor, &release, 1)
                if count == 1 || count == 0 {
                    return 0
                }
                if errno != EINTR {
                    throw SecureStateError.systemCall("read lock-holder release", errno)
                }
            }
        } catch {
            writeError("M1 lock-holder failed: \(Redactor.sanitize(String(describing: error))).\n")
            return 2
        }
    }

    private static func validate(_ request: M1HarnessRequest) throws {
        let testRoot = try validatedTestRoot(request.testRoot)
        guard request.schema == M1HarnessRequest.schemaName,
              testRoot == request.testRoot,
              isContainedPhysicalPath(request.repositoryPath, root: testRoot),
              isContainedPhysicalPath(request.localBareRemote, root: testRoot),
              GitHubIdentity.parse(request.logicalOrigin) != nil,
              !request.testRoot.contains("\n"),
              !request.repositoryPath.contains("\n"),
              !request.localBareRemote.contains("\n"),
              (request.seededDiagnostic?.utf8.count ?? 0) <= 8_192 else {
            throw GitSafetyError.unsafeRepository("test request escaped its explicit root")
        }
    }

    fileprivate static func validatedTestRoot(_ root: String) throws -> String {
        try TestIsolation.validateRoot(root)
    }

    fileprivate static func isContainedPhysicalPath(_ path: String, root: String) -> Bool {
        (try? TestIsolation.validateContainedDirectory(path, root: root)) != nil
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}

private final class HarnessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reportValue: RunReport?
    private var eventsValue: [RunEvent] = []
    private var errorValue: String?
    private var workerPIDValue: Int32?
    private var exitCodeValue: Int32?

    func accept(_ message: WorkerWireMessage) {
        lock.lock()
        if let event = message.event {
            eventsValue.append(event)
        }
        if let report = message.report {
            reportValue = report
        }
        if let error = message.error {
            errorValue = error
        }
        if let workerPID = message.workerPID {
            workerPIDValue = workerPID
        }
        lock.unlock()
    }

    func finish(_ status: Int32) {
        lock.lock()
        exitCodeValue = status
        lock.unlock()
    }

    func snapshot() -> (
        report: RunReport?,
        events: [RunEvent],
        error: String?,
        workerPID: Int32?,
        exitCode: Int32?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (reportValue, eventsValue, errorValue, workerPIDValue, exitCodeValue)
    }
}

private struct M1AppKitRequest: Codable {
    static let schemaName = "shadow-sync-m1-appkit/v1"
    let schema: String
    let testRoot: String
    let repositoryPath: String
    let logicalOrigin: String
    let localBareRemote: String
    let crashSentinel: String?
    let agentSocketPath: String?
}

private struct M1FailingDiscovery: RepositoryDiscovering {
    func discover() throws -> [RepositoryCandidate] {
        throw M1RepositoryDiscoveryError.requiredRootUnavailable
    }
}

private struct M2BudgetFailingDiscovery: RepositoryDiscovering {
    func discover() throws -> [RepositoryCandidate] {
        throw M1RepositoryDiscoveryError.scanBudgetExceeded
    }
}

private struct M2AppKitDiscovery: RepositoryDiscovering {
    let candidates: [RepositoryCandidate]

    func discover() throws -> [RepositoryCandidate] {
        candidates
    }
}

private struct M1AppKitResponse: Encodable {
    let schema = "shadow-sync-m1-appkit-result/v1"
    let noDefaultSelection: Bool
    let confirmationAccepted: Bool
    let backAndCancelExercised: Bool
    let confirmationPresentationExact: Bool
    let openLogUsedIsolatedPath: Bool
    let menuContentsExact: Bool
    let selectionPresentationExact: Bool
    let selectionControlsExact: Bool
    let multiSelectionPresentationExact: Bool
    let multiSelectionFailures: [String]
    let multiRowProgressExact: Bool
    let discoveryPresentationExact: Bool
    let resultLabelMappingExact: Bool
    let statusSymbolMappingExact: Bool
    let workerEnvironmentExact: Bool
    let mainRunLoopTicks: Int
    let phases: [RepositoryPhase]
    let report: RunReport?
    let summary: String
    let reportPersistedAfterClose: Bool
    let workerDrained: Bool
    let quitExercised: Bool
    let needsAttention: Bool
    let partialLogRecordCount: Int
    let leaseBlockedAfterWorkerCrash: Bool
    let leaseReleasedAfterGitExit: Bool
    let childDrainedAfterWorkerCrash: Bool
    let recoveryEvidenceBlockedUntilAcknowledged: Bool
    let recoveryAcknowledgementEnabledSelection: Bool
    let ownershipFailureLifecycleExact: Bool
    let stopLifecycleStateExact: Bool
    let controllerStopRaceExact: Bool
    let workerStopSingleFlightExact: Bool
    let lifecycleInvocationAdmissionExact: Bool
    let takeoverTransitionExact: Bool
    let cancelDuringWorkerEventsExact: Bool
}

private final class M1TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
enum M1AppKitDriver {
    private static let mode = "--shadow-sync-m1-appkit-channel"

    static func dispatch(arguments: [String], executablePath: String) -> Int32? {
        guard arguments.count >= 2, arguments[1] == mode else {
            return nil
        }
        guard arguments.count == 3,
              let descriptor = Int32(arguments[2]),
              descriptor >= 0,
              fcntl(descriptor, F_GETFD) >= 0 else {
            return 2
        }
        do {
            let request = try JSONLineChannel.readOne(
                M1AppKitRequest.self,
                descriptor: descriptor
            )
            let root = try M1Harness.validatedTestRoot(request.testRoot)
            guard request.schema == M1AppKitRequest.schemaName,
                  M1Harness.isContainedPhysicalPath(request.repositoryPath, root: root),
                  M1Harness.isContainedPhysicalPath(request.localBareRemote, root: root),
                  request.crashSentinel == nil
                    || (
                        request.crashSentinel!.hasPrefix(root + "/")
                            && !request.crashSentinel!.contains("/../")
                            && !request.crashSentinel!.contains("/./")
                    ),
                  GitHubIdentity.parse(request.logicalOrigin) != nil else {
                throw GitSafetyError.unsafeRepository("AppKit test request is not isolated")
            }
            let candidate = try RepositoryHandle.testingBoundCandidate(
                path: request.repositoryPath,
                id: "fixture-owner/fixture-repo",
                displayName: "M1 AppKit Fixture",
                rawOrigin: request.logicalOrigin,
                presentationLocation: "~/dev"
            )
            let mapping = try TransportMapping(
                logicalURL: request.logicalOrigin,
                localRepositoryPath: request.localBareRemote,
                containmentRoot: root
            )
            var confirmationResponses: [NSApplication.ModalResponse] = [
                .alertFirstButtonReturn,
                .alertSecondButtonReturn,
                .alertThirdButtonReturn,
            ]
            var quits = 0
            var openedLogs: [String] = []
            let delegate = ShadowSyncAppDelegate(
                executablePath: executablePath,
                discovery: IsolatedRepositoryDiscovery(candidate: candidate),
                testingRoot: root,
                testingMapping: mapping,
                testingConfirmation: {
                    confirmationResponses.removeFirst()
                },
                testingLogOpener: { url in
                    openedLogs.append(url.path)
                    return true
                },
                testingShortcutAvailable: false,
                testingQuitHandler: {
                    quits += 1
                }
            )
            let application = NSApplication.shared
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            delegate.applicationDidFinishLaunching(
                Notification(name: NSApplication.didFinishLaunchingNotification)
            )
            defer {
                delegate.applicationWillTerminate(
                    Notification(name: NSApplication.willTerminateNotification)
                )
                application.delegate = nil
            }
            delegate.testStartNewRun()
            let noDefault = delegate.testSelectionHasNoDefault
            let selectionPresentation = delegate.testSelectionPresentation
            let selectionExact = selectionPresentation?.0
                    == ShadowSyncPresentation.selectionTitle
                && selectionPresentation?.1 == ShadowSyncPresentation.help
                && selectionPresentation?.2 == ShadowSyncPresentation.zeroSelection
                && selectionPresentation?.3 == [
                    ShadowSyncPresentation.selectAll,
                    ShadowSyncPresentation.clearAll,
                    ShadowSyncPresentation.cancelSelection,
                    ShadowSyncPresentation.reviewSelection,
                ]
            guard noDefault else {
                throw GitSafetyError.unsafeRepository("AppKit selection was not default-off")
            }
            delegate.testSelectAll()
            let selectedAll = delegate.testSelectionCount == 1
            delegate.testClearAll()
            let clearedAll = delegate.testSelectionCount == 0
            delegate.testSelectFirst()
            let selectedSubset = delegate.testSelectionCount == 1
            let selectionIdentity = delegate.testSelectionControllerIdentity
            let relay = HostActivationRelay()
            let coldAccepted = relay.activate()
                && relay.activate()
                && relay.activate()
            relay.install(target: delegate)
            let coldDeadline = MonotonicDeadline(seconds: 1)
            while delegate.testDuplicateActivationCount < 1,
                  !coldDeadline.hasExpired {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            let coldActivationExact =
                delegate.testDuplicateActivationCount == 1
                && delegate.testSelectionControllerIdentity == selectionIdentity
                && delegate.testSelectionCount == 1
            let warmAccepted = relay.activate()
                && relay.activate()
                && relay.activate()
            let relayDeadline = MonotonicDeadline(seconds: 1)
            while delegate.testDuplicateActivationCount < 2,
                  !relayDeadline.hasExpired {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            let warmActivationExact =
                delegate.testDuplicateActivationCount == 2
                && delegate.testSelectionControllerIdentity == selectionIdentity
                && delegate.testSelectionCount == 1
            let racingRelay = HostActivationRelay()
            let raceStart = DispatchSemaphore(value: 0)
            let raceFinished = DispatchGroup()
            for _ in 0..<8 {
                raceFinished.enter()
                DispatchQueue.global().async {
                    _ = raceStart.wait(timeout: .now() + 1)
                    _ = racingRelay.activate()
                    raceFinished.leave()
                }
            }
            for _ in 0..<8 {
                raceStart.signal()
            }
            racingRelay.install(target: delegate)
            guard raceFinished.wait(timeout: .now() + 2) == .success else {
                throw GitSafetyError.unsafeRepository("activation relay race timed out")
            }
            let racingDeadline = MonotonicDeadline(seconds: 1)
            while delegate.testDuplicateActivationCount < 3,
                  !racingDeadline.hasExpired {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            let racingActivationExact =
                delegate.testDuplicateActivationCount == 3
                && delegate.testSelectionControllerIdentity == selectionIdentity
                && delegate.testSelectionCount == 1
            delegate.testClearAll()
            let selectionControlsExact = selectedAll
                && clearedAll
                && selectedSubset
                && coldAccepted
                && warmAccepted
                && coldActivationExact
                && warmActivationExact
                && racingActivationExact
            delegate.testSelectAndReview()
            let backReturnedToSelection = delegate.testSelectionIsOpen
            delegate.testSelectAndReview()
            let cancelClosedSelection = !delegate.testSelectionIsOpen
            delegate.testStartNewRun()
            delegate.testSelectAndReview()
            let tickCounter = M1TickCounter()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                tickCounter.increment()
            }
            defer { timer.invalidate() }
            let deadline = MonotonicDeadline(seconds: 155)
            var killedWorker = false
            while !deadline.hasExpired,
                  !(delegate.testRunFinished
                    && delegate.testWorkerDrained
                    && delegate.testRunSettled
                    && (request.crashSentinel == nil
                        || delegate.testReport != nil)) {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
                if !killedWorker,
                   let crashSentinel = request.crashSentinel,
                   FileManager.default.fileExists(atPath: crashSentinel) {
                    delegate.testKillWorker()
                    killedWorker = true
                }
            }
            guard delegate.testRunFinished,
                  delegate.testWorkerDrained,
                  delegate.testRunSettled,
                  request.crashSentinel == nil
                    || delegate.testReport != nil,
                  tickCounter.value > 0 else {
                throw GitSafetyError.unsafeRepository(
                    "AppKit run did not finish responsively: "
                        + "finished=\(delegate.testRunFinished) "
                        + "drained=\(delegate.testWorkerDrained) "
                        + "settled=\(delegate.testRunSettled) "
                        + "ticks=\(tickCounter.value) "
                        + "phases=\(delegate.testObservedPhases) "
                        + "wire=\(delegate.testWireTrace) "
                        + "report=\(delegate.testReport != nil) "
                        + "needsAttention=\(delegate.testNeedsAttention) "
                        + "row=\(delegate.testReportRowText)"
                )
            }
            let phases = delegate.testObservedPhases
            let drained = delegate.testWorkerDrained
            let needsAttention = delegate.testNeedsAttention
            let partialCount = delegate.testRecoveredLogRecordCount
            var leaseBlocked = false
            var leaseReleased = request.crashSentinel == nil
            if request.crashSentinel != nil {
                do {
                    let authority = try RunAuthority.acquireRun(at: .isolated(root: root))
                    authority.release()
                } catch {
                    leaseBlocked = true
                }
                let leaseDeadline = MonotonicDeadline(seconds: 10)
                while !leaseDeadline.hasExpired, !leaseReleased {
                    do {
                        let authority = try RunAuthority.acquireRun(at: .isolated(root: root))
                        authority.release()
                        leaseReleased = true
                    } catch {
                        RunLoop.current.run(
                            mode: .default,
                            before: Date().addingTimeInterval(0.05)
                        )
                    }
                }
            }
            let report = delegate.testReport
            if request.crashSentinel == nil, report == nil {
                throw GitSafetyError.unsafeRepository(
                    "AppKit normal run lacked a report: \(delegate.testReportRowText)"
                )
            }
            delegate.testOpenLatestLog()
            let expectedLog = URL(fileURLWithPath: root)
                .appendingPathComponent("state/shadow-sync/latest.log").path
            let confirmation = delegate.testConfirmationSnapshot
            let exactConfirmation = confirmation?.0
                    == ShadowSyncPresentation.confirmationTitle
                && confirmation?.1
                    == "\(RepositoryOperatorPresentation.confirmationLabel(candidate))\n\n\(ShadowSyncPresentation.confirmationText)"
                && confirmation?.2 == [
                    ShadowSyncPresentation.back,
                    ShadowSyncPresentation.cancel,
                    ShadowSyncPresentation.startUpdate,
                ]
            let expectedMenu = [
                "Start New Run…",
                "Show Last Report",
                "Open Latest Log",
                ShadowSyncPresentation.shortcutUnavailable,
                "Quit ShadowSync",
            ]
            let menuExact = delegate.testMenuTitles() == expectedMenu
            let reportRow = delegate.testReportRowText
            guard delegate.testReportHasSymbol else {
                throw GitSafetyError.unsafeRepository("AppKit report symbol is absent")
            }
            if report != nil {
                for required in ["Fetched:", "Before:", "Duration:"]
                where !reportRow.contains(required) {
                    throw GitSafetyError.unsafeRepository(
                        "AppKit report presentation lacks \(required): \(reportRow)"
                    )
                }
            }
            let presentationRoot = root + "/presentation-\(RunIdentity.make())"
            try FileManager.default.createDirectory(
                atPath: presentationRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var recoveryEvidenceBlocked = request.crashSentinel == nil
            var recoveryAcknowledgementEnabled = request.crashSentinel == nil
            if request.crashSentinel != nil, let report {
                let logURL = URL(fileURLWithPath: root)
                    .appendingPathComponent("state/shadow-sync/latest.log")
                let evidenceBefore = try Data(contentsOf: logURL)
                let relaunched = ShadowSyncAppDelegate(
                    executablePath: executablePath,
                    discovery: IsolatedRepositoryDiscovery(candidate: candidate),
                    testingRoot: root,
                    testingMapping: mapping,
                    testingConfirmation: { .alertSecondButtonReturn },
                    testingLogOpener: { _ in true },
                    testingShortcutAvailable: false,
                    testingQuitHandler: {}
                )
                relaunched.testLoadRecoveryPresentation()
                relaunched.testStartNewRun()
                relaunched.testStartNewRun()
                let evidenceAfterBlockedStarts = try Data(contentsOf: logURL)
                recoveryEvidenceBlocked =
                    relaunched.testRecoveryReviewRequired
                    && !relaunched.testSelectionIsOpen
                    && relaunched.testReport?.run == report.run
                    && evidenceAfterBlockedStarts == evidenceBefore
                relaunched.testCloseRun()
                let acknowledged = !relaunched.testRecoveryReviewRequired
                relaunched.testStartNewRun()
                let evidenceAfterAcknowledgement = try Data(contentsOf: logURL)
                recoveryAcknowledgementEnabled =
                    acknowledged
                    && relaunched.testSelectionIsOpen
                    && evidenceAfterAcknowledgement == evidenceBefore
            }
            delegate.testCloseRun()
            let persisted = report != nil && delegate.testLastReport == report
            delegate.testQuitUtility()
            let multiSelectionFailures = exactMultiSelectionPresentation(
                executablePath: executablePath,
                root: presentationRoot,
                mapping: mapping,
                first: candidate
            )
            let response = M1AppKitResponse(
                noDefaultSelection: noDefault,
                confirmationAccepted: confirmationResponses.isEmpty,
                backAndCancelExercised: backReturnedToSelection && cancelClosedSelection,
                confirmationPresentationExact: exactConfirmation,
                openLogUsedIsolatedPath: openedLogs == [expectedLog],
                menuContentsExact: menuExact,
                selectionPresentationExact: selectionExact,
                selectionControlsExact: selectionControlsExact,
                multiSelectionPresentationExact: multiSelectionFailures.isEmpty,
                multiSelectionFailures: multiSelectionFailures,
                multiRowProgressExact: ShadowSyncAppDelegate
                    .testThreeRowProgressIsCoherent(),
                discoveryPresentationExact: exactDiscoveryPresentation(
                    executablePath: executablePath,
                    root: presentationRoot,
                    mapping: mapping
                ),
                resultLabelMappingExact:
                    ResultCodePresentation.label(for: .updatedBeforeCancellation)
                        == "Updated"
                    && ResultCodePresentation.label(for: .updatedWithWarning)
                        == "Updated with Warning"
                    && ResultCode.updatedBeforeCancellation.resultClass == .success
                    && ResultCode.updatedWithWarning.resultClass == .warning,
                statusSymbolMappingExact: exactStatusSymbolMapping(),
                workerEnvironmentExact: exactWorkerEnvironment(
                    account: try EffectiveAccount.isolated(
                        homeDirectory: URL(fileURLWithPath: root)
                            .appendingPathComponent("home", isDirectory: true).path
                    ),
                    validSocketPath: request.agentSocketPath
                ),
                mainRunLoopTicks: tickCounter.value,
                phases: phases,
                report: report,
                summary: report?.summary ?? "Needs Attention",
                reportPersistedAfterClose: persisted,
                workerDrained: drained,
                quitExercised: quits == 1,
                needsAttention: needsAttention,
                partialLogRecordCount: partialCount,
                leaseBlockedAfterWorkerCrash: leaseBlocked,
                leaseReleasedAfterGitExit: leaseReleased,
                childDrainedAfterWorkerCrash:
                    request.crashSentinel == nil || (!leaseBlocked && leaseReleased),
                recoveryEvidenceBlockedUntilAcknowledged: recoveryEvidenceBlocked,
                recoveryAcknowledgementEnabledSelection: recoveryAcknowledgementEnabled,
                ownershipFailureLifecycleExact:
                    request.crashSentinel != nil
                    || ShadowSyncAppDelegate.testOwnershipFailureLifecycle(
                        executablePath: executablePath,
                        root: presentationRoot,
                        mapping: mapping,
                        candidate: candidate
                    ),
                stopLifecycleStateExact:
                    ShadowSyncAppDelegate.testStopLifecycleStateIsCoherent(),
                controllerStopRaceExact:
                    ShadowSyncAppDelegate.testControllerStopRaces(
                        candidate: candidate
                    ),
                workerStopSingleFlightExact:
                    ShadowSyncAppDelegate.testWorkerStopSingleFlight(root: presentationRoot),
                lifecycleInvocationAdmissionExact:
                    LifecycleMain.testingAdmissionMatrix(),
                takeoverTransitionExact:
                    ShadowSyncAppDelegate.testTakeoverTransitionIsCoherent(
                        root: presentationRoot
                    ),
                cancelDuringWorkerEventsExact:
                    ShadowSyncAppDelegate.testStoppingOverlayControllerRaces(
                        root: presentationRoot
                    )
            )
            try JSONLineChannel.write(response, descriptor: descriptor)
            return 0
        } catch {
            FileHandle.standardError.write(
                Data(
                    "M1 AppKit driver failed: \(Redactor.sanitize(String(describing: error)))\n"
                        .utf8
                )
            )
            return 2
        }
    }

    private static func exactMultiSelectionPresentation(
        executablePath: String,
        root: String,
        mapping: TransportMapping,
        first: RepositoryCandidate
    ) -> [String] {
        let logPath = root + "/state/shadow-sync/latest.log"
        let second = RepositoryCandidate(
            id: "fixture-owner/second-repo",
            displayName: "Second Fixture",
            path: root + "/selection-only",
            rawOrigin: "https://github.com/fixture-owner/second-repo.git"
        )
        let delegate = ShadowSyncAppDelegate(
            executablePath: executablePath,
            discovery: M2AppKitDiscovery(candidates: [first, second]),
            testingRoot: root,
            testingMapping: mapping,
            testingConfirmation: { .alertSecondButtonReturn },
            testingLogOpener: { _ in false },
            testingShortcutAvailable: true,
            testingQuitHandler: {}
        )
        delegate.testStartNewRun()
        let logBefore = try? Data(contentsOf: URL(fileURLWithPath: logPath))
        var setupFailures: [String] = []
        if delegate.testSelectionCount != 0 {
            setupFailures.append("initial-selection")
        }
        delegate.testSelectAll()
        if delegate.testSelectionCount != 2 {
            setupFailures.append("select-all")
        }
        delegate.testClearAll()
        if delegate.testSelectionCount != 0 {
            setupFailures.append("clear-all")
        }
        delegate.testSelectFirst()
        if delegate.testSelectionCount != 1 {
            setupFailures.append("select-first")
        }
        delegate.testClearAll()
        delegate.testSelectAndReview()
        let snapshot = delegate.testConfirmationSnapshot
        let expectedRows = [first, second]
            .map(RepositoryOperatorPresentation.confirmationLabel)
            .joined(separator: "\n")
        let checks = [
            "title": snapshot?.0 == "Ready to update 2 repositories",
            "rows": snapshot?.1
                == "\(expectedRows)\n\n\(ShadowSyncPresentation.confirmationText)",
            "buttons": snapshot?.2 == [
                ShadowSyncPresentation.back,
                ShadowSyncPresentation.cancel,
                ShadowSyncPresentation.startUpdate,
            ],
            "closed": !delegate.testSelectionIsOpen,
            "log": (try? Data(contentsOf: URL(fileURLWithPath: logPath))) == logBefore,
        ]
        let failures = setupFailures + checks.filter { !$0.value }.keys.sorted()
        if !failures.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "M1 multi-selection mismatch: \(failures.joined(separator: ","))\n".utf8
                )
            )
        }
        return failures
    }

    private static func exactStatusSymbolMapping() -> Bool {
        let phases: [(RepositoryPhase, String, String)] = [
            (.pending, "clock", "Pending"),
            (.checking, "magnifyingglass", "Checking"),
            (.fetching, "arrow.down.circle", "Fetching"),
            (.updating, "arrow.triangle.2.circlepath", "Updating"),
            (.stopping, "stop.circle", "Stopping"),
            (.complete, "checkmark.circle", "Complete"),
        ]
        let results: [(ResultClass?, String, String)] = [
            (.success, "checkmark.circle", "Success"),
            (.warning, "exclamationmark.triangle", "Warning"),
            (.failure, "xmark.octagon", "Failure"),
            (.cancelled, "stop.circle", "Cancelled"),
            (nil, "questionmark.circle", "No result"),
        ]
        return phases.allSatisfy { phase, name, description in
            let symbol = ShadowSyncStatusSymbol.phase(phase)
            let image = NSImage(
                systemSymbolName: symbol.name,
                accessibilityDescription: symbol.description
            )
            return symbol.name == name
                && symbol.description == description
                && image?.accessibilityDescription == description
        } && results.allSatisfy { resultClass, name, description in
            let symbol = ShadowSyncStatusSymbol.result(resultClass)
            let image = NSImage(
                systemSymbolName: symbol.name,
                accessibilityDescription: symbol.description
            )
            return symbol.name == name
                && symbol.description == description
                && image?.accessibilityDescription == description
        }
    }

    private static func exactDiscoveryPresentation(
        executablePath: String,
        root: String,
        mapping: TransportMapping
    ) -> Bool {
        func presentation(for discovery: any RepositoryDiscovering) -> (String, String)? {
            let delegate = ShadowSyncAppDelegate(
                executablePath: executablePath,
                discovery: discovery,
                testingRoot: root,
                testingMapping: mapping,
                testingConfirmation: { .alertSecondButtonReturn },
                testingLogOpener: { _ in false },
                testingShortcutAvailable: false,
                testingQuitHandler: {}
            )
            delegate.testStartNewRun()
            return delegate.testDiscoveryPresentation
        }

        let missing = presentation(for: M1FailingDiscovery())
        let overBudget = presentation(for: M2BudgetFailingDiscovery())
        let empty = presentation(for: IsolatedRepositoryDiscovery(candidate: nil))
        return missing?.0 == "Required ~/dev Folder Unavailable"
            && missing?.1.contains("Restore or check out ~/dev") == true
            && overBudget?.0 == "Repository Search Limit Reached"
            && overBudget?.1
                == "ShadowSync stopped before offering repositories because ~/dev contains more folders than can be safely inspected in one run. Move unnecessary folders outside ~/dev, then try again. No update was started."
            && empty?.0 == "No Eligible Repository Found"
            && empty?.1.contains("found ~/dev") == true
            && empty?.1.contains("No update was started") == true
    }

    private static func exactWorkerEnvironment(
        account: EffectiveAccount,
        validSocketPath: String?
    ) -> Bool {
        guard let validSocketPath else {
            return false
        }
        let valid = WorkerEnvironment.make(
            account: account,
            inherited: [
                "SSH_AUTH_SOCK": validSocketPath,
                "SHADOW_SYNC_UNRELATED_SENTINEL": "must-not-survive",
            ]
        )
        let invalidValues = [
            "relative-agent.sock",
            "/does/not/exist/agent.sock",
            account.homeDirectory,
        ]
        return valid.contains("SSH_AUTH_SOCK=\(validSocketPath)")
            && !valid.contains { $0.hasPrefix("SHADOW_SYNC_UNRELATED_SENTINEL=") }
            && invalidValues.allSatisfy { value in
                !WorkerEnvironment.make(
                    account: account,
                    inherited: [
                        "SSH_AUTH_SOCK": value,
                        "SHADOW_SYNC_UNRELATED_SENTINEL": "must-not-survive",
                    ]
                ).contains { $0.hasPrefix("SSH_AUTH_SOCK=") }
            }
    }
}
#endif
