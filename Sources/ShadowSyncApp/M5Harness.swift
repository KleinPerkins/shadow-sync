#if SHADOW_SYNC_TESTING
import AppKit
import Carbon
import Darwin
import ShadowSyncCatalog
import ShadowSyncCore
import Foundation

private struct M5UIRequest: Codable {
    static let schemaName = "shadow-sync-m5-ui/v1"
    let schema: String
    let testRoot: String
}

private struct NativeUISuiteRequest: Decodable {
    let schema: String
    let testRoot: String
    let suite: String
}

private struct NativeUISuiteDefinition: Encodable {
    let id: String
    let checks: [String]
    let diagnostic_only: [String]
    let core_tests: [String]
}

private struct NativeUIInventory: Encodable {
    let schema = "shadow-sync-native-ui-suites/v1"
    let suites: [NativeUISuiteDefinition]
    let legacy_assertions: [String: [String]]
    let lifecycle_checks: [String]
    let core_tests: [String]
}

private struct NativeUISuiteResult: Encodable {
    let schema = "shadow-sync-native-ui-suite-result/v1"
    let suite: String
    let checks: [String: Bool]
    let coreTests: [String]
}

private struct M5ConfirmationCloseRequest: Codable {
    static let schemaName = "shadow-sync-m5-confirmation-close/v1"
    let schema: String
    let testRoot: String
}

private struct M5ConfirmationCloseResponse: Encodable {
    let schema = "shadow-sync-m5-confirmation-close-result/v1"
    let closeClearsSession: Bool
    let retryStartsRun: Bool
    let hiddenCardRemainsOpen: Bool
    let reactivationReusesCard: Bool
    let hiddenOnboardingRemainsOpen: Bool
    let onboardingReactivationReuses: Bool
    let dismissedCanonicalRootCommitStaysClosed: Bool
    let savedCanonicalRootRefreshFailureRecovers: Bool
    let dismissedSavedCanonicalRootReconciles: Bool
    let concurrentCanonicalRootCommitIsRejected: Bool
    let discoveryActivationShowsProgress: Bool
    let discoveryActivationPresentsOnce: Bool
    let onboardingFailurePreservesOnboarding: Bool
    let dismissedFailureReportsAndReconciles: Bool
    let quitRejectsAuthorityAdmission: Bool
    let quitCompletionGenerationIsolated: Bool
    let quitCompletionExactlyOnce: Bool
}

private struct M5ForegroundRequest: Codable {
    static let schemaName = "shadow-sync-m5-foreground/v1"
    let schema: String
    let testRoot: String
}

private struct M5OperationContentionRequest: Codable {
    static let schemaName = "shadow-sync-m5-operation-contention/v1"
    let schema: String
    let testRoot: String
}

private struct M5OperationContentionResponse: Encodable {
    let schema = "shadow-sync-m5-operation-contention-result/v1"
    let lifecyclePassed: Bool
}

private struct M5PracticalUIRequest: Codable {
    static let schemaName = "shadow-sync-m5-practical-ui/v1"
    let schema: String
    let testRoot: String
}

private struct M5StatusItemGuidanceRequest: Codable {
    static let schemaName = "shadow-sync-m5-status-item-guidance/v1"
    let schema: String
    let testRoot: String
}

private struct M5StatusItemGuidanceResponse: Encodable {
    let schema = "shadow-sync-m5-status-item-guidance-result/v1"
    let publicVisibilityClassification: Bool
    let delayedHiddenPresentation: Bool
    let pendingUntilWindow: Bool
    let singlePresentation: Bool
    let guidanceThenForegroundFailure: Bool
    let foregroundFailureThenGuidance: Bool
    let dismissClearsOwnedForegroundFailure: Bool
    let dismissPreservesUnrelatedInlineStatus: Bool
    let dismissPreservesOtherForegroundOwner: Bool
    let dismissPreservesNewForegroundOwner: Bool
    let dismissRestoresShortcutUnavailableHelp: Bool
    let visibleBeforePresentationCancelsGuidance: Bool
    let repeatedOrderingNoDuplicate: Bool
    let visibleNoImpact: Bool
    let exactCopy: Bool
}

private struct M5PracticalUIResponse: Encodable {
    let schema = "shadow-sync-m5-practical-ui-result/v1"
    let disabledRowsAndReasons: Bool
    let eligibleBlockedCounts: Bool
    let selectionExcludesBlocked: Bool
    let keyboardExcludesBlocked: Bool
    let reviewExcludesBlocked: Bool
    let runRowsShowCompactLocation: Bool
    let menuLabelsAndShortcut: Bool
    let chooserInitialAndRestoredGeometry: Bool
    let chooserBothAxisResize: Bool
    let chooserZoomAndFullScreen: Bool
    let menuShortcutFlowEquivalence: Bool
    let originRowsConsolidated: Bool
    let canonicalChoiceRequiredWhenSelected: Bool
    let canonicalChoiceIndependentFromDefaults: Bool
    let validSaveReopenAndContinue: Bool
    let statusSectionsCollapsed: Bool
}

private struct M5ForegroundResponse: Encodable {
    let schema = "shadow-sync-m5-foreground-result/v1"
    let legacyAsyncOrderingRejected: Bool
    let callbackSynchronousOnMain: Bool
    let activationReachedBeforeReturn: Bool
    let realityGateCompletedBeforeReturn: Bool
    let firstShortcutActivated: Bool
    let repeatedShortcutActivated: Bool
    let sameWindowReused: Bool
    let currentSpaceBehavior: Bool
    let inFlightDuplicateWaitedForReality: Bool
    let onboardingRetiresCompletedRun: Bool
    let onboardingRetiresHistoricalViewer: Bool
    let onboardingOwnsForeground: Bool
    let surfaceRoutingCoherent: Bool
    let collisionBlockerRegistered: Bool
    let collisionSurfaced: Bool
    let collisionReleaseThenInvocationSucceeded: Bool
    let shortcutHandlerIsolationPassed: Bool
    let productionShortcutDefaultsPreserved: Bool
    let registrationConflictPassed: Bool
    let timingMatrixPassed: Bool
    let foregroundObserversCleaned: Bool
    let preflightSurfaceOrdering: Bool
    let loadingSurfaceIsCurrent: Bool
    let repeatedLoadingRoutesReuseSurface: Bool
    let staleInventoryCompletionIgnored: Bool
    let inventoryFailureIsRecoverable: Bool
    let reusedContentReplacedByLoading: Bool
    let staleInventoryControlsUnavailable: Bool
    let reusedFailureIsVisible: Bool
    let currentCompletionInstalledOnce: Bool
    let hiddenSuccessRecovered: Bool
    let hiddenFailureRetry: Bool
    let pendingHiddenReshow: Bool
    let hiddenQuitNoResurface: Bool
    let reusedRetryConfigured: Bool
    let staleHiddenCompletionIgnored: Bool
    let dualWindowInventoryPriority: Bool
    let failureSurfacePriority: Bool
    let blockingSurfacePriority: Bool
    let retiredSelectionRunPriority: Bool
    let hiddenSurfaceInvocationPriority: Bool
    let visibleBeginFailureResolved: Bool
    let hiddenBeginFailureResolved: Bool
    let beginFailureRetryStartsOnce: Bool
    let beginFailureQueuedQuit: Bool
    let beginFailureStaleGenerationIgnored: Bool
    let beginFailureLoggingContract: Bool
    let visibleOnboardingPrecedesCards: Bool
    let hiddenOnboardingRemainsGated: Bool
    let pendingOnboardingReopensFirst: Bool
    let onboardingCancelRemainsGated: Bool
    let onboardingConfirmationBuildsCardsOnce: Bool
    let pendingOnboardingQuitAndStaleSafe: Bool
    let onboardedHiddenCompletionPreserved: Bool
    let ownedInventoryQuitLifecycle: Bool
    let lifecycleLoggingContract: Bool
}

@MainActor
private final class M5AsyncOrderingProbe {
    var foregroundRequested = false
}

private struct M5CarbonCollisionResult {
    let blockerRegistered: Bool
    let collisionSurfaced: Bool
    let releaseThenInvocationSucceeded: Bool
    let handlerIsolationPassed: Bool
    let productionDefaultsPreserved: Bool

    var passed: Bool {
        blockerRegistered
            && collisionSurfaced
            && releaseThenInvocationSucceeded
            && handlerIsolationPassed
            && productionDefaultsPreserved
    }
}

private struct M5UIResponse: Encodable {
    let schema = "shadow-sync-m5-ui-result/v1"
    let coreTests: [String]
    let exactCopySnapshots: Bool
    let resultTaxonomyAndTransitions: Bool
    let reducerReportTransactions: Bool
    let workerOwnerSignalReapOrdering: Bool
    let workerOwnerFailedCustodyRefusal: Bool
    let controllerReportTransactions: Bool
    let stoppingOverlayRaces: Bool
    let stoppingControllerRaces: Bool
    let sealedPresentationRaces: Bool
    let operationContentionLifecycle: Bool
    let historicalViewerLifecycleIsolation: Bool
    let body3CorrectiveSessionOwnership: Bool
    let originIdentityPresentation: Bool
    let orderedNativeRows: Bool
    let constantTimeRowMutation: Bool
    let selectionStates: Bool
    let routeStateMatrix: Bool
    let partialAndFinalReopen: Bool
    let secureLogFeedback: Bool
    let focusAndAlertSafety: Bool
    let accessibilitySemantics: Bool
    let adaptiveSemanticLayout: Bool
    let mixedAndCancelledReports: Bool
}

private struct M5LatencyRequest: Codable {
    static let schemaName = "shadow-sync-m5-latency/v1"
    let schema: String
    let testRoot: String
    let trial: Int
    let rowCount: Int
    let durationSeconds: Int
    let eventIntervalMilliseconds: Int
}

private struct M5LatencyResponse: Encodable {
    let schema = "shadow-sync-m5-latency-result/v1"
    let trial: Int
    let rowCount: Int
    let durationSeconds: Int
    let eventIntervalMilliseconds: Int
    let expectedEventCount: Int
    let renderedEventCount: Int
    let firstSequence: Int
    let lastSequence: Int
    let monotonic: Bool
    let noDroppedEvents: Bool
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let samplesMilliseconds: [Double]
}

private final class M5LatencyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var sequences: [Int] = []
    private var emissionTimes: [UInt64] = []
    private var completionTimes: [UInt64] = []
    private var failure: String?

    func append(
        sample: Double,
        sequence: Int,
        emitted: UInt64,
        completed: UInt64
    ) {
        lock.lock()
        samples.append(sample)
        sequences.append(sequence)
        emissionTimes.append(emitted)
        completionTimes.append(completed)
        lock.unlock()
    }

    func fail(_ detail: String) {
        lock.lock()
        if failure == nil {
            failure = detail
        }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    var hasFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failure != nil
    }

    var snapshot: (
        samples: [Double],
        sequences: [Int],
        emissionTimes: [UInt64],
        completionTimes: [UInt64],
        failure: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            samples,
            sequences,
            emissionTimes,
            completionTimes,
            failure
        )
    }
}

private final class M5CountingDiscovery: RepositoryDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private let candidates: [RepositoryCandidate]
    private var count = 0

    init(candidates: [RepositoryCandidate]) {
        self.candidates = candidates
    }

    func discover() throws -> [RepositoryCandidate] {
        lock.lock()
        count += 1
        lock.unlock()
        return candidates
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
private final class M5BetaRecutVisualControl: NSObject {
    private let root: String
    private unowned let application: NSApplication
    private unowned let window: NSWindow
    private unowned let chooser: RepositoryChooserWindowController

    init(
        root: String,
        application: NSApplication,
        window: NSWindow,
        chooser: RepositoryChooserWindowController
    ) {
        self.root = root
        self.application = application
        self.window = window
        self.chooser = chooser
    }

    @objc func poll() {
        let enterPath = root + "/enter-full-screen"
        let exitPath = root + "/exit-full-screen"
        let savePath = root + "/save-defaults"
        if FileManager.default.fileExists(atPath: enterPath) {
            try? FileManager.default.removeItem(atPath: enterPath)
            application.activate()
            window.toggleFullScreen(nil)
        } else if FileManager.default.fileExists(atPath: exitPath) {
            try? FileManager.default.removeItem(atPath: exitPath)
            application.activate()
            window.toggleFullScreen(nil)
        } else if FileManager.default.fileExists(atPath: savePath) {
            try? FileManager.default.removeItem(atPath: savePath)
            let before = window.frame
            chooser.testingSave()
            let after = window.frame
            print(
                "SAVED before=\(before.origin.x),\(before.origin.y),\(before.width),\(before.height) "
                    + "after=\(after.origin.x),\(after.origin.y),\(after.width),\(after.height) "
                    + "status=\(chooser.testingStatus)"
            )
            fflush(stdout)
        }
    }
}

@MainActor
private final class M5BetaV06ResultsVisualControl:
    NSObject {
    private let root: String
    private unowned let application: NSApplication
    private let plan: Body3BatchPlan
    private let report: Body3BatchReport
    private var controller: Body3RunWindowController

    init(
        root: String,
        application: NSApplication,
        plan: Body3BatchPlan,
        report: Body3BatchReport,
        controller: Body3RunWindowController
    ) {
        self.root = root
        self.application = application
        self.plan = plan
        self.report = report
        self.controller = controller
    }

    @objc func poll() {
        let midPath = root + "/mid-run"
        let terminalPath = root + "/terminal"
        let historicalPath = root + "/historical"
        let stopPath = root + "/stop"
        if FileManager.default.fileExists(atPath: midPath) {
            try? FileManager.default.removeItem(
                atPath: midPath
            )
            guard let first = plan.nodes.first,
                  let second = plan.nodes.dropFirst().first else {
                return
            }
            controller.update(Body3CoordinatorEvent(
                record: Body3LogRecord(
                    run: plan.run,
                    sequence: 2,
                    type: "node_started",
                    repository: first.repositoryID,
                    operation: first.id,
                    kind: first.kind.rawValue,
                    phase: first.kind.phase,
                    worker: 1,
                    status: .running,
                    detail:
                        "Fresh repository evidence is being verified."
                )
            ))
            controller.update(Body3CoordinatorEvent(
                record: Body3LogRecord(
                    run: plan.run,
                    sequence: 3,
                    type: "command",
                    repository: first.repositoryID,
                    operation: first.id,
                    kind: first.kind.rawValue,
                    phase: first.kind.phase,
                    worker: 1,
                    executable: "/usr/bin/git",
                    arguments: ["status", "--porcelain"],
                    outcome: "closed command completed",
                    status: .running,
                    detail:
                        "Command evidence remains in Live Log."
                )
            ))
            controller.update(Body3CoordinatorEvent(
                record: Body3LogRecord(
                    run: plan.run,
                    sequence: 4,
                    type: "node_started",
                    repository: second.repositoryID,
                    operation: second.id,
                    kind: second.kind.rawValue,
                    phase: second.kind.phase,
                    worker: 2,
                    status: .running,
                    detail:
                        "Fresh repository evidence is being verified."
                )
            ))
            print(
                "MID window=\(controller.window?.windowNumber ?? 0)"
            )
            fflush(stdout)
        } else if FileManager.default.fileExists(
            atPath: terminalPath
        ) {
            try? FileManager.default.removeItem(
                atPath: terminalPath
            )
            controller.finish(report)
            print(
                "TERMINAL window=\(controller.window?.windowNumber ?? 0)"
            )
            fflush(stdout)
        } else if FileManager.default.fileExists(
            atPath: historicalPath
        ) {
            try? FileManager.default.removeItem(
                atPath: historicalPath
            )
            let frame = controller.window?.frame
            let historical = Body3RunWindowController(
                plan: plan
            )
            historical.finish(report)
            historical.window?.title =
                ShadowSyncPresentation.historicalBatchTitle
            if let frame {
                historical.window?.setFrame(
                    frame,
                    display: false
                )
            }
            historical.showWindow(nil)
            historical.window?.makeKeyAndOrderFront(nil)
            historical.window?.orderFrontRegardless()
            controller.close()
            controller = historical
            application.activate()
            print(
                "HISTORICAL window=\(historical.window?.windowNumber ?? 0)"
            )
            fflush(stdout)
        } else if FileManager.default.fileExists(
            atPath: stopPath
        ) {
            try? FileManager.default.removeItem(
                atPath: stopPath
            )
            controller.close()
            application.terminate(nil)
        }
    }
}

@MainActor
private final class M5BetaV09RLCCVisualControl:
    NSObject {
    private let root: String
    private unowned let application: NSApplication
    private let controller:
        RepositoryCardSelectionWindowController

    init(
        root: String,
        application: NSApplication,
        controller: RepositoryCardSelectionWindowController
    ) {
        self.root = root
        self.application = application
        self.controller = controller
    }

    @objc func poll() {
        let stop = root + "/stop"
        guard FileManager.default.fileExists(
            atPath: stop
        ) else {
            return
        }
        try? FileManager.default.removeItem(atPath: stop)
        controller.close()
        application.terminate(nil)
    }
}

@MainActor
enum M5AppKitDriver {
    private static let nativeUISuiteMode = "--shadow-sync-native-ui-suite-channel"
    private static let nativeUIInventoryMode = "--shadow-sync-list-native-ui-suites"
    private static let uiMode = "--shadow-sync-m5-ui-channel"
    private static let practicalUIMode = "--shadow-sync-m5-practical-ui-channel"
    private static let statusItemGuidanceMode =
        "--shadow-sync-m5-status-item-guidance-channel"
    private static let confirmationCloseMode =
        "--shadow-sync-m5-confirmation-close-channel"
    private static let foregroundMode = "--shadow-sync-m5-foreground-channel"
    private static let operationContentionMode =
        "--shadow-sync-m5-operation-contention-channel"
    private static let latencyMode = "--shadow-sync-m5-latency-channel"
    private static let body3LayoutMode =
        "--shadow-sync-body3-layout-regression"
    private static let betaRecutVisualHostMode =
        "--shadow-sync-beta-recut-visual-host"
    private static let betaV06ResultsVisualHostMode =
        "--shadow-sync-beta-v06-results-visual-host"
    private static let betaV07ResultsVisualHostMode =
        "--shadow-sync-beta-v07-results-visual-host"
    private static let betaV09RLCCVisualHostMode =
        "--shadow-sync-beta-v09-rlcc-visual-host"

    static func dispatch(arguments: [String]) -> Int32? {
        if arguments.count >= 2, arguments[1] == nativeUIInventoryMode {
            guard arguments.count == 2 else { return 64 }
            do {
                try JSONLineChannel.write(nativeUIInventory, descriptor: STDOUT_FILENO)
                return 0
            } catch { return 1 }
        }

        if arguments.count == 4,
           arguments[1] == betaV09RLCCVisualHostMode {
            do {
                let root = try TestIsolation.validateRoot(
                    arguments[2]
                )
                return try runBetaV09RLCCVisualHost(
                    root: root,
                    appearance: arguments[3]
                )
            } catch {
                fputs(
                    "Beta v0.9 RLCC visual host failed: \(error)\n",
                    stderr
                )
                return 2
            }
        }
        if arguments.count == 3,
           arguments[1] == betaRecutVisualHostMode {
            do {
                let root = try TestIsolation.validateRoot(
                    arguments[2]
                )
                return try runBetaRecutVisualHost(root: root)
            } catch {
                fputs(
                    "Beta recut visual host failed: \(error)\n",
                    stderr
                )
                return 2
            }
        }
        if arguments.count == 3,
           [
               betaV06ResultsVisualHostMode,
               betaV07ResultsVisualHostMode,
           ].contains(arguments[1]) {
            do {
                let root = try TestIsolation.validateRoot(
                    arguments[2]
                )
                return try runBetaV06ResultsVisualHost(
                    root: root
                )
            } catch {
                fputs(
                    "Beta v0.6 result visual host failed: \(error)\n",
                    stderr
                )
                return 2
            }
        }
        if arguments.count >= 2, arguments[1] == body3LayoutMode {
            guard arguments.count == 3 else { return 2 }
            do {
                let root = try TestIsolation.validateRoot(arguments[2])
                let application = NSApplication.shared
                application.setActivationPolicy(.accessory)
                application.finishLaunching()
                let layout = try testBody3RepositoryCardLayout(root: root)
                let sessionOwnership =
                    try testBody3CorrectiveSessionOwnership(root: root)
                let historicalOwnership =
                    try testHistoricalViewerLifecycleIsolation(root: root)
                return layout
                    && sessionOwnership
                    && historicalOwnership ? 0 : 1
            } catch {
                fputs(
                    "Body 3 layout regression error: "
                        + "\(error)\n",
                    stderr
                )
                return 1
            }
        }
        guard arguments.count >= 2,
              [
                uiMode,
                nativeUISuiteMode,
                practicalUIMode,
                statusItemGuidanceMode,
                confirmationCloseMode,
                foregroundMode,
                operationContentionMode,
                latencyMode,
              ]
                .contains(arguments[1]) else {
            return nil
        }
        guard arguments.count == 3,
              let descriptor = Int32(arguments[2]),
              descriptor >= 0,
              fcntl(descriptor, F_GETFD) >= 0 else {
            return 2
        }
        do {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            if arguments[1] == nativeUISuiteMode {
                let request = try JSONLineChannel.readOne(NativeUISuiteRequest.self, descriptor: descriptor)
                guard request.schema == "shadow-sync-native-ui-suite/v1",
                      nativeUIInventory.suites.contains(where: { $0.id == request.suite }) else { return 64 }
                let root = try TestIsolation.validateRoot(request.testRoot)
                let result = try runNativeUISuite(request.suite, root: root)
                try JSONLineChannel.write(result, descriptor: descriptor)
            } else if arguments[1] == uiMode {
                let request = try JSONLineChannel.readOne(
                    M5UIRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5UIRequest.schemaName,
                    root: request.testRoot
                )
                let response = try runUITests(root: root)
                try JSONLineChannel.write(response, descriptor: descriptor)
            } else if arguments[1] == confirmationCloseMode {
                let request = try JSONLineChannel.readOne(
                    M5ConfirmationCloseRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5ConfirmationCloseRequest.schemaName,
                    root: request.testRoot
                )
                try JSONLineChannel.write(
                    try runConfirmationCloseRegression(root: root),
                    descriptor: descriptor
                )
            } else if arguments[1] == practicalUIMode {
                let request = try JSONLineChannel.readOne(
                    M5PracticalUIRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5PracticalUIRequest.schemaName,
                    root: request.testRoot
                )
                try JSONLineChannel.write(
                    try runPracticalUITests(root: root),
                    descriptor: descriptor
                )
            } else if arguments[1] == statusItemGuidanceMode {
                let request = try JSONLineChannel.readOne(
                    M5StatusItemGuidanceRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5StatusItemGuidanceRequest.schemaName,
                    root: request.testRoot
                )
                try JSONLineChannel.write(
                    try runStatusItemGuidanceTests(root: root),
                    descriptor: descriptor
                )
            } else if arguments[1] == foregroundMode {
                let request = try JSONLineChannel.readOne(
                    M5ForegroundRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5ForegroundRequest.schemaName,
                    root: request.testRoot
                )
                try JSONLineChannel.write(
                    try runForegroundRegression(root: root),
                    descriptor: descriptor
                )
            } else if arguments[1] == operationContentionMode {
                let request = try JSONLineChannel.readOne(
                    M5OperationContentionRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5OperationContentionRequest.schemaName,
                    root: request.testRoot
                )
                try JSONLineChannel.write(
                    M5OperationContentionResponse(
                        lifecyclePassed:
                            try testOperationContentionLifecycle(root: root)
                    ),
                    descriptor: descriptor
                )
            } else {
                let request = try JSONLineChannel.readOne(
                    M5LatencyRequest.self,
                    descriptor: descriptor
                )
                let root = try validate(
                    schema: request.schema,
                    expectedSchema: M5LatencyRequest.schemaName,
                    root: request.testRoot
                )
                guard (1...3).contains(request.trial),
                      request.rowCount == 100,
                      request.durationSeconds == 60,
                      request.eventIntervalMilliseconds == 25 else {
                    throw M5HarnessError.message(
                        "the latency request does not match the accepted M5 protocol"
                    )
                }
                let response = try runLatencyTrial(
                    root: root,
                    trial: request.trial
                )
                try JSONLineChannel.write(response, descriptor: descriptor)
            }
            return 0
        } catch {
            FileHandle.standardError.write(
                Data(
                    "M5 AppKit driver failed: \(Redactor.sanitize(String(describing: error)))\n"
                        .utf8
                )
            )
            return 2
        }
    }

    private static func runBetaV09RLCCVisualHost(
        root: String,
        appearance: String
    ) throws -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let progressInventory =
            try makeBetaV09RLCCVisualInventory(
                root: root + "/progress",
                repositoryCount: 3
            )
        let progressController =
            RepositoryCardSelectionWindowController(
                inventory: progressInventory
            )
        let progressIDs = progressInventory.cards.map(\.id)
        progressController.beginCleanupInspection(
            repositoryIDs: Set(progressIDs)
        )
        progressController.updateCleanupInspectionProgress(
            CleanupInspectionProgress(
                repositoryID: progressIDs[0],
                repositoryCompleted: 0,
                repositoryTotal: 3,
                stage: .pullRequestEvidence,
                completed: 2,
                total: 5,
                activeChildren: 4,
                maximumActiveChildren: 4
            )
        )
        guard progressController.testingCleanupBatchRows.count == 3,
              progressController.testingCleanupBatchRows[0]
                .contains("Checking pull requests 2/5"),
              progressController.testingCleanupBatchRows[1]
                .contains("Not inspected") else {
            throw M5HarnessError.message(
                "v0.9 batch progress rows were not retained in order: "
                    + progressController.testingCleanupBatchRows
                        .joined(separator: " | ")
            )
        }
        progressController.applyCleanupInspection(
            inventory: progressInventory,
            repositoryIDs: [progressIDs[0]]
        )
        progressController.updateCleanupInspectionProgress(
            CleanupInspectionProgress(
                repositoryID: progressIDs[1],
                repositoryCompleted: 1,
                repositoryTotal: 3,
                stage: .worktreeEvidence,
                completed: 1,
                total: 2
            )
        )
        progressController.failCleanupInspection(
            repositoryIDs: Set(progressIDs),
            message: "Cancelled by deterministic fixture."
        )
        let terminalRows =
            progressController.testingCleanupBatchRows
        guard terminalRows.count == 3,
              terminalRows[0].contains("Complete"),
              terminalRows[1].contains("Cancelled"),
              terminalRows[2].contains("Not inspected"),
              progressController
                .testingCleanupBatchCompletedValue == 2 else {
            throw M5HarnessError.message(
                "v0.9 cancellation did not retain complete/current/pending rows"
            )
        }
        progressController.close()
        let controller =
            RepositoryCardSelectionWindowController(
                inventory:
                    try makeBetaV09RLCCVisualInventory(root: root)
            )
        guard let repositoryID =
                controller.inventorySnapshot.cards.first?.id else {
            throw M5HarnessError.message(
                "v0.9 RLCC visual fixture is empty"
            )
        }
        controller.beginCleanupInspection(
            repositoryIDs: [repositoryID]
        )
        controller.applyCleanupInspection(
            inventory:
                try makeBetaV09RLCCVisualInventory(root: root),
            repositoryIDs: [repositoryID]
        )
        controller.testingSetCloneDisclosuresExpanded(true)
        controller.showWindow(nil)
        controller.window?.appearance = NSAppearance(
            named: appearance == "dark"
                ? .darkAqua : .aqua
        )
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        guard let window = controller.window else {
            throw M5HarnessError.message(
                "v0.9 RLCC visual window is missing"
            )
        }
        window.setContentSize(
            NSSize(width: 720, height: 620)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        guard controller
                .testingBetaV09CandidateHierarchyIsAccessible else {
            throw M5HarnessError.message(
                "v0.9 candidate hierarchy geometry or accessibility is invalid"
            )
        }
        application.activate()
        print(
            "READY pid=\(getpid()) window=\(window.windowNumber) "
                + "width=\(window.frame.width) "
                + "height=\(window.frame.height)"
        )
        fflush(stdout)
        let control = M5BetaV09RLCCVisualControl(
            root: root,
            application: application,
            controller: controller
        )
        let timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: control,
            selector:
                #selector(M5BetaV09RLCCVisualControl.poll),
            userInfo: nil,
            repeats: true
        )
        application.run()
        timer.invalidate()
        return 0
    }

    private static func makeBetaV09RLCCVisualInventory(
        root: String,
        repositoryCount: Int = 1
    ) throws -> RepositoryInventory {
        func identity(_ inode: UInt64)
            throws -> RepositoryDirectoryIdentity {
            let data = try JSONSerialization.data(
                withJSONObject: ["device": 1, "inode": inode]
            )
            return try JSONDecoder().decode(
                RepositoryDirectoryIdentity.self,
                from: data
            )
        }
        let repositoryID = "kleinperkins/visual-layout"
        let origin =
            "https://github.com/\(repositoryID).git"
        let source = RepositoryCandidate(
            id: repositoryID,
            displayName: "Visual layout",
            path: root + "/visual-layout",
            rawOrigin: origin,
            presentationLocation:
                "~/dev/testing/visual-layout",
            rootIdentity: try identity(9_001),
            gitDirectoryIdentity: try identity(9_002),
            commonDirectoryIdentity: try identity(9_002)
        )
        let seed = try LocalClone(
            repositoryID: repositoryID,
            sourceSnapshot: source,
            effectiveOrigin: origin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: [],
            branches: [],
            warnings: []
        )
        let cloneID = seed.id
        let mainOID = String(repeating: "a", count: 40)
        let featureOID = String(repeating: "b", count: 40)
        let primaryID = "worktree:visual-primary"
        let featureID = "worktree:visual-feature"
        let clean = WorktreeFileState(
            trackedChanges: 0,
            untrackedFiles: 0,
            ignoredFiles: 0,
            hiddenIndexState: false,
            operationState: .clear
        )
        let fulfilled = PurposeAssessment(
            purpose: .integrated,
            exactAssociations: [],
            allCandidates: [],
            explanation:
                "Independent local ancestry proves this work is integrated."
        )
        let primary = try Worktree(
            id: primaryID,
            cloneID: cloneID,
            path: root + "/visual-layout",
            rootIdentity: try identity(9_003),
            registrationIdentity: nil,
            attachedBranchRef: "refs/heads/main",
            detachedOID: nil,
            isPrimary: true,
            locationKind: .canonicalPrimary,
            cleanliness: .clean,
            fileState: clean
        )
        let worktreePreview =
            RemovalPreviewOracle.worktree(
                isResolvedDefaultClaim: false,
                policyCategory: .writable,
                verification: .verified,
                fileState: clean,
                awa: .notManaged,
                purpose: .integrated,
                activity: .staleCandidate,
                branchTipPreserved: true
            )
        let feature = try Worktree(
            id: featureID,
            cloneID: cloneID,
            path:
                root
                    + "/agent/controller-v0130-ai-analytics-context-20260921t2220",
            rootIdentity: try identity(9_004),
            registrationIdentity: try identity(9_005),
            attachedBranchRef:
                "refs/heads/agent/controller-v0130-ai-analytics-context-20260921t2220",
            detachedOID: nil,
            isPrimary: false,
            locationKind: .awaManaged,
            cleanliness: .clean,
            fileState: clean,
            relationToDefault: DefaultBranchRelation(
                kind: .equal,
                aheadCount: 0,
                behindCount: 0
            ),
            tipCommitDate: "2026-08-01T12:00:00Z",
            awaEvidence: .notManaged,
            purpose: fulfilled,
            activity: .staleCandidate,
            currentSession: false,
            removalPreview: worktreePreview
        )
        let main = try Branch(
            cloneID: cloneID,
            fullRef: "refs/heads/main",
            tipOID: mainOID,
            claimingWorktreeIDs: [primaryID]
        )
        let attachedPreview = RemovalPreviewOracle.branch(
            isResolvedDefault: false,
            policyCategory: .writable,
            claimIDs: [featureID],
            purpose: .integrated,
            activity: .staleCandidate,
            tipPreserved: true
        )
        let attached = try Branch(
            cloneID: cloneID,
            fullRef:
                "refs/heads/agent/controller-v0130-ai-analytics-context-20260921t2220",
            tipOID: featureOID,
            claimingWorktreeIDs: [featureID],
            relationToDefault: DefaultBranchRelation(
                kind: .equal,
                aheadCount: 0,
                behindCount: 0
            ),
            upstream: BranchUpstream(
                fullRef:
                    "refs/remotes/origin/agent/controller-v0130-ai-analytics-context-20260921t2220",
                localOID: featureOID,
                upstreamOID: featureOID,
                relation: .equal,
                aheadCount: 0,
                behindCount: 0
            ),
            commitDate: "2026-08-01T12:00:00Z",
            pullRequests: [],
            pullRequestAvailability: .available,
            purpose: fulfilled,
            activity: .staleCandidate,
            removalPreview: attachedPreview
        )
        let standalonePreview = RemovalPreview(
            recommendation: .recovery,
            permission: .previewOnly,
            explanation:
                "Purpose appears fulfilled; unique history needs a recovery artifact before removal.",
            recoveryConsequence:
                "Create a protected recovery copy before removal."
        )
        let standalone = try Branch(
            cloneID: cloneID,
            fullRef:
                "refs/heads/chore/pr-automation-v0130-policy",
            tipOID: String(repeating: "c", count: 40),
            claimingWorktreeIDs: [],
            relationToDefault: DefaultBranchRelation(
                kind: .ahead,
                aheadCount: 2,
                behindCount: 0
            ),
            commitDate: "2026-07-01T12:00:00Z",
            pullRequests: [],
            pullRequestAvailability: .available,
            purpose: PurposeAssessment(
                purpose: .completed,
                exactAssociations: [],
                allCandidates: [],
                explanation:
                    "A completed pull request identifies fulfilled work."
            ),
            activity: .staleCandidate,
            removalPreview: standalonePreview
        )
        let clone = try LocalClone(
            repositoryID: repositoryID,
            sourceSnapshot: source,
            effectiveOrigin: origin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: [primary, feature],
            branches: [main, attached, standalone],
            warnings: []
        )
        let repository = try RemoteRepository(
            id: repositoryID,
            origins: [origin],
            policyCategory: .writable,
            resolvedDefault: try RemoteDefaultBranch(
                name: "main",
                advertisedOID: mainOID
            ),
            defaultUnavailableReason: nil
        )
        let card = try RepositoryCard(
            repository: repository,
            authority: CanonicalAuthorityState(
                status: .missing,
                record: nil,
                explanation: "Visual fixture authority."
            ),
            clones: [clone],
            relation: DefaultBranchRelation(
                kind: .equal,
                aheadCount: 0,
                behindCount: 0
            ),
            fastForward: nil,
            fastForwardRefusal:
                "No operation is selectable in this visual fixture.",
            originHeadExplanation: nil
        )
        var cards = [card]
        if repositoryCount > 1 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let encoded = try encoder.encode(card)
            guard let sourceJSON = String(
                data: encoded,
                encoding: .utf8
            ) else {
                throw M5HarnessError.message(
                    "v0.9 progress fixture encoding failed"
                )
            }
            for index in 2...repositoryCount {
                let nextName = "visual-layout-\(index)"
                guard let data = sourceJSON
                    .replacingOccurrences(
                        of: "visual-layout",
                        with: nextName
                    ).data(using: .utf8) else {
                    throw M5HarnessError.message(
                        "v0.9 progress fixture rewrite failed"
                    )
                }
                cards.append(
                    try JSONDecoder().decode(
                        RepositoryCard.self,
                        from: data
                    )
                )
            }
        }
        return RepositoryInventory(
            cards: cards,
            onboardingProposals: [],
            authorityFileIdentity: nil
        )
    }

    private static func runBetaRecutVisualHost(
        root: String
    ) throws -> Int32 {
        if let mode = ProcessInfo.processInfo.environment["SHADOW_SYNC_VISUAL_CATALOG"],
           mode != "fixture" {
            throw M5HarnessError.message("visual catalog requires disposable fixtures")
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let catalog = try RepositorySelectionCatalogResult.testingV02Chooser(
            canonicalResolved: true,
            defaultSelected: true
        )
        let chooser = RepositoryChooserWindowController(
            catalog: catalog,
            preferenceSnapshot: .testingAbsent
        )
        chooser.onSaveDefaults = { [weak chooser] _ in
            chooser?.showSaveOutcome("Defaults saved.")
        }
        chooser.showWindow(nil)
        chooser.prepareForPresentation()
        chooser.window?.makeKeyAndOrderFront(nil)
        chooser.window?.orderFrontRegardless()
        guard let window = chooser.window else {
            throw M5HarnessError.message(
                "visual host chooser window is missing"
            )
        }
        print(
            "READY pid=\(getpid()) window=\(window.windowNumber) "
                + "width=\(window.frame.width) "
                + "height=\(window.frame.height)"
        )
        fflush(stdout)
        chooser.testingDidEnterFullScreen = { windowNumber in
            print("FULLSCREEN window=\(windowNumber)")
            fflush(stdout)
        }
        chooser.testingDidExitFullScreen = { windowNumber in
            print("RESTORED window=\(windowNumber)")
            fflush(stdout)
        }
        let control = M5BetaRecutVisualControl(
            root: root,
            application: application,
            window: window,
            chooser: chooser
        )
        let timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: control,
            selector: #selector(M5BetaRecutVisualControl.poll),
            userInfo: nil,
            repeats: true
        )
        application.run()
        timer.invalidate()
        chooser.close()
        return 0
    }

    private static func runBetaV06ResultsVisualHost(
        root: String
    ) throws -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let run = RunIdentity.make()
        let repositories = [
            "fixture/alpha",
            "fixture/alpha",
            "fixture/bravo",
            "fixture/bravo",
            "fixture/charlie",
            "fixture/charlie",
        ]
        let nodes = try repositories.enumerated().map {
            index, repository in
            try Body3BatchNode(
                id:
                    "body3-node:policyInvalidation:visual-\(index)",
                repositoryID: repository,
                commonDirectoryKey: "clone:visual-\(index)",
                kind: .policyInvalidation,
                dependencies: [],
                payload: .policyInvalidation(
                    repositoryID: repository
                ),
                requiresExclusiveWorkerPool: true
            )
        }
        let start = "2026-10-05T20:00:00.000Z"
        let end = "2026-10-05T20:00:04.250Z"
        let plan = try Body3BatchPlan(
            run: run,
            createdAt: start,
            policyEvidenceDigest:
                String(repeating: "a", count: 64),
            nodes: nodes
        )
        let statuses: [Body3BatchNodeStatus] = [
            .succeeded, .succeeded,
            .refused, .skipped,
            .cancelled, .skipped,
        ]
        let details = [
            "Fresh repository evidence passed.",
            "Repository policy stayed unchanged.",
            "The expected repository identity changed; no mutation was admitted.",
            "A prerequisite refused safely.",
            "Cancelled before admission; existing state was preserved.",
            "A prerequisite did not complete.",
        ]
        let results = nodes.enumerated().map {
            index, node in
            Body3BatchNodeResult(
                node: node,
                status: statuses[index],
                worker: index < 2 ? index + 1 : nil,
                startedAt: index < 2 ? start : nil,
                endedAt: end,
                durationMilliseconds:
                    index < 2 ? 4_250 : 0,
                detail: details[index],
                technicalDetail:
                    index == 2
                        ? "identity evidence changed at "
                            + "/" + "Users/operator/private"
                        : nil
            )
        }
        let report = try Body3BatchReport(
            run: run,
            startedAt: start,
            endedAt: end,
            cancelled: true,
            results: results
        )
        let controller = Body3RunWindowController(
            plan: plan
        )
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        guard let window = controller.window else {
            throw M5HarnessError.message(
                "v0.6 result visual window is missing"
            )
        }
        application.activate()
        print(
            "READY pid=\(getpid()) window=\(window.windowNumber) "
                + "width=\(window.frame.width) "
                + "height=\(window.frame.height)"
        )
        fflush(stdout)
        let control = M5BetaV06ResultsVisualControl(
            root: root,
            application: application,
            plan: plan,
            report: report,
            controller: controller
        )
        let timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: control,
            selector:
                #selector(M5BetaV06ResultsVisualControl.poll),
            userInfo: nil,
            repeats: true
        )
        application.run()
        timer.invalidate()
        return 0
    }

    private static func validate(
        schema: String,
        expectedSchema: String,
        root: String
    ) throws -> String {
        guard schema == expectedSchema else {
            throw M5HarnessError.message("the M5 request schema is invalid")
        }
        let fixtureRoot = try TestIsolation.validateRoot(root)
        // These legacy probe entrypoints need the same explicit fixture setup
        // as the isolated UI suites before exercising ordinary app admission.
        try TestIsolation.initializeState(at: StateLocation.isolated(root: fixtureRoot))
        return fixtureRoot
    }

    // Stable compiled inventory. Each suite executes once in its own application
    // process in CI, so AppKit's animation pool cannot starve another suite.
    // Physical interaction/animation UAT remains separately required.
    private static let nativeUIInventory = NativeUIInventory(
        suites: [
            NativeUISuiteDefinition(id: "secure-log-core", checks: [], diagnostic_only: [], core_tests: ["m5-secure-log-open-success", "m5-secure-log-open-refusals", "m5-secure-log-open-identity-change", "m5-secure-log-open-default-app-failure"]),
            NativeUISuiteDefinition(id: "exact-copy", checks: ["exactCopySnapshots"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "taxonomy", checks: ["resultTaxonomyAndTransitions"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "reducer-transactions", checks: ["reducerReportTransactions"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "controller-transactions", checks: ["controllerReportTransactions"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "stopping-overlay", checks: ["stoppingOverlayRaces"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "stopping-controller", checks: ["stoppingControllerRaces"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "sealed-presentation", checks: ["sealedPresentationRaces"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "operation-contention", checks: ["operationContentionLifecycle"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "historical-viewer", checks: ["historicalViewerLifecycleIsolation"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "body3-session", checks: ["body3CorrectiveSessionOwnership"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "origin-presentation", checks: ["originIdentityPresentation"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "routing", checks: ["deterministicRouting"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "foreground", checks: ["foregroundTransactions"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "report-reopen", checks: ["partialAndFinalReopen"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "secure-log-feedback", checks: ["secureLogFeedback"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "report-summaries", checks: ["mixedAndCancelledReports"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "m4-row-progress", checks: ["m4ThreeRowProgress"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "m4-stop-lifecycle", checks: ["m4StopLifecycle"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "m4-controller-stop", checks: ["m4ControllerStopRaces"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "m4-worker-stop", checks: ["m4WorkerStopSingleFlight"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "m4-takeover", checks: ["m4TakeoverTransition"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "worker-owner-ordering", checks: ["workerOwnerSignalReapOrdering"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "worker-owner-refusal", checks: ["workerOwnerFailedCustodyRefusal"], diagnostic_only: [], core_tests: []),
            NativeUISuiteDefinition(id: "native-rows", checks: ["orderedNativeRows", "constantTimeRowMutation", "nativeRowsFocus", "nativeRowsAdaptive", "nativeRowsAccessibility"], diagnostic_only: ["nativeRowsAccessibility"], core_tests: []),
            NativeUISuiteDefinition(id: "selection", checks: ["selectionStates", "selectionFocus", "selectionAdaptive", "selectionAccessibility"], diagnostic_only: ["selectionAccessibility"], core_tests: []),
            NativeUISuiteDefinition(id: "confirmation-close", checks: ["closeClearsSession", "retryStartsRun", "hiddenCardRemainsOpen", "reactivationReusesCard", "hiddenOnboardingRemainsOpen", "onboardingReactivationReuses", "dismissedCanonicalRootCommitStaysClosed", "savedCanonicalRootRefreshFailureRecovers", "dismissedSavedCanonicalRootReconciles", "concurrentCanonicalRootCommitIsRejected", "discoveryActivationShowsProgress", "discoveryActivationPresentsOnce", "onboardingFailurePreservesOnboarding", "dismissedFailureReportsAndReconciles"], diagnostic_only: [], core_tests: [])
        ],
        legacy_assertions: [
            "exactCopySnapshots": ["exactCopySnapshots"],
            "resultTaxonomyAndTransitions": ["resultTaxonomyAndTransitions"],
            "reducerReportTransactions": ["reducerReportTransactions"],
            "workerOwnerSignalReapOrdering": ["workerOwnerSignalReapOrdering"],
            "workerOwnerFailedCustodyRefusal": ["workerOwnerFailedCustodyRefusal"],
            "controllerReportTransactions": ["controllerReportTransactions"],
            "stoppingOverlayRaces": ["stoppingOverlayRaces"],
            "stoppingControllerRaces": ["stoppingControllerRaces"],
            "sealedPresentationRaces": ["sealedPresentationRaces"],
            "operationContentionLifecycle": ["operationContentionLifecycle"],
            "historicalViewerLifecycleIsolation": ["historicalViewerLifecycleIsolation"],
            "body3CorrectiveSessionOwnership": ["body3CorrectiveSessionOwnership"],
            "originIdentityPresentation": ["originIdentityPresentation"],
            "orderedNativeRows": ["orderedNativeRows"],
            "constantTimeRowMutation": ["constantTimeRowMutation"],
            "selectionStates": ["selectionStates"],
            "routeStateMatrix": ["deterministicRouting", "closeClearsSession", "retryStartsRun", "hiddenCardRemainsOpen", "reactivationReusesCard", "hiddenOnboardingRemainsOpen", "onboardingReactivationReuses", "dismissedCanonicalRootCommitStaysClosed", "savedCanonicalRootRefreshFailureRecovers", "dismissedSavedCanonicalRootReconciles", "concurrentCanonicalRootCommitIsRejected", "discoveryActivationShowsProgress", "discoveryActivationPresentsOnce", "onboardingFailurePreservesOnboarding", "dismissedFailureReportsAndReconciles", "foregroundTransactions"],
            "partialAndFinalReopen": ["partialAndFinalReopen"],
            "secureLogFeedback": ["secureLogFeedback"],
            "focusAndAlertSafety": ["exactCopySnapshots", "selectionFocus", "nativeRowsFocus"],
            "accessibilitySemantics": ["selectionAccessibility", "nativeRowsAccessibility"],
            "adaptiveSemanticLayout": ["selectionAdaptive", "nativeRowsAdaptive"],
            "mixedAndCancelledReports": ["mixedAndCancelledReports"]
        ],
        lifecycle_checks: ["m4ThreeRowProgress", "m4StopLifecycle", "m4ControllerStopRaces", "m4WorkerStopSingleFlight", "m4TakeoverTransition"],
        core_tests: ["m5-secure-log-open-success", "m5-secure-log-open-refusals", "m5-secure-log-open-identity-change", "m5-secure-log-open-default-app-failure"]
    )

    private static func runNativeUISuite(_ id: String, root: String) throws -> NativeUISuiteResult {
        guard let definition = nativeUIInventory.suites.first(where: { $0.id == id }) else {
            throw M5HarnessError.message("Unknown native UI suite")
        }
        try TestIsolation.initializeState(at: StateLocation.isolated(root: root))
        var checks: [String: Bool] = [:]
        var coreTests: [String] = []
        switch id {
        case "secure-log-core":
            coreTests = try M5SelfTestRunner.runAll(testRoot: root)
        case "exact-copy":
            checks["exactCopySnapshots"] = try testExactCopy(root: root)
        case "taxonomy":
            checks["resultTaxonomyAndTransitions"] = try testTaxonomyAndTransitions(root: root)
        case "reducer-transactions":
            checks["reducerReportTransactions"] = try testReducerReportTransactions(root: root)
        case "controller-transactions":
            checks["controllerReportTransactions"] = ShadowSyncAppDelegate.testReportTransactionsAreAtomic(root: root)
        case "stopping-overlay":
            checks["stoppingOverlayRaces"] = try testStoppingOverlayRaces(root: root)
        case "stopping-controller":
            checks["stoppingControllerRaces"] = ShadowSyncAppDelegate.testStoppingOverlayControllerRaces(root: root)
        case "sealed-presentation":
            checks["sealedPresentationRaces"] = ShadowSyncAppDelegate.testSealedPresentationRaces(root: root)
        case "operation-contention":
            checks["operationContentionLifecycle"] = try testOperationContentionLifecycle(root: root)
        case "historical-viewer":
            checks["historicalViewerLifecycleIsolation"] = try testHistoricalViewerLifecycleIsolation(root: root)
        case "body3-session":
            checks["body3CorrectiveSessionOwnership"] = try testBody3CorrectiveSessionOwnership(root: root)
        case "origin-presentation":
            checks["originIdentityPresentation"] = try testOriginIdentityPresentation(root: root)
        case "routing":
            checks["deterministicRouting"] = try testRouting(root: root)
        case "foreground":
            checks["foregroundTransactions"] = testForegroundRequestTransactions(root: root)
        case "report-reopen":
            checks["partialAndFinalReopen"] = try testReportReopen(root: root)
        case "secure-log-feedback":
            checks["secureLogFeedback"] = try testSecureLogFeedback(root: root)
        case "report-summaries":
            checks["mixedAndCancelledReports"] = try testReportSummaries(root: root)
        case "m4-row-progress":
            checks["m4ThreeRowProgress"] = ShadowSyncAppDelegate.testThreeRowProgressIsCoherent()
        case "m4-stop-lifecycle":
            checks["m4StopLifecycle"] = ShadowSyncAppDelegate.testStopLifecycleStateIsCoherent()
        case "m4-controller-stop":
            checks["m4ControllerStopRaces"] = ShadowSyncAppDelegate.testControllerStopRaces(candidate: makeCandidates(count: 1, root: root + "/lifecycle")[0])
        case "m4-worker-stop":
            checks["m4WorkerStopSingleFlight"] = ShadowSyncAppDelegate.testWorkerStopSingleFlight(root: root)
        case "m4-takeover":
            checks["m4TakeoverTransition"] = ShadowSyncAppDelegate.testTakeoverTransitionIsCoherent(root: root)
        case "worker-owner-ordering":
            checks["workerOwnerSignalReapOrdering"] = WorkerOwnerOrderingFixtures.signalReapOrdering(root: root)
        case "worker-owner-refusal":
            checks["workerOwnerFailedCustodyRefusal"] = WorkerOwnerOrderingFixtures.failedCustody(root: root)
        case "native-rows":
            let result = try testNativeRows(root: root)
            checks = ["orderedNativeRows": result.ordered, "constantTimeRowMutation": result.constantTime,
                      "nativeRowsFocus": result.focus, "nativeRowsAdaptive": result.adaptive,
                      "nativeRowsAccessibility": result.accessibility]
        case "selection":
            let result = try testSelectionAndAccessibility(root: root)
            checks = ["selectionStates": result.states, "selectionFocus": result.focus,
                      "selectionAdaptive": result.adaptive, "selectionAccessibility": result.accessibility]
        case "confirmation-close":
            let result = try runConfirmationCloseRegression(root: root)
            checks["closeClearsSession"] = result.closeClearsSession
            checks["retryStartsRun"] = result.retryStartsRun
            checks["hiddenCardRemainsOpen"] = result.hiddenCardRemainsOpen
            checks["reactivationReusesCard"] = result.reactivationReusesCard
            checks["hiddenOnboardingRemainsOpen"] = result.hiddenOnboardingRemainsOpen
            checks["onboardingReactivationReuses"] = result.onboardingReactivationReuses
            checks["dismissedCanonicalRootCommitStaysClosed"] = result.dismissedCanonicalRootCommitStaysClosed
            checks["savedCanonicalRootRefreshFailureRecovers"] = result.savedCanonicalRootRefreshFailureRecovers
            checks["dismissedSavedCanonicalRootReconciles"] = result.dismissedSavedCanonicalRootReconciles
            checks["concurrentCanonicalRootCommitIsRejected"] = result.concurrentCanonicalRootCommitIsRejected
            checks["discoveryActivationShowsProgress"] = result.discoveryActivationShowsProgress
            checks["discoveryActivationPresentsOnce"] = result.discoveryActivationPresentsOnce
            checks["onboardingFailurePreservesOnboarding"] = result.onboardingFailurePreservesOnboarding
            checks["dismissedFailureReportsAndReconciles"] = result.dismissedFailureReportsAndReconciles

        default: throw M5HarnessError.message("Unknown native UI suite")
        }
        guard Set(checks.keys) == Set(definition.checks), coreTests == definition.core_tests else {
            throw M5HarnessError.message("Incomplete native UI suite")
        }
        let failed = checks.filter { !definition.diagnostic_only.contains($0.key) && !$0.value }.keys.sorted()
        guard failed.isEmpty else {
            throw M5HarnessError.message("Native UI suite \(id) failed: \(failed.joined(separator: ", "))")
        }
        return NativeUISuiteResult(suite: id, checks: checks, coreTests: coreTests)
    }

    private static func runUITests(root: String) throws -> M5UIResponse {
        // Compatibility route shares the exact bodies and complete roster.
        // The canonical CI runner uses fresh processes for these same suites.
        var checks: [String: Bool] = [:]
        var coreTests: [String] = []
        for definition in nativeUIInventory.suites {
            let result = try runNativeUISuite(definition.id, root: root)
            for (name, value) in result.checks {
                guard checks.updateValue(value, forKey: name) == nil else {
                    throw M5HarnessError.message("Duplicate native UI result")
                }
            }
            coreTests += result.coreTests
        }
        guard coreTests == nativeUIInventory.core_tests,
              nativeUIInventory.lifecycle_checks.allSatisfy({ checks[$0] == true }) else {
            throw M5HarnessError.message("Incomplete native UI lifecycle/core results")
        }
        func combined(_ name: String) throws -> Bool {
            guard let components = nativeUIInventory.legacy_assertions[name],
                  !components.isEmpty, components.allSatisfy({ checks[$0] != nil }) else {
                throw M5HarnessError.message("Missing native UI assertion component")
            }
            return components.allSatisfy { checks[$0] == true }
        }
        return try M5UIResponse(
            coreTests: coreTests,
            exactCopySnapshots: combined("exactCopySnapshots"),
            resultTaxonomyAndTransitions: combined("resultTaxonomyAndTransitions"),
            reducerReportTransactions: combined("reducerReportTransactions"),
            workerOwnerSignalReapOrdering: combined("workerOwnerSignalReapOrdering"),
            workerOwnerFailedCustodyRefusal: combined("workerOwnerFailedCustodyRefusal"),
            controllerReportTransactions: combined("controllerReportTransactions"),
            stoppingOverlayRaces: combined("stoppingOverlayRaces"),
            stoppingControllerRaces: combined("stoppingControllerRaces"),
            sealedPresentationRaces: combined("sealedPresentationRaces"),
            operationContentionLifecycle: combined("operationContentionLifecycle"),
            historicalViewerLifecycleIsolation: combined("historicalViewerLifecycleIsolation"),
            body3CorrectiveSessionOwnership: combined("body3CorrectiveSessionOwnership"),
            originIdentityPresentation: combined("originIdentityPresentation"),
            orderedNativeRows: combined("orderedNativeRows"),
            constantTimeRowMutation: combined("constantTimeRowMutation"),
            selectionStates: combined("selectionStates"),
            routeStateMatrix: combined("routeStateMatrix"),
            partialAndFinalReopen: combined("partialAndFinalReopen"),
            secureLogFeedback: combined("secureLogFeedback"),
            focusAndAlertSafety: combined("focusAndAlertSafety"),
            accessibilitySemantics: combined("accessibilitySemantics"),
            adaptiveSemanticLayout: combined("adaptiveSemanticLayout"),
            mixedAndCancelledReports: combined("mixedAndCancelledReports")
        )
    }

    private static func runPracticalUITests(
        root: String
    ) throws -> M5PracticalUIResponse {
        let result = try testSelectionAndAccessibility(root: root)
        let recut = try testBetaRecutMenuAndChooser(root: root)
        let v02 = try testBetaV02Chooser(root: root)
        let response = M5PracticalUIResponse(
            disabledRowsAndReasons: result.disabledRowsAndReasons,
            eligibleBlockedCounts: result.eligibleBlockedCounts,
            selectionExcludesBlocked: result.states,
            keyboardExcludesBlocked: result.focus && result.accessibility,
            reviewExcludesBlocked: result.reviewExcludesBlocked,
            runRowsShowCompactLocation: result.runRowsShowCompactLocation,
            menuLabelsAndShortcut: recut.menu,
            chooserInitialAndRestoredGeometry: recut.geometry,
            chooserBothAxisResize: recut.resize,
            chooserZoomAndFullScreen: recut.zoomAndFullScreen,
            menuShortcutFlowEquivalence: recut.routing,
            originRowsConsolidated: v02.consolidated,
            canonicalChoiceRequiredWhenSelected:
                v02.canonicalRequired,
            canonicalChoiceIndependentFromDefaults:
                v02.canonicalIndependent,
            validSaveReopenAndContinue:
                v02.saveReopenContinue,
            statusSectionsCollapsed: v02.sectionsCollapsed
        )
        let mirror = Mirror(reflecting: response)
        let failed = mirror.children.compactMap { child -> String? in
            guard let value = child.value as? Bool,
                  !value else {
                return nil
            }
            return child.label ?? "unknown"
        }
        guard failed.isEmpty else {
            throw M5HarnessError.message(
                "practical selection UI assertions failed: "
                    + failed.joined(separator: ", ")
            )
        }
        return response
    }

    private static func testBetaRecutMenuAndChooser(
        root: String
    ) throws -> (
        menu: Bool,
        geometry: Bool,
        resize: Bool,
        zoomAndFullScreen: Bool,
        routing: Bool
    ) {
        let chooser = RepositoryChooserWindowController(
            catalog: try .testingChooser(rowCount: 20),
            preferenceSnapshot: .testingAbsent
        )
        chooser.showWindow(nil)
        chooser.window?.layoutIfNeeded()
        let initial = chooser.testingNativeGeometrySnapshot
        let invalid = chooser.testingApplyFrame(
            NSRect(
                x: initial.frame.origin.x,
                y: initial.frame.origin.y,
                width: 38,
                height: 72
            )
        )
        let horizontal = chooser.testingApplyFrame(
            NSRect(
                origin: invalid.origin,
                size: NSSize(
                    width: initial.minimum.width + 180,
                    height: initial.minimum.height
                )
            )
        )
        let vertical = chooser.testingApplyFrame(
            NSRect(
                origin: horizontal.origin,
                size: NSSize(
                    width: horizontal.width,
                    height: initial.minimum.height + 180
                )
            )
        )
        let zoom = chooser.testingStandardZoomFrame()

        let candidates = makeCandidates(
            count: 2,
            root: root + "/beta-recut"
        )
        let delegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "beta-recut-transport"
            ),
            shortcutAvailable: true
        )
        let menuItems = delegate.testMenuItems()
        let start = menuItems.first {
            $0.title == ShadowSyncPresentation.startNewRun
        }
        let quit = menuItems.first {
            $0.title == ShadowSyncPresentation.quitUtility
        }
        let chord: NSEvent.ModifierFlags = [
            .control, .option, .command,
        ]
        let menu = start?.keyEquivalent == "m"
            && start?.modifierMask.intersection(
                .deviceIndependentFlagsMask
            ) == chord
            && quit?.title == "Quit ShadowSync"
            && quit?.keyEquivalent == "q"

        delegate.testStartNewRun()
        let selectionIdentity =
            delegate.testSelectionControllerIdentity
        let windowNumber =
            delegate.testingSelectionWindowState?.number
        delegate.testingHideSelectionWindow()
        delegate.testingTriggerShortcut()
        let shortcutReused =
            delegate.testSelectionControllerIdentity
                == selectionIdentity
            && delegate.testingSelectionWindowState?.number
                == windowNumber
            && delegate.testingSelectionWindowState?.visible
                == true
        delegate.testingHideSelectionWindow()
        delegate.testingTriggerMenuStart()
        let deadline = MonotonicDeadline(seconds: 0.25)
        while !deadline.hasExpired {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        let menuReused =
            delegate.testSelectionControllerIdentity
                == selectionIdentity
            && delegate.testingSelectionWindowState?.number
                == windowNumber
            && delegate.testingSelectionWindowState?.visible
                == true

        let geometry = initial.frame.width
                >= initial.minimum.width
            && initial.frame.height >= initial.minimum.height
            && invalid.width >= initial.minimum.width
            && invalid.height >= initial.minimum.height
            && initial.minimum == NSSize(width: 640, height: 460)
            && initial.contentMinimum.width > 0
            && initial.contentMinimum.height > 0
        let resize =
            abs(
                horizontal.width
                    - (initial.minimum.width + 180)
            ) < 1
            && abs(horizontal.height - initial.minimum.height) < 1
            && abs(vertical.width - horizontal.width) < 1
            && abs(
                vertical.height
                    - (initial.minimum.height + 180)
            ) < 1
        let zoomAndFullScreen =
            initial.resizable
            && initial.miniaturizable
            && initial.fullScreenPrimary
            && initial.zoomEnabled
            && zoom.width >= initial.minimum.width
            && zoom.height >= initial.minimum.height

        chooser.close()
        return (
            menu,
            geometry,
            resize,
            zoomAndFullScreen,
            shortcutReused && menuReused
        )
    }

    private static func testBetaV02Chooser(
        root: String
    ) throws -> (
        consolidated: Bool,
        canonicalRequired: Bool,
        canonicalIndependent: Bool,
        saveReopenContinue: Bool,
        sectionsCollapsed: Bool
    ) {
        let unresolvedCatalog =
            try RepositorySelectionCatalogResult
                .testingV02Chooser()
        guard let unresolvedRow =
                unresolvedCatalog.catalog.candidates.first(where: {
                    $0.id == "fixture/duplicate"
                }) else {
            throw M5HarnessError.message(
                "v0.2 duplicate-origin row is missing"
            )
        }
        let unresolved = RepositoryChooserWindowController(
            catalog: unresolvedCatalog,
            preferenceSnapshot: .testingAbsent
        )
        var canonicalSelections:
            [RepositorySelectionAlternative] = []
        var prematureDefaults:
            [RepositorySelectionPreferenceEntry]?
        unresolved.onCanonicalRootChange = { _, alternative in
            canonicalSelections.append(alternative)
        }
        unresolved.onSaveDefaults = {
            prematureDefaults = $0
        }
        unresolved.testingSelect(
            repositoryID: unresolvedRow.id
        )
        let canonicalRequired =
            !unresolved.testingCanContinue
            && !unresolved.testingCanSave
            && unresolved.testingStatus.contains(
                "Choose a canonical primary checkout"
            )
        unresolved.testingChooseCanonical(
            repositoryID: unresolvedRow.id,
            index: 1
        )
        let canonicalIndependent =
            canonicalSelections.count == 1
            && canonicalSelections[0]
                == unresolvedRow.alternatives[1]
            && prematureDefaults == nil
        let sectionsCollapsed =
            unresolved.testingCollapsedSectionCount == 1
        unresolved.close()

        let resolvedCatalog =
            try RepositorySelectionCatalogResult
                .testingV02Chooser(canonicalResolved: true)
        let resolved = RepositoryChooserWindowController(
            catalog: resolvedCatalog,
            preferenceSnapshot: .testingAbsent
        )
        var savedEntries:
            [RepositorySelectionPreferenceEntry] = []
        var continuedEntries:
            [RepositorySelectionPreferenceEntry] = []
        resolved.onSaveDefaults = { savedEntries = $0 }
        resolved.onContinue = { continuedEntries = $0 }
        resolved.testingSelect(
            repositoryID: "fixture/duplicate"
        )
        resolved.testingSave()
        resolved.testingContinue()
        let location = try StateLocation.isolated(
            root: root
        )
        try TestIsolation.initializeState(at: location)
        let store = try RepositorySelectionPreferenceStore.open(
            at: location
        )
        _ = try store.save(
            entries: savedEntries,
            expected: store.snapshot()
        )
        let saved = store.snapshot()
        let reopened = RepositoryChooserWindowController(
            catalog: try .testingV02Chooser(
                canonicalResolved: true,
                defaultSelected: true
            ),
            preferenceSnapshot: saved,
            initialSavedEntries: Set(
                saved.document?.entries ?? []
            )
        )
        let saveReopenContinue =
            saved.status == .available
            && saved.document?.entries.count == 1
            && saved.document?.entries.first?.repositoryID
                == "fixture/duplicate"
            && continuedEntries.count == 1
            && continuedEntries.first?.repositoryID
                == "fixture/duplicate"
            && resolved.testingStatus
                != "Selected repositories changed. Reload before continuing."
            && reopened.testingSelectedCount == 1
            && reopened.testingCanContinue
        resolved.close()
        reopened.close()
        return (
            unresolvedCatalog.catalog.candidates.count == 2
                && unresolvedRow.alternatives.count == 2,
            canonicalRequired,
            canonicalIndependent,
            saveReopenContinue,
            sectionsCollapsed
        )
    }

    private static func runStatusItemGuidanceTests(
        root: String
    ) throws -> M5StatusItemGuidanceResponse {
        let visible = StatusItemVisibilitySnapshot(
            apiVisible: true,
            hasButton: true,
            hasWindow: true,
            hasAvailableScreen: true,
            windowIsOnScreen: true
        )
        let hiddenByAPI = StatusItemVisibilitySnapshot(
            apiVisible: false,
            hasButton: true,
            hasWindow: true,
            hasAvailableScreen: true,
            windowIsOnScreen: true
        )
        let hiddenByGeometry = StatusItemVisibilitySnapshot(
            apiVisible: true,
            hasButton: true,
            hasWindow: true,
            hasAvailableScreen: true,
            windowIsOnScreen: false
        )
        let inconclusive = [
            StatusItemVisibilitySnapshot(
                apiVisible: true,
                hasButton: false,
                hasWindow: false,
                hasAvailableScreen: true,
                windowIsOnScreen: false
            ),
            StatusItemVisibilitySnapshot(
                apiVisible: true,
                hasButton: true,
                hasWindow: true,
                hasAvailableScreen: false,
                windowIsOnScreen: false
            ),
        ]
        let publicVisibilityClassification =
            visible.observation == .visible
            && hiddenByAPI.observation == .hidden
            && hiddenByGeometry.observation == .hidden
            && inconclusive.allSatisfy { $0.observation == .inconclusive }

        let mapping = try makeMapping(
            root: root,
            localName: "m5-status-item-guidance-transport"
        )
        let candidates = makeCandidates(
            count: 1,
            root: root + "/status-item-guidance"
        )

        let delayedDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        delayedDelegate.testStartNewRun()
        let delayedIdentity = delayedDelegate.testSelectionControllerIdentity
        delayedDelegate.testingCompleteStatusItemVisibilityCheck(
            hiddenByGeometry
        )
        let delayedHiddenPresentation =
            delayedDelegate.testStatusItemGuidancePresentationCount == 1
            && delayedDelegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.hiddenStatusItemGuidance
        delayedDelegate.testingTriggerAppReopen()
        delayedDelegate.testingCompleteStatusItemVisibilityCheck(hiddenByAPI)
        let singlePresentation =
            delayedDelegate.testStatusItemGuidancePresentationCount == 1
            && delayedDelegate.testSelectionControllerIdentity == delayedIdentity

        let pendingDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        pendingDelegate.testingCompleteStatusItemVisibilityCheck(
            hiddenByGeometry
        )
        let pendingBeforeWindow =
            pendingDelegate.testStatusItemGuidancePresentationCount == 0
            && !pendingDelegate.testSelectionIsOpen
        pendingDelegate.testingSetCurrentStatusItemVisibilitySnapshot(
            inconclusive[0]
        )
        pendingDelegate.testingTriggerShortcut()
        let pendingUntilWindow =
            pendingBeforeWindow
            && pendingDelegate.testStatusItemGuidancePresentationCount == 1
            && pendingDelegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.hiddenStatusItemGuidance

        let guidanceFirstDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        guidanceFirstDelegate.testStartNewRun()
        guidanceFirstDelegate.testingCompleteStatusItemVisibilityCheck(
            hiddenByGeometry
        )
        guidanceFirstDelegate.testingBeginCurrentForegroundRequest()
        guidanceFirstDelegate.testingResolveForegroundTimeout()
        let guidanceFirstForegroundCopy =
            guidanceFirstDelegate.testingForegroundSnapshot.menu
        let guidanceThenForegroundFailure =
            guidanceFirstDelegate.testStatusItemGuidancePresentationCount == 1
            && guidanceFirstDelegate.testingInlineStatusMessage
                == ShadowSyncPresentation.hiddenStatusItemGuidance
            && guidanceFirstDelegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.hiddenStatusItemGuidance
            && guidanceFirstForegroundCopy?.contains("⌃⌥⌘M") == true
            && guidanceFirstForegroundCopy?.contains("Open the status menu")
                == false
        guidanceFirstDelegate.testingHideSelectionWindow()
        let dismissedGuidanceSnapshot =
            guidanceFirstDelegate.testingForegroundSnapshot
        let dismissClearsOwnedForegroundFailure =
            guidanceFirstDelegate.testStatusItemGuidancePresentationCount == 1
            && guidanceFirstDelegate.testingInlineStatusMessage == nil
            && guidanceFirstDelegate.testingSelectionInlineMessage == nil
            && dismissedGuidanceSnapshot.menu == nil
            && dismissedGuidanceSnapshot.tooltip == nil
            && dismissedGuidanceSnapshot.accessibilityHelp == nil
            && !dismissedGuidanceSnapshot.timedOut

        let unrelatedDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        unrelatedDelegate.testStartNewRun()
        unrelatedDelegate.testingPresentLogOpenFailure()
        unrelatedDelegate.testingBeginCurrentForegroundRequest()
        unrelatedDelegate.testingResolveForegroundTimeout()
        unrelatedDelegate.testingHideSelectionWindow()
        let unrelatedDismissedSnapshot =
            unrelatedDelegate.testingForegroundSnapshot
        let dismissPreservesUnrelatedInlineStatus =
            unrelatedDelegate.testingInlineStatusMessage
                == ShadowSyncPresentation.logOpenFailure
            && unrelatedDelegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.logOpenFailure
            && unrelatedDismissedSnapshot.menu == nil
            && unrelatedDismissedSnapshot.tooltip == nil
            && unrelatedDismissedSnapshot.accessibilityHelp == nil
            && !unrelatedDismissedSnapshot.timedOut

        let ownerDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        let firstOwner = SelectionWindowController(candidates: candidates)
        let nextOwner = SelectionWindowController(candidates: candidates)
        defer {
            ownerDelegate.testingTerminateForegroundObservation()
            ownerDelegate.testingRemoveForegroundStatusItem()
            firstOwner.close()
            nextOwner.close()
        }
        guard ownerDelegate.testingInstallForegroundStatusItem() else {
            throw M5HarnessError.message("foreground ownership status-item fixture unavailable")
        }
        firstOwner.showWindow(nil)
        ownerDelegate.testingInstallSelectionWindow(firstOwner)
        ownerDelegate.testingRequestForeground(
            firstOwner, activationAccepted: false, activeBefore: false
        )
        let firstFailure = ownerDelegate.testingForegroundSnapshot
        ownerDelegate.testingCancelForegroundRequest(nextOwner)
        let unrelatedFailure = ownerDelegate.testingForegroundSnapshot
        let dismissPreservesOtherForegroundOwner =
            firstFailure.menu != nil
            && firstFailure.tooltip == firstFailure.menu
            && firstFailure.accessibilityHelp == firstFailure.menu
            && unrelatedFailure.menu == firstFailure.menu
            && unrelatedFailure.tooltip == firstFailure.tooltip
            && unrelatedFailure.accessibilityHelp == firstFailure.accessibilityHelp
            && unrelatedFailure.failureClears == firstFailure.failureClears
            && ownerDelegate.testingInlineStatusMessage == firstFailure.menu

        nextOwner.showWindow(nil)
        ownerDelegate.testingInstallSelectionWindow(nextOwner)
        ownerDelegate.testingRequestForeground(
            nextOwner, activationAccepted: false, activeBefore: false
        )
        let nextFailure = ownerDelegate.testingForegroundSnapshot
        ownerDelegate.testingCancelForegroundRequest(firstOwner)
        let staleDismissal = ownerDelegate.testingForegroundSnapshot
        let dismissPreservesNewForegroundOwner =
            nextFailure.menu != nil
            && staleDismissal.menu == nextFailure.menu
            && staleDismissal.tooltip == nextFailure.tooltip
            && staleDismissal.accessibilityHelp == nextFailure.accessibilityHelp
            && staleDismissal.failureClears == nextFailure.failureClears
            && ownerDelegate.testingInlineStatusMessage == nextFailure.menu

        let shortcutDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: false
        )
        let shortcutOwner = SelectionWindowController(candidates: candidates)
        defer {
            shortcutDelegate.testingTerminateForegroundObservation()
            shortcutDelegate.testingRemoveForegroundStatusItem()
            shortcutOwner.close()
        }
        guard shortcutDelegate.testingInstallForegroundStatusItem() else {
            throw M5HarnessError.message("shortcut fallback status-item fixture unavailable")
        }
        shortcutOwner.showWindow(nil)
        shortcutDelegate.testingInstallSelectionWindow(shortcutOwner)
        shortcutDelegate.testingRequestForeground(
            shortcutOwner, activationAccepted: false, activeBefore: false
        )
        let shortcutFailure = shortcutDelegate.testingForegroundSnapshot
        shortcutDelegate.testingCancelForegroundRequest(shortcutOwner)
        let shortcutDismissal = shortcutDelegate.testingForegroundSnapshot
        let dismissRestoresShortcutUnavailableHelp =
            shortcutFailure.menu != nil
            && shortcutDismissal.menu == nil
            && shortcutDismissal.tooltip == ShadowSyncPresentation.shortcutUnavailableText
            && shortcutDismissal.accessibilityHelp == ShadowSyncPresentation.shortcutUnavailableText
            && shortcutDismissal.failureClears == shortcutFailure.failureClears + 1

        let failureFirstDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        failureFirstDelegate.testStartNewRun()
        let failureFirstIdentity =
            failureFirstDelegate.testSelectionControllerIdentity
        failureFirstDelegate.testingBeginCurrentForegroundRequest()
        failureFirstDelegate.testingResolveForegroundTimeout()
        failureFirstDelegate.testingCompleteStatusItemVisibilityCheck(
            hiddenByGeometry
        )
        let guidanceWaitedForFailure =
            failureFirstDelegate.testStatusItemGuidancePresentationCount == 0
            && failureFirstDelegate.testingInlineStatusMessage
                == ShadowSyncPresentation.foregroundUnavailable
        failureFirstDelegate.testingReconcileForegroundActivation(
            applicationActive: true,
            foregroundEstablished: true
        )
        let foregroundFailureThenGuidance =
            guidanceWaitedForFailure
            && failureFirstDelegate.testStatusItemGuidancePresentationCount == 1
            && failureFirstDelegate.testingInlineStatusMessage
                == ShadowSyncPresentation.hiddenStatusItemGuidance
            && failureFirstDelegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.hiddenStatusItemGuidance
            && failureFirstDelegate.testingForegroundSnapshot.menu == nil
        failureFirstDelegate.testingReconcileForegroundActivation(
            applicationActive: true,
            foregroundEstablished: true
        )
        failureFirstDelegate.testingHideSelectionWindow()
        failureFirstDelegate.testingTriggerAppReopen()
        let repeatedOrderingNoDuplicate =
            failureFirstDelegate.testStatusItemGuidancePresentationCount == 1
            && failureFirstDelegate.testSelectionControllerIdentity
                == failureFirstIdentity
            && failureFirstDelegate.testingInlineStatusMessage == nil
            && failureFirstDelegate.testingSelectionInlineMessage == nil

        let stalePendingDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        stalePendingDelegate.testingInstallStatusItem()
        stalePendingDelegate.testingCompleteStatusItemVisibilityCheck(
            hiddenByGeometry
        )
        stalePendingDelegate.testingSetCurrentStatusItemVisibilitySnapshot(
            visible
        )
        stalePendingDelegate.testingTriggerShortcut()
        let staleGuidanceCancelled =
            stalePendingDelegate.testStatusItemGuidancePresentationCount == 0
            && stalePendingDelegate.testingInlineStatusMessage == nil
            && stalePendingDelegate.testingSelectionInlineMessage == nil
        stalePendingDelegate.testingBeginCurrentForegroundRequest()
        stalePendingDelegate.testingResolveForegroundTimeout()
        let staleFailureUsesNormalCopy =
            stalePendingDelegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable
            && stalePendingDelegate.testingForegroundSnapshot.tooltip
                == ShadowSyncPresentation.foregroundUnavailable
            && stalePendingDelegate.testingForegroundSnapshot
                .accessibilityHelp
                == ShadowSyncPresentation.foregroundUnavailable
            && stalePendingDelegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.foregroundUnavailable
        stalePendingDelegate.testingReconcileForegroundActivation(
            applicationActive: true,
            foregroundEstablished: true
        )
        stalePendingDelegate.testingSetCurrentStatusItemVisibilitySnapshot(
            hiddenByGeometry
        )
        stalePendingDelegate.testingTriggerAppReopen()
        let visibleBeforePresentationCancelsGuidance =
            staleGuidanceCancelled
            && staleFailureUsesNormalCopy
            && stalePendingDelegate.testStatusItemGuidancePresentationCount == 0
            && stalePendingDelegate.testingInlineStatusMessage == nil
            && stalePendingDelegate.testingSelectionInlineMessage == nil
            && stalePendingDelegate.testingForegroundSnapshot.menu == nil
        stalePendingDelegate.testingRemoveStatusItem()

        let visibleDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        visibleDelegate.testStartNewRun()
        let visibleIdentity = visibleDelegate.testSelectionControllerIdentity
        visibleDelegate.testingCompleteStatusItemVisibilityCheck(visible)
        visibleDelegate.testingTriggerAppReopen()
        let visibleNoImpact =
            visibleDelegate.testStatusItemGuidancePresentationCount == 0
            && visibleDelegate.testingSelectionInlineMessage == nil
            && visibleDelegate.testSelectionControllerIdentity == visibleIdentity

        let expectedGuidanceCopy = "macOS is hiding the ShadowSync menu icon. Use ⌃⌥⌘M to open this window. To restore the icon, enable it in System Settings → Menu Bar; macOS may list it under Cursor, and that setting may also show other Cursor menu items."
        let expectedHiddenForegroundCopy = "macOS did not foreground ShadowSync. Use ⌃⌥⌘M to try again. The menu icon remains hidden until it is enabled in System Settings → Menu Bar."
        return M5StatusItemGuidanceResponse(
            publicVisibilityClassification: publicVisibilityClassification,
            delayedHiddenPresentation: delayedHiddenPresentation,
            pendingUntilWindow: pendingUntilWindow,
            singlePresentation: singlePresentation,
            guidanceThenForegroundFailure: guidanceThenForegroundFailure,
            foregroundFailureThenGuidance: foregroundFailureThenGuidance,
            dismissClearsOwnedForegroundFailure:
                dismissClearsOwnedForegroundFailure,
            dismissPreservesUnrelatedInlineStatus:
                dismissPreservesUnrelatedInlineStatus,
            dismissPreservesOtherForegroundOwner:
                dismissPreservesOtherForegroundOwner,
            dismissPreservesNewForegroundOwner:
                dismissPreservesNewForegroundOwner,
            dismissRestoresShortcutUnavailableHelp:
                dismissRestoresShortcutUnavailableHelp,
            visibleBeforePresentationCancelsGuidance:
                visibleBeforePresentationCancelsGuidance,
            repeatedOrderingNoDuplicate: repeatedOrderingNoDuplicate,
            visibleNoImpact: visibleNoImpact,
            exactCopy:
                ShadowSyncPresentation.hiddenStatusItemGuidance
                    == expectedGuidanceCopy
                && ShadowSyncPresentation
                    .foregroundUnavailableWithHiddenStatusItem
                    == expectedHiddenForegroundCopy
        )
    }

    private static func testExactCopy(root: String) throws -> Bool {
        let candidates = makeCandidates(count: 2, root: root)
        let confirmation = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.confirmation(candidates: candidates)
        )
        let cancellation = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.cancellation()
        )
        let active = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.activeRun(repositoryCount: 7)
        )
        let takeover = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.takeover()
        )
        let contention = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.operationContention()
        )
        let unverifiedController = RunWindowController(candidates: [candidates[0]])
        unverifiedController.testingPresentUnverifiedTakeover()
        let rows = candidates.map(
            RepositoryOperatorPresentation.confirmationLabel
        ).joined(separator: "\n")
        let allButtonsDescribed = [
            confirmation.accessibilityLabels,
            confirmation.accessibilityHelp,
            cancellation.accessibilityLabels,
            cancellation.accessibilityHelp,
            active.accessibilityLabels,
            active.accessibilityHelp,
            takeover.accessibilityLabels,
            takeover.accessibilityHelp,
            contention.accessibilityLabels,
            contention.accessibilityHelp,
        ].flatMap { $0 }.allSatisfy { $0?.isEmpty == false }
        let contentionCopyMatches =
            contention.title
                == "Another ShadowSync operation is finishing"
            && contention.text
                == "ShadowSync cannot continue until the other operation finishes.\n\nWait a moment, or close this message and try again shortly."
            && contention.buttons == ["Close"]
            && contention.keyEquivalents == ["\r"]
            && !contention.showsSuppressionButton
        if !contentionCopyMatches {
            fputs(
                "M5 contention copy mismatch: title=\(String(reflecting: contention.title)) text=\(String(reflecting: contention.text)) buttons=\(contention.buttons) keys=\(contention.keyEquivalents)\n",
                stderr
            )
        }
        return confirmation.title == "Ready to update 2 repositories"
            && confirmation.text
                == "\(rows)\n\n\(ShadowSyncPresentation.confirmationText)"
            && confirmation.buttons == ["Back", "Cancel", "Start Update"]
            && confirmation.keyEquivalents == ["\r", "\u{1b}", ""]
            && cancellation.title == "Stop this run?"
            && cancellation.text
                == "The current Git operation will be asked to stop. Repositories already completed will stay completed. Remaining repositories will be marked Cancelled."
            && cancellation.buttons == ["Keep Running", "Stop Run"]
            && cancellation.keyEquivalents == ["\r", ""]
            && active.title == "A run is already active"
            && active.text
                == "ShadowSync is already updating 7 repositories. You can keep that run, or stop it safely and start a new selection. Repositories already completed will not be rolled back."
            && active.buttons == [
                "Cancel New Launch",
                "Stop Existing & Start New…",
            ]
            && active.keyEquivalents == ["\r", ""]
            && takeover.title == "Stop the active run?"
            && takeover.text
                == "The current Git operation will be asked to stop first. If it does not exit, only this run’s verified process group will be force-stopped. The existing log remains available until a new run acquires ownership."
            && takeover.buttons == ["Keep Existing Run", "Stop & Start New"]
            && takeover.keyEquivalents == ["\r", ""]
            && contentionCopyMatches
            && ShadowSyncPresentation.unverifiedOwner
                == "Nothing was stopped because ShadowSync could not verify ownership of the active process. No new run was started."
            && unverifiedController.testNeedsAttention
            && unverifiedController.requiresRecoveryReview
            && unverifiedController.testRowText.contains(
                ShadowSyncPresentation.unverifiedOwner
            )
            && ShadowSyncPresentation.selectionTitle
                == "Update local main branches"
            && [
                ShadowSyncPresentation.selectAll,
                ShadowSyncPresentation.clearAll,
                ShadowSyncPresentation.cancelSelection,
                ShadowSyncPresentation.reviewSelection,
                ShadowSyncPresentation.zeroSelection,
            ] == [
                "Select All",
                "Clear All",
                "Cancel",
                "Review Selection…",
                "Select at least one repository to continue.",
            ]
            && [
                ShadowSyncPresentation.openLog,
                ShadowSyncPresentation.cancelRun,
                ShadowSyncPresentation.closeRun,
                ShadowSyncPresentation.startNewRun,
                ShadowSyncPresentation.showCurrentRun,
                ShadowSyncPresentation.showLastReport,
                ShadowSyncPresentation.openLatestLog,
                ShadowSyncPresentation.shortcutUnavailable,
                ShadowSyncPresentation.quitUtility,
            ] == [
                "Open Log",
                "Cancel Run",
                "Close Run",
                "Start New Run…",
                "Show Current Run",
                "Show Last Report",
                "Open Latest Log",
                "Keyboard Shortcut Unavailable",
                "Quit ShadowSync",
            ]
            && ShadowSyncPresentation.help
                == "Eligible clean main working copies can be selected. Blocked repositories stay visible with the first reason they cannot run. Cached origin/main status uses local refs only and is not current GitHub state."
            && allButtonsDescribed
    }

    private static func testTaxonomyAndTransitions(root: String) throws -> Bool {
        for (offset, code) in ResultCode.allCases.enumerated() {
            let candidate = makeCandidates(
                count: 1,
                root: root + "/taxonomy-\(offset)"
            )[0]
            let run = RunIdentity.make()
            var reducer = RunPresentationReducer(
                runID: run,
                candidates: [candidate]
            )
            _ = try reducer.apply(RunEvent(
                run: run,
                sequence: 1,
                type: .runStarted
            ))
            let result = makeResult(candidate: candidate, code: code)
            let change = try reducer.apply(RunEvent(
                run: run,
                sequence: 2,
                type: .repositoryResult,
                repositoryID: candidate.path,
                phase: .complete,
                result: result
            ))
            let rowView = RunRowView(presentation: reducer.rows[0])
            guard change == .row(0),
                  reducer.rows[0].status == .result(code),
                  reducer.rows[0].detailText.contains("Result: \(code.rawValue)"),
                  reducer.rows[0].detailText.contains(
                      "Started: 2026-09-05T20:00:00.000Z · Ended: 2026-09-05T20:00:00.125Z · Duration: 125 ms"
                  ),
                  reducer.rows[0].result == result,
                  rowView.testingStatusText == RunRowStatus.result(code).label,
                  rowView.testingDetailText.contains("Result: \(code.rawValue)"),
                  rowView.testingSymbolDescription?.isEmpty == false,
                  try reducer.apply(RunEvent(
                      run: run,
                      sequence: 3,
                      type: .runFinished,
                      message: "terminal"
                  )) == .runFinished("terminal") else {
                return false
            }
            let frozen = reducer.rows
            _ = try reducer.apply(RunEvent(
                run: run,
                sequence: 4,
                type: .repositoryPhase,
                repositoryID: candidate.path,
                phase: .checking
            ))
            guard reducer.rows == frozen else { return false }
        }

        let candidate = makeCandidates(count: 1, root: root + "/transitions")[0]
        let run = RunIdentity.make()
        var reducer = RunPresentationReducer(runID: run, candidates: [candidate])
        let phases: [RepositoryPhase] = [
            .checking, .checking, .fetching, .fetching, .updating, .updating,
        ]
        _ = try reducer.apply(RunEvent(
            run: run,
            sequence: 1,
            type: .runStarted
        ))
        let transitionView = RunRowView(presentation: reducer.rows[0])
        for (offset, phase) in phases.enumerated() {
            let change = try reducer.apply(RunEvent(
                run: run,
                sequence: offset + 2,
                type: .repositoryPhase,
                repositoryID: candidate.path,
                phase: phase
            ))
            if case let .row(index) = change {
                transitionView.update(reducer.rows[index])
            }
        }
        guard reducer.rows[0].status == .updating,
              transitionView.testingStatusText == "Updating",
              transitionView.testingSymbolDescription == "Updating" else {
            return false
        }
        do {
            _ = try reducer.apply(RunEvent(
                run: run,
                sequence: 8,
                type: .repositoryPhase,
                repositoryID: candidate.path,
                phase: .checking
            ))
            return false
        } catch {}

        var gap = RunPresentationReducer(runID: run, candidates: [candidate])
        do {
            _ = try gap.apply(RunEvent(
                run: run,
                sequence: 2,
                type: .runStarted
            ))
            return false
        } catch {}

        var stopping = RunPresentationReducer(
            runID: run,
            candidates: [candidate]
        )
        _ = try stopping.apply(RunEvent(
            run: run,
            sequence: 1,
            type: .runStarted
        ))
        _ = try stopping.apply(RunEvent(
            run: run,
            sequence: 2,
            type: .repositoryPhase,
            repositoryID: candidate.path,
            phase: .checking
        ))
        guard stopping.requestStoppingOverlay() == 0,
              stopping.rows[0].status == .stopping,
              stopping.rows[0].authoritativeStatus == .checking,
              stopping.rows[0].stoppingOverlayRequested,
              stopping.requestStoppingOverlay() == nil else {
            return false
        }
        guard try stopping.apply(RunEvent(
            run: run,
            sequence: 3,
            type: .repositoryPhase,
            repositoryID: candidate.path,
            phase: .fetching
        )) == .row(0),
        stopping.rows[0].status == .stopping,
        stopping.rows[0].authoritativeStatus == .fetching,
        stopping.rows[0].stoppingOverlayRequested else {
            return false
        }

        var invalid = RunPresentationReducer(
            runID: run,
            candidates: [candidate]
        )
        _ = try invalid.apply(RunEvent(
            run: run,
            sequence: 1,
            type: .runStarted
        ))
        let unchanged = invalid.rows[0]
        do {
            _ = try invalid.apply(RunEvent(
                run: run,
                sequence: 2,
                type: .repositoryPhase,
                repositoryID: candidate.path,
                phase: .fetching
            ))
            return false
        } catch {}
        guard invalid.rows[0] == unchanged else {
            return false
        }

        let statuses: [RunRowStatus] = [
            .pending,
            .checking,
            .fetching,
            .updating,
            .updated,
            .alreadyCurrent,
            .skipped,
            .updatedWithWarning,
            .failed,
            .needsAttention,
            .stopping,
            .cancelled,
        ]
        return statuses.map(\.label) == [
            "Pending",
            "Checking",
            "Fetching",
            "Updating",
            "Updated",
            "Already Current",
            "Skipped",
            "Updated with Warning",
            "Failed",
            "Needs Attention",
            "Stopping…",
            "Cancelled",
        ] && statuses.allSatisfy {
            !ShadowSyncStatusSymbol.rowStatus($0).name.isEmpty
                && !ShadowSyncStatusSymbol.rowStatus($0).description.isEmpty
        }
    }

    private static func testReducerReportTransactions(
        root: String
    ) throws -> Bool {
        let candidates = makeCandidates(
            count: 3,
            root: root + "/report-transactions"
        )
        let run = RunIdentity.make()
        let validResults = candidates.map {
            makeResult(candidate: $0, code: .alreadyCurrent)
        }
        let validReport = makeReport(run: run, results: validResults)
        let validLiveReport = makeReport(
            run: run,
            results: validResults,
            repositoryModel: "v2"
        )
        let fresh = RunPresentationReducer(
            runID: run,
            candidates: candidates
        )

        func rejects(
            _ report: RunReport,
            from initial: RunPresentationReducer? = nil,
            policy: RunReportApplicationPolicy = .historicalOrRecovery
        ) -> Bool {
            let baseline = initial ?? fresh
            var subject = baseline
            do {
                _ = try subject.apply(report: report, policy: policy)
                return false
            } catch {
                return subject == baseline
            }
        }

        guard rejects(makeReport(
            run: RunIdentity.make(),
            results: validResults
        )),
        rejects(makeReport(
            run: run,
            results: Array(validResults.dropLast())
        )),
        rejects(makeReport(
            run: run,
            results: [validResults[1], validResults[0], validResults[2]]
        )),
        rejects(makeReport(
            run: run,
            results: [
                makeResult(candidate: candidates[1], code: .alreadyCurrent),
                validResults[1],
                validResults[2],
            ]
        )),
        rejects(makeReport(
            run: run,
            results: [
                validResults[0],
                makeResult(candidate: candidates[2], code: .alreadyCurrent),
                validResults[2],
            ]
        )),
        rejects(makeReport(
            run: run,
            results: [
                validResults[0],
                validResults[1],
                makeResult(candidate: candidates[0], code: .alreadyCurrent),
            ]
        )),
        rejects(makeReport(
            run: run,
            startedAt: "not-a-timestamp",
            results: validResults
        )),
        rejects(makeReport(
            run: run,
            startedAt: "2026-09-05T20:00:02.000Z",
            endedAt: "2026-09-05T20:00:01.000Z",
            results: validResults
        )),
        rejects(makeReport(
            run: run,
            durationMilliseconds: -1,
            results: validResults
        )),
        rejects(makeReport(
            run: run,
            results: [
                makeResult(
                    candidate: candidates[0],
                    code: .alreadyCurrent,
                    startedAt: "not-a-timestamp"
                ),
                validResults[1],
                validResults[2],
            ]
        )),
        rejects(makeReport(
            run: run,
            results: [
                validResults[0],
                makeResult(
                    candidate: candidates[1],
                    code: .alreadyCurrent,
                    durationMilliseconds: -1
                ),
                validResults[2],
            ]
        )),
        rejects(makeReport(
            run: run,
            results: validResults,
            summaryOverride: "Untrusted summary"
        )) else {
            return false
        }

        var nonterminal = fresh
        _ = try nonterminal.apply(RunEvent(
            run: run,
            sequence: 1,
            type: .runStarted
        ))
        guard rejects(
            validLiveReport,
            from: nonterminal,
            policy: .liveWorker
        ) else {
            return false
        }

        var conflictingTerminal = fresh
        _ = try conflictingTerminal.apply(RunEvent(
            run: run,
            sequence: 1,
            type: .runStarted
        ))
        _ = try conflictingTerminal.apply(RunEvent(
            run: run,
            sequence: 2,
            type: .repositoryResult,
            repositoryID: candidates[0].path,
            phase: .complete,
            result: makeResult(candidate: candidates[0], code: .updated)
        ))
        guard rejects(validReport, from: conflictingTerminal) else {
            return false
        }

        var injected = fresh
        do {
            _ = try injected.testingApply(
                report: validReport,
                failAfterAppliedRow: 1
            )
            return false
        } catch {
            guard injected == fresh else {
                return false
            }
        }

        var committed = fresh
        let changed = try committed.apply(report: validReport)
        guard changed == [0, 1, 2],
              committed.rows.allSatisfy(\.status.isTerminal),
              committed.terminalEventReceived,
              committed.activeRowIndex == nil,
              committed.lastEventSequence == fresh.lastEventSequence else {
            return false
        }
        let committedSnapshot = committed
        let duplicateChanges = try committed.apply(report: validReport)
        guard duplicateChanges.isEmpty,
              committed == committedSnapshot else {
            return false
        }
        let conflict = makeReport(
            run: run,
            results: [
                makeResult(candidate: candidates[0], code: .updated),
                validResults[1],
                validResults[2],
            ]
        )
        guard rejects(conflict, from: committed) else {
            return false
        }

        var retry = fresh
        guard rejects(makeReport(
            run: run,
            durationMilliseconds: -1,
            results: validResults
        ), from: retry) else {
            return false
        }
        _ = try retry.apply(report: validReport)
        return retry == committedSnapshot
    }

    private static func testStoppingOverlayRaces(
        root: String
    ) throws -> Bool {
        let phases: [RepositoryPhase] = [
            .checking,
            .fetching,
            .updating,
        ]
        for cut in 0...phases.count {
            let candidate = makeCandidates(
                count: 1,
                root: "\(root)/stopping-cut-\(cut)"
            )[0]
            let run = RunIdentity.make()
            var reducer = RunPresentationReducer(
                runID: run,
                candidates: [candidate]
            )
            var sequence = 1
            _ = try reducer.apply(RunEvent(
                run: run,
                sequence: sequence,
                type: .runStarted
            ))
            for phase in phases.prefix(cut) {
                sequence += 1
                _ = try reducer.apply(RunEvent(
                    run: run,
                    sequence: sequence,
                    type: .repositoryPhase,
                    repositoryID: candidate.path,
                    phase: phase
                ))
            }

            let overlayRow = reducer.requestStoppingOverlay()
            guard reducer.stoppingOverlayRequested,
                  reducer.requestStoppingOverlay() == nil else {
                return false
            }
            if cut == 0 {
                guard overlayRow == nil,
                      reducer.rows[0].status == .pending,
                      reducer.rows[0].authoritativeStatus == .pending,
                      !reducer.rows[0].stoppingOverlayRequested else {
                    return false
                }
            } else {
                guard overlayRow == 0,
                      reducer.rows[0].status == .stopping,
                      reducer.rows[0].authoritativeStatus
                        == RunRowPresentation.status(for: phases[cut - 1]),
                      reducer.rows[0].stoppingOverlayRequested else {
                    return false
                }
                sequence += 1
                _ = try reducer.apply(RunEvent(
                    run: run,
                    sequence: sequence,
                    type: .repositoryPhase,
                    repositoryID: candidate.path,
                    phase: phases[cut - 1]
                ))
            }

            for phase in phases.dropFirst(cut) {
                sequence += 1
                _ = try reducer.apply(RunEvent(
                    run: run,
                    sequence: sequence,
                    type: .repositoryPhase,
                    repositoryID: candidate.path,
                    phase: phase
                ))
                guard reducer.rows[0].status == .stopping,
                      reducer.rows[0].authoritativeStatus
                        == RunRowPresentation.status(for: phase),
                      reducer.rows[0].stoppingOverlayRequested else {
                    return false
                }
            }

            let code: ResultCode
            switch cut {
            case 0, 1:
                code = .cancelledNoUpdate
            case 2:
                code = .cancelledDuringFetch
            default:
                code = .updatedBeforeCancellation
            }
            let terminal = makeResult(candidate: candidate, code: code)
            sequence += 1
            _ = try reducer.apply(RunEvent(
                run: run,
                sequence: sequence,
                type: .repositoryResult,
                repositoryID: candidate.path,
                phase: .complete,
                result: terminal
            ))
            guard reducer.rows[0].status == .result(code),
                  reducer.rows[0].authoritativeStatus == .result(code),
                  !reducer.rows[0].stoppingOverlayRequested else {
                return false
            }
            sequence += 1
            _ = try reducer.apply(RunEvent(
                run: run,
                sequence: sequence,
                type: .runFinished,
                message: "Cancelled normally"
            ))
            let report = makeReport(
                run: run,
                cancelled: true,
                results: [terminal],
                repositoryModel: "v2"
            )
            let changed = try reducer.apply(
                report: report,
                policy: .liveWorker
            )
            guard changed.isEmpty,
                  reducer.lastEventSequence == sequence,
                  reducer.terminalEventReceived,
                  !reducer.stoppingOverlayRequested,
                  reducer.rows[0].result == terminal else {
                return false
            }
        }

        let candidates = makeCandidates(
            count: 3,
            root: root + "/stopping-next-row"
        )
        let run = RunIdentity.make()
        var nextRow = RunPresentationReducer(
            runID: run,
            candidates: candidates
        )
        _ = try nextRow.apply(RunEvent(
            run: run,
            sequence: 1,
            type: .runStarted
        ))
        let completed = makeResult(candidate: candidates[0], code: .updated)
        _ = try nextRow.apply(RunEvent(
            run: run,
            sequence: 2,
            type: .repositoryResult,
            repositoryID: candidates[0].path,
            phase: .complete,
            result: completed
        ))
        guard nextRow.requestStoppingOverlay() == nil else {
            return false
        }
        _ = try nextRow.apply(RunEvent(
            run: run,
            sequence: 3,
            type: .repositoryPhase,
            repositoryID: candidates[1].path,
            phase: .checking
        ))
        guard nextRow.rows[0].status == .updated,
              nextRow.rows[1].status == .stopping,
              nextRow.rows[1].authoritativeStatus == .checking,
              nextRow.rows[2].status == .pending else {
            return false
        }
        let second = makeResult(
            candidate: candidates[1],
            code: .cancelledNoUpdate
        )
        let third = makeResult(
            candidate: candidates[2],
            code: .cancelledPending
        )
        _ = try nextRow.apply(RunEvent(
            run: run,
            sequence: 4,
            type: .repositoryResult,
            repositoryID: candidates[1].path,
            phase: .complete,
            result: second
        ))
        _ = try nextRow.apply(RunEvent(
            run: run,
            sequence: 5,
            type: .repositoryResult,
            repositoryID: candidates[2].path,
            phase: .complete,
            result: third
        ))
        _ = try nextRow.apply(RunEvent(
            run: run,
            sequence: 6,
            type: .runFinished,
            message: "Cancelled normally"
        ))
        _ = try nextRow.apply(
            report: makeReport(
                run: run,
                cancelled: true,
                results: [completed, second, third],
                repositoryModel: "v2"
            ),
            policy: .liveWorker
        )
        guard nextRow.rows.map(\.status) == [
            .updated,
            .cancelled,
            .cancelled,
        ],
        !nextRow.stoppingOverlayRequested else {
            return false
        }

        let invalidCandidate = makeCandidates(
            count: 1,
            root: root + "/stopping-invalid"
        )[0]
        let invalidRun = RunIdentity.make()
        var invalid = RunPresentationReducer(
            runID: invalidRun,
            candidates: [invalidCandidate]
        )
        _ = try invalid.apply(RunEvent(
            run: invalidRun,
            sequence: 1,
            type: .runStarted
        ))
        _ = try invalid.apply(RunEvent(
            run: invalidRun,
            sequence: 2,
            type: .repositoryPhase,
            repositoryID: invalidCandidate.path,
            phase: .checking
        ))
        _ = invalid.requestStoppingOverlay()
        _ = try invalid.apply(RunEvent(
            run: invalidRun,
            sequence: 3,
            type: .repositoryPhase,
            repositoryID: invalidCandidate.path,
            phase: .fetching
        ))
        let authoritativeSnapshot = invalid
        do {
            _ = try invalid.apply(RunEvent(
                run: invalidRun,
                sequence: 4,
                type: .repositoryPhase,
                repositoryID: invalidCandidate.path,
                phase: .checking
            ))
            return false
        } catch {
            guard invalid == authoritativeSnapshot else { return false }
        }
        do {
            _ = try invalid.apply(RunEvent(
                run: invalidRun,
                sequence: 5,
                type: .repositoryPhase,
                repositoryID: invalidCandidate.path,
                phase: .updating
            ))
            return false
        } catch {
            guard invalid == authoritativeSnapshot else { return false }
        }
        let terminal = makeResult(
            candidate: invalidCandidate,
            code: .cancelledDuringFetch
        )
        _ = try invalid.apply(RunEvent(
            run: invalidRun,
            sequence: 4,
            type: .repositoryResult,
            repositoryID: invalidCandidate.path,
            phase: .complete,
            result: terminal
        ))
        let terminalSnapshot = invalid
        do {
            _ = try invalid.apply(RunEvent(
                run: invalidRun,
                sequence: 5,
                type: .repositoryResult,
                repositoryID: invalidCandidate.path,
                phase: .complete,
                result: makeResult(
                    candidate: invalidCandidate,
                    code: .cancelledNoUpdate
                )
            ))
            return false
        } catch {
            return invalid == terminalSnapshot
        }
    }

    private static func testNativeRows(
        root: String
    ) throws -> (
        ordered: Bool,
        constantTime: Bool,
        focus: Bool,
        accessibility: Bool,
        adaptive: Bool
    ) {
        let candidates = makeCandidates(count: 100, root: root + "/native")
        let controller = RunWindowController(candidates: candidates)
        let identities = controller.testingRowObjectIdentifiers
        let before = controller.testingRowUpdateCounts
        controller.testingAcceptEvent(RunEvent(
            run: controller.testingRunID,
            sequence: 1,
            type: .runStarted
        ))
        controller.testingAcceptEvent(RunEvent(
            run: controller.testingRunID,
            sequence: 2,
            type: .repositoryPhase,
            repositoryID: candidates[57].path,
            phase: .checking
        ))
        let after = controller.testingRowUpdateCounts
        let changed = zip(before, after).enumerated().compactMap {
            $0.element.0 == $0.element.1 ? nil : $0.offset
        }
        let rows = controller.testingRows
        let accessibility = controller.testingAccessibilitySnapshot
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        controller.window?.displayIfNeeded()
        let adaptive = controller.testingAdaptiveSnapshot
        controller.window?.performClose(nil)
        let hiddenWithoutRelease =
            controller.testingRowObjectIdentifiers == identities
                && controller.testingRows == rows
        controller.showWindow(nil)
        let ordered = rows.map(\.repository) == candidates
            && controller.testingRowObjectIdentifiers == identities
            && rows[57].status == .checking
            && rows.enumerated().allSatisfy {
                $0.offset == 57 || $0.element.status == .pending
            }
            && controller.testHasSymbol
            && hiddenWithoutRelease
        let rowAccessibility =
            accessibility.rowLabels.count == 100
                && accessibility.rowLabels.enumerated().allSatisfy {
                    $0.element
                        == candidates[$0.offset].canonicalOriginName
                }
                && accessibility.rowValues.allSatisfy { $0 != nil }
                && accessibility.symbolDescriptions.allSatisfy {
                    $0?.isEmpty == false
                }
        return (
            ordered,
            changed == [57] && after[57] == before[57] + 1,
            accessibility.initialResponderIsSafe
                && accessibility.keyOrderIsLogical
                && accessibility.destructiveButtonsAreNotDefault,
            rowAccessibility,
            adaptive.resizable
                && adaptive.minimumSize.width >= 620
                && adaptive.minimumSize.height >= 400
                && adaptive.scrolls
                && adaptive.contentExceedsViewport
                && adaptive.rowsFillViewport
                && adaptive.rowsWrap
                && adaptive.usesSemanticColors
        )
    }

    private static func testSelectionAndAccessibility(
        root: String
    ) throws -> (
        states: Bool,
        focus: Bool,
        accessibility: Bool,
        adaptive: Bool,
        disabledRowsAndReasons: Bool,
        eligibleBlockedCounts: Bool,
        reviewExcludesBlocked: Bool,
        runRowsShowCompactLocation: Bool
    ) {
        let eligible = makeCandidates(count: 2, root: root + "/selection")
        let blockedMain = RepositoryCandidate(
            id: "fixture-owner/blocked-main",
            displayName: "Blocked main",
            path: root + "/selection/blocked-main",
            rawOrigin: "https://github.com/fixture-owner/blocked-main.git",
            presentationLocation: "~/dev/testing/blocked-main",
            blockedReason: .mainInLinkedWorktree
        )
        let blockedHook = RepositoryCandidate(
            id: "fixture-owner/blocked-hook",
            displayName: "Blocked hook",
            path: root + "/selection/blocked-hook",
            rawOrigin: "https://github.com/fixture-owner/blocked-hook.git",
            presentationLocation: "~/dev/testing/blocked-hook",
            blockedReason: .unsupportedHook
        )
        let blockedLocal = RepositoryCandidate(
            id: "local:1:2",
            displayName: "local-only",
            path: root + "/selection/local-only",
            rawOrigin: "",
            presentationLocation: "~/dev/testing/local-only",
            blockedReason: .unsupportedOrigin
        )
        let candidates = [
            eligible[0],
            blockedMain,
            eligible[1],
            blockedHook,
            blockedLocal,
        ]
        let controller = SelectionWindowController(candidates: candidates)
        let empty = !controller.testHasSelection
            && controller.testSelectionCount == 0
            && controller.testPresentation.2
                == "Select at least one repository to continue."
        controller.testSelectAll()
        let all = controller.testSelectionCount == 2
        controller.testClearAll()
        let clear = controller.testSelectionCount == 0
        controller.testSelectFirst()
        let one = controller.testSelectionCount == 1
        var reviewed: [RepositoryCandidate] = []
        controller.onReview = { reviewed = $0 }
        controller.testSelectAndReview()
        let blockedConfirmation =
            ShadowSyncAlertFactory.testingSnapshot(
                ShadowSyncAlertFactory.confirmation(
                    candidates: [eligible[0], blockedMain]
                )
            )
        let accessibility = controller.testingAccessibilitySnapshot
        let adaptive = controller.testingAdaptiveSnapshot
        let availability = controller.testingAvailabilitySnapshot
        let allBlockedController = SelectionWindowController(
            candidates: [blockedMain, blockedHook, blockedLocal]
        )
        allBlockedController.testSelectAll()
        let allBlockedAvailability =
            allBlockedController.testingAvailabilitySnapshot
        let allBlockedSafe =
            allBlockedController.testSelectionCount == 0
            && !allBlockedController.testHasSelection
            && !allBlockedAvailability.selectAllEnabled
            && allBlockedController.testingAccessibilitySnapshot
                .initialResponderIsSafe
        let runRows = RunPresentationReducer(
            runID: "practical-location-run",
            candidates: eligible
        ).rows
        let disabledReasons =
            availability.enabledRows == [true, false, true, false, false]
            && availability.labels[1].contains(
                RepositoryBlockReason.mainInLinkedWorktree.operatorExplanation
            )
            && availability.labels[3].contains(
                RepositoryBlockReason.unsupportedHook.operatorExplanation
            )
            && accessibility.checkboxHelp[1]?.contains(
                RepositoryBlockReason.mainInLinkedWorktree.operatorExplanation
            ) == true
            && accessibility.checkboxHelp[3]?.contains(
                RepositoryBlockReason.unsupportedHook.operatorExplanation
            ) == true
            && availability.labels[4].contains("local-only")
            && !availability.labels[4].contains("local:1:2")
            && availability.warningReasons == [
                nil,
                RepositoryBlockReason.mainInLinkedWorktree
                    .operatorExplanation,
                nil,
                RepositoryBlockReason.unsupportedHook
                    .operatorExplanation,
                RepositoryBlockReason.unsupportedOrigin
                    .operatorExplanation,
            ]
            && availability.warningSymbols == [
                false, true, false, true, true,
            ]
            && availability.symbolTooltips.enumerated()
                .allSatisfy { row in
                    guard let reason =
                        candidates[row.offset].blockedReason?
                            .operatorExplanation else {
                        return row.element == nil
                    }
                    return row.element?.contains(reason) == true
                }
            && availability.tooltips.enumerated().allSatisfy { row in
                guard !candidates[row.offset].isEligible else {
                    return row.element?.contains(
                        candidates[row.offset].presentationLocation!
                    ) == true
                }
                return row.element?.contains(
                    candidates[row.offset].blockedReason!
                        .operatorExplanation
                ) == true
            }
            && zip(
                availability.warningAccessibilityHelp,
                availability.symbolAccessibilityHelp
            ).enumerated().allSatisfy { row in
                guard let reason =
                    candidates[row.offset].blockedReason?
                        .operatorExplanation else {
                    return row.element.0 == nil
                        && row.element.1 == nil
                }
                return row.element.0?.contains(reason) == true
                    && row.element.1?.contains(reason) == true
            }
        return (
            empty && all && clear && one && allBlockedSafe,
            accessibility.initialResponderIsSafe
                && accessibility.keyOrderIsLogical
                && !accessibility.reviewIsDefault
                && accessibility.cancelUsesEscape,
            accessibility.checkboxLabels.count == candidates.count
                && accessibility.checkboxLabels.enumerated().allSatisfy { row in
                    row.element?.contains(
                        RepositoryOperatorPresentation.primaryName(
                            candidates[row.offset]
                        )
                    ) == true
                        && row.element?.contains(candidates[row.offset].path)
                            == false
                },
            adaptive.resizable
                && adaptive.minimumSize.width >= 560
                && adaptive.minimumSize.height >= 360
                && adaptive.scrolls
                && adaptive.helpWraps
                && adaptive.rowsWrap
                && adaptive.usesSemanticColors,
            disabledReasons,
            availability.count == "2 eligible, 3 blocked"
                && availability.selectAllEnabled,
            reviewed == eligible
                && blockedConfirmation.title
                    == ShadowSyncPresentation.locationAttentionTitle
                && blockedConfirmation.buttons
                    == [ShadowSyncPresentation.cancel]
                && WorkerRequest.admitsPayload(eligible)
                && !WorkerRequest.admitsPayload([
                    eligible[0], blockedMain,
                ]),
            runRows.allSatisfy(\.showsLocation)
        )
    }

    private static func testForegroundRequestTransactions(
        root: String
    ) -> Bool {
        func fail(_ stage: String) -> Bool {
            fputs("M5 foreground transaction failure: \(stage)\n", stderr)
            return false
        }
        let sourceDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("source")
        guard let delegateSource = try? String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "AppDelegate.swift"
            ),
            encoding: .utf8
        ),
              delegateSource.contains("NSWorkspace.shared.openApplication("),
              delegateSource.contains("configuration.activates = true"),
              delegateSource.contains(
                "configuration.createsNewApplicationInstance = false"
              ),
              delegateSource.contains(
                "processIdentifier == getpid()"
              ),
              delegateSource.contains(
                "window.collectionBehavior.insert(.moveToActiveSpace)"
              ),
              delegateSource.contains("window.isOnActiveSpace"),
              !delegateSource.contains("NSApp.activate()"),
              !delegateSource.contains(
                "activate(ignoringOtherApps:"
              ),
              !delegateSource.contains(
                "NSRunningApplication.current.activate("
              ) else {
            return fail("activation API contract")
        }
        guard let readme = try? String(
            contentsOf: sourceDirectory.appendingPathComponent("native-acceptance.md"),
            encoding: .utf8
        ),
              readme.contains("`00-dirty-first`"),
              readme.contains("as `SKIPPED_DIRTY`"),
              !readme.contains("`00-fail-first`"),
              !readme.contains("`FAILED_INSPECTION`") else {
            return fail("native acceptance runbook taxonomy")
        }
        guard let mapping = try? makeMapping(root: root) else {
            return fail("mapping")
        }
        let candidates = makeCandidates(
            count: 2,
            root: root + "/foreground-transactions"
        )
        let discovery = M5CountingDiscovery(candidates: candidates)
        let delegate = makeDelegate(
            discovery: discovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        delegate.testingInstallStatusItem()
        defer { delegate.testingRemoveStatusItem() }
        let selection = SelectionWindowController(candidates: candidates)
        let run = RunWindowController(candidates: candidates)

        delegate.testingInstallSelectionWindow(selection)
        let fallbackWindowNumber =
            delegate.testingSelectionWindowState?.number
        delegate.testingHideSelectionWindow()
        guard delegate.testingSelectionWindowState?.visible == false else {
            return fail("fallback selection hide")
        }
        delegate.testingBeginForegroundRequest(selection)
        guard delegate.testingSelectionWindowState?.visible == true,
              delegate.testingSelectionWindowState?.number
                == fallbackWindowNumber,
              delegate.testSelectionControllerIdentity
                == ObjectIdentifier(selection) else {
            return fail("fallback selection identity")
        }
        delegate.testingResolveForegroundTimeout()
        guard delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable,
              delegate.testingForegroundSnapshot.tooltip
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("fallback timeout guidance")
        }
        delegate.testingBeginForegroundRequest(selection)
        delegate.testingResolveForegroundSuccess()
        guard delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingSelectionWindowState?.number
                == fallbackWindowNumber else {
            return fail("fallback retry")
        }

        delegate.testingBeginForegroundRequest(selection)
        guard let generationA = delegate.testingForegroundSnapshot.generation,
              delegate.testingForegroundSnapshot.target
                == ObjectIdentifier(selection) else {
            return fail("pending A")
        }
        delegate.testingBeginForegroundRequest(selection)
        guard delegate.testingForegroundSnapshot.generation == generationA,
              delegate.testingForegroundSnapshot.inline == nil,
              delegate.testingForegroundSnapshot.menu == nil else {
            return fail("same-target coalescing")
        }
        delegate.testingBeginForegroundRequest(run)
        guard let generationB = delegate.testingForegroundSnapshot.generation,
              generationB > generationA,
              delegate.testingForegroundSnapshot.target
                == ObjectIdentifier(run),
              delegate.testingForegroundSnapshot.inline == nil,
              delegate.testingForegroundSnapshot.tooltip == nil else {
            return fail("silent supersession")
        }
        delegate.testingResolveForegroundDenied(generation: generationA)
        guard delegate.testingForegroundSnapshot.generation == generationB,
              delegate.testingForegroundSnapshot.inline == nil,
              delegate.testingForegroundSnapshot.tooltip == nil else {
            return fail("stale callback")
        }
        delegate.testingResolveForegroundDenied()
        let failed = delegate.testingForegroundSnapshot
        guard failed.generation == nil,
              failed.timedOut,
              failed.observerInstalled,
              failed.inline == ShadowSyncPresentation.foregroundUnavailable,
              failed.menu == ShadowSyncPresentation.foregroundUnavailable,
              failed.tooltip == ShadowSyncPresentation.foregroundUnavailable,
              failed.accessibilityHelp
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("denied rendering")
        }
        delegate.testingBeginForegroundRequest(run)
        delegate.testingResolveForegroundSuccess()
        let succeeded = delegate.testingForegroundSnapshot
        guard succeeded.generation == nil,
              succeeded.inline == nil,
              succeeded.menu == nil,
              succeeded.tooltip == nil,
              succeeded.accessibilityHelp == nil,
              succeeded.observerInstalled else {
            return fail("success cleanup")
        }

        let callsBeforeImmediate = succeeded.activationCalls
        delegate.testingRequestForeground(
            selection,
            activationAccepted: false,
            activeBefore: false,
            activeAfterActivation: true
        )
        let immediate = delegate.testingForegroundSnapshot
        guard immediate.activationCalls == callsBeforeImmediate + 1,
              immediate.generation == nil,
              immediate.menu == nil,
              immediate.tooltip == nil else {
            return fail("active after rejected activation")
        }

        delegate.testingRequestForeground(
            selection,
            activationAccepted: false,
            activeBefore: false
        )
        let deniedGeneration =
            delegate.testingForegroundSnapshot.issuedGeneration
        guard delegate.testingForegroundSnapshot.generation == nil,
              delegate.testingForegroundSnapshot.timedOut else {
            return fail("retry denied")
        }
        let deniedCalls = delegate.testingForegroundSnapshot.activationCalls
        delegate.testingRequestForeground(
            selection,
            activationAccepted: true,
            activeBefore: false
        )
        guard let retryGeneration =
                delegate.testingForegroundSnapshot.generation,
              retryGeneration > deniedGeneration,
              delegate.testingForegroundSnapshot.activationCalls
                == deniedCalls + 1,
              !delegate.testingForegroundSnapshot.timedOut else {
            return fail("same-target denied retry")
        }
        delegate.testingResolveForegroundDenied(
            generation: deniedGeneration
        )
        guard delegate.testingForegroundSnapshot.generation
                == retryGeneration else {
            return fail("stale denied retry callback")
        }
        let awaitingCalls = delegate.testingForegroundSnapshot.activationCalls
        delegate.testingRequestForeground(
            selection,
            activationAccepted: true,
            activeBefore: false
        )
        guard delegate.testingForegroundSnapshot.generation
                == retryGeneration,
              delegate.testingForegroundSnapshot.activationCalls
                == awaitingCalls else {
            return fail("awaiting coalescing")
        }
        selection.window?.makeKeyAndOrderFront(nil)
        delegate.testingFireForegroundTimeout(
            applicationActive: true,
            foregroundEstablished: true
        )
        guard delegate.testingForegroundSnapshot.generation == nil,
              delegate.testingForegroundSnapshot.menu == nil else {
            return fail("active at timeout")
        }

        delegate.testingBeginForegroundRequest(selection)
        guard let timedOutGeneration =
                delegate.testingForegroundSnapshot.generation else {
            return fail("timeout pending")
        }
        delegate.testingResolveForegroundTimeout()
        guard delegate.testingForegroundSnapshot.timedOut,
              delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("timeout status")
        }
        delegate.testingBeginForegroundRequest(run)
        guard let postTimeoutGeneration =
                delegate.testingForegroundSnapshot.generation,
              postTimeoutGeneration > timedOutGeneration,
              delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("timeout supersession")
        }
        delegate.testingResolveForegroundSuccess(
            generation: timedOutGeneration
        )
        guard delegate.testingForegroundSnapshot.generation
                == postTimeoutGeneration else {
            return fail("late timed-out generation")
        }
        delegate.testingResolveForegroundSuccess()

        delegate.testingBeginForegroundRequest(selection)
        delegate.testingResolveForegroundTimeout()
        delegate.testingBeginForegroundRequest(selection)
        guard let awaitingWithGuidance =
                delegate.testingForegroundSnapshot.generation else {
            return fail("guided awaiting request")
        }
        delegate.testingBeginForegroundRequest(run)
        guard let replacementWithGuidance =
                delegate.testingForegroundSnapshot.generation,
              replacementWithGuidance > awaitingWithGuidance,
              delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable,
              delegate.testingForegroundSnapshot.tooltip
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("guided supersession")
        }
        delegate.testingResolveForegroundSuccess(
            generation: awaitingWithGuidance
        )
        guard delegate.testingForegroundSnapshot.generation
                == replacementWithGuidance,
              delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("guided stale callback")
        }
        delegate.testingResolveForegroundDenied()
        guard delegate.testingForegroundSnapshot.generation == nil,
              delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable,
              delegate.testMenuTitles().filter({
                  $0 == ShadowSyncPresentation.foregroundUnavailable
              }).count == 1 else {
            return fail("guided replacement failure")
        }
        delegate.testingBeginForegroundRequest(run)
        delegate.testingResolveForegroundSuccess()
        guard delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil else {
            return fail("guided replacement success")
        }

        let hiddenSelection = SelectionWindowController(
            candidates: candidates
        )
        delegate.testingInstallSelectionWindow(hiddenSelection)
        delegate.testingBeginForegroundRequest(hiddenSelection)
        let discoveryBeforeAwaitingHide = discovery.invocationCount
        delegate.testingHideSelectionWindow()
        guard delegate.testingForegroundSnapshot.generation == nil,
              delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil,
              discovery.invocationCount == discoveryBeforeAwaitingHide else {
            return fail("awaiting selection hide cancellation")
        }
        delegate.testingBeginForegroundRequest(hiddenSelection)
        delegate.testingResolveForegroundTimeout()
        let discoveryBeforeHide = discovery.invocationCount
        delegate.testingHideSelectionWindow()
        guard delegate.testingForegroundSnapshot.generation == nil,
              delegate.testingForegroundSnapshot.inline == nil,
              delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil,
              discovery.invocationCount == discoveryBeforeHide,
              hiddenSelection.window?.isVisible == false else {
            return fail(
                "selection hide cancellation "
                    + "generation=\(String(describing: delegate.testingForegroundSnapshot.generation)) "
                    + "inline=\(String(describing: delegate.testingForegroundSnapshot.inline)) "
                    + "menu=\(String(describing: delegate.testingForegroundSnapshot.menu)) "
                    + "tooltip=\(String(describing: delegate.testingForegroundSnapshot.tooltip)) "
                    + "discovery=\(discovery.invocationCount - discoveryBeforeHide) "
                    + "visible=\(hiddenSelection.window?.isVisible == true)"
            )
        }
        // A new failed request has its own guidance. Ordinary dismissal above
        // retired only the previous failure; unrelated activation must not clear
        // this new one, and observed foreground reality must still recover it.
        delegate.testingBeginForegroundRequest(hiddenSelection)
        delegate.testingResolveForegroundTimeout()
        hiddenSelection.window?.orderOut(nil)
        guard delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable,
              delegate.testingForegroundSnapshot.tooltip
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("new hidden selection timeout")
        }
        delegate.testingReconcileForegroundActivation(
            applicationActive: true,
            foregroundEstablished: false
        )
        guard hiddenSelection.window?.isVisible == false,
              delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable else {
            return fail("unrelated activation after timeout")
        }
        hiddenSelection.showWindow(nil)
        hiddenSelection.window?.makeKeyAndOrderFront(nil)
        delegate.testingReconcileForegroundActivation(
            applicationActive: true,
            foregroundEstablished: true
        )
        guard delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil else {
            return fail("observed natural foreground")
        }
        delegate.testingHideSelectionWindow()

        let hiddenRun = RunWindowController(candidates: candidates)
        delegate.testingInstallRunWindow(hiddenRun)
        delegate.testingBeginForegroundRequest(hiddenRun)
        delegate.testingResolveForegroundTimeout()
        delegate.testingHideRunWindow()
        guard delegate.testingForegroundSnapshot.generation == nil,
              delegate.testingForegroundSnapshot.inline == nil,
              delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil,
              hiddenRun.window?.isVisible == false else {
            return fail("run hide cancellation")
        }

        let closingSelection = SelectionWindowController(
            candidates: candidates
        )
        delegate.testingBeginForegroundRequest(closingSelection)
        delegate.testingResolveForegroundTimeout()
        let discoveryBeforeClose = discovery.invocationCount
        let selectionBeforeClose = delegate.testSelectionControllerIdentity
        let runBeforeClose = delegate.testingRunControllerIdentity
        closingSelection.close()
        delegate.testingCancelForegroundRequest(closingSelection)
        delegate.testingResolveForegroundSuccess()
        guard delegate.testingRunControllerIdentity == runBeforeClose,
              delegate.testSelectionControllerIdentity
                == selectionBeforeClose,
              discovery.invocationCount == discoveryBeforeClose,
              hiddenSelection.window?.isVisible == false,
              hiddenRun.window?.isVisible == false,
              delegate.testingForegroundSnapshot.inline == nil,
              delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil,
              delegate.testingForegroundSnapshot.generation == nil else {
            return fail("target close retarget")
        }
        let recoveryRun = RunWindowController(candidates: candidates)
        delegate.testingBeginForegroundRequest(recoveryRun)
        delegate.testingResolveForegroundSuccess()
        guard delegate.testingForegroundSnapshot.menu == nil,
              delegate.testingForegroundSnapshot.tooltip == nil,
              delegate.testingForegroundSnapshot.accessibilityHelp == nil else {
            return fail("post-hide success cleanup")
        }
        delegate.testingTerminateForegroundObservation()
        guard !delegate.testingForegroundSnapshot.observerInstalled else {
            return fail("observer termination")
        }

        let collision = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: false
        )
        collision.testingInstallStatusItem()
        defer { collision.testingRemoveStatusItem() }
        collision.testingPresentPendingShortcutCollision()
        guard collision.testingForegroundSnapshot.collisionCount == 0 else {
            return fail("windowless collision")
        }
        let collisionSelection = SelectionWindowController(
            candidates: candidates
        )
        collisionSelection.showWindow(nil)
        collision.testingInstallSelectionWindow(collisionSelection)
        collision.testingSetCollisionAttachmentSucceeds(false)
        collision.testingPresentPendingShortcutCollision()
        guard collision.testingForegroundSnapshot.collisionCount == 0,
              collision.testingForegroundSnapshot.collisionAttempts == 1,
              collision.testingForegroundSnapshot.collisionState
                == "pending" else {
            return fail("collision attachment failure")
        }
        collision.testingSetCollisionAttachmentSucceeds(true)
        collision.testingBeginForegroundRequest(collisionSelection)
        collision.testingResolveForegroundDenied()
        let collisionDeadline = MonotonicDeadline(seconds: 0.5)
        while collision.testingForegroundSnapshot.collisionCount == 0,
              !collisionDeadline.hasExpired {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.02)
            )
        }
        let collisionFailed = collision.testingForegroundSnapshot
        guard collisionFailed.collisionCount == 1,
              collisionFailed.collisionAttempts == 2,
              collisionFailed.collisionState == "shown",
              collisionFailed.inline
                == ShadowSyncPresentation.foregroundUnavailable,
              collisionFailed.tooltip
                == ShadowSyncPresentation.foregroundUnavailable,
              collision.testMenuTitles().contains(
                ShadowSyncPresentation.shortcutUnavailable
              ) else {
            fputs(
                "M5 collision denied state: count=\(collisionFailed.collisionCount) "
                    + "inline=\(String(describing: collisionFailed.inline)) "
                    + "menu=\(String(describing: collisionFailed.menu)) "
                    + "tooltip=\(String(describing: collisionFailed.tooltip))\n",
                stderr
            )
            return fail("collision after denial")
        }
        collision.testingBeginForegroundRequest(collisionSelection)
        collision.testingResolveForegroundSuccess()
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.02)
        )
        let collisionSucceeded = collision.testingForegroundSnapshot
        guard collisionSucceeded.collisionCount == 1,
              collisionSucceeded.collisionAttempts == 2,
              collisionSucceeded.collisionState == "shown",
              collisionSucceeded.inline == nil,
              collisionSucceeded.menu == nil,
              collisionSucceeded.tooltip
                == ShadowSyncPresentation.shortcutUnavailableText,
              collisionSucceeded.accessibilityHelp
                == ShadowSyncPresentation.shortcutUnavailableText else {
            return fail("collision success cleanup")
        }
        return true
    }

    private static func runForegroundTimingRegression(
        root: String
    ) throws -> Bool {
        let candidates = makeCandidates(
            count: 1,
            root: root + "/foreground-timing"
        )

        func fixture(_ name: String) throws -> (
            ShadowSyncAppDelegate,
            SelectionWindowController
        ) {
            let caseRoot = root + "/" + name
            try FileManager.default.createDirectory(
                atPath: caseRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                atPath: caseRoot + "/home",
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let delegate = makeDelegate(
                discovery: M5CountingDiscovery(candidates: candidates),
                root: caseRoot,
                mapping: try makeMapping(root: caseRoot),
                shortcutAvailable: true
            )
            let controller = SelectionWindowController(candidates: candidates)
            delegate.testingInstallSelectionWindow(controller)
            return (delegate, controller)
        }

        func require(
            _ condition: Bool,
            _ message: String
        ) throws {
            if !condition { throw M5HarnessError.message(message) }
        }

        do {
            let (delegate, controller) = try fixture("active-first")
            delegate.testingBeginTimedForegroundRequest(controller)
            delegate.testingReconcileForegroundActivation(
                applicationActive: true,
                foregroundEstablished: false
            )
            delegate.testingAdvanceForeground(seconds: 0.5)
            delegate.testingPostForegroundWindowEvent(
                applicationActive: true,
                foregroundEstablished: true
            )
            try require(
                delegate.testingForegroundSnapshot.generation == nil
                    && delegate.testingForegroundSnapshot.successes == 1,
                "active-first foreground did not complete on key event"
            )
            try require(
                delegate.testingForegroundRequestObservation.windowObservers == 0
                    && !delegate.testingForegroundRequestObservation.timeoutScheduled
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "active-first foreground observers leaked"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, controller) = try fixture("delayed-active-space")
            delegate.testingBeginTimedForegroundRequest(controller)
            guard let identity =
                    delegate.testingForegroundRealityRevalidationIdentity else {
                throw M5HarnessError.message(
                    "active-Space revalidation was not scheduled"
                )
            }
            delegate.testingFireForegroundRealityRevalidation(
                windowOnActiveSpace: false
            )
            let waiting = delegate.testingForegroundSnapshot
            try require(
                waiting.generation == identity.generation
                    && waiting.successes == 0
                    && waiting.realityRevalidations == 1
                    && delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "pre-Space reality completed without active-Space membership"
            )
            delegate.testingFireForegroundRealityRevalidation(
                windowOnActiveSpace: true
            )
            let completed = delegate.testingForegroundSnapshot
            try require(
                completed.generation == nil
                    && completed.successes == 1
                    && completed.realityRevalidations == 2
                    && delegate.testingForegroundRequestObservation
                        .windowObservers == 0
                    && !delegate.testingForegroundRequestObservation
                        .timeoutScheduled
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "active-Space condition polling did not complete exactly once"
            )
            delegate.testingFireForegroundRealityRevalidation(
                generation: identity.generation,
                windowNumber: identity.windowNumber,
                windowOnActiveSpace: true
            )
            try require(
                delegate.testingForegroundSnapshot.successes == 1
                    && delegate.testingForegroundSnapshot
                        .realityRevalidations == 2,
                "completed active-Space callback ran again"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, controller) = try fixture("just-before-deadline")
            delegate.testingBeginTimedForegroundRequest(controller)
            delegate.testingAdvanceForeground(seconds: 1.999_999)
            delegate.testingPostForegroundWindowEvent(
                applicationActive: true,
                foregroundEstablished: true
            )
            try require(
                delegate.testingForegroundSnapshot.successes == 1
                    && delegate.testingForegroundSnapshot.generation == nil,
                "pre-deadline key event timed out"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, controller) = try fixture("deadline-race")
            delegate.testingBeginTimedForegroundRequest(controller)
            delegate.testingAdvanceForeground(seconds: 1.999_999)
            delegate.testingFireForegroundTimeout(
                applicationActive: true,
                foregroundEstablished: true
            )
            delegate.testingPostForegroundWindowEvent(
                applicationActive: true,
                foregroundEstablished: true
            )
            try require(
                delegate.testingForegroundSnapshot.successes == 1
                    && delegate.testingForegroundSnapshot.generation == nil,
                "deadline/key race did not complete exactly once"
            )
            delegate.testingTerminateForegroundObservation()
        }

        for (name, foregroundEstablished) in [
            ("after-deadline", true),
            ("never-key", false),
        ] {
            let (delegate, controller) = try fixture(name)
            delegate.testingBeginTimedForegroundRequest(controller)
            delegate.testingAdvanceForeground(seconds: 2.001)
            if foregroundEstablished {
                delegate.testingPostForegroundWindowEvent(
                    applicationActive: true,
                    foregroundEstablished: true
                )
            } else {
                delegate.testingFireForegroundTimeout(
                    applicationActive: true,
                    foregroundEstablished: false
                )
            }
            try require(
                delegate.testingForegroundSnapshot.timedOut
                    && delegate.testingForegroundSnapshot.successes == 0
                    && delegate.testingForegroundSnapshot.generation == nil,
                "\(name) did not fail closed at the deadline"
            )
            try require(
                delegate.testingForegroundRequestObservation.windowObservers == 0
                    && !delegate.testingForegroundRequestObservation.timeoutScheduled
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "\(name) observers leaked"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, controller) = try fixture("duplicate")
            delegate.testingBeginTimedForegroundRequest(controller)
            let generation = delegate.testingForegroundSnapshot.generation
            let revalidationIdentity =
                delegate.testingForegroundRealityRevalidationIdentity
            delegate.testingRepeatPendingForegroundRequest(
                applicationActive: true,
                foregroundEstablished: false
            )
            try require(
                delegate.testingForegroundSnapshot.generation == generation
                    && delegate.testingForegroundRequestObservation.windowObservers == 3
                    && delegate.testingForegroundRequestObservation.timeoutScheduled
                    && delegate.testingForegroundRealityRevalidationIdentity?
                        .generation == revalidationIdentity?.generation
                    && delegate.testingForegroundRealityRevalidationIdentity?
                        .windowNumber == revalidationIdentity?.windowNumber,
                "duplicate request replaced observers or generation"
            )
            delegate.testingAdvanceForeground(seconds: 0.5)
            delegate.testingPostForegroundWindowEvent(
                applicationActive: true,
                foregroundEstablished: true
            )
            try require(
                delegate.testingForegroundSnapshot.successes == 1,
                "duplicate request completed more than once"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, first) = try fixture("replacement")
            delegate.testingBeginTimedForegroundRequest(first)
            guard let staleRevalidation =
                    delegate.testingForegroundRealityRevalidationIdentity else {
                throw M5HarnessError.message(
                    "replacement did not capture its first revalidation"
                )
            }
            let replacement = SelectionWindowController(candidates: candidates)
            delegate.testingInstallSelectionWindow(replacement)
            delegate.testingBeginTimedForegroundRequest(
                replacement,
                startNanoseconds: 5_000_000_000
            )
            let replacementRevalidation =
                delegate.testingForegroundRealityRevalidationIdentity
            delegate.testingFireForegroundRealityRevalidation(
                generation: staleRevalidation.generation,
                windowNumber: staleRevalidation.windowNumber,
                windowOnActiveSpace: true
            )
            try require(
                delegate.testingForegroundSnapshot.target
                    == ObjectIdentifier(replacement)
                    && delegate.testingForegroundRequestObservation.windowObservers == 3
                    && delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled
                    && delegate.testingForegroundRealityRevalidationIdentity?
                        .generation == replacementRevalidation?.generation
                    && delegate.testingForegroundSnapshot.successes == 0,
                "replacement did not own the pending observers"
            )
            delegate.testingCancelForegroundRequest(replacement)
            try require(
                delegate.testingForegroundSnapshot.generation == nil
                    && delegate.testingForegroundRequestObservation.windowObservers == 0
                    && !delegate.testingForegroundRequestObservation.timeoutScheduled
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "replacement closure leaked pending observation"
            )
            delegate.testingTerminateForegroundObservation()
        }

        let realityCases: [(String, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            ("complete", true, true, true, true, true, true),
            ("inactive", false, true, true, true, true, false),
            ("hidden", true, false, true, true, true, false),
            ("not-key", true, true, false, true, true, false),
            ("offscreen", true, true, true, false, true, false),
            ("wrong-space", true, true, true, true, false, false),
        ]
        for (
            name,
            active,
            visible,
            key,
            onScreen,
            activeSpace,
            expected
        ) in realityCases {
            try require(
                ShadowSyncAppDelegate.testingForegroundRealityIsEstablished(
                    applicationActive: active,
                    windowVisible: visible,
                    windowKey: key,
                    windowOnScreen: onScreen,
                    windowOnActiveSpace: activeSpace
                ) == expected,
                "foreground reality gate accepted \(name)"
            )
        }

        do {
            let (delegate, controller) = try fixture("strict-failure-reconcile")
            delegate.testingRequestForeground(
                controller,
                activationAccepted: false,
                activeBefore: false
            )
            let before = delegate.testingForegroundSnapshot.failureClears
            delegate.testingReconcileForegroundFailure(
                applicationActive: false,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: true
            )
            delegate.testingReconcileForegroundFailure(
                applicationActive: true,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: false
            )
            try require(
                delegate.testingForegroundSnapshot.menu
                    == ShadowSyncPresentation.foregroundUnavailable
                    && delegate.testingForegroundSnapshot.failureClears
                        == before,
                "partial visible-key reality cleared foreground failure"
            )
            delegate.testingReconcileForegroundFailure(
                applicationActive: true,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: true
            )
            let reconciled = delegate.testingForegroundSnapshot
            delegate.testingReconcileForegroundFailure(
                applicationActive: true,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: true
            )
            try require(
                reconciled.menu == nil
                    && reconciled.failureClears == before + 1
                    && delegate.testingForegroundSnapshot.failureClears
                        == before + 1,
                "strict foreground reality did not clear failure exactly once"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, selection) =
                try fixture("contention-dismiss-pending")
            delegate.testingRequestForeground(
                selection,
                activationAccepted: false,
                activeBefore: false
            )
            let before = delegate.testingForegroundSnapshot.failureClears
            let contention =
                delegate.testingInstallOperationContentionWindow()
            defer { contention.close() }
            delegate.testingBeginTimedForegroundRequest(contention)
            delegate.testingDismissOperationContentionWindow(
                applicationActive: false,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: false
            )
            try require(
                delegate.testingForegroundSnapshot.generation == nil
                    && delegate.testingForegroundSnapshot.menu
                        == ShadowSyncPresentation.foregroundUnavailable
                    && delegate.testingForegroundSnapshot.failureClears
                        == before
                    && !delegate.testingHasOperationContentionWindow
                    && !delegate.testingForegroundRequestObservation
                        .timeoutScheduled
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "pending contention dismissal erased valid failure"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, selection) =
                try fixture("contention-dismiss-to-valid-primary")
            delegate.testingRequestForeground(
                selection,
                activationAccepted: false,
                activeBefore: false
            )
            let before = delegate.testingForegroundSnapshot.failureClears
            let contention =
                delegate.testingInstallOperationContentionWindow()
            defer { contention.close() }
            delegate.testingBeginTimedForegroundRequest(contention)
            delegate.testingDismissOperationContentionWindow(
                applicationActive: true,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: true
            )
            try require(
                delegate.testingForegroundSnapshot.generation == nil
                    && delegate.testingForegroundSnapshot.menu == nil
                    && delegate.testingForegroundSnapshot.failureClears
                        == before + 1
                    && !delegate.testingHasOperationContentionWindow,
                "valid primary did not reconcile dismissed contention failure"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, selection) =
                try fixture("contention-dismiss-after-failure")
            delegate.testingRemoveSelectionWindow()
            selection.close()
            let contention =
                delegate.testingInstallOperationContentionWindow()
            defer { contention.close() }
            delegate.testingRequestForeground(
                contention,
                activationAccepted: false,
                activeBefore: false
            )
            let before = delegate.testingForegroundSnapshot.failureClears
            delegate.testingDismissOperationContentionWindow(
                applicationActive: true,
                windowVisible: true,
                windowKey: true,
                windowOnScreen: true,
                windowOnActiveSpace: true
            )
            try require(
                delegate.testingForegroundSnapshot.menu
                    == ShadowSyncPresentation.foregroundUnavailable
                    && delegate.testingForegroundSnapshot.failureClears
                        == before
                    && !delegate.testingHasOperationContentionWindow,
                "dismissed failed contention without target erased failure"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, controller) = try fixture("workspace-completion")
            delegate.testingRequestForeground(
                controller,
                activationAccepted: true,
                activeBefore: false,
                activeAfterActivation: true
            )
            let snapshot = delegate.testingForegroundSnapshot
            try require(
                snapshot.activationCalls == 1
                    && snapshot.activationCompletions == 1
                    && snapshot.activationFailures == 0
                    && snapshot.activationReassertions == 1
                    && snapshot.successes == 1
                    && snapshot.generation == nil
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "workspace completion did not reassert current target once"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, controller) = try fixture("workspace-failure")
            delegate.testingRequestForeground(
                controller,
                activationAccepted: false,
                activeBefore: false
            )
            let snapshot = delegate.testingForegroundSnapshot
            try require(
                snapshot.activationCalls == 1
                    && snapshot.activationCompletions == 0
                    && snapshot.activationFailures == 1
                    && snapshot.activationReassertions == 0
                    && snapshot.successes == 0
                    && snapshot.timedOut
                    && !delegate.testingForegroundRequestObservation
                        .timeoutScheduled
                    && !delegate.testingForegroundRequestObservation
                        .realityRevalidationScheduled,
                "workspace activation failure was not observable"
            )
            delegate.testingTerminateForegroundObservation()
        }

        do {
            let (delegate, first) = try fixture("stale-completion")
            delegate.testingBeginTimedForegroundRequest(first)
            let staleGeneration =
                delegate.testingForegroundSnapshot.generation
            let replacement = SelectionWindowController(candidates: candidates)
            delegate.testingInstallSelectionWindow(replacement)
            delegate.testingBeginTimedForegroundRequest(
                replacement,
                startNanoseconds: 5_000_000_000
            )
            guard let staleGeneration else {
                throw M5HarnessError.message(
                    "stale completion did not capture a generation"
                )
            }
            delegate.testingCompleteApplicationActivation(
                generation: staleGeneration,
                processMatchesCurrent: true
            )
            let snapshot = delegate.testingForegroundSnapshot
            try require(
                snapshot.target == ObjectIdentifier(replacement)
                    && snapshot.generation != staleGeneration
                    && snapshot.activationCompletions == 0
                    && snapshot.activationReassertions == 0
                    && snapshot.successes == 0,
                "stale workspace completion foregrounded obsolete target"
            )
            delegate.testingCancelForegroundRequest(replacement)
            delegate.testingTerminateForegroundObservation()
        }
        return true
    }

    private static func runForegroundRegression(
        root: String
    ) throws -> M5ForegroundResponse {
        let legacyProbe = M5AsyncOrderingProbe()
        let legacyRequest = DispatchWorkItem {
            legacyProbe.foregroundRequested = true
        }
        DispatchQueue.main.async(execute: legacyRequest)
        let legacyAsyncOrderingRejected =
            !legacyProbe.foregroundRequested
        legacyRequest.cancel()

        let candidates = makeCandidates(
            count: 1,
            root: root + "/foreground-regression"
        )
        let discovery = M5CountingDiscovery(candidates: candidates)
        let delegate = makeDelegate(
            discovery: discovery,
            root: root,
            mapping: try makeMapping(root: root),
            shortcutAvailable: true
        )
        let selection = RepositoryCardSelectionWindowController(
            inventory: RepositoryInventory(
                cards: [],
                onboardingProposals: [],
                authorityFileIdentity: nil
            )
        )
        delegate.testingInstallSelectionWindow(selection)
        selection.showWindow(nil)
        selection.window?.makeKeyAndOrderFront(nil)
        guard let expectedWindow = selection.window?.windowNumber else {
            throw M5HarnessError.message(
                "foreground regression did not create its existing window"
            )
        }
        let expectedController = ObjectIdentifier(selection)
        let sourceDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("source")
        guard let delegateSource = try? String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "AppDelegate.swift"
            ),
            encoding: .utf8
        ) else {
            throw M5HarnessError.message(
                "foreground regression could not inspect the AppKit contract"
            )
        }

        delegate.testingBeginForegroundRequest(selection)
        let pending = delegate.testingForegroundSnapshot
        delegate.testingRepeatPendingForegroundRequest(
            applicationActive: true,
            foregroundEstablished: false
        )
        let duplicate = delegate.testingForegroundSnapshot
        delegate.testingReconcileForegroundActivation(
            applicationActive: true,
            foregroundEstablished: true
        )
        let reconciled = delegate.testingForegroundSnapshot
        let inFlightDuplicateWaitedForReality =
            pending.generation != nil
            && duplicate.generation == pending.generation
            && duplicate.successes == pending.successes
            && reconciled.generation == nil
            && reconciled.successes == pending.successes + 1

        let before = reconciled
        selection.window?.miniaturize(nil)
        selection.window?.orderOut(nil)
        let firstContract =
            delegate.testingTriggerShortcutWithActivationEvidence()
        let first = delegate.testingForegroundSnapshot
        let firstWindow = delegate.testingSelectionWindowState
        let firstShortcutActivated =
            firstContract.status == noErr
            && first.activationCalls == before.activationCalls + 1
            && first.keyWindowOrders > before.keyWindowOrders
            && first.successes == before.successes + 1
            && first.generation == nil
            && firstWindow?.visible == true
            && firstWindow?.miniaturized == false
            && firstWindow?.number == expectedWindow
        let repeatedContract =
            delegate.testingTriggerShortcutWithActivationEvidence()
        let repeated = delegate.testingForegroundSnapshot
        let repeatedShortcutActivated =
            repeatedContract.status == noErr
            && repeated.activationCalls == first.activationCalls + 1
            && repeated.keyWindowOrders > first.keyWindowOrders
            && repeated.successes == first.successes + 1
            && repeated.generation == nil
            && delegate.testingSelectionWindowState?.visible == true
            && delegate.testingSelectionWindowState?.number == expectedWindow
        selection.window?.orderOut(nil)
        let beforeMenu = delegate.testingForegroundSnapshot
        delegate.testingTriggerMenuStart()
        let afterMenu = delegate.testingForegroundSnapshot
        let menuStartUsedCurrentForeground =
            afterMenu.successes == beforeMenu.successes + 1
            && delegate.testingSelectionWindowState?.visible == true
            && delegate.testingSelectionWindowState?.number == expectedWindow
            && discovery.invocationCount == 0
        let sameWindowReused =
            delegate.testSelectionControllerIdentity == expectedController
            && delegate.testingSelectionWindowState?.number == expectedWindow
            && discovery.invocationCount == 0
        let currentSpaceBehavior = selection.window?.collectionBehavior
            .contains(.moveToActiveSpace) == true
            && delegateSource.contains("NSWorkspace.shared.openApplication(")
            && delegateSource.contains("configuration.activates = true")
            && delegateSource.contains(
                "configuration.createsNewApplicationInstance = false"
            )
            && delegateSource.contains(
                "configuration.allowsRunningApplicationSubstitution = false"
            )
            && delegateSource.contains("processIdentifier == getpid()")
            && delegateSource.contains("window.isOnActiveSpace")
            && !delegateSource.contains("NSApp.activate()")
            && !delegateSource.contains("activate(ignoringOtherApps:")
        let callbackSynchronousOnMain =
            firstContract.handlerOnMain
            && firstContract.admittedBeforeReturn
            && repeatedContract.handlerOnMain
            && repeatedContract.admittedBeforeReturn
        let activationReachedBeforeReturn =
            firstContract.activationReachedBeforeReturn
            && repeatedContract.activationReachedBeforeReturn
        let realityGateCompletedBeforeReturn =
            firstContract.realityGateCompletedBeforeReturn
            && repeatedContract.realityGateCompletedBeforeReturn

        let currentRunDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let currentRunDelegate = makeDelegate(
            discovery: currentRunDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "foreground-current-run-transport"
            ),
            shortcutAvailable: true
        )
        let currentRun = RunWindowController(candidates: candidates)
        currentRunDelegate.testingInstallRunWindow(currentRun)
        currentRun.showWindow(nil)
        currentRun.window?.orderOut(nil)
        let currentRunIdentity =
            currentRunDelegate.testingRunControllerIdentity
        let currentRunContract =
            currentRunDelegate
                .testingTriggerShortcutWithActivationEvidence()
        let currentRunReused =
            currentRunContract.status == noErr
            && currentRunContract.admittedBeforeReturn
            && currentRunDelegate.testingRunControllerIdentity
                == currentRunIdentity
            && currentRunDelegate.testingRunWindowState?.visible == true
            && currentRunDiscovery.invocationCount == 0

        let completedRunDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let completedRunDelegate = makeDelegate(
            discovery: completedRunDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "foreground-completed-run-transport"
            ),
            shortcutAvailable: true
        )
        let completedRun = RunWindowController(candidates: candidates)
        let completedReport = makeReport(
            run: completedRun.testingRunID,
            results: candidates.map {
                makeResult(candidate: $0, code: .alreadyCurrent)
            }
        )
        guard completedRun.present(report: completedReport) else {
            throw M5HarnessError.message(
                "foreground regression could not settle its completed run"
            )
        }
        completedRun.testingPresentSafeWorkerExit()
        completedRun.showWindow(nil)
        completedRunDelegate.testingInstallRunWindow(completedRun)
        let completedRunOnboarding =
            CanonicalRootConfirmationWindowController(proposals: [])
        completedRunDelegate
            .testingPresentCanonicalRootOnboardingAfterInventory(
                completedRunOnboarding
            )
        let completedOnboardingIdentity =
            completedRunDelegate.testingCanonicalRootWindowIdentity
        completedRunOnboarding.window?.orderOut(nil)
        completedRunDelegate.testingTriggerShortcut()
        let onboardingRetiresCompletedRun =
            completedRunDelegate.testingRunControllerIdentity == nil
            && completedRun.window?.isVisible != true
            && completedRunDelegate.testLastReport == completedReport
        let completedRunOnboardingOwnsForeground =
            completedOnboardingIdentity != nil
            && completedRunDelegate.testingCanonicalRootWindowIdentity
                == completedOnboardingIdentity
            && completedRunDelegate.testingCanonicalRootWindowState?.visible
                == true
            && completedRunDelegate.testingHistoricalViewerIdentity == nil
            && !completedRunDelegate.testSelectionIsOpen
            && completedRunDiscovery.invocationCount == 0

        let historicalDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let historicalDelegate = makeDelegate(
            discovery: historicalDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "foreground-historical-transport"
            ),
            shortcutAvailable: true
        )
        historicalDelegate.testingSetLastReport(completedReport)
        historicalDelegate.testingShowLastReport()
        let historicalIdentity =
            historicalDelegate.testingHistoricalViewerIdentity
        historicalDelegate.testingHideHistoricalWindow()
        let historicalContract =
            historicalDelegate
                .testingTriggerShortcutWithActivationEvidence()
        let historicalReportReused =
            historicalContract.status == noErr
            && historicalContract.admittedBeforeReturn
            && historicalDelegate.testingHistoricalViewerIdentity
                == historicalIdentity
            && historicalDelegate.testingHistoricalWindowState?.visible
                == true
            && historicalDiscovery.invocationCount == 0
        let historicalOnboarding =
            CanonicalRootConfirmationWindowController(proposals: [])
        historicalDelegate
            .testingPresentCanonicalRootOnboardingAfterInventory(
                historicalOnboarding
            )
        let historicalOnboardingIdentity =
            historicalDelegate.testingCanonicalRootWindowIdentity
        historicalOnboarding.window?.orderOut(nil)
        historicalDelegate.testingTriggerShortcut()
        let onboardingRetiresHistoricalViewer =
            historicalIdentity != nil
            && historicalDelegate.testingHistoricalViewerIdentity == nil
        let historicalOnboardingOwnsForeground =
            historicalOnboardingIdentity != nil
            && historicalDelegate.testingCanonicalRootWindowIdentity
                == historicalOnboardingIdentity
            && historicalDelegate.testingCanonicalRootWindowState?.visible
                == true
            && historicalDelegate.testingRunControllerIdentity == nil
            && !historicalDelegate.testSelectionIsOpen
            && historicalDiscovery.invocationCount == 0
        let onboardingOwnsForeground =
            completedRunOnboardingOwnsForeground
            && historicalOnboardingOwnsForeground
        let surfaceRoutingCoherent =
            firstShortcutActivated
            && menuStartUsedCurrentForeground
            && currentRunReused
            && historicalReportReused
            && onboardingOwnsForeground

        completedRunOnboarding.close()
        completedRun.close()
        currentRun.close()
        historicalOnboarding.close()
        historicalDelegate.testingExplicitCloseHistoricalWindow()
        fputs(
            "M5 foreground regression: "
                + "first=\(firstShortcutActivated) "
                + "repeated=\(repeatedShortcutActivated) "
                + "menu=\(menuStartUsedCurrentForeground) "
                + "same-window=\(sameWindowReused) "
                + "current-space=\(currentSpaceBehavior) "
                + "in-flight-waited=\(inFlightDuplicateWaitedForReality) "
                + "onboarding-run=\(onboardingRetiresCompletedRun) "
                + "onboarding-history=\(onboardingRetiresHistoricalViewer) "
                + "onboarding-foreground=\(onboardingOwnsForeground)\n",
            stderr
        )
        let preflightDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let preflightDelegate = makeDelegate(
            discovery: preflightDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "inventory-preflight-transport"
            ),
            shortcutAvailable: true
        )
        guard let preflightGeneration =
                preflightDelegate
                    .testingBeginRepositoryInventoryPreflight(),
              let preflightIdentity =
                preflightDelegate.testingInventoryPreflightIdentity,
              let preflightWindow =
                preflightDelegate.testingInventoryPreflightWindowNumber else {
            throw M5HarnessError.message(
                "inventory preflight did not create its loading surface"
            )
        }
        preflightDelegate.testingRecordRepositoryInventoryAuthority(
            generation: preflightGeneration
        )
        preflightDelegate.testingRecordRepositoryInventoryChild(
            generation: preflightGeneration,
            count: 1
        )
        let preflightTrace = preflightDelegate.testLifecycleTrace
        let surfaceIndex = preflightTrace.firstIndex(
            of: "inventory:surface_presented:\(preflightGeneration)"
        )
        let authorityIndex = preflightTrace.firstIndex(
            of: "inventory:authority_acquired:\(preflightGeneration)"
        )
        let childIndex = preflightTrace.firstIndex(
            of: "inventory:child:\(preflightGeneration):1"
        )
        let preflightSurfaceOrdering =
            surfaceIndex != nil
            && authorityIndex != nil
            && childIndex != nil
            && surfaceIndex! < authorityIndex!
            && authorityIndex! < childIndex!
        let loadingSurfaceIsCurrent =
            preflightDelegate.testingInventoryPreflightIsLoading
            && preflightDelegate.testSelectionControllerIdentity
                == preflightIdentity
            && preflightDelegate.testingSelectionWindowState?.visible == true
            && preflightDelegate.testInventoryDiscoveryStartCount == 1

        preflightDelegate.testingHideSelectionWindow()
        preflightDelegate.testingTriggerMenuStart()
        preflightDelegate.testingHideSelectionWindow()
        preflightDelegate.testingTriggerShortcut()
        let initialLoadingRoutesReuseSurface =
            preflightDelegate.testingInventoryPreflightIdentity
                == preflightIdentity
            && preflightDelegate.testingInventoryPreflightWindowNumber
                == preflightWindow
            && preflightDelegate.testingSelectionWindowState?.visible == true
            && preflightDelegate.testInventoryDiscoveryStartCount == 1
            && preflightDiscovery.invocationCount == 0
        let staleInventoryCompletionIgnored =
            !preflightDelegate.testingCompleteRepositoryInventoryFailure(
                generation: preflightGeneration &+ 1
            )
            && preflightDelegate.testingInventoryPreflightIsLoading
        let completedFailure =
            preflightDelegate.testingCompleteRepositoryInventoryFailure(
                generation: preflightGeneration
            )
        let inventoryFailureIsRecoverable =
            completedFailure
            && preflightDelegate.testingInventoryPreflightIdentity
                == preflightIdentity
            && preflightDelegate.testingInventoryFailureState?.0
                .contains("Try again") == true
            && preflightDelegate.testingInventoryFailureState?.1 == true

        let beginFailureDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "begin-failure-transport"
            ),
            shortcutAvailable: true
        )
        beginFailureDelegate.testingForceNextInventoryBeginFailure(
            hidden: false
        )
        guard let failedBeginGeneration =
                beginFailureDelegate
                    .testingBeginRepositoryInventoryPreflight(),
              let failedBeginController =
                beginFailureDelegate.testingInventoryController else {
            throw M5HarnessError.message(
                "visible inventory begin failure did not resolve"
            )
        }
        let visibleBeginFailureResolved =
            beginFailureDelegate.testingSelectionWindowIsVisible
            && failedBeginController.testingRenderingState == "failure"
            && failedBeginController.testingInventoryRetryVisible
            && !beginFailureDelegate.testInventoryDiscoveryInProgress
            && beginFailureDelegate.testingActiveInventoryGeneration == nil
            && !beginFailureDelegate.testingInventoryCancellationExists
            && beginFailureDelegate.testLifecycleTrace.contains(
                "inventory:begin_failed:\(failedBeginGeneration):injected"
            )
        failedBeginController.testingActivateInventoryRetry()
        failedBeginController.testingActivateInventoryRetry()
        guard let beginRetryGeneration =
                beginFailureDelegate.testingActiveInventoryGeneration else {
            throw M5HarnessError.message(
                "inventory begin failure retry did not start"
            )
        }
        let beginFailureRetryStartsOnce =
            beginFailureDelegate.testInventoryRetryCount == 1
            && beginFailureDelegate.testInventoryDiscoveryStartCount == 1
            && beginFailureDelegate.testInventoryDiscoveryInProgress
            && beginRetryGeneration != failedBeginGeneration
            && failedBeginController.testingRenderingState == "preparing"
        let beginFailureStaleGenerationIgnored =
            !beginFailureDelegate
                .testingCompleteRepositoryInventoryFailure(
                    generation: failedBeginGeneration
                )
            && beginFailureDelegate.testingActiveInventoryGeneration
                == beginRetryGeneration
            && failedBeginController.testingRenderingState == "preparing"
        _ = beginFailureDelegate
            .testingCompleteRepositoryInventoryFailure(
                generation: beginRetryGeneration
            )

        let hiddenBeginDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "hidden-begin-failure-transport"
            ),
            shortcutAvailable: true
        )
        hiddenBeginDelegate.testingForceNextInventoryBeginFailure(
            hidden: true
        )
        guard hiddenBeginDelegate
                .testingBeginRepositoryInventoryPreflight() != nil,
              let hiddenBeginController =
                hiddenBeginDelegate.testingInventoryController else {
            throw M5HarnessError.message(
                "hidden inventory begin failure did not resolve"
            )
        }
        let hiddenBeginStayedHidden =
            !hiddenBeginDelegate.testingSelectionWindowIsVisible
            && hiddenBeginController.testingRenderingState == "failure"
            && hiddenBeginController.testingInventoryRetryVisible
            && !hiddenBeginDelegate.testInventoryDiscoveryInProgress
        hiddenBeginDelegate.testingTriggerShortcut()
        let hiddenBeginFailureResolved =
            hiddenBeginStayedHidden
            && hiddenBeginDelegate.testingSelectionWindowIsVisible
            && hiddenBeginController.testingRenderingState == "failure"
            && hiddenBeginDelegate.testInventoryDiscoveryStartCount == 0

        final class BeginQuitCounter {
            var value = 0
        }
        let beginQuitCounter = BeginQuitCounter()
        let beginQuitDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0],
            discovery: M5CountingDiscovery(candidates: candidates),
            testingRoot: root,
            testingMapping: try makeMapping(
                root: root,
                localName: "begin-failure-quit-transport"
            ),
            testingConfirmation: { .alertFirstButtonReturn },
            testingLogOpener: { _ in true },
            testingShortcutAvailable: true,
            testingQuitHandler: { beginQuitCounter.value += 1 }
        )
        beginQuitDelegate.testingForceNextInventoryBeginFailure(
            hidden: true,
            queuedQuit: true
        )
        _ = beginQuitDelegate
            .testingBeginRepositoryInventoryPreflight()
        let beginFailureQueuedQuit =
            beginQuitCounter.value == 1
            && beginQuitDelegate.testInventoryTerminationCount == 1
            && !beginQuitDelegate.testingInventoryQuitIsPending
            && !beginQuitDelegate.testInventoryDiscoveryInProgress
            && beginQuitDelegate.testingActiveInventoryGeneration == nil
            && !beginQuitDelegate.testingInventoryCancellationExists
            && !beginQuitDelegate.testSelectionIsOpen
            && !beginQuitDelegate.testingSelectionWindowIsVisible
        let beginFailureLoggingContract =
            delegateSource.contains(
                "inventory_begin_failed generation="
            )
            && delegateSource.contains(
                "case discoveryBusy = \"discovery_busy\""
            )
            && delegateSource.contains(
                "case authorityCommitBusy = \"authority_commit_busy\""
            )

        let oldInventory = try makeRepositoryCardInventory(
            root: root,
            index: 70
        )
        let newInventory = try makeRepositoryCardInventory(
            root: root,
            index: 71
        )
        let onboardingInventory = try makeRepositoryCardInventory(
            root: root,
            index: 72,
            requiresOnboarding: true
        )
        let visibleOnboardingDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "visible-onboarding-transport"
            ),
            shortcutAvailable: true
        )
        guard let visibleOnboardingGeneration =
                visibleOnboardingDelegate
                    .testingBeginRepositoryInventoryPreflight() else {
            throw M5HarnessError.message(
                "visible onboarding preflight did not start"
            )
        }
        let visibleOnboardingCompleted =
            visibleOnboardingDelegate
                .testingCompleteRepositoryInventorySuccess(
                    onboardingInventory,
                    generation: visibleOnboardingGeneration
                )
        let visibleOnboardingPrecedesCards =
            visibleOnboardingCompleted
            && visibleOnboardingDelegate.testingHasPendingOnboarding
            && visibleOnboardingDelegate
                .testingPendingOnboardingGeneration
                == visibleOnboardingGeneration
            && visibleOnboardingDelegate
                .testingCanonicalRootWindowState?.visible == true
            && !visibleOnboardingDelegate.testSelectionIsOpen
        visibleOnboardingDelegate.testingCancelPendingOnboarding()
        let onboardingCancelRemainsGated =
            visibleOnboardingDelegate.testingHasPendingOnboarding
            && visibleOnboardingDelegate
                .testingCanonicalRootWindowIdentity == nil
            && !visibleOnboardingDelegate.testSelectionIsOpen
        visibleOnboardingDelegate.testingTriggerShortcut()
        let pendingOnboardingReopensFirst =
            visibleOnboardingDelegate.testingHasPendingOnboarding
            && visibleOnboardingDelegate
                .testingCanonicalRootWindowState?.visible == true
            && !visibleOnboardingDelegate.testSelectionIsOpen
            && visibleOnboardingDelegate
                .testingCurrentOperatorSurfaceKind(explicit: true)
                == "canonical_root"
        visibleOnboardingDelegate.testingConfirmPendingOnboarding()
        visibleOnboardingDelegate.testingConfirmPendingOnboarding()
        let onboardingConfirmationBuildsCardsOnce =
            !visibleOnboardingDelegate.testingHasPendingOnboarding
            && visibleOnboardingDelegate
                .testingCanonicalRootWindowIdentity == nil
            && visibleOnboardingDelegate.testSelectionIsOpen
            && visibleOnboardingDelegate
                .testingInventoryController?.testingRenderingState
                == "inventory"
            && visibleOnboardingDelegate
                .testCanonicalRootInventoryPresentationCount == 1

        let hiddenOnboardingDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "hidden-onboarding-transport"
            ),
            shortcutAvailable: true
        )
        guard let hiddenOnboardingGeneration =
                hiddenOnboardingDelegate
                    .testingBeginRepositoryInventoryPreflight() else {
            throw M5HarnessError.message(
                "hidden onboarding preflight did not start"
            )
        }
        hiddenOnboardingDelegate.testingCloseSelectionWindow()
        let staleOnboardingIgnored =
            !hiddenOnboardingDelegate
                .testingCompleteRepositoryInventorySuccess(
                    onboardingInventory,
                    generation: hiddenOnboardingGeneration &+ 1
                )
            && !hiddenOnboardingDelegate.testingHasPendingOnboarding
        let hiddenOnboardingCompleted =
            hiddenOnboardingDelegate
                .testingCompleteRepositoryInventorySuccess(
                    onboardingInventory,
                    generation: hiddenOnboardingGeneration
                )
        let hiddenOnboardingRemainsGated =
            staleOnboardingIgnored
            && hiddenOnboardingCompleted
            && hiddenOnboardingDelegate.testingHasPendingOnboarding
            && hiddenOnboardingDelegate
                .testingCanonicalRootWindowIdentity == nil
            && !hiddenOnboardingDelegate.testSelectionIsOpen
            && !hiddenOnboardingDelegate
                .testingSelectionWindowIsVisible

        final class PendingOnboardingQuitCounter {
            var value = 0
        }
        let pendingQuitCounter = PendingOnboardingQuitCounter()
        let pendingQuitDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0],
            discovery: M5CountingDiscovery(candidates: candidates),
            testingRoot: root,
            testingMapping: try makeMapping(
                root: root,
                localName: "pending-onboarding-quit-transport"
            ),
            testingConfirmation: { .alertFirstButtonReturn },
            testingLogOpener: { _ in true },
            testingShortcutAvailable: true,
            testingQuitHandler: { pendingQuitCounter.value += 1 }
        )
        guard let pendingQuitGeneration =
                pendingQuitDelegate
                    .testingBeginRepositoryInventoryPreflight() else {
            throw M5HarnessError.message(
                "pending onboarding quit preflight did not start"
            )
        }
        pendingQuitDelegate.testingCloseSelectionWindow()
        _ = pendingQuitDelegate
            .testingCompleteRepositoryInventorySuccess(
                onboardingInventory,
                generation: pendingQuitGeneration
            )
        pendingQuitDelegate.testQuitUtility()
        let pendingOnboardingQuitAndStaleSafe =
            hiddenOnboardingRemainsGated
            && pendingQuitCounter.value == 1
            && pendingQuitDelegate.testInventoryTerminationCount == 1
            && !pendingQuitDelegate.testingHasPendingOnboarding
            && pendingQuitDelegate
                .testingCanonicalRootWindowIdentity == nil
            && !pendingQuitDelegate.testSelectionIsOpen
        let reuseDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "inventory-reuse-transport"
            ),
            shortcutAvailable: true
        )
        let reuseController = RepositoryCardSelectionWindowController(
            inventory: oldInventory
        )
        reuseController.showWindow(nil)
        reuseDelegate.testingInstallSelectionWindow(reuseController)
        let reuseIdentity = ObjectIdentifier(reuseController)
        let reuseWindow = reuseController.window?.windowNumber
        let reuseFrame = reuseController.window?.frame
        let oldContentIdentity =
            reuseController.testingContentViewIdentity
        let oldActionControls = Set(
            reuseController.testingLiveActionControlIdentities
        )
        let oldInstallationCount =
            reuseController.testingContentInstallationCount
        guard let reuseGeneration =
                reuseDelegate.testingBeginRepositoryInventoryPreflight()
                else {
            throw M5HarnessError.message(
                "completed card controller did not begin refresh"
            )
        }
        let loadingActionControls = Set(
            reuseController.testingLiveActionControlIdentities
        )
        let reusedContentReplacedByLoading =
            reuseDelegate.testingInventoryPreflightIdentity
                == reuseIdentity
            && reuseController.window?.windowNumber == reuseWindow
            && reuseController.window?.frame == reuseFrame
            && reuseController.testingRenderingState == "preparing"
            && reuseController.testingContentViewIdentity
                != oldContentIdentity
            && reuseController.testingContentInstallationCount
                == oldInstallationCount + 1
        let staleInventoryControlsUnavailable =
            oldActionControls.isDisjoint(with: loadingActionControls)
            && reuseController
                .testingDeactivatedControlsAreUnreachable
        reuseDelegate.testingHideSelectionWindow()
        reuseDelegate.testingTriggerMenuStart()
        reuseDelegate.testingHideSelectionWindow()
        reuseDelegate.testingTriggerShortcut()
        let reuseRoutesSameWindow =
            reuseDelegate.testingInventoryPreflightIdentity
                == reuseIdentity
            && reuseController.window?.windowNumber == reuseWindow
            && reuseDelegate.testInventoryDiscoveryStartCount == 1
        let loadingContentIdentity =
            reuseController.testingContentViewIdentity
        let reuseFailureCompleted =
            reuseDelegate.testingCompleteRepositoryInventoryFailure(
                generation: reuseGeneration
            )
        let reusedFailureIsVisible =
            reuseFailureCompleted
            && reuseController.testingRenderingState == "failure"
            && reuseController.testingContentViewIdentity
                != loadingContentIdentity
            && reuseController.testingInventoryRetryVisible
            && reuseController.testingInventoryStatus
                .contains("Try again")
        reuseController.testingActivateInventoryRetry()
        reuseController.testingActivateInventoryRetry()
        let reusedRetryConfigured =
            reuseDelegate.testInventoryRetryCount == 1
            && reuseDelegate.testInventoryDiscoveryStartCount == 2
            && reuseDelegate.testInventoryDiscoveryInProgress
            && reuseController.testingRenderingState == "preparing"
        if let retryGeneration =
                reuseDelegate.testingActiveInventoryGeneration {
            _ = reuseDelegate
                .testingCompleteRepositoryInventoryFailure(
                    generation: retryGeneration
                )
        }

        let completionDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "inventory-completion-transport"
            ),
            shortcutAvailable: true
        )
        let completionController =
            RepositoryCardSelectionWindowController(
                inventory: oldInventory
            )
        completionController.showWindow(nil)
        completionDelegate.testingInstallSelectionWindow(
            completionController
        )
        guard let completionGeneration =
                completionDelegate
                    .testingBeginRepositoryInventoryPreflight() else {
            throw M5HarnessError.message(
                "completion controller did not begin refresh"
            )
        }
        let completionLoadingCount =
            completionController.testingContentInstallationCount
        let staleSuccessIgnored =
            !completionDelegate.testingCompleteRepositoryInventorySuccess(
                newInventory,
                generation: completionGeneration &+ 1
            )
            && completionController.testingContentInstallationCount
                == completionLoadingCount
            && completionController.testingRenderingState == "preparing"
        let currentSuccess =
            completionDelegate.testingCompleteRepositoryInventorySuccess(
                newInventory,
                generation: completionGeneration
            )
        let installedCount =
            completionController.testingContentInstallationCount
        let staleAfterSuccessIgnored =
            !completionDelegate.testingCompleteRepositoryInventorySuccess(
                oldInventory,
                generation: completionGeneration
            )
            && completionController.testingContentInstallationCount
                == installedCount
        let currentCompletionInstalledOnce =
            staleSuccessIgnored
            && currentSuccess
            && staleAfterSuccessIgnored
            && completionDelegate.testingInventoryPreflightIdentity
                == ObjectIdentifier(completionController)
            && completionController.window?.windowNumber
                == completionDelegate
                    .testingInventoryPreflightWindowNumber
            && completionController.testingRenderingState == "inventory"
            && installedCount == completionLoadingCount + 1
        let repeatedLoadingRoutesReuseSurface =
            initialLoadingRoutesReuseSurface
            && reuseRoutesSameWindow

        let hiddenSuccessDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "hidden-success-transport"
            ),
            shortcutAvailable: true
        )
        guard let hiddenSuccessGeneration =
                hiddenSuccessDelegate
                    .testingBeginRepositoryInventoryPreflight(),
              let hiddenSuccessController =
                hiddenSuccessDelegate.testingInventoryController else {
            throw M5HarnessError.message(
                "hidden success preflight did not start"
            )
        }
        let hiddenSuccessIdentity =
            ObjectIdentifier(hiddenSuccessController)
        hiddenSuccessDelegate.testingCloseSelectionWindow()
        let hiddenSuccessRetained =
            !hiddenSuccessDelegate.testingSelectionWindowIsVisible
            && hiddenSuccessDelegate.testingInventoryPreflightIdentity
                == hiddenSuccessIdentity
            && hiddenSuccessDelegate.testInventoryDiscoveryInProgress
        let staleHiddenCompletionIgnored =
            !hiddenSuccessDelegate
                .testingCompleteRepositoryInventorySuccess(
                    newInventory,
                    generation: hiddenSuccessGeneration &+ 1
                )
            && hiddenSuccessController.testingRenderingState
                == "preparing"
            && !hiddenSuccessDelegate.testingSelectionWindowIsVisible
        let hiddenSuccessCompleted =
            hiddenSuccessDelegate
                .testingCompleteRepositoryInventorySuccess(
                    newInventory,
                    generation: hiddenSuccessGeneration
                )
        let hiddenSuccessStayedHidden =
            hiddenSuccessCompleted
            && !hiddenSuccessDelegate.testingSelectionWindowIsVisible
            && !hiddenSuccessDelegate.testInventoryDiscoveryInProgress
            && hiddenSuccessController.testingRenderingState
                == "inventory"
        hiddenSuccessDelegate.testingTriggerMenuStart()
        let hiddenSuccessRecovered =
            hiddenSuccessRetained
            && hiddenSuccessStayedHidden
            && hiddenSuccessDelegate.testingSelectionWindowIsVisible
            && hiddenSuccessDelegate.testingInventoryPreflightIdentity
                == hiddenSuccessIdentity
            && hiddenSuccessDelegate.testInventoryDiscoveryStartCount == 1
        let onboardedHiddenCompletionPreserved =
            hiddenSuccessRecovered
            && !hiddenSuccessDelegate.testingHasPendingOnboarding

        let hiddenFailureDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "hidden-failure-transport"
            ),
            shortcutAvailable: true
        )
        guard let hiddenFailureGeneration =
                hiddenFailureDelegate
                    .testingBeginRepositoryInventoryPreflight(),
              let hiddenFailureController =
                hiddenFailureDelegate.testingInventoryController else {
            throw M5HarnessError.message(
                "hidden failure preflight did not start"
            )
        }
        let hiddenFailureIdentity =
            ObjectIdentifier(hiddenFailureController)
        hiddenFailureDelegate.testingCloseSelectionWindow()
        hiddenFailureDelegate.testingTriggerShortcut()
        let pendingHiddenReshow =
            hiddenFailureDelegate.testingSelectionWindowIsVisible
            && hiddenFailureDelegate.testingInventoryPreflightIdentity
                == hiddenFailureIdentity
            && hiddenFailureDelegate.testInventoryDiscoveryStartCount == 1
        hiddenFailureDelegate.testingCloseSelectionWindow()
        let hiddenFailureCompleted =
            hiddenFailureDelegate
                .testingCompleteRepositoryInventoryFailure(
                    generation: hiddenFailureGeneration
                )
        let hiddenFailureStayedHidden =
            hiddenFailureCompleted
            && !hiddenFailureDelegate.testingSelectionWindowIsVisible
            && hiddenFailureController.testingRenderingState == "failure"
            && hiddenFailureController.testingInventoryRetryVisible
        hiddenFailureDelegate.testingTriggerShortcut()
        hiddenFailureController.testingActivateInventoryRetry()
        hiddenFailureController.testingActivateInventoryRetry()
        let hiddenFailureRetry =
            hiddenFailureStayedHidden
            && hiddenFailureDelegate.testingSelectionWindowIsVisible
            && hiddenFailureDelegate.testingInventoryPreflightIdentity
                == hiddenFailureIdentity
            && hiddenFailureDelegate.testInventoryRetryCount == 1
            && hiddenFailureDelegate.testInventoryDiscoveryStartCount == 2
            && hiddenFailureDelegate.testInventoryDiscoveryInProgress
        if let retryGeneration =
                hiddenFailureDelegate.testingActiveInventoryGeneration {
            _ = hiddenFailureDelegate
                .testingCompleteRepositoryInventoryFailure(
                    generation: retryGeneration
                )
        }

        let priorityDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "surface-priority-transport"
            ),
            shortcutAvailable: true
        )
        let staleRun = RunWindowController(candidates: candidates)
        priorityDelegate.testingInstallRunWindow(staleRun)
        staleRun.showWindow(nil)
        guard let priorityGeneration =
                priorityDelegate
                    .testingBeginRepositoryInventoryPreflight(),
              let priorityController =
                priorityDelegate.testingInventoryController else {
            throw M5HarnessError.message(
                "surface priority preflight did not start"
            )
        }
        let priorityIdentity = ObjectIdentifier(priorityController)
        priorityDelegate.testingCloseSelectionWindow()
        let hiddenSurfaceInvocationPriority =
            priorityDelegate.testingCurrentOperatorSurfaceKind(
                explicit: true
            ) == "repository_cards"
            && priorityDelegate.testingCurrentOperatorSurfaceKind(
                explicit: false
            ) == "run"
            && !priorityDelegate.testingSelectionWindowIsVisible
            && staleRun.window?.isVisible == true
        priorityDelegate.testingTriggerShortcut()
        let hotkeyChoseLoading =
            priorityDelegate.testingSelectionWindowIsVisible
            && priorityDelegate.testingInventoryPreflightIdentity
                == priorityIdentity
            && priorityDelegate.testInventoryDiscoveryStartCount == 1
        priorityDelegate.testingHideSelectionWindow()
        priorityDelegate.testingTriggerMenuStart()
        let startChoseLoading =
            priorityDelegate.testingSelectionWindowIsVisible
            && priorityDelegate.testingInventoryPreflightIdentity
                == priorityIdentity
            && priorityDelegate.testInventoryDiscoveryStartCount == 1
        priorityDelegate.testingHideSelectionWindow()
        priorityDelegate.testingHandleDuplicateActivation()
        let reopenChoseLoading =
            priorityDelegate.testingSelectionWindowIsVisible
            && priorityDelegate.testingInventoryPreflightIdentity
                == priorityIdentity
            && priorityDelegate.testInventoryDiscoveryStartCount == 1
        let dualWindowInventoryPriority =
            hotkeyChoseLoading
            && startChoseLoading
            && reopenChoseLoading
        _ = priorityDelegate
            .testingCompleteRepositoryInventoryFailure(
                generation: priorityGeneration
            )
        priorityDelegate.testingHideSelectionWindow()
        staleRun.showWindow(nil)
        priorityDelegate.testingTriggerShortcut()
        let failureSurfacePriority =
            priorityDelegate.testingSelectionWindowIsVisible
            && priorityController.testingRenderingState == "failure"
            && priorityController.testingInventoryRetryVisible
            && priorityDelegate.testingCurrentOperatorSurfaceKind(
                explicit: true
            ) == "repository_cards"
        priorityDelegate.testingRequestStartOperationContention()
        let blockingSurfacePriority =
            priorityDelegate.testingCurrentOperatorSurfaceKind(
                explicit: true
            ) == "contention"
        priorityDelegate.testingTriggerShortcut()
        priorityDelegate
            .testingCloseOperationContentionPresentation()
        priorityDelegate.testingRemoveSelectionWindow()
        staleRun.window?.orderOut(nil)
        priorityDelegate.testingTriggerShortcut()
        let retiredSelectionRunPriority =
            priorityDelegate.testingCurrentOperatorSurfaceKind(
                explicit: true
            ) == "run"
            && priorityDelegate.testingRunWindowIsVisible

        final class QuitCounter {
            var value = 0
        }
        let quitCounter = QuitCounter()
        let quitDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0],
            discovery: M5CountingDiscovery(candidates: candidates),
            testingRoot: root,
            testingMapping: try makeMapping(
                root: root,
                localName: "inventory-quit-transport"
            ),
            testingConfirmation: { .alertFirstButtonReturn },
            testingLogOpener: { _ in true },
            testingShortcutAvailable: true,
            testingQuitHandler: { quitCounter.value += 1 }
        )
        guard let quitGeneration =
                quitDelegate.testingBeginRepositoryInventoryPreflight() else {
            throw M5HarnessError.message(
                "inventory quit preflight did not begin"
            )
        }
        quitDelegate.testingRecordRepositoryInventoryAuthority(
            generation: quitGeneration
        )
        quitDelegate.testingRecordRepositoryInventoryChild(
            generation: quitGeneration,
            count: 1
        )
        quitDelegate.testingCloseSelectionWindow()
        let quitSurfaceStayedHidden =
            !quitDelegate.testingSelectionWindowIsVisible
            && quitDelegate.testingInventoryPreflightIdentity != nil
        quitDelegate.testQuitUtility()
        quitDelegate.testQuitUtility()
        quitDelegate.testingRecordRepositoryInventoryChild(
            generation: quitGeneration,
            count: 2
        )
        let noSecondChild = !quitDelegate.testLifecycleTrace.contains(
            "inventory:child:\(quitGeneration):2"
        )
        let quitStoppedAdmissions =
            quitDelegate.testingInventoryFutureChildrenStopped
        let quitCompleted =
            quitDelegate.testingCompleteRepositoryInventoryFailure(
                generation: quitGeneration
            )
        let ownedInventoryQuitLifecycle =
            quitStoppedAdmissions
            && noSecondChild
            && quitCompleted
            && quitDelegate.testOwnedInventoryQuitCount == 1
            && quitDelegate.testInventoryTerminationCount == 1
            && quitCounter.value == 1
            && !quitDelegate.testOperationContentionHasPendingRetry
            && !quitDelegate.testSelectionIsOpen
        let hiddenQuitNoResurface =
            quitSurfaceStayedHidden
            && !quitDelegate.testingSelectionWindowIsVisible
            && quitCounter.value == 1

        let lifecycleLoggingContract =
            delegateSource.contains("action entry action=")
            && delegateSource.contains("target selected generation=")
            && delegateSource.contains("inventory requested generation=")
            && delegateSource.contains("inventory surface_presented generation=")
            && delegateSource.contains("inventory authority_acquired generation=")
            && delegateSource.contains("inventory child generation=")
            && delegateSource.contains("ownership=owned intent=quit")
            && delegateSource.contains("ownership=external intent=")
            && delegateSource.contains("contention requested token=")
            && delegateSource.contains("contention closed token=")
            && delegateSource.contains("contention resumed token=")

        let timingMatrixPassed = try runForegroundTimingRegression(root: root)
        let carbonCollision = testActualCarbonCollision()
        return M5ForegroundResponse(
            legacyAsyncOrderingRejected: legacyAsyncOrderingRejected,
            callbackSynchronousOnMain: callbackSynchronousOnMain,
            activationReachedBeforeReturn: activationReachedBeforeReturn,
            realityGateCompletedBeforeReturn:
                realityGateCompletedBeforeReturn,
            firstShortcutActivated: firstShortcutActivated,
            repeatedShortcutActivated: repeatedShortcutActivated,
            sameWindowReused: sameWindowReused,
            currentSpaceBehavior: currentSpaceBehavior,
            inFlightDuplicateWaitedForReality:
                inFlightDuplicateWaitedForReality,
            onboardingRetiresCompletedRun:
                onboardingRetiresCompletedRun,
            onboardingRetiresHistoricalViewer:
                onboardingRetiresHistoricalViewer,
            onboardingOwnsForeground: onboardingOwnsForeground,
            surfaceRoutingCoherent: surfaceRoutingCoherent,
            collisionBlockerRegistered:
                carbonCollision.blockerRegistered,
            collisionSurfaced: carbonCollision.collisionSurfaced,
            collisionReleaseThenInvocationSucceeded:
                carbonCollision.releaseThenInvocationSucceeded,
            shortcutHandlerIsolationPassed:
                carbonCollision.handlerIsolationPassed,
            productionShortcutDefaultsPreserved:
                carbonCollision.productionDefaultsPreserved,
            registrationConflictPassed: carbonCollision.passed,
            timingMatrixPassed: timingMatrixPassed,
            foregroundObserversCleaned: timingMatrixPassed,
            preflightSurfaceOrdering: preflightSurfaceOrdering,
            loadingSurfaceIsCurrent: loadingSurfaceIsCurrent,
            repeatedLoadingRoutesReuseSurface:
                repeatedLoadingRoutesReuseSurface,
            staleInventoryCompletionIgnored:
                staleInventoryCompletionIgnored,
            inventoryFailureIsRecoverable:
                inventoryFailureIsRecoverable,
            reusedContentReplacedByLoading:
                reusedContentReplacedByLoading,
            staleInventoryControlsUnavailable:
                staleInventoryControlsUnavailable,
            reusedFailureIsVisible: reusedFailureIsVisible,
            currentCompletionInstalledOnce:
                currentCompletionInstalledOnce,
            hiddenSuccessRecovered: hiddenSuccessRecovered,
            hiddenFailureRetry: hiddenFailureRetry,
            pendingHiddenReshow: pendingHiddenReshow,
            hiddenQuitNoResurface: hiddenQuitNoResurface,
            reusedRetryConfigured: reusedRetryConfigured,
            staleHiddenCompletionIgnored:
                staleHiddenCompletionIgnored,
            dualWindowInventoryPriority:
                dualWindowInventoryPriority,
            failureSurfacePriority: failureSurfacePriority,
            blockingSurfacePriority: blockingSurfacePriority,
            retiredSelectionRunPriority:
                retiredSelectionRunPriority,
            hiddenSurfaceInvocationPriority:
                hiddenSurfaceInvocationPriority,
            visibleBeginFailureResolved:
                visibleBeginFailureResolved,
            hiddenBeginFailureResolved:
                hiddenBeginFailureResolved,
            beginFailureRetryStartsOnce:
                beginFailureRetryStartsOnce,
            beginFailureQueuedQuit: beginFailureQueuedQuit,
            beginFailureStaleGenerationIgnored:
                beginFailureStaleGenerationIgnored,
            beginFailureLoggingContract:
                beginFailureLoggingContract,
            visibleOnboardingPrecedesCards:
                visibleOnboardingPrecedesCards,
            hiddenOnboardingRemainsGated:
                hiddenOnboardingRemainsGated,
            pendingOnboardingReopensFirst:
                pendingOnboardingReopensFirst,
            onboardingCancelRemainsGated:
                onboardingCancelRemainsGated,
            onboardingConfirmationBuildsCardsOnce:
                onboardingConfirmationBuildsCardsOnce,
            pendingOnboardingQuitAndStaleSafe:
                pendingOnboardingQuitAndStaleSafe,
            onboardedHiddenCompletionPreserved:
                onboardedHiddenCompletionPreserved,
            ownedInventoryQuitLifecycle:
                ownedInventoryQuitLifecycle,
            lifecycleLoggingContract: lifecycleLoggingContract
        )
    }

    private static func runConfirmationCloseRegression(
        root: String
    ) throws -> M5ConfirmationCloseResponse {
        func pumpRunLoop(seconds: TimeInterval) {
            let deadline = MonotonicDeadline(seconds: seconds)
            while !deadline.hasExpired {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
        }

        let candidates = makeCandidates(
            count: 1,
            root: root + "/confirmation-close"
        )
        let delegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "confirmation-close-transport"
            ),
            shortcutAvailable: true
        )
        let emptyInventory = RepositoryInventory(
            cards: [],
            onboardingProposals: [],
            authorityFileIdentity: nil
        )
        let closingCard = RepositoryCardSelectionWindowController(
            inventory: emptyInventory
        )
        delegate.testingBeginRealConfirmation(
            selected: candidates,
            selectionController: closingCard
        )
        pumpRunLoop(seconds: 0.15)
        let closeSetup = delegate.testingConfirmationState.open
            && closingCard.window?.attachedSheet != nil
        closingCard.close()
        let closed = delegate.testingConfirmationState
        let closeClearsSession = closeSetup
            && !closed.open
            && !closed.armed
            && !closed.hasRun
            && !closed.selectionOpen
            && closingCard.window?.attachedSheet == nil
            && delegate.testBeginRunCount == 0
            && delegate.testConfirmationClearCount == 1

        let retryCard = RepositoryCardSelectionWindowController(
            inventory: emptyInventory
        )
        delegate.testingBeginRealConfirmation(
            selected: candidates,
            selectionController: retryCard
        )
        pumpRunLoop(seconds: 0.15)
        let retrySetup = delegate.testingConfirmationState.open
            && retryCard.window?.attachedSheet != nil
            && delegate.testConfirmationClearCount == 1
        if retrySetup {
            delegate.testingActivateConfirmationStart()
            pumpRunLoop(seconds: 0.05)
        }
        let retried = delegate.testingConfirmationState
        let retryStartsRun = retrySetup
            && retried.hasRun
            && !retried.selectionOpen
            && delegate.testBeginRunCount == 1
            && delegate.testConfirmationClearCount == 2

        let presentationDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let presentationDelegate = makeDelegate(
            discovery: presentationDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "card-presentation-transport"
            ),
            shortcutAvailable: true
        )
        let presentationCard = RepositoryCardSelectionWindowController(
            inventory: emptyInventory
        )
        presentationCard.showWindow(nil)
        presentationDelegate.testingInstallSelectionWindow(
            presentationCard
        )
        let presentationIdentity =
            presentationDelegate.testSelectionControllerIdentity
        presentationCard.window?.orderOut(nil)
        let hiddenCardRemainsOpen = presentationCard.isPresentationOpen
            && presentationDelegate.testingSelectionWindowState?.visible
                == false
            && presentationDelegate.testSelectionControllerIdentity
                == presentationIdentity

        presentationDelegate.testingTriggerShortcut()
        let hiddenReuse =
            presentationDelegate.testSelectionControllerIdentity
                == presentationIdentity
            && presentationDelegate.testingSelectionWindowState?.visible
                == true
            && presentationDiscovery.invocationCount == 0

        let onboardingDiscovery = M5CountingDiscovery(candidates: candidates)
        let onboardingDelegate = makeDelegate(
            discovery: onboardingDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "onboarding-presentation-transport"
            ),
            shortcutAvailable: true
        )
        let onboarding =
            CanonicalRootConfirmationWindowController(proposals: [])
        onboarding.showWindow(nil)
        onboardingDelegate.testingInstallCanonicalRootWindow(onboarding)
        let onboardingIdentity =
            onboardingDelegate.testingCanonicalRootWindowIdentity
        onboarding.window?.orderOut(nil)
        let hiddenOnboardingRemainsOpen = onboarding.isPresentationOpen
            && onboardingDelegate.testingCanonicalRootWindowState?.visible
                == false
            && onboardingDelegate.testingCanonicalRootWindowIdentity
                == onboardingIdentity

        onboardingDelegate.testingTriggerShortcut()
        let onboardingReused =
            onboardingDelegate.testingCanonicalRootWindowIdentity
                == onboardingIdentity
            && onboardingDelegate.testingCanonicalRootWindowState?.visible
                == true
            && onboardingDiscovery.invocationCount == 0
        onboarding.close()
        let onboardingReactivationReuses = onboardingReused
            && onboardingDelegate.testingCanonicalRootWindowIdentity == nil

        let busyDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let busyDelegate = makeDelegate(
            discovery: busyDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "authority-busy-discovery-transport"
            ),
            shortcutAvailable: true
        )
        let beganSilentDiscovery =
            busyDelegate.testingBeginRepositoryInventoryDiscovery(
                presentResult: false
            )
        busyDelegate.testingTriggerShortcut()
        busyDelegate.testingTriggerShortcut()
        let discoveryActivationShowsProgress =
            beganSilentDiscovery
            && busyDelegate.testDiscoveryPresentation?.0
                == "Repository scan in progress"
            && busyDelegate.testDiscoveryPresentation?.1.contains(
                "normal repository selection will appear when it finishes"
            ) == true
            && busyDelegate.testDiscoveryPresentationCount == 1
            && busyDelegate.testInventoryPresentationPending
            && busyDelegate.testInventoryDiscoveryInProgress
            && busyDelegate.testInventoryDiscoveryStartCount == 1
            && busyDelegate
                .testInventoryDiscoveryBusyPresentationCount == 1
            && !busyDelegate.testSelectionIsOpen
            && busyDiscovery.invocationCount == 0
        let firstDiscoveryCompletion =
            busyDelegate.testingCompleteRepositoryInventoryDiscovery()
        let duplicateDiscoveryCompletion =
            busyDelegate.testingCompleteRepositoryInventoryDiscovery()
        let discoveryActivationPresentsOnce =
            firstDiscoveryCompletion
            && !duplicateDiscoveryCompletion
            && !busyDelegate.testInventoryPresentationPending
            && !busyDelegate.testInventoryDiscoveryInProgress
            && busyDelegate.testInventoryDiscoveryStartCount == 1
            && busyDelegate.testInventoryDiscoveryPresentationCount == 1
            && busyDiscovery.invocationCount == 0

        let onboardingFailureDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let onboardingFailureDelegate = makeDelegate(
            discovery: onboardingFailureDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "onboarding-failure-transport"
            ),
            shortcutAvailable: true
        )
        let failedOnboarding =
            CanonicalRootConfirmationWindowController(proposals: [])
        failedOnboarding.showWindow(nil)
        onboardingFailureDelegate.testingInstallCanonicalRootWindow(
            failedOnboarding
        )
        let onboardingFailureToken =
            onboardingFailureDelegate.testingBeginOnboardingAuthorityCommit()
        let onboardingAuthorityHeld = onboardingFailureToken != nil
            && onboardingFailureDelegate.testAuthorityCommitInProgress
        failedOnboarding.close()
        if let onboardingFailureToken {
            onboardingFailureDelegate.testingCompleteOnboardingCommitFailure(
                token: onboardingFailureToken
            )
            onboardingFailureDelegate.testingCompleteOnboardingCommitFailure(
                token: onboardingFailureToken
            )
        }
        onboardingFailureDelegate.testingTriggerShortcut()
        onboardingFailureDelegate.testingTriggerShortcut()
        let onboardingRecoveryCompletion =
            onboardingFailureDelegate
                .testingCompleteRepositoryInventoryDiscovery()
        let duplicateOnboardingRecoveryCompletion =
            onboardingFailureDelegate
                .testingCompleteRepositoryInventoryDiscovery()
        let onboardingFailurePreservesOnboarding =
            onboardingAuthorityHeld
            && failedOnboarding.window?.isVisible != true
            && onboardingFailureDelegate
                .testingCanonicalRootWindowIdentity == nil
            && !onboardingFailureDelegate.testAuthorityCommitInProgress
            && !onboardingFailureDelegate.testInventoryDiscoveryInProgress
            && onboardingFailureDelegate.testDiscoveryPresentation?.0
                == "Canonical roots were not changed"
            && onboardingFailureDelegate.testDiscoveryPresentation?.1.contains(
                "Nothing was saved."
            ) == true
            && onboardingFailureDelegate.testDiscoveryPresentationCount == 1
            && onboardingFailureDelegate
                .testCanonicalRootInventoryRetryCount == 1
            && onboardingFailureDelegate
                .testCanonicalRootInventoryRetryPresentationCount == 1
            && onboardingFailureDelegate
                .testRepositoryInventoryReconciliation?.allowOnboarding
                == true
            && onboardingFailureDelegate
                .testRepositoryInventoryReconciliation?.presentResult
                == true
            && onboardingFailureDelegate.testInventoryDiscoveryStartCount == 1
            && onboardingFailureDelegate
                .testInventoryDiscoveryBusyPresentationCount == 0
            && onboardingRecoveryCompletion
            && !duplicateOnboardingRecoveryCompletion
            && onboardingFailureDelegate
                .testInventoryDiscoveryPresentationCount == 1
            && !onboardingFailureDelegate.testSelectionIsOpen
            && onboardingFailureDiscovery.invocationCount == 0

        final class OnboardingCommitQuitCounter {
            var value = 0
        }
        let onboardingCommitQuitCounter =
            OnboardingCommitQuitCounter()
        let onboardingCommitQuitDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0],
            discovery: M5CountingDiscovery(candidates: candidates),
            testingRoot: root,
            testingMapping: try makeMapping(
                root: root,
                localName: "onboarding-commit-quit-transport"
            ),
            testingConfirmation: { .alertFirstButtonReturn },
            testingLogOpener: { _ in true },
            testingShortcutAvailable: true,
            testingQuitHandler: {
                onboardingCommitQuitCounter.value += 1
            }
        )
        let onboardingCommitQuitToken =
            onboardingCommitQuitDelegate
                .testingBeginOnboardingAuthorityCommit()
        onboardingCommitQuitDelegate.requestLifecycleExit()
        let onboardingCommitQuitDeferred =
            onboardingCommitQuitToken != nil
            && onboardingCommitQuitDelegate
                .testingInventoryQuitIsPending
            && onboardingCommitQuitCounter.value == 0
        let rejectedWhileQuitPending =
            onboardingCommitQuitDelegate.testingBeginOnboardingAuthorityCommit() == nil
        if let onboardingCommitQuitToken {
            onboardingCommitQuitDelegate.testingCompleteOnboardingCommitFailure(
                token: onboardingCommitQuitToken &+ 1
            )
        }
        let quitCompletionGenerationIsolated =
            onboardingCommitQuitDeferred
            && onboardingCommitQuitDelegate.testAuthorityCommitInProgress
            && onboardingCommitQuitDelegate.testInventoryDiscoveryInProgress
            && onboardingCommitQuitCounter.value == 0
        if let onboardingCommitQuitToken {
            onboardingCommitQuitDelegate
                .testingCompleteOnboardingCommitFailure(
                    token: onboardingCommitQuitToken
                )
        }
        let onboardingCommitQuitServiced =
            onboardingCommitQuitDeferred
            && onboardingCommitQuitCounter.value == 1
            && !onboardingCommitQuitDelegate
                .testAuthorityCommitInProgress
            && !onboardingCommitQuitDelegate
                .testInventoryDiscoveryInProgress
            && onboardingCommitQuitDelegate
                .testDiscoveryPresentationCount == 0
        let quitRejectsAuthorityAdmission =
            rejectedWhileQuitPending
            && onboardingCommitQuitServiced
            && onboardingCommitQuitDelegate.testingBeginOnboardingAuthorityCommit() == nil
        if let onboardingCommitQuitToken {
            onboardingCommitQuitDelegate.testingCompleteOnboardingCommitFailure(
                token: onboardingCommitQuitToken
            )
            onboardingCommitQuitDelegate.testingCompleteOnboardingCommitFailure(
                token: onboardingCommitQuitToken &+ 1
            )
        }
        onboardingCommitQuitDelegate.requestLifecycleExit()
        onboardingCommitQuitDelegate.requestLifecycleExit()
        let quitCompletionExactlyOnce =
            onboardingCommitQuitServiced
            && onboardingCommitQuitCounter.value == 1
            && !onboardingCommitQuitDelegate.testAuthorityCommitInProgress
            && !onboardingCommitQuitDelegate.testInventoryDiscoveryInProgress
            && onboardingCommitQuitDelegate.testDiscoveryPresentationCount == 0

        let dismissedFailureDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let dismissedFailureDelegate = makeDelegate(
            discovery: dismissedFailureDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "dismissed-failure-transport"
            ),
            shortcutAvailable: true
        )
        let dismissedFailureCard =
            RepositoryCardSelectionWindowController(
                inventory: emptyInventory
            )
        dismissedFailureDelegate.testingInstallCanonicalRootCommitOrigin(
            dismissedFailureCard
        )
        let dismissedFailureToken =
            dismissedFailureDelegate.testingBeginCanonicalRootCommit(
                originatingFrom: dismissedFailureCard
            )
        let dismissedFailureInlineBefore =
            dismissedFailureCard.testingCardStatusMessage
        let dismissedFailureWasOpen = dismissedFailureToken != nil
            && dismissedFailureCard.window?.isVisible == true
            && !dismissedFailureCard.testingAuthorityControlsEnabled
        dismissedFailureCard.close()
        if let dismissedFailureToken {
            dismissedFailureDelegate
                .testingCompleteCanonicalRootCommitFailure(
                    token: dismissedFailureToken,
                    originatingFrom: dismissedFailureCard
                )
            dismissedFailureDelegate
                .testingCompleteCanonicalRootCommitFailure(
                    token: dismissedFailureToken,
                    originatingFrom: dismissedFailureCard
                )
        }
        let dismissedFailureRecoveryCompletion =
            dismissedFailureDelegate
                .testingCompleteRepositoryInventoryDiscovery()
        let duplicateDismissedFailureRecoveryCompletion =
            dismissedFailureDelegate
                .testingCompleteRepositoryInventoryDiscovery()
        let dismissedFailureReportsAndReconciles =
            dismissedFailureWasOpen
            && dismissedFailureCard.window?.isVisible != true
            && !dismissedFailureDelegate.testSelectionIsOpen
            && dismissedFailureCard.testingCardStatusMessage
                == dismissedFailureInlineBefore
            && !dismissedFailureDelegate.testAuthorityCommitInProgress
            && !dismissedFailureDelegate.testInventoryDiscoveryInProgress
            && dismissedFailureDelegate.testDiscoveryPresentation?.0
                == "Canonical root was not changed"
            && dismissedFailureDelegate.testDiscoveryPresentation?.1.contains(
                "Nothing was saved."
            ) == true
            && dismissedFailureDelegate.testDiscoveryPresentation?.1.contains(
                "is refreshing the repository inventory"
            ) == true
            && dismissedFailureDelegate.testDiscoveryPresentationCount == 1
            && dismissedFailureDelegate
                .testCanonicalRootInventoryRetryCount == 1
            && dismissedFailureDelegate
                .testCanonicalRootInventoryRetryPresentationCount == 0
            && dismissedFailureDelegate
                .testRepositoryInventoryReconciliation?.allowOnboarding
                == false
            && dismissedFailureDelegate
                .testRepositoryInventoryReconciliation?.presentResult
                == false
            && dismissedFailureDelegate.testInventoryDiscoveryStartCount == 1
            && dismissedFailureDelegate
                .testInventoryDiscoveryBusyPresentationCount == 0
            && !dismissedFailureRecoveryCompletion
            && !duplicateDismissedFailureRecoveryCompletion
            && dismissedFailureDelegate
                .testInventoryDiscoveryPresentationCount == 0
            && dismissedFailureDiscovery.invocationCount == 0

        let dismissedCommitDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let dismissedCommitDelegate = makeDelegate(
            discovery: dismissedCommitDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "dismissed-canonical-root-transport"
            ),
            shortcutAvailable: true
        )
        let dismissedCommitCard =
            RepositoryCardSelectionWindowController(
                inventory: emptyInventory
            )
        dismissedCommitDelegate.testingInstallCanonicalRootCommitOrigin(
            dismissedCommitCard
        )
        let dismissedCommitToken =
            dismissedCommitDelegate.testingBeginCanonicalRootCommit(
                originatingFrom: dismissedCommitCard
            )
        let dismissedCommitWasOpen =
            dismissedCommitCard.window?.isVisible == true
            && dismissedCommitToken != nil
        dismissedCommitCard.close()
        if let dismissedCommitToken {
            dismissedCommitDelegate
                .testingCompleteCanonicalRootCommitSuccess(
                    emptyInventory,
                    token: dismissedCommitToken,
                    originatingFrom: dismissedCommitCard
                )
        }
        let dismissedCanonicalRootCommitStaysClosed =
            dismissedCommitWasOpen
            && dismissedCommitCard.window?.isVisible != true
            && !dismissedCommitDelegate.testSelectionIsOpen
            && dismissedCommitDelegate
                .testCanonicalRootInventoryPresentationCount == 0
            && dismissedCommitDelegate
                .testCanonicalRootInventoryRetryCount == 0
            && !dismissedCommitDelegate.testAuthorityCommitInProgress
            && !dismissedCommitDelegate.testInventoryDiscoveryInProgress
            && dismissedCommitDelegate.testDiscoveryPresentationCount == 0
            && dismissedCommitDiscovery.invocationCount == 0

        let savedRefreshDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let savedRefreshDelegate = makeDelegate(
            discovery: savedRefreshDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "saved-canonical-root-refresh-transport"
            ),
            shortcutAvailable: true
        )
        let savedRefreshCard =
            RepositoryCardSelectionWindowController(
                inventory: emptyInventory
            )
        savedRefreshDelegate.testingInstallCanonicalRootCommitOrigin(
            savedRefreshCard
        )
        let savedRefreshToken =
            savedRefreshDelegate.testingBeginCanonicalRootCommit(
                originatingFrom: savedRefreshCard
            )
        let savedRefreshWasOpen = savedRefreshCard.window?.isVisible == true
            && savedRefreshDelegate.testSelectionIsOpen
            && savedRefreshToken != nil
            && !savedRefreshCard.testingAuthorityControlsEnabled
        if let savedRefreshToken {
            savedRefreshDelegate
                .testingCompleteCanonicalRootCommitSavedRefreshFailure(
                    token: savedRefreshToken,
                    originatingFrom: savedRefreshCard
                )
        }
        let savedRefreshOwnsDiscovery =
            !savedRefreshDelegate.testAuthorityCommitInProgress
            && savedRefreshDelegate.testInventoryDiscoveryInProgress
        let savedRefreshCompletion =
            savedRefreshDelegate.testingCompleteRepositoryInventoryDiscovery()
        let duplicateSavedRefreshCompletion =
            savedRefreshDelegate.testingCompleteRepositoryInventoryDiscovery()
        let savedCanonicalRootRefreshFailureRecovers =
            savedRefreshWasOpen
            && savedRefreshCard.window?.isVisible != true
            && !savedRefreshDelegate.testSelectionIsOpen
            && savedRefreshDelegate.testDiscoveryPresentation?.0
                == "Canonical root was saved"
            && savedRefreshDelegate.testDiscoveryPresentation?.1.contains(
                "The selection was recorded but the repository list could not refresh."
            ) == true
            && savedRefreshDelegate
                .testCanonicalRootInventoryRetryCount == 1
            && savedRefreshDelegate
                .testCanonicalRootInventoryRetryPresentationCount == 1
            && savedRefreshDelegate
                .testCanonicalRootInventoryPresentationCount == 0
            && savedRefreshDelegate.testDiscoveryPresentationCount == 1
            && savedRefreshOwnsDiscovery
            && savedRefreshCompletion
            && !duplicateSavedRefreshCompletion
            && !savedRefreshDelegate.testInventoryDiscoveryInProgress
            && savedRefreshDelegate.testInventoryDiscoveryStartCount == 1
            && savedRefreshDelegate
                .testInventoryDiscoveryPresentationCount == 1
            && savedRefreshDiscovery.invocationCount == 0
        savedRefreshCard.close()

        let dismissedSavedDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let dismissedSavedDelegate = makeDelegate(
            discovery: dismissedSavedDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "dismissed-saved-refresh-transport"
            ),
            shortcutAvailable: true
        )
        let dismissedSavedCard =
            RepositoryCardSelectionWindowController(
                inventory: emptyInventory
            )
        dismissedSavedDelegate.testingInstallCanonicalRootCommitOrigin(
            dismissedSavedCard
        )
        let dismissedSavedToken =
            dismissedSavedDelegate.testingBeginCanonicalRootCommit(
                originatingFrom: dismissedSavedCard
            )
        dismissedSavedCard.close()
        if let dismissedSavedToken {
            dismissedSavedDelegate
                .testingCompleteCanonicalRootCommitSavedRefreshFailure(
                    token: dismissedSavedToken,
                    originatingFrom: dismissedSavedCard
                )
        }
        let dismissedSavedOwnsDiscovery =
            !dismissedSavedDelegate.testAuthorityCommitInProgress
            && dismissedSavedDelegate.testInventoryDiscoveryInProgress
        let dismissedSavedCompletion =
            dismissedSavedDelegate
                .testingCompleteRepositoryInventoryDiscovery()
        let duplicateDismissedSavedCompletion =
            dismissedSavedDelegate
                .testingCompleteRepositoryInventoryDiscovery()
        let dismissedSavedCanonicalRootReconciles =
            dismissedSavedToken != nil
            && dismissedSavedCard.window?.isVisible != true
            && !dismissedSavedDelegate.testSelectionIsOpen
            && dismissedSavedDelegate.testDiscoveryPresentation == nil
            && dismissedSavedDelegate
                .testCanonicalRootInventoryRetryCount == 1
            && dismissedSavedDelegate
                .testCanonicalRootInventoryRetryPresentationCount == 0
            && dismissedSavedDelegate
                .testCanonicalRootInventoryPresentationCount == 0
            && dismissedSavedDelegate.testDiscoveryPresentationCount == 0
            && dismissedSavedOwnsDiscovery
            && !dismissedSavedCompletion
            && !duplicateDismissedSavedCompletion
            && !dismissedSavedDelegate.testInventoryDiscoveryInProgress
            && dismissedSavedDelegate.testInventoryDiscoveryStartCount == 1
            && dismissedSavedDelegate
                .testInventoryDiscoveryPresentationCount == 0
            && dismissedSavedDiscovery.invocationCount == 0

        let concurrentDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let concurrentDelegate = makeDelegate(
            discovery: concurrentDiscovery,
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "concurrent-canonical-root-transport"
            ),
            shortcutAvailable: true
        )
        let concurrentCard =
            RepositoryCardSelectionWindowController(
                inventory: emptyInventory
            )
        concurrentDelegate.testingInstallCanonicalRootCommitOrigin(
            concurrentCard
        )
        let firstConcurrentToken =
            concurrentDelegate.testingBeginCanonicalRootCommit(
                originatingFrom: concurrentCard
            )
        let controlsDisabled =
            !concurrentCard.testingAuthorityControlsEnabled
        let rejectedConcurrentToken =
            concurrentDelegate.testingBeginCanonicalRootCommit(
                originatingFrom: concurrentCard
            )
        let busyFeedback = concurrentCard.testingCardStatusMessage
        let busyStateHeld =
            concurrentDelegate.testAuthorityCommitInProgress
        if let firstConcurrentToken {
            concurrentDelegate.testingCompleteCanonicalRootCommitFailure(
                token: firstConcurrentToken,
                originatingFrom: concurrentCard
            )
        }
        let concurrentCanonicalRootCommitIsRejected =
            firstConcurrentToken != nil
            && rejectedConcurrentToken == nil
            && controlsDisabled
            && busyFeedback.contains("already in progress")
            && busyStateHeld
            && !concurrentDelegate.testAuthorityCommitInProgress
            && !concurrentDelegate.testInventoryDiscoveryInProgress
            && concurrentCard.testingAuthorityControlsEnabled
            && concurrentDelegate.testSelectionIsOpen
            && concurrentCard.window?.isVisible == true
            && concurrentDelegate
                .testCanonicalRootInventoryRetryCount == 0
            && concurrentDelegate
                .testCanonicalRootInventoryPresentationCount == 0
            && concurrentDelegate.testDiscoveryPresentationCount == 0
            && concurrentDiscovery.invocationCount == 0
        concurrentCard.close()

        fputs(
            "M5 canonical-root completion: "
                + "dismissed=\(dismissedCanonicalRootCommitStaysClosed) "
                + "saved-refresh=\(savedCanonicalRootRefreshFailureRecovers) "
                + "dismissed-saved=\(dismissedSavedCanonicalRootReconciles) "
                + "concurrent=\(concurrentCanonicalRootCommitIsRejected) "
                + "discovery-progress=\(discoveryActivationShowsProgress) "
                + "discovery-once=\(discoveryActivationPresentsOnce) "
                + "onboarding-failure=\(onboardingFailurePreservesOnboarding) "
                + "dismissed-failure=\(dismissedFailureReportsAndReconciles)\n",
            stderr
        )
        return M5ConfirmationCloseResponse(
            closeClearsSession: closeClearsSession,
            retryStartsRun: retryStartsRun,
            hiddenCardRemainsOpen: hiddenCardRemainsOpen,
            reactivationReusesCard: hiddenReuse,
            hiddenOnboardingRemainsOpen: hiddenOnboardingRemainsOpen,
            onboardingReactivationReuses: onboardingReactivationReuses,
            dismissedCanonicalRootCommitStaysClosed:
                dismissedCanonicalRootCommitStaysClosed,
            savedCanonicalRootRefreshFailureRecovers:
                savedCanonicalRootRefreshFailureRecovers,
            dismissedSavedCanonicalRootReconciles:
                dismissedSavedCanonicalRootReconciles,
            concurrentCanonicalRootCommitIsRejected:
                concurrentCanonicalRootCommitIsRejected,
            discoveryActivationShowsProgress:
                discoveryActivationShowsProgress,
            discoveryActivationPresentsOnce:
                discoveryActivationPresentsOnce,
            onboardingFailurePreservesOnboarding:
                onboardingFailurePreservesOnboarding
                    && onboardingCommitQuitServiced,
            dismissedFailureReportsAndReconciles:
                dismissedFailureReportsAndReconciles,
            quitRejectsAuthorityAdmission: quitRejectsAuthorityAdmission,
            quitCompletionGenerationIsolated: quitCompletionGenerationIsolated,
            quitCompletionExactlyOnce: quitCompletionExactlyOnce
        )
    }

    private static func testRouting(root: String) throws -> Bool {
        func fail(_ stage: String) -> Bool {
            fputs("M5 routing failure: \(stage)\n", stderr)
            return false
        }
        func menuTitles(_ delegate: ShadowSyncAppDelegate) -> [String] {
            delegate.testMenuTitles().filter {
                $0 != ShadowSyncPresentation.foregroundUnavailable
            }
        }
        func pumpRunLoop(seconds: TimeInterval) {
            let deadline = MonotonicDeadline(seconds: seconds)
            while !deadline.hasExpired {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
        }
        guard testActualCarbonCollision().passed else {
            return fail("actual Carbon collision")
        }
        let candidates = makeCandidates(count: 2, root: root + "/routing")
        let mapping = try makeMapping(root: root)
        let idleMenu = [
            "Start New Run…",
            "Open Latest Log",
            "Quit ShadowSync",
        ]
        let currentRunMenu = [
            "Start New Run…",
            "Show Current Run",
            "Open Latest Log",
            "Quit ShadowSync",
        ]
        let lastReportMenu = [
            "Start New Run…",
            "Show Last Report",
            "Open Latest Log",
            "Quit ShadowSync",
        ]

        let selectionDiscovery = M5CountingDiscovery(candidates: candidates)
        let selectionDelegate = makeDelegate(
            discovery: selectionDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        selectionDelegate.testStartNewRun()
        let selectionIdentity = selectionDelegate.testSelectionControllerIdentity
        let selectionWindowNumber =
            selectionDelegate.testingSelectionWindowState?.number
        selectionDelegate.testingHideSelectionWindow()
        selectionDelegate.testingTriggerShortcut()
        guard selectionDelegate.testingSelectionWindowState?.visible == true,
              selectionDelegate.testingSelectionWindowState?.number
                == selectionWindowNumber else {
            return fail("deterministic hidden selection restore")
        }
        selectionDelegate.testingMiniaturizeSelectionWindow()
        selectionDelegate.testingTriggerShortcut()
        guard selectionDelegate.testingSelectionWindowState?.miniaturized
                == false,
              selectionDelegate.testingSelectionWindowState?.visible == true,
              selectionDelegate.testingSelectionWindowState?.number
                == selectionWindowNumber else {
            return fail("deterministic miniaturized selection restore")
        }
        selectionDelegate.testingTriggerMenuStart()
        selectionDelegate.handleDuplicateActivation()
        guard selectionDelegate.testSelectionControllerIdentity == selectionIdentity,
              selectionDelegate.testSelectionCount == 0,
              selectionDiscovery.invocationCount == 1,
              menuTitles(selectionDelegate) == idleMenu else {
            return fail("selection identity and menu")
        }

        let activeDiscovery = M5CountingDiscovery(candidates: candidates)
        let activeDelegate = makeDelegate(
            discovery: activeDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        let activeController = RunWindowController(candidates: candidates)
        activeDelegate.testingInstallRunWindow(activeController)
        let activeIdentity = activeDelegate.testingRunControllerIdentity
        activeDelegate.testingHideRunWindow()
        activeDelegate.testingTriggerShortcut()
        guard activeDelegate.testingRunWindowState?.visible == true else {
            return fail("hidden active restore")
        }
        activeDelegate.testingMiniaturizeRunWindow()
        activeDelegate.testingTriggerStatusActivation()
        activeDelegate.testingTriggerMenuStart()
        guard activeDelegate.testingRunControllerIdentity == activeIdentity,
              activeDelegate.testingRunWindowState?.miniaturized == false,
              activeDiscovery.invocationCount == 0,
              menuTitles(activeDelegate) == currentRunMenu else {
            return fail("miniaturized active restore")
        }

        let stoppingDiscovery = M5CountingDiscovery(candidates: candidates)
        let stoppingDelegate = makeDelegate(
            discovery: stoppingDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        let stoppingController = RunWindowController(candidates: candidates)
        stoppingController.testingConfigureStoppingForRouting()
        stoppingDelegate.testingInstallRunWindow(stoppingController)
        let stoppingIdentity = stoppingDelegate.testingRunControllerIdentity
        stoppingDelegate.testingTriggerShortcut()
        guard stoppingDelegate.testingRunControllerIdentity == stoppingIdentity,
              stoppingDiscovery.invocationCount == 0,
              menuTitles(stoppingDelegate) == currentRunMenu else {
            return false
        }

        let blockedDiscovery = M5CountingDiscovery(candidates: candidates)
        let blockedDelegate = makeDelegate(
            discovery: blockedDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        let blockedController = RunWindowController(candidates: candidates)
        blockedController.presentFailure(
            "fixture safety block",
            requiresRecoveryReview: true
        )
        blockedDelegate.testingInstallRunWindow(blockedController)
        let blockedIdentity = blockedDelegate.testingRunControllerIdentity
        blockedDelegate.testingTriggerShortcut()
        guard blockedDelegate.testingRunControllerIdentity == blockedIdentity,
              blockedDiscovery.invocationCount == 0,
              menuTitles(blockedDelegate) == currentRunMenu else {
            return false
        }

        let reportDiscovery = M5CountingDiscovery(candidates: candidates)
        let reportDelegate = makeDelegate(
            discovery: reportDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        let reportController = RunWindowController(candidates: candidates)
        let report = makeReport(
            run: reportController.testingRunID,
            results: candidates.map {
                makeResult(candidate: $0, code: .alreadyCurrent)
            }
        )
        reportController.present(report: report)
        reportController.testingPresentSafeWorkerExit()
        reportDelegate.testingInstallRunWindow(reportController)
        guard menuTitles(reportDelegate) == lastReportMenu else {
            return false
        }
        let reportIdentity = reportDelegate.testingRunControllerIdentity
        reportDelegate.testingHideRunWindow()
        reportDelegate.testingTriggerShortcut()
        guard reportDelegate.testingRunControllerIdentity == reportIdentity,
              reportDelegate.testingRunWindowState?.visible == true,
              !reportDelegate.testSelectionIsOpen,
              reportDiscovery.invocationCount == 0 else {
            return false
        }
        reportDelegate.testingTriggerMenuStart()
        guard reportDelegate.testingRunControllerIdentity == nil,
              reportDelegate.testSelectionIsOpen,
              reportDelegate.testLastReport == report,
              reportDiscovery.invocationCount == 1 else {
            return false
        }

        let recoveryDiscovery = M5CountingDiscovery(candidates: candidates)
        let recoveryDelegate = makeDelegate(
            discovery: recoveryDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        let recoveryController = RunWindowController(candidates: candidates)
        let interrupted = makeReport(
            run: recoveryController.testingRunID,
            cancelled: true,
            results: candidates.map {
                makeResult(candidate: $0, code: .cancelledPending)
            },
            summaryOverride: InterruptedRunReconstructor.summary
        )
        recoveryController.present(report: interrupted)
        recoveryController.testingPresentSafeWorkerExit()
        recoveryDelegate.testingInstallRunWindow(recoveryController)
        let recoveryIdentity = recoveryDelegate.testingRunControllerIdentity
        recoveryDelegate.testingTriggerMenuStart()
        guard recoveryDelegate.testingRunControllerIdentity == recoveryIdentity,
              recoveryDiscovery.invocationCount == 0,
              menuTitles(recoveryDelegate) == lastReportMenu else {
            return false
        }

        let historicalDiscovery = M5CountingDiscovery(candidates: candidates)
        let historicalDelegate = makeDelegate(
            discovery: historicalDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        historicalDelegate.testingSetLastReport(report)
        historicalDelegate.testingShowLastReport()
        let historicalIdentity =
            historicalDelegate.testingHistoricalViewerIdentity
        let historicalWindowNumber =
            historicalDelegate.testingHistoricalWindowState?.number
        historicalDelegate.testingHideHistoricalWindow()
        historicalDelegate.testingTriggerShortcut()
        guard historicalDelegate.testingHistoricalWindowState?.visible
                == true,
              historicalDelegate.testingHistoricalWindowState?.number
                == historicalWindowNumber,
              historicalDelegate.testingHistoricalViewerIdentity
                == historicalIdentity,
              historicalDiscovery.invocationCount == 0 else {
            return fail("deterministic hidden historical restore")
        }
        historicalDelegate.testingHideHistoricalWindow()
        historicalDelegate.testingShowLastReport()
        guard historicalDelegate.testingHistoricalWindowState?.visible
                == true,
              historicalDelegate.testingHistoricalWindowState?.number
                == historicalWindowNumber,
              historicalDelegate.testingHistoricalViewerIdentity
                == historicalIdentity,
              historicalDiscovery.invocationCount == 0 else {
            return fail("deterministic historical menu restore")
        }
        historicalDelegate.testingMiniaturizeHistoricalWindow()
        historicalDelegate.testingTriggerStatusActivation()
        guard historicalDelegate.testingHistoricalViewerIdentity
                == historicalIdentity,
              historicalDelegate.testingHistoricalWindowState?.miniaturized
                == false else {
            return fail("miniaturized historical restore")
        }

        let confirmationDiscovery = M5CountingDiscovery(
            candidates: Array(candidates.prefix(1))
        )
        let confirmationDelegate = makeDelegate(
            discovery: confirmationDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        confirmationDelegate.testStartNewRun()
        confirmationDelegate.testingBeginRealConfirmationFromSpace()
        pumpRunLoop(seconds: 0.15)
        let confirmationOnly = confirmationDelegate.testingConfirmationState
        pumpRunLoop(seconds: 0.15)
        guard confirmationOnly.open,
              !confirmationOnly.armed,
              !confirmationOnly.hasRun,
              confirmationOnly.selectionOpen,
              !confirmationDelegate.testingConfirmationState.hasRun,
              confirmationDelegate.testBeginRunCount == 0 else {
            fputs(
                "M5 confirmation state: open=\(confirmationOnly.open) "
                    + "armed=\(confirmationOnly.armed) "
                    + "run=\(confirmationOnly.hasRun) "
                    + "selection=\(confirmationOnly.selectionOpen) "
                    + "count=\(confirmationDelegate.testBeginRunCount)\n",
                stderr
            )
            return fail("confirmation event boundary")
        }
        confirmationDelegate.testingActivateConfirmationStart()
        pumpRunLoop(seconds: 0.05)
        guard confirmationDelegate.testingConfirmationState.hasRun,
              !confirmationDelegate.testingConfirmationState.selectionOpen,
              confirmationDelegate.testBeginRunCount == 1 else {
            return fail("explicit confirmation start")
        }

        let collisionDiscovery = M5CountingDiscovery(candidates: candidates)
        let collisionDelegate = makeDelegate(
            discovery: collisionDiscovery,
            root: root,
            mapping: mapping,
            shortcutAvailable: false
        )
        let collisionMenu = collisionDelegate.testMenuTitles()
        collisionDelegate.testingTriggerMenuStart()
        collisionDelegate.testingPresentPendingShortcutCollision()
        let collisionPass = collisionMenu == [
            "Start New Run…",
            "Open Latest Log",
            "Keyboard Shortcut Unavailable",
            "Quit ShadowSync",
        ]
            && collisionDelegate.testSelectionIsOpen
            && collisionDiscovery.invocationCount == 1
            && collisionDelegate.testShortcutCollisionPresentationCount == 1
            && collisionDelegate.testShortcutCollisionPresentation?.0
                == ShadowSyncPresentation.shortcutUnavailable
            && collisionDelegate.testShortcutCollisionPresentation?.1
                == ShadowSyncPresentation.shortcutUnavailableText
        return collisionPass || fail("collision warning presentation")
    }

    private static func testActualCarbonCollision()
        -> M5CarbonCollisionResult {
        let requiredModifiers = UInt32(
            controlKey | optionKey | cmdKey
        )
        let productionChord =
            ShadowSyncAppDelegate.testingProductionShortcutChord
        let productionDefaultsPreserved =
            productionChord.keyCode == UInt32(kVK_ANSI_M)
            && productionChord.modifiers == requiredModifiers
        let candidateKeyCodes = [
            UInt32(kVK_F13),
            UInt32(kVK_F14),
            UInt32(kVK_F15),
            UInt32(kVK_F16),
        ]
        var blocker: EventHotKeyRef?
        var selectedKeyCode: UInt32?
        defer {
            if let blocker {
                UnregisterEventHotKey(blocker)
            }
        }
        for (index, keyCode) in candidateKeyCodes.enumerated() {
            var candidate: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                requiredModifiers,
                EventHotKeyID(
                    signature: 0x4D35424C,
                    id: UInt32(index + 1)
                ),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &candidate
            )
            if status == noErr, let candidate {
                blocker = candidate
                selectedKeyCode = keyCode
                break
            }
            if status != OSStatus(eventHotKeyExistsErr) {
                fputs(
                    "M5 Carbon candidate registration failed: "
                        + "key=\(keyCode) status=\(status)\n",
                    stderr
                )
            }
        }
        guard let selectedKeyCode, blocker != nil else {
            fputs(
                "M5 Carbon collision fixture exhausted its bounded chords\n",
                stderr
            )
            return M5CarbonCollisionResult(
                blockerRegistered: false,
                collisionSurfaced: false,
                releaseThenInvocationSucceeded: false,
                handlerIsolationPassed: false,
                productionDefaultsPreserved:
                    productionDefaultsPreserved
            )
        }

        let conflictStatus =
            ShadowSyncAppDelegate.testingShortcutRegistrationStatus(
                keyCode: selectedKeyCode,
                modifiers: requiredModifiers
            )
        let collisionSurfaced =
            conflictStatus == OSStatus(eventHotKeyExistsErr)
        if let ownedBlocker = blocker {
            UnregisterEventHotKey(ownedBlocker)
            blocker = nil
        }
        let recovered =
            ShadowSyncAppDelegate.testingShortcutRegistrationAndDispatch(
                keyCode: selectedKeyCode,
                modifiers: requiredModifiers
            )
        let cleanupStatus =
            ShadowSyncAppDelegate.testingShortcutRegistrationStatus(
                keyCode: selectedKeyCode,
                modifiers: requiredModifiers
            )
        let releaseThenInvocationSucceeded =
            recovered.registered
            && recovered.registrationStatus == noErr
            && recovered.matchingStatus == noErr
            && recovered.actionCount == 1
            && cleanupStatus == noErr
        let handlerIsolationPassed =
            recovered.wrongSignatureStatus
                == OSStatus(eventNotHandledErr)
            && recovered.wrongIdentifierStatus
                == OSStatus(eventNotHandledErr)
            && recovered.actionCount == 1
        return M5CarbonCollisionResult(
            blockerRegistered: true,
            collisionSurfaced: collisionSurfaced,
            releaseThenInvocationSucceeded:
                releaseThenInvocationSucceeded,
            handlerIsolationPassed: handlerIsolationPassed,
            productionDefaultsPreserved:
                productionDefaultsPreserved
        )
    }

    private static func testBody3RepositoryCardLayout(root: String)
        throws -> Bool {
        func fail(_ detail: String) -> Bool {
            fputs(
                "Body 3 repository-card layout failure: "
                    + detail + "\n",
                stderr
            )
            return false
        }
        func descendants<T: NSView>(
            of type: T.Type,
            in view: NSView
        ) -> [T] {
            view.subviews.flatMap { child -> [T] in
                ((child as? T).map { [$0] } ?? [])
                    + descendants(of: type, in: child)
            }
        }
        func hasAmbiguousLayout(_ view: NSView) -> Bool {
            view.hasAmbiguousLayout
                || view.subviews.contains(
                    where: hasAmbiguousLayout
                )
        }
        func ambiguousDescriptions(
            _ view: NSView
        ) -> [String] {
            let current = view.hasAmbiguousLayout
                ? ["\(type(of: view)):\(view.frame)"]
                : []
            return current + view.subviews.flatMap(
                ambiguousDescriptions
            )
        }
        func directoryIdentity(
            _ inode: UInt64
        ) throws -> RepositoryDirectoryIdentity {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "device": 1,
                    "inode": inode,
                ]
            )
            return try JSONDecoder().decode(
                RepositoryDirectoryIdentity.self,
                from: data
            )
        }
        func card(
            index: Int,
            category: RepositoryPolicyCategory,
            includeCleanup: Bool = false,
            maintenanceRefusals: [String] = [],
            maintenanceDiagnostics: [String]? = nil
        ) throws -> RepositoryCard {
            let prefix: String
            switch category {
            case .writable: prefix = "writable"
            case .repositoryOwnedWorkflow:
                prefix = "protected"
            case .permanentNoTouch:
                prefix = "no-touch"
            case .reference: prefix = "reference"
            }
            let name = String(
                format: "%@-%02d",
                prefix,
                index
            )
            let repositoryID =
                "fixture-owner/\(name)"
            let origin =
                "https://github.com/\(repositoryID).git"
            let path =
                "/private/tmp/body3-layout/\(name)"
            let source = RepositoryCandidate(
                id: repositoryID,
                displayName: name,
                path: path,
                rawOrigin: origin,
                presentationLocation:
                    "~/dev/body3-layout/\(name)",
                rootIdentity:
                    try directoryIdentity(
                        UInt64(index * 10 + 10)
                    ),
                gitDirectoryIdentity:
                    try directoryIdentity(
                        UInt64(index * 10 + 11)
                    ),
                commonDirectoryIdentity:
                    try directoryIdentity(
                        UInt64(index * 10 + 12)
                    )
            )
            let commonIdentity = try directoryIdentity(
                UInt64(index * 10 + 12)
            )
            let cloneID = LocalClone.id(
                for: commonIdentity
            )
            let recommendedPreview = RemovalPreview(
                recommendation: .recommended,
                permission: .previewOnly,
                explanation:
                    "Synthetic fulfilled cleanup candidate."
            )
            let worktrees: [Worktree]
            let branches: [Branch]
            if category == .writable,
               includeCleanup {
                let featureRef =
                    "refs/heads/feature-\(index)"
                worktrees = [
                    try Worktree(
                        id: "worktree:\(index)",
                        cloneID: cloneID,
                        path: path + "-feature",
                        rootIdentity:
                            try directoryIdentity(
                                UInt64(index * 10 + 13)
                            ),
                        registrationIdentity:
                            try directoryIdentity(
                                UInt64(index * 10 + 14)
                            ),
                        attachedBranchRef: featureRef,
                        detachedOID: nil,
                        isPrimary: false,
                        locationKind: .cursorManaged,
                        cleanliness: .clean,
                        fileState: WorktreeFileState(
                            trackedChanges: 0,
                            untrackedFiles: 0,
                            ignoredFiles: 0,
                            hiddenIndexState: false,
                            operationState: .clear
                        ),
                        contentEvidenceDigest:
                            String(repeating: "c", count: 64),
                        relationToDefault:
                            DefaultBranchRelation(
                                kind: .equal,
                                aheadCount: 0,
                                behindCount: 0
                            ),
                        currentSession: false,
                        removalPreview: recommendedPreview
                    ),
                ]
                branches = [
                    try Branch(
                        cloneID: cloneID,
                        fullRef: featureRef,
                        tipOID:
                            String(repeating: "b", count: 40),
                        claimingWorktreeIDs: [],
                        relationToDefault:
                            DefaultBranchRelation(
                                kind: .equal,
                                aheadCount: 0,
                                behindCount: 0
                            ),
                        pullRequests: [],
                        pullRequestAvailability:
                            .available,
                        removalPreview: recommendedPreview
                    ),
                ]
            } else {
                worktrees = []
                branches = []
            }
            let clone = try LocalClone(
                repositoryID: repositoryID,
                sourceSnapshot: source,
                effectiveOrigin: origin,
                originParityVerified: true,
                policyCategory: category,
                kind: category == .writable
                    ? .primaryCheckout
                    : (
                        category == .reference
                            ? .readOnlyReference
                            : .protected
                    ),
                worktrees: worktrees,
                branches: branches,
                warnings: []
            )
            let repository = try RemoteRepository(
                id: repositoryID,
                origins: [origin],
                policyCategory: category,
                resolvedDefault:
                    try RemoteDefaultBranch(
                        name: "main",
                        advertisedOID:
                            String(repeating: "a", count: 40)
                    ),
                defaultUnavailableReason: nil
            )
            return try RepositoryCard(
                repository: repository,
                authority: CanonicalAuthorityState(
                    status: category == .writable
                        ? .missing : .notApplicable,
                    record: nil,
                    explanation: category == .writable
                        ? "Choose one verified local root."
                        : "Protected by repository policy."
                ),
                clones: [clone],
                relation: .unavailable,
                fastForward: nil,
                fastForwardRefusal:
                    "No operation is selectable.",
                maintenanceRefusals:
                    maintenanceRefusals,
                maintenanceDiagnostics:
                    maintenanceDiagnostics,
                originHeadExplanation:
                    "Origin default is main."
            )
        }

        let writable = try (0..<14).map {
            try card(index: $0, category: .writable)
        }
        let protected = try (20..<22).map {
            try card(
                index: $0,
                category: .repositoryOwnedWorkflow
            )
        }
        let references = try (30..<33).map {
            try card(index: $0, category: .reference)
        }
        let inventory = RepositoryInventory(
            cards:
                writable + protected + references,
            onboardingProposals: [],
            authorityFileIdentity: nil
        )
        let cleanupInventory = RepositoryInventory(
            cards: try (100..<104).map {
                try card(
                    index: $0,
                    category: .writable,
                    includeCleanup: true
                )
            },
            onboardingProposals: [],
            authorityFileIdentity: nil
        )
        let repairUnavailableMessage =
            "Repair unavailable: 1 of 2 stale registrations is detached and cannot be safely removed. Nothing will be changed."
        let repairUnavailableInventory =
            RepositoryInventory(
                cards: [
                    try card(
                        index: 200,
                        category: .writable,
                        maintenanceRefusals: [
                            repairUnavailableMessage,
                        ],
                        maintenanceDiagnostics: [
                            "Repair unavailable registration detached-stale: HEAD is detached.",
                        ]
                    ),
                ],
                onboardingProposals: [],
                authorityFileIdentity: nil
            )
        let repairUnavailableController =
            RepositoryCardSelectionWindowController(
                inventory:
                    repairUnavailableInventory
            )
        let repairUnavailablePresentationIsNeutral =
            repairUnavailableController
                .testingMaintenanceUnavailableIsNeutral
                && repairUnavailableController
                    .testingMaintenanceUnavailableCopy
                    == [repairUnavailableMessage]
                && repairUnavailableInventory.cards[0]
                    .maintenanceDiagnostics?
                    .contains {
                        $0.contains("detached-stale")
                    } == true
                && !repairUnavailableMessage
                    .contains("detached-stale")
        repairUnavailableController.close()
        let gatedCleanupController =
            RepositoryCardSelectionWindowController(
                inventory: cleanupInventory
            )
        let zeroInspectionBulkGate =
            !gatedCleanupController
                .testingSelectRecommendedCleanupEnabled
                && gatedCleanupController.testingCardStatusMessage
                    .contains("Inspect cleanup")
        gatedCleanupController
            .testingSelectAllRecommendedRemoval()
        let zeroInspectionSelectsNothing =
            gatedCleanupController
                .testingSelectedRemovalIDs.isEmpty
        let mixedIDs = cleanupInventory.writableCards
            .map(\.id).sorted()
        guard mixedIDs.count >= 2 else {
            return fail("mixed cleanup fixture unavailable")
        }
        let successfulInspectionID = mixedIDs[0]
        let failedInspectionID = mixedIDs[1]
        gatedCleanupController.beginCleanupInspection(
            repositoryIDs: [
                successfulInspectionID,
                failedInspectionID,
            ]
        )
        let manageDisabledDuringInspection =
            !gatedCleanupController
                .testingManageSelectionEnabled
        gatedCleanupController.applyCleanupInspection(
            inventory: cleanupInventory,
            repositoryIDs: [successfulInspectionID]
        )
        gatedCleanupController.failCleanupInspection(
            repositoryIDs: [failedInspectionID],
            message: "Synthetic cleanup inspection failure."
        )
        gatedCleanupController
            .testingSelectAllRecommendedRemoval()
        let successfulCandidateIDs = Set(
            RepositoryInventoryRemovalCandidates
                .make(from: cleanupInventory)
                .filter {
                    $0.repository.id
                        == successfulInspectionID
                        && $0.selectAllEligible
                }
                .map(\.id)
        )
        let mixedInspectionBulkGate =
            gatedCleanupController
                .testingSelectRecommendedCleanupEnabled
                && gatedCleanupController
                    .testingManageSelectionEnabled
                && !successfulCandidateIDs.isEmpty
                && gatedCleanupController
                    .testingSelectedRemovalIDs
                    == successfulCandidateIDs
        let selectionController =
            RepositoryCardSelectionWindowController(
                inventory: cleanupInventory
            )
        selectionController.applyCleanupInspection(
            inventory: cleanupInventory,
            repositoryIDs:
                Set(cleanupInventory.writableCards.map(\.id))
        )
        if let visualRoot = ProcessInfo.processInfo.environment[
            "SHADOW_SYNC_LAYOUT_VISUAL_ROOT"
        ] {
            let root = try TestIsolation.validateRoot(
                visualRoot
            )
            let visualController =
                RepositoryCardSelectionWindowController(
                    inventory: cleanupInventory
                )
            visualController.applyCleanupInspection(
                inventory: cleanupInventory,
                repositoryIDs:
                    Set(
                        cleanupInventory
                            .writableCards.map(\.id)
                    )
            )
            guard let visualWindow =
                    visualController.window else {
                return fail("visual cleanup window unavailable")
            }
            visualWindow.appearance = NSAppearance(
                named:
                    ProcessInfo.processInfo.environment[
                        "SHADOW_SYNC_VISUAL_APPEARANCE"
                    ] == "dark"
                        ? .darkAqua : .aqua
            )
            visualController.showWindow(nil)
            visualWindow.makeKeyAndOrderFront(nil)
            visualWindow.orderFrontRegardless()
            visualWindow.layoutIfNeeded()
            print(
                "READY pid=\(getpid()) window=\(visualWindow.windowNumber)"
            )
            fflush(stdout)
            let stop = root + "/stop"
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default
                .fileExists(atPath: stop),
                Date() < deadline {
                RunLoop.current.run(
                    mode: .default,
                    before:
                        Date().addingTimeInterval(0.05)
                )
            }
            visualController.close()
        }
        let controller =
            RepositoryCardSelectionWindowController(
                inventory: inventory
            )
        guard let window = controller.window,
              let content = window.contentView else {
            return fail("window unavailable")
        }
        controller.showWindow(nil)
        window.setFrame(
            NSRect(
                origin: window.frame.origin,
                size: NSSize(width: 720, height: 720)
            ),
            display: false
        )
        content.needsLayout = true
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let scrollViews = descendants(
            of: NSScrollView.self,
            in: content
        )
        guard scrollViews.count == 1,
              let scroll = scrollViews.first,
              let document =
                scroll.documentView as? NSStackView else {
            controller.close()
            return fail("single document stack unavailable")
        }
        document.layoutSubtreeIfNeeded()
        controller.testingSetCloneDisclosuresExpanded(true)
        content.needsLayout = true
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        document.layoutSubtreeIfNeeded()
        let writableCardStacks = document.arrangedSubviews
            .compactMap { ($0 as? NSBox)?.contentView }
            .compactMap {
                $0.subviews.compactMap { $0 as? NSStackView }.first
            }
        let representativeRows: [NSView]
        let representativeLeftEdges: [CGFloat]
        let leadingCardGeometry: Bool
        if let cardContent = document.arrangedSubviews
            .compactMap({ ($0 as? NSBox)?.contentView }).first,
           let cardStack = writableCardStacks.first {
            let directTextRows = cardStack.arrangedSubviews
                .compactMap { $0 as? NSTextField }
                .filter {
                    $0.stringValue.contains("default branch:")
                        || $0.stringValue.hasPrefix("Canonical root:")
                        || $0.stringValue.hasPrefix(
                            "Default relation:"
                        )
                        || $0.stringValue.hasPrefix("Fast-forward:")
                }
            let directControlRows = cardStack.arrangedSubviews
                .compactMap { $0 as? NSStackView }
                .filter { row in
                    descendants(of: NSButton.self, in: row)
                        .contains {
                            $0.title == "Choose canonical root…"
                                || $0.title.hasPrefix("Clone:")
                        }
                }
            representativeRows =
                directTextRows.map { $0 as NSView }
                + directControlRows.map { $0 as NSView }
            representativeLeftEdges = representativeRows.map {
                $0.convert($0.bounds, to: cardContent).minX
            }
            let textLeftEdges = directTextRows.map {
                $0.convert($0.bounds, to: cardContent).minX
            }
            let controlLeftEdges = directControlRows.map {
                $0.convert($0.bounds, to: cardContent).minX
            }
            let nestedCloneStacks = directControlRows.filter { row in
                descendants(of: NSButton.self, in: row)
                    .contains {
                        $0.title.hasPrefix(
                            "Cleanup candidates"
                        )
                    }
            }.flatMap { row in
                row.arrangedSubviews.compactMap {
                    $0 as? NSStackView
                }
            }
            leadingCardGeometry =
                writableCardStacks.allSatisfy {
                    $0.alignment == .leading
                }
                && directControlRows.allSatisfy {
                    $0.alignment == .leading
                        || descendants(
                            of: NSButton.self,
                            in: $0
                        ).contains {
                            $0.title
                                == "Choose canonical root…"
                        }
                }
                && nestedCloneStacks.allSatisfy {
                    $0.alignment == .leading
                }
                && representativeRows.count >= 5
                && textLeftEdges.count >= 4
                && controlLeftEdges.count >= 1
                && textLeftEdges.allSatisfy {
                    abs($0 - (textLeftEdges.first ?? 0)) < 1
                }
                && controlLeftEdges.allSatisfy {
                    abs($0 - (controlLeftEdges.first ?? 0)) < 1
                }
                && representativeLeftEdges.allSatisfy {
                    abs($0) <= 2
                }
        } else {
            representativeRows = []
            representativeLeftEdges = []
            leadingCardGeometry = false
        }
        let collapsedRecommendedIDs =
            selectionController.testingRecommendedRemovalIDs
        let disclosuresInitiallyCollapsed =
            selectionController.testingCloneDisclosuresAreCollapsed
        selectionController.testingSelectAllRecommendedRemoval()
        let collapsedSelectedIDs =
            selectionController.testingSelectedRemovalIDs
        selectionController
            .testingSetCloneDisclosuresExpanded(true)
        let expandedRecommendedIDs =
            selectionController.testingRecommendedRemovalIDs
        selectionController.testingSelectAllRecommendedRemoval()
        let expandedSelectedIDs =
            selectionController.testingSelectedRemovalIDs
        selectionController
            .testingSetCloneDisclosuresExpanded(false)
        let selectionButtons = selectionController.window?
            .contentView.map {
                descendants(
                    of: NSButton.self,
                    in: $0
                ).map(\.title)
            } ?? []
        let resolverFailureProtection =
            RepositoryCleanupProtection.resolve(
                executablePath: CommandLine.arguments[0],
                stateLocation: {
                    throw SecureStateError.unsafePath(
                        "synthetic state resolver failure"
                    )
                }
            )
        let resolverFailureController =
            RepositoryCardSelectionWindowController(
                inventory: cleanupInventory,
                protectedPaths:
                    resolverFailureProtection
                        .protectedPaths,
                protectionBoundaryEstablished:
                    resolverFailureProtection
                        .boundaryEstablished
            )
        resolverFailureController
            .testingSelectAllRecommendedRemoval()
        let resolverFailureClosedCleanup =
            resolverFailureController
                .testingRecommendedRemovalIDs.isEmpty
                && resolverFailureController
                    .testingSelectedRemovalIDs.isEmpty
                && resolverFailureController
                    .testingAllRemovalControlsDisabled
        let pathOnlyProtection =
            RepositoryCleanupProtection.resolve(
                executablePath: CommandLine.arguments[0],
                stateLocation: {
                    try StateLocation.isolated(root: root)
                }
            )
        let pathOnlyController =
            RepositoryCardSelectionWindowController(
                inventory: cleanupInventory,
                protectedPaths:
                    pathOnlyProtection.protectedPaths,
                protectionBoundaryEstablished:
                    pathOnlyProtection
                        .boundaryEstablished
            )
        let pathOnlyResolutionAllowsCleanup =
            pathOnlyController
                .testingRecommendedRemovalIDs
                == collapsedRecommendedIDs
        let candidate = RepositoryInventoryRemovalCandidates
            .make(from: cleanupInventory).first {
                $0.kind == .worktree
                    && $0.selectAllEligible
            }
        guard let candidate else {
            controller.close()
            return fail(
                "recommended confirmation fixture unavailable"
            )
        }
        let selection = try RemovalSelection(
            candidate: candidate,
            intent: candidate.defaultIntent,
            includePossibleSecrets: false
        )
        let prepared = try PreparedRemovalOracle.prepare(
            selection: selection,
            retention: nil
        )
        func confirmationFixture() throws -> (
            request: Body3ConfirmationRequest,
            plan: Body3BatchPlan,
            progress: Body3RunWindowController,
            cancellation: CancellationToken
        ) {
            let run = RunIdentity.make()
            let plan = try Body3BatchPlanner.make(
                run: run,
                operations: [],
                removals: [selection]
            )
            return (
                Body3ConfirmationRequest.testing(
                    run: run,
                    prepared: [prepared]
                ),
                plan,
                Body3RunWindowController(plan: plan),
                CancellationToken()
            )
        }
        func settled(
            _ request: Body3ConfirmationRequest,
            cancellation: CancellationToken
        ) -> String {
            let started = ProcessInfo.processInfo.systemUptime
            DispatchQueue.global().asyncAfter(
                deadline: .now() + 0.5
            ) {
                cancellation.cancel()
            }
            let result = request.testingWait(
                cancellation: cancellation
            )
            return ProcessInfo.processInfo.systemUptime
                - started < 0.1 ? result : "blocked"
        }

        let normalConfirm = try confirmationFixture()
        let confirmDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0]
        )
        let confirmController =
            confirmDelegate.testingPresentBody3Confirmation(
                request: normalConfirm.request,
                progressWindow: normalConfirm.progress,
                cancellation: normalConfirm.cancellation
            )
        confirmController?.testingConfirm()
        let normalConfirmSettled =
            settled(
                normalConfirm.request,
                cancellation: normalConfirm.cancellation
            ) == "confirmed"

        let normalCancel = try confirmationFixture()
        let cancelDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0]
        )
        let cancelController =
            cancelDelegate.testingPresentBody3Confirmation(
                request: normalCancel.request,
                progressWindow: normalCancel.progress,
                cancellation: normalCancel.cancellation
            )
        cancelController?.testingCancel()
        let normalCancelSettled =
            settled(
                normalCancel.request,
                cancellation: normalCancel.cancellation
            ) == "cancelled"

        let missingProgress = try confirmationFixture()
        let missingProgressDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        var releasedProgress:
            Body3RunWindowController? =
                missingProgress.progress
        let missingProgressController =
            missingProgressDelegate
                .testingPresentBody3Confirmation(
                    request: missingProgress.request,
                    progressWindow: releasedProgress!,
                    cancellation:
                        missingProgress.cancellation
                )
        missingProgressDelegate
            .testingDropBody3ProgressWindow()
        releasedProgress = nil
        missingProgressController?.testingConfirm()
        let missingProgressSettled =
            settled(
                missingProgress.request,
                cancellation:
                    missingProgress.cancellation
            ) == "cancelled"

        let missingOwner = try confirmationFixture()
        var releasedDelegate:
            ShadowSyncAppDelegate? =
                ShadowSyncAppDelegate(
                    executablePath: CommandLine.arguments[0]
                )
        let missingOwnerController =
            releasedDelegate?
                .testingPresentBody3Confirmation(
                    request: missingOwner.request,
                    progressWindow: missingOwner.progress,
                    cancellation:
                        missingOwner.cancellation
                )
        releasedDelegate = nil
        missingOwnerController?.testingConfirm()
        let missingOwnerSettled =
            settled(
                missingOwner.request,
                cancellation: missingOwner.cancellation
            ) == "cancelled"

        let staleOriginal = try confirmationFixture()
        let staleReplacement = try confirmationFixture()
        let staleDelegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0]
        )
        let staleController =
            staleDelegate.testingPresentBody3Confirmation(
                request: staleOriginal.request,
                progressWindow: staleOriginal.progress,
                cancellation: staleOriginal.cancellation
            )
        staleController?.testingConfirm()
        let replacementController =
            staleDelegate.testingPresentBody3Confirmation(
                request: staleReplacement.request,
                progressWindow: staleReplacement.progress,
                cancellation:
                    staleReplacement.cancellation
            )
        staleController?.testingConfirm()
        let staleDidNotReplace =
            staleDelegate.testingBody3ConfirmationRequest
                === staleReplacement.request
        replacementController?.testingCancel()
        let duplicateAndStaleSettled =
            staleDidNotReplace
                && settled(
                    staleReplacement.request,
                    cancellation:
                        staleReplacement.cancellation
                ) == "cancelled"
        let mismatchCopy =
            "Final confirmation no longer matched the pending batch; no removal command was admitted."
        let mismatchCompletion =
            try Body3BatchReport.testing(
                plan: normalConfirm.plan,
                status: .cancelled,
                cancelled: true
            )
        normalConfirm.progress.fail(mismatchCopy)
        normalConfirm.progress.finish(
            mismatchCompletion
        )
        let mismatchPresentation =
            normalConfirm.progress
                .testingTerminalPresentation
        let mismatchRemainsSpecific =
            mismatchPresentation.headline
                == "Needs Attention"
                && mismatchPresentation.summary
                    == mismatchCopy
                        + " No unreported retry will start."
                && mismatchPresentation.terminal
                && mismatchPresentation.hasReport

        let successCompletion = try confirmationFixture()
        let successReport =
            try Body3BatchReport.testing(
                plan: successCompletion.plan,
                status: .succeeded,
                cancelled: false
            )
        successCompletion.progress.finish(successReport)
        let successPresentation =
            successCompletion.progress
                .testingTerminalPresentation
        let successStillRenders =
            successPresentation.headline == "Complete"
                && successPresentation.terminal
                && successPresentation.hasReport

        let stableRows = try confirmationFixture()
        guard let firstStableNode =
                stableRows.plan.nodes.first else {
            return fail("stable row fixture unavailable")
        }
        let initialActionIdentities =
            stableRows.progress.testingActionRowIdentities
        let initialGroupIdentities =
            stableRows.progress
                .testingRepositoryGroupIdentities
        let startedRecord = Body3LogRecord(
            run: stableRows.plan.run,
            sequence: 2,
            type: "node_started",
            repository: firstStableNode.repositoryID,
            operation: firstStableNode.id,
            kind: firstStableNode.kind.rawValue,
            phase: firstStableNode.kind.phase,
            worker: 1,
            status: .running,
            detail: "Public action started."
        )
        stableRows.progress.update(
            Body3CoordinatorEvent(record: startedRecord)
        )
        let actionTextBeforeCommand =
            stableRows.progress.testingActionText[
                firstStableNode.id
            ]
        let commandOnlyRecord = Body3LogRecord(
            run: stableRows.plan.run,
            sequence: 3,
            type: "command",
            repository: firstStableNode.repositoryID,
            operation: firstStableNode.id,
            kind: firstStableNode.kind.rawValue,
            phase: firstStableNode.kind.phase,
            worker: 1,
            executable: "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            outcome: "command completed",
            status: .running,
            detail: "COMMAND-ONLY-EVENT"
        )
        stableRows.progress.update(
            Body3CoordinatorEvent(
                record: commandOnlyRecord
            )
        )
        let collapsedLogStayedLazy =
            stableRows.progress.testingLogIsCollapsed
                && stableRows.progress
                    .testingLiveLogText.isEmpty
                && stableRows.progress
                    .testingPerformanceEvidence
                    .recordsReceived == 2
                && stableRows.progress
                    .testingPerformanceEvidence
                    .visibleLogRenders == 0
        stableRows.progress.testingToggleLog()
        let commandStayedInLiveLog =
            stableRows.progress.testingActionText[
                firstStableNode.id
            ] == actionTextBeforeCommand
                && stableRows.progress
                    .testingLiveLogText
                    .contains("COMMAND-ONLY-EVENT")
        let terminalRecord = Body3LogRecord(
            run: stableRows.plan.run,
            sequence: 4,
            type: "node_terminal",
            repository: firstStableNode.repositoryID,
            operation: firstStableNode.id,
            kind: firstStableNode.kind.rawValue,
            phase: firstStableNode.kind.phase,
            worker: 1,
            status: .succeeded,
            detail: "Public action completed.",
            technicalDetail:
                "token=super-secret "
                    + "/" + "Users/operator/private"
        )
        stableRows.progress.update(
            Body3CoordinatorEvent(record: terminalRecord)
        )
        let metadataStart = WallClock.timestamp(
            Date(timeIntervalSince1970: 1_800_000_000)
        )
        let metadataEnd = WallClock.timestamp(
            Date(timeIntervalSince1970: 1_800_000_002)
        )
        let metadataResults =
            stableRows.plan.nodes.enumerated().map {
                index, node in
                Body3BatchNodeResult(
                    node: node,
                    status: index == 0
                        ? .succeeded : .skipped,
                    worker: index == 0 ? 1 : nil,
                    startedAt:
                        index == 0
                            ? metadataStart : nil,
                    endedAt: metadataEnd,
                    durationMilliseconds:
                        index == 0 ? 2_000 : 0,
                    detail:
                        index == 0
                            ? "Public action completed."
                            : "Dependency did not run.",
                    technicalDetail:
                        index == 0
                            ? "token=super-secret "
                                + "/" + "Users/operator/private"
                            : nil
                )
            }
        let stableReport = try Body3BatchReport(
            run: stableRows.plan.run,
            startedAt: metadataStart,
            endedAt: metadataEnd,
            cancelled: false,
            results: metadataResults
        )
        stableRows.progress.finish(stableReport)
        let terminalActionIdentities =
            stableRows.progress.testingActionRowIdentities
        let terminalGroupIdentities =
            stableRows.progress
                .testingRepositoryGroupIdentities
        let stableRowsAndMetadata =
            initialActionIdentities
                == terminalActionIdentities
                && initialGroupIdentities
                    == terminalGroupIdentities
                && stableRows.progress
                    .testingActionRowOrder
                    == stableRows.plan.nodes.map(\.id)
                && stableRows.progress
                    .testingRepositoryGroupsAreLeadingAndBounded
                && stableRows.progress
                    .testingHierarchyMeetsApprovedGeometry
                && collapsedLogStayedLazy
                && commandStayedInLiveLog
                && stableRows.progress.testingActionText[
                    firstStableNode.id
                ]?.contains(
                    "Public action completed."
                ) == true
                && stableRows.progress.testingActionText[
                    firstStableNode.id
                ]?.contains("COMMAND-ONLY-EVENT")
                    == false
                && stableRows.progress.testingActionText[
                    firstStableNode.id
                ]?.contains("[REDACTED PATH]")
                    == true
                && stableRows.progress
                    .testingRunMetadataText
                    .contains("Duration 2 seconds")
                && stableRows.progress
                    .testingRunMetadataText
                    .contains("1 attempted action")
                && !stableRows.progress
                    .testingRunMetadataText
                    .contains(firstStableNode.repositoryID ?? "")
        let pacific = TimeZone(
            identifier: "America/Los_Angeles"
        )!
        let daylightTimestamp =
            try Body3RunMetadataPresentation.localTimestamp(
                "2026-10-06T01:45:01.000Z",
                timeZone: pacific
            )
        let standardTimestamp =
            try Body3RunMetadataPresentation.localTimestamp(
                "2026-01-06T02:45:01.000Z",
                timeZone: pacific
            )
        let metadataFormattingHolds =
            daylightTimestamp
                == "Oct 5, 2026 at 6:45:01 PM PDT"
            && standardTimestamp
                == "Jan 5, 2026 at 6:45:01 PM PST"
            && [
                (499, "0 seconds"),
                (500, "1 second"),
                (59_500, "1 minute"),
                (3_599_500, "1 hour"),
                (86_399_500, "1 day"),
                (
                    90_061_500,
                    "1 day 1 hour 1 minute 2 seconds"
                ),
            ].allSatisfy {
                Body3RunMetadataPresentation.duration(
                    Int64($0.0)
                ) == $0.1
            }
        let aquaFill =
            ShadowSyncAppColors
                .resolvedCleanupInspectionPanelFill(
                    for: NSAppearance(
                        named: .aqua
                    )!
                )
                .usingColorSpace(.deviceRGB)!
        let darkFill =
            ShadowSyncAppColors
                .resolvedCleanupInspectionPanelFill(
                    for: NSAppearance(
                        named: .darkAqua
                    )!
                )
                .usingColorSpace(.deviceRGB)!
        func resolvedColor(
            _ color: NSColor,
            appearance: NSAppearance
        ) -> NSColor {
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved =
                    color.usingColorSpace(.deviceRGB)
                    ?? color
            }
            return resolved
        }
        func luminance(_ color: NSColor) -> CGFloat {
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.03928
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.redComponent)
                + 0.7152 * channel(color.greenComponent)
                + 0.0722 * channel(color.blueComponent)
        }
        func contrast(_ first: NSColor, _ second: NSColor)
            -> CGFloat {
            let high = max(luminance(first), luminance(second))
            let low = min(luminance(first), luminance(second))
            return (high + 0.05) / (low + 0.05)
        }
        let aquaAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!
        let aquaLabel = resolvedColor(
            .labelColor,
            appearance: aquaAppearance
        )
        let darkLabel = resolvedColor(
            .labelColor,
            appearance: darkAppearance
        )
        let aquaBackground = resolvedColor(
            .windowBackgroundColor,
            appearance: aquaAppearance
        )
        let darkBackground = resolvedColor(
            .windowBackgroundColor,
            appearance: darkAppearance
        )
        let appearanceColorsHold =
            aquaFill.redComponent > 0.75
                && aquaFill.redComponent < 0.98
                && darkFill.redComponent > 0.10
                && darkFill.redComponent < 0.35
                && aquaFill.alphaComponent == 1
                && darkFill.alphaComponent == 1
                && contrast(aquaLabel, aquaFill) >= 4.5
                && contrast(darkLabel, darkFill) >= 4.5
                && contrast(aquaBackground, aquaFill) < 1.5
                && contrast(darkBackground, darkFill) < 1.5
        let historicalRows = Body3RunWindowController(
            plan: stableRows.plan
        )
        for record in [
            startedRecord,
            commandOnlyRecord,
            terminalRecord,
        ] {
            historicalRows.update(
                Body3CoordinatorEvent(record: record)
            )
        }
        historicalRows.finish(stableReport)
        let historicalMetadataMatches =
            historicalRows.testingRunMetadataText
                == stableRows.progress
                    .testingRunMetadataText
                && historicalRows.testingActionText
                    == stableRows.progress.testingActionText
        historicalRows.close()

        let highVolume = Body3RunWindowController(
            plan: stableRows.plan
        )
        let highVolumeEvents = (1...816).map {
            sequence in
            Body3CoordinatorEvent(
                record: Body3LogRecord(
                    run: stableRows.plan.run,
                    sequence: sequence,
                    type: "command",
                    repository:
                        firstStableNode.repositoryID,
                    operation: firstStableNode.id,
                    kind:
                        firstStableNode.kind.rawValue,
                    phase:
                        firstStableNode.kind.phase,
                    worker: sequence % 2 + 1,
                    executable: "/usr/bin/git",
                    arguments: [
                        "status",
                        String(
                            repeating: "x",
                            count: 64
                        ),
                    ],
                    outcome: "exit 0",
                    detail:
                        "high-volume record \(sequence)"
                )
            )
        }
        let deliveryDelegate =
            ShadowSyncAppDelegate(
                executablePath:
                    CommandLine.arguments[0]
            )
        let deliveryCancellation =
            CancellationToken()
        deliveryDelegate.testingDeliverBody3Events(
            Body3EventBatch(
                events: highVolumeEvents,
                maximumBacklogDepth:
                    highVolumeEvents.count
            ),
            progressWindow: highVolume,
            cancellation: deliveryCancellation
        )
        let collapsedEvidence =
            highVolume.testingPerformanceEvidence
        highVolume.testingToggleLog()
        let expandedEvidence =
            highVolume.testingPerformanceEvidence
        let incrementalEvent =
            Body3CoordinatorEvent(
                record: Body3LogRecord(
                    run: stableRows.plan.run,
                    sequence: 817,
                    type: "command",
                    repository:
                        firstStableNode.repositoryID,
                    operation: firstStableNode.id,
                    kind:
                        firstStableNode.kind.rawValue,
                    phase:
                        firstStableNode.kind.phase,
                    worker: 1,
                    executable: "/usr/bin/git",
                    arguments: [
                        "status",
                        String(
                            repeating: "y",
                            count: 64
                        ),
                    ],
                    outcome: "exit 0",
                    detail:
                        "high-volume record 817"
                )
            )
        deliveryDelegate.testingDeliverBody3Events(
            Body3EventBatch(
                events: [incrementalEvent],
                maximumBacklogDepth: 1
            ),
            progressWindow: highVolume,
            cancellation: deliveryCancellation
        )
        let incrementalEvidence =
            highVolume.testingPerformanceEvidence
        highVolume.testingToggleLog()
        let collapsedCatchupEvent =
            Body3CoordinatorEvent(
                record: Body3LogRecord(
                    run: stableRows.plan.run,
                    sequence: 818,
                    type: "event",
                    detail:
                        "collapsed catch-up 👩🏽‍💻 e\u{301}"
                )
            )
        deliveryDelegate.testingDeliverBody3Events(
            Body3EventBatch(
                events: [collapsedCatchupEvent],
                maximumBacklogDepth: 1
            ),
            progressWindow: highVolume,
            cancellation: deliveryCancellation
        )
        let recollapsedEvidence =
            highVolume.testingPerformanceEvidence
        highVolume.testingToggleLog()
        let caughtUpEvidence =
            highVolume.testingPerformanceEvidence
        let expectedVisibleLog =
            Body3RunLogReader.render(
                (
                    highVolumeEvents
                        + [
                            incrementalEvent,
                            collapsedCatchupEvent,
                        ]
                ).compactMap(\.record)
            )
        let inbox = Body3EventInbox()
        let scheduleCount =
            highVolumeEvents.reduce(into: 0) {
                count, event in
                if inbox.submit(event) {
                    count += 1
                }
            }
        let inboxBatch = inbox.drain()
        let highVolumeWorkIsBounded =
            collapsedEvidence.recordsReceived == 816
                && collapsedEvidence
                    .maximumBacklogDepth == 816
                && collapsedEvidence
                    .coalescedEventBatches == 1
                && collapsedEvidence
                    .visibleLogRenders == 0
                && expandedEvidence.visibleLogRenders
                    == 1
                && incrementalEvidence
                    .visibleLogRenders == 2
                && recollapsedEvidence
                    .visibleLogRenders == 2
                && caughtUpEvidence
                    .visibleLogRenders == 3
                && highVolume.testingLiveLogText
                    == expectedVisibleLog
                && highVolume
                    .testingPerformanceEvidenceText
                    .contains("UI evidence")
                && scheduleCount == 1
                && inboxBatch.events.count == 816
                && inboxBatch.maximumBacklogDepth
                    == 816
                && inbox.drain().events.isEmpty
        deliveryDelegate.testingSetBody3Progress(nil)
        highVolume.close()

        let cancellationCompletion =
            try confirmationFixture()
        let cancellationReport =
            try Body3BatchReport.testing(
                plan: cancellationCompletion.plan,
                status: .cancelled,
                cancelled: true
            )
        cancellationCompletion.progress.finish(
            cancellationReport
        )
        let cancellationPresentation =
            cancellationCompletion.progress
                .testingTerminalPresentation
        let cancellationStillRenders =
            cancellationPresentation.headline
                == "Cancelled · residue checked"
                && cancellationPresentation.terminal
                && cancellationPresentation.hasReport
                && cancellationPresentation
                    .closeAcknowledgementRunID == nil
                && cancellationPresentation
                    .reviewRequiredRunID
                    == cancellationCompletion.plan.run

        let pausedCompletion = try confirmationFixture()
        let pausedReport = try Body3BatchReport.testing(
            plan: pausedCompletion.plan,
            status: .succeeded,
            cancelled: false,
            paused: true
        )
        pausedCompletion.progress.finish(pausedReport)
        let failedCompletion = try confirmationFixture()
        let failedReport = try Body3BatchReport.testing(
            plan: failedCompletion.plan,
            status: .failed,
            cancelled: false,
            detail: "Partial residue needs attention."
        )
        failedCompletion.progress.finish(failedReport)
        let refusedCompletion = try confirmationFixture()
        let refusedReport = try Body3BatchReport.testing(
            plan: refusedCompletion.plan,
            status: .refused,
            cancelled: false
        )
        refusedCompletion.progress.finish(refusedReport)
        let interruptedCompletion =
            try confirmationFixture()
        interruptedCompletion.progress.fail(
            "Interrupted completion needs review."
        )
        let quitDecisionDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        let terminalQuitDecisionsHold =
            quitDecisionDelegate
                .testingBody3QuitDecision(
                    successCompletion.progress
                ) == "terminate"
                && quitDecisionDelegate
                    .testingBody3QuitDecision(
                        cancellationCompletion.progress
                    ) == "terminate"
                && quitDecisionDelegate
                    .testingBody3QuitDecision(
                        pausedCompletion.progress
                    ) == "terminate"
                && quitDecisionDelegate
                    .testingBody3QuitDecision(
                        failedCompletion.progress
                    ) == "terminate"
                && quitDecisionDelegate
                    .testingBody3QuitDecision(
                        refusedCompletion.progress
                    ) == "terminate"
                && quitDecisionDelegate
                    .testingBody3QuitDecision(
                        interruptedCompletion.progress
                    ) == "review"
        let reviewContractsHold =
            successPresentation
                .closeAcknowledgementRunID
                == successCompletion.plan.run
                && successCompletion.progress
                    .canQuitImmediately(
                        acknowledgedRunID: nil
                    )
                && successPresentation
                    .reviewRequiredRunID == nil
                && cancellationCompletion.progress
                    .canQuitImmediately(
                        acknowledgedRunID: nil
                    )
                && pausedCompletion.progress
                    .testingTerminalPresentation
                    .closeAcknowledgementRunID == nil
                && pausedCompletion.progress
                    .canQuitImmediately(
                        acknowledgedRunID: nil
                    )
                && failedCompletion.progress
                    .testingTerminalPresentation
                    .reviewRequiredRunID
                    == failedCompletion.plan.run
                && failedCompletion.progress
                    .canQuitImmediately(
                        acknowledgedRunID: nil
                    )
                && refusedCompletion.progress
                    .testingTerminalPresentation
                    .reviewRequiredRunID
                    == refusedCompletion.plan.run
                && interruptedCompletion.progress
                    .testingTerminalPresentation
                    .reviewRequiredRunID
                    == interruptedCompletion.plan.run
                && !interruptedCompletion.progress
                    .canQuitImmediately(
                        acknowledgedRunID: nil
                    )

        let quitRouteCompletion =
            try confirmationFixture()
        let quitRouteReport =
            try Body3BatchReport.testing(
                plan: quitRouteCompletion.plan,
                status: .failed,
                cancelled: false,
                detail:
                    "Partial residue needs exact review."
            )
        quitRouteCompletion.progress.finish(
            quitRouteReport
        )
        let quitRouteDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        quitRouteDelegate.testingSetBody3Progress(
            quitRouteCompletion.progress
        )
        let terminalReportQuitDoesNotRequireReview =
            quitRouteDelegate
                .testingBody3QuitDecision(
                    quitRouteCompletion.progress
                ) == "terminate"
                && quitRouteDelegate
                    .testingBody3Progress
                    === quitRouteCompletion.progress
        let explicitReportReviewRoute =
            quitRouteDelegate
                .testingRouteBody3QuitReview(
                    quitRouteCompletion.progress
                )
                && quitRouteDelegate
                    .testingBody3Progress == nil
                && quitRouteDelegate
                    .testingHistoricalBody3Viewer?.runID
                    == quitRouteCompletion.plan.run
                && quitRouteDelegate
                    .testingAcknowledgedBody3Run == nil
        guard let reviewedQuitWindow =
                quitRouteDelegate
                    .testingHistoricalBody3Viewer else {
            return fail(
                "Body 3 quit review window was not presented"
            )
        }
        let exactReviewAllowsQuit =
            quitRouteDelegate
                .testingAcknowledgeReviewedBody3(
                    run: quitRouteCompletion.plan.run,
                    controller: reviewedQuitWindow
                )
                && reviewedQuitWindow
                    .canQuitImmediately(
                        acknowledgedRunID:
                            quitRouteDelegate
                                .testingAcknowledgedBody3Run
                    )
        let reportlessTerminalCannotQuit =
            !interruptedCompletion.progress
                .canQuitImmediately(
                    acknowledgedRunID:
                        quitRouteDelegate
                            .testingAcknowledgedBody3Run
                )

        let nonterminalQuit = try confirmationFixture()
        let nonterminalStillCancels =
            quitRouteDelegate
                .testingBody3QuitDecision(
                    nonterminalQuit.progress
                ) == "cancelActiveRun"
        let needsAttentionQuit =
            try confirmationFixture()
        needsAttentionQuit.progress.fail(
            "Synthetic Needs Attention."
        )
        quitRouteDelegate.testingSetBody3Progress(
            needsAttentionQuit.progress
        )
        let needsAttentionRoutesReview =
            quitRouteDelegate
                .testingBody3QuitDecision(
                    needsAttentionQuit.progress
                ) == "review"
                && quitRouteDelegate
                    .testingRouteBody3QuitReview(
                        needsAttentionQuit.progress
                    )
                && quitRouteDelegate
                    .testingBody3Progress
                    === needsAttentionQuit.progress

        let invalidCompletion = try confirmationFixture()
        let invalidNodes = Array(
            invalidCompletion.plan.nodes.dropLast()
        )
        let invalidReport = try Body3BatchReport.testing(
            plan: invalidCompletion.plan,
            status: .succeeded,
            cancelled: false,
            nodes: invalidNodes
        )
        invalidCompletion.progress.finish(invalidReport)
        let invalidPresentation =
            invalidCompletion.progress
                .testingTerminalPresentation
        let invalidSameRunNeedsAttention =
            invalidPresentation.headline
                == "Needs Attention"
                && invalidPresentation.terminal
                && !invalidPresentation.hasReport
                && invalidPresentation
                    .reviewRequiredRunID
                    == invalidCompletion.plan.run
                && invalidPresentation
                    .closeAcknowledgementRunID == nil

        let successfulCloseDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        let successfulCloseAcknowledged =
            successfulCloseDelegate
                .testingCloseLiveBody3Progress(
                    successCompletion.progress
                )
                && successfulCloseDelegate
                    .testingAcknowledgedBody3Run
                    == successCompletion.plan.run
        let reviewCloseDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        let reviewCloseStayedUnacknowledged =
            reviewCloseDelegate
                .testingCloseLiveBody3Progress(
                    failedCompletion.progress
                )
                && reviewCloseDelegate
                    .testingAcknowledgedBody3Run == nil

        let explicitReviewDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        explicitReviewDelegate.testingSetBody3Progress(
            cancellationCompletion.progress
        )
        let explicitExactAcknowledgement =
            explicitReviewDelegate
                .testingAcknowledgeReviewedBody3(
                    run: cancellationCompletion.plan.run,
                    controller:
                        cancellationCompletion.progress
                )
                && explicitReviewDelegate
                    .testingAcknowledgedBody3Run
                    == cancellationCompletion.plan.run
        explicitReviewDelegate.testingSetBody3Progress(
            pausedCompletion.progress
        )
        let staleReviewIgnored =
            !explicitReviewDelegate
                .testingAcknowledgeReviewedBody3(
                    run: cancellationCompletion.plan.run,
                    controller:
                        cancellationCompletion.progress
                )
                && explicitReviewDelegate
                    .testingAcknowledgedBody3Run
                    == cancellationCompletion.plan.run

        let mismatchedRunCompletion =
            try confirmationFixture()
        mismatchedRunCompletion.progress.finish(
            successReport
        )
        let mismatchedRunPresentation =
            mismatchedRunCompletion.progress
                .testingTerminalPresentation
        let mismatchedRunNeedsAttention =
            mismatchedRunPresentation.headline
                == "Needs Attention"
                && mismatchedRunPresentation.summary
                    == "The final batch report named a different run than this live window; review the validated log before retrying. No unreported retry will start."
                && mismatchedRunPresentation.terminal
                && !mismatchedRunPresentation.hasReport
                && mismatchedRunPresentation
                    .reviewRequiredRunID
                    == mismatchedRunCompletion.plan.run

        let staleCompletion = try confirmationFixture()
        let staleDeliveryDelegate =
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0]
            )
        staleDeliveryDelegate.testingSetBody3Progress(
            staleCompletion.progress
        )
        let oldCallbackRejected =
            !staleDeliveryDelegate
                .testingDeliverBody3Report(
                    successReport,
                    run: successCompletion.plan.run,
                    to: successCompletion.progress
                )
        let stalePresentation =
            staleCompletion.progress
                .testingTerminalPresentation
        let staleCompletionIgnored =
            oldCallbackRejected
                && !stalePresentation.terminal
                && !stalePresentation.hasReport
        let cardFrames = document.arrangedSubviews
            .compactMap { view -> NSRect? in
                guard view is NSBox else { return nil }
                return view.frame
            }
        let overlap = cardFrames.indices.contains {
            first in
            cardFrames.indices.contains {
                second in
                first < second
                    && cardFrames[first]
                        .intersects(cardFrames[second])
            }
        }
        let canonicalButtons = descendants(
            of: NSButton.self,
            in: document
        ).filter {
            $0.title == "Choose canonical root…"
        }
        let canonicalFrames = canonicalButtons.map {
            $0.convert($0.bounds, to: document)
        }
        let distinctCanonicalY = Set(
            canonicalFrames.map {
                Int($0.midY.rounded())
            }
        ).count
        let text = descendants(
            of: NSTextField.self,
            in: document
        ).map(\.stringValue)
        let cloneDisclosures = descendants(
            of: NSButton.self,
            in: document
        ).filter {
            $0.title.hasPrefix("Cleanup candidates")
                && $0.title.hasSuffix(" ▸")
        }
        let inspectButtons = descendants(
            of: NSButton.self,
            in: document
        ).filter {
            $0.title == "Inspect branches & worktrees"
        }
        let cleanupTitles = descendants(
            of: NSTextField.self,
            in: document
        ).filter {
            $0.stringValue
                == "Optional cleanup inspection"
        }
        let inspectFrames = inspectButtons.map {
            $0.convert($0.bounds, to: document)
        }.sorted { $0.midY < $1.midY }
        let cleanupTitleFrames = cleanupTitles.map {
            $0.convert($0.bounds, to: document)
        }.sorted { $0.midY < $1.midY }
        let cleanupControlsLead =
            inspectFrames.count
                == cleanupTitleFrames.count
                && zip(
                    inspectFrames,
                    cleanupTitleFrames
                ).allSatisfy {
                    abs($0.0.minX - $0.1.minX)
                        <= 2
                }
        let greenPassed =
            !hasAmbiguousLayout(content)
                && zeroInspectionBulkGate
                && zeroInspectionSelectsNothing
                && manageDisabledDuringInspection
                && mixedInspectionBulkGate
                && repairUnavailablePresentationIsNeutral
                && disclosuresInitiallyCollapsed
                && !collapsedRecommendedIDs.isEmpty
                && collapsedSelectedIDs
                    == collapsedRecommendedIDs
                && expandedSelectedIDs
                    == expandedRecommendedIDs
                && expandedRecommendedIDs
                    == collapsedRecommendedIDs
                && resolverFailureClosedCleanup
                && pathOnlyResolutionAllowsCleanup
                && normalConfirmSettled
                && normalCancelSettled
                && missingProgressSettled
                && missingOwnerSettled
                && duplicateAndStaleSettled
                && mismatchRemainsSpecific
                && successStillRenders
                && stableRowsAndMetadata
                && metadataFormattingHolds
                && appearanceColorsHold
                && historicalMetadataMatches
                && highVolumeWorkIsBounded
                && cancellationStillRenders
                && reviewContractsHold
                && terminalQuitDecisionsHold
                && terminalReportQuitDoesNotRequireReview
                && explicitReportReviewRoute
                && exactReviewAllowsQuit
                && reportlessTerminalCannotQuit
                && nonterminalStillCancels
                && needsAttentionRoutesReview
                && invalidSameRunNeedsAttention
                && successfulCloseAcknowledged
                && reviewCloseStayedUnacknowledged
                && explicitExactAcknowledgement
                && staleReviewIgnored
                && mismatchedRunNeedsAttention
                && staleCompletionIgnored
                && leadingCardGeometry
                && document.frame.width > 0
                && document.frame.height
                    > scroll.contentView.bounds.height
                && cardFrames.count
                    == writable.count + protected.count
                && cardFrames.allSatisfy {
                    $0.width > 0 && $0.height > 0
                }
                && !overlap
                && canonicalButtons.count
                    == writable.count
                && distinctCanonicalY
                    == canonicalButtons.count
                && canonicalFrames.allSatisfy {
                    document.bounds.contains($0)
                }
                && text.contains("Writable repositories")
                && text.contains("Protected repositories")
                && selectionButtons.contains(
                    "Inspect for all repositories"
                )
                && descendants(
                    of: NSButton.self,
                    in: document
                ).contains {
                    $0.title
                        == "References (\(references.count)) ▸"
                }
                && cloneDisclosures.isEmpty
                && inspectButtons.count
                    == writable.count
                && cleanupTitles.count
                    == writable.count
                && cleanupControlsLead
        gatedCleanupController.close()
        let unpinned =
            RepositoryCardSelectionWindowController(
                inventory: inventory
            )
        guard let unpinnedWindow = unpinned.window,
              let unpinnedContent =
                unpinnedWindow.contentView else {
            controller.close()
            return fail("red-phase window unavailable")
        }
        unpinned.showWindow(nil)
        unpinnedWindow.setFrame(
            NSRect(
                origin: unpinnedWindow.frame.origin,
                size: NSSize(width: 720, height: 720)
            ),
            display: false
        )
        guard let unpinnedScroll = descendants(
            of: NSScrollView.self,
            in: unpinnedContent
        ).first,
              let unpinnedDocument =
                unpinnedScroll.documentView
                    as? NSStackView else {
            controller.close()
            unpinned.close()
            return fail("red-phase document unavailable")
        }
        let documentConstraints =
            unpinnedScroll.contentView.constraints
                .filter { constraint in
                    (constraint.firstItem as? NSView)
                        === unpinnedDocument
                        || (constraint.secondItem as? NSView)
                            === unpinnedDocument
                }
        NSLayoutConstraint.deactivate(
            documentConstraints
        )
        unpinnedContent.needsLayout = true
        unpinnedWindow.layoutIfNeeded()
        unpinnedContent.layoutSubtreeIfNeeded()
        unpinnedWindow.displayIfNeeded()
        let unpinnedFrames =
            unpinnedDocument.arrangedSubviews
                .compactMap { view -> NSRect? in
                    guard view is NSBox else {
                        return nil
                    }
                    return view.frame
                }
        let unpinnedOverlap =
            unpinnedFrames.indices.contains {
                first in
                unpinnedFrames.indices.contains {
                    second in
                    first < second
                        && unpinnedFrames[first]
                            .intersects(
                                unpinnedFrames[second]
                            )
                }
            }
        let redDetected =
            documentConstraints.count == 3
                && (
                    hasAmbiguousLayout(
                        unpinnedContent
                    )
                        || unpinnedDocument
                            .frame.height
                            <= unpinnedScroll
                                .contentView
                                .bounds.height
                        || unpinnedFrames.contains {
                            $0.width <= 0
                                || $0.height <= 0
                        }
                        || unpinnedOverlap
                )
        let passed = greenPassed && redDetected
        fputs(
            "Body 3 layout evidence: cards=\(cardFrames.count) "
                + "window=\(window.frame) "
                + "content=\(content.frame) "
                + "scroll=\(scroll.frame) "
                + "canonical-buttons=\(canonicalButtons.count) "
                + "distinct-y=\(distinctCanonicalY) "
                + "document-height=\(document.frame.height) "
                + "clip-height=\(scroll.contentView.bounds.height) "
                + "ambiguous=\(hasAmbiguousLayout(content)) "
                + "overlap=\(overlap) "
                + "leading-card-geometry=\(leadingCardGeometry) "
                + "left-edges=\(representativeLeftEdges) "
                + "red-detected=\(redDetected) "
                + "cleanup-zero-gate=\(zeroInspectionBulkGate) "
                + "cleanup-zero-selection=\(zeroInspectionSelectsNothing) "
                + "cleanup-manage-inflight=\(manageDisabledDuringInspection) "
                + "cleanup-mixed-gate=\(mixedInspectionBulkGate) "
                + "repair-unavailable-neutral=\(repairUnavailablePresentationIsNeutral) "
                + "cleanup-leading=\(cleanupControlsLead) "
                + "stable-results=\(stableRowsAndMetadata) "
                + "metadata-format=\(metadataFormattingHolds) "
                + "appearance-colors=\(appearanceColorsHold) "
                + "historical-results=\(historicalMetadataMatches) "
                + "bounded-ui-work=\(highVolumeWorkIsBounded) "
                + "collapsed-select=\(collapsedSelectedIDs == collapsedRecommendedIDs) "
                + "expanded-select=\(expandedSelectedIDs == expandedRecommendedIDs) "
                + "resolver-fail-closed=\(resolverFailureClosedCleanup) "
                + "path-only=\(pathOnlyResolutionAllowsCleanup) "
                + "confirm=\(normalConfirmSettled) "
                + "cancel=\(normalCancelSettled) "
                + "missing-progress=\(missingProgressSettled) "
                + "missing-owner=\(missingOwnerSettled) "
                + "stale=\(duplicateAndStaleSettled) "
                + "mismatch-precedence=\(mismatchRemainsSpecific) "
                + "success-report=\(successStillRenders) "
                + "cancel-report=\(cancellationStillRenders) "
                + "review-contracts=\(reviewContractsHold) "
                + "quit-decisions=\(terminalQuitDecisionsHold) "
                + "quit-with-report=\(terminalReportQuitDoesNotRequireReview) "
                + "explicit-review=\(explicitReportReviewRoute) "
                + "reviewed-quit=\(exactReviewAllowsQuit) "
                + "reportless-quit=\(reportlessTerminalCannotQuit) "
                + "active-quit=\(nonterminalStillCancels) "
                + "attention-quit=\(needsAttentionRoutesReview) "
                + "invalid-report=\(invalidSameRunNeedsAttention) "
                + "success-close=\(successfulCloseAcknowledged) "
                + "review-close=\(reviewCloseStayedUnacknowledged) "
                + "exact-review=\(explicitExactAcknowledgement) "
                + "stale-review=\(staleReviewIgnored) "
                + "mismatched-run=\(mismatchedRunNeedsAttention) "
                + "stale-completion=\(staleCompletionIgnored)\n",
            stderr
        )
        if !passed {
            fputs(
                "Body 3 layout diagnostics: "
                    + "ambiguous-views=\(ambiguousDescriptions(content)) "
                    + "card-frames=\(cardFrames) "
                    + "leading-card-geometry=\(leadingCardGeometry) "
                    + "representative-left-edges=\(representativeLeftEdges) "
                    + "cleanup-inspect-x=\(inspectFrames.map(\.minX)) "
                    + "cleanup-title-x=\(cleanupTitleFrames.map(\.minX))\n",
                stderr
            )
        }
        controller.close()
        selectionController.close()
        resolverFailureController.close()
        pathOnlyController.close()
        unpinned.close()
        return passed || fail("layout contract was not satisfied")
    }

    private static func testOriginIdentityPresentation(
        root: String
    ) throws -> Bool {
        func fail(_ stage: String) -> Bool {
            fputs("M5 origin identity failure: \(stage)\n", stderr)
            return false
        }
        func descendants<T: NSView>(
            of type: T.Type,
            in view: NSView
        ) -> [T] {
            view.subviews.flatMap { subview -> [T] in
                let current = (subview as? T).map { [$0] } ?? []
                return current + descendants(of: type, in: subview)
            }
        }
        func settleAtMinimumSize(_ window: NSWindow) {
            window.setFrame(
                NSRect(origin: window.frame.origin, size: window.minSize),
                display: false
            )
            window.contentView?.needsLayout = true
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func isActuallyMultiline(_ field: NSTextField) -> Bool {
            guard let font = field.font else {
                return false
            }
            return field.frame.height
                > font.boundingRectForFont.height * 1.5
        }
        func hasAmbiguousLayout(_ view: NSView) -> Bool {
            view.hasAmbiguousLayout
                || view.subviews.contains(where: hasAmbiguousLayout)
        }
        func ambiguousLayoutDescriptions(_ view: NSView) -> [String] {
            let current = view.hasAmbiguousLayout
                ? ["\(type(of: view)):\(view.frame)"]
                : []
            return current + view.subviews.flatMap(
                ambiguousLayoutDescriptions
            )
        }
        func isContained(_ view: NSView, in ancestor: NSView) -> Bool {
            let converted = view.convert(view.bounds, to: ancestor)
            return ancestor.bounds.insetBy(dx: -1, dy: -1).contains(converted)
        }
        let ssh = RepositoryCandidate(
            id: "fixture-owner/skills",
            displayName: "misleading local basename",
            path: root + "/Unicode Ω/checkout one",
            rawOrigin: "git@github.com:Fixture-Owner/Skills.git",
            presentationLocation: "~/dev/personal/Unicode Ω/checkout one"
        )
        let https = RepositoryCandidate(
            id: "fixture-owner/skills",
            displayName: "another misleading basename",
            path: root + "/path with spaces/checkout two",
            rawOrigin: "https://github.com/fixture-owner/skills/",
            presentationLocation: "~/dev/capabilities/path with spaces/checkout two"
        )
        let umbrella = RepositoryCandidate(
            id: "fixture-owner/dev",
            displayName: "dev",
            path: root + "/dev",
            rawOrigin: "ssh://git@github.com/fixture-owner/dev.git",
            presentationLocation: "~/dev"
        )
        guard ssh.canonicalOriginName == "fixture-owner/skills",
              https.canonicalOriginName == "fixture-owner/skills",
              umbrella.canonicalOriginName == "fixture-owner/dev",
              ssh.originIdentity?.transport == .ssh,
              https.originIdentity?.transport == .https,
              GitHubIdentity.parse(
                  "https://user:secret@github.com/owner/repo.git"
              ) == nil,
              GitHubIdentity.parse(
                  "https://github.com/owner/repo.git?token=secret"
              ) == nil,
              GitHubIdentity.parse("") == nil else {
            return fail("canonical parsing")
        }

        let collisions = RepositoryOperatorPresentation.collidingPaths(
            in: [ssh, https, umbrella]
        )
        let sshLabel = RepositoryOperatorPresentation.selectionLabel(
            ssh,
            collidingPaths: collisions
        )
        let httpsLabel = RepositoryOperatorPresentation.selectionLabel(
            https,
            collidingPaths: collisions
        )
        let umbrellaLabel = RepositoryOperatorPresentation.selectionLabel(
            umbrella,
            collidingPaths: collisions
        )
        guard collisions == Set([ssh.path, https.path]),
              sshLabel
                == "fixture-owner/skills — ~/dev/personal/Unicode Ω/checkout one",
              httpsLabel
                == "fixture-owner/skills — ~/dev/capabilities/path with spaces/checkout two",
              umbrellaLabel == "fixture-owner/dev — ~/dev" else {
            return fail("collision labels")
        }

        let missingLocationCandidates = ["first", "second"].map { parent in
            RepositoryCandidate(
                id: "fixture-owner/shared",
                displayName: "shared",
                path: "\(root)/\(parent)/shared",
                rawOrigin: "https://github.com/fixture-owner/shared.git"
            )
        }
        let missingLocationCollisions =
            RepositoryOperatorPresentation.collidingPaths(
                in: missingLocationCandidates
            )
        let missingLocationLabels = missingLocationCandidates.map {
            RepositoryOperatorPresentation.selectionLabel(
                $0,
                collidingPaths: missingLocationCollisions
            )
        }
        guard Set(missingLocationLabels).count
                == missingLocationCandidates.count,
              missingLocationLabels.enumerated().allSatisfy({
                  $0.element.hasPrefix("fixture-owner/shared — ")
                      && $0.element
                          .contains(missingLocationCandidates[$0.offset].path)
              }),
              RepositoryOperatorPresentation.canPresent(
                  missingLocationCandidates
              ) else {
            return fail("missing compact location collision")
        }

        let fallbackSelection = SelectionWindowController(
            candidates: missingLocationCandidates
        )
        let fallbackAccessibility =
            fallbackSelection.testingAccessibilitySnapshot
        let fallbackConfirmation = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.confirmation(
                candidates: missingLocationCandidates
            )
        )
        let fallbackRun = RunWindowController(
            candidates: missingLocationCandidates,
            role: .historicalViewer
        )
        let fallbackReport = makeReport(
            run: fallbackRun.testingRunID,
            results: missingLocationCandidates.map {
                makeResult(candidate: $0, code: .alreadyCurrent)
            }
        )
        let fallbackPresented = fallbackRun.present(
            report: fallbackReport
        )
        guard fallbackPresented,
              fallbackAccessibility.checkboxLabels.enumerated()
                .allSatisfy({
                    $0.element
                        == missingLocationLabels[$0.offset]
                            + "\nCached origin/main: Unavailable"
                }),
              zip(
                  fallbackAccessibility.checkboxHelp,
                  missingLocationCandidates
              ).allSatisfy({
                  $0.0?.contains($0.1.path) == true
              }),
              missingLocationCandidates.allSatisfy({
                  fallbackConfirmation.text.contains(
                      "fixture-owner/shared\n\($0.path)"
                  )
              }),
              fallbackRun.testingRows.allSatisfy(\.showsLocation),
              fallbackRun.testingLocationTexts
                == missingLocationCandidates.map(\.path),
              fallbackRun.testingAccessibilitySnapshot.rowLabels
                == Array(
                    repeating: "fixture-owner/shared",
                    count: missingLocationCandidates.count
                ),
              zip(
                  fallbackRun.testingAccessibilitySnapshot.rowValues,
                  missingLocationCandidates
              ).allSatisfy({
                  ($0.0 as? String)?.contains($0.1.path) == true
              }) else {
            return fail(
                "fallback surfaces "
                    + "presented=\(fallbackPresented) "
                    + "rows=\(fallbackRun.testingRows.allSatisfy(\.showsLocation)) "
                    + "locations=\(fallbackRun.testingLocationTexts == missingLocationCandidates.map(\.path)) "
                    + "checkboxes=\(String(describing: fallbackAccessibility.checkboxLabels)) "
                    + "labels=\(String(describing: fallbackRun.testingAccessibilitySnapshot.rowLabels)) "
                    + "values=\(String(describing: fallbackRun.testingAccessibilitySnapshot.rowValues))"
            )
        }

        let invalidCompact = RepositoryCandidate(
            id: "fixture-owner/shared",
            displayName: "shared",
            path: "\(root)/invalid compact/shared",
            rawOrigin: "https://github.com/fixture-owner/shared.git",
            presentationLocation: "~/dev/../invalid"
        )
        let overlongCompact = RepositoryCandidate(
            id: "fixture-owner/shared",
            displayName: "shared",
            path: "\(root)/overlong compact/shared",
            rawOrigin: "https://github.com/fixture-owner/shared.git",
            presentationLocation: "~/dev/" + String(repeating: "x", count: 1_100)
        )
        guard invalidCompact.presentationLocation == nil,
              overlongCompact.presentationLocation == nil,
              RepositoryOperatorPresentation.secondaryLocation(invalidCompact)
                == invalidCompact.path,
              RepositoryOperatorPresentation.secondaryLocation(overlongCompact)
                == overlongCompact.path,
              RepositoryOperatorPresentation.canPresent([
                  invalidCompact,
                  overlongCompact,
              ]) else {
            return fail("invalid compact fallback")
        }

        var legacyObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(missingLocationCandidates[0])
        ) as! [String: Any]
        legacyObject.removeValue(forKey: "presentationLocation")
        legacyObject.removeValue(forKey: "originIdentity")
        let legacy = try JSONDecoder().decode(
            RepositoryCandidate.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        guard legacy.presentationLocation == nil,
              legacy.originIdentity
                == missingLocationCandidates[0].originIdentity,
              RepositoryOperatorPresentation.secondaryLocation(legacy)
                == missingLocationCandidates[0].path else {
            return fail("legacy fallback")
        }
        legacyObject["presentationLocation"] = "~/dev/../unsafe"
        let invalidDecodedLocation = try JSONDecoder().decode(
            RepositoryCandidate.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        legacyObject["presentationLocation"] =
            "~/dev/" + String(repeating: "x", count: 1_100)
        let overlongDecodedLocation = try JSONDecoder().decode(
            RepositoryCandidate.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        guard invalidDecodedLocation.presentationLocation == nil,
              overlongDecodedLocation.presentationLocation == nil,
              RepositoryOperatorPresentation.secondaryLocation(
                  invalidDecodedLocation
              ) == missingLocationCandidates[0].path,
              RepositoryOperatorPresentation.secondaryLocation(
                  overlongDecodedLocation
              ) == missingLocationCandidates[0].path else {
            return fail("invalid decoded fallback")
        }

        let unsafeLocation = RepositoryCandidate(
            id: "fixture-owner/unsafe",
            displayName: "unsafe",
            path: "relative/unsafe",
            rawOrigin: "https://github.com/fixture-owner/unsafe.git"
        )
        let unsafeAlert = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.confirmation(
                candidates: [unsafeLocation]
            )
        )
        guard !RepositoryOperatorPresentation.canPresent([unsafeLocation]),
              unsafeAlert.title
                == ShadowSyncPresentation.locationAttentionTitle,
              unsafeAlert.text
                == ShadowSyncPresentation.locationAttentionText,
              unsafeAlert.buttons == [ShadowSyncPresentation.cancel] else {
            return fail("unsafe fallback refusal")
        }
        let unsafeHistorical = RunWindowController(
            candidates: [unsafeLocation],
            role: .historicalViewer
        )
        let unsafeReport = makeReport(
            run: unsafeHistorical.testingRunID,
            results: [
                makeResult(
                    candidate: unsafeLocation,
                    code: .alreadyCurrent
                ),
            ]
        )
        guard !unsafeHistorical.present(report: unsafeReport),
              unsafeHistorical.report == nil,
              unsafeHistorical.testNeedsAttention else {
            return fail("unsafe historical refusal")
        }
        let unsafeDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: [unsafeLocation]),
            root: root,
            mapping: try makeMapping(
                root: root,
                localName: "unsafe-selection-remote"
            ),
            shortcutAvailable: true
        )
        unsafeDelegate.testingTriggerShortcut()
        guard !unsafeDelegate.testSelectionIsOpen,
              unsafeDelegate.testDiscoveryPresentation?.0
                == ShadowSyncPresentation.locationAttentionTitle,
              unsafeDelegate.testDiscoveryPresentation?.1
                == ShadowSyncPresentation.locationAttentionText else {
            return fail("unsafe selection refusal")
        }

        let candidates = [ssh, https, umbrella]
        let selection = SelectionWindowController(candidates: candidates)
        let selectionLabels =
            selection.testingAccessibilitySnapshot.checkboxLabels.compactMap {
                $0
            }
        let confirmation = ShadowSyncAlertFactory.testingSnapshot(
            ShadowSyncAlertFactory.confirmation(candidates: candidates)
        )
        let controller = RunWindowController(
            candidates: candidates,
            role: .historicalViewer
        )
        let results = candidates.map {
            makeResult(candidate: $0, code: .alreadyCurrent)
        }
        let report = makeReport(
            run: controller.testingRunID,
            results: results
        )
        guard controller.present(report: report) else {
            return fail("report presentation")
        }
        let rowText = controller.testRowText
        let rowAccessibility = controller.testingAccessibilitySnapshot
        let forbidden = [
            root,
            ssh.path,
            https.path,
            umbrella.path,
            "git@github.com",
            "https://github.com",
            "secret",
        ]
        let visibleCopy = selectionLabels
            + [confirmation.text, rowText]
            + rowAccessibility.rowLabels.compactMap { $0 }
            + rowAccessibility.rowValues.compactMap { $0 as? String }
        let expectedVisibleSelectionLabels =
            [sshLabel, httpsLabel, umbrellaLabel].map {
                $0 + "\nCached origin/main: Unavailable"
            }
        guard selectionLabels == expectedVisibleSelectionLabels,
              confirmation.text.contains(
                  "fixture-owner/skills\n~/dev/personal/Unicode Ω/checkout one"
              ),
              confirmation.text.contains(
                  "fixture-owner/skills\n~/dev/capabilities/path with spaces/checkout two"
              ),
              confirmation.text.contains("fixture-owner/dev\n~/dev"),
              controller.testingRows.map(\.showsLocation)
                == [true, true, true],
              rowText.contains("fixture-owner/skills"),
              rowText.contains(ssh.presentationLocation!),
              rowText.contains(https.presentationLocation!),
              rowText.contains("fixture-owner/dev"),
              visibleCopy.allSatisfy({ text in
                  forbidden.allSatisfy { !text.contains($0) }
              }) else {
            return fail("visible copy")
        }

        let longOwner = Array(repeating: "long-owner", count: 14)
            .joined(separator: "-")
        let longRepository = Array(repeating: "long-repository", count: 14)
            .joined(separator: "-")
        let longCanonicalName = "\(longOwner)/\(longRepository)"
        let nestedLocation = String(
            repeating: "long-nested-checkout-segment/",
            count: 20
        )
        let narrowCandidates = (0..<100).map { index in
            let suffix = String(format: "%03d", index)
            return RepositoryCandidate(
                id: longCanonicalName,
                displayName: "misleading-\(suffix)",
                path:
                    "\(root)/fallback path Ω/\(nestedLocation)checkout-\(suffix)",
                rawOrigin:
                    "https://github.com/\(longOwner)/\(longRepository).git",
                presentationLocation: "~/dev/"
                    + String(repeating: "overlong/", count: 150)
            )
        }
        let narrowLocations = narrowCandidates.compactMap(
            RepositoryOperatorPresentation.secondaryLocation
        )
        let narrowSelection = SelectionWindowController(
            candidates: narrowCandidates
        )
        guard let selectionWindow = narrowSelection.window,
              let selectionContent = selectionWindow.contentView else {
            return fail("narrow selection window")
        }
        narrowSelection.showWindow(nil)
        selectionWindow.layoutIfNeeded()
        let selectionInitialWidth = selectionWindow.frame.width
        descendants(of: NSTextField.self, in: selectionContent).forEach {
            $0.font = .systemFont(ofSize: 24)
        }
        descendants(of: NSButton.self, in: selectionContent).forEach {
            $0.font = .systemFont(ofSize: 24)
        }
        settleAtMinimumSize(selectionWindow)
        let selectionScrollViews = descendants(
            of: NSScrollView.self,
            in: selectionContent
        )
        let expectedSelectionLabels = narrowLocations.map {
            "\(longCanonicalName) — \($0)"
                + "\nCached origin/main: Unavailable"
        }
        let selectionCheckboxes = descendants(
            of: NSButton.self,
            in: selectionContent
        ).filter { expectedSelectionLabels.contains($0.title) }
        let selectionControls = descendants(
            of: NSButton.self,
            in: selectionContent
        ).filter { !expectedSelectionLabels.contains($0.title) }
        selectionWindow.appearance = NSAppearance(
            named: .accessibilityHighContrastDarkAqua
        )
        let selectionControlContainment = selectionControls.map {
            isContained($0, in: selectionContent)
        }
        let selectionAppearance = selectionWindow.appearance?.name
        let selectionAmbiguousDescriptions =
            ambiguousLayoutDescriptions(selectionContent)
        guard selectionInitialWidth == 680,
              selectionWindow.styleMask.contains(.resizable),
              selectionWindow.minSize.width == 560,
              abs(selectionWindow.frame.width - 560) < 1,
              selectionWindow.frame.width < 1_805,
              !hasAmbiguousLayout(selectionContent),
              selectionControls.allSatisfy({
                  !$0.isHidden && isContained($0, in: selectionContent)
              }),
              selectionAppearance == .darkAqua else {
            return fail(
                "narrow selection sizing "
                    + "initial=\(selectionInitialWidth) "
                    + "frame=\(selectionWindow.frame.width) "
                    + "minimum=\(selectionWindow.minSize.width) "
                    + "resizable=\(selectionWindow.styleMask.contains(.resizable)) "
                    + "ambiguous=\(hasAmbiguousLayout(selectionContent)) "
                    + "ambiguousViews=\(selectionAmbiguousDescriptions) "
                    + "controls=\(selectionControlContainment) "
                    + "appearance=\(String(describing: selectionAppearance))"
            )
        }
        guard selectionScrollViews.count == 1,
              let selectionScrollView = selectionScrollViews.first else {
            return fail("narrow selection scroll view")
        }
        guard
              selectionScrollView.hasVerticalScroller,
              !selectionScrollView.hasHorizontalScroller,
              selectionScrollView.documentView?.frame.height
                ?? 0 > selectionScrollView.contentView.bounds.height else {
            return fail("narrow selection scrolling")
        }
        guard selectionCheckboxes.map(\.title) == expectedSelectionLabels else {
            return fail("narrow selection labels")
        }
        guard
              selectionCheckboxes.allSatisfy({
                  guard let font = $0.font else {
                      return false
                  }
                  return $0.lineBreakMode == .byWordWrapping
                      && $0.frame.width
                          <= selectionScrollView.contentView.bounds.width
                      && $0.frame.height
                          > font.boundingRectForFont.height * 1.5
              }) else {
            return fail("narrow selection wrapping")
        }
        selectionWindow.setFrame(
            NSRect(
                origin: selectionWindow.frame.origin,
                size: NSSize(width: 920, height: 560)
            ),
            display: false
        )
        selectionWindow.layoutIfNeeded()
        guard abs(selectionWindow.frame.width - 920) < 1,
              !hasAmbiguousLayout(selectionContent),
              selectionControls.allSatisfy({
                  isContained($0, in: selectionContent)
              }) else {
            return fail("large selection resize")
        }
        let selectionLargeWidth = selectionWindow.frame.width
        selectionWindow.orderOut(nil)

        let longConfirmation =
            ShadowSyncAlertFactory.confirmation(
                candidates: Array(narrowCandidates.prefix(2))
            )
        let confirmationWindow = longConfirmation.window
        confirmationWindow.layoutIfNeeded()
        confirmationWindow.contentView?.layoutSubtreeIfNeeded()
        let confirmationButtons = longConfirmation.buttons
        guard confirmationWindow.frame.width < 1_805,
              confirmationButtons.allSatisfy({
                  guard let content = confirmationWindow.contentView else {
                      return false
                  }
                  return isContained($0, in: content)
              }),
              longConfirmation.informativeText.contains(longCanonicalName),
              narrowLocations.prefix(2).allSatisfy({
                  longConfirmation.informativeText.contains($0)
              }) else {
            return fail(
                "confirmation layout width=\(confirmationWindow.frame.width)"
            )
        }
        let confirmationWidth = confirmationWindow.frame.width

        let narrowRun = RunWindowController(
            candidates: narrowCandidates,
            role: .historicalViewer
        )
        let narrowReport = makeReport(
            run: narrowRun.testingRunID,
            cancelled: true,
            results: narrowCandidates.enumerated().map { index, candidate in
                let code: ResultCode
                switch index % 3 {
                case 0:
                    code = .failedInspection
                case 1:
                    code = .cancelledPending
                default:
                    code = .updatedBeforeCancellation
                }
                return makeResult(candidate: candidate, code: code)
            }
        )
        guard narrowRun.present(report: narrowReport),
              let runWindow = narrowRun.window,
              let runContent = runWindow.contentView else {
            return fail("narrow report window")
        }
        narrowRun.showWindow(nil)
        runWindow.layoutIfNeeded()
        let runInitialWidth = runWindow.frame.width
        descendants(of: NSTextField.self, in: runContent).forEach {
            $0.font = .systemFont(ofSize: 24)
        }
        settleAtMinimumSize(runWindow)
        let runScrollViews = descendants(
            of: NSScrollView.self,
            in: runContent
        )
        let runRows = descendants(of: RunRowView.self, in: runContent)
        let runFields = descendants(of: NSTextField.self, in: runContent)
        let originFields = runFields.filter {
            $0.stringValue == longCanonicalName
        }
        let locationFields = runFields.filter {
            narrowLocations.contains($0.stringValue)
        }
        let runControls = descendants(
            of: NSButton.self,
            in: runContent
        ).filter { ![""].contains($0.title) }
        runWindow.appearance = NSAppearance(
            named: .accessibilityHighContrastDarkAqua
        )
        let runOriginMultiline = originFields.map(isActuallyMultiline)
        let runLocationMultiline = locationFields.map(isActuallyMultiline)
        let runControlContainment = runControls.filter {
            !$0.isHidden
        }.map {
            isContained($0, in: runContent)
        }
        let runAmbiguousDescriptions =
            ambiguousLayoutDescriptions(runContent)
        let runAppearanceDescription = String(
            describing: runWindow.appearance?.name
        )
        guard runInitialWidth == 760,
              runWindow.styleMask.contains(.resizable),
              runWindow.minSize.width == 620,
              abs(runWindow.frame.width - 620) < 1,
              runWindow.frame.width < 1_805,
              runScrollViews.count == 1,
              let runScrollView = runScrollViews.first,
              runScrollView.hasVerticalScroller,
              !runScrollView.hasHorizontalScroller,
              runScrollView.documentView?.frame.height
                ?? 0 > runScrollView.contentView.bounds.height,
              runRows.map(\.testingIdentityText)
                == Array(
                    repeating: longCanonicalName,
                    count: narrowCandidates.count
                ),
              runRows.map(\.testingPathText) == narrowLocations,
              runRows.allSatisfy(\.testingSupportsWrapping),
              originFields.count == narrowCandidates.count,
              originFields.allSatisfy(isActuallyMultiline),
              locationFields.count == narrowCandidates.count,
              locationFields.allSatisfy(isActuallyMultiline),
              !hasAmbiguousLayout(runContent),
              runControls.filter({ !$0.isHidden }).allSatisfy({
                  isContained($0, in: runContent)
              }),
              runWindow.appearance?.name == .darkAqua,
              narrowRun.testingAccessibilitySnapshot.rowLabels
                == Array(
                    repeating: longCanonicalName,
                    count: narrowCandidates.count
                ) else {
            return fail(
                "narrow report layout "
                    + "initial=\(runInitialWidth) "
                    + "frame=\(runWindow.frame.width) "
                    + "ambiguous=\(runAmbiguousDescriptions) "
                    + "rows=\(runRows.count) "
                    + "origins=\(runOriginMultiline) "
                    + "locations=\(runLocationMultiline) "
                    + "controls=\(runControlContainment) "
                    + "appearance=\(runAppearanceDescription)"
            )
        }
        runWindow.setFrame(
            NSRect(
                origin: runWindow.frame.origin,
                size: NSSize(width: 1_080, height: 700)
            ),
            display: false
        )
        runWindow.layoutIfNeeded()
        guard abs(runWindow.frame.width - 1_080) < 1,
              !hasAmbiguousLayout(runContent),
              runControls.filter({ !$0.isHidden }).allSatisfy({
                  isContained($0, in: runContent)
              }) else {
            return fail("large report resize")
        }
        let runLargeWidth = runWindow.frame.width
        fputs(
            "M5 layout evidence: "
                + "selection-initial=\(selectionInitialWidth) "
                + "selection-minimum=560.0 "
                + "selection-large=\(selectionLargeWidth) "
                + "confirmation=\(confirmationWidth) "
                + "report-initial=\(runInitialWidth) "
                + "report-minimum=620.0 "
                + "report-large=\(runLargeWidth)\n",
            stderr
        )
        runWindow.orderOut(nil)

        var reducer = RunPresentationReducer(
            runID: report.run,
            candidates: candidates
        )
        let before = reducer
        let drifted = RepositoryCandidate(
            id: "other-owner/other-repository",
            displayName: ssh.displayName,
            path: ssh.path,
            rawOrigin: "https://github.com/other-owner/other-repository.git",
            presentationLocation: ssh.presentationLocation
        )
        let driftedReport = makeReport(
            run: report.run,
            results: [
                makeResult(candidate: drifted, code: .alreadyCurrent),
                results[1],
                results[2],
            ]
        )
        do {
            _ = try reducer.apply(
                report: driftedReport,
                policy: .historicalOrRecovery
            )
            return fail("origin drift accepted")
        } catch {
            guard reducer == before else {
                return fail("origin drift mutated reducer")
            }
        }

        let locationDrifted = RepositoryCandidate(
            id: ssh.id,
            displayName: ssh.displayName,
            path: ssh.path,
            rawOrigin: ssh.rawOrigin,
            presentationLocation: "~/dev/other-checkout"
        )
        let locationDriftedReport = makeReport(
            run: report.run,
            results: [
                makeResult(candidate: locationDrifted, code: .alreadyCurrent),
                results[1],
                results[2],
            ]
        )
        do {
            _ = try reducer.apply(
                report: locationDriftedReport,
                policy: .historicalOrRecovery
            )
            return fail("location drift accepted")
        } catch {
            guard reducer == before else {
                return fail("location drift mutated reducer")
            }
        }

        let encoded = try JSONEncoder().encode(ssh)
        var object = try JSONSerialization.jsonObject(with: encoded)
            as! [String: Any]
        var identity = object["originIdentity"] as! [String: Any]
        identity["owner"] = "other-owner"
        object["originIdentity"] = identity
        let tampered = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try JSONDecoder().decode(
                RepositoryCandidate.self,
                from: tampered
            )
            return fail("serialized identity drift accepted")
        } catch {
            // Expected: serialized trusted identity must match raw origin.
        }

        let invalid = RepositoryCandidate(
            id: "invalid",
            displayName: ssh.path,
            path: ssh.path,
            rawOrigin: "https://github.com/owner/repo.git?credential=secret",
            presentationLocation: "~/dev/personal/invalid"
        )
        guard invalid.originIdentity == nil,
              RepositoryOperatorPresentation.primaryName(invalid)
                == "Local repository",
              !RepositoryOperatorPresentation.primaryName(invalid).contains(
                  ssh.path
              ) else {
            return fail("invalid origin fallback")
        }
        do {
            _ = try JSONDecoder().decode(
                RepositoryCandidate.self,
                from: JSONEncoder().encode(invalid)
            )
            return fail("invalid serialized origin accepted")
        } catch {
            // Expected: invalid origins cannot cross a process/log boundary.
        }
        return true
    }

    private static func testOperationContentionLifecycle(
        root: String
    ) throws -> Bool {
        final class Counter {
            var value = 0
        }
        func fail(_ stage: String) -> Bool {
            fputs("M5 operation contention failure: \(stage)\n", stderr)
            return false
        }
        func makeRoot(_ label: String) throws -> String {
            let path = root + "/operation-contention-\(label)-\(RunIdentity.make())"
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try TestIsolation.initializeState(at: StateLocation.isolated(root: path))
            return path
        }
        func delegate(
            root: String,
            discovery: M5CountingDiscovery,
            onQuit: @escaping () -> Void = {}
        ) throws -> ShadowSyncAppDelegate {
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0],
                discovery: discovery,
                testingRoot: root,
                testingMapping: try makeMapping(root: root),
                testingConfirmation: { .alertFirstButtonReturn },
                testingLogOpener: { _ in true },
                testingShortcutAvailable: true,
                testingQuitHandler: onQuit
            )
        }

        let candidates = makeCandidates(
            count: 2,
            root: root + "/operation-contention-rows"
        )

        let transientRoot = try makeRoot("transient")
        let transientDiscovery = M5CountingDiscovery(candidates: candidates)
        let transient = try delegate(
            root: transientRoot,
            discovery: transientDiscovery
        )
        let transientLocation = try StateLocation.isolated(root: transientRoot)
        var transientAuthority: RunAuthority? = try RunAuthority.acquireRun(
            at: transientLocation
        )
        defer { transientAuthority?.release() }
        transient.testingTriggerMenuStart()
        guard transient.testOperationContentionHasPendingRetry,
              !transient.testOperationContentionIsVisible,
              transient.testOperationContentionRevalidationScheduled,
              transient.testOperationContentionPresentationCount == 0,
              transientDiscovery.invocationCount == 0 else {
            return fail("transient request")
        }
        transientAuthority?.release()
        transientAuthority = nil
        transient.testingFireOperationContentionRevalidation()
        guard !transient.testOperationContentionHasPendingRetry,
              !transient.testOperationContentionIsVisible,
              !transient.testOperationContentionRevalidationScheduled,
              transient.testOperationContentionPresentationCount == 0,
              transient.testOperationContentionResumeCount == 1,
              transientDiscovery.invocationCount == 1,
              transient.testSelectionIsOpen else {
            return fail("transient release before presentation")
        }
        transient.testingFireOperationContentionRevalidation()
        guard transient.testOperationContentionResumeCount == 1,
              transientDiscovery.invocationCount == 1 else {
            return fail("transient stale callback")
        }

        let transientQuitRoot = try makeRoot("transient-quit")
        let transientQuitCount = Counter()
        let transientQuitDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let transientQuit = try delegate(
            root: transientQuitRoot,
            discovery: transientQuitDiscovery,
            onQuit: { transientQuitCount.value += 1 }
        )
        let transientQuitLocation = try StateLocation.isolated(
            root: transientQuitRoot
        )
        var transientQuitAuthority: RunAuthority? =
            try RunAuthority.acquireRun(at: transientQuitLocation)
        defer { transientQuitAuthority?.release() }
        transientQuit.testQuitUtility()
        guard transientQuit.testOperationContentionHasPendingRetry,
              !transientQuit.testOperationContentionIsVisible,
              transientQuit.testOperationContentionRevalidationScheduled,
              transientQuit.testOperationContentionPresentationCount == 0,
              transientQuit.testOperationContentionResumeCount == 0,
              transientQuitCount.value == 0 else {
            return fail("transient quit request")
        }
        transientQuitAuthority?.release()
        transientQuitAuthority = nil
        transientQuit.testingFireOperationContentionRevalidation()
        transientQuit.testingFireOperationContentionRevalidation()
        guard !transientQuit.testOperationContentionHasPendingRetry,
              !transientQuit.testOperationContentionIsVisible,
              !transientQuit.testOperationContentionRevalidationScheduled,
              transientQuit.testOperationContentionPresentationCount == 0,
              transientQuit.testOperationContentionResumeCount == 1,
              transientQuitCount.value == 1,
              transientQuitDiscovery.invocationCount == 0 else {
            return fail("transient quit single resume")
        }

        let visibleQuitRoot = try makeRoot("visible-quit")
        let visibleQuitCount = Counter()
        let visibleQuitDiscovery = M5CountingDiscovery(candidates: candidates)
        let visibleQuit = try delegate(
            root: visibleQuitRoot,
            discovery: visibleQuitDiscovery,
            onQuit: { visibleQuitCount.value += 1 }
        )
        let visibleQuitLocation = try StateLocation.isolated(
            root: visibleQuitRoot
        )
        var visibleQuitAuthority: RunAuthority? =
            try RunAuthority.acquireRun(at: visibleQuitLocation)
        defer { visibleQuitAuthority?.release() }
        visibleQuit.testQuitUtility()
        visibleQuit.testingFireOperationContentionRevalidation()
        visibleQuit.testQuitUtility()
        visibleQuit.testQuitUtility()
        visibleQuit.testingFireOperationContentionRevalidation()
        guard visibleQuit.testOperationContentionHasPendingRetry,
              visibleQuit.testOperationContentionIsVisible,
              visibleQuit.testOperationContentionRevalidationScheduled,
              visibleQuit.testOperationContentionPresentationCount == 1,
              visibleQuit.testOperationContentionDismissalCount == 0,
              visibleQuit.testOperationContentionResumeCount == 0,
              visibleQuitCount.value == 0 else {
            return fail("visible quit coalescing")
        }
        visibleQuitAuthority?.release()
        visibleQuitAuthority = nil
        visibleQuit.testingFireOperationContentionRevalidation()
        visibleQuit.testingFireOperationContentionRevalidation()
        guard !visibleQuit.testOperationContentionHasPendingRetry,
              !visibleQuit.testOperationContentionIsVisible,
              !visibleQuit.testOperationContentionRevalidationScheduled,
              visibleQuit.testOperationContentionPresentationCount == 1,
              visibleQuit.testOperationContentionDismissalCount == 1,
              visibleQuit.testOperationContentionResumeCount == 1,
              visibleQuitCount.value == 1,
              visibleQuitDiscovery.invocationCount == 0 else {
            return fail("visible quit single resume")
        }

        let cancelledQuitRoot = try makeRoot("cancelled-quit")
        let cancelledQuitCount = Counter()
        let cancelledQuitDiscovery = M5CountingDiscovery(
            candidates: candidates
        )
        let cancelledQuit = try delegate(
            root: cancelledQuitRoot,
            discovery: cancelledQuitDiscovery,
            onQuit: { cancelledQuitCount.value += 1 }
        )
        let cancelledQuitLocation = try StateLocation.isolated(
            root: cancelledQuitRoot
        )
        var cancelledQuitAuthority: RunAuthority? =
            try RunAuthority.acquireRun(at: cancelledQuitLocation)
        defer { cancelledQuitAuthority?.release() }
        cancelledQuit.testQuitUtility()
        cancelledQuit.testQuitUtility()
        cancelledQuit.testingFireOperationContentionRevalidation()
        cancelledQuit.testQuitUtility()
        guard let staleCancelledQuitRevalidation =
                cancelledQuit.testOperationContentionRevalidationIdentity else {
            return fail("manual quit stale identity")
        }
        cancelledQuit.testingCloseOperationContentionPresentation()
        guard cancelledQuit.testOperationContentionHasPendingRetry,
              !cancelledQuit.testOperationContentionIsVisible,
              cancelledQuit.testOperationContentionRevalidationScheduled,
              cancelledQuit.testOperationContentionPresentationCount == 1,
              cancelledQuit.testOperationContentionDismissalCount == 0,
              cancelledQuit.testOperationContentionResumeCount == 0,
              cancelledQuitCount.value == 0 else {
            return fail("manual close dropped queued quit")
        }
        cancelledQuit.testingTriggerMenuStart()
        cancelledQuit.testingFireOperationContentionRevalidation()
        guard cancelledQuit.testOperationContentionHasPendingRetry,
              !cancelledQuit.testOperationContentionIsVisible,
              cancelledQuit.testOperationContentionRevalidationScheduled,
              cancelledQuit.testOperationContentionPresentationCount == 1,
              cancelledQuit.testOperationContentionResumeCount == 0,
              cancelledQuitCount.value == 0 else {
            return fail("manual close re-presented held quit")
        }
        cancelledQuitAuthority?.release()
        cancelledQuitAuthority = nil
        cancelledQuit.testingFireOperationContentionRevalidation(
            token: staleCancelledQuitRevalidation.token,
            generation: staleCancelledQuitRevalidation.generation
        )
        cancelledQuit.testingFireOperationContentionRevalidation()
        guard !cancelledQuit.testOperationContentionHasPendingRetry,
              !cancelledQuit.testOperationContentionIsVisible,
              !cancelledQuit.testOperationContentionRevalidationScheduled,
              cancelledQuit.testOperationContentionPresentationCount == 1,
              cancelledQuit.testOperationContentionResumeCount == 1,
              cancelledQuitCount.value == 1,
              cancelledQuitDiscovery.invocationCount == 0 else {
            return fail("closed quit did not resume once after release")
        }

        let persistentRoot = try makeRoot("persistent")
        let persistentDiscovery = M5CountingDiscovery(candidates: candidates)
        let persistent = try delegate(
            root: persistentRoot,
            discovery: persistentDiscovery
        )
        let persistentLocation = try StateLocation.isolated(root: persistentRoot)
        var persistentAuthority: RunAuthority? = try RunAuthority.acquireRun(
            at: persistentLocation
        )
        defer { persistentAuthority?.release() }
        persistent.testLoadRecoveryPresentation()
        persistent.testingFireOperationContentionRevalidation()
        guard persistent.testOperationContentionHasPendingRetry,
              persistent.testOperationContentionIsVisible,
              persistent.testOperationContentionRevalidationScheduled,
              persistent.testOperationContentionPresentationCount == 1,
              persistent.testOperationContentionResumeCount == 0,
              persistentDiscovery.invocationCount == 0,
              let presentation = persistent.testOperationContentionPresentation,
              presentation.0
                == InterruptedRunReconstructor.operationContentionTitle,
              presentation.1.contains(
                InterruptedRunReconstructor.operationContentionMessage
              ),
              presentation.1.contains(
                InterruptedRunReconstructor.operationContentionRecovery
              ),
              !presentation.0.lowercased().contains("git"),
              !presentation.1.lowercased().contains("git"),
              !presentation.1.lowercased().contains("restart") else {
            return fail("persistent generic presentation")
        }

        persistent.testingTriggerShortcut()
        persistent.testingTriggerStatusActivation()
        persistent.testingTriggerAppReopen()
        persistent.handleDuplicateActivation()
        persistent.testingTriggerMenuStart()
        persistent.testingFireOperationContentionRevalidation()
        guard persistent.testOperationContentionHasPendingRetry,
              persistent.testOperationContentionIsVisible,
              persistent.testOperationContentionRevalidationScheduled,
              persistent.testOperationContentionPresentationCount == 1,
              persistent.testOperationContentionDismissalCount == 0,
              persistent.testOperationContentionResumeCount == 0,
              persistentDiscovery.invocationCount == 0,
              !persistent.testSelectionIsOpen,
              RunRecoveryInspector.inspect(at: persistentLocation)
                == .operationStillActive else {
            return fail("persistent repeated entry coalescing")
        }
        var competingRunWasRejected = false
        do {
            let unexpected = try RunAuthority.acquireRun(at: persistentLocation)
            unexpected.release()
        } catch let SecureStateError.contention(name) {
            competingRunWasRejected =
                name == "operation.lock" || name == "run.lock"
        } catch {
            return fail("persistent lock refusal classification")
        }
        guard competingRunWasRejected else {
            return fail("persistent lock enforcement")
        }

        persistentAuthority?.release()
        persistentAuthority = nil
        persistent.testingFireOperationContentionRevalidation()
        guard !persistent.testOperationContentionHasPendingRetry,
              !persistent.testOperationContentionIsVisible,
              !persistent.testOperationContentionRevalidationScheduled,
              persistent.testOperationContentionPresentationCount == 1,
              persistent.testOperationContentionDismissalCount == 1,
              persistent.testOperationContentionResumeCount == 1,
              persistentDiscovery.invocationCount == 1,
              persistent.testSelectionIsOpen else {
            return fail("visible release and single resume")
        }
        persistent.testingFireOperationContentionRevalidation()
        guard persistent.testOperationContentionResumeCount == 1,
              persistentDiscovery.invocationCount == 1 else {
            return fail("visible stale callback")
        }
        return true
    }

    private static func testBody3CorrectiveSessionOwnership(
        root: String
    ) throws -> Bool {
        func fixture(
            run: String = RunIdentity.make()
        ) throws -> (
            plan: Body3BatchPlan,
            report: Body3BatchReport,
            recovered: Body3RecoveredRun
        ) {
            let node = try Body3BatchNode(
                id:
                    "body3-node:policyInvalidation:"
                    + String(run.prefix(12)),
                repositoryID: "fixture/body3-session",
                commonDirectoryKey: "clone:body3-session",
                kind: .policyInvalidation,
                dependencies: [],
                payload: .policyInvalidation(
                    repositoryID:
                        "fixture/body3-session"
                ),
                requiresExclusiveWorkerPool: true
            )
            let start = WallClock.timestamp(
                Date(timeIntervalSince1970: 1_800_000_100)
            )
            let end = WallClock.timestamp(
                Date(timeIntervalSince1970: 1_800_000_101)
            )
            let plan = try Body3BatchPlan(
                run: run,
                createdAt: start,
                policyEvidenceDigest:
                    String(repeating: "a", count: 64),
                nodes: [node]
            )
            let report = try Body3BatchReport(
                run: run,
                startedAt: start,
                endedAt: end,
                cancelled: false,
                results: [
                    Body3BatchNodeResult(
                        node: node,
                        status: .succeeded,
                        worker: 1,
                        startedAt: start,
                        endedAt: end,
                        durationMilliseconds: 1_000,
                        detail: "Session fixture completed."
                    ),
                ]
            )
            return (
                plan,
                report,
                Body3RecoveredRun(
                    plan: plan,
                    report: report,
                    records: []
                )
            )
        }
        func delegate(
            label: String,
            discovery: M5CountingDiscovery
        ) throws -> ShadowSyncAppDelegate {
            let isolated = root + "/body3-session-\(label)"
            try FileManager.default.createDirectory(
                atPath: isolated,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try TestIsolation.initializeState(at: StateLocation.isolated(root: isolated))
            return ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0],
                discovery: discovery,
                testingRoot: isolated,
                testingMapping: try makeMapping(
                    root: isolated,
                    localName: "mapping"
                ),
                testingConfirmation: {
                    .alertFirstButtonReturn
                },
                testingLogOpener: { _ in true },
                testingShortcutAvailable: true,
                testingQuitHandler: {}
            )
        }
        let candidates = makeCandidates(
            count: 1,
            root: root + "/body3-session-candidates"
        )
        let terminalFixture = try fixture()
        let terminalController = Body3RunWindowController(
            plan: terminalFixture.plan
        )
        terminalController.finish(terminalFixture.report)
        let terminalDiscovery =
            M5CountingDiscovery(candidates: candidates)
        let terminalDelegate = try delegate(
            label: "terminal",
            discovery: terminalDiscovery
        )
        terminalDelegate.testingSetBody3Progress(
            terminalController
        )
        terminalDelegate.testingTriggerMenuStart()
        let terminalOpensChooser =
            terminalDelegate.testingBody3Progress == nil
                && terminalDelegate.testSelectionIsOpen
                && terminalDiscovery.invocationCount == 1

        let coexistFixture = try fixture()
        let coexistController = Body3RunWindowController(
            plan: coexistFixture.plan
        )
        coexistController.finish(coexistFixture.report)
        let coexistDiscovery =
            M5CountingDiscovery(candidates: candidates)
        let coexistDelegate = try delegate(
            label: "terminal-with-history",
            discovery: coexistDiscovery
        )
        coexistDelegate.testingSetBody3Progress(
            coexistController
        )
        coexistDelegate.testingSetLastBody3Recovered(
            coexistFixture.recovered
        )
        coexistDelegate.testingShowLastBody3Report()
        guard coexistDelegate.testingHistoricalBody3Viewer
                != nil else {
            return false
        }
        coexistDelegate.testingTriggerMenuStart()
        let terminalAndHistoryOpenChooser =
            coexistDelegate.testingBody3Progress == nil
                && coexistDelegate
                    .testingHistoricalBody3Viewer == nil
                && coexistDelegate.testSelectionIsOpen
                && coexistDiscovery.invocationCount == 1

        let activeFixture = try fixture()
        let activeController = Body3RunWindowController(
            plan: activeFixture.plan
        )
        let activeDiscovery =
            M5CountingDiscovery(candidates: candidates)
        let activeDelegate = try delegate(
            label: "active",
            discovery: activeDiscovery
        )
        activeDelegate.testingSetBody3Progress(
            activeController
        )
        activeDelegate.testingTriggerMenuStart()
        let activeStillBlocks =
            activeDelegate.testingBody3Progress
                === activeController
                && !activeDelegate.testSelectionIsOpen
                && activeDiscovery.invocationCount == 0

        let unsettledFixture = try fixture()
        let unsettledController =
            Body3RunWindowController(
                plan: unsettledFixture.plan
            )
        unsettledController.fail(
            "Synthetic unsettled report."
        )
        let unsettledDiscovery =
            M5CountingDiscovery(candidates: candidates)
        let unsettledDelegate = try delegate(
            label: "unsettled",
            discovery: unsettledDiscovery
        )
        unsettledDelegate.testingSetBody3Progress(
            unsettledController
        )
        unsettledDelegate.testingTriggerMenuStart()
        let unsettledStillBlocks =
            unsettledDelegate.testingBody3Progress
                === unsettledController
                && !unsettledDelegate.testSelectionIsOpen
                && unsettledDiscovery.invocationCount == 0

        let historyFixture = try fixture()
        let historyActive = Body3RunWindowController(
            plan: historyFixture.plan
        )
        let historyDelegate = try delegate(
            label: "history",
            discovery:
                M5CountingDiscovery(candidates: candidates)
        )
        historyDelegate.testingSetBody3Progress(
            historyActive
        )
        historyDelegate.testingSetLastBody3Recovered(
            historyFixture.recovered
        )
        historyDelegate.testingShowLastBody3Report()
        guard let historical =
                historyDelegate
                    .testingHistoricalBody3Viewer else {
            return false
        }
        let independentHistory =
            historical !== historyActive
                && historyDelegate.testingBody3Progress
                    === historyActive
                && historical.window?.title
                    == ShadowSyncPresentation
                        .historicalBatchTitle
                && historyDelegate
                    .testingAcknowledgedBody3Run == nil
        historical.testingCloseTerminalPresentation()
        let historicalCloseIsReadOnly =
            historyDelegate
                .testingHistoricalBody3Viewer == nil
                && historyDelegate.testingBody3Progress
                    === historyActive
                && historyDelegate
                    .testingAcknowledgedBody3Run == nil

        let malformedFixture = try fixture()
        let malformedReport = try Body3BatchReport(
            run: malformedFixture.plan.run,
            startedAt:
                "2027-01-15T08:00:02.000Z",
            endedAt:
                "2027-01-15T08:00:01.000Z",
            cancelled: false,
            results: malformedFixture.report.results
        )
        let malformedDelegate = try delegate(
            label: "malformed",
            discovery:
                M5CountingDiscovery(candidates: candidates)
        )
        malformedDelegate.testingSetLastBody3Recovered(
            Body3RecoveredRun(
                plan: malformedFixture.plan,
                report: malformedReport,
                records: []
            )
        )
        malformedDelegate.testingShowLastBody3Report()
        let malformedRefused =
            malformedDelegate
                .testingHistoricalBody3Viewer == nil

        return terminalOpensChooser
            && terminalAndHistoryOpenChooser
            && activeStillBlocks
            && unsettledStillBlocks
            && independentHistory
            && historicalCloseIsReadOnly
            && malformedRefused
    }

    private static func testHistoricalViewerLifecycleIsolation(
        root: String
    ) throws -> Bool {
        final class Counter {
            var value = 0
        }
        func fail(_ stage: String) -> Bool {
            fputs("M5 historical viewer failure: \(stage)\n", stderr)
            return false
        }
        func makeRoot(_ label: String) throws -> String {
            let path = root + "/historical-\(label)-\(RunIdentity.make())"
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try TestIsolation.initializeState(at: StateLocation.isolated(root: path))
            return path
        }
        func delegate(
            root: String,
            discovery: M5CountingDiscovery,
            quitCount: Counter
        ) throws -> ShadowSyncAppDelegate {
            ShadowSyncAppDelegate(
                executablePath: CommandLine.arguments[0],
                discovery: discovery,
                testingRoot: root,
                testingMapping: try makeMapping(
                    root: root,
                    localName: "mapping"
                ),
                testingConfirmation: { .alertFirstButtonReturn },
                testingLogOpener: { _ in true },
                testingShortcutAvailable: true,
                testingQuitHandler: { quitCount.value += 1 }
            )
        }
        let candidates = makeCandidates(
            count: 2,
            root: root + "/historical-rows"
        )
        let valid = makeReport(
            run: RunIdentity.make(),
            results: candidates.map {
                makeResult(candidate: $0, code: .alreadyCurrent)
            }
        )
        let invalid = RunReport(
            run: valid.run,
            startedAt: valid.startedAt,
            endedAt: valid.endedAt,
            durationMilliseconds: -1,
            cancelled: valid.cancelled,
            results: valid.results
        )

        let cleanRoot = try makeRoot("clean")
        let cleanDiscovery = M5CountingDiscovery(candidates: candidates)
        let cleanQuit = Counter()
        let clean = try delegate(
            root: cleanRoot,
            discovery: cleanDiscovery,
            quitCount: cleanQuit
        )
        clean.testingSetLastReport(valid)
        clean.testingShowLastReport()
        guard clean.testingRunControllerIdentity == nil,
              let cleanViewer = clean.testingHistoricalViewerIdentity,
              clean.testingHistoricalViewerHasNoLifecycleEvidence,
              clean.testingHistoricalViewerStopCount == 0 else {
            return fail("clean open")
        }
        clean.testingShowLastReport()
        guard clean.testingHistoricalViewerIdentity == cleanViewer else {
            return fail("clean repeated open")
        }
        clean.testingHideHistoricalWindow()
        clean.testingTriggerShortcut()
        guard clean.testingHistoricalViewerIdentity == cleanViewer,
              clean.testingHistoricalWindowIsVisible,
              cleanDiscovery.invocationCount == 0,
              clean.testSelectionIsOpen == false else {
            return fail("hidden shortcut activation")
        }
        clean.testingMiniaturizeHistoricalWindow()
        clean.testingTriggerStatusActivation()
        guard clean.testingHistoricalViewerIdentity == cleanViewer,
              clean.testingHistoricalWindowIsVisible,
              !clean.testingHistoricalWindowIsMiniaturized,
              cleanDiscovery.invocationCount == 0 else {
            return fail("miniaturized status activation")
        }
        clean.testingTriggerAppReopen()
        clean.handleDuplicateActivation()
        guard clean.testingHistoricalViewerIdentity == cleanViewer,
              cleanDiscovery.invocationCount == 0,
              clean.testDuplicateActivationCount == 1 else {
            return fail("repeated ambient activation")
        }
        clean.testQuitUtility()
        guard cleanQuit.value == 1,
              clean.testingHistoricalViewerHasNoLifecycleEvidence else {
            return fail("clean quit")
        }
        clean.testingTriggerMenuStart()
        guard clean.testingRunControllerIdentity == nil,
              clean.testingHistoricalViewerIdentity == nil,
              clean.testSelectionIsOpen,
              cleanDiscovery.invocationCount == 1,
              clean.testingHistoricalViewerStopCount == 0 else {
            return fail("clean start")
        }

        let changedRoot = try makeRoot("changed")
        let changedDiscovery = M5CountingDiscovery(candidates: candidates)
        let changedQuit = Counter()
        let changed = try delegate(
            root: changedRoot,
            discovery: changedDiscovery,
            quitCount: changedQuit
        )
        changed.testingSetLastReport(valid)
        changed.testingShowLastReport()
        guard changed.testingHistoricalViewerHasNoLifecycleEvidence else {
            return fail("changed open")
        }
        let heldLocation = try StateLocation.isolated(root: changedRoot)
        let heldAuthority = try RunAuthority.acquireRun(at: heldLocation)
        changed.testingTriggerMenuStart()
        changed.testingFireOperationContentionRevalidation()
        changed.testQuitUtility()
        guard changed.testingRunControllerIdentity == nil,
              changed.testSelectionIsOpen == false,
              changedDiscovery.invocationCount == 0,
              changedQuit.value == 0,
              changed.testOperationContentionPresentation?.0
                == InterruptedRunReconstructor.operationContentionTitle,
              changed.testingHistoricalViewerIdentity == nil,
              changed.testingHistoricalViewerStopCount == 0 else {
            heldAuthority.release()
            return fail("changed held")
        }
        heldAuthority.release()
        changed.testingFireOperationContentionRevalidation()
        guard changedQuit.value == 1,
              changed.testOperationContentionResumeCount == 1,
              changedDiscovery.invocationCount == 0,
              !changed.testOperationContentionHasPendingRetry else {
            return fail("changed release")
        }
        changed.testingTriggerMenuStart()
        guard changed.testSelectionIsOpen,
              changedDiscovery.invocationCount == 1 else {
            return fail("changed released")
        }

        let needsAttentionRoot = try makeRoot("needs-attention")
        let needsAttentionDiscovery = M5CountingDiscovery(candidates: candidates)
        let needsAttentionQuit = Counter()
        let needsAttention = try delegate(
            root: needsAttentionRoot,
            discovery: needsAttentionDiscovery,
            quitCount: needsAttentionQuit
        )
        needsAttention.testingSetLastReport(valid)
        needsAttention.testingShowLastReport()
        let needsAttentionLocation = try StateLocation.isolated(
            root: needsAttentionRoot
        )
        let needsAttentionAuthority = try RunAuthority.acquireRun(
            at: needsAttentionLocation
        )
        needsAttentionAuthority.release()
        try FileManager.default.removeItem(
            atPath: needsAttentionLocation.path + "/latest.log"
        )
        try FileManager.default.createDirectory(
            atPath: needsAttentionLocation.path + "/latest.log",
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        needsAttention.testingTriggerMenuStart()
        needsAttention.testQuitUtility()
        guard needsAttentionDiscovery.invocationCount == 0,
              needsAttentionQuit.value == 0,
              needsAttention.testSelectionIsOpen == false,
              needsAttention.testingHistoricalViewerIdentity == nil,
              needsAttention.testingHistoricalViewerStopCount == 0 else {
            return fail("needs-attention gates")
        }

        let recoveryReviewRoot = try makeRoot("recovery-review")
        let recoveryReviewLocation = try StateLocation.isolated(
            root: recoveryReviewRoot
        )
        let recoveryReviewReport = makeReport(
            run: RunIdentity.make(),
            cancelled: true,
            results: candidates.map {
                makeResult(candidate: $0, code: .needsAttention)
            },
            summaryOverride: InterruptedRunReconstructor.summary
        )
        let recoveryReviewAuthority = try RunAuthority.acquireRun(
            at: recoveryReviewLocation
        )
        let recoveryReviewWriter = try RunLogWriter(
            authority: recoveryReviewAuthority,
            runID: recoveryReviewReport.run
        )
        try recoveryReviewWriter.append(
            type: "run_intent",
            intent: RunIntent(
                run: recoveryReviewReport.run,
                startedAt: recoveryReviewReport.startedAt,
                candidates: candidates
            )
        )
        try recoveryReviewWriter.append(
            type: "run_finished",
            report: recoveryReviewReport
        )
        try recoveryReviewWriter.flush()
        recoveryReviewAuthority.release()
        let recoveryReviewDiscovery =
            M5CountingDiscovery(candidates: candidates)
        let recoveryReviewQuit = Counter()
        let recoveryReview = try delegate(
            root: recoveryReviewRoot,
            discovery: recoveryReviewDiscovery,
            quitCount: recoveryReviewQuit
        )
        recoveryReview.testLoadRecoveryPresentation()
        recoveryReview.testingShowLastReport()
        let recoveryViewer = recoveryReview.testingHistoricalViewerIdentity
        recoveryReview.testingTriggerMenuStart()
        recoveryReview.testQuitUtility()
        let reopenedRecoveryViewer =
            recoveryReview.testingHistoricalViewerIdentity
        guard recoveryViewer != nil,
              reopenedRecoveryViewer != nil,
              reopenedRecoveryViewer != recoveryViewer,
              recoveryReview.testRecoveryReviewRequired,
              recoveryReviewDiscovery.invocationCount == 0,
              recoveryReviewQuit.value == 0,
              recoveryReview.testSelectionIsOpen == false,
              recoveryReview.testingHistoricalViewerHasNoLifecycleEvidence else {
            return fail(
                "recovery-review gates "
                    + "viewer=\(recoveryViewer != nil) "
                    + "reopened=\(reopenedRecoveryViewer != nil && reopenedRecoveryViewer != recoveryViewer) "
                    + "required=\(recoveryReview.testRecoveryReviewRequired) "
                    + "discovery=\(recoveryReviewDiscovery.invocationCount) "
                    + "quit=\(recoveryReviewQuit.value) "
                    + "selection=\(recoveryReview.testSelectionIsOpen) "
                    + "evidence=\(!recoveryReview.testingHistoricalViewerHasNoLifecycleEvidence)"
            )
        }

        let invalidHeldRoot = try makeRoot("invalid-held")
        let invalidHeldDiscovery = M5CountingDiscovery(candidates: candidates)
        let invalidHeldQuit = Counter()
        let invalidHeld = try delegate(
            root: invalidHeldRoot,
            discovery: invalidHeldDiscovery,
            quitCount: invalidHeldQuit
        )
        let invalidHeldAuthority = try RunAuthority.acquireRun(
            at: StateLocation.isolated(root: invalidHeldRoot)
        )
        invalidHeld.testingSetLastReport(invalid)
        invalidHeld.testingShowLastReport()
        guard invalidHeld.testingRunControllerIdentity == nil,
              invalidHeld.testingHistoricalViewerIdentity == nil,
              invalidHeld.testDiscoveryPresentation?.0
                == "Last report needs attention" else {
            invalidHeldAuthority.release()
            return fail("invalid held rejection")
        }
        invalidHeld.testingTriggerShortcut()
        invalidHeld.testQuitUtility()
        guard invalidHeldDiscovery.invocationCount == 0,
              invalidHeldQuit.value == 0,
              invalidHeld.testSelectionIsOpen == false else {
            invalidHeldAuthority.release()
            return fail("invalid held gates")
        }
        invalidHeldAuthority.release()

        let invalidCleanRoot = try makeRoot("invalid-clean")
        let invalidCleanDiscovery = M5CountingDiscovery(candidates: candidates)
        let invalidCleanQuit = Counter()
        let invalidClean = try delegate(
            root: invalidCleanRoot,
            discovery: invalidCleanDiscovery,
            quitCount: invalidCleanQuit
        )
        invalidClean.testingSetLastReport(invalid)
        invalidClean.testingShowLastReport()
        guard invalidClean.testingHistoricalViewerIdentity == nil,
              invalidClean.testingRunControllerIdentity == nil else {
            return fail("invalid clean rejection")
        }
        invalidClean.testQuitUtility()
        guard invalidCleanQuit.value == 1 else {
            return fail("invalid clean quit")
        }
        invalidClean.testingSetLastReport(valid)
        invalidClean.testingShowLastReport()
        guard invalidClean.testingHistoricalViewerHasNoLifecycleEvidence else {
            return fail("invalid corrected retry")
        }
        let correctedViewer = invalidClean.testingHistoricalViewerIdentity
        invalidClean.testingCloseHistoricalWindow()
        guard invalidClean.testingHistoricalViewerIdentity == correctedViewer,
              !invalidClean.testingHistoricalWindowIsVisible else {
            return fail("invalid corrected red close")
        }
        invalidClean.testingShowLastReport()
        guard invalidClean.testingHistoricalViewerIdentity == correctedViewer,
              invalidClean.testingHistoricalWindowIsVisible else {
            return fail("invalid corrected hidden restore")
        }
        invalidClean.testingExplicitCloseHistoricalWindow()
        guard invalidClean.testingHistoricalViewerIdentity == nil else {
            return fail("invalid corrected explicit close")
        }
        invalidClean.testingShowLastReport()
        guard let replacementViewer =
                invalidClean.testingHistoricalViewerIdentity,
              replacementViewer != correctedViewer else {
            return fail("invalid corrected replacement")
        }
        invalidClean.testingExplicitCloseHistoricalWindow()
        invalidClean.testingTriggerMenuStart()
        guard invalidClean.testSelectionIsOpen,
              invalidCleanDiscovery.invocationCount == 1 else {
            return fail("invalid corrected start")
        }

        let invalidAmbientRoot = try makeRoot("invalid-ambient")
        let invalidAmbientDiscovery = M5CountingDiscovery(candidates: candidates)
        let invalidAmbient = try delegate(
            root: invalidAmbientRoot,
            discovery: invalidAmbientDiscovery,
            quitCount: Counter()
        )
        invalidAmbient.testingSetLastReport(invalid)
        invalidAmbient.testingShowLastReport()
        invalidAmbient.testingTriggerShortcut()
        guard invalidAmbient.testingHistoricalViewerIdentity == nil,
              invalidAmbient.testSelectionIsOpen,
              invalidAmbientDiscovery.invocationCount == 1 else {
            return fail("invalid ambient recovery")
        }

        let staleRoot = try makeRoot("stale")
        let staleDiscovery = M5CountingDiscovery(candidates: candidates)
        let stale = try delegate(
            root: staleRoot,
            discovery: staleDiscovery,
            quitCount: Counter()
        )
        stale.testingSetLastReport(valid)
        stale.testingShowLastReport()
        stale.testingLeaveStaleHistoricalReference()
        stale.testingTriggerStatusActivation()
        guard stale.testingHistoricalViewerIdentity == nil,
              stale.testSelectionIsOpen,
              staleDiscovery.invocationCount == 1 else {
            return fail("stale viewer activation")
        }

        let selectionPriorityRoot = try makeRoot("selection-priority")
        let selectionPriorityDiscovery =
            M5CountingDiscovery(candidates: candidates)
        let selectionPriority = try delegate(
            root: selectionPriorityRoot,
            discovery: selectionPriorityDiscovery,
            quitCount: Counter()
        )
        selectionPriority.testingSetLastReport(valid)
        selectionPriority.testingShowLastReport()
        let priorityViewer = selectionPriority.testingHistoricalViewerIdentity
        let forcedSelection = SelectionWindowController(candidates: candidates)
        selectionPriority.testingInstallSelectionWindow(forcedSelection)
        selectionPriority.testingHideHistoricalWindow()
        selectionPriority.testingHideSelectionWindow()
        selectionPriority.testingTriggerShortcut()
        guard selectionPriority.testingSelectionWindowIsVisible,
              !selectionPriority.testingHistoricalWindowIsVisible,
              selectionPriority.testingHistoricalViewerIdentity == priorityViewer,
              selectionPriorityDiscovery.invocationCount == 0 else {
            return fail("selection priority")
        }

        let activeRoot = try makeRoot("active")
        let activeDiscovery = M5CountingDiscovery(candidates: candidates)
        let activeQuit = Counter()
        let active = try delegate(
            root: activeRoot,
            discovery: activeDiscovery,
            quitCount: activeQuit
        )
        let live = RunWindowController(candidates: candidates)
        active.testingInstallRunWindow(live)
        active.testingSetLastReport(valid)
        let liveIdentity = active.testingRunControllerIdentity
        active.testingShowLastReport()
        let activeHistoricalIdentity =
            active.testingHistoricalViewerIdentity
        active.testingTriggerShortcut()
        guard active.testingRunControllerIdentity == liveIdentity,
              activeHistoricalIdentity != nil,
              active.testingHistoricalViewerIdentity
                == activeHistoricalIdentity,
              active.testingRunWindowIsVisible,
              activeDiscovery.invocationCount == 0 else {
            return fail("active routing")
        }

        let coexistRoot = try makeRoot("coexist")
        let coexistDiscovery = M5CountingDiscovery(candidates: candidates)
        let coexistQuit = Counter()
        let coexist = try delegate(
            root: coexistRoot,
            discovery: coexistDiscovery,
            quitCount: coexistQuit
        )
        coexist.testingSetLastReport(valid)
        coexist.testingShowLastReport()
        let historicalIdentity = coexist.testingHistoricalViewerIdentity
        let newLive = RunWindowController(candidates: candidates)
        coexist.testingInstallRunWindow(newLive)
        let newLiveIdentity = coexist.testingRunControllerIdentity
        coexist.testingHideHistoricalWindow()
        coexist.testingHideRunWindow()
        coexist.testingTriggerShortcut()
        guard coexist.testingRunWindowIsVisible,
              !coexist.testingHistoricalWindowIsVisible,
              coexist.testingHistoricalViewerIdentity == historicalIdentity,
              coexistDiscovery.invocationCount == 0 else {
            return fail("live priority")
        }
        coexist.testingCloseHistoricalWindow()
        guard historicalIdentity != nil,
              coexist.testingHistoricalViewerIdentity == historicalIdentity,
              !coexist.testingHistoricalWindowIsVisible,
              coexist.testingRunControllerIdentity == newLiveIdentity else {
            return fail("coexisting red close")
        }
        coexist.testingExplicitCloseHistoricalWindow()
        guard coexist.testingHistoricalViewerIdentity == nil,
              coexist.testingRunControllerIdentity == newLiveIdentity else {
            return fail("coexisting explicit close")
        }
        coexist.testingShowLastReport()
        let reopenedCoexistingHistory =
            coexist.testingHistoricalViewerIdentity
        let finalExact = coexist.testingRunControllerIdentity == newLiveIdentity
            && reopenedCoexistingHistory != nil
            && reopenedCoexistingHistory
                != historicalIdentity
            && coexistDiscovery.invocationCount == 0
        return finalExact ? true : fail("coexisting active routing")
    }

    private static func testReportReopen(root: String) throws -> Bool {
        func fail(_ stage: String) -> Bool {
            fputs("M5 report reopen failure: \(stage)\n", stderr)
            return false
        }
        let candidates = makeCandidates(count: 2, root: root + "/reopen")
        let mapping = try makeMapping(root: root)
        let report = makeReport(
            run: RunIdentity.make(),
            results: candidates.map {
                makeResult(candidate: $0, code: .alreadyCurrent)
            }
        )
        let delegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        delegate.testingSetLastReport(report)
        delegate.testingShowLastReport()
        guard delegate.testingRunControllerIdentity == nil,
              let first = delegate.testingHistoricalViewerIdentity,
              delegate.testReport == report,
              delegate.testingRunMetadata
                == "Legacy run — clone-based model · Run started: 2026-09-05T20:00:00.000Z · Ended: 2026-09-05T20:00:01.000Z · Duration: 1000 ms · Cancellation: not_cancelled",
              delegate.testMenuTitles().contains("Show Last Report") else {
            return fail(
                "first open "
                    + "live=\(delegate.testingRunControllerIdentity != nil) "
                    + "historical=\(delegate.testingHistoricalViewerIdentity != nil) "
                    + "report=\(delegate.testReport == report) "
                    + "metadata=\(delegate.testingRunMetadata ?? "nil")"
            )
        }
        delegate.testCloseRun()
        guard delegate.testingRunControllerIdentity == nil,
              delegate.testingHistoricalViewerIdentity == nil,
              delegate.testLastReport == report else {
            return fail("first close")
        }
        delegate.testingShowLastReport()
        guard let second = delegate.testingHistoricalViewerIdentity,
              second != first,
              delegate.testReport == report else {
            return fail("second open")
        }

        let interrupted = makeReport(
            run: RunIdentity.make(),
            cancelled: true,
            results: candidates.map {
                makeResult(candidate: $0, code: .cancelledPending)
            },
            summaryOverride: InterruptedRunReconstructor.summary
        )
        let partialDelegate = makeDelegate(
            discovery: M5CountingDiscovery(candidates: candidates),
            root: root,
            mapping: mapping,
            shortcutAvailable: true
        )
        partialDelegate.testingSetLastReport(interrupted)
        partialDelegate.testingShowLastReport()
        let partialIdentity = partialDelegate.testingHistoricalViewerIdentity
        partialDelegate.testingShowLastReport()
        let partialExact = partialDelegate.testingRunControllerIdentity == nil
            && partialDelegate.testingHistoricalViewerIdentity == partialIdentity
            && partialDelegate.testReport == interrupted
            && partialDelegate.testReportRowText.contains(
                "Result: CANCELLED_PENDING"
            )
        return partialExact ? true : fail("partial reopen")
    }

    private static func testSecureLogFeedback(root: String) throws -> Bool {
        let logRoot = root + "/log-feedback-\(RunIdentity.make())"
        guard mkdir(logRoot, 0o700) == 0 else {
            throw M5HarnessError.systemCall("mkdir log feedback", errno)
        }
        defer { try? FileManager.default.removeItem(atPath: logRoot) }
        let location = try StateLocation.isolated(root: logRoot)
        try TestIsolation.initializeState(at: location)
        let candidates = makeCandidates(count: 1, root: logRoot + "/rows")
        let mappingRoot = logRoot + "/mapping"
        guard mkdir(mappingRoot, 0o700) == 0 else {
            throw M5HarnessError.systemCall("mkdir log mapping", errno)
        }
        let mapping = try makeMapping(root: logRoot, localName: "mapping")
        var openerCalls = 0
        var openSucceeds = false
        let delegate = ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0],
            discovery: M5CountingDiscovery(candidates: candidates),
            testingRoot: logRoot,
            testingMapping: mapping,
            testingConfirmation: { .alertFirstButtonReturn },
            testingLogOpener: { _ in
                openerCalls += 1
                return openSucceeds
            },
            testingShortcutAvailable: true,
            testingQuitHandler: {}
        )
        delegate.testingInstallStatusItem()
        defer {
            delegate.testingTerminateForegroundObservation()
            delegate.testingRemoveStatusItem()
        }
        delegate.testStartNewRun()
        let authority = try RunAuthority.acquireRun(at: location)
        let writer = try RunLogWriter(
            authority: authority,
            runID: RunIdentity.make()
        )
        try writer.append(type: "diagnostic", data: "safe fixture")
        try writer.flush()
        authority.release()
        delegate.testOpenLatestLog()
        let failureWasInline = openerCalls == 1
            && delegate.testingInlineStatusMessage
                == ShadowSyncPresentation.logOpenFailure
            && delegate.testingSelectionInlineMessage
                == ShadowSyncPresentation.logOpenFailure
            && delegate.testMenuTitles().contains(
                ShadowSyncPresentation.logOpenFailure
            )
        delegate.testingBeginCurrentForegroundRequest()
        delegate.testingResolveForegroundTimeout()
        let foregroundFailureWasGlobal =
            delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable
            && delegate.testingForegroundSnapshot.tooltip
                == ShadowSyncPresentation.foregroundUnavailable
            && delegate.testingForegroundSnapshot.accessibilityHelp
                == ShadowSyncPresentation.foregroundUnavailable
        openSucceeds = true
        delegate.testOpenLatestLog()
        return failureWasInline
            && foregroundFailureWasGlobal
            && openerCalls == 2
            && delegate.testingInlineStatusMessage == nil
            && delegate.testingSelectionInlineMessage == nil
            && delegate.testingForegroundSnapshot.menu
                == ShadowSyncPresentation.foregroundUnavailable
            && delegate.testingForegroundSnapshot.tooltip
                == ShadowSyncPresentation.foregroundUnavailable
            && delegate.testingForegroundSnapshot.accessibilityHelp
                == ShadowSyncPresentation.foregroundUnavailable
            && delegate.testingForegroundSnapshot.generation == nil
            && !delegate.testMenuTitles().contains(
                ShadowSyncPresentation.logOpenFailure
            )
    }

    private static func testReportSummaries(root: String) throws -> Bool {
        let successCandidates = makeCandidates(count: 8, root: root + "/summary-success")
        let successResults = successCandidates.enumerated().map {
            makeResult(
                candidate: $0.element,
                code: $0.offset < 5 ? .updated : .alreadyCurrent
            )
        }
        let success = makeReport(
            run: RunIdentity.make(),
            results: successResults
        )

        let mixedCandidates = makeCandidates(count: 7, root: root + "/summary-mixed")
        let mixedResults = mixedCandidates.enumerated().map { index, candidate in
            let code: ResultCode
            switch index {
            case 0..<4: code = .updated
            case 4..<6: code = .skippedDirty
            default: code = .failedFetch
            }
            return makeResult(candidate: candidate, code: code)
        }
        let mixed = makeReport(run: RunIdentity.make(), results: mixedResults)

        let cancelledCandidates = makeCandidates(
            count: 8,
            root: root + "/summary-cancelled"
        )
        let cancelledResults = cancelledCandidates.enumerated().map {
            makeResult(
                candidate: $0.element,
                code: $0.offset < 3 ? .alreadyCurrent : .cancelledPending
            )
        }
        let cancelled = makeReport(
            run: RunIdentity.make(),
            cancelled: true,
            results: cancelledResults
        )
        return success.summary == "Run complete — 5 updated, 3 already current."
            && mixed.summary
                == "Run complete with issues — 4 updated, 2 skipped, 1 failed. Completed updates were kept."
            && cancelled.summary
                == "Run cancelled — 3 repositories completed before cancellation; 5 were not run. Completed updates were kept."
            && Set(successResults.map(\.code)).isSubset(of: Set(ResultCode.allCases))
            && mixedResults.filter(\.mainUpdated).count == 4
            && cancelledResults.filter {
                $0.resultClass == .cancelled
            }.count == 5
    }

    private static func runLatencyTrial(
        root: String,
        trial: Int
    ) throws -> M5LatencyResponse {
        let rowCount = 100
        let durationSeconds = 60
        let intervalMilliseconds = 25
        let expectedEvents = durationSeconds * 1_000 / intervalMilliseconds
        let candidates = makeCandidates(
            count: rowCount,
            root: root + "/latency-\(trial)"
        )
        let controller = RunWindowController(candidates: candidates)
        let runID = controller.testingRunID
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.testingAcceptEvent(RunEvent(
            run: runID,
            sequence: 1,
            type: .runStarted
        ))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let box = M5LatencyBox()
        let start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<expectedEvents {
                let target = start
                    + UInt64(index + 1)
                    * UInt64(intervalMilliseconds)
                    * 1_000_000
                while true {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now >= target { break }
                    let remaining = target - now
                    if remaining > 1_000_000 {
                        usleep(useconds_t(min(remaining / 1_000, 20_000)))
                    } else {
                        sched_yield()
                    }
                }
                let emitted = DispatchTime.now().uptimeNanoseconds
                let sequence = index + 2
                let repositoryIndex = index % rowCount
                let phase: RepositoryPhase
                switch index / 800 {
                case 0: phase = .checking
                case 1: phase = .fetching
                default: phase = .updating
                }
                let event = RunEvent(
                    run: runID,
                    sequence: sequence,
                    type: .repositoryPhase,
                    repositoryID: candidates[repositoryIndex].path,
                    phase: phase
                )
                DispatchQueue.main.async {
                    guard !box.hasFailure else { return }
                    controller.testingAcceptEventAndCompleteRender(event)
                    let completed = DispatchTime.now().uptimeNanoseconds
                    box.append(
                        sample: Double(completed - emitted) / 1_000_000,
                        sequence: sequence,
                        emitted: emitted,
                        completed: completed
                    )
                }
            }
        }
        let deadline = MonotonicDeadline(seconds: 70)
        while box.count < expectedEvents, !deadline.hasExpired {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        let snapshot = box.snapshot
        if let failure = snapshot.failure {
            throw M5HarnessError.message(failure)
        }
        guard snapshot.samples.count == expectedEvents else {
            throw M5HarnessError.message(
                "latency trial rendered \(snapshot.samples.count) of \(expectedEvents) events"
            )
        }
        let expectedSequences = Array(2..<(2 + expectedEvents))
        let monotonic =
            snapshot.sequences == expectedSequences
                && zip(
                    snapshot.emissionTimes,
                    snapshot.emissionTimes.dropFirst()
                ).allSatisfy(<)
                && zip(
                    snapshot.completionTimes,
                    snapshot.completionTimes.dropFirst()
                ).allSatisfy(<)
                && controller.testingLastEventSequence == expectedEvents + 1
        let noDrop = snapshot.sequences.count == expectedEvents
            && Set(snapshot.sequences).count == expectedEvents
        let sorted = snapshot.samples.sorted()
        let p95Index = max(
            0,
            min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        let p95 = sorted[p95Index]
        let maximum = sorted.last ?? 0
        guard monotonic, noDrop, p95 <= 250 else {
            throw M5HarnessError.message(
                "latency trial failed: monotonic=\(monotonic) noDrop=\(noDrop) "
                    + "p95=\(p95) maximum=\(maximum)"
            )
        }
        return M5LatencyResponse(
            trial: trial,
            rowCount: rowCount,
            durationSeconds: durationSeconds,
            eventIntervalMilliseconds: intervalMilliseconds,
            expectedEventCount: expectedEvents,
            renderedEventCount: snapshot.samples.count,
            firstSequence: snapshot.sequences.first ?? 0,
            lastSequence: snapshot.sequences.last ?? 0,
            monotonic: monotonic,
            noDroppedEvents: noDrop,
            p95Milliseconds: p95,
            maximumMilliseconds: maximum,
            samplesMilliseconds: snapshot.samples
        )
    }

    private static func makeDelegate(
        discovery: any RepositoryDiscovering,
        root: String,
        mapping: TransportMapping,
        shortcutAvailable: Bool
    ) -> ShadowSyncAppDelegate {
        ShadowSyncAppDelegate(
            executablePath: CommandLine.arguments[0],
            discovery: discovery,
            testingRoot: root,
            testingMapping: mapping,
            testingConfirmation: { .alertFirstButtonReturn },
            testingLogOpener: { _ in true },
            testingShortcutAvailable: shortcutAvailable,
            testingQuitHandler: {}
        )
    }

    private static func makeMapping(
        root: String,
        localName: String = "m5-local-transport"
    ) throws -> TransportMapping {
        let path = root + "/\(localName)"
        if !FileManager.default.fileExists(atPath: path) {
            guard mkdir(path, 0o700) == 0 else {
                throw M5HarnessError.systemCall("mkdir transport fixture", errno)
            }
        }
        return try TransportMapping(
            logicalURL: "https://github.com/fixture-owner/m5-fixture.git",
            localRepositoryPath: path,
            containmentRoot: root
        )
    }

    private static func makeCandidates(
        count: Int,
        root: String
    ) -> [RepositoryCandidate] {
        (0..<count).map { index in
            RepositoryCandidate(
                id: "fixture-owner/repository-\(index)",
                displayName: index == 0
                    ? "Repository \(index) — Unicode Ω with a deliberately long adaptive name"
                    : "Repository \(index)",
                path: "\(root)/repository-\(index)",
                rawOrigin: "https://github.com/fixture-owner/repository-\(index).git",
                presentationLocation: "~/dev/testing/repository-\(index)"
            )
        }
    }

    private static func makeRepositoryCardInventory(
        root: String,
        index: Int,
        requiresOnboarding: Bool = false
    ) throws -> RepositoryInventory {
        func identity(_ inode: UInt64)
            throws -> RepositoryDirectoryIdentity {
            let data = try JSONSerialization.data(
                withJSONObject: ["device": 1, "inode": inode]
            )
            return try JSONDecoder().decode(
                RepositoryDirectoryIdentity.self,
                from: data
            )
        }
        let repositoryID = "fixture-owner/card-\(index)"
        let origin = "https://github.com/\(repositoryID).git"
        let source = RepositoryCandidate(
            id: repositoryID,
            displayName: "Card \(index)",
            path: "\(root)/card-\(index)",
            rawOrigin: origin,
            presentationLocation: "~/dev/testing/card-\(index)",
            rootIdentity: try identity(UInt64(index * 10 + 1)),
            gitDirectoryIdentity:
                try identity(UInt64(index * 10 + 2)),
            commonDirectoryIdentity:
                try identity(UInt64(index * 10 + 2))
        )
        let clone = try LocalClone(
            repositoryID: repositoryID,
            sourceSnapshot: source,
            effectiveOrigin: origin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: [],
            branches: [],
            warnings: []
        )
        let repository = try RemoteRepository(
            id: repositoryID,
            origins: [origin],
            policyCategory: .writable,
            resolvedDefault: try RemoteDefaultBranch(
                name: "main",
                advertisedOID: String(repeating: "a", count: 40)
            ),
            defaultUnavailableReason: nil
        )
        let card = try RepositoryCard(
            repository: repository,
            authority: CanonicalAuthorityState(
                status: .missing,
                record: nil,
                explanation: "Choose one verified local root."
            ),
            clones: [clone],
            relation: .unavailable,
            fastForward: nil,
            fastForwardRefusal: "No operation is selectable.",
            originHeadExplanation: "Origin default is main."
        )
        return RepositoryInventory(
            cards: [card],
            onboardingProposals: requiresOnboarding
                ? [CanonicalAuthorityProposal(clone: clone)] : [],
            authorityFileIdentity: nil
        )
    }

    private static func makeResult(
        candidate: RepositoryCandidate,
        code: ResultCode,
        startedAt: String = "2026-09-05T20:00:00.000Z",
        endedAt: String = "2026-09-05T20:00:00.125Z",
        durationMilliseconds: Int64 = 125
    ) -> RepositoryResult {
        let updated = [
            ResultCode.updated,
            .updatedBeforeCancellation,
            .updatedWithWarning,
        ].contains(code)
        let fetched = updated
            || code == .alreadyCurrent
            || code == .skippedAhead
            || code == .skippedDiverged
        return RepositoryResult(
            repository: candidate,
            code: code,
            fetched: fetched,
            mainUpdated: updated,
            beforeCommit: "1111111111111111111111111111111111111111",
            targetCommit: fetched
                ? "2222222222222222222222222222222222222222"
                : nil,
            afterCommit: updated
                ? "2222222222222222222222222222222222222222"
                : "1111111111111111111111111111111111111111",
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: durationMilliseconds,
            explanation: "Stable M5 fixture outcome.",
            failureReason: code == .failedFetch ? .other : nil
        )
    }

    private static func makeReport(
        run: String,
        cancelled: Bool = false,
        startedAt: String = "2026-09-05T20:00:00.000Z",
        endedAt: String = "2026-09-05T20:00:01.000Z",
        durationMilliseconds: Int64 = 1_000,
        results: [RepositoryResult],
        summaryOverride: String? = nil,
        repositoryModel: String? = nil
    ) -> RunReport {
        RunReport(
            run: run,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: durationMilliseconds,
            cancelled: cancelled,
            results: results,
            summaryOverride: summaryOverride,
            repositoryModel: repositoryModel
        )
    }
}

private enum M5HarnessError: Error, CustomStringConvertible {
    case message(String)
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case let .message(detail):
            return detail
        case let .systemCall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}
#endif
