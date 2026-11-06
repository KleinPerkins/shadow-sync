import AppKit
import Carbon
import ShadowSyncCatalog
import ShadowSyncCore
import Foundation
import OSLog
import ServiceManagement

final class HostActivationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: ShadowSyncAppDelegate?
    private var activationQueued = false

    @MainActor
    func install(target: ShadowSyncAppDelegate) {
        lock.lock()
        self.target = target
        let shouldDeliver = activationQueued
        lock.unlock()
        if shouldDeliver {
            Task { @MainActor [weak self] in
                self?.deliver()
            }
        }
    }

    @discardableResult
    func activate() -> Bool {
        lock.lock()
        if activationQueued {
            lock.unlock()
            return true
        }
        activationQueued = true
        let canDeliver = target != nil
        lock.unlock()
        if canDeliver {
            Task { @MainActor [weak self] in
                self?.deliver()
            }
        }
        return true
    }

    @MainActor
    private func deliver() {
        lock.lock()
        guard activationQueued, let target else {
            lock.unlock()
            return
        }
        activationQueued = false
        lock.unlock()
        target.handleDuplicateActivation()
    }
}

struct Body3EventBatch: Sendable {
    let events: [Body3CoordinatorEvent]
    let maximumBacklogDepth: Int
}

final class Body3EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Body3CoordinatorEvent] = []
    private var drainScheduled = false
    private var maximumBacklogDepth = 0

    @discardableResult
    func submit(_ event: Body3CoordinatorEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        maximumBacklogDepth = max(
            maximumBacklogDepth,
            events.count
        )
        guard !drainScheduled else {
            return false
        }
        drainScheduled = true
        return true
    }

    func drain() -> Body3EventBatch {
        lock.lock()
        defer { lock.unlock() }
        let batch = Body3EventBatch(
            events: events,
            maximumBacklogDepth: maximumBacklogDepth
        )
        events.removeAll(keepingCapacity: true)
        maximumBacklogDepth = 0
        drainScheduled = false
        return batch
    }
}

enum LifecycleGateAction: CaseIterable, Equatable {
    case startNewRun
    case closeRun
    case quit
    case takeoverPresentation
    case takeoverRequest
    case takeoverAdvance
}

enum RecoveryStartEvidence {
    case none
    case completedReport
    case interruptedReport(acknowledgementMatches: Bool)
    case operationStillActive
    case needsAttention
}

enum LifecycleGateBlockReason: Equatable {
    case failureRecovery
    case recoveryReview
    case needsAttentionResults
    case postRunSafety
    case awaitingReport
    case workerActive
    case childDrain
    case authorityHeld
    case stopInProgress
    case transitionInProgress
}

enum LifecycleGateDecision: Equatable {
    case allow
    case stopThenReevaluate
    case block(LifecycleGateBlockReason)
}

enum LifecycleGateStopState: CaseIterable, Equatable {
    case idle
    case stopping
    case completedVerified
    case completedUnverified
    case completedStillActive
}

enum RepositoryCleanupProtection {
    static func resolve(
        executablePath: String,
        stateLocation: () throws -> StateLocation
    ) -> (
        protectedPaths: [String],
        boundaryEstablished: Bool
    ) {
        let executableDirectory = URL(
            fileURLWithPath: executablePath
        ).deletingLastPathComponent().path
        do {
            return (
                [
                    executablePath,
                    executableDirectory,
                    try stateLocation().path,
                ],
                true
            )
        } catch {
            return (
                [executablePath, executableDirectory],
                false
            )
        }
    }
}

struct LifecycleGateSnapshot {
    let trustedReport: Bool
    let terminalRunMatched: Bool
    let reportSettled: Bool
    let failureRecoveryRequired: Bool
    let reportRecoveryRequired: Bool
    let recoveryAcknowledged: Bool
    let needsAttentionResults: Bool
    let postRunNoticeBlocks: Bool
    let workerReaped: Bool
    let childDrainVerified: Bool
    let authorityReleased: Bool
    let stopState: LifecycleGateStopState
    let transitionPending: Bool
}

enum LifecycleGate {
    private static func stopStateDecision(
        for action: LifecycleGateAction,
        state: LifecycleGateStopState
    ) -> LifecycleGateDecision? {
        switch state {
        case .idle:
            switch action {
            case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                 .takeoverRequest, .takeoverAdvance:
                return nil
            }
        case .stopping:
            switch action {
            case .quit, .takeoverRequest:
                return .stopThenReevaluate
            case .startNewRun, .closeRun, .takeoverPresentation,
                 .takeoverAdvance:
                return .block(.stopInProgress)
            }
        case .completedVerified:
            switch action {
            case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                 .takeoverRequest, .takeoverAdvance:
                return nil
            }
        case .completedUnverified:
            switch action {
            case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                 .takeoverRequest, .takeoverAdvance:
                return .block(.childDrain)
            }
        case .completedStillActive:
            switch action {
            case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                 .takeoverRequest, .takeoverAdvance:
                return .block(.workerActive)
            }
        }
    }

    static func decideRecoveryStart(
        from evidence: RecoveryStartEvidence
    ) -> LifecycleGateDecision {
        switch evidence {
        case .none, .completedReport:
            return .allow
        case let .interruptedReport(acknowledgementMatches):
            return acknowledgementMatches
                ? .allow
                : .block(.recoveryReview)
        case .operationStillActive:
            return .block(.authorityHeld)
        case .needsAttention:
            return .block(.postRunSafety)
        }
    }

    static func decide(
        _ action: LifecycleGateAction,
        from state: LifecycleGateSnapshot
    ) -> LifecycleGateDecision {
        if let stopDecision = stopStateDecision(
            for: action,
            state: state.stopState
        ) {
            return stopDecision
        }
        if action == .quit {
            guard state.workerReaped else {
                return .stopThenReevaluate
            }
            guard state.childDrainVerified else {
                return .block(.childDrain)
            }
            guard state.authorityReleased else {
                return .block(.authorityHeld)
            }
            switch state.stopState {
            case .idle, .completedVerified:
                return .allow
            case .stopping:
                return .block(.stopInProgress)
            case .completedUnverified:
                return .block(.childDrain)
            case .completedStillActive:
                return .block(.workerActive)
            }
        }
        if state.transitionPending && action == .takeoverPresentation {
            return .block(.transitionInProgress)
        }
        if state.failureRecoveryRequired {
            return .block(.failureRecovery)
        }
        if !state.trustedReport {
            if action == .takeoverPresentation || action == .takeoverRequest {
                return .stopThenReevaluate
            }
            return .block(.awaitingReport)
        }
        if !state.terminalRunMatched || !state.reportSettled {
            return .block(.awaitingReport)
        }
        if state.reportRecoveryRequired && !state.recoveryAcknowledged {
            return .block(.recoveryReview)
        }
        if state.needsAttentionResults {
            return .block(.needsAttentionResults)
        }
        if state.postRunNoticeBlocks {
            return .block(.postRunSafety)
        }
        if !state.workerReaped {
            return action == .takeoverPresentation || action == .takeoverRequest
                ? .stopThenReevaluate
                : .block(.workerActive)
        }
        if !state.childDrainVerified {
            return .block(.childDrain)
        }
        if !state.authorityReleased {
            return .block(.authorityHeld)
        }
        if action == .takeoverAdvance {
            switch state.stopState {
            case .idle, .completedVerified:
                break
            case .stopping, .completedUnverified, .completedStillActive:
                return .block(.stopInProgress)
            }
        }
        if action == .takeoverAdvance && !state.transitionPending {
            return .block(.transitionInProgress)
        }
        return .allow
    }
}

private enum TakeoverWatchdog {
    static var maximumDuration: TimeInterval {
        ProcessOwnershipTiming.takeoverWatchdogMaximum
    }

    static func hasExpired(
        startedAt: TimeInterval,
        now: TimeInterval,
        maximum: TimeInterval = maximumDuration
    ) -> Bool {
        now - startedAt >= maximum
    }
}

private final class OperationContentionWindowController: NSWindowController {
    init(alert: NSAlert) {
        super.init(window: alert.window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
final class ShadowSyncAppDelegate:
    NSObject, NSApplicationDelegate, NSMenuDelegate,
    NSMenuItemValidation {
    private enum OperatorAction: String {
        case menuStart = "menu_start"
        case hotkey
        case quit
    }

    private enum Body3QuitDecision: String {
        case terminate
        case review
        case cancelActiveRun
    }

    private struct RecoveryReviewRequirement: Equatable {
        let run: String
        let startedAt: String
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        func matches(_ report: RunReport) -> Bool {
            report.run == run
                && report.startedAt == startedAt
                && report.summaryOverride == InterruptedRunReconstructor.summary
        }
    }

    private enum ForegroundOutcome: Equatable {
        case success
        case denied
        case timedOut
        case targetClosed
        case superseded
    }

    private struct ForegroundRequest {
        let generation: UInt64
        let controller: NSWindowController
        let windowNumber: Int
        let startedAt: UInt64
        let deadline: UInt64
    }

    private struct ForegroundReality: Equatable {
        let applicationActive: Bool
        let windowVisible: Bool
        let windowKey: Bool
        let windowOnScreen: Bool
        let windowOnActiveSpace: Bool

        var isEstablished: Bool {
            applicationActive
                && windowVisible
                && windowKey
                && windowOnScreen
                && windowOnActiveSpace
        }
    }

    private enum ShortcutCollisionPresentation: Equatable {
        case none
        case pending
        case presenting(UInt64)
        case shown
    }

    private enum InlineStatusSource: Equatable {
        case logOpenFailure
        case foregroundUnavailable
        case hiddenStatusItemGuidance
    }

    private struct AuthorityCommitSession {
        let token: UInt64
    }

    private let executablePath: String
    #if SHADOW_SYNC_TESTING
    private let discovery: any RepositoryDiscovering
    #endif
    private let lifecycleRouter = AppLifecycleRouter()
    private var chooserGeneration: UInt64 = 0
    private var pendingChooserSavedEntries:
        Set<RepositorySelectionPreferenceEntry>?
    private var pendingChooserAcknowledgement: String?
    private var activeSelectedScope: ValidatedSelectedRepositoryScope?
    private var activeVerifiedCapability:
        VerifiedRepositoryAuthorityCapability?
    private var retainedSessionInventory: RepositoryInventory?
    private var retainedSessionCapability:
        VerifiedRepositoryAuthorityCapability?
    private var retainedSuccessfulCleanupInspectionRepositoryIDs:
        Set<String> = []
    private var statusItem: NSStatusItem?
    private var statusItemGuidance = StatusItemGuidanceCoordinator()
    private var statusItemVisibilityCheckWorkItem: DispatchWorkItem?
    private var shortcut: GlobalShortcut?
    private var shortcutAvailable = true
    private var shortcutCollisionPresentation: ShortcutCollisionPresentation = .none
    private var shortcutCollisionGeneration: UInt64 = 0
    private var collisionPresentationScheduled = false
    private var foregroundRequestPending = false
    private var foregroundGeneration: UInt64 = 0
    private var pendingForegroundRequest: ForegroundRequest?
    private var applicationActivationObserver: NSObjectProtocol?
    private var foregroundWindowObservers: [NSObjectProtocol] = []
    private var foregroundRealityRevalidationWorkItem: DispatchWorkItem?
    private var foregroundRealityRevalidationGeneration: UInt64?
    private var foregroundTimeoutWorkItem: DispatchWorkItem?
    private var operationContention = OperationContentionCoordinator()
    private var operationContentionRevalidationWorkItem: DispatchWorkItem?
    private var operationContentionRevalidationGeneration: UInt64 = 0
    private var operationContentionScheduledToken: UInt64?
    private var operationContentionAlert: NSAlert?
    private var operationContentionWindowController:
        OperationContentionWindowController?
    private var operationContentionAlertToken: UInt64?
    private var operationContentionCloseObserver: NSObjectProtocol?
    private var confirmationInProgress = false
    private var confirmationStartArmed = false
    private weak var confirmationSelectionController: SelectionWindowController?
    private var confirmationOnConfirmed: (() -> Void)?
    private var activeConfirmationAlert: NSAlert?
    private var confirmationInputMonitor: Any?
    private var selectionWindow: SelectionWindowController?
    private var canonicalRootWindow:
        CanonicalRootConfirmationWindowController?
    private var inventoryDiscoveryInProgress = false
    private var inventoryPresentationRequested = false
    private var inventoryGeneration: UInt64 = 0
    private var activeInventoryGeneration: UInt64?
    private var inventoryCancellation: CancellationToken?
    private struct PendingCanonicalRootOnboarding {
        let generation: UInt64
        let inventory: RepositoryInventory
    }
    private var pendingCanonicalRootOnboarding:
        PendingCanonicalRootOnboarding?
    private var actionGeneration: UInt64 = 0
    private var activeActionGeneration: UInt64?
    private var authorityCommitGeneration: UInt64 = 0
    private var authorityCommitSession: AuthorityCommitSession?
    private var pendingPlannedOperations: [PlannedOperation] = []
    private var pendingWindowContinuity:
        WindowContinuitySnapshot?
    private var runWindow: RunWindowController?
    private var body3RunWindow: Body3RunWindowController?
    private var body3ConfirmationWindow:
        Body3GroupedConfirmationWindowController?
    private var body3ConfirmationRequest:
        Body3ConfirmationRequest?
    private var body3Cancellation: CancellationToken?
    private var historicalBody3Viewer:
        Body3RunWindowController?
    private var historicalViewer: RunWindowController?
    private var lastReport: RunReport?
    private var lastBody3Recovered: Body3RecoveredRun?
    private var acknowledgedBody3Run: String?
    private var terminalReportNotice: String?
    private var recoveryReviewRequirement: RecoveryReviewRequirement?
    private var acknowledgedRecovery: RecoveryReviewRequirement?
    private var quitConfirmationInProgress = false
    private var inlineStatusSource: InlineStatusSource?
    private var foregroundStatusMessage: String?
    private weak var foregroundFailureController: NSWindowController?
    private var inlineStatusMessage: String? {
        switch inlineStatusSource {
        case .logOpenFailure:
            ShadowSyncPresentation.logOpenFailure
        case .foregroundUnavailable:
            foregroundStatusMessage
                ?? ShadowSyncPresentation.foregroundUnavailable
        case .hiddenStatusItemGuidance:
            ShadowSyncPresentation.hiddenStatusItemGuidance
        case nil:
            nil
        }
    }

    private func rememberWindowFrame(
        _ window: NSWindow?
    ) {
        pendingWindowContinuity =
            WindowFrameContinuity.capture(window)
                ?? pendingWindowContinuity
    }

    private func restoreWindowFrame(
        _ window: NSWindow?
    ) {
        WindowFrameContinuity.apply(
            pendingWindowContinuity,
            to: window
        )
        pendingWindowContinuity = nil
    }
    private let foregroundTimeoutNanoseconds: UInt64 = 2_000_000_000
    private let foregroundRealityRevalidationDelay: TimeInterval = 0.05
    private let foregroundLogger = Logger(
        subsystem: "com.kleinperkins.shadow-sync",
        category: "foreground"
    )
    private let lifecycleLogger = Logger(
        subsystem: "com.kleinperkins.shadow-sync",
        category: "lifecycle"
    )
    private let operationContentionRevalidationDelay: TimeInterval = 0.25
    private let statusItemVisibilityCheckDelay: TimeInterval = 1
    private let stateLocationResolver: () throws -> StateLocation
    private let logLocation: () throws -> StateLocation
    private let logOpener: (URL) -> Bool
    #if SHADOW_SYNC_TESTING
    private let testingRoot: String?
    private let testingMapping: TransportMapping?
    private let testingConfirmation: (() -> NSApplication.ModalResponse)?
    private let testingQuitHandler: (() -> Void)?
    private let testingHostChrome: Bool
    private(set) var testConfirmationSnapshot: (String, String, [String])?
    private(set) var testDiscoveryPresentation: (String, String)?
    private(set) var testDiscoveryPresentationCount = 0
    private(set) var testDuplicateActivationCount = 0
    private(set) var testShortcutCollisionPresentationCount = 0
    private(set) var testShortcutCollisionAttemptCount = 0
    private(set) var testShortcutCollisionPresentation: (String, String)?
    private(set) var testOperationContentionPresentationCount = 0
    private(set) var testOperationContentionDismissalCount = 0
    private(set) var testOperationContentionResumeCount = 0
    private(set) var testOperationContentionPresentation: (String, String)?
    private var testingCollisionAttachmentSucceeds = true
    private var forceAsyncConfirmationForTesting = false
    private var suppressWorkerStartForConfirmationTest = false
    private(set) var testBeginRunCount = 0
    private(set) var testConfirmationClearCount = 0
    private(set) var testCanonicalRootInventoryPresentationCount = 0
    private(set) var testCanonicalRootInventoryRetryCount = 0
    private(set) var testCanonicalRootInventoryRetryPresentationCount = 0
    private(set) var testRepositoryInventoryReconciliation: (
        allowOnboarding: Bool,
        presentResult: Bool
    )?
    private(set) var testInventoryDiscoveryStartCount = 0
    private(set) var testInventoryDiscoveryBusyPresentationCount = 0
    private(set) var testInventoryDiscoveryPresentationCount = 0
    private(set) var testInventoryRetryCount = 0
    private var testingInventoryBeginFailure:
        TestingInventoryBeginFailure?
    private(set) var testLifecycleTrace: [String] = []
    private(set) var testOwnedInventoryQuitCount = 0
    private(set) var testInventoryTerminationCount = 0
    private var testingUsesRealActivation = false
    private var testingSuppressesSystemActivation = false
    private var testingApplicationActiveOverride: Bool?
    private var testingForegroundRealityOverride: Bool?
    private var testingForegroundRealitySnapshotOverride: ForegroundReality?
    private var testingActivationAcceptedOverride: Bool?
    private var testingBecomesActiveAfterActivation = false
    private var testingActivationCallCount = 0
    private var testingActivationCompletionCount = 0
    private var testingActivationFailureCount = 0
    private var testingActivationReassertionCount = 0
    private var testingForegroundRealityRevalidationCount = 0
    private var testingKeyWindowOrderCount = 0
    private var testingForegroundSuccessCount = 0
    private var testingForegroundFailureClearCount = 0
    private(set) var testStatusItemGuidancePresentationCount = 0
    private var testingForegroundNowOverride: UInt64?
    private var testingStatusItemVisibilitySnapshot:
        StatusItemVisibilitySnapshot?
    #endif

    private enum InventoryBeginFailureReason: String {
        case discoveryBusy = "discovery_busy"
        case authorityCommitBusy = "authority_commit_busy"
        #if SHADOW_SYNC_TESTING
        case injected = "injected"
        #endif
    }

    #if SHADOW_SYNC_TESTING
    private enum TestingInventoryBeginFailure {
        case visible
        case hidden
        case queuedQuit
    }
    #endif

    init(executablePath: String) {
        self.executablePath = executablePath
        let resolveState = { try StateLocation.production() }
        stateLocationResolver = resolveState
        logLocation = resolveState
        logOpener = { NSWorkspace.shared.open($0) }
        #if SHADOW_SYNC_TESTING
        discovery = RepositoryDiscovery()
        testingRoot = nil
        testingMapping = nil
        testingConfirmation = nil
        testingQuitHandler = nil
        testingHostChrome = false
        #endif
    }

    #if SHADOW_SYNC_TESTING
    init(
        executablePath: String,
        discovery: any RepositoryDiscovering,
        testingRoot: String,
        testingMapping: TransportMapping,
        testingConfirmation: @escaping () -> NSApplication.ModalResponse,
        testingLogOpener: @escaping (URL) -> Bool,
        testingShortcutAvailable: Bool,
        testingQuitHandler: @escaping () -> Void
    ) {
        self.executablePath = executablePath
        self.discovery = discovery
        self.testingRoot = testingRoot
        self.testingMapping = testingMapping
        self.testingConfirmation = testingConfirmation
        self.testingQuitHandler = testingQuitHandler
        testingHostChrome = true
        shortcutAvailable = testingShortcutAvailable
        shortcutCollisionPresentation = testingShortcutAvailable
            ? .none
            : .pending
        let resolveState = {
            try StateLocation.isolated(root: testingRoot)
        }
        stateLocationResolver = resolveState
        logLocation = resolveState
        logOpener = testingLogOpener
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            return
        }
        #endif
        NSApp.disableRelaunchOnLogin()
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = ShadowSyncStatusItemIcon.make()
        let menu = NSMenu(title: "ShadowSync")
        menu.delegate = self
        item.menu = menu
        statusItem = item

        let shortcut = GlobalShortcut { [weak self] in
            self?.requestForegroundCurrentSurface(action: .hotkey)
        }
        shortcutAvailable = shortcut.register()
        shortcutCollisionPresentation = shortcutAvailable
            ? .none
            : .pending
        if !shortcutAvailable {
            item.button?.toolTip = ShadowSyncPresentation.shortcutUnavailableText
            item.button?.setAccessibilityHelp(
                ShadowSyncPresentation.shortcutUnavailableText
            )
        }
        self.shortcut = shortcut
        loadRecoveryPresentation()
        scheduleStatusItemVisibilityCheck(for: item)
    }

    private func installMainMenu() {
        let main = NSMenu(title: ShadowSyncPresentation.appTitle)

        let applicationItem = NSMenuItem(
            title: ShadowSyncPresentation.appTitle,
            action: nil,
            keyEquivalent: ""
        )
        let applicationMenu = NSMenu(
            title: ShadowSyncPresentation.appTitle
        )
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let about = applicationMenu.addItem(
            withTitle: "About ShadowSync",
            action:
                #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        applicationMenu.addItem(.separator())
        let openAtLogin = applicationMenu.addItem(
            withTitle: ShadowSyncPresentation.openAtLogin,
            action: #selector(toggleOpenAtLogin(_:)),
            keyEquivalent: ""
        )
        openAtLogin.target = self
        configureOpenAtLoginItem(openAtLogin)
        applicationMenu.addItem(.separator())
        let hide = applicationMenu.addItem(
            withTitle: "Hide ShadowSync",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        applicationMenu.addItem(.separator())
        let quit = applicationMenu.addItem(
            withTitle: ShadowSyncPresentation.quitUtility,
            action: #selector(quitUtility),
            keyEquivalent: "q"
        )
        quit.target = self

        let fileItem = NSMenuItem(
            title: "File",
            action: nil,
            keyEquivalent: ""
        )
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let start = fileMenu.addItem(
            withTitle: ShadowSyncPresentation.startNewRun,
            action: #selector(startNewRunAction),
            keyEquivalent: "m"
        )
        start.target = self
        start.keyEquivalentModifierMask = [
            .control, .option, .command,
        ]
        let report = fileMenu.addItem(
            withTitle: ShadowSyncPresentation.showLastReport,
            action: #selector(showLastReportAction),
            keyEquivalent: ""
        )
        report.target = self
        let log = fileMenu.addItem(
            withTitle: ShadowSyncPresentation.openLatestLog,
            action: #selector(openLatestLog),
            keyEquivalent: ""
        )
        log.target = self

        let windowItem = NSMenuItem(
            title: "Window",
            action: nil,
            keyEquivalent: ""
        )
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func configureOpenAtLoginItem(
        _ item: NSMenuItem
    ) {
        switch SMAppService.mainApp.status {
        case .enabled:
            item.state = .on
            item.isEnabled = true
        case .requiresApproval:
            item.state = .mixed
            item.isEnabled = true
        case .notRegistered, .notFound:
            item.state = .off
            item.isEnabled = true
        @unknown default:
            item.state = .off
            item.isEnabled = false
        }
    }

    @objc private func toggleOpenAtLogin(
        _ sender: NSMenuItem
    ) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            @unknown default:
                break
            }
        } catch {
            presentDiscoveryAlert(
                messageText:
                    "Open at Login could not be changed",
                informativeText:
                    "macOS did not accept the change. "
                    + "Review ShadowSync under System Settings → "
                    + "General → Login Items. "
                    + Redactor.sanitize(
                        error.localizedDescription
                    )
            )
        }
        configureOpenAtLoginItem(sender)
    }

    func validateMenuItem(
        _ menuItem: NSMenuItem
    ) -> Bool {
        guard menuItem.action
                == #selector(toggleOpenAtLogin(_:)) else {
            return true
        }
        configureOpenAtLoginItem(menuItem)
        return menuItem.isEnabled
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestForegroundCurrentSurface()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelOperationContention()
        statusItemVisibilityCheckWorkItem?.cancel()
        statusItemVisibilityCheckWorkItem = nil
        pendingForegroundRequest = nil
        clearForegroundRequestObservation()
        clearApplicationActivationObserver()
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            return
        }
        #endif
        shortcut?.unregister()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func scheduleStatusItemVisibilityCheck(for item: NSStatusItem) {
        statusItemVisibilityCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else {
                return
            }
            self.statusItemVisibilityCheckWorkItem = nil
            self.completeStatusItemVisibilityCheck(
                self.statusItemVisibilitySnapshot(for: item)
            )
        }
        statusItemVisibilityCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + statusItemVisibilityCheckDelay,
            execute: workItem
        )
    }

    private func statusItemVisibilitySnapshot(
        for item: NSStatusItem
    ) -> StatusItemVisibilitySnapshot {
        let button = item.button
        let window = button?.window
        let screens = NSScreen.screens
        let windowIsOnScreen = window.map { window in
            window.screen != nil
                || screens.contains { $0.frame.intersects(window.frame) }
        } ?? false
        return StatusItemVisibilitySnapshot(
            apiVisible: item.isVisible,
            hasButton: button != nil,
            hasWindow: window != nil,
            hasAvailableScreen: !screens.isEmpty,
            windowIsOnScreen: windowIsOnScreen
        )
    }

    private func currentStatusItemVisibilitySnapshot()
        -> StatusItemVisibilitySnapshot? {
        #if SHADOW_SYNC_TESTING
        if let testingStatusItemVisibilitySnapshot {
            return testingStatusItemVisibilitySnapshot
        }
        #endif
        guard let statusItem else {
            return nil
        }
        return statusItemVisibilitySnapshot(for: statusItem)
    }

    private func reconcileStatusItemGuidanceWithCurrentVisibility() {
        guard statusItemGuidance.hasObservedHiddenStatusItem,
              let snapshot = currentStatusItemVisibilitySnapshot(),
              statusItemGuidance.cancelIfStatusItemIsVisible(snapshot) else {
            return
        }
        clearInlineStatus(
            .hiddenStatusItemGuidance,
            retryGuidance: false
        )
        guard foregroundStatusMessage
                == ShadowSyncPresentation
                    .foregroundUnavailableWithHiddenStatusItem else {
            return
        }
        foregroundStatusMessage = ShadowSyncPresentation.foregroundUnavailable
        _ = presentInlineStatus(
            .foregroundUnavailable,
            on: currentPrimaryController()
        )
        statusItem?.button?.toolTip =
            ShadowSyncPresentation.foregroundUnavailable
        statusItem?.button?.setAccessibilityHelp(
            ShadowSyncPresentation.foregroundUnavailable
        )
    }

    private func completeStatusItemVisibilityCheck(
        _ snapshot: StatusItemVisibilitySnapshot
    ) {
        statusItemGuidance.completeDeferredCheck(snapshot)
        if let controller = currentPrimaryController() {
            presentStatusItemGuidanceIfNeeded(on: controller)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let start = menu.addItem(
            withTitle: ShadowSyncPresentation.startNewRun,
            action: #selector(startNewRunAction),
            keyEquivalent: "m"
        )
        start.target = self
        start.keyEquivalentModifierMask = [
            .control, .option, .command,
        ]
        if let body3RunWindow {
            let item = menu.addItem(
                withTitle: body3RunWindow.report == nil
                    ? ShadowSyncPresentation.showCurrentRun
                    : ShadowSyncPresentation.showLastReport,
                action: #selector(showCurrentRun),
                keyEquivalent: ""
            )
            item.target = self
        } else if let runWindow {
            let showsValidatedReport =
                runWindow.isFinished && runWindow.report != nil
            let item = menu.addItem(
                withTitle: showsValidatedReport
                    ? ShadowSyncPresentation.showLastReport
                    : ShadowSyncPresentation.showCurrentRun,
                action: #selector(showCurrentRun),
                keyEquivalent: ""
            )
            item.target = self
        } else if lastBody3Recovered != nil
                    || lastReport != nil
                    || historicalViewer != nil {
            let item = menu.addItem(
                withTitle: ShadowSyncPresentation.showLastReport,
                action: #selector(showLastReportAction),
                keyEquivalent: ""
            )
            item.target = self
        }
        if let terminalReportNotice {
            let notice = NSMenuItem(
                title: terminalReportNotice,
                action: nil,
                keyEquivalent: ""
            )
            notice.isEnabled = false
            menu.addItem(notice)
        }
        let log = menu.addItem(
            withTitle: ShadowSyncPresentation.openLatestLog,
            action: #selector(openLatestLog),
            keyEquivalent: ""
        )
        log.target = self
        if let inlineStatusMessage {
            let status = NSMenuItem(
                title: inlineStatusMessage,
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            menu.addItem(status)
        }
        if let foregroundStatusMessage,
           foregroundStatusMessage != inlineStatusMessage {
            let status = NSMenuItem(
                title: foregroundStatusMessage,
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            menu.addItem(status)
        }
        if !shortcutAvailable {
            let unavailable = NSMenuItem(
                title: ShadowSyncPresentation.shortcutUnavailable,
                action: nil,
                keyEquivalent: ""
            )
            unavailable.isEnabled = false
            unavailable.setAccessibilityLabel(
                ShadowSyncPresentation.shortcutUnavailable
            )
            unavailable.setAccessibilityHelp(
                ShadowSyncPresentation.shortcutUnavailableText
            )
            menu.addItem(unavailable)
        }
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: ShadowSyncPresentation.quitUtility,
            action: #selector(quitUtility),
            keyEquivalent: "q"
        )
        quit.target = self
    }

    @objc private func startNewRunAction() {
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            recordAction(.menuStart)
            startNewRun()
            return
        }
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.recordAction(.menuStart)
            self?.startNewRun()
        }
    }

    @objc private func showLastReportAction() {
        DispatchQueue.main.async { [weak self] in
            self?.showLastReport()
        }
    }

    private func requestForegroundCurrentSurface(
        action: OperatorAction? = nil
    ) {
        if let action {
            recordAction(action)
        }
        guard !foregroundRequestPending else {
            return
        }
        foregroundRequestPending = true
        defer { foregroundRequestPending = false }
        foregroundCurrentSurface()
    }

    private func recordAction(_ action: OperatorAction) {
        actionGeneration &+= 1
        activeActionGeneration = actionGeneration
        lifecycleLogger.notice(
            "action entry action=\(action.rawValue, privacy: .public) generation=\(self.actionGeneration, privacy: .public)"
        )
        #if SHADOW_SYNC_TESTING
        testLifecycleTrace.append(
            "action:\(action.rawValue):\(actionGeneration)"
        )
        #endif
        recordSelectedTarget()
    }

    private enum OperatorSurfaceSelection {
        case explicitInvocation
        case passiveReconciliation
    }

    private enum OperatorSurfaceKind: String {
        case contention
        case body3Confirmation = "body3_confirmation"
        case body3Run = "body3_run"
        case canonicalRoot = "canonical_root"
        case pendingOnboarding = "pending_onboarding"
        case repositoryCards = "repository_cards"
        case selection
        case run
        case historical
    }

    private struct CurrentOperatorSurface {
        let kind: OperatorSurfaceKind
        let controller: NSWindowController?
        let contentionToken: UInt64?
    }

    private func currentOperatorSurface(
        for selection: OperatorSurfaceSelection
    ) -> CurrentOperatorSurface? {
        if let token = operationContentionAlertToken,
           operationContention.isPresented {
            return CurrentOperatorSurface(
                kind: .contention,
                controller: operationContentionWindowController,
                contentionToken: token
            )
        }
        if let controller = body3ConfirmationWindow,
           controller.window != nil {
            return CurrentOperatorSurface(
                kind: .body3Confirmation,
                controller: controller,
                contentionToken: nil
            )
        }
        if let controller = body3RunWindow,
           controller.isPresentationOpen {
            return CurrentOperatorSurface(
                kind: .body3Run,
                controller: controller,
                contentionToken: nil
            )
        }
        if let controller = canonicalRootWindow,
           controller.isPresentationOpen {
            return CurrentOperatorSurface(
                kind: .canonicalRoot,
                controller: controller,
                contentionToken: nil
            )
        }
        if case .explicitInvocation = selection,
           pendingCanonicalRootOnboarding != nil,
           authorityCommitSession == nil {
            return CurrentOperatorSurface(
                kind: .pendingOnboarding,
                controller: nil,
                contentionToken: nil
            )
        }
        if let controller = selectionWindow {
            let isRepositoryCards =
                controller
                    is RepositoryCardSelectionWindowController
            let isEligible: Bool
            switch selection {
            case .explicitInvocation:
                isEligible = controller.isPresentationOpen
            case .passiveReconciliation:
                isEligible = controller.isPresentationOpen
                    && controller.window?.isVisible == true
            }
            if isEligible {
                return CurrentOperatorSurface(
                    kind: isRepositoryCards
                        ? .repositoryCards : .selection,
                    controller: controller,
                    contentionToken: nil
                )
            }
        }
        if let controller = runWindow,
           controller.isPresentationOpen {
            return CurrentOperatorSurface(
                kind: .run,
                controller: controller,
                contentionToken: nil
            )
        }
        if let controller = historicalBody3Viewer,
           controller.isPresentationOpen {
            return CurrentOperatorSurface(
                kind: .historical,
                controller: controller,
                contentionToken: nil
            )
        }
        if let controller = historicalViewer,
           controller.isPresentationOpen {
            return CurrentOperatorSurface(
                kind: .historical,
                controller: controller,
                contentionToken: nil
            )
        }
        return nil
    }

    private func foreground(
        _ surface: CurrentOperatorSurface
    ) {
        if let token = surface.contentionToken {
            foregroundOperationContention(token: token)
            return
        }
        if surface.kind == .pendingOnboarding {
            presentPendingCanonicalRootOnboarding()
            return
        }
        guard let controller = surface.controller else { return }
        (controller
            as? RepositoryCardSelectionWindowController)?
            .prepareForRedisplay()
        foreground(controller)
    }

    private func recordSelectedTarget() {
        let surface = currentOperatorSurface(
            for: .explicitInvocation
        )
        let target = surface?.kind.rawValue ?? "none"
        let windowNumber =
            surface?.controller?.window?.windowNumber ?? 0
        lifecycleLogger.notice(
            "target selected generation=\(self.activeActionGeneration ?? 0, privacy: .public) type=\(target, privacy: .public) window=\(windowNumber, privacy: .public)"
        )
        #if SHADOW_SYNC_TESTING
        testLifecycleTrace.append(
            "target:\(target):\(windowNumber)"
        )
        #endif
    }

    private func foregroundCurrentSurface() {
        if let surface = currentOperatorSurface(
            for: .explicitInvocation
        ) {
            foreground(surface)
            return
        }
        if runWindow != nil {
            runWindow = nil
        }
        if canonicalRootWindow != nil {
            canonicalRootWindow = nil
        }
        if let historicalBody3Viewer {
            dismissHistoricalBody3Viewer(
                historicalBody3Viewer
            )
        }
        if historicalViewer != nil {
            historicalViewer = nil
        }
        startNewRun()
    }

    private func startNewRun() {
        if let surface = currentOperatorSurface(
            for: .explicitInvocation
        ) {
            switch surface.kind {
            case .contention:
                requestOperationContention(.startNewRun)
                foreground(surface)
                return
            case .body3Run:
                guard let controller = body3RunWindow,
                      controller.isTerminal,
                      controller.recoverySnapshot != nil,
                      closeLiveBody3Progress(controller) else {
                    foreground(surface)
                    return
                }
                rememberWindowFrame(controller.window)
                controller.close()
            case .historical:
                if let controller = historicalBody3Viewer {
                    dismissHistoricalBody3Viewer(controller)
                }
                if let controller = historicalViewer {
                    dismissHistoricalViewer(controller)
                }
            case .run:
                break
            default:
                foreground(surface)
                return
            }
        }
        if let runWindow {
            guard runWindow.prepareForNewRun() else {
                foreground(runWindow)
                return
            }
        }
        if inventoryDiscoveryInProgress {
            if authorityCommitSession != nil {
                presentAuthorityCommitBusy(on: nil)
            } else {
                requestInventoryPresentationWhileDiscoveryBusy()
            }
            return
        }
        var hasBody3Recovery = false
        switch body3RecoveryState() {
        case .notBody3:
            break
        case let .previous(recovered):
            hasBody3Recovery = true
            lastBody3Recovered = recovered
            updateTerminalReportNotice(
                needsAttention: recovered.requiresReview
            )
        case .operationStillActive:
            requestOperationContention(.startNewRun)
            return
        case .needsAttention:
            presentDiscoveryAlert(
                messageText:
                    "Previous protected cleanup needs attention",
                informativeText:
                    "The validated Body 3 event prefix could not be reconstructed safely. Review the latest log before trying again."
            )
            return
        }
        let recovery: RunRecoveryState =
            hasBody3Recovery ? .none : recoveryState()
        let recoveryDecision: LifecycleGateDecision
        switch recovery {
        case .none:
            recoveryDecision = recoveryReviewRequirement == nil
                ? lifecycleRouter.decideRecoveryStart(from: .none)
                : .block(.recoveryReview)
        case let .previousReport(recovered)
            where recovered.summaryOverride == InterruptedRunReconstructor.summary:
            let requirement = recoveryRequirement(for: recovered)
            let matches = requirement != nil
                && acknowledgedRecovery == requirement
                && (recoveryReviewRequirement == nil
                    || recoveryReviewRequirement == requirement)
            recoveryDecision = lifecycleRouter.decideRecoveryStart(
                from: .interruptedReport(acknowledgementMatches: matches)
            )
            if recoveryDecision != .allow {
                requireRecoveryReview(recovered)
            }
        case let .previousReport(recovered)
            where recovered.results.contains(where: { $0.code == .needsAttention }):
            recoveryDecision = .allow
            lastReport = recovered
            updateTerminalReportNotice(needsAttention: true)
        case .previousReport:
            recoveryDecision = recoveryReviewRequirement == nil
                ? lifecycleRouter.decideRecoveryStart(
                    from: .completedReport
                )
                : .block(.recoveryReview)
        case .operationStillActive:
            recoveryDecision = lifecycleRouter.decideRecoveryStart(
                from: .operationStillActive
            )
            requestOperationContention(.startNewRun)
        case .needsAttention:
            recoveryDecision = lifecycleRouter.decideRecoveryStart(
                from: .needsAttention
            )
            presentDiscoveryAlert(
                messageText: InterruptedRunReconstructor.summary,
                informativeText: "ShadowSync could not validate the previous run evidence. Open the latest log and resolve the safety condition before trying again."
            )
        }
        guard recoveryDecision == .allow else {
            if recoveryReviewRequirement != nil,
               case .none = recovery {
                enforceRecoveryReviewGate()
            } else if recoveryReviewRequirement != nil,
                      case .previousReport = recovery,
                      case .block(.recoveryReview) = recoveryDecision {
                enforceRecoveryReviewGate()
            }
            if let runWindow {
                foreground(runWindow)
            } else if let historicalBody3Viewer {
                foreground(historicalBody3Viewer)
            } else if let historicalViewer {
                foreground(historicalViewer)
            }
            return
        }
        if let runWindow {
            handleForegroundTargetDismissed(runWindow)
            lastReport = runWindow.report
            rememberWindowFrame(runWindow.window)
            runWindow.close()
            self.runWindow = nil
        }
        if let historicalViewer {
            dismissHistoricalViewer(historicalViewer)
        }
        if let historicalBody3Viewer {
            dismissHistoricalBody3Viewer(
                historicalBody3Viewer
            )
        }
        retainedSessionInventory = nil
        retainedSessionCapability = nil
        retainedSuccessfulCleanupInspectionRepositoryIDs = []
        activeSelectedScope = nil
        activeVerifiedCapability = nil
        pendingPlannedOperations = []
        if confirmationInProgress {
            clearConfirmationState()
        }
        #if !SHADOW_SYNC_TESTING
        presentRepositoryChooser()
        return
        #else
        do {
            let candidates = try discovery.discover()
            guard !candidates.isEmpty else {
                let presentation = RepositoryDiscoveryEmptyPresentation.noEligibleCandidate
                presentDiscoveryAlert(
                    messageText: presentation.messageText,
                    informativeText: presentation.informativeText
                )
                return
            }
            guard RepositoryOperatorPresentation.canPresent(candidates) else {
                presentDiscoveryAlert(
                    messageText: ShadowSyncPresentation.locationAttentionTitle,
                    informativeText: ShadowSyncPresentation.locationAttentionText
                )
                return
            }
            let controller = SelectionWindowController(candidates: candidates)
            configureSelectionCancellation(controller)
            controller.onReview = { [weak self, weak controller] selected in
                guard let self, let controller else {
                    return
                }
                self.review(selected: selected, selectionController: controller)
            }
            selectionWindow = controller
            foreground(controller)
        } catch {
            let presentation = RepositoryDiscoveryFailurePresentation.forError(error)
            presentDiscoveryAlert(
                messageText: presentation.messageText,
                informativeText: presentation.informativeText
            )
        }
        #endif
    }

    #if !SHADOW_SYNC_TESTING
    private func presentRepositoryChooser() {
        guard !CommandCustodian.hasRetainedWork else {
            presentDiscoveryAlert(messageText: "Previous work is still stopping.",
                informativeText: "Wait for cleanup before opening another repository operation.")
            return
        }
        let cancellation = CancellationToken()
        guard inventoryCancellation == nil else { return }
        inventoryCancellation = cancellation
        defer { if inventoryCancellation === cancellation { inventoryCancellation = nil } }
        do {
            chooserGeneration &+= 1
            let stateLocation = try stateLocationResolver()
            let store = try RepositorySelectionPreferenceStore.open(
                at: stateLocation
            )
            var preferences = store.snapshot()
            let authority = try RepositoryAuthorityStore.open(
                at: stateLocation
            ).snapshot()
            let pendingEntries = Array(
                pendingChooserSavedEntries ?? []
            )
            let catalog = try SelectedRepositoryScopeBinder.withProductionReadPhase(cancellation: cancellation) { binder in
                try binder.processFreeCatalog(
                    preferences: preferences.document,
                    canonicalLocators: binder.canonicalLocators(records: authority.usableRecords),
                    sessionEntries: pendingEntries,
                    generation: chooserGeneration
                )
            }
            let controller = RepositoryChooserWindowController(
                catalog: catalog,
                preferenceSnapshot: preferences,
                initialSavedEntries: pendingChooserSavedEntries
            )
            pendingChooserSavedEntries = nil
            let acknowledgement = pendingChooserAcknowledgement
            pendingChooserAcknowledgement = nil
            guard case let .accepted(generation) =
                    lifecycleRouter.showChooser(
                        controller: controller
                    ) else {
                return
            }
            activeSelectedScope = nil
            activeVerifiedCapability = nil
            controller.onContinue = {
                [weak self, weak controller] entries in
                guard let self, let controller,
                      self.selectionWindow === controller else {
                    return
                }
                self.continueRepositorySelection(
                    entries,
                    catalog: catalog.catalog,
                    generation: generation,
                    controller: controller
                )
            }
            controller.onSaveDefaults = {
                [weak self, weak controller] entries in
                guard let self, let controller,
                      self.selectionWindow === controller else {
                    return
                }
                self.saveRepositoryDefaults(
                    entries,
                    expected: preferences,
                    generation: generation,
                    controller: controller,
                    didSave: { snapshot in
                        preferences = snapshot
                    }
                )
            }
            controller.onRecoverDefaults = {
                [weak self, weak controller] entries in
                guard let self, let controller,
                      self.selectionWindow === controller else {
                    return
                }
                self.recoverRepositoryDefaults(
                    entries,
                    expected: preferences,
                    generation: generation,
                    controller: controller
                )
            }
            controller.onCanonicalRootChange = {
                [weak self, weak controller]
                candidate,
                alternative in
                guard let self, let controller,
                      self.selectionWindow === controller else {
                    return
                }
                self.changeCatalogCanonicalRoot(
                    candidate: candidate,
                    alternative: alternative,
                    preferences: preferences,
                    authority: authority,
                    controller: controller
                )
            }
            controller.onReload = {
                [weak self, weak controller] in
                guard let self, let controller,
                      self.selectionWindow === controller else {
                    return
                }
                self.pendingChooserSavedEntries = Set(
                    controller.savedEntriesSnapshot()
                )
                self.rememberWindowFrame(controller.window)
                self.handleForegroundTargetDismissed(controller)
                self.selectionWindow = nil
                controller.close()
                self.presentRepositoryChooser()
            }
            controller.onQuit = { [weak self] in
                guard let self else { return }
                self.closeCurrentChooserRun(
                    controller: controller,
                    generation: generation
                )
            }
            controller.onCancel = {
                [weak self, weak controller] in
                guard let self, let controller,
                      self.selectionWindow === controller else {
                    return
                }
                if self.inventoryDiscoveryInProgress,
                   case .accepted = self.lifecycleRouter.beginCancel(
                       generation: generation
                   ) {
                    self.pendingChooserSavedEntries = Set(
                        controller.savedEntriesSnapshot()
                    )
                    controller.acknowledgeCancellation()
                    self.inventoryCancellation?.cancel()
                    return
                }
                self.handleForegroundTargetDismissed(controller)
                self.selectionWindow = nil
            }
            selectionWindow = controller
            if let acknowledgement {
                controller.showSaveOutcome(acknowledgement)
            }
            restoreWindowFrame(controller.window)
            foreground(controller)
        } catch {
            presentDiscoveryAlert(
                messageText: "Repository chooser unavailable",
                informativeText: Redactor.sanitize(
                    String(describing: error)
                )
            )
        }
    }

    private func closeCurrentChooserRun(
        controller: RepositoryChooserWindowController,
        generation: UInt64
    ) {
        pendingChooserSavedEntries = Set(
            controller.savedEntriesSnapshot()
        )
        if inventoryDiscoveryInProgress {
            _ = lifecycleRouter.beginCancel(
                generation: generation
            )
            inventoryCancellation?.cancel()
        }
        handleForegroundTargetDismissed(controller)
        selectionWindow = nil
        controller.closeCurrentRunWindow()
    }

    private func changeCatalogCanonicalRoot(
        candidate: RepositorySelectionCandidate,
        alternative: RepositorySelectionAlternative,
        preferences: RepositorySelectionPreferenceSnapshot,
        authority: RepositoryAuthoritySnapshot,
        controller: RepositoryChooserWindowController
    ) {
        guard !CommandCustodian.hasRetainedWork else {
            controller.showSaveOutcome("Previous work is still stopping. Wait for cleanup before continuing.")
            return
        }

        var selected = Set(controller.savedEntriesSnapshot())
        if controller.selectedRepositoryIDsSnapshot().contains(
            candidate.id
        ),
        let replacement = try? RepositorySelectionPreferenceEntry(
            repositoryID: candidate.id,
            locator: alternative.locator
        ) {
            selected.insert(replacement)
        }
        let generation = chooserGeneration
        let cancellation = CancellationToken()
        guard inventoryCancellation == nil else { return }
        inventoryCancellation = cancellation
        let task = Task.detached {
            let state = try StateLocation.production()
            let mutation = try RunAuthority.acquireRun(at: state)
            defer { mutation.release() }
            return try SelectedRepositoryScopeBinder.withProductionPhase(borrowing: mutation, cancellation: cancellation) { binder in
                let freshAuthority = try RepositoryAuthorityStore.open(
                    at: state
                ).snapshot()
                guard freshAuthority.fileIdentity
                        == authority.fileIdentity else {
                    throw RepositoryAuthorityStoreError.changed
                }
                let fresh = try binder.processFreeCatalog(
                    preferences: preferences.document,
                    canonicalLocators: binder.canonicalLocators(
                        records: freshAuthority.usableRecords
                    ),
                    generation: generation
                )
                if fresh.degradedReason == .cleanupPending { throw SelectedRepositoryScopeError.cleanupPending }
                guard let row = fresh.catalog.candidates.first(where: {
                    $0.id == candidate.id
                }),
                let verified = row.alternatives.first(where: {
                    $0 == alternative
                }),
                let path = binder.canonicalRootPath(
                    for: verified.locator
                ) else {
                    throw RepositoryAuthorityStoreError.invalidSelection
                }
                return try RepositoryAuthorityStore.open(
                    at: state
                ).confirmCatalogCanonicalRoot(
                    repositoryID: candidate.id,
                    canonicalRoot: path,
                    rootIdentity: verified.repositoryIdentity,
                    commonDirectoryIdentity:
                        verified.commonDirectoryIdentity,
                    rawOrigin: verified.rawOrigin,
                    expectedFileIdentity:
                        freshAuthority.fileIdentity
                )
            }
        }
        Task { @MainActor [weak self, weak controller] in
            let result = await task.result
            if let self, self.inventoryCancellation === cancellation { self.inventoryCancellation = nil }
            guard let self, let controller,
                  self.selectionWindow === controller else {
                return
            }
            switch result {
            case .success:
                self.pendingChooserSavedEntries = selected
                self.handleForegroundTargetDismissed(controller)
                self.selectionWindow = nil
                controller.close()
                self.presentRepositoryChooser()
            case let .failure(error):
                controller.showSaveOutcome(
                    "Canonical root was not changed: "
                        + Redactor.sanitize(
                            String(describing: error)
                        )
                )
            }
        }
    }

    private func continueRepositorySelection(
        _ entries: [RepositorySelectionPreferenceEntry],
        catalog: RepositorySelectionCatalog,
        generation: UInt64,
        controller: RepositoryChooserWindowController
    ) {
        guard !CommandCustodian.hasRetainedWork else {
            controller.showSaveOutcome("Previous work is still stopping. Wait for cleanup before continuing.")
            return
        }

        guard case .accepted =
                lifecycleRouter.beginContinue(
                    generation: generation,
                    controller: controller,
                    selectedRepositoryIDs: Set(
                        entries.map(\.repositoryID)
                    )
                ) else {
            return
        }
        pendingPlannedOperations = []
        if confirmationInProgress {
            clearConfirmationState()
        }
        let intent: RepositorySelectionIntent
        do {
            intent = try RepositorySelectionIntent(
                catalog: catalog,
                entries: entries.sorted()
            )
        } catch {
            let route = lifecycleRouter.settleHydrationFailure(
                generation: generation,
                controller: controller,
                evidence: .noWork(generation: generation)
            )
            if case .terminate = route {
                terminateAfterConfirmedQuit()
                return
            }
            guard case .accepted = route else {
                return
            }
            controller.reopenAdmission(
                message:
                    "Selected repositories changed. "
                    + "Reload before continuing."
            )
            return
        }
        let executablePath = self.executablePath
        let retainedInventory = retainedSessionInventory
        let retainedCapability =
            retainedSessionCapability
        let cancellation = CancellationToken()
        let drainTracker = SelectedHydrationDrainTracker()
        inventoryCancellation = cancellation
        inventoryDiscoveryInProgress = true
        let progressObserver: @Sendable (
            RepositoryInventoryLifecycleEvent
        ) -> Void = { [weak self, weak controller] event in
            drainTracker.observe(event)
            let update: (
                completed: Int,
                total: Int,
                repositoryID: String,
                phase: String
            )
            switch event {
            case let .repositoryProgress(
                completed, total, repositoryID, phase
            ):
                update = (
                    completed, total, repositoryID, phase
                )
            case let .repositoryStarted(
                completed, total, repositoryID
            ):
                update = (
                    completed, total, repositoryID, "Inspecting"
                )
            default:
                return
            }
            Task { @MainActor in
                guard let self, let controller,
                      self.selectionWindow === controller,
                      self.lifecycleRouter.phase.generation
                        == generation else {
                    return
                }
                controller.showHydrationProgress(
                    completed: update.completed,
                    total: update.total,
                    repositoryID: update.repositoryID,
                    phase: update.phase
                )
            }
        }
        let task = Task.detached(
            priority: .userInitiated
        ) {
            let scope: ValidatedSelectedRepositoryScope
            do {
                scope = try SelectedRepositoryScopeBinder.withProductionReadPhase(cancellation: cancellation) { binder in
                    try binder.bind(intent: intent)
                }
            } catch SelectedRepositoryScopeError.cleanupPending {
                drainTracker.markCustodyPending()
                throw SelectedRepositoryScopeError.cleanupPending
            }
            drainTracker.markHydrationStarted()
            let hydrator = SelectedRepositoryHydrator(
                executablePath: executablePath,
                cancellation: cancellation,
                lifecycleObserver: progressObserver
            )
            return try hydrator.reconcileSession(
                scope: scope,
                retainedInventory: retainedInventory,
                retainedCapability: retainedCapability
            )
        }
        _ = lifecycleRouter.enterHydration(generation: generation)
        Task { @MainActor [weak self, weak controller] in
            let result = await task.result
            guard let self else { return }
            self.inventoryDiscoveryInProgress = false
            self.inventoryCancellation = nil
            let drainEvidence =
                drainTracker.evidenceAfterTaskCompletion(
                    generation: generation
                )
            let hydrationWasSettled =
                drainEvidence.allChildrenReaped
                && drainEvidence.inventoryAuthorityReleased
                && drainEvidence.transactionsSettled
            guard self.lifecycleRouter.phase.generation == generation else {
                return
            }
            let cancelled =
                self.lifecycleRouter.phase.kind == .cancelling
            if cancelled
                || self.lifecycleRouter.phase.kind == .drainingForQuit {
                let route = self.lifecycleRouter.settleHydrationFailure(
                    generation: generation,
                    controller: controller,
                    evidence: drainEvidence
                )
                if case .terminate = route {
                    self.terminateAfterConfirmedQuit()
                } else if case let .quitPaused(missing) = route,
                          let controller,
                          self.selectionWindow === controller {
                    if cancelled {
                        controller.showCancellationDrainBlocked(missing)
                    } else {
                        controller.showQuitDrainBlocked(missing)
                    }
                } else if case .accepted = route,
                          let controller,
                          self.selectionWindow === controller {
                    if cancelled {
                        controller.reopenAdmission(
                            message:
                                "Cancelled. Safe cleanup completed; selections were preserved."
                        )
                    }
                }
                return
            }
            guard hydrationWasSettled else {
                let route = self.lifecycleRouter.settleHydrationFailure(
                    generation: generation,
                    controller: controller,
                    evidence: drainEvidence
                )
                if case .terminate = route {
                    self.terminateAfterConfirmedQuit()
                } else if case let .quitPaused(missing) = route {
                    controller?.showHydrationDrainBlocked(missing)
                } else if case .accepted = route {
                    controller?.reopenAdmission(
                        message:
                            "Selected hydration stopped because "
                            + "owned work could not be proven settled."
                    )
                }
                return
            }
            switch result {
            case let .success(.onboarding(scope, inventory)):
                self.activeSelectedScope = scope
                let reusable =
                    SelectedRepositoryHydrator.sessionDelta(
                        scope: scope,
                        retainedScope:
                            retainedCapability?.scope,
                        retainedRepositoryIDs: Set(
                            retainedInventory?.cards.map(\.id)
                                ?? []
                        )
                    ).reusableRepositoryIDs
                self.retainedSuccessfulCleanupInspectionRepositoryIDs
                    .formIntersection(reusable)
                let route = self.lifecycleRouter.enterOnboarding(
                    generation: generation
                )
                if case .terminate = route {
                    self.terminateAfterConfirmedQuit()
                    return
                }
                self.stageCanonicalRootOnboarding(
                    inventory,
                    generation: generation,
                    foregroundResult: true
                )
            case let .success(.verified(verified)):
                self.activeSelectedScope =
                    verified.capability.scope
                self.activeVerifiedCapability =
                    verified.capability
                self.retainedSessionInventory =
                    verified.inventory
                self.retainedSessionCapability =
                    verified.capability
                let reusable =
                    SelectedRepositoryHydrator.sessionDelta(
                        scope: verified.capability.scope,
                        retainedScope:
                            retainedCapability?.scope,
                        retainedRepositoryIDs: Set(
                            retainedInventory?.cards.map(\.id)
                                ?? []
                        )
                    ).reusableRepositoryIDs
                self.retainedSuccessfulCleanupInspectionRepositoryIDs
                    .formIntersection(reusable)
                let route = self.lifecycleRouter.enterCards(
                    generation: generation
                )
                if case .terminate = route {
                    self.terminateAfterConfirmedQuit()
                    return
                }
                if let controller,
                   self.selectionWindow === controller {
                    self.handleForegroundTargetDismissed(controller)
                    self.selectionWindow = nil
                    controller.close()
                }
                self.presentRepositoryInventory(
                    verified.inventory,
                    allowOnboarding: false,
                    generation: generation
                )
            case let .failure(error):
                guard let controller,
                      self.selectionWindow === controller else {
                    return
                }
                let route = self.lifecycleRouter.settleHydrationFailure(
                    generation: generation,
                    controller: controller,
                    evidence: drainEvidence
                )
                if case .terminate = route {
                    self.terminateAfterConfirmedQuit()
                } else if case let .quitPaused(missing) = route {
                    controller.showHydrationDrainBlocked(missing)
                } else if case .accepted = route {
                    let refresh: Bool
                    if let scopeError =
                            error as? SelectedRepositoryScopeError {
                        switch scopeError {
                        case .changed, .unknown, .ambiguous,
                             .forbidden:
                            refresh = true
                        case .invalidIntent, .policyUnavailable, .cleanupPending,
                             .catalogDegraded, .unsafeTraversal:
                            refresh = false
                        }
                    } else {
                        refresh = false
                    }
                    if refresh {
                        self.pendingChooserSavedEntries = Set(
                            controller.savedEntriesSnapshot()
                        )
                        self.pendingChooserAcknowledgement =
                            "Repository inventory changed. Unaffected selections were preserved; review unavailable or changed rows."
                        self.handleForegroundTargetDismissed(
                            controller
                        )
                        self.selectionWindow = nil
                        controller.close()
                        self.presentRepositoryChooser()
                    } else {
                        controller.reopenAdmission(
                            message:
                                "Selected hydration stopped safely: "
                                + Redactor.sanitize(
                                    String(describing: error)
                                )
                        )
                    }
                }
            }
        }
    }

    private func saveRepositoryDefaults(
        _ entries: [RepositorySelectionPreferenceEntry],
        expected: RepositorySelectionPreferenceSnapshot,
        generation: UInt64,
        controller: RepositoryChooserWindowController,
        didSave:
            @escaping (RepositorySelectionPreferenceSnapshot) -> Void
    ) {
        guard case .accepted = lifecycleRouter.beginSave(
            generation: generation,
            controller: controller
        ) else {
            return
        }
        let location: StateLocation
        do {
            location = try stateLocationResolver()
        } catch {
            _ = lifecycleRouter.completeSave(
                generation: generation,
                renameLinearized: false,
                controller: controller
            )
            controller.showSaveOutcome("Defaults were not saved.")
            return
        }
        let task = Task.detached {
            let store = try RepositorySelectionPreferenceStore.open(
                at: location
            )
            let outcome = try store.save(
                entries: entries,
                expected: expected
            )
            return (outcome, store.snapshot())
        }
        Task { @MainActor [weak self, weak controller] in
            let result = await task.result
            guard let self else { return }
            let linearized: Bool
            switch result {
            case .success:
                linearized = true
            case .failure:
                linearized = false
            }
            let route = self.lifecycleRouter.completeSave(
                generation: generation,
                renameLinearized: linearized,
                controller: controller
            )
            if case .terminate = route {
                self.terminateAfterConfirmedQuit()
                return
            }
            guard let controller,
                  self.selectionWindow === controller else {
                return
            }
            switch result {
            case let .success((.saved, snapshot)):
                didSave(snapshot)
                controller.showSaveOutcome("Defaults saved.")
            case .success((.durabilityUncertain, _)):
                controller.showSaveOutcome(
                    "Defaults saved; durability confirmation needs reload.",
                    blocksSave: true
                )
            case let .failure(error):
                controller.showSaveOutcome(
                    "Defaults were not saved: "
                        + Redactor.sanitize(
                            String(describing: error)
                        )
                )
            }
        }
    }

    private func recoverRepositoryDefaults(
        _ entries: [RepositorySelectionPreferenceEntry],
        expected: RepositorySelectionPreferenceSnapshot,
        generation: UInt64,
        controller: RepositoryChooserWindowController
    ) {
        guard expected.status == .malformed,
              case .accepted = lifecycleRouter.beginSave(
                  generation: generation,
                  controller: controller
              ) else {
            return
        }
        let location: StateLocation
        do {
            location = try stateLocationResolver()
        } catch {
            _ = lifecycleRouter.completeSave(
                generation: generation,
                renameLinearized: false,
                controller: controller
            )
            controller.showSaveOutcome("Defaults were not recovered.")
            return
        }
        let task = Task.detached {
            try RepositorySelectionPreferenceStore.open(
                at: location
            ).recover(entries: entries, expected: expected)
        }
        Task { @MainActor [weak self, weak controller] in
            let result = await task.result
            guard let self else { return }
            let route = self.lifecycleRouter.completeSave(
                generation: generation,
                renameLinearized: {
                    if case .success = result { return true }
                    return false
                }(),
                controller: controller
            )
            if case .terminate = route {
                self.terminateAfterConfirmedQuit()
                return
            }
            guard let controller,
                  self.selectionWindow === controller else {
                return
            }
            switch result {
            case .success:
                self.pendingChooserAcknowledgement =
                    "Defaults recovered."
                self.handleForegroundTargetDismissed(controller)
                self.selectionWindow = nil
                controller.close()
                self.presentRepositoryChooser()
            case let .failure(error):
                controller.showSaveOutcome(
                    "Defaults were not recovered: "
                        + Redactor.sanitize(
                            String(describing: error)
                        )
                )
            }
        }
    }
    #endif

    private func beginRepositoryInventoryDiscovery(
        presentResult: Bool
    ) -> InventoryBeginFailureReason? {
        #if SHADOW_SYNC_TESTING
        if testingInventoryBeginFailure != nil {
            return .injected
        }
        #endif
        guard !inventoryDiscoveryInProgress else {
            if presentResult {
                if authorityCommitSession != nil {
                    presentAuthorityCommitBusy(on: nil)
                } else {
                    requestInventoryPresentationWhileDiscoveryBusy()
                }
            }
            return authorityCommitSession == nil
                ? .discoveryBusy : .authorityCommitBusy
        }
        inventoryDiscoveryInProgress = true
        inventoryPresentationRequested = presentResult
        #if SHADOW_SYNC_TESTING
        testInventoryDiscoveryStartCount += 1
        #endif
        return nil
    }

    private func resolveRepositoryInventoryBeginFailure(
        generation: UInt64,
        loadingController:
            RepositoryCardSelectionWindowController?,
        reason: InventoryBeginFailureReason
    ) {
        guard activeInventoryGeneration == generation else { return }
        inventoryCancellation?.closeFutureChildAdmissions()
        inventoryCancellation = nil
        activeInventoryGeneration = nil
        lifecycleLogger.error(
            "inventory_begin_failed generation=\(generation, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        #if SHADOW_SYNC_TESTING
        testLifecycleTrace.append(
            "inventory:begin_failed:\(generation):\(reason.rawValue)"
        )
        #endif
        if lifecycleRouter.deferredQuit {
            if let loadingController,
               selectionWindow === loadingController {
                handleForegroundTargetDismissed(loadingController)
                selectionWindow = nil
                loadingController.close()
            }
            terminateAfterConfirmedQuit()
            return
        }
        guard let loadingController,
              selectionWindow === loadingController else {
            return
        }
        let shouldForeground =
            loadingController.window?.isVisible == true
        loadingController.showInventoryFailure(
            "Repository inventory failed. Try again."
        )
        if shouldForeground {
            foreground(loadingController)
        }
    }

    private func finishRepositoryInventoryDiscovery() -> Bool {
        guard inventoryDiscoveryInProgress,
              authorityCommitSession == nil else {
            return false
        }
        inventoryDiscoveryInProgress = false
        let shouldPresent = inventoryPresentationRequested
        inventoryPresentationRequested = false
        return shouldPresent
    }

    private func requestInventoryPresentationWhileDiscoveryBusy() {
        if let controller =
                selectionWindow as? RepositoryCardSelectionWindowController {
            controller.prepareForRedisplay()
            foreground(controller)
            return
        }
        guard !inventoryPresentationRequested else {
            return
        }
        inventoryPresentationRequested = true
        #if SHADOW_SYNC_TESTING
        testInventoryDiscoveryBusyPresentationCount += 1
        #endif
        presentDiscoveryAlert(
            messageText: "Repository scan in progress",
            informativeText:
                "ShadowSync is already refreshing repository state. The normal repository selection will appear when it finishes."
        )
    }

    #if !SHADOW_SYNC_TESTING
    private func configureRepositoryCardController(
        _ controller: RepositoryCardSelectionWindowController,
        inventory: RepositoryInventory?,
        allowOnboarding: Bool
    ) {
        configureSelectionCancellation(controller)
        controller.onRetryInventory = {
            [weak self, weak controller] in
            guard let self, let controller,
                  self.selectionWindow === controller,
                  !self.inventoryDiscoveryInProgress else {
                return
            }
            controller.showPreparingRepositoryList()
            self.startRepositoryInventoryDiscovery(
                allowOnboarding: allowOnboarding,
                presentResult: true
            )
        }
        controller.onReviewOperations = nil
        controller.onReviewBatch = nil
        controller.onChooseCanonicalRoot = nil
        controller.onInspectCleanup = nil
        controller.onManageSelection = {
            [weak self, weak controller] in
            guard let self, let controller,
                  self.selectionWindow === controller else {
                return
            }
            self.handleForegroundTargetDismissed(controller)
            self.rememberWindowFrame(controller.window)
            if let capability =
                    self.activeVerifiedCapability {
                self.retainedSessionInventory =
                    controller.inventorySnapshot
                self.retainedSessionCapability =
                    capability
                self.retainedSuccessfulCleanupInspectionRepositoryIDs =
                    controller
                        .successfulCleanupInspectionRepositoryIDs
            }
            self.pendingPlannedOperations = []
            if self.confirmationInProgress {
                self.clearConfirmationState()
            }
            self.selectionWindow = nil
            controller.close()
            self.activeSelectedScope = nil
            self.activeVerifiedCapability = nil
            self.presentRepositoryChooser()
        }
        guard let inventory else { return }
        controller.onInspectCleanup = {
            [weak self, weak controller] repositoryIDs in
            guard let self, let controller,
                  self.selectionWindow === controller,
                  let capability =
                    self.activeVerifiedCapability,
                  self.beginRepositoryInventoryDiscovery(
                    presentResult: false
                  ) == nil else {
                return
            }
            let base = controller.inventorySnapshot
            let cancellation = CancellationToken()
            self.inventoryCancellation = cancellation
            controller.beginCleanupInspection(
                repositoryIDs: repositoryIDs
            )
            let executablePath = self.executablePath
            let logger = self.lifecycleLogger
            let progressRelay =
                CleanupInspectionProgressRelay(
                    controller: controller
                )
            let observer: @Sendable (
                RepositoryInventoryLifecycleEvent
            ) -> Void = { event in
                guard case let .cleanupProgress(progress) =
                        event else {
                    return
                }
                logger.notice(
                    "cleanup_inspection stage=\(progress.stage.rawValue, privacy: .public) repository_completed=\(progress.repositoryCompleted, privacy: .public) repository_total=\(progress.repositoryTotal, privacy: .public) completed=\(progress.completed, privacy: .public) total=\(progress.total, privacy: .public) active_children=\(progress.activeChildren, privacy: .public) max_children=\(progress.maximumActiveChildren, privacy: .public) partial=\(progress.partialCount, privacy: .public) duration_ms=\(progress.durationMilliseconds, privacy: .public) heartbeat=\(progress.heartbeat, privacy: .public)"
                )
                progressRelay.publish(progress)
            }
            let task = Task.detached(
                priority: .userInitiated
            ) {
                let discovery =
                    try RepositoryInventoryDiscovery(
                        executablePath: executablePath,
                        cancellation: cancellation,
                        lifecycleObserver: observer
                    )
                return try discovery.inspectCleanup(
                    inventory: base,
                    repositoryIDs: repositoryIDs,
                    capability: capability
                )
            }
            Task { @MainActor [weak self, weak controller] in
                let result = await task.result
                guard let self else { return }
                _ = self.finishRepositoryInventoryDiscovery()
                self.inventoryCancellation = nil
                guard let controller,
                      self.selectionWindow === controller else {
                    return
                }
                switch result {
                case let .success(updated):
                    controller.applyCleanupInspection(
                        inventory: updated,
                        repositoryIDs: repositoryIDs
                    )
                    self.retainedSessionInventory =
                        updated
                    self.retainedSessionCapability =
                        capability
                    self.retainedSuccessfulCleanupInspectionRepositoryIDs =
                        controller
                            .successfulCleanupInspectionRepositoryIDs
                case let .failure(error):
                    controller.failCleanupInspection(
                        repositoryIDs: repositoryIDs,
                        message: Redactor.sanitize(
                            String(describing: error)
                        )
                    )
                }
            }
        }
        controller.onReviewOperations = {
            [weak self, weak controller] operations in
            guard let self, let controller,
                  let capability =
                    self.activeVerifiedCapability,
                  operations.allSatisfy(
                    capability.admits
                  ) else {
                return
            }
            self.pendingPlannedOperations = operations
            self.review(
                selected: operations.map {
                    $0.target.canonicalClone.sourceSnapshot
                },
                selectionController: controller
            )
        }
        controller.onReviewBatch = {
            [weak self, weak controller]
            operations, removals in
            guard let self, let controller,
                  let capability =
                    self.activeVerifiedCapability,
                  operations.allSatisfy(
                    capability.admits
                  ),
                  Set(removals.map {
                      $0.candidate.repository.id
                  }).isSubset(
                      of: capability.verifiedRepositoryIDs
                  ) else {
                return
            }
            if operations.isEmpty {
                self.prepareBody3Batch(
                    operations: operations,
                    removals: removals,
                    selectionController: controller
                )
            } else {
                self.pendingPlannedOperations = operations
                self.review(
                    selected: operations.map {
                        $0.target.canonicalClone.sourceSnapshot
                    },
                    selectionController: controller
                ) { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.prepareBody3Batch(
                        operations: operations,
                        removals: removals,
                        selectionController: controller
                    )
                }
            }
        }
        controller.onChooseCanonicalRoot = {
            [weak self, weak controller] card, clone in
            guard let self, let controller else { return }
            self.confirmCanonicalRoot(
                card: card,
                clone: clone,
                inventory: inventory,
                selectionController: controller
            )
        }
    }

    private func startRepositoryInventoryDiscovery(
        allowOnboarding: Bool = true,
        presentResult: Bool = true
    ) {
        guard let selectedScope = activeSelectedScope else {
            if presentResult {
                presentRepositoryChooser()
            }
            return
        }
        if inventoryDiscoveryInProgress {
            if presentResult {
                requestInventoryPresentationWhileDiscoveryBusy()
            }
            return
        }
        inventoryGeneration &+= 1
        let generation = inventoryGeneration
        activeInventoryGeneration = generation
        let cancellation = CancellationToken()
        inventoryCancellation = cancellation
        let action = activeActionGeneration ?? 0
        lifecycleLogger.notice(
            "inventory requested generation=\(generation, privacy: .public) action_generation=\(action, privacy: .public)"
        )
        #if SHADOW_SYNC_TESTING
        testLifecycleTrace.append("inventory:requested:\(generation)")
        #endif
        var loadingController: RepositoryCardSelectionWindowController?
        if presentResult {
            let controller: RepositoryCardSelectionWindowController
            if let current =
                    selectionWindow
                        as? RepositoryCardSelectionWindowController,
               current.isPresentationOpen {
                controller = current
                configureRepositoryCardController(
                    controller,
                    inventory: nil,
                    allowOnboarding: allowOnboarding
                )
                controller.showPreparingRepositoryList()
            } else {
                self.rememberWindowFrame(
                    self.selectionWindow?.window
                )
                controller = RepositoryCardSelectionWindowController()
                configureRepositoryCardController(
                    controller,
                    inventory: nil,
                    allowOnboarding: allowOnboarding
                )
                selectionWindow = controller
                self.restoreWindowFrame(controller.window)
            }
            loadingController = controller
            foreground(controller)
            lifecycleLogger.notice(
                "inventory surface_presented generation=\(generation, privacy: .public) window=\(controller.window?.windowNumber ?? 0, privacy: .public)"
            )
            #if SHADOW_SYNC_TESTING
            testLifecycleTrace.append("inventory:surface_presented:\(generation)")
            #endif
        }
        if let reason = beginRepositoryInventoryDiscovery(
            presentResult: presentResult
        ) {
            resolveRepositoryInventoryBeginFailure(
                generation: generation,
                loadingController: loadingController,
                reason: reason
            )
            return
        }
        let executablePath = self.executablePath
        let logger = lifecycleLogger
        let observer: @Sendable (
            RepositoryInventoryLifecycleEvent
        ) -> Void = { event in
            switch event {
            case .authorityAcquired:
                logger.notice(
                    "inventory authority_acquired generation=\(generation, privacy: .public) lock=owned"
                )
            case let .repositoryStarted(completed, total, repositoryID):
                logger.notice(
                    "inventory repository generation=\(generation, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public) repository=\(repositoryID, privacy: .private(mask: .hash))"
                )
            case let .repositoryProgress(
                completed, total, repositoryID, phase
            ):
                logger.notice(
                    "inventory repository generation=\(generation, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public) phase=\(phase, privacy: .public) repository=\(repositoryID, privacy: .private(mask: .hash))"
                )
            case let .childStarted(count, phase):
                logger.notice(
                    "inventory child generation=\(generation, privacy: .public) count=\(count, privacy: .public) phase=\(phase, privacy: .public)"
                )
            case let .cleanupProgress(progress):
                logger.notice(
                    "inventory cleanup generation=\(generation, privacy: .public) stage=\(progress.stage.rawValue, privacy: .public) repository_completed=\(progress.repositoryCompleted, privacy: .public) repository_total=\(progress.repositoryTotal, privacy: .public) completed=\(progress.completed, privacy: .public) total=\(progress.total, privacy: .public) active_children=\(progress.activeChildren, privacy: .public) max_children=\(progress.maximumActiveChildren, privacy: .public) partial=\(progress.partialCount, privacy: .public) duration_ms=\(progress.durationMilliseconds, privacy: .public) heartbeat=\(progress.heartbeat, privacy: .public)"
                )
            case let .finished(childCount):
                logger.notice(
                    "inventory finished generation=\(generation, privacy: .public) child_count=\(childCount, privacy: .public)"
                )
            case let .failed(childCount):
                logger.error(
                    "inventory failed generation=\(generation, privacy: .public) child_count=\(childCount, privacy: .public)"
                )
            case let .cancelled(childCount):
                logger.notice(
                    "inventory cancelled generation=\(generation, privacy: .public) child_count=\(childCount, privacy: .public)"
                )
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            let discovery = try RepositoryInventoryDiscovery(
                executablePath: executablePath,
                cancellation: cancellation,
                lifecycleObserver: observer
            )
            return try discovery.discoverInventory(
                scope: selectedScope
            )
        }
        Task { @MainActor [weak self] in
            let result = await task.result
            guard let self else { return }
            guard self.activeInventoryGeneration == generation else {
                return
            }
            let shouldPresent = self.finishRepositoryInventoryDiscovery()
            self.inventoryCancellation = nil
            self.activeInventoryGeneration = nil
            let shouldForegroundResult =
                loadingController?.window?.isVisible == true
            if self.lifecycleRouter.deferredQuit {
                if let loadingController,
                   self.selectionWindow === loadingController {
                    self.handleForegroundTargetDismissed(loadingController)
                    self.selectionWindow = nil
                    loadingController.close()
                }
                self.terminateAfterConfirmedQuit()
                return
            }
            if shouldPresent,
               let loadingController,
               self.selectionWindow !== loadingController {
                return
            }
            switch result {
            case let .success(inventory):
                guard shouldPresent else { return }
                if inventory.onboardingProposals.isEmpty {
                    guard let verified = try?
                            SelectedRepositoryHydrator
                                .verifyFreshInventory(
                                    scope: selectedScope,
                                    inventory: inventory
                                ) else {
                        loadingController?.showInventoryFailure(
                            "Selected repository authority changed. Reload the chooser."
                        )
                        self.activeVerifiedCapability = nil
                        return
                    }
                    self.activeVerifiedCapability =
                        verified.capability
                } else {
                    self.activeVerifiedCapability = nil
                }
                self.presentRepositoryInventory(
                    inventory,
                    allowOnboarding: allowOnboarding,
                    foregroundResult: shouldForegroundResult,
                    generation: generation
                )
            case let .failure(error):
                guard shouldPresent else { return }
                let presentation =
                    RepositoryDiscoveryFailurePresentation.forError(error)
                if let loadingController,
                   self.selectionWindow === loadingController {
                    loadingController.showInventoryFailure(
                        "\(presentation.messageText) \(presentation.informativeText)"
                    )
                    if shouldForegroundResult {
                        self.foreground(loadingController)
                    }
                } else if loadingController == nil {
                    self.presentDiscoveryAlert(
                        messageText: presentation.messageText,
                        informativeText: presentation.informativeText
                    )
                }
            }
        }
    }

    private func presentRepositoryInventory(
        _ inventory: RepositoryInventory,
        allowOnboarding: Bool,
        foregroundResult: Bool = true,
        generation: UInt64? = nil
    ) {
        guard !inventory.cards.isEmpty else {
            let presentation =
                RepositoryDiscoveryEmptyPresentation.noEligibleCandidate
            if let controller =
                    selectionWindow
                        as? RepositoryCardSelectionWindowController,
               controller.isPreparingRepositoryList {
                controller.showInventoryFailure(
                    "\(presentation.messageText) \(presentation.informativeText)"
                )
                if foregroundResult {
                    foreground(controller)
                }
            } else {
                presentDiscoveryAlert(
                    messageText: presentation.messageText,
                    informativeText: presentation.informativeText
                )
            }
            return
        }
        if allowOnboarding,
           !inventory.onboardingProposals.isEmpty {
            guard let generation else {
                return
            }
            stageCanonicalRootOnboarding(
                inventory,
                generation: generation,
                foregroundResult: foregroundResult
            )
            return
        }
        if allowOnboarding,
           let generation,
           let pending = pendingCanonicalRootOnboarding,
           pending.generation <= generation {
            pendingCanonicalRootOnboarding = nil
        }
        prepareRepositoryInventoryPresentation()
        let protection =
            RepositoryCleanupProtection.resolve(
                executablePath: executablePath,
                stateLocation: stateLocationResolver
            )
        #if SHADOW_SYNC_TESTING
        let capability = activeVerifiedCapability
        #else
        guard let capability = activeVerifiedCapability,
              capability.admits(inventory) else {
            presentDiscoveryAlert(
                messageText: "Repository authority changed",
                informativeText:
                    "Reload the repository chooser before reviewing repository operations."
            )
            return
        }
        #endif
        let controller: RepositoryCardSelectionWindowController
        if let loading =
                selectionWindow
                    as? RepositoryCardSelectionWindowController,
           loading.isPreparingRepositoryList {
            #if SHADOW_SYNC_TESTING
            let didApply: Bool
            if let capability {
                didApply = loading.apply(
                    inventory: inventory,
                    capability: capability,
                    protectedPaths: protection.protectedPaths,
                    protectionBoundaryEstablished:
                        protection.boundaryEstablished
                )
            } else {
                didApply = loading.apply(
                    inventory: inventory,
                    protectedPaths: protection.protectedPaths,
                    protectionBoundaryEstablished:
                        protection.boundaryEstablished
                )
            }
            #else
            let didApply = loading.apply(
                inventory: inventory,
                capability: capability,
                protectedPaths: protection.protectedPaths,
                protectionBoundaryEstablished:
                    protection.boundaryEstablished
            )
            #endif
            if didApply {
                controller = loading
            } else {
                #if SHADOW_SYNC_TESTING
                if let capability {
                    controller = RepositoryCardSelectionWindowController(
                        inventory: inventory,
                        capability: capability,
                        protectedPaths: protection.protectedPaths,
                        protectionBoundaryEstablished:
                            protection.boundaryEstablished
                    )
                } else {
                    controller = RepositoryCardSelectionWindowController(
                        inventory: inventory,
                        protectedPaths: protection.protectedPaths,
                        protectionBoundaryEstablished:
                            protection.boundaryEstablished
                    )
                }
                #else
                controller = RepositoryCardSelectionWindowController(
                    inventory: inventory,
                    capability: capability,
                    protectedPaths: protection.protectedPaths,
                    protectionBoundaryEstablished:
                        protection.boundaryEstablished
                )
                #endif
            }
        } else {
            #if SHADOW_SYNC_TESTING
            if let capability {
                controller = RepositoryCardSelectionWindowController(
                    inventory: inventory,
                    capability: capability,
                    protectedPaths: protection.protectedPaths,
                    protectionBoundaryEstablished:
                        protection.boundaryEstablished
                )
            } else {
                controller = RepositoryCardSelectionWindowController(
                    inventory: inventory,
                    protectedPaths: protection.protectedPaths,
                    protectionBoundaryEstablished:
                        protection.boundaryEstablished
                )
            }
            #else
            controller = RepositoryCardSelectionWindowController(
                inventory: inventory,
                capability: capability,
                protectedPaths: protection.protectedPaths,
                protectionBoundaryEstablished:
                    protection.boundaryEstablished
            )
            #endif
        }
        controller.restoreSuccessfulCleanupInspections(
            retainedSuccessfulCleanupInspectionRepositoryIDs
        )
        configureRepositoryCardController(
            controller,
            inventory: inventory,
            allowOnboarding: allowOnboarding
        )
        selectionWindow = controller
        if foregroundResult {
            foreground(controller)
        }
    }

    private func prepareBody3Batch(
        operations: [PlannedOperation],
        removals: [RemovalSelection],
        selectionController: SelectionWindowController
    ) {
        guard body3RunWindow == nil,
              !operations.isEmpty
                || !removals.isEmpty else { return }
        let run = RunIdentity.make()
        let plan: Body3BatchPlan
        let location: StateLocation
        do {
            let role: GovernedRootRole
            #if SHADOW_SYNC_TESTING
            role = try activeVerifiedCapability?.scope.requireGovernedRootRole() ?? .testing()
            #else
            guard let capability = activeVerifiedCapability else {
                throw SelectedRepositoryScopeError.policyUnavailable
            }
            role = try capability.scope.requireGovernedRootRole()
            #endif
            plan = try Body3BatchPlanner.make(
                run: run,
                operations: operations,
                removals: removals,
                governedRoot: role
            )
            location = try logLocation()
        } catch {
            presentDiscoveryAlert(
                messageText:
                    "Cleanup plan could not be closed",
                informativeText:
                    "No recovery or Git operation started. "
                    + Redactor.sanitize(error.localizedDescription)
            )
            return
        }
        #if !SHADOW_SYNC_TESTING
        guard case .accepted = lifecycleRouter.beginExecution(
            generation: lifecycleRouter.phase.generation
        ) else {
            return
        }
        #endif
        pendingPlannedOperations = []
        let cancellation = CancellationToken()
        body3Cancellation = cancellation
        let progressWindow = Body3RunWindowController(
            plan: plan
        )
        progressWindow.onCancel = {
            [weak self, weak cancellation] in
            cancellation?.cancel()
            self?.body3ConfirmationRequest?.cancel()
            self?.body3ConfirmationWindow?
                .cancelForBatch()
        }
        progressWindow.onClose = {
            [weak self, weak progressWindow] in
            guard let self, let progressWindow,
                  self.closeLiveBody3Progress(
                    progressWindow
                  ) else {
                return
            }
            self.rememberWindowFrame(
                progressWindow.window
            )
            self.startNewRun()
        }
        body3RunWindow = progressWindow
        rememberWindowFrame(selectionController.window)
        restoreWindowFrame(progressWindow.window)
        handleForegroundTargetDismissed(
            selectionController
        )
        selectionWindow = nil
        selectionController.close()
        foreground(progressWindow)
        progressWindow.showPreparing(
            0,
            total: removals.count
        )
        executeBody3Batch(
            plan: plan,
            progressWindow: progressWindow,
            cancellation: cancellation,
            location: location
        )
    }

    #endif

    private func stageCanonicalRootOnboarding(
        _ inventory: RepositoryInventory,
        generation: UInt64,
        foregroundResult: Bool
    ) {
        if let pending = pendingCanonicalRootOnboarding,
           pending.generation > generation {
            return
        }
        pendingCanonicalRootOnboarding =
            PendingCanonicalRootOnboarding(
                generation: generation,
                inventory: inventory
            )
        if let loading =
                selectionWindow
                    as? RepositoryCardSelectionWindowController {
            handleForegroundTargetDismissed(loading)
            selectionWindow = nil
            loading.close()
        }
        if foregroundResult {
            presentPendingCanonicalRootOnboarding()
        }
    }

    private func presentPendingCanonicalRootOnboarding() {
        guard canonicalRootWindow == nil,
              authorityCommitSession == nil,
              let pending = pendingCanonicalRootOnboarding else {
            return
        }
        #if SHADOW_SYNC_TESTING
        testingPresentPendingCanonicalRootOnboarding(pending)
        #else
        presentCanonicalRootOnboarding(
            pending.inventory,
            generation: pending.generation
        )
        #endif
    }

    @discardableResult
    private func closeLiveBody3Progress(
        _ progressWindow: Body3RunWindowController
    ) -> Bool {
        guard body3RunWindow === progressWindow else {
            return false
        }
        lastBody3Recovered =
            progressWindow.recoverySnapshot
        updateTerminalReportNotice(
            needsAttention:
                progressWindow.reviewRequiredRunID != nil
        )
        if let acknowledged =
                progressWindow
                    .closeAcknowledgementRunID {
            acknowledgedBody3Run = acknowledged
        }
        body3RunWindow = nil
        body3ConfirmationWindow = nil
        body3ConfirmationRequest = nil
        body3Cancellation = nil
        return true
    }

    private func ownsBody3Session(
        _ progressWindow: Body3RunWindowController,
        run: String
    ) -> Bool {
        body3RunWindow === progressWindow
            && progressWindow.runID == run
    }

    @discardableResult
    private func deliverBody3Report(
        _ report: Body3BatchReport,
        run: String,
        to progressWindow: Body3RunWindowController
    ) -> Bool {
        guard ownsBody3Session(
            progressWindow,
            run: run
        ) else {
            return false
        }
        progressWindow.finish(report)
        return true
    }

    private func presentBody3Confirmation(
        request: Body3ConfirmationRequest,
        progressWindow: Body3RunWindowController,
        cancellation: CancellationToken
    ) {
        guard body3ConfirmationRequest == nil,
              !cancellation.isCancelled else {
            request.cancel()
            return
        }
        body3ConfirmationRequest = request
        let controller =
            Body3GroupedConfirmationWindowController(
                prepared: request.prepared,
                operations: request.operations
            )
        controller.onCancel = {
            [weak self, weak progressWindow] in
            guard let self else {
                request.cancel()
                return
            }
            self.cancelBody3Confirmation(
                request: request,
                progressWindow: progressWindow
            )
        }
        controller.onConfirm = {
            [weak self, weak progressWindow]
            retainedIDs in
            guard let self else {
                request.cancel()
                return
            }
            guard let progressWindow else {
                self.cancelBody3Confirmation(
                    request: request,
                    progressWindow: nil
                )
                return
            }
            self.confirmBody3Confirmation(
                request: request,
                retainedIDs: retainedIDs,
                progressWindow: progressWindow,
                cancellation: cancellation
            )
        }
        body3ConfirmationWindow = controller
        foreground(controller)
    }

    private func cancelBody3Confirmation(
        request: Body3ConfirmationRequest,
        progressWindow: Body3RunWindowController?
    ) {
        request.cancel()
        guard body3ConfirmationRequest === request else {
            return
        }
        body3ConfirmationWindow = nil
        body3ConfirmationRequest = nil
        if let progressWindow,
           body3RunWindow === progressWindow {
            foreground(progressWindow)
        }
    }

    private func confirmBody3Confirmation(
        request: Body3ConfirmationRequest,
        retainedIDs: Set<String>,
        progressWindow: Body3RunWindowController,
        cancellation: CancellationToken
    ) {
        guard body3ConfirmationRequest === request,
              body3RunWindow === progressWindow,
              !cancellation.isCancelled else {
            request.cancel()
            if body3ConfirmationRequest === request {
                body3ConfirmationWindow = nil
                body3ConfirmationRequest = nil
            }
            return
        }
        body3ConfirmationWindow = nil
        body3ConfirmationRequest = nil
        guard request.confirm(
            retainedIDs: retainedIDs
        ) else {
            progressWindow.fail(
                "Final confirmation no longer matched the pending batch; no removal command was admitted."
            )
            cancellation.cancel()
            return
        }
        foreground(progressWindow)
    }

    #if SHADOW_SYNC_TESTING
    func testingPresentBody3Confirmation(
        request: Body3ConfirmationRequest,
        progressWindow: Body3RunWindowController,
        cancellation: CancellationToken
    ) -> Body3GroupedConfirmationWindowController? {
        body3RunWindow = progressWindow
        presentBody3Confirmation(
            request: request,
            progressWindow: progressWindow,
            cancellation: cancellation
        )
        return body3ConfirmationWindow
    }

    func testingDropBody3ProgressWindow() {
        body3RunWindow = nil
    }

    var testingBody3ConfirmationRequest:
        Body3ConfirmationRequest? {
        body3ConfirmationRequest
    }

    func testingCloseLiveBody3Progress(
        _ progressWindow: Body3RunWindowController
    ) -> Bool {
        body3RunWindow = progressWindow
        return closeLiveBody3Progress(progressWindow)
    }

    func testingSetBody3Progress(
        _ progressWindow: Body3RunWindowController?
    ) {
        body3RunWindow = progressWindow
    }

    func testingSetLastBody3Recovered(
        _ recovered: Body3RecoveredRun?
    ) {
        lastBody3Recovered = recovered
    }

    func testingShowLastBody3Report() {
        showLastBody3Report()
    }

    var testingHistoricalBody3Viewer:
        Body3RunWindowController? {
        historicalBody3Viewer
    }

    func testingAcknowledgeReviewedBody3(
        run: String,
        controller: Body3RunWindowController
    ) -> Bool {
        acknowledgeReviewedBody3(
            run: run,
            controller: controller
        )
    }

    func testingDeliverBody3Report(
        _ report: Body3BatchReport,
        run: String,
        to progressWindow: Body3RunWindowController
    ) -> Bool {
        deliverBody3Report(
            report,
            run: run,
            to: progressWindow
        )
    }

    var testingAcknowledgedBody3Run: String? {
        acknowledgedBody3Run
    }

    func testingBody3QuitDecision(
        _ progressWindow: Body3RunWindowController
    ) -> String {
        body3QuitDecision(progressWindow).rawValue
    }

    func testingRouteBody3QuitReview(
        _ progressWindow: Body3RunWindowController
    ) -> Bool {
        routeBody3QuitReview(progressWindow)
    }

    var testingBody3Progress:
        Body3RunWindowController? {
        body3RunWindow
    }

    func testingDeliverBody3Events(
        _ batch: Body3EventBatch,
        progressWindow: Body3RunWindowController,
        cancellation: CancellationToken
    ) {
        body3RunWindow = progressWindow
        deliverBody3Events(
            batch,
            progressWindow: progressWindow,
            run: progressWindow.runID,
            cancellation: cancellation
        )
    }

    #endif

    @MainActor
    private func deliverBody3Events(
        _ batch: Body3EventBatch,
        progressWindow: Body3RunWindowController,
        run: String,
        cancellation: CancellationToken
    ) {
        guard ownsBody3Session(
            progressWindow,
            run: run
        ) else {
            for event in batch.events {
                event.confirmation?.cancel()
            }
            return
        }
        progressWindow.update(
            batch.events,
            maximumBacklogDepth:
                batch.maximumBacklogDepth
        )
        for request in batch.events.compactMap(
            \.confirmation
        ) {
            progressWindow.showAwaitingConfirmation()
            presentBody3Confirmation(
                request: request,
                progressWindow: progressWindow,
                cancellation: cancellation
            )
        }
    }

    #if !SHADOW_SYNC_TESTING
    private func executeBody3Batch(
        plan: Body3BatchPlan,
        progressWindow: Body3RunWindowController,
        cancellation: CancellationToken,
        location: StateLocation
    ) {
        guard let capability = activeVerifiedCapability,
              let authorizedPlan = try? AuthorizedBody3Plan(
                  plan: plan,
                  capability: capability
              ) else {
            progressWindow.fail(
                "The selected repository scope is unavailable. Reload the chooser."
            )
            return
        }
        let eventInbox = Body3EventInbox()
        let executablePath = self.executablePath
        let task = Task.detached(
            priority: .userInitiated
        ) {
            let account = try EffectiveAccount.current()
            let coordinator = RunCoordinator(
                configuration: CoordinatorConfiguration(
                    stateLocation: location,
                    trampolineExecutable: executablePath
                ),
                account: account
            )
            return try coordinator.runBody3(
                authorizedPlan: authorizedPlan,
                cancellation: cancellation
            ) { event in
                if eventInbox.submit(event) {
                    Task { @MainActor in
                        self.deliverBody3Events(
                            eventInbox.drain(),
                            progressWindow:
                                progressWindow,
                            run: plan.run,
                            cancellation:
                                cancellation
                        )
                    }
                }
            }
        }
        Task { @MainActor [weak self, weak progressWindow] in
            let result = await task.result
            guard let self, let progressWindow,
                  self.ownsBody3Session(
                    progressWindow,
                    run: plan.run
                  ) else {
                return
            }
            let pendingEvents = eventInbox.drain()
            if !pendingEvents.events.isEmpty {
                self.deliverBody3Events(
                    pendingEvents,
                    progressWindow: progressWindow,
                    run: plan.run,
                    cancellation: cancellation
                )
            }
            self.body3ConfirmationRequest?.cancel()
            self.body3ConfirmationRequest = nil
            self.body3ConfirmationWindow?
                .cancelForBatch()
            self.body3ConfirmationWindow = nil
            switch result {
            case let .success(report):
                self.deliverBody3Report(
                    report,
                    run: plan.run,
                    to: progressWindow
                )
            case let .failure(error):
                progressWindow.fail(
                    "The batch stopped safely: "
                        + Redactor.sanitize(
                            error.localizedDescription
                        )
                )
            }
            let generation =
                self.lifecycleRouter.phase.generation
            let route = self.lifecycleRouter.settleExecution(
                generation: generation,
                evidence: .noWork(generation: generation)
            )
            if case .terminate = route {
                self.terminateAfterConfirmedQuit()
            } else if self.lifecycleRouter.deferredQuit {
                self.terminateAfterConfirmedQuit()
            }
        }
    }

    private func presentCanonicalRootOnboarding(
        _ inventory: RepositoryInventory,
        generation: UInt64
    ) {
        let controller = CanonicalRootConfirmationWindowController(
            proposals: inventory.onboardingProposals
        )
        controller.onCancel = { [weak self, weak controller] in
            guard let self else { return }
            controller?.close()
            self.canonicalRootWindow = nil
        }
        controller.onConfirm = {
            [weak self, weak controller] selected in
            guard let self else { return }
            guard self.pendingCanonicalRootOnboarding?
                .generation == generation else {
                controller?.close()
                self.canonicalRootWindow = nil
                return
            }
            guard self.commitOnboarding(
                original: inventory,
                selected: selected
            ) else {
                return
            }
            controller?.close()
            self.canonicalRootWindow = nil
        }
        canonicalRootWindow = controller
        foreground(controller)
    }
    #endif

    // Phase-aware result shared by both authority commit paths.
    // .unchanged means onboarding intentionally wrote nothing and can reuse
    // the already-fresh pre-write inventory without claiming persistence.
    // .refreshed means the write AND the post-write rediscovery succeeded.
    // .savedButRefreshFailed means the write committed to disk but the
    // subsequent rediscovery failed; the authority file is durable and
    // correct, but the in-memory inventory needs a separate refresh.
    private enum AuthorityCommitOutcome: @unchecked Sendable {
        case unchanged(RepositoryInventory)
        case refreshed(RepositoryInventory)
        case verified(VerifiedSelectedRepositoryInventory)
        case savedButRefreshFailed(Error)
    }

    #if !SHADOW_SYNC_TESTING
    @discardableResult
    private func commitOnboarding(
        original: RepositoryInventory,
        selected: [CanonicalAuthorityProposal]
    ) -> Bool {
        guard let selectedScope = activeSelectedScope else {
            return false
        }
        guard let commitToken = beginAuthorityCommit(
            feedbackController: nil
        ) else {
            return false
        }
        let executablePath = self.executablePath
        let retainedInventory =
            retainedSessionInventory
        let retainedCapability =
            retainedSessionCapability
        let task: Task<AuthorityCommitOutcome, Error> =
            Task.detached(priority: .userInitiated) {
            let hydrator = SelectedRepositoryHydrator(
                executablePath: executablePath
            )
            let reusableInventory:
                RepositoryInventory?
            let sessionPlan:
                SelectedRepositorySessionPlan
            if let retainedInventory,
               let retainedCapability,
               retainedCapability.admits(
                   retainedInventory
               ) {
                reusableInventory = retainedInventory
                sessionPlan =
                    SelectedRepositoryHydrator.sessionPlan(
                        scope: selectedScope,
                        retainedScope:
                            retainedCapability.scope,
                        retainedRepositoryIDs: Set(
                            retainedInventory.cards.map(\.id)
                        )
                    )
            } else {
                reusableInventory = nil
                sessionPlan =
                    SelectedRepositoryHydrator.sessionPlan(
                        scope: selectedScope,
                        retainedScope: nil,
                        retainedRepositoryIDs: []
                    )
            }
            guard let hydrationScope =
                    sessionPlan.hydrationScope else {
                throw GitSafetyError.unsafeRepository(
                    "onboarding hydration scope is empty"
                )
            }
            let fresh = try hydrator.hydrateEvidence(
                scope: hydrationScope
            )
            let location = try StateLocation.production()
            let commitResult: RepositoryAuthorityCommitResult
            do {
                let authority = try RunAuthority.acquireRun(
                    at: location
                )
                defer { authority.release() }
                let store = RepositoryAuthorityStore(
                    state: authority.stateDirectory
                )
                commitResult = try store.confirmOnboarding(
                    proposals: original.onboardingProposals,
                    selectedRepositoryIDs: Set(
                        selected.map(\.repositoryID)
                    ),
                    freshClones: fresh.authorityCandidateClones,
                    expectedFileIdentity:
                        original.authorityFileIdentity
                )
            }
            guard commitResult.didPersistChange else {
                return .verified(
                    try hydrator.hydrateVerifiedSession(
                        scope: selectedScope,
                        plan: sessionPlan,
                        retainedInventory:
                            reusableInventory
                    )
                )
            }
            do {
                return .verified(
                    try hydrator.hydrateVerifiedSession(
                        scope: selectedScope,
                        plan: sessionPlan,
                        retainedInventory:
                            reusableInventory
                    )
                )
            } catch {
                return .savedButRefreshFailed(error)
            }
        }
        Task { @MainActor [weak self] in
            let result = await task.result
            guard let self else { return }
            guard finishAuthorityCommit(token: commitToken) else {
                return
            }
            completeOnboardingCommit(result)
        }
        return true
    }
    #endif

    private func completeOnboardingCommit(
        _ result: Result<AuthorityCommitOutcome, Error>
    ) {
        if lifecycleRouter.deferredQuit {
            terminateAfterConfirmedQuit()
            return
        }
        switch result {
        case let .success(outcome):
            switch outcome {
            case let .verified(verified):
                #if SHADOW_SYNC_TESTING
                testCanonicalRootInventoryPresentationCount += 1
                #else
                activeSelectedScope = verified.capability.scope
                activeVerifiedCapability = verified.capability
                retainedSessionInventory =
                    verified.inventory
                retainedSessionCapability =
                    verified.capability
                guard case .accepted = lifecycleRouter.enterCards(
                    generation: lifecycleRouter.phase.generation
                ) else {
                    presentDiscoveryAlert(
                        messageText: "Repository authority changed",
                        informativeText:
                            "Reload the repository chooser before continuing."
                    )
                    return
                }
                pendingCanonicalRootOnboarding = nil
                presentRepositoryInventory(
                    verified.inventory,
                    allowOnboarding: false
                )
                #endif
            case let .unchanged(inventory),
                 let .refreshed(inventory):
                #if SHADOW_SYNC_TESTING
                testCanonicalRootInventoryPresentationCount += 1
                #else
                if inventory.onboardingProposals.isEmpty {
                    if let scope = activeSelectedScope,
                       let verified = try?
                        SelectedRepositoryHydrator
                            .verifyFreshInventory(
                                scope: scope,
                                inventory: inventory
                            ) {
                        activeVerifiedCapability =
                            verified.capability
                        retainedSessionInventory =
                            inventory
                        retainedSessionCapability =
                            verified.capability
                        guard case .accepted =
                                lifecycleRouter.enterCards(
                            generation:
                                lifecycleRouter.phase.generation
                                ) else {
                            presentDiscoveryAlert(
                                messageText:
                                    "Repository authority changed",
                                informativeText:
                                    "Reload the repository chooser before continuing."
                            )
                            return
                        }
                    } else {
                        presentDiscoveryAlert(
                            messageText:
                                "Repository authority changed",
                            informativeText:
                                "Reload the repository chooser before continuing."
                        )
                        return
                    }
                    pendingCanonicalRootOnboarding = nil
                    presentRepositoryInventory(
                        inventory,
                        allowOnboarding: false
                    )
                } else {
                    inventoryGeneration &+= 1
                    presentRepositoryInventory(
                        inventory,
                        allowOnboarding: true,
                        generation: inventoryGeneration
                    )
                }
                #endif
            case let .savedButRefreshFailed(refreshError):
                // Write committed; refresh is the only failure.
                reconcileRepositoryInventoryAfterAuthorityResolution(
                    presentResult: true
                )
                presentDiscoveryAlert(
                    messageText: "Canonical roots were saved",
                    informativeText:
                        "The selection was recorded but the repository list could not refresh. "
                        + "Reopen the window to retry. "
                        + Redactor.sanitize(
                            String(describing: refreshError)
                        )
                )
            }
        case let .failure(error):
            // Pre-write or write failure: nothing was changed. Rediscover
            // with onboarding enabled so unresolved authority stays gated.
            reconcileRepositoryInventoryAfterAuthorityResolution(
                allowOnboarding: true,
                presentResult: true
            )
            presentDiscoveryAlert(
                messageText: "Canonical roots were not changed",
                informativeText:
                    "The repository inventory changed before confirmation. Nothing was saved. "
                    + Redactor.sanitize(String(describing: error))
            )
        }
    }

    #if !SHADOW_SYNC_TESTING
    private func confirmCanonicalRoot(
        card: RepositoryCard,
        clone: LocalClone,
        inventory: RepositoryInventory,
        selectionController: SelectionWindowController
    ) {
        let alert = NSAlert()
        alert.messageText = "Confirm canonical root"
        alert.informativeText =
            "\(card.id)\n\n\(clone.primaryRoot)\n\nThis records update authority only. It does not fetch or change the repository."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Confirm root")
        alert.beginSheetModal(for: selectionController.window!) {
            [weak self, weak selectionController] response in
            guard response == .alertSecondButtonReturn,
                  let self,
                  let selectionController else {
                return
            }
            self.commitCanonicalRoot(
                clone: clone,
                inventory: inventory,
                selectionController: selectionController
            )
        }
    }

    private func commitCanonicalRoot(
        clone: LocalClone,
        inventory: RepositoryInventory,
        selectionController: SelectionWindowController
    ) {
        guard let selectedScope = activeSelectedScope else {
            return
        }
        guard let commitToken = beginAuthorityCommit(
            feedbackController: selectionController
        ) else {
            return
        }
        let executablePath = self.executablePath
        let task: Task<AuthorityCommitOutcome, Error> =
            Task.detached(priority: .userInitiated) {
            let hydrator = SelectedRepositoryHydrator(
                executablePath: executablePath
            )
            let fresh = try hydrator.hydrateEvidence(
                scope: selectedScope
            )
            guard let freshClone = fresh.authorityCandidateClones
                    .first(where: {
                        $0.authorityEvidenceDigest
                            == clone.authorityEvidenceDigest
                    }) else {
                throw RepositoryAuthorityStoreError.invalidSelection
            }
            let location = try StateLocation.production()
            do {
                let authority = try RunAuthority.acquireRun(
                    at: location
                )
                defer { authority.release() }
                let store = RepositoryAuthorityStore(
                    state: authority.stateDirectory
                )
                _ = try store.confirmCanonicalRoot(
                    clone: freshClone,
                    freshClones: fresh.authorityCandidateClones,
                    expectedFileIdentity:
                        inventory.authorityFileIdentity
                )
            }
            do {
                return .verified(
                    try hydrator.hydrateVerified(
                        scope: selectedScope
                    )
                )
            } catch {
                return .savedButRefreshFailed(error)
            }
        }
        Task { @MainActor [weak self, weak selectionController] in
            let result = await task.result
            guard let self else { return }
            guard finishAuthorityCommit(token: commitToken) else {
                return
            }
            completeCanonicalRootCommit(
                result,
                originatingFrom: selectionController
            )
        }
    }
    #endif

    private func completeCanonicalRootCommit(
        _ result: Result<AuthorityCommitOutcome, Error>,
        originatingFrom selectionController: SelectionWindowController?
    ) {
        let currentController = selectionController.flatMap {
            selectionWindow === $0 ? $0 : nil
        }
        switch result {
        case let .success(outcome):
            switch outcome {
            case let .verified(verified):
                #if SHADOW_SYNC_TESTING
                testCanonicalRootInventoryPresentationCount += 1
                #else
                guard let currentController else { return }
                currentController.close()
                selectionWindow = nil
                activeSelectedScope = verified.capability.scope
                activeVerifiedCapability = verified.capability
                retainedSessionInventory =
                    verified.inventory
                retainedSessionCapability =
                    verified.capability
                presentRepositoryInventory(
                    verified.inventory,
                    allowOnboarding: false
                )
                #endif
            case let .unchanged(fresh),
                 let .refreshed(fresh):
                guard let currentController else { return }
                currentController.close()
                selectionWindow = nil
                #if SHADOW_SYNC_TESTING
                testCanonicalRootInventoryPresentationCount += 1
                #else
                guard let scope = activeSelectedScope,
                      let verified = try?
                        SelectedRepositoryHydrator
                            .verifyFreshInventory(
                                scope: scope,
                                inventory: fresh
                            ) else {
                    presentRepositoryChooser()
                    return
                }
                activeVerifiedCapability =
                    verified.capability
                retainedSessionInventory = fresh
                retainedSessionCapability =
                    verified.capability
                presentRepositoryInventory(
                    fresh,
                    allowOnboarding: false
                )
                #endif
            case let .savedButRefreshFailed(refreshError):
                if let currentController {
                    currentController.close()
                    selectionWindow = nil
                }
                reconcileRepositoryInventoryAfterAuthorityResolution(
                    presentResult: currentController != nil
                )
                if currentController != nil {
                    presentDiscoveryAlert(
                        messageText: "Canonical root was saved",
                        informativeText:
                            "The selection was recorded but the repository list could not refresh. "
                            + "ShadowSync will retry from a fresh inventory. "
                            + Redactor.sanitize(
                                String(describing: refreshError)
                            )
                    )
                }
            }
        case let .failure(error):
            if let currentController {
                currentController.presentInlineMessage(
                    "Canonical root was not changed because the live evidence changed. "
                        + Redactor.sanitize(String(describing: error))
                )
                currentController.setReviewEnabled(true)
                (currentController
                    as? RepositoryCardSelectionWindowController)?
                    .setAuthorityControlsEnabled(true)
            } else {
                reconcileRepositoryInventoryAfterAuthorityResolution(
                    allowOnboarding: false,
                    presentResult: false
                )
                presentDiscoveryAlert(
                    messageText: "Canonical root was not changed",
                    informativeText:
                        "The update could not be completed. Nothing was saved. "
                        + "ShadowSync is refreshing the repository inventory. "
                        + Redactor.sanitize(String(describing: error))
                )
            }
        }
    }

    private func beginAuthorityCommit(
        feedbackController: SelectionWindowController?
    ) -> UInt64? {
        guard lifecycleRouter.phase.kind != .drainingForQuit else {
            return nil
        }
        if let feedbackController,
           selectionWindow !== feedbackController {
            return nil
        }
        guard authorityCommitSession == nil,
              !inventoryDiscoveryInProgress else {
            presentAuthorityCommitBusy(on: feedbackController)
            return nil
        }
        authorityCommitGeneration &+= 1
        let session = AuthorityCommitSession(
            token: authorityCommitGeneration
        )
        authorityCommitSession = session
        inventoryDiscoveryInProgress = true
        inventoryPresentationRequested = false
        if let feedbackController {
            feedbackController.setReviewEnabled(false)
            (feedbackController
                as? RepositoryCardSelectionWindowController)?
                .setAuthorityControlsEnabled(false)
        }
        return session.token
    }

    private func finishAuthorityCommit(token: UInt64) -> Bool {
        guard authorityCommitSession?.token == token else {
            return false
        }
        authorityCommitSession = nil
        inventoryDiscoveryInProgress = false
        inventoryPresentationRequested = false
        return true
    }

    private func presentAuthorityCommitBusy(
        on controller: SelectionWindowController?
    ) {
        let message =
            "A canonical-root update or repository refresh is already in progress. Wait for it to finish, then confirm again."
        if let controller, selectionWindow === controller {
            controller.presentInlineMessage(message)
            foreground(controller)
        } else {
            presentDiscoveryAlert(
                messageText: "Canonical root update in progress",
                informativeText: message
            )
        }
    }

    private func reconcileRepositoryInventoryAfterAuthorityResolution(
        allowOnboarding: Bool = true,
        presentResult: Bool
    ) {
        #if SHADOW_SYNC_TESTING
        guard beginRepositoryInventoryDiscovery(
            presentResult: presentResult
        ) == nil else {
            return
        }
        testCanonicalRootInventoryRetryCount += 1
        if presentResult {
            testCanonicalRootInventoryRetryPresentationCount += 1
        }
        testRepositoryInventoryReconciliation = (
            allowOnboarding,
            presentResult
        )
        #else
        if activeSelectedScope != nil {
            startRepositoryInventoryDiscovery(
                allowOnboarding: allowOnboarding,
                presentResult: presentResult
            )
        } else if presentResult {
            presentRepositoryChooser()
        }
        #endif
    }

    private func prepareRepositoryInventoryPresentation() {
        if let runWindow {
            handleForegroundTargetDismissed(runWindow)
            lastReport = runWindow.report
            runWindow.close()
            self.runWindow = nil
        }
        if let historicalViewer {
            dismissHistoricalViewer(historicalViewer)
        }
    }

    private func configureSelectionCancellation(
        _ controller: SelectionWindowController
    ) {
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller,
                  self.selectionWindow === controller else {
                return
            }
            if let repositoryController =
                    controller
                        as? RepositoryCardSelectionWindowController,
               repositoryController.isCleanupInspectionInProgress,
               let inventoryCancellation {
                self.lifecycleLogger.notice(
                    "cleanup_inspection cancellation_requested"
                )
                inventoryCancellation.closeFutureChildAdmissions()
                inventoryCancellation.cancel()
                return
            }
            if let repositoryController =
                    controller
                        as? RepositoryCardSelectionWindowController,
               repositoryController.isPreparingRepositoryList,
               self.activeInventoryGeneration != nil {
                // Preparing-window Hide preserves the owned generation so
                // menu/shortcut activation can reveal its eventual result.
                self.lifecycleLogger.notice(
                    "inventory surface_hidden generation=\(self.activeInventoryGeneration ?? 0, privacy: .public)"
                )
                self.handleForegroundTargetDismissed(controller)
                self.pendingPlannedOperations = []
                return
            }
            self.handleForegroundTargetDismissed(controller)
            if self.confirmationSelectionController === controller {
                self.clearConfirmationState()
            }
            self.pendingPlannedOperations = []
            self.selectionWindow = nil
        }
    }

    private func recoveryState() -> RunRecoveryState {
        do {
            return RunRecoveryInspector.inspect(at: try logLocation())
        } catch {
            return .needsAttention
        }
    }

    private func body3RecoveryState()
        -> Body3RunRecoveryState {
        do {
            return Body3RunRecoveryInspector.inspect(
                at: try logLocation(),
                account: try EffectiveAccount.current()
            )
        } catch {
            return .needsAttention
        }
    }

    private func updateTerminalReportNotice(
        needsAttention: Bool
    ) {
        terminalReportNotice = needsAttention
            ? ShadowSyncPresentation.previousReportNeedsAttention
            : nil
        guard inlineStatusMessage == nil,
              foregroundStatusMessage == nil,
              let button = statusItem?.button else {
            return
        }
        let message = terminalReportNotice
            ?? (
                shortcutAvailable
                    ? nil
                    : ShadowSyncPresentation
                        .shortcutUnavailableText
            )
        button.toolTip = message
        button.setAccessibilityHelp(message)
    }

    private func loadRecoveryPresentation() {
        switch body3RecoveryState() {
        case .notBody3:
            break
        case let .previous(recovered):
            lastBody3Recovered = recovered
            updateTerminalReportNotice(
                needsAttention: recovered.requiresReview
            )
            return
        case .operationStillActive:
            requestOperationContention(
                .recoveryPresentation
            )
            return
        case .needsAttention:
            presentDiscoveryAlert(
                messageText:
                    "Previous protected cleanup needs attention",
                informativeText:
                    "ShadowSync could not safely reconstruct the contiguous Body 3 event log. Review the latest log before trying again."
            )
            return
        }
        switch recoveryState() {
        case .none:
            break
        case let .previousReport(report):
            lastReport = report
            if report.summaryOverride == InterruptedRunReconstructor.summary {
                recoveryReviewRequirement = recoveryRequirement(for: report)
            }
        case .operationStillActive:
            requestOperationContention(.recoveryPresentation)
        case .needsAttention:
            presentDiscoveryAlert(
                messageText: InterruptedRunReconstructor.summary,
                informativeText: "ShadowSync could not safely reconstruct the previous run. Review the latest log before trying again."
            )
        }
    }

    private func showLastBody3Report() {
        if let historicalBody3Viewer {
            if historicalBody3Viewer.isPresentationOpen {
                foreground(historicalBody3Viewer)
                return
            }
            self.historicalBody3Viewer = nil
        }
        guard let recovered = lastBody3Recovered else {
            return
        }
        guard (try? Body3BatchMetadata.derive(
            plan: recovered.plan,
            report: recovered.report
        )) != nil else {
            presentDiscoveryAlert(
                messageText:
                    "Last report needs attention",
                informativeText:
                    "The saved protected-cleanup report contradicted its immutable plan and was not opened. No live-run safety state was changed."
            )
            return
        }
        let controller = Body3RunWindowController(
            plan: recovered.plan
        )
        controller.window?.title =
            ShadowSyncPresentation.historicalBatchTitle
        for record in recovered.records {
            controller.update(
                Body3CoordinatorEvent(record: record)
            )
        }
        controller.finish(recovered.report)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller,
                  self.historicalBody3Viewer === controller else {
                return
            }
            self.rememberWindowFrame(controller.window)
            self.historicalBody3Viewer = nil
        }
        historicalBody3Viewer = controller
        foreground(controller)
    }

    @discardableResult
    private func acknowledgeReviewedBody3(
        run: String,
        controller: Body3RunWindowController
    ) -> Bool {
        guard historicalBody3Viewer === controller
                || body3RunWindow === controller else {
            return false
        }
        if historicalBody3Viewer === controller {
            historicalBody3Viewer = nil
        }
        if body3RunWindow === controller {
            body3RunWindow = nil
        }
        acknowledgedBody3Run = run
        updateTerminalReportNotice(needsAttention: false)
        return true
    }

    private func dismissHistoricalBody3Viewer(
        _ controller: Body3RunWindowController
    ) {
        guard historicalBody3Viewer === controller else {
            return
        }
        rememberWindowFrame(controller.window)
        handleForegroundTargetDismissed(controller)
        historicalBody3Viewer = nil
        controller.close()
    }

    private func requireRecoveryReview(_ report: RunReport) {
        guard let requirement = recoveryRequirement(for: report) else {
            presentDiscoveryAlert(
                messageText: InterruptedRunReconstructor.summary,
                informativeText: "ShadowSync could not verify the recovered log. Review the latest log before trying again."
            )
            return
        }
        if let existing = recoveryReviewRequirement, existing != requirement {
            presentDiscoveryAlert(
                messageText: InterruptedRunReconstructor.summary,
                informativeText: "The recovery evidence changed before review was acknowledged. ShadowSync will remain blocked."
            )
            return
        }
        recoveryReviewRequirement = requirement
        lastReport = report
        showLastReport()
    }

    private func recoveryRequirement(
        for report: RunReport
    ) -> RecoveryReviewRequirement? {
        let path: String
        do {
            path = try logLocation().path + "/latest.log"
        } catch {
            return nil
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            return nil
        }
        return RecoveryReviewRequirement(
            run: report.run,
            startedAt: report.startedAt,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private func enforceRecoveryReviewGate() {
        switch recoveryState() {
        case let .previousReport(report)
            where report.summaryOverride == InterruptedRunReconstructor.summary:
            requireRecoveryReview(report)
        case .operationStillActive:
            requestOperationContention(.startNewRun)
        case .none, .needsAttention, .previousReport:
            presentDiscoveryAlert(
                messageText: InterruptedRunReconstructor.summary,
                informativeText: "The recovery evidence changed before review was acknowledged. ShadowSync will not start a new run. Review the latest log."
            )
        }
    }

    private func requestOperationContention(
        _ intent: OperationContentionIntent
    ) {
        lifecycleLogger.notice(
            "lock classified generation=\(self.activeActionGeneration ?? 0, privacy: .public) ownership=external intent=\(String(describing: intent), privacy: .public)"
        )
        let effects = operationContention.request(intent)
        lifecycleLogger.notice(
            "contention requested token=\(self.operationContention.currentToken ?? 0, privacy: .public) intent=\(String(describing: intent), privacy: .public)"
        )
        applyOperationContentionEffects(effects)
    }

    private func applyOperationContentionEffects(
        _ effects: [OperationContentionEffect]
    ) {
        for effect in effects {
            switch effect {
            case let .scheduleRevalidation(token, delayed):
                scheduleOperationContentionRevalidation(
                    token: token,
                    delayed: delayed
                )
            case let .present(token):
                presentOperationContention(token: token)
            case let .foreground(token):
                foregroundOperationContention(token: token)
            case .cancelRevalidation:
                cancelOperationContentionRevalidation()
            case let .dismiss(token):
                dismissOperationContention(token: token)
            case let .resume(token, intent):
                resumeAfterOperationContention(token: token, intent: intent)
            }
        }
    }

    private func scheduleOperationContentionRevalidation(
        token: UInt64,
        delayed: Bool
    ) {
        guard operationContention.currentToken == token else {
            return
        }
        operationContentionRevalidationWorkItem?.cancel()
        operationContentionRevalidationGeneration &+= 1
        let generation = operationContentionRevalidationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.performOperationContentionRevalidation(
                token: token,
                generation: generation
            )
        }
        operationContentionRevalidationWorkItem = workItem
        operationContentionScheduledToken = token
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            return
        }
        #endif
        let deadline: DispatchTime = delayed
            ? .now() + operationContentionRevalidationDelay
            : .now()
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: workItem)
    }

    private func performOperationContentionRevalidation(
        token: UInt64,
        generation: UInt64
    ) {
        guard operationContentionRevalidationGeneration == generation,
              operationContentionScheduledToken == token else {
            return
        }
        operationContentionRevalidationWorkItem = nil
        operationContentionScheduledToken = nil
        let observation: OperationContentionObservation
        if recoveryState() == .operationStillActive {
            observation = .held
        } else {
            observation = .released
        }
        lifecycleLogger.notice(
            "contention observation token=\(token, privacy: .public) outcome=\(observation == .held ? "held" : "released", privacy: .public)"
        )
        applyOperationContentionEffects(
            operationContention.observe(observation, token: token)
        )
    }

    private func cancelOperationContentionRevalidation() {
        operationContentionRevalidationWorkItem?.cancel()
        operationContentionRevalidationWorkItem = nil
        operationContentionScheduledToken = nil
        operationContentionRevalidationGeneration &+= 1
    }

    private func presentOperationContention(token: UInt64) {
        guard operationContention.currentToken == token,
              operationContention.isPresented,
              operationContentionAlertToken == nil else {
            return
        }
        let title = InterruptedRunReconstructor.operationContentionTitle
        let text = """
        \(InterruptedRunReconstructor.operationContentionMessage)

        \(InterruptedRunReconstructor.operationContentionRecovery)
        """
        operationContentionAlertToken = token
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            testOperationContentionPresentationCount += 1
            testOperationContentionPresentation = (title, text)
            return
        }
        #endif
        let alert = ShadowSyncAlertFactory.operationContention()
        let controller = OperationContentionWindowController(alert: alert)
        operationContentionAlert = alert
        operationContentionWindowController = controller
        alert.buttons.first?.target = self
        alert.buttons.first?.action = #selector(closeOperationContentionAlert)
        operationContentionCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: alert.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.operationContentionWindowClosed(token: token)
            }
        }
        alert.window.center()
        foreground(controller)
    }

    private func foregroundOperationContention(token: UInt64) {
        guard operationContentionAlertToken == token else {
            return
        }
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            return
        }
        #endif
        guard let controller = operationContentionWindowController else {
            return
        }
        foreground(controller)
    }

    @objc private func closeOperationContentionAlert() {
        operationContentionAlert?.window.close()
    }

    private func operationContentionWindowClosed(token: UInt64) {
        guard operationContentionAlertToken == token else {
            return
        }
        clearOperationContentionPresentation()
        lifecycleLogger.notice(
            "contention closed token=\(token, privacy: .public)"
        )
        applyOperationContentionEffects(
            operationContention.presentationClosed(token: token)
        )
    }

    private func dismissOperationContention(token: UInt64) {
        guard operationContentionAlertToken == token else {
            return
        }
        let window = operationContentionAlert?.window
        clearOperationContentionPresentation()
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            testOperationContentionDismissalCount += 1
            return
        }
        #endif
        window?.orderOut(nil)
        window?.close()
    }

    private func clearOperationContentionPresentation() {
        if let controller = operationContentionWindowController {
            handleForegroundTargetDismissed(controller)
        }
        if let operationContentionCloseObserver {
            NotificationCenter.default.removeObserver(
                operationContentionCloseObserver
            )
            self.operationContentionCloseObserver = nil
        }
        operationContentionAlert = nil
        operationContentionWindowController = nil
        operationContentionAlertToken = nil
        reconcileForegroundFailureFromCurrentReality()
    }

    private func resumeAfterOperationContention(
        token: UInt64,
        intent: OperationContentionIntent
    ) {
        guard operationContention.currentToken != token else {
            return
        }
        #if SHADOW_SYNC_TESTING
        testOperationContentionResumeCount += 1
        #endif
        lifecycleLogger.notice(
            "contention resumed token=\(token, privacy: .public) intent=\(String(describing: intent), privacy: .public)"
        )
        switch intent {
        case .recoveryPresentation:
            loadRecoveryPresentation()
        case .startNewRun:
            startNewRun()
        case .quitUtility:
            continueQuitUtility()
        }
    }

    private func cancelOperationContention() {
        applyOperationContentionEffects(operationContention.cancel())
    }

    func handleDuplicateActivation() {
        #if SHADOW_SYNC_TESTING
        testDuplicateActivationCount += 1
        #endif
        if let surface = currentOperatorSurface(
            for: .explicitInvocation
        ), surface.kind != .run {
            foreground(surface)
            return
        }
        guard let runWindow else {
            startNewRun()
            return
        }
        if lifecycleRouter.deferredQuit
            || quitConfirmationInProgress
            || runWindow.hasPendingQuit {
            runWindow.presentQuitInProgressFeedback()
            foreground(runWindow)
            return
        }
        switch runWindow.takeoverGateDecision {
        case .allow:
            startNewRun()
            return
        case .block(.stopInProgress):
            runWindow.presentStoppingFeedback()
            foreground(runWindow)
            return
        case .block:
            foreground(runWindow)
            return
        case .stopThenReevaluate:
            break
        }
        let alert = ShadowSyncAlertFactory.activeRun(
            repositoryCount: runWindow.repositoryCount
        )
        guard alert.runModal() == .alertSecondButtonReturn else {
            runWindow.cancelPendingTakeover()
            return
        }
        let confirmation = ShadowSyncAlertFactory.takeover()
        guard confirmation.runModal() == .alertSecondButtonReturn else {
            runWindow.cancelPendingTakeover()
            return
        }
        runWindow.requestTakeover { [weak self, weak runWindow] in
            guard let self, let runWindow,
                  self.runWindow === runWindow,
                  !self.lifecycleRouter.deferredQuit,
                  runWindow.prepareForNewRun() else {
                return false
            }
            self.lastReport = runWindow.report
            runWindow.close()
            self.runWindow = nil
            self.startNewRun()
            return true
        }
    }

    private func presentDiscoveryAlert(messageText: String, informativeText: String) {
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            testDiscoveryPresentation = (messageText, informativeText)
            testDiscoveryPresentationCount += 1
            return
        }
        #endif
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    private func review(
        selected: [RepositoryCandidate],
        selectionController: SelectionWindowController,
        onConfirmed: (() -> Void)? = nil
    ) {
        guard !selected.isEmpty else {
            return
        }
        #if !SHADOW_SYNC_TESTING
        let selectedPaths = Set(selected.map(\.path))
        let operationPaths = Set(pendingPlannedOperations.map {
            $0.target.canonicalClone.primaryRoot
        })
        let canConfirmSelection = !pendingPlannedOperations.isEmpty
            && selectedPaths == operationPaths
            ? WorkerRequest.admitsOperations(pendingPlannedOperations)
            : RepositoryOperatorPresentation.canConfirm(selected)
        #else
        let canConfirmSelection =
            RepositoryOperatorPresentation.canConfirm(selected)
        #endif
        guard canConfirmSelection else {
            selectionController.presentInlineMessage(
                ShadowSyncPresentation.locationAttentionText
            )
            foreground(selectionController)
            return
        }
        #if SHADOW_SYNC_TESTING
        if testingHostChrome, !forceAsyncConfirmationForTesting,
           let testingConfirmation {
            let alert = confirmationAlert(
                for: selected,
                includesCleanupRecovery:
                    onConfirmed != nil
            )
            testConfirmationSnapshot = (
                alert.messageText,
                alert.informativeText,
                alert.buttons.map(\.title)
            )
            handleConfirmationResponse(
                testingConfirmation(),
                selected: selected,
                selectionController: selectionController,
                startWasArmed: true,
                onConfirmed: onConfirmed
            )
            return
        }
        #endif
        beginConfirmationSheet(
            selected: selected,
            selectionController: selectionController,
            onConfirmed: onConfirmed
        )
    }

    private func beginConfirmationSheet(
        selected: [RepositoryCandidate],
        selectionController: SelectionWindowController,
        onConfirmed: (() -> Void)?
    ) {
        guard !confirmationInProgress,
              self.selectionWindow === selectionController,
              selectionController.window != nil else {
            return
        }
        confirmationInProgress = true
        confirmationStartArmed = false
        confirmationSelectionController = selectionController
        confirmationOnConfirmed = onConfirmed
        selectionController.setReviewEnabled(false)
        DispatchQueue.main.async { [weak self, weak selectionController] in
            guard let self, let selectionController else {
                return
            }
            guard
                  self.confirmationInProgress,
                  self.confirmationSelectionController === selectionController,
                  self.selectionWindow === selectionController,
                  let window = selectionController.window else {
                if self.confirmationSelectionController === selectionController {
                    self.clearConfirmationState()
                }
                return
            }
            let alert = self.confirmationAlert(
                for: selected,
                includesCleanupRecovery:
                    onConfirmed != nil
            )
            self.activeConfirmationAlert = alert
            let startButton = alert.buttons.indices.contains(2)
                ? alert.buttons[2]
                : nil
            startButton?.isEnabled = false
            alert.beginSheetModal(for: window) { [weak self, weak selectionController] response in
                guard let self, let selectionController else {
                    return
                }
                guard self.confirmationInProgress,
                      self.confirmationSelectionController === selectionController else {
                    return
                }
                let armed = self.confirmationStartArmed
                let onConfirmed =
                    self.confirmationOnConfirmed
                self.clearConfirmationState()
                self.handleConfirmationResponse(
                    response,
                    selected: selected,
                    selectionController: selectionController,
                    startWasArmed: armed,
                    onConfirmed: onConfirmed
                )
                self.presentPendingShortcutCollisionOnCurrentSurface()
            }
            alert.window.makeFirstResponder(alert.buttons.first)
            self.confirmationInputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self, weak alert] event in
                guard let self,
                      let alert,
                      self.activeConfirmationAlert === alert,
                      self.confirmationInProgress else {
                    return event
                }
                self.armConfirmationStart(alert)
                return event
            }
        }
    }

    private func armConfirmationStart(_ alert: NSAlert) {
        guard activeConfirmationAlert === alert,
              confirmationInProgress else {
            return
        }
        confirmationStartArmed = true
        if alert.buttons.indices.contains(2) {
            alert.buttons[2].isEnabled = true
        }
        if let status = alert.accessoryView
            as? NSTextField {
            status.stringValue =
                "Ready. Start will revalidate every operation immediately before it runs."
            status.textColor = .systemGreen
        }
    }

    private func handleConfirmationResponse(
        _ response: NSApplication.ModalResponse,
        selected: [RepositoryCandidate],
        selectionController: SelectionWindowController,
        startWasArmed: Bool,
        onConfirmed: (() -> Void)? = nil
    ) {
        switch response {
        case .alertThirdButtonReturn where startWasArmed:
            if let onConfirmed {
                onConfirmed()
                return
            }
            if let cardController = selectionController
                as? RepositoryCardSelectionWindowController {
                cardController.closeForConfirmedRun()
            } else {
                selectionController.close()
            }
            selectionWindow = nil
            beginRun(selected)
        case .alertFirstButtonReturn:
            selectionController.showWindow(nil)
        default:
            pendingPlannedOperations = []
            selectionController.close()
            selectionWindow = nil
        }
    }

    private func clearConfirmationState() {
        #if SHADOW_SYNC_TESTING
        testConfirmationClearCount += 1
        #endif
        if let confirmationInputMonitor {
            NSEvent.removeMonitor(confirmationInputMonitor)
            self.confirmationInputMonitor = nil
        }
        confirmationInProgress = false
        confirmationStartArmed = false
        confirmationSelectionController?.setReviewEnabled(true)
        confirmationSelectionController = nil
        confirmationOnConfirmed = nil
        activeConfirmationAlert = nil
        #if SHADOW_SYNC_TESTING
        forceAsyncConfirmationForTesting = false
        #endif
    }

    private func confirmationAlert(
        for candidates: [RepositoryCandidate],
        includesCleanupRecovery: Bool = false
    ) -> NSAlert {
        #if !SHADOW_SYNC_TESTING
        let selectedPaths = Set(candidates.map(\.path))
        let operationPaths = Set(pendingPlannedOperations.map {
            $0.target.canonicalClone.primaryRoot
        })
        if !pendingPlannedOperations.isEmpty,
           selectedPaths == operationPaths {
            let alert = NSAlert()
            alert.messageText =
                "Review \(pendingPlannedOperations.count) repository operation"
                    + (pendingPlannedOperations.count == 1 ? "" : "s")
                    + (!includesCleanupRecovery
                        ? "" : " before cleanup recovery")
            var repositoryOrder: [String] = []
            var grouped:
                [String: [PlannedOperation]] = [:]
            for operation in pendingPlannedOperations {
                let id = operation.target.repository.id
                if grouped[id] == nil {
                    repositoryOrder.append(id)
                }
                grouped[id, default: []].append(
                    operation
                )
            }
            let rows = repositoryOrder.map { repositoryID in
                let operations = grouped[repositoryID] ?? []
                let children = operations.enumerated().map {
                    index, operation in
                    let target = operation.target
                    let action: String
                switch operation.kind {
                case .fastForward:
                    action = "Fast-forward \(target.resolvedDefault.name)"
                case .repairPruneRegistrations:
                    let count: Int
                    if case let .prune(items)? =
                        operation.maintenanceEvidence {
                        count = items.count
                    } else {
                        count = 0
                    }
                    action =
                        "Repair \(count) exact stale registration\(count == 1 ? "" : "s")"
                case .repairMovedWorktree:
                    if case let .repairMoved(item)? =
                        operation.maintenanceEvidence {
                        action =
                            "Repair moved worktree \(item.verifiedPath)"
                    } else {
                        action = "Repair moved worktree"
                    }
                case .initializeDefaultBranch:
                    action =
                        "Initialize local \(target.resolvedDefault.name)"
                }
                    return "  \(index + 1). \(action)\n"
                        + "     Revalidate authority and repository state, then run this exact action."
                }.joined(separator: "\n")
                return "\(repositoryID)\n\(children)"
            }.joined(separator: "\n\n")
            alert.informativeText =
                "Repositories run in the order shown. Within each repository, operations run top-to-bottom. ShadowSync freshly revalidates authority and repository state before every operation; changed or unverifiable evidence stops that repository’s remaining operations while independent repositories continue."
                + (!includesCleanupRecovery
                    ? " No cleanup action is available."
                    : " Selected protected recovery follows these operations; no Worktree or Branch removal can start until the later grouped final confirmation.")
                + "\n\n"
                + rows
            let arming = NSTextField(
                wrappingLabelWithString:
                    "Review the ordered plan, then click or press a key in this dialog to enable Start selected."
            )
            arming.font = .systemFont(
                ofSize: 11,
                weight: .medium
            )
            arming.textColor = .systemOrange
            arming.maximumNumberOfLines = 2
            arming.frame.size = NSSize(
                width: 520,
                height: 34
            )
            alert.accessoryView = arming
            alert.addButton(withTitle: "Back")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Start selected")
            return alert
        }
        #endif
        return ShadowSyncAlertFactory.confirmation(
            candidates: candidates
        )
    }

    private func beginRun(_ candidates: [RepositoryCandidate]) {
        guard RepositoryOperatorPresentation.canPresent(candidates) else {
            presentDiscoveryAlert(
                messageText: ShadowSyncPresentation.locationAttentionTitle,
                informativeText: ShadowSyncPresentation.locationAttentionText
            )
            return
        }
        #if !SHADOW_SYNC_TESTING
        let operations = pendingPlannedOperations
        pendingPlannedOperations = []
        guard let capability = activeVerifiedCapability,
              let authorizedOperations = try? operations.map({
                  try AuthorizedOperationEnvelope(
                      operation: $0,
                      capability: capability
                  )
              }),
              case .accepted = lifecycleRouter.beginExecution(
                  generation: lifecycleRouter.phase.generation
              ) else {
            presentDiscoveryAlert(
                messageText: "Repository authority changed",
                informativeText:
                    "Reload the repository chooser before starting repository operations."
            )
            return
        }
        let controller = RunWindowController(
            candidates: candidates,
            plannedOperations: operations,
            authorizedOperations: authorizedOperations,
            lifecycleRouter: lifecycleRouter
        )
        #else
        let controller = RunWindowController(candidates: candidates)
        #endif
        controller.onOpenLog = { [weak self] in
            self?.openLog()
        }
        controller.onHide = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.handleForegroundTargetDismissed(controller)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.handleForegroundTargetDismissed(controller)
            self.lastReport = controller.report
            let generation =
                self.lifecycleRouter.phase.generation
            _ = self.lifecycleRouter.settleExecution(
                generation: generation,
                evidence: controller.appDrainEvidence(
                    generation: generation
                )
            )
            controller.close()
            self.runWindow = nil
        }
        controller.onRecoveryAcknowledgementRequested = { [weak self] report in
            self?.acknowledgeRecovery(report) == true
        }
        controller.onQuitBlocked = { [weak self] in
            self?.lifecycleRouter.cancelDeferredQuit()
        }
        controller.onQuitReady = { [weak self] in
            self?.terminateAfterConfirmedQuit()
        }
        controller.onWorkerReaped = { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.lastReport = controller.report
            let generation =
                self.lifecycleRouter.phase.generation
            _ = self.lifecycleRouter.settleExecution(
                generation: generation,
                evidence: controller.appDrainEvidence(
                    generation: generation
                )
            )
        }
        controller.onWorkerExit = { [weak self, weak controller] _ in
            guard let self, let controller else {
                return
            }
            self.lastReport = controller.report
            controller.maybeAdvancePendingTransitions()
            let generation =
                self.lifecycleRouter.phase.generation
            _ = self.lifecycleRouter.settleExecution(
                generation: generation,
                evidence: controller.appDrainEvidence(
                    generation: generation
                )
            )
        }
        runWindow = controller
        foreground(controller)
        #if SHADOW_SYNC_TESTING
        testBeginRunCount += 1
        if suppressWorkerStartForConfirmationTest {
            return
        }
        guard let testingRoot, let testingMapping else {
            controller.presentFailure("Testing host lacks an isolated worker configuration.")
            return
        }
        controller.start(
            executablePath: executablePath,
            isolatedRoot: testingRoot,
            transportMapping: testingMapping
        )
        #else
        controller.start(executablePath: executablePath)
        #endif
    }

    @objc private func showCurrentRun() {
        requestForegroundCurrentSurface()
    }

    @objc private func showLastReport() {
        if lastBody3Recovered != nil {
            showLastBody3Report()
            return
        }
        if let historicalViewer {
            if historicalViewer.isPresentationOpen {
                foreground(historicalViewer)
                return
            }
            self.historicalViewer = nil
        }
        guard let lastReport else {
            return
        }
        let candidates = lastReport.results.map(\.repository)
        let controller = RunWindowController(
            candidates: candidates,
            runID: lastReport.run,
            role: .historicalViewer
        )
        guard controller.present(report: lastReport) else {
            controller.close()
            presentDiscoveryAlert(
                messageText: "Last report needs attention",
                informativeText: "The saved report could not be validated and was not opened. No live-run safety state was changed. Review the latest log, then retry Show Last Report."
            )
            return
        }
        controller.window?.title =
            LegacyRunPresentation.isLegacy(lastReport)
                ? LegacyRunPresentation.label
                : ShadowSyncPresentation.appTitle
        controller.onOpenLog = { [weak self] in self?.openLog() }
        controller.onHide = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.handleForegroundTargetDismissed(controller)
        }
        controller.onRecoveryAcknowledgementRequested = { [weak self] report in
            self?.acknowledgeRecovery(report) == true
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller,
                  self.historicalViewer === controller else {
                return
            }
            self.handleForegroundTargetDismissed(controller)
            self.dismissHistoricalViewer(controller)
        }
        historicalViewer = controller
        foreground(controller)
    }

    private func dismissHistoricalViewer(_ controller: RunWindowController) {
        guard historicalViewer === controller else {
            return
        }
        handleForegroundTargetDismissed(controller)
        historicalViewer = nil
        controller.dismissHistoricalPresentation()
    }

    private func acknowledgeRecovery(_ report: RunReport) -> Bool {
        guard report.summaryOverride == InterruptedRunReconstructor.summary,
              case let .previousReport(current) = recoveryState(),
              let requirement = recoveryRequirement(for: report),
              requirement.matches(current),
              recoveryRequirement(for: current) == requirement,
              recoveryReviewRequirement == nil
                || recoveryReviewRequirement == requirement else {
            presentDiscoveryAlert(
                messageText: InterruptedRunReconstructor.summary,
                informativeText: "Recovery cannot be acknowledged because the bound log is missing, unsafe, or changed. Open the latest log and resolve the evidence before retrying."
            )
            return false
        }
        recoveryReviewRequirement = nil
        acknowledgedRecovery = requirement
        return true
    }

    @objc private func openLatestLog() {
        openLog()
    }

    private func openLog() {
        do {
            let state = try SecureStateDirectory.open(logLocation())
            try CurrentLogOpener.open(state: state, opener: logOpener)
            pendingForegroundRequest = nil
            clearForegroundRequestObservation()
            clearInlineStatus(.logOpenFailure, retryGuidance: true)
        } catch {
            pendingForegroundRequest = nil
            clearForegroundRequestObservation()
            if let controller = currentPrimaryController() {
                _ = presentInlineStatus(.logOpenFailure, on: controller)
                foreground(controller)
            } else {
                _ = presentInlineStatus(.logOpenFailure, on: nil)
                if foregroundStatusMessage == nil {
                    statusItem?.button?.toolTip = inlineStatusMessage
                }
            }
        }
    }

    @objc private func quitUtility() {
        recordAction(.quit)
        continueQuitUtility()
    }

    func requestLifecycleExit() {
        lifecycleRouter.deferQuit()
        inventoryCancellation?.closeFutureChildAdmissions()
        inventoryCancellation?.cancel()
        body3ConfirmationRequest?.cancel()
        body3Cancellation?.cancel()
        terminateAfterConfirmedQuit()
    }

    private func continueQuitUtility() {
        guard !lifecycleRouter.deferredQuit else {
            return
        }
        if pendingCanonicalRootOnboarding != nil,
           authorityCommitSession == nil {
            lifecycleRouter.deferQuit()
            if let controller = canonicalRootWindow {
                handleForegroundTargetDismissed(controller)
                canonicalRootWindow = nil
                controller.close()
            }
            terminateAfterConfirmedQuit()
            return
        }
        #if !SHADOW_SYNC_TESTING
        if let chooser =
                selectionWindow as? RepositoryChooserWindowController {
            switch terminateAfterConfirmedQuit() {
            case .terminate:
                break
            case let .quitPaused(missing):
                inventoryCancellation?.cancel()
                chooser.showQuitDraining(missing)
                foreground(chooser)
            case .accepted, .ignored:
                break
            }
            return
        }
        #endif
        if inventoryDiscoveryInProgress,
           let inventoryCancellation,
           activeInventoryGeneration != nil {
            lifecycleLogger.notice(
                "lock classified generation=\(self.activeActionGeneration ?? 0, privacy: .public) ownership=owned intent=quit"
            )
            lifecycleRouter.deferQuit()
            inventoryCancellation.closeFutureChildAdmissions()
            #if SHADOW_SYNC_TESTING
            testOwnedInventoryQuitCount += 1
            #endif
            if let controller =
                    selectionWindow
                        as? RepositoryCardSelectionWindowController,
               controller.isPresentationOpen {
                controller.showInventoryCancellation(
                    "Finishing the current repository check before quitting…"
                )
                foreground(controller)
            }
            return
        }
        if let body3RunWindow {
            switch body3QuitDecision(
                body3RunWindow
            ) {
            case .terminate:
                lifecycleRouter.deferQuit()
                terminateAfterConfirmedQuit()
                return
            case .review:
                _ = routeBody3QuitReview(
                    body3RunWindow
                )
                return
            case .cancelActiveRun:
                break
            }
            let alert = ShadowSyncAlertFactory
                .quitActiveRun()
            quitConfirmationInProgress = true
            let response = alert.runModal()
            quitConfirmationInProgress = false
            guard response
                    == .alertSecondButtonReturn else {
                if let body3ConfirmationWindow {
                    foreground(body3ConfirmationWindow)
                } else {
                    foreground(body3RunWindow)
                }
                return
            }
            lifecycleRouter.deferQuit()
            body3ConfirmationRequest?.cancel()
            body3Cancellation?.cancel()
            body3ConfirmationWindow?
                .cancelForBatch()
            return
        }
        if runWindow == nil {
            switch body3RecoveryState() {
            case .notBody3:
                break
            case let .previous(recovered):
                lastBody3Recovered = recovered
                updateTerminalReportNotice(
                    needsAttention:
                        recovered.requiresReview
                )
                lifecycleRouter.deferQuit()
                terminateAfterConfirmedQuit()
                return
            case .operationStillActive:
                requestOperationContention(.quitUtility)
                return
            case .needsAttention:
                presentDiscoveryAlert(
                    messageText:
                        "Quit needs attention",
                    informativeText:
                        "ShadowSync could not validate the previous protected-cleanup log. Quit was cancelled so the evidence can be reviewed."
                )
                return
            }
        }
        guard let runWindow else {
            switch recoveryState() {
            case .none:
                break
            case let .previousReport(report)
                where report.summaryOverride
                    == InterruptedRunReconstructor.summary:
                guard let requirement = recoveryRequirement(for: report),
                      acknowledgedRecovery == requirement else {
                    requireRecoveryReview(report)
                    return
                }
            case .previousReport:
                break
            case .operationStillActive:
                requestOperationContention(.quitUtility)
                return
            case .needsAttention:
                presentDiscoveryAlert(
                    messageText: "Quit needs attention",
                    informativeText: "ShadowSync could not validate that no owned operation remains. Quit was cancelled; review the latest log and retry."
                )
                return
            }
            #if SHADOW_SYNC_TESTING
            if let testingQuitHandler {
                testingQuitHandler()
                return
            }
            #endif
            lifecycleRouter.deferQuit()
            terminateAfterConfirmedQuit()
            return
        }
        if runWindow.quitGateDecision == .allow {
            #if SHADOW_SYNC_TESTING
            if let testingQuitHandler {
                testingQuitHandler()
                return
            }
            #endif
            lifecycleRouter.deferQuit()
            terminateAfterConfirmedQuit()
            return
        }
        let alert = ShadowSyncAlertFactory.quitActiveRun()
        quitConfirmationInProgress = true
        let response = alert.runModal()
        quitConfirmationInProgress = false
        guard response == .alertSecondButtonReturn else {
            return
        }
        runWindow.cancelPendingTakeover()
        lifecycleRouter.deferQuit()
        switch runWindow.requestQuitAfterConfirmation() {
        case .terminateNow:
            terminateAfterConfirmedQuit()
        case .stopping:
            break
        case .blocked:
            lifecycleRouter.cancelDeferredQuit()
        }
    }

    private func body3QuitDecision(
        _ progressWindow: Body3RunWindowController
    ) -> Body3QuitDecision {
        if progressWindow.canQuitImmediately(
            acknowledgedRunID:
                acknowledgedBody3Run
        ) {
            return .terminate
        }
        return progressWindow.isTerminal
            ? .review
            : .cancelActiveRun
    }

    @discardableResult
    private func routeBody3QuitReview(
        _ progressWindow: Body3RunWindowController
    ) -> Bool {
        guard body3RunWindow === progressWindow,
              progressWindow.reviewRequiredRunID
                == progressWindow.runID,
              acknowledgedBody3Run
                != progressWindow.runID else {
            return false
        }
        if lastBody3Recovered?.plan.run
            == progressWindow.runID {
            foreground(progressWindow)
            return true
        }
        guard let recovered =
                progressWindow.recoverySnapshot else {
            foreground(progressWindow)
            return true
        }
        lastBody3Recovered = recovered
        body3RunWindow = nil
        body3ConfirmationWindow = nil
        body3ConfirmationRequest = nil
        body3Cancellation = nil
        progressWindow.close()
        showLastBody3Report()
        return true
    }

    @discardableResult
    private func terminateAfterConfirmedQuit()
        -> AppLifecycleRouteResult {
        let generation = lifecycleRouter.phase.generation
        var evidence = runWindow?.appDrainEvidence(
            generation: generation
        ) ?? lifecycleRouter.drainEvidence
        let body3Settled =
            body3RunWindow == nil || body3RunWindow?.isTerminal == true
        let confirmationsSettled =
            !confirmationInProgress
                && body3ConfirmationRequest == nil
                && body3ConfirmationWindow == nil
        let inventorySettled =
            !inventoryDiscoveryInProgress
                && activeInventoryGeneration == nil
        let authoritySettled = authorityCommitSession == nil
        let foregroundRunAdmissionClosed =
            runWindow == nil || evidence.processAdmissionClosed
        evidence.processAdmissionClosed =
            foregroundRunAdmissionClosed
                && inventorySettled
                && body3Settled
        let foregroundRunTasksSettled =
            runWindow == nil || evidence.ownedTasksSettled
        evidence.ownedTasksSettled =
            foregroundRunTasksSettled
                && inventorySettled
                && authoritySettled
                && body3Settled
        evidence.allChildrenReaped =
            evidence.allChildrenReaped && body3Settled
        evidence.body3WorkersTerminal = body3Settled
        evidence.confirmationWaitersSettled =
            confirmationsSettled
        evidence.inventoryAuthorityReleased = inventorySettled
        evidence.lifecycleAuthorityReleased = authoritySettled
        evidence.transactionsSettled =
            evidence.transactionsSettled && body3Settled
        evidence.preferenceOutcomeRecorded =
            lifecycleRouter.drainEvidence
                .preferenceOutcomeRecorded
        evidence.accountForRetainedCommands(CommandCustodian.hasRetainedWork)
        let route = lifecycleRouter.requestQuit(
            evidence: evidence
        )
        guard case .terminate = route else {
            lifecycleRouter.deferQuit()
            return route
        }
        guard lifecycleRouter.consumeTermination(
            generation: generation
        ) else {
            return .ignored
        }
        pendingCanonicalRootOnboarding = nil
        #if SHADOW_SYNC_TESTING
        if lifecycleRouter.deferredQuit == false {
            testInventoryTerminationCount += 1
        }
        if let testingQuitHandler {
            testingQuitHandler()
            return .terminate
        }
        #endif
        NSApp.terminate(nil)
        return .terminate
    }

    private func foreground(_ controller: NSWindowController) {
        guard isOpenForegroundTarget(controller),
              let window = controller.window else {
            return
        }
        (controller as? SelectionWindowController)?
            .prepareForPresentation()
        presentStatusItemGuidanceIfNeeded(on: controller)
        controller.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderFrontRegardless()
        makeKeyAndOrderFront(window)
        scheduleShortcutCollisionPresentation()
        if let pending = pendingForegroundRequest,
           pending.controller === controller,
           pending.windowNumber == window.windowNumber {
            if applicationIsActive,
               isForegroundRealityEstablished(for: pending) {
                finishForeground(pending, outcome: .success)
                return
            }
            return
        }
        if let pending = pendingForegroundRequest {
            finishForeground(pending, outcome: .superseded)
        }
        foregroundGeneration &+= 1
        let startedAt = foregroundNow
        let request = ForegroundRequest(
            generation: foregroundGeneration,
            controller: controller,
            windowNumber: window.windowNumber,
            startedAt: startedAt,
            deadline: startedAt + foregroundTimeoutNanoseconds
        )
        pendingForegroundRequest = request
        #if SHADOW_SYNC_TESTING
        if testingHostChrome && !testingUsesRealActivation {
            makeKeyAndOrderFront(window)
            finishForeground(request, outcome: .success)
            return
        }
        #endif
        installApplicationActivationObserver()
        installForegroundWindowObservers(for: request, window: window)
        if applicationIsActive,
           isForegroundRealityEstablished(for: request) {
            finishForeground(request, outcome: .success)
            return
        }
        #if SHADOW_SYNC_TESTING
        if testingSuppressesSystemActivation {
            if testingForegroundNowOverride != nil {
                scheduleForegroundRealityRevalidation(for: request)
                scheduleForegroundTimeout(for: request)
            }
            return
        }
        #endif
        requestApplicationActivation(for: request)
        if applicationIsActive,
           isForegroundRealityEstablished(for: request) {
            finishForeground(request, outcome: .success)
            return
        }
        scheduleForegroundRealityRevalidation(for: request)
        scheduleForegroundTimeout(for: request)
    }

    private func installApplicationActivationObserver() {
        guard applicationActivationObserver == nil else {
            return
        }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.completePendingForeground(observedAt: self?.foregroundNow)
            }
        }
    }

    private func installForegroundWindowObservers(
        for request: ForegroundRequest,
        window: NSWindow
    ) {
        clearForegroundWindowObservers()
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            foregroundWindowObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard self?.pendingForegroundRequest?.generation
                                == request.generation else {
                            return
                        }
                        self?.completePendingForeground(
                            observedAt: self?.foregroundNow
                        )
                    }
                }
            )
        }
    }

    private func completePendingForeground(observedAt: UInt64? = nil) {
        if let request = pendingForegroundRequest,
           (observedAt ?? foregroundNow) >= request.deadline {
            handleForegroundTimeout(generation: request.generation)
            return
        }
        guard applicationIsActive else {
            return
        }
        if let request = pendingForegroundRequest {
            guard isForegroundRealityEstablished(for: request) else {
                return
            }
            finishForeground(request, outcome: .success)
        } else {
            reconcileForegroundFailureFromCurrentReality()
        }
    }

    private func scheduleForegroundRealityRevalidation(
        for request: ForegroundRequest
    ) {
        guard pendingForegroundRequest?.generation == request.generation,
              pendingForegroundRequest?.windowNumber == request.windowNumber,
              foregroundRealityRevalidationWorkItem == nil else {
            return
        }
        let generation = request.generation
        let windowNumber = request.windowNumber
        let workItem = DispatchWorkItem { [weak self] in
            self?.performForegroundRealityRevalidation(
                generation: generation,
                windowNumber: windowNumber
            )
        }
        foregroundRealityRevalidationGeneration = generation
        foregroundRealityRevalidationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + foregroundRealityRevalidationDelay,
            execute: workItem
        )
    }

    private func performForegroundRealityRevalidation(
        generation: UInt64,
        windowNumber: Int
    ) {
        guard foregroundRealityRevalidationGeneration == generation else {
            return
        }
        foregroundRealityRevalidationWorkItem = nil
        foregroundRealityRevalidationGeneration = nil
        guard let request = pendingForegroundRequest,
              request.generation == generation,
              request.windowNumber == windowNumber else {
            return
        }
        guard isOpenForegroundTarget(request.controller),
              request.controller.window?.windowNumber == windowNumber else {
            finishForeground(request, outcome: .targetClosed)
            return
        }
        #if SHADOW_SYNC_TESTING
        testingForegroundRealityRevalidationCount += 1
        #endif
        completePendingForeground()
        guard let current = pendingForegroundRequest,
              current.generation == generation,
              current.windowNumber == windowNumber else {
            return
        }
        scheduleForegroundRealityRevalidation(for: current)
    }

    private func scheduleForegroundTimeout(for request: ForegroundRequest) {
        guard pendingForegroundRequest?.generation == request.generation,
              pendingForegroundRequest?.windowNumber == request.windowNumber else {
            return
        }
        foregroundTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleForegroundTimeout(generation: request.generation)
        }
        foregroundTimeoutWorkItem = workItem
        #if SHADOW_SYNC_TESTING
        let dispatchDeadline = testingForegroundNowOverride == nil
            ? DispatchTime(uptimeNanoseconds: request.deadline)
            : .now() + 60
        #else
        let dispatchDeadline = DispatchTime(uptimeNanoseconds: request.deadline)
        #endif
        DispatchQueue.main.asyncAfter(
            deadline: dispatchDeadline,
            execute: workItem
        )
    }

    private func handleForegroundTimeout(generation: UInt64) {
        guard let current = pendingForegroundRequest,
              current.generation == generation else {
            return
        }
        let realityEstablished = applicationIsActive
            && isForegroundRealityEstablished(for: current)
        if realityEstablished && foregroundNow < current.deadline {
            finishForeground(current, outcome: .success)
        } else {
            finishForeground(current, outcome: .timedOut)
        }
    }

    private var foregroundNow: UInt64 {
        #if SHADOW_SYNC_TESTING
        if let testingForegroundNowOverride {
            return testingForegroundNowOverride
        }
        #endif
        return DispatchTime.now().uptimeNanoseconds
    }

    private var applicationIsActive: Bool {
        #if SHADOW_SYNC_TESTING
        if let testingApplicationActiveOverride {
            return testingApplicationActiveOverride
        }
        #endif
        return NSApp.isActive
            && NSRunningApplication.current.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier
                == getpid()
    }

    private func isForegroundRealityEstablished(
        for request: ForegroundRequest
    ) -> Bool {
        guard isOpenForegroundTarget(request.controller),
              let window = request.controller.window,
              window.windowNumber == request.windowNumber else {
            return false
        }
        return foregroundReality(for: window).isEstablished
    }

    private func foregroundReality(for window: NSWindow) -> ForegroundReality {
        #if SHADOW_SYNC_TESTING
        if let testingForegroundRealitySnapshotOverride {
            return testingForegroundRealitySnapshotOverride
        }
        if let testingForegroundRealityOverride {
            return ForegroundReality(
                applicationActive: testingForegroundRealityOverride,
                windowVisible: testingForegroundRealityOverride,
                windowKey: testingForegroundRealityOverride,
                windowOnScreen: testingForegroundRealityOverride,
                windowOnActiveSpace: testingForegroundRealityOverride
            )
        }
        #endif
        let onScreen = window.screen != nil
            && NSScreen.screens.contains {
                $0.frame.intersects(window.frame)
            }
        return ForegroundReality(
            applicationActive: applicationIsActive,
            windowVisible: window.isVisible,
            windowKey: window.isKeyWindow || window.isMainWindow,
            windowOnScreen: onScreen,
            windowOnActiveSpace: window.isOnActiveSpace
        )
    }

    private func reconcileForegroundFailureFromCurrentReality() {
        guard foregroundStatusMessage != nil,
              pendingForegroundRequest == nil,
              let controller = currentPrimaryController(),
              isOpenForegroundTarget(controller),
              let window = controller.window,
              foregroundReality(for: window).isEstablished else {
            return
        }
        clearForegroundFailure()
    }

    private func currentPrimaryController() -> NSWindowController? {
        currentOperatorSurface(
            for: .passiveReconciliation
        )?.controller
    }

    private func currentPrimaryWindow() -> NSWindow? {
        currentPrimaryController()?.window
    }

    private func presentStatusItemGuidanceIfNeeded(
        on controller: NSWindowController
    ) {
        reconcileStatusItemGuidanceWithCurrentVisibility()
        if let selection = controller as? SelectionWindowController {
            guard statusItemGuidance.hasPendingGuidance,
                  inlineStatusSource == nil,
                  selection.canPresentStatusItemGuidance,
                  presentInlineStatus(
                    .hiddenStatusItemGuidance,
                    on: selection
                  ) else {
                return
            }
        } else if let run = controller as? RunWindowController {
            guard statusItemGuidance.hasPendingGuidance,
                  inlineStatusSource == nil,
                  run.canPresentStatusItemGuidance,
                  presentInlineStatus(
                    .hiddenStatusItemGuidance,
                    on: run
                  ) else {
                return
            }
        } else {
            return
        }
        statusItemGuidance.markGuidancePresented()
        #if SHADOW_SYNC_TESTING
        testStatusItemGuidancePresentationCount += 1
        #endif
    }

    @discardableResult
    private func presentInlineStatus(
        _ source: InlineStatusSource,
        on controller: NSWindowController?
    ) -> Bool {
        if let current = inlineStatusSource, current != source {
            guard source == .logOpenFailure else {
                return false
            }
            if current == .hiddenStatusItemGuidance {
                statusItemGuidance.requeuePresentedGuidance()
            }
        }
        inlineStatusSource = source
        let message = inlineStatusMessage
        if let selection = controller as? SelectionWindowController {
            selection.presentInlineMessage(message)
        } else if let run = controller as? RunWindowController {
            run.presentInlineMessage(message)
        }
        return true
    }

    private func clearInlineStatus(
        _ source: InlineStatusSource,
        retryGuidance: Bool
    ) {
        guard inlineStatusSource == source else {
            return
        }
        inlineStatusSource = nil
        selectionWindow?.presentInlineMessage(nil)
        runWindow?.presentInlineMessage(nil)
        historicalViewer?.presentInlineMessage(nil)
        if retryGuidance, let controller = currentPrimaryController() {
            presentStatusItemGuidanceIfNeeded(on: controller)
        }
    }

    private func requestApplicationActivation(
        for request: ForegroundRequest
    ) {
        #if SHADOW_SYNC_TESTING
        testingActivationCallCount += 1
        if let activationAccepted = testingActivationAcceptedOverride {
            if testingBecomesActiveAfterActivation {
                testingApplicationActiveOverride = true
            }
            completeApplicationActivation(
                generation: request.generation,
                processIdentifier: activationAccepted ? getpid() : nil,
                failed: !activationAccepted
            )
            return
        }
        #endif
        foregroundLogger.notice(
            "activation requested generation=\(request.generation, privacy: .public)"
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        let generation = request.generation
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            let processIdentifier = application?.processIdentifier
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.completeApplicationActivation(
                    generation: generation,
                    processIdentifier: processIdentifier,
                    failed: failed
                )
            }
        }
    }

    private func completeApplicationActivation(
        generation: UInt64,
        processIdentifier: pid_t?,
        failed: Bool
    ) {
        guard let request = pendingForegroundRequest,
              request.generation == generation else {
            foregroundLogger.notice(
                "activation completed generation=\(generation, privacy: .public) reality=superseded"
            )
            return
        }
        guard !failed, processIdentifier == getpid() else {
            if applicationIsActive {
                foregroundLogger.notice(
                    "activation completed generation=\(generation, privacy: .public) reality=already-active"
                )
                reassertForegroundAfterActivation(request)
                return
            }
            #if SHADOW_SYNC_TESTING
            testingActivationFailureCount += 1
            #endif
            foregroundLogger.error(
                "activation failed generation=\(generation, privacy: .public) reason=workspace"
            )
            finishForeground(request, outcome: .denied)
            return
        }
        #if SHADOW_SYNC_TESTING
        testingActivationCompletionCount += 1
        #endif
        foregroundLogger.notice(
            "activation completed generation=\(generation, privacy: .public)"
        )
        reassertForegroundAfterActivation(request)
    }

    private func reassertForegroundAfterActivation(
        _ request: ForegroundRequest
    ) {
        guard pendingForegroundRequest?.generation == request.generation,
              isOpenForegroundTarget(request.controller),
              let window = request.controller.window,
              window.windowNumber == request.windowNumber else {
            if pendingForegroundRequest?.generation == request.generation {
                finishForeground(request, outcome: .targetClosed)
            }
            return
        }
        #if SHADOW_SYNC_TESTING
        testingActivationReassertionCount += 1
        #endif
        request.controller.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderFrontRegardless()
        makeKeyAndOrderFront(window)
        let reality = foregroundReality(for: window)
        foregroundLogger.notice(
            "activation reality generation=\(request.generation, privacy: .public) active=\(reality.applicationActive, privacy: .public) visible=\(reality.windowVisible, privacy: .public) key=\(reality.windowKey, privacy: .public) onscreen=\(reality.windowOnScreen, privacy: .public) activeSpace=\(reality.windowOnActiveSpace, privacy: .public)"
        )
        if reality.isEstablished {
            finishForeground(request, outcome: .success)
        }
    }

    private func makeKeyAndOrderFront(_ window: NSWindow) {
        #if SHADOW_SYNC_TESTING
        testingKeyWindowOrderCount += 1
        #endif
        window.makeKeyAndOrderFront(nil)
    }

    private func finishForeground(
        _ request: ForegroundRequest,
        outcome: ForegroundOutcome
    ) {
        guard let current = pendingForegroundRequest,
              current.generation == request.generation else {
            return
        }
        if outcome != .targetClosed,
           outcome != .superseded,
           (!isOpenForegroundTarget(request.controller)
            || request.controller.window?.windowNumber
                != request.windowNumber) {
            finishForeground(request, outcome: .targetClosed)
            return
        }
        let outcomeName: String
        switch outcome {
        case .success: outcomeName = "success"
        case .denied: outcomeName = "denied"
        case .timedOut: outcomeName = "timed-out"
        case .targetClosed: outcomeName = "target-closed"
        case .superseded: outcomeName = "superseded"
        }
        let realityEstablished =
            request.controller.window.map {
                foregroundReality(for: $0).isEstablished
            } ?? false
        foregroundLogger.notice(
            "foreground finished generation=\(request.generation, privacy: .public) outcome=\(outcomeName, privacy: .public) reality=\(realityEstablished, privacy: .public)"
        )
        clearForegroundRequestObservation()
        switch outcome {
        case .success:
            pendingForegroundRequest = nil
            #if SHADOW_SYNC_TESTING
            testingForegroundSuccessCount += 1
            #endif
            clearForegroundFailure()
            guard let window = request.controller.window else { return }
            request.controller.showWindow(nil)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            makeKeyAndOrderFront(window)
        case .denied, .timedOut:
            pendingForegroundRequest = nil
            renderForegroundFailure(on: request.controller)
        case .targetClosed:
            terminateForegroundRequest(
                current,
                preservePublishedFailure: foregroundStatusMessage != nil
            )
        case .superseded:
            pendingForegroundRequest = nil
        }
        scheduleShortcutCollisionPresentation()
    }

    private func cancelForegroundRequest(for controller: NSWindowController) {
        guard let pending = pendingForegroundRequest,
              pending.controller === controller else {
            return
        }
        finishForeground(pending, outcome: .targetClosed)
    }

    private func handleForegroundTargetDismissed(
        _ controller: NSWindowController
    ) {
        cancelForegroundRequest(for: controller)
        if !(controller is OperationContentionWindowController),
           foregroundFailureController === controller {
            clearForegroundFailure(retryGuidance: false)
        }
        if inlineStatusSource == .hiddenStatusItemGuidance {
            clearInlineStatus(
                .hiddenStatusItemGuidance,
                retryGuidance: false
            )
        } else if inlineStatusSource == .foregroundUnavailable,
                  foregroundFailureController === controller {
            clearForegroundInlineMessage(retryGuidance: false)
        }
    }

    private func terminateForegroundRequest(
        _ request: ForegroundRequest,
        preservePublishedFailure: Bool
    ) {
        guard pendingForegroundRequest?.generation == request.generation else {
            return
        }
        pendingForegroundRequest = nil
        if preservePublishedFailure {
            if foregroundFailureController === request.controller {
                clearForegroundInlineMessage()
            }
        } else {
            clearForegroundFailure()
        }
    }

    private func isOpenForegroundTarget(
        _ controller: NSWindowController
    ) -> Bool {
        if controller is OperationContentionWindowController {
            return operationContentionWindowController === controller
                && operationContentionAlertToken != nil
                && operationContentionAlert != nil
        }
        if let selection = controller as? SelectionWindowController {
            return selection.isPresentationOpen
        }
        if let run = controller as? RunWindowController {
            return run.isPresentationOpen
        }
        if let canonicalRoot =
            controller as? CanonicalRootConfirmationWindowController {
            return canonicalRoot.isPresentationOpen
        }
        return controller.window != nil
    }

    private func clearApplicationActivationObserver() {
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
    }

    private func clearForegroundRequestObservation() {
        foregroundTimeoutWorkItem?.cancel()
        foregroundTimeoutWorkItem = nil
        foregroundRealityRevalidationWorkItem?.cancel()
        foregroundRealityRevalidationWorkItem = nil
        foregroundRealityRevalidationGeneration = nil
        clearForegroundWindowObservers()
    }

    private func clearForegroundWindowObservers() {
        for observer in foregroundWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        foregroundWindowObservers.removeAll()
    }

    private func clearForegroundFailure(retryGuidance: Bool = true) {
        #if SHADOW_SYNC_TESTING
        if foregroundStatusMessage != nil {
            testingForegroundFailureClearCount += 1
        }
        #endif
        foregroundStatusMessage = nil
        foregroundFailureController = nil
        clearForegroundInlineMessage(retryGuidance: retryGuidance)
        let shortcutHelp = shortcutAvailable
            ? nil
            : ShadowSyncPresentation.shortcutUnavailableText
        statusItem?.button?.toolTip = shortcutHelp
        statusItem?.button?.setAccessibilityHelp(shortcutHelp)
    }

    private func clearForegroundInlineMessage(
        retryGuidance: Bool = true
    ) {
        clearInlineStatus(
            .foregroundUnavailable,
            retryGuidance: retryGuidance
        )
    }

    private func renderForegroundFailure(on controller: NSWindowController) {
        reconcileStatusItemGuidanceWithCurrentVisibility()
        let failure = statusItemGuidance.hasObservedHiddenStatusItem
            ? ShadowSyncPresentation
                .foregroundUnavailableWithHiddenStatusItem
            : ShadowSyncPresentation.foregroundUnavailable
        foregroundStatusMessage = failure
        foregroundFailureController = controller
        _ = presentInlineStatus(.foregroundUnavailable, on: controller)
        statusItem?.button?.toolTip = failure
        statusItem?.button?.setAccessibilityHelp(failure)
    }

    private func scheduleShortcutCollisionPresentation() {
        guard shortcutCollisionPresentation == .pending,
              !collisionPresentationScheduled else {
            return
        }
        collisionPresentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collisionPresentationScheduled = false
            self.presentPendingShortcutCollisionOnCurrentSurface()
        }
    }

    private func presentPendingShortcutCollision(on window: NSWindow) {
        guard shortcutCollisionPresentation == .pending,
              isSafeCollisionParent(window),
              window.attachedSheet == nil else {
            return
        }
        shortcutCollisionGeneration &+= 1
        let token = shortcutCollisionGeneration
        shortcutCollisionPresentation = .presenting(token)
        #if SHADOW_SYNC_TESTING
        if testingHostChrome {
            testShortcutCollisionAttemptCount += 1
            if testingCollisionAttachmentSucceeds {
                testShortcutCollisionPresentationCount += 1
                testShortcutCollisionPresentation = (
                    ShadowSyncPresentation.shortcutUnavailable,
                    ShadowSyncPresentation.shortcutUnavailableText
                )
                shortcutCollisionPresentation = .shown
            } else {
                shortcutCollisionPresentation = .pending
            }
            return
        }
        #endif
        let alert = ShadowSyncAlertFactory.shortcutUnavailable()
        alert.beginSheetModal(for: window) { [weak self, weak window, weak alert] _ in
            guard let self,
                  self.shortcutCollisionPresentation == .presenting(token)
                    else {
                return
            }
            if let window, let alert,
               window.attachedSheet === alert.window {
                self.shortcutCollisionPresentation = .shown
            } else {
                self.shortcutCollisionPresentation = .pending
            }
        }
        verifyShortcutCollisionAttachment(
            token: token,
            parent: window,
            alert: alert
        )
        if shortcutCollisionPresentation == .presenting(token) {
            DispatchQueue.main.async { [weak self, weak window, weak alert] in
                guard let self,
                      self.shortcutCollisionPresentation
                        == .presenting(token) else {
                    return
                }
                guard let window, let alert else {
                    self.shortcutCollisionPresentation = .pending
                    return
                }
                self.verifyShortcutCollisionAttachment(
                    token: token,
                    parent: window,
                    alert: alert
                )
                if self.shortcutCollisionPresentation == .presenting(token) {
                    self.shortcutCollisionPresentation = .pending
                }
            }
        }
    }

    private func verifyShortcutCollisionAttachment(
        token: UInt64,
        parent: NSWindow,
        alert: NSAlert
    ) {
        guard shortcutCollisionPresentation == .presenting(token) else {
            return
        }
        guard isSafeCollisionParent(parent),
              parent.attachedSheet === alert.window else {
            return
        }
        shortcutCollisionPresentation = .shown
    }

    private func isSafeCollisionParent(_ window: NSWindow) -> Bool {
        guard window.isVisible else {
            return false
        }
        if let runWindow, runWindow.isPresentationOpen,
           runWindow.window === window {
            return true
        }
        if let selectionWindow, selectionWindow.isPresentationOpen,
           selectionWindow.window === window {
            return true
        }
        if let historicalViewer, historicalViewer.isPresentationOpen,
           historicalViewer.window === window {
            return true
        }
        return false
    }

    private func presentPendingShortcutCollisionOnCurrentSurface() {
        guard let surface = currentOperatorSurface(
                for: .passiveReconciliation
              ),
              [
                OperatorSurfaceKind.repositoryCards,
                .selection,
                .run,
                .historical,
              ].contains(surface.kind),
              let controller = surface.controller,
              let window = controller.window else {
            return
        }
        controller.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        presentPendingShortcutCollision(on: window)
    }

    #if SHADOW_SYNC_TESTING
    func testStartNewRun() {
        startNewRun()
    }

    func testingTriggerShortcut() {
        foregroundCurrentSurface()
    }

    func testingHandleDuplicateActivation() {
        handleDuplicateActivation()
    }

    func testingCurrentOperatorSurfaceKind(
        explicit: Bool
    ) -> String? {
        currentOperatorSurface(
            for: explicit
                ? .explicitInvocation : .passiveReconciliation
        )?.kind.rawValue
    }

    func testingRequestStartOperationContention() {
        requestOperationContention(.startNewRun)
        guard let token = operationContention.currentToken else {
            return
        }
        applyOperationContentionEffects(
            operationContention.observe(.held, token: token)
        )
    }

    func testingBeginRepositoryInventoryDiscovery(
        presentResult: Bool
    ) -> Bool {
        beginRepositoryInventoryDiscovery(
            presentResult: presentResult
        ) == nil
    }

    func testingBeginRepositoryInventoryPreflight() -> UInt64? {
        guard !inventoryDiscoveryInProgress else { return nil }
        inventoryGeneration &+= 1
        let generation = inventoryGeneration
        activeInventoryGeneration = generation
        inventoryCancellation = CancellationToken()
        testLifecycleTrace.append("inventory:requested:\(generation)")
        let controller: RepositoryCardSelectionWindowController
        if let current =
                selectionWindow
                    as? RepositoryCardSelectionWindowController,
           current.isPresentationOpen {
            controller = current
            configureTestingRepositoryCardController(controller)
            controller.showPreparingRepositoryList()
        } else {
            controller = RepositoryCardSelectionWindowController()
            configureTestingRepositoryCardController(controller)
            selectionWindow = controller
        }
        foreground(controller)
        testLifecycleTrace.append("inventory:surface_presented:\(generation)")
        if testingInventoryBeginFailure == .hidden
            || testingInventoryBeginFailure == .queuedQuit {
            controller.window?.performClose(nil)
        }
        if testingInventoryBeginFailure == .queuedQuit {
            lifecycleRouter.deferQuit()
        }
        if let reason = beginRepositoryInventoryDiscovery(
            presentResult: true
        ) {
            testingInventoryBeginFailure = nil
            resolveRepositoryInventoryBeginFailure(
                generation: generation,
                loadingController: controller,
                reason: reason
            )
            return generation
        }
        return generation
    }

    func testingForceNextInventoryBeginFailure(
        hidden: Bool,
        queuedQuit: Bool = false
    ) {
        testingInventoryBeginFailure = queuedQuit
            ? .queuedQuit : (hidden ? .hidden : .visible)
    }

    private func configureTestingRepositoryCardController(
        _ controller: RepositoryCardSelectionWindowController
    ) {
        configureSelectionCancellation(controller)
        controller.onRetryInventory = {
            [weak self, weak controller] in
            guard let self, let controller,
                  self.selectionWindow === controller,
                  !self.inventoryDiscoveryInProgress else {
                return
            }
            self.testInventoryRetryCount += 1
            controller.showPreparingRepositoryList()
            _ = self.testingBeginRepositoryInventoryPreflight()
        }
    }

    @discardableResult
    func testingCompleteRepositoryInventorySuccess(
        _ inventory: RepositoryInventory,
        generation: UInt64
    ) -> Bool {
        guard activeInventoryGeneration == generation else { return false }
        let shouldPresent = finishRepositoryInventoryDiscovery()
        inventoryCancellation = nil
        activeInventoryGeneration = nil
        if lifecycleRouter.deferredQuit {
            if let controller =
                selectionWindow
                    as? RepositoryCardSelectionWindowController {
                handleForegroundTargetDismissed(controller)
                selectionWindow = nil
                controller.close()
            }
            terminateAfterConfirmedQuit()
            return true
        }
        guard shouldPresent,
              let controller =
                selectionWindow
                    as? RepositoryCardSelectionWindowController else {
            return false
        }
        if !inventory.onboardingProposals.isEmpty {
            stageCanonicalRootOnboarding(
                inventory,
                generation: generation,
                foregroundResult:
                    controller.window?.isVisible == true
            )
            testLifecycleTrace.append(
                "inventory:onboarding_pending:\(generation)"
            )
            return true
        }
        if let pending = pendingCanonicalRootOnboarding,
           pending.generation <= generation {
            pendingCanonicalRootOnboarding = nil
        }
        guard controller.apply(
                inventory: inventory,
                protectedPaths: [],
                protectionBoundaryEstablished: true
              ) else {
            return false
        }
        testLifecycleTrace.append("inventory:finished:\(generation)")
        return true
    }

    private func testingPresentPendingCanonicalRootOnboarding(
        _ pending: PendingCanonicalRootOnboarding
    ) {
        let controller = CanonicalRootConfirmationWindowController(
            proposals: pending.inventory.onboardingProposals
        )
        controller.onCancel = { [weak self, weak controller] in
            guard let self,
                  self.canonicalRootWindow === controller else {
                return
            }
            controller?.close()
            self.canonicalRootWindow = nil
        }
        controller.onConfirm = {
            [weak self, weak controller] _ in
            guard let self,
                  self.pendingCanonicalRootOnboarding?
                    .generation == pending.generation else {
                return
            }
            self.pendingCanonicalRootOnboarding = nil
            controller?.close()
            self.canonicalRootWindow = nil
            let cards = RepositoryCardSelectionWindowController(
                inventory: pending.inventory,
                protectedPaths: [],
                protectionBoundaryEstablished: true
            )
            self.configureTestingRepositoryCardController(cards)
            self.selectionWindow = cards
            self.testCanonicalRootInventoryPresentationCount += 1
            self.foreground(cards)
        }
        canonicalRootWindow = controller
        foreground(controller)
    }

    func testingRecordRepositoryInventoryAuthority(
        generation: UInt64
    ) {
        guard activeInventoryGeneration == generation else { return }
        testLifecycleTrace.append("inventory:authority_acquired:\(generation)")
    }

    func testingRecordRepositoryInventoryChild(
        generation: UInt64,
        count: Int
    ) {
        guard activeInventoryGeneration == generation,
              inventoryCancellation?
                .areFutureChildAdmissionsClosed == false else {
            return
        }
        testLifecycleTrace.append(
            "inventory:child:\(generation):\(count)"
        )
    }

    @discardableResult
    func testingCompleteRepositoryInventoryFailure(
        generation: UInt64
    ) -> Bool {
        guard activeInventoryGeneration == generation else { return false }
        let shouldPresent = finishRepositoryInventoryDiscovery()
        inventoryCancellation = nil
        activeInventoryGeneration = nil
        if lifecycleRouter.deferredQuit {
            if let controller =
                    selectionWindow
                        as? RepositoryCardSelectionWindowController {
                handleForegroundTargetDismissed(controller)
                selectionWindow = nil
                controller.close()
            }
            terminateAfterConfirmedQuit()
            return true
        }
        if shouldPresent,
           let controller =
                selectionWindow
                    as? RepositoryCardSelectionWindowController {
            let shouldForeground =
                controller.window?.isVisible == true
            controller.showInventoryFailure(
                "Repository inventory failed. Try again."
            )
            if shouldForeground {
                foreground(controller)
            }
        }
        testLifecycleTrace.append("inventory:failed:\(generation)")
        return true
    }

    var testingInventoryPreflightIdentity: ObjectIdentifier? {
        (selectionWindow as? RepositoryCardSelectionWindowController)
            .map(ObjectIdentifier.init)
    }

    var testingInventoryController:
        RepositoryCardSelectionWindowController? {
        selectionWindow as? RepositoryCardSelectionWindowController
    }

    var testingInventoryPreflightWindowNumber: Int? {
        (selectionWindow as? RepositoryCardSelectionWindowController)?
            .window?.windowNumber
    }

    var testingInventoryPreflightIsLoading: Bool {
        (selectionWindow as? RepositoryCardSelectionWindowController)?
            .isPreparingRepositoryList == true
    }

    var testingInventoryFailureState: (String, Bool)? {
        guard let controller =
                selectionWindow
                    as? RepositoryCardSelectionWindowController else {
            return nil
        }
        return (
            controller.testingInventoryStatus,
            controller.testingInventoryRetryVisible
        )
    }

    var testingInventoryFutureChildrenStopped: Bool {
        inventoryCancellation?
            .areFutureChildAdmissionsClosed == true
    }

    @discardableResult
    func testingCompleteRepositoryInventoryDiscovery() -> Bool {
        let shouldPresent = finishRepositoryInventoryDiscovery()
        if shouldPresent {
            testInventoryDiscoveryPresentationCount += 1
        }
        return shouldPresent
    }

    var testInventoryPresentationPending: Bool {
        inventoryPresentationRequested
    }

    var testInventoryDiscoveryInProgress: Bool {
        inventoryDiscoveryInProgress
    }

    var testingActiveInventoryGeneration: UInt64? {
        activeInventoryGeneration
    }

    var testingInventoryCancellationExists: Bool {
        inventoryCancellation != nil
    }

    var testingInventoryQuitIsPending: Bool {
        lifecycleRouter.deferredQuit
    }

    func testingTriggerShortcutWithActivationEvidence() -> (
        handlerOnMain: Bool,
        admittedBeforeReturn: Bool,
        activationReachedBeforeReturn: Bool,
        realityGateCompletedBeforeReturn: Bool,
        status: OSStatus
    ) {
        testingUsesRealActivation = true
        testingApplicationActiveOverride = false
        testingActivationAcceptedOverride = true
        testingBecomesActiveAfterActivation = true
        testingForegroundRealityOverride = true
        let generationBefore = foregroundGeneration
        let activationCallsBefore = testingActivationCallCount
        let successesBefore = testingForegroundSuccessCount
        var handlerOnMain = false
        var admittedInsideHandler = false
        var activationReachedInsideHandler = false
        var realityGateCompletedInsideHandler = false
        let shortcut = GlobalShortcut { [weak self] in
            guard let self else { return }
            handlerOnMain = Thread.isMainThread
            self.requestForegroundCurrentSurface(action: .hotkey)
            admittedInsideHandler =
                self.foregroundGeneration > generationBefore
            activationReachedInsideHandler =
                self.testingActivationCallCount > activationCallsBefore
            realityGateCompletedInsideHandler =
                self.testingForegroundSuccessCount > successesBefore
                    && self.pendingForegroundRequest == nil
        }
        let status = shortcut.testingDispatch()
        testingForegroundRealityOverride = nil
        testingBecomesActiveAfterActivation = false
        testingActivationAcceptedOverride = nil
        testingApplicationActiveOverride = nil
        testingUsesRealActivation = false
        return (
            handlerOnMain,
            admittedInsideHandler
                && foregroundGeneration > generationBefore,
            activationReachedInsideHandler
                && testingActivationCallCount > activationCallsBefore,
            realityGateCompletedInsideHandler
                && testingForegroundSuccessCount > successesBefore
                && pendingForegroundRequest == nil,
            status
        )
    }

    func testingTriggerStatusActivation() {
        foregroundCurrentSurface()
    }

    func testingTriggerAppReopen() {
        foregroundCurrentSurface()
    }

    func testingTriggerMenuStart() {
        startNewRunAction()
    }

    func testingPresentPendingShortcutCollision() {
        presentPendingShortcutCollisionOnCurrentSurface()
    }

    func testingSetCollisionAttachmentSucceeds(_ succeeds: Bool) {
        testingCollisionAttachmentSucceeds = succeeds
    }

    func testingShowLastReport() {
        showLastReport()
    }

    func testingShowLastReportWithActivationEvidence() {
        testingUsesRealActivation = true
        showLastReport()
        testingUsesRealActivation = false
    }

    func testingInstallStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
    }

    func testingRemoveStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func testingCompleteStatusItemVisibilityCheck(
        _ snapshot: StatusItemVisibilitySnapshot
    ) {
        completeStatusItemVisibilityCheck(snapshot)
    }

    func testingSetCurrentStatusItemVisibilitySnapshot(
        _ snapshot: StatusItemVisibilitySnapshot?
    ) {
        testingStatusItemVisibilitySnapshot = snapshot
    }

    func testingBeginForegroundRequest(_ controller: NSWindowController) {
        testingUsesRealActivation = true
        testingSuppressesSystemActivation = true
        testingApplicationActiveOverride = false
        foreground(controller)
        testingApplicationActiveOverride = nil
        testingSuppressesSystemActivation = false
        testingUsesRealActivation = false
    }

    func testingBeginTimedForegroundRequest(
        _ controller: NSWindowController,
        startNanoseconds: UInt64 = 1_000_000_000
    ) {
        testingForegroundNowOverride = startNanoseconds
        testingBeginForegroundRequest(controller)
    }

    func testingAdvanceForeground(seconds: TimeInterval) {
        guard let pending = pendingForegroundRequest else { return }
        testingForegroundNowOverride = pending.startedAt
            + UInt64(max(0, seconds) * 1_000_000_000)
    }

    func testingPostForegroundWindowEvent(
        applicationActive: Bool,
        foregroundEstablished: Bool
    ) {
        guard let window = pendingForegroundRequest?.controller.window else {
            return
        }
        testingApplicationActiveOverride = applicationActive
        testingForegroundRealityOverride = foregroundEstablished
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        testingForegroundRealityOverride = nil
        testingApplicationActiveOverride = nil
    }

    func testingRepeatPendingForegroundRequest(
        applicationActive: Bool,
        foregroundEstablished: Bool
    ) {
        guard let controller = pendingForegroundRequest?.controller else {
            return
        }
        testingUsesRealActivation = true
        testingApplicationActiveOverride = applicationActive
        testingForegroundRealityOverride = foregroundEstablished
        foreground(controller)
        testingForegroundRealityOverride = nil
        testingApplicationActiveOverride = nil
        testingUsesRealActivation = false
    }

    func testingRequestForeground(
        _ controller: NSWindowController,
        activationAccepted: Bool,
        activeBefore: Bool,
        activeAfterActivation: Bool = false
    ) {
        testingUsesRealActivation = true
        testingApplicationActiveOverride = activeBefore
        testingActivationAcceptedOverride = activationAccepted
        testingBecomesActiveAfterActivation = activeAfterActivation
        testingForegroundRealityOverride = activeAfterActivation ? true : nil
        foreground(controller)
        if !activationAccepted,
           testingApplicationActiveOverride != true,
           pendingForegroundRequest?.controller === controller {
            testingResolveForegroundDenied()
        }
        testingForegroundRealityOverride = nil
        testingBecomesActiveAfterActivation = false
        testingActivationAcceptedOverride = nil
        testingApplicationActiveOverride = nil
        testingUsesRealActivation = false
    }

    func testingFireForegroundTimeout(
        applicationActive: Bool,
        foregroundEstablished: Bool = false
    ) {
        guard let generation = pendingForegroundRequest?.generation else {
            return
        }
        testingApplicationActiveOverride = applicationActive
        testingForegroundRealityOverride = foregroundEstablished
        handleForegroundTimeout(generation: generation)
        testingForegroundRealityOverride = nil
        testingApplicationActiveOverride = nil
    }

    func testingFireForegroundRealityRevalidation(
        generation: UInt64? = nil,
        windowNumber: Int? = nil,
        windowOnActiveSpace: Bool
    ) {
        guard let pending = pendingForegroundRequest else {
            return
        }
        let generation =
            generation ?? foregroundRealityRevalidationGeneration
        guard let generation else {
            return
        }
        if foregroundRealityRevalidationGeneration == generation {
            foregroundRealityRevalidationWorkItem?.cancel()
        }
        testingApplicationActiveOverride = true
        testingForegroundRealityOverride = windowOnActiveSpace
        performForegroundRealityRevalidation(
            generation: generation,
            windowNumber: windowNumber ?? pending.windowNumber
        )
        testingForegroundRealityOverride = nil
        testingApplicationActiveOverride = nil
    }

    func testingReconcileForegroundActivation(
        applicationActive: Bool,
        foregroundEstablished: Bool? = nil
    ) {
        testingApplicationActiveOverride = applicationActive
        testingForegroundRealityOverride = foregroundEstablished
        completePendingForeground()
        testingForegroundRealityOverride = nil
        testingApplicationActiveOverride = nil
    }

    func testingReconcileForegroundFailure(
        applicationActive: Bool,
        windowVisible: Bool,
        windowKey: Bool,
        windowOnScreen: Bool,
        windowOnActiveSpace: Bool
    ) {
        testingForegroundRealitySnapshotOverride = ForegroundReality(
            applicationActive: applicationActive,
            windowVisible: windowVisible,
            windowKey: windowKey,
            windowOnScreen: windowOnScreen,
            windowOnActiveSpace: windowOnActiveSpace
        )
        reconcileForegroundFailureFromCurrentReality()
        testingForegroundRealitySnapshotOverride = nil
    }

    func testingBeginCurrentForegroundRequest() {
        testingUsesRealActivation = true
        testingSuppressesSystemActivation = true
        testingApplicationActiveOverride = false
        foregroundCurrentSurface()
        testingApplicationActiveOverride = nil
        testingSuppressesSystemActivation = false
        testingUsesRealActivation = false
    }

    func testingResolveForegroundSuccess(generation: UInt64? = nil) {
        guard let pending = pendingForegroundRequest else { return }
        let request = ForegroundRequest(
            generation: generation ?? pending.generation,
            controller: pending.controller,
            windowNumber: pending.windowNumber,
            startedAt: pending.startedAt,
            deadline: pending.deadline
        )
        finishForeground(request, outcome: .success)
    }

    func testingResolveForegroundDenied(generation: UInt64? = nil) {
        guard let pending = pendingForegroundRequest else { return }
        let request = ForegroundRequest(
            generation: generation ?? pending.generation,
            controller: pending.controller,
            windowNumber: pending.windowNumber,
            startedAt: pending.startedAt,
            deadline: pending.deadline
        )
        finishForeground(request, outcome: .denied)
    }

    func testingResolveForegroundTimeout(generation: UInt64? = nil) {
        guard let pending = pendingForegroundRequest else { return }
        let request = ForegroundRequest(
            generation: generation ?? pending.generation,
            controller: pending.controller,
            windowNumber: pending.windowNumber,
            startedAt: pending.startedAt,
            deadline: pending.deadline
        )
        finishForeground(request, outcome: .timedOut)
    }

    func testingCompleteApplicationActivation(
        generation: UInt64,
        processMatchesCurrent: Bool,
        failed: Bool = false
    ) {
        completeApplicationActivation(
            generation: generation,
            processIdentifier: processMatchesCurrent ? getpid() : nil,
            failed: failed
        )
    }

    static func testingForegroundRealityIsEstablished(
        applicationActive: Bool,
        windowVisible: Bool,
        windowKey: Bool,
        windowOnScreen: Bool,
        windowOnActiveSpace: Bool
    ) -> Bool {
        ForegroundReality(
            applicationActive: applicationActive,
            windowVisible: windowVisible,
            windowKey: windowKey,
            windowOnScreen: windowOnScreen,
            windowOnActiveSpace: windowOnActiveSpace
        ).isEstablished
    }

    func testingCancelForegroundRequest(
        _ controller: NSWindowController
    ) {
        handleForegroundTargetDismissed(controller)
    }

    func testingInstallForegroundStatusItem() -> Bool {
        guard testingHostChrome, statusItem == nil else { return false }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = false
        statusItem = item
        return item.button != nil
    }

    func testingRemoveForegroundStatusItem() {
        guard testingHostChrome, let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    func testingTerminateForegroundObservation() {
        pendingForegroundRequest = nil
        clearForegroundRequestObservation()
        clearApplicationActivationObserver()
        testingForegroundNowOverride = nil
    }

    var testingForegroundRequestObservation: (
        windowObservers: Int,
        timeoutScheduled: Bool,
        realityRevalidationScheduled: Bool
    ) {
        (
            foregroundWindowObservers.count,
            foregroundTimeoutWorkItem != nil,
            foregroundRealityRevalidationWorkItem != nil
        )
    }

    var testingForegroundRealityRevalidationIdentity: (
        generation: UInt64,
        windowNumber: Int
    )? {
        guard let generation = foregroundRealityRevalidationGeneration,
              let pending = pendingForegroundRequest,
              pending.generation == generation else {
            return nil
        }
        return (generation, pending.windowNumber)
    }

    var testingForegroundSnapshot: (
        generation: UInt64?,
        issuedGeneration: UInt64,
        target: ObjectIdentifier?,
        timedOut: Bool,
        observerInstalled: Bool,
        activationCalls: Int,
        keyWindowOrders: Int,
        successes: Int,
        inline: String?,
        menu: String?,
        tooltip: String?,
        accessibilityHelp: String?,
        collisionCount: Int,
        collisionAttempts: Int,
        collisionState: String,
        activationCompletions: Int,
        activationFailures: Int,
        activationReassertions: Int,
        realityRevalidations: Int,
        failureClears: Int
    ) {
        (
            pendingForegroundRequest?.generation,
            foregroundGeneration,
            pendingForegroundRequest.map {
                ObjectIdentifier($0.controller)
            },
            pendingForegroundRequest == nil
                && foregroundStatusMessage != nil,
            applicationActivationObserver != nil,
            testingActivationCallCount,
            testingKeyWindowOrderCount,
            testingForegroundSuccessCount,
            inlineStatusMessage,
            foregroundStatusMessage,
            statusItem?.button?.toolTip,
            statusItem?.button?.accessibilityHelp(),
            testShortcutCollisionPresentationCount,
            testShortcutCollisionAttemptCount,
            {
                switch shortcutCollisionPresentation {
                case .none: return "none"
                case .pending: return "pending"
                case .presenting: return "presenting"
                case .shown: return "shown"
                }
            }(),
            testingActivationCompletionCount,
            testingActivationFailureCount,
            testingActivationReassertionCount,
            testingForegroundRealityRevalidationCount,
            testingForegroundFailureClearCount
        )
    }

    func testingInstallRunWindow(_ controller: RunWindowController) {
        controller.onHide = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.handleForegroundTargetDismissed(controller)
        }
        runWindow = controller
    }

    func testingInstallSelectionWindow(_ controller: SelectionWindowController) {
        selectionWindow = controller
    }

    func testingRemoveSelectionWindow() {
        selectionWindow = nil
    }

    func testingInstallCanonicalRootCommitOrigin(
        _ controller: SelectionWindowController
    ) {
        configureSelectionCancellation(controller)
        selectionWindow = controller
        controller.showWindow(nil)
    }

    func testingBeginCanonicalRootCommit(
        originatingFrom controller: SelectionWindowController
    ) -> UInt64? {
        beginAuthorityCommit(
            feedbackController: controller
        )
    }

    func testingBeginOnboardingAuthorityCommit() -> UInt64? {
        beginAuthorityCommit(feedbackController: nil)
    }

    func testingCompleteCanonicalRootCommitSuccess(
        _ inventory: RepositoryInventory,
        token: UInt64,
        originatingFrom controller: SelectionWindowController
    ) {
        guard finishAuthorityCommit(token: token) else { return }
        completeCanonicalRootCommit(
            .success(.refreshed(inventory)),
            originatingFrom: controller
        )
    }

    func testingCompleteCanonicalRootCommitSavedRefreshFailure(
        token: UInt64,
        originatingFrom controller: SelectionWindowController
    ) {
        guard finishAuthorityCommit(token: token) else { return }
        completeCanonicalRootCommit(
            .success(.savedButRefreshFailed(NSError(
                domain: "ShadowSyncM5",
                code: 1
            ))),
            originatingFrom: controller
        )
    }

    func testingCompleteCanonicalRootCommitFailure(
        token: UInt64,
        originatingFrom controller: SelectionWindowController
    ) {
        guard finishAuthorityCommit(token: token) else { return }
        completeCanonicalRootCommit(
            .failure(NSError(
                domain: "ShadowSyncM5",
                code: 2
            )),
            originatingFrom: controller
        )
    }

    func testingCompleteOnboardingCommitFailure(token: UInt64) {
        guard finishAuthorityCommit(token: token) else { return }
        completeOnboardingCommit(
            .failure(NSError(
                domain: "ShadowSyncM5",
                code: 3
            ))
        )
    }

    var testAuthorityCommitInProgress: Bool {
        authorityCommitSession != nil
    }

    func testingInstallCanonicalRootWindow(
        _ controller: CanonicalRootConfirmationWindowController
    ) {
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller,
                  self.canonicalRootWindow === controller else {
                return
            }
            self.canonicalRootWindow = nil
        }
        canonicalRootWindow = controller
    }

    func testingPresentCanonicalRootOnboardingAfterInventory(
        _ controller: CanonicalRootConfirmationWindowController
    ) {
        prepareRepositoryInventoryPresentation()
        testingInstallCanonicalRootWindow(controller)
        foreground(controller)
    }

    func testingBeginRealConfirmation(
        selected: [RepositoryCandidate],
        selectionController: SelectionWindowController
    ) {
        configureSelectionCancellation(selectionController)
        selectionWindow = selectionController
        forceAsyncConfirmationForTesting = true
        suppressWorkerStartForConfirmationTest = true
        selectionController.showWindow(nil)
        review(
            selected: selected,
            selectionController: selectionController
        )
    }

    func testingSetLastReport(_ report: RunReport?) {
        lastReport = report
    }

    var testingRunControllerIdentity: ObjectIdentifier? {
        runWindow.map(ObjectIdentifier.init)
    }

    var testingHistoricalViewerIdentity: ObjectIdentifier? {
        historicalViewer.map(ObjectIdentifier.init)
    }

    var testingHistoricalViewerHasNoLifecycleEvidence: Bool {
        historicalViewer?.testingHasNoLifecycleEvidence == true
    }

    var testingHistoricalViewerStopCount: Int {
        historicalViewer?.testingStopCount ?? 0
    }

    func testingCloseHistoricalWindow() {
        historicalViewer?.window?.performClose(nil)
    }

    func testingExplicitCloseHistoricalWindow() {
        historicalViewer?.testCloseRun()
    }

    func testingHideHistoricalWindow() {
        historicalViewer?.testingHideAsIntent()
    }

    func testingHideRunWindow() {
        runWindow?.testingHideAsIntent()
    }

    func testingHideSelectionWindow() {
        if let selectionWindow {
            handleForegroundTargetDismissed(selectionWindow)
        }
        selectionWindow?.window?.orderOut(nil)
    }

    func testingCloseSelectionWindow() {
        selectionWindow?.window?.performClose(nil)
    }

    func testingMiniaturizeHistoricalWindow() {
        historicalViewer?.window?.miniaturize(nil)
    }

    func testingMiniaturizeRunWindow() {
        runWindow?.window?.miniaturize(nil)
    }

    func testingMiniaturizeSelectionWindow() {
        selectionWindow?.window?.miniaturize(nil)
    }

    var testingSelectionWindowState: (
        visible: Bool,
        miniaturized: Bool,
        key: Bool,
        main: Bool,
        number: Int,
        appActive: Bool
    )? {
        selectionWindow?.window.map {
            ($0.isVisible, $0.isMiniaturized, $0.isKeyWindow,
             $0.isMainWindow, $0.windowNumber, NSApp.isActive)
        }
    }

    var testingCanonicalRootWindowIdentity: ObjectIdentifier? {
        canonicalRootWindow.map(ObjectIdentifier.init)
    }

    var testingPendingOnboardingGeneration: UInt64? {
        pendingCanonicalRootOnboarding?.generation
    }

    var testingHasPendingOnboarding: Bool {
        pendingCanonicalRootOnboarding != nil
    }

    func testingCancelPendingOnboarding() {
        canonicalRootWindow?.testingActivateCancel()
    }

    func testingConfirmPendingOnboarding() {
        canonicalRootWindow?.testingActivateConfirm()
    }

    var testingCanonicalRootWindowState: (
        visible: Bool,
        miniaturized: Bool,
        number: Int
    )? {
        canonicalRootWindow?.window.map {
            ($0.isVisible, $0.isMiniaturized, $0.windowNumber)
        }
    }

    var testingRunWindowState: (
        visible: Bool,
        miniaturized: Bool,
        key: Bool,
        main: Bool,
        number: Int,
        appActive: Bool
    )? {
        runWindow?.window.map {
            ($0.isVisible, $0.isMiniaturized, $0.isKeyWindow,
             $0.isMainWindow, $0.windowNumber, NSApp.isActive)
        }
    }

    var testingHistoricalWindowState: (
        visible: Bool,
        miniaturized: Bool,
        key: Bool,
        main: Bool,
        number: Int,
        appActive: Bool
    )? {
        historicalViewer?.window.map {
            ($0.isVisible, $0.isMiniaturized, $0.isKeyWindow,
             $0.isMainWindow, $0.windowNumber, NSApp.isActive)
        }
    }

    func testingLeaveStaleHistoricalReference() {
        historicalViewer?.dismissHistoricalPresentation()
    }

    var testingHistoricalWindowIsVisible: Bool {
        historicalViewer?.window?.isVisible == true
    }

    var testingHistoricalWindowIsMiniaturized: Bool {
        historicalViewer?.window?.isMiniaturized == true
    }

    var testingRunWindowIsVisible: Bool {
        runWindow?.window?.isVisible == true
    }

    var testingSelectionWindowIsVisible: Bool {
        selectionWindow?.window?.isVisible == true
    }

    var testingRunMetadata: String? {
        (runWindow ?? historicalViewer)?.testingRunMetadata
    }

    var testingInlineStatusMessage: String? {
        inlineStatusMessage
    }

    func testingPresentLogOpenFailure() {
        _ = presentInlineStatus(
            .logOpenFailure,
            on: currentPrimaryController()
        )
    }

    var testingSelectionInlineMessage: String? {
        selectionWindow?.testingInlineMessage
    }

    func testLoadRecoveryPresentation() {
        loadRecoveryPresentation()
    }

    func testingFireOperationContentionRevalidation() {
        guard let token = operationContentionScheduledToken else {
            return
        }
        let generation = operationContentionRevalidationGeneration
        operationContentionRevalidationWorkItem?.cancel()
        performOperationContentionRevalidation(
            token: token,
            generation: generation
        )
    }

    func testingFireOperationContentionRevalidation(
        token: UInt64,
        generation: UInt64
    ) {
        performOperationContentionRevalidation(
            token: token,
            generation: generation
        )
    }

    func testingCloseOperationContentionPresentation() {
        guard let token = operationContentionAlertToken else {
            return
        }
        clearOperationContentionPresentation()
        applyOperationContentionEffects(
            operationContention.presentationClosed(token: token)
        )
    }

    func testingInstallOperationContentionWindow()
        -> NSWindowController {
        let alert = ShadowSyncAlertFactory.operationContention()
        let controller = OperationContentionWindowController(alert: alert)
        operationContentionAlert = alert
        operationContentionWindowController = controller
        operationContentionAlertToken = UInt64.max
        return controller
    }

    func testingDismissOperationContentionWindow(
        applicationActive: Bool,
        windowVisible: Bool,
        windowKey: Bool,
        windowOnScreen: Bool,
        windowOnActiveSpace: Bool
    ) {
        testingForegroundRealitySnapshotOverride = ForegroundReality(
            applicationActive: applicationActive,
            windowVisible: windowVisible,
            windowKey: windowKey,
            windowOnScreen: windowOnScreen,
            windowOnActiveSpace: windowOnActiveSpace
        )
        clearOperationContentionPresentation()
        testingForegroundRealitySnapshotOverride = nil
    }

    var testingHasOperationContentionWindow: Bool {
        operationContentionAlert != nil
            || operationContentionWindowController != nil
            || operationContentionAlertToken != nil
    }

    var testOperationContentionRevalidationIdentity: (
        token: UInt64,
        generation: UInt64
    )? {
        guard let token = operationContentionScheduledToken,
              operationContentionRevalidationWorkItem != nil else {
            return nil
        }
        return (token, operationContentionRevalidationGeneration)
    }

    var testOperationContentionHasPendingRetry: Bool {
        operationContention.hasPendingRetry
    }

    var testOperationContentionIsVisible: Bool {
        operationContention.isPresented
    }

    var testOperationContentionRevalidationScheduled: Bool {
        operationContentionRevalidationWorkItem != nil
    }

    var testRecoveryReviewRequired: Bool {
        recoveryReviewRequirement != nil
    }

    var testSelectionHasNoDefault: Bool {
        selectionWindow?.testHasSelection == false
    }

    var testSelectionPresentation: (String, String, String, [String])? {
        selectionWindow?.testPresentation
    }

    func testSelectAndReview() {
        selectionWindow?.testSelectAndReview()
    }

    func testingBeginRealConfirmationFromSpace() {
        forceAsyncConfirmationForTesting = true
        suppressWorkerStartForConfirmationTest = true
        selectionWindow?.testSelectAll()
        selectionWindow?.testActivateReviewWithSpace()
    }

    var testingConfirmationState: (
        open: Bool,
        armed: Bool,
        hasRun: Bool,
        selectionOpen: Bool
    ) {
        (
            confirmationInProgress,
            confirmationStartArmed,
            runWindow != nil,
            selectionWindow != nil
        )
    }

    func testingActivateConfirmationStart() {
        guard let alert = activeConfirmationAlert,
              alert.buttons.indices.contains(2) else {
            return
        }
        armConfirmationStart(alert)
        alert.buttons[2].performClick(nil)
    }

    func testSelectAll() {
        selectionWindow?.testSelectAll()
    }

    func testClearAll() {
        selectionWindow?.testClearAll()
    }

    func testSelectFirst() {
        selectionWindow?.testSelectFirst()
    }

    var testSelectionCount: Int {
        selectionWindow?.testSelectionCount ?? 0
    }

    var testSelectionIsOpen: Bool {
        selectionWindow != nil
    }

    var testSelectionControllerIdentity: ObjectIdentifier? {
        selectionWindow.map(ObjectIdentifier.init)
    }

    func testMenuTitles() -> [String] {
        let menu = NSMenu(title: "ShadowSync Test")
        menuNeedsUpdate(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    func testMenuItems() -> [(
        title: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags
    )] {
        let menu = NSMenu(title: "ShadowSync Test")
        menuNeedsUpdate(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map {
            ($0.title, $0.keyEquivalent, $0.keyEquivalentModifierMask)
        }
    }

    func testOpenLatestLog() {
        openLatestLog()
    }

    var testRunFinished: Bool {
        (runWindow ?? historicalViewer)?.isFinished == true
    }

    var testWorkerDrained: Bool {
        runWindow?.testWorkerDrained == true
    }

    var testRunSettled: Bool {
        runWindow?.quitGateDecision == .allow
    }

    var testReport: RunReport? {
        (runWindow ?? historicalViewer)?.report
    }

    var testObservedPhases: [RepositoryPhase] {
        runWindow?.observedPhases ?? []
    }

    var testWireTrace: [String] {
        runWindow?.testingWireTraceSnapshot ?? []
    }

    var testNeedsAttention: Bool {
        runWindow?.testNeedsAttention == true
    }

    var testRecoveredLogRecordCount: Int {
        runWindow?.testRecoveredLogRecordCount ?? 0
    }

    func testKillWorker() {
        runWindow?.testKillWorker()
    }

    func testCloseRun() {
        (runWindow ?? historicalViewer)?.testCloseRun()
    }

    func testQuitUtility() {
        quitUtility()
    }

    var testLastReport: RunReport? {
        lastReport
    }

    var testReportRowText: String {
        (runWindow ?? historicalViewer)?.testRowText ?? ""
    }

    var testReportHasSymbol: Bool {
        (runWindow ?? historicalViewer)?.testHasSymbol == true
    }

    static func testThreeRowProgressIsCoherent() -> Bool {
        RunWindowController.testingThreeRowProgressIsCoherent()
    }

    static func testOwnershipFailureLifecycle(
        executablePath: String,
        root: String,
        mapping: TransportMapping,
        candidate: RepositoryCandidate
    ) -> Bool {
        RunWindowController.testingOwnershipFailureLifecycle(
            executablePath: executablePath,
            root: root,
            mapping: mapping,
            candidate: candidate
        )
    }

    static func testStopLifecycleStateIsCoherent() -> Bool {
        RunWindowController.testingStopLifecycleStateIsCoherent()
    }

    static func testControllerStopRaces(
        candidate: RepositoryCandidate
    ) -> Bool {
        RunWindowController.testingControllerStopRaces(
            candidate: candidate
        )
    }

    static func testWorkerStopSingleFlight(root: String) -> Bool {
        RunWindowController.testingWorkerSessionStopSingleFlight(root: root)
    }

    static func testTakeoverTransitionIsCoherent(root: String) -> Bool {
        RunWindowController.testingTakeoverTransitionIsCoherent(root: root)
    }

    static func testReportTransactionsAreAtomic(root: String) -> Bool {
        RunWindowController.testingReportTransactionsAreAtomic(root: root)
    }

    static func testStoppingOverlayControllerRaces(root: String) -> Bool {
        RunWindowController.testingStoppingOverlayControllerRaces(root: root)
    }

    static func testSealedPresentationRaces(root: String) -> Bool {
        RunWindowController.testingSealedPresentationRaces(root: root)
    }

    static var testingProductionShortcutChord: (
        keyCode: UInt32,
        modifiers: UInt32
    ) {
        GlobalShortcut.testingProductionChord
    }

    static func testingShortcutRegistrationStatus(
        keyCode: UInt32,
        modifiers: UInt32
    ) -> OSStatus? {
        let shortcut = GlobalShortcut(
            testingKeyCode: keyCode,
            modifiers: modifiers,
            action: {}
        )
        _ = shortcut.register()
        let status = shortcut.registrationStatus
        shortcut.unregister()
        return status
    }

    static func testingShortcutRegistrationAndDispatch(
        keyCode: UInt32,
        modifiers: UInt32
    ) -> (
        registered: Bool,
        registrationStatus: OSStatus?,
        matchingStatus: OSStatus,
        wrongSignatureStatus: OSStatus,
        wrongIdentifierStatus: OSStatus,
        actionCount: Int
    ) {
        var actionCount = 0
        let shortcut = GlobalShortcut(
            testingKeyCode: keyCode,
            modifiers: modifiers
        ) {
            actionCount += 1
        }
        let registered = shortcut.register()
        defer { shortcut.unregister() }
        guard registered else {
            return (
                false,
                shortcut.registrationStatus,
                OSStatus(eventNotHandledErr),
                OSStatus(eventNotHandledErr),
                OSStatus(eventNotHandledErr),
                actionCount
            )
        }
        let wrongSignatureStatus = shortcut.testingDispatch(
            signature: 0x4D355752
        )
        let wrongIdentifierStatus = shortcut.testingDispatch(identifier: 2)
        let matchingStatus = shortcut.testingDispatch()
        return (
            true,
            shortcut.registrationStatus,
            matchingStatus,
            wrongSignatureStatus,
            wrongIdentifierStatus,
            actionCount
        )
    }
    #endif
}

@MainActor
class SelectionWindowController: NSWindowController, NSWindowDelegate {
    private let candidates: [RepositoryCandidate]
    private var checkboxes: [NSButton] = []
    private var warningLabels: [NSTextField?] = []
    private var warningSymbols: [NSImageView?] = []
    private let reviewButton = NSButton(
        title: ShadowSyncPresentation.reviewSelection,
        target: nil,
        action: nil
    )
    private let message = NSTextField(labelWithString: ShadowSyncPresentation.zeroSelection)
    private let countLabel = NSTextField(labelWithString: "")
    private let inlineMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let helpLabel = NSTextField(
        wrappingLabelWithString: ShadowSyncPresentation.help
    )
    private let selectAllButton = NSButton(
        title: ShadowSyncPresentation.selectAll,
        target: nil,
        action: nil
    )
    private let clearAllButton = NSButton(
        title: ShadowSyncPresentation.clearAll,
        target: nil,
        action: nil
    )
    private let selectionCancelButton = NSButton(
        title: ShadowSyncPresentation.cancelSelection,
        target: nil,
        action: nil
    )
    private var closeNotified = false
    private var geometryAutosaveName: String?
    private var defaultWindowFrameSize = NSSize.zero
    private var isNormalizingWindowFrame = false
    #if SHADOW_SYNC_TESTING
    var testingDidEnterFullScreen: ((Int) -> Void)?
    var testingDidExitFullScreen: ((Int) -> Void)?
    #endif
    var onReview: (([RepositoryCandidate]) -> Void)?
    var onCancel: (() -> Void)?

    init(candidates: [RepositoryCandidate]) {
        self.candidates = candidates
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = ShadowSyncPresentation.selectionTitle
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
        configureNativeWindowGeometry(
            autosaveName: "ShadowSync.SelectionWindow.v1",
            minimumFrameSize: NSSize(width: 560, height: 360)
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configureNativeWindowGeometry(
        autosaveName: String,
        minimumFrameSize: NSSize
    ) {
        guard let window else { return }
        geometryAutosaveName = autosaveName
        defaultWindowFrameSize = window.frame.size
        window.minSize = minimumFrameSize
        window.contentMinSize = window.contentRect(
            forFrameRect: NSRect(
                origin: .zero,
                size: minimumFrameSize
            )
        ).size
        window.styleMask.formUnion([
            .resizable, .miniaturizable,
        ])
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isRestorable = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        #if !SHADOW_SYNC_TESTING
        window.setFrameAutosaveName(autosaveName)
        #endif
        normalizeWindowGeometry()
    }

    func prepareForPresentation() {
        normalizeWindowGeometry()
    }

    private func clampedWindowFrame(
        _ proposed: NSRect,
        for window: NSWindow
    ) -> NSRect {
        let fallbackScreen =
            window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = fallbackScreen?.visibleFrame else {
            var frame = proposed
            if !frame.size.width.isFinite
                || frame.size.width < window.minSize.width {
                frame.size.width = max(
                    window.minSize.width,
                    defaultWindowFrameSize.width
                )
            }
            if !frame.size.height.isFinite
                || frame.size.height < window.minSize.height {
                frame.size.height = max(
                    window.minSize.height,
                    defaultWindowFrameSize.height
                )
            }
            return frame
        }
        var frame = proposed
        let widthIsValid =
            frame.size.width.isFinite && frame.size.width > 0
        let heightIsValid =
            frame.size.height.isFinite && frame.size.height > 0
        frame.size.width = min(
            max(
                widthIsValid
                    ? frame.size.width : defaultWindowFrameSize.width,
                min(window.minSize.width, visible.width)
            ),
            visible.width
        )
        frame.size.height = min(
            max(
                heightIsValid
                    ? frame.size.height : defaultWindowFrameSize.height,
                min(window.minSize.height, visible.height)
            ),
            visible.height
        )
        if !frame.origin.x.isFinite || !frame.origin.y.isFinite
            || !frame.intersects(visible) {
            frame.origin = NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
        }
        frame.origin.x = min(
            max(frame.origin.x, visible.minX),
            visible.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.origin.y, visible.minY),
            visible.maxY - frame.height
        )
        return frame
    }

    private func normalizeWindowGeometry() {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              !isNormalizingWindowFrame else {
            return
        }
        let clamped = clampedWindowFrame(window.frame, for: window)
        guard !NSEqualRects(clamped, window.frame) else {
            persistWindowGeometry()
            return
        }
        isNormalizingWindowFrame = true
        window.setFrame(clamped, display: window.isVisible)
        isNormalizingWindowFrame = false
        persistWindowGeometry()
    }

    private func persistWindowGeometry() {
        guard let window,
              let geometryAutosaveName,
              !window.styleMask.contains(.fullScreen) else {
            return
        }
        #if !SHADOW_SYNC_TESTING
        window.saveFrame(usingName: geometryAutosaveName)
        #endif
    }

    func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        clampedWindowFrame(
            NSRect(origin: sender.frame.origin, size: frameSize),
            for: sender
        ).size
    }

    func windowDidResize(_ notification: Notification) {
        normalizeWindowGeometry()
    }

    func windowDidMove(_ notification: Notification) {
        normalizeWindowGeometry()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        normalizeWindowGeometry()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        #if SHADOW_SYNC_TESTING
        if let window {
            testingDidEnterFullScreen?(window.windowNumber)
        }
        #endif
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        normalizeWindowGeometry()
        #if SHADOW_SYNC_TESTING
        if let window {
            testingDidExitFullScreen?(window.windowNumber)
        }
        #endif
    }

    func windowWillUseStandardFrame(
        _ window: NSWindow,
        defaultFrame newFrame: NSRect
    ) -> NSRect {
        clampedWindowFrame(
            window.screen?.visibleFrame.insetBy(dx: 24, dy: 24)
                ?? newFrame,
            for: window
        )
    }

    private func buildContent() {
        guard let content = window?.contentView else {
            return
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        content.addSubview(stack)

        helpLabel.maximumNumberOfLines = 0
        helpLabel.font = .preferredFont(forTextStyle: .body)
        helpLabel.setAccessibilityLabel("Repository update help")
        helpLabel.setAccessibilityValue(ShadowSyncPresentation.help)
        helpLabel.lineBreakMode = .byCharWrapping
        helpLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        stack.addArrangedSubview(helpLabel)

        let eligibleCount = candidates.filter(\.isEligible).count
        let blockedCount = candidates.count - eligibleCount
        countLabel.stringValue =
            "\(eligibleCount) eligible, \(blockedCount) blocked"
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .preferredFont(forTextStyle: .body)
        countLabel.setAccessibilityLabel("Repository availability")
        stack.addArrangedSubview(countLabel)

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let collidingPaths =
            RepositoryOperatorPresentation.collidingPaths(in: candidates)
        for candidate in candidates {
            let label = RepositoryOperatorPresentation.selectionLabel(
                candidate,
                collidingPaths: collidingPaths
            )
            let rowLabel = """
            \(label)
            Cached origin/main: \(candidate.cachedMainRelation.operatorLabel)
            """
            let checkbox = NSButton(
                checkboxWithTitle: rowLabel,
                target: self,
                action: #selector(selectionChanged)
            )
            checkbox.state = .off
            checkbox.isEnabled = candidate.isEligible
            checkbox.lineBreakMode = .byWordWrapping
            checkbox.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )
            checkbox.setAccessibilityLabel(rowLabel)
            let location = RepositoryOperatorPresentation.secondaryLocation(
                candidate
            ) ?? "Unavailable"
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )
            row.addArrangedSubview(checkbox)
            if let reason = candidate.blockedReason {
                let help = """
                \(reason.operatorExplanation) Local checkout: \(location). Cached origin/main: \(candidate.cachedMainRelation.operatorLabel).
                """
                checkbox.toolTip = help
                checkbox.setAccessibilityHelp(help)
                row.toolTip = help
                let warningRow = NSStackView()
                warningRow.orientation = .horizontal
                warningRow.alignment = .firstBaseline
                warningRow.spacing = 6
                warningRow.translatesAutoresizingMaskIntoConstraints = false
                let symbol = NSImageView(
                    image: NSImage(
                        systemSymbolName: "exclamationmark.triangle.fill",
                        accessibilityDescription: "Warning"
                    ) ?? NSImage()
                )
                symbol.contentTintColor = .secondaryLabelColor
                symbol.toolTip = help
                symbol.setAccessibilityLabel("Warning")
                symbol.setAccessibilityHelp(help)
                let warning = NSTextField(
                    wrappingLabelWithString: reason.operatorExplanation
                )
                warning.font = .preferredFont(forTextStyle: .callout)
                warning.textColor = .secondaryLabelColor
                warning.maximumNumberOfLines = 0
                warning.lineBreakMode = .byWordWrapping
                warning.toolTip = help
                warning.setAccessibilityLabel(
                    "Warning: \(reason.operatorExplanation)"
                )
                warning.setAccessibilityHelp(help)
                warning.setContentCompressionResistancePriority(
                    .defaultLow,
                    for: .horizontal
                )
                warningRow.addArrangedSubview(symbol)
                warningRow.addArrangedSubview(warning)
                warningRow.toolTip = help
                row.addArrangedSubview(warningRow)
                warningRow.widthAnchor.constraint(
                    lessThanOrEqualTo: row.widthAnchor
                ).isActive = true
                warningLabels.append(warning)
                warningSymbols.append(symbol)
            } else {
                let help = """
                Local checkout: \(location). Cached origin/main: \(candidate.cachedMainRelation.operatorLabel). Includes this repository in the review step. Selection alone changes nothing.
                """
                checkbox.toolTip = help
                checkbox.setAccessibilityHelp(help)
                row.toolTip = help
                warningLabels.append(nil)
                warningSymbols.append(nil)
            }
            checkboxes.append(checkbox)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(
                equalTo: rowsStack.widthAnchor
            ).isActive = true
            checkbox.widthAnchor.constraint(
                equalTo: row.widthAnchor
            ).isActive = true
        }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = rowsStack
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(scrollView)

        message.textColor = .secondaryLabelColor
        message.font = .preferredFont(forTextStyle: .body)
        message.setAccessibilityLabel("Selection status")
        stack.addArrangedSubview(message)

        inlineMessageLabel.textColor = .secondaryLabelColor
        inlineMessageLabel.font = .preferredFont(forTextStyle: .body)
        inlineMessageLabel.maximumNumberOfLines = 0
        inlineMessageLabel.lineBreakMode = .byCharWrapping
        inlineMessageLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        inlineMessageLabel.isHidden = true
        inlineMessageLabel.setAccessibilityLabel("ShadowSync status")
        stack.addArrangedSubview(inlineMessageLabel)

        let selectionControls = NSStackView()
        selectionControls.orientation = .horizontal
        selectionControls.alignment = .centerY
        selectionControls.spacing = 8
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllRows)
        selectAllButton.isEnabled = candidates.contains(where: \.isEligible)
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllRows)
        selectionCancelButton.target = self
        selectionCancelButton.action = #selector(cancel)
        selectionCancelButton.keyEquivalent = "\u{1b}"
        selectionCancelButton.setAccessibilityHelp(
            "Closes this selection without starting a worker or changing a repository."
        )
        selectionControls.addArrangedSubview(selectAllButton)
        selectionControls.addArrangedSubview(clearAllButton)
        stack.addArrangedSubview(selectionControls)

        let reviewControls = NSStackView()
        reviewControls.orientation = .horizontal
        reviewControls.alignment = .centerY
        reviewControls.spacing = 8
        reviewControls.addArrangedSubview(selectionCancelButton)
        reviewButton.target = self
        reviewButton.action = #selector(review)
        reviewButton.isEnabled = false
        reviewButton.keyEquivalent = ""
        reviewButton.setAccessibilityHelp(
            "Opens a non-destructive confirmation for the selected repositories."
        )
        reviewControls.addArrangedSubview(reviewButton)
        stack.addArrangedSubview(reviewControls)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            helpLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inlineMessageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selectionControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reviewControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -8),
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 8),
            rowsStack.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor,
                constant: -8
            ),
        ])
        let keyViews = checkboxes.filter(\.isEnabled) + [
            selectAllButton,
            clearAllButton,
            selectionCancelButton,
            reviewButton,
        ]
        for (current, next) in zip(keyViews, keyViews.dropFirst()) {
            current.nextKeyView = next
        }
        keyViews.last?.nextKeyView = keyViews.first
        window?.initialFirstResponder =
            checkboxes.first(where: \.isEnabled) ?? selectionCancelButton
        window?.defaultButtonCell = nil
    }

    @objc private func selectionChanged() {
        updateSelectionState()
    }

    @objc private func selectAllRows() {
        checkboxes.filter(\.isEnabled).forEach { $0.state = .on }
        updateSelectionState()
    }

    @objc private func clearAllRows() {
        checkboxes.forEach { $0.state = .off }
        updateSelectionState()
    }

    @objc private func cancel() {
        close()
        notifyClosed()
    }

    @objc private func review() {
        let selected = zip(candidates, checkboxes).compactMap { candidate, checkbox in
            candidate.isEligible && checkbox.state == .on ? candidate : nil
        }
        guard !selected.isEmpty else {
            return
        }
        onReview?(selected)
    }

    private func updateSelectionState() {
        let hasSelection = checkboxes.contains {
            $0.isEnabled && $0.state == .on
        }
        reviewButton.isEnabled = hasSelection && window?.attachedSheet == nil
        message.isHidden = hasSelection
    }

    func setReviewEnabled(_ enabled: Bool) {
        reviewButton.isEnabled = enabled
            && checkboxes.contains {
                $0.isEnabled && $0.state == .on
            }
    }

    func presentInlineMessage(_ text: String?) {
        inlineMessageLabel.stringValue = text ?? ""
        inlineMessageLabel.isHidden = text == nil
    }

    var canPresentStatusItemGuidance: Bool {
        inlineMessageLabel.isHidden
    }

    func windowWillClose(_ notification: Notification) {
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .abort)
        }
        notifyClosed()
    }

    private func notifyClosed() {
        guard !closeNotified else { return }
        closeNotified = true
        onCancel?()
    }

    var isPresentationOpen: Bool {
        !closeNotified && window != nil
    }

    #if SHADOW_SYNC_TESTING
    var testHasSelection: Bool {
        checkboxes.contains { $0.isEnabled && $0.state == .on }
    }

    var testPresentation: (String, String, String, [String]) {
        (
            window?.title ?? "",
            helpLabel.stringValue,
            message.stringValue,
            [
                selectAllButton.title,
                clearAllButton.title,
                selectionCancelButton.title,
                reviewButton.title,
            ]
        )
    }

    func testSelectAndReview() {
        selectAllRows()
        review()
    }

    func testActivateReviewWithSpace() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(reviewButton)
        for isRepeat in [false, true] {
            if let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: isRepeat,
                keyCode: 49
            ) {
                window.sendEvent(down)
            }
        }
        if let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ) {
            window.sendEvent(up)
        }
    }

    func testSelectAll() {
        selectAllRows()
    }

    func testClearAll() {
        clearAllRows()
    }

    func testSelectFirst() {
        clearAllRows()
        checkboxes.first(where: \.isEnabled)?.state = .on
        updateSelectionState()
    }

    var testSelectionCount: Int {
        checkboxes.filter { $0.isEnabled && $0.state == .on }.count
    }

    var testingAccessibilitySnapshot: (
        checkboxLabels: [String?],
        checkboxHelp: [String?],
        initialResponderIsSafe: Bool,
        keyOrderIsLogical: Bool,
        reviewIsDefault: Bool,
        cancelUsesEscape: Bool
    ) {
        let keyViews: [NSView] = checkboxes.filter(\.isEnabled) + [
            selectAllButton,
            clearAllButton,
            selectionCancelButton,
            reviewButton,
        ]
        let logical = zip(keyViews, keyViews.dropFirst()).allSatisfy {
            $0.0.nextKeyView === $0.1
        } && keyViews.last?.nextKeyView === keyViews.first
        return (
            checkboxes.map { $0.accessibilityLabel() },
            checkboxes.map { $0.accessibilityHelp() },
            window?.initialFirstResponder
                === (
                    checkboxes.first(where: \.isEnabled)
                        ?? selectionCancelButton
                ),
            logical,
            window?.defaultButtonCell === reviewButton.cell,
            selectionCancelButton.keyEquivalent == "\u{1b}"
        )
    }

    var testingAdaptiveSnapshot: (
        resizable: Bool,
        minimumSize: NSSize,
        scrolls: Bool,
        helpWraps: Bool,
        rowsWrap: Bool,
        usesSemanticColors: Bool
    ) {
        (
            window?.styleMask.contains(.resizable) == true,
            window?.minSize ?? .zero,
            (window?.contentView?.subviews.first as? NSStackView)?
                .arrangedSubviews.compactMap { $0 as? NSScrollView }
                .first?.hasVerticalScroller == true,
            helpLabel.maximumNumberOfLines == 0,
            checkboxes.allSatisfy {
                $0.lineBreakMode == .byWordWrapping
            } && warningLabels.compactMap { $0 }.allSatisfy {
                $0.lineBreakMode == .byWordWrapping
            },
            message.textColor == .secondaryLabelColor
                && inlineMessageLabel.textColor == .secondaryLabelColor
                && warningLabels.compactMap { $0 }.allSatisfy {
                    $0.textColor == .secondaryLabelColor
                }
        )
    }

    var testingInlineMessage: String? {
        inlineMessageLabel.isHidden ? nil : inlineMessageLabel.stringValue
    }

    var testingAvailabilitySnapshot: (
        enabledRows: [Bool],
        labels: [String],
        count: String,
        selectAllEnabled: Bool,
        tooltips: [String?],
        warningReasons: [String?],
        warningSymbols: [Bool],
        symbolTooltips: [String?],
        warningAccessibilityHelp: [String?],
        symbolAccessibilityHelp: [String?]
    ) {
        (
            checkboxes.map(\.isEnabled),
            zip(checkboxes, warningLabels).map {
                guard let warning = $0.1 else {
                    return $0.0.title
                }
                return "\($0.0.title)\n\(warning.stringValue)"
            },
            countLabel.stringValue,
            selectAllButton.isEnabled,
            checkboxes.map(\.toolTip),
            warningLabels.map { $0?.stringValue },
            warningSymbols.map { $0?.image != nil },
            warningSymbols.map { $0?.toolTip },
            warningLabels.map { $0?.accessibilityHelp() },
            warningSymbols.map { $0?.accessibilityHelp() }
        )
    }
    #endif
}

private enum QuitTransitionResult: Equatable {
    case terminateNow
    case stopping
    case blocked
}

private enum TakeoverRequestResult: Equatable {
    case accepted
    case blockedByQuit
    case blocked
}

enum RunWindowRole: Equatable {
    case liveRun
    case historicalViewer
}

@MainActor
final class RunWindowController: NSWindowController, NSWindowDelegate {
    private enum PostRunNoticeReason: Equatable {
        case childDrainUnverified
        case authorityHeld
        case handoffTimedOut
        case evidenceConflict
    }

    private struct PostRunNotice: Equatable {
        let reason: PostRunNoticeReason
        let detail: String
        let blocksNewRun: Bool
        let requiresRecoveryAcknowledgement: Bool
    }

    private struct WorkerSessionBinding: Equatable, Sendable {
        let runID: String
        let workerGeneration: String
    }

    private enum StopIntent: Int, Equatable, Sendable {
        case ordinary
        case takeover
        case quit

        func takingPrecedence(over other: StopIntent) -> StopIntent {
            rawValue >= other.rawValue ? self : other
        }
    }

    private enum StopReason: Equatable, Sendable {
        case operatorRequested
        case ownershipFailure

        func preservingSafetyPrecedence(over other: StopReason) -> StopReason {
            self == .ownershipFailure || other == .ownershipFailure
                ? .ownershipFailure
                : .operatorRequested
        }
    }

    private struct StopTransaction: Equatable, Sendable {
        let token: String
        let binding: WorkerSessionBinding
        var intent: StopIntent
        var reason: StopReason
        var workerExitStatus: Int32?
    }

    private enum VerifiedStopResult: Equatable, Sendable {
        case cooperative(Int32)
        case terminated(Int32)
        case killed(Int32)
        case alreadyExited(Int32)

        init?(_ outcome: WorkerStopOutcome) {
            switch outcome {
            case let .cooperative(status):
                self = .cooperative(status)
            case let .terminated(status):
                self = .terminated(status)
            case let .killed(status):
                self = .killed(status)
            case let .alreadyExited(status):
                self = .alreadyExited(status)
            case .unverified, .stillActive:
                return nil
            }
        }

        var outcome: WorkerStopOutcome {
            switch self {
            case let .cooperative(status):
                return .cooperative(status)
            case let .terminated(status):
                return .terminated(status)
            case let .killed(status):
                return .killed(status)
            case let .alreadyExited(status):
                return .alreadyExited(status)
            }
        }
    }

    private enum BlockedStopResult: Equatable, Sendable {
        case unverified
        case stillActive

        init?(_ outcome: WorkerStopOutcome) {
            switch outcome {
            case .unverified:
                self = .unverified
            case .stillActive:
                self = .stillActive
            case .cooperative, .terminated, .killed, .alreadyExited:
                return nil
            }
        }

        var outcome: WorkerStopOutcome {
            switch self {
            case .unverified:
                return .unverified
            case .stillActive:
                return .stillActive
            }
        }
    }

    private enum StopTerminalResult: Equatable, Sendable {
        case verified(VerifiedStopResult)
        case blocked(BlockedStopResult)

        init(_ outcome: WorkerStopOutcome) {
            if let verified = VerifiedStopResult(outcome) {
                self = .verified(verified)
            } else if let blocked = BlockedStopResult(outcome) {
                self = .blocked(blocked)
            } else {
                preconditionFailure("WorkerStopOutcome classification is exhaustive")
            }
        }

        var outcome: WorkerStopOutcome {
            switch self {
            case let .verified(result):
                return result.outcome
            case let .blocked(result):
                return result.outcome
            }
        }

        var isVerified: Bool {
            if case .verified = self {
                return true
            }
            return false
        }
    }

    private enum StopLifecycle: Equatable {
        case idle
        case stopping(StopTransaction)
        case terminal(transaction: StopTransaction, result: StopTerminalResult)
    }

    private enum BeginStopResult: Equatable {
        case launched
        case joined
        case blocked
    }

    private enum ReportSource {
        case liveWorker(WorkerSessionBinding)
        case historicalOrRecovery
    }

    private struct PresentationSeal: Equatable {
        let runID: String
        let workerGeneration: String?
    }

    private enum TakeoverTransition {
        case none
        case pending(() -> Bool)
        case finished
    }

    private enum QuitTransition {
        case none
        case pending
        case finished
    }

    private let candidates: [RepositoryCandidate]
    private let plannedOperations: [PlannedOperation]
    private let authorizedOperations: [AuthorizedOperationEnvelope]
    private let lifecycleRouter: AppLifecycleRouter
    private let expectedRunID: String
    private let role: RunWindowRole
    private let headline = NSTextField(labelWithString: "Pending")
    private let runMetadataLabel = NSTextField(wrappingLabelWithString: "")
    private let globalDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let inlineMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private let rowsScrollView = NSScrollView()
    private var rowViews: [RunRowView] = []
    private var presentationReducer: RunPresentationReducer
    private let postRunNoticeLabel = NSTextField(wrappingLabelWithString: "")
    private let openLogButton = NSButton(
        title: ShadowSyncPresentation.openLog,
        target: nil,
        action: nil
    )
    private let cancelButton = NSButton(
        title: ShadowSyncPresentation.cancelRun,
        target: nil,
        action: nil
    )
    private let closeButton = NSButton(
        title: ShadowSyncPresentation.closeRun,
        target: nil,
        action: nil
    )
    private var session: WorkerSession?
    private var installedSessionBinding: WorkerSessionBinding?
    private var stopConsumedGenerations: Set<String> = []
    #if SHADOW_SYNC_TESTING
    private var testingWorkerProcessID: pid_t?
    private var testingStopTransactionLaunchCount = 0
    private var testingWireTrace: [String] = []
    private var testingStopExecutor:
        (@Sendable (WorkerSession) -> WorkerStopOutcome)?
    #endif
    private var recoveredLogRecordCount = 0
    private(set) var report: RunReport?
    private(set) var isFinished = false
    private var failureRequiresRecoveryReview = false
    private var reportRequiresRecoveryReview = false
    private var recoveryAcknowledged = false
    private var postRunNotice: PostRunNotice?
    var requiresRecoveryReview: Bool {
        failureRequiresRecoveryReview
            || (reportRequiresRecoveryReview && !recoveryAcknowledged)
            || postRunNotice?.requiresRecoveryAcknowledgement == true
    }
    var blocksNewRun: Bool {
        gateDecision(for: .startNewRun) != .allow
    }
    private(set) var observedPhases: [RepositoryPhase] = []
    private var cancellationRequested = false
    private var terminalEventReceived = false
    private var workerExitHandled = false
    private var workerExitHandlingSettled = false
    private var naturalExitDrainVerified = false
    private var runAuthorityReleased = false
    private var postReapEvidence: WorkerPostReapEvidence?
    private var lastStateLocation: StateLocation?
    private var stopLifecycle = StopLifecycle.idle
    private var ownershipHandshakeVerified = false
    private var protocolFailureDetail: String?
    private var reportValidationFailure = false
    private var presentationSeal: PresentationSeal?
    private var lateWireResidueCount = 0
    private var sealedStopNoticeVisible = false
    private var takeoverTransition = TakeoverTransition.none
    private var takeoverTimeoutToken: String?
    private var quitTransition = QuitTransition.none
    private var quitTimeoutToken: String?
    private var quitStartedAt: TimeInterval?
    private var closeCompleted = false
    var onOpenLog: (() -> Void)?
    var onHide: (() -> Void)?
    var onClose: (() -> Void)?
    var onWorkerExit: ((Int32) -> Void)?
    var onWorkerReaped: ((Int32) -> Void)?
    var onQuitBlocked: (() -> Void)?
    var onQuitReady: (() -> Void)?
    var onRecoveryAcknowledgementRequested: ((RunReport) -> Bool)?
    var isAwaitingFinalReport: Bool {
        terminalEventReceived && !isFinished
    }

    private var gateSnapshot: LifecycleGateSnapshot {
        let stopState: LifecycleGateStopState
        switch stopLifecycle {
        case .idle:
            stopState = .idle
        case .stopping:
            stopState = .stopping
        case let .terminal(_, result):
            switch result {
            case .verified:
                stopState = .completedVerified
            case .blocked(.unverified):
                stopState = .completedUnverified
            case .blocked(.stillActive):
                stopState = .completedStillActive
            }
        }
        let transitionPending: Bool
        if case .pending = takeoverTransition {
            transitionPending = true
        } else {
            transitionPending = false
        }
        return LifecycleGateSnapshot(
            trustedReport: report != nil,
            terminalRunMatched: terminalEventReceived || report != nil,
            reportSettled: isFinished && report != nil,
            failureRecoveryRequired: failureRequiresRecoveryReview,
            reportRecoveryRequired: reportRequiresRecoveryReview,
            recoveryAcknowledged: recoveryAcknowledged,
            needsAttentionResults:
                report?.results.contains(where: { $0.code == .needsAttention }) == true,
            postRunNoticeBlocks: postRunNotice?.blocksNewRun == true,
            workerReaped: workerExitHandled,
            childDrainVerified: naturalExitDrainVerified,
            authorityReleased: runAuthorityReleased,
            stopState: stopState,
            transitionPending: transitionPending
        )
    }

    private func gateDecision(
        for action: LifecycleGateAction
    ) -> LifecycleGateDecision {
        guard role == .liveRun else {
            return .block(.failureRecovery)
        }
        return lifecycleRouter.decideLegacyAction(
            action,
            state: gateSnapshot
        )
    }

    func appDrainEvidence(generation: UInt64) -> AppDrainEvidence {
        let noOwnedWorker = session == nil
        let postReap = postReapEvidence
        return AppDrainEvidence(
            processAdmissionClosed:
                noOwnedWorker || cancellationRequested || isFinished,
            ownedTasksSettled:
                noOwnedWorker || workerExitHandlingSettled,
            allChildrenReaped:
                noOwnedWorker
                    || (
                        workerExitHandled
                            && naturalExitDrainVerified
                    ),
            workerPostReapVerified:
                noOwnedWorker
                    || (
                        postReap?.workerReaped == true
                            && postReap?.childDrainVerified == true
                    ),
            workerOwnershipSettled:
                noOwnedWorker || workerExitHandled,
            body3WorkersTerminal: true,
            confirmationWaitersSettled: true,
            inventoryAuthorityReleased: true,
            operationAuthorityReleased:
                noOwnedWorker || runAuthorityReleased,
            lifecycleAuthorityReleased: true,
            transactionsSettled:
                noOwnedWorker || workerExitHandlingSettled,
            preferenceOutcomeRecorded: true,
            generation: generation
        )
    }

    init(
        candidates: [RepositoryCandidate],
        plannedOperations: [PlannedOperation] = [],
        authorizedOperations: [AuthorizedOperationEnvelope] = [],
        lifecycleRouter: AppLifecycleRouter = AppLifecycleRouter(),
        runID: String? = nil,
        role: RunWindowRole = .liveRun
    ) {
        self.candidates = candidates
        self.plannedOperations = plannedOperations
        self.authorizedOperations = authorizedOperations
        self.lifecycleRouter = lifecycleRouter
        expectedRunID = runID ?? RunIdentity.make()
        self.role = role
        presentationReducer = RunPresentationReducer(
            runID: expectedRunID,
            candidates: candidates
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = ShadowSyncPresentation.appTitle
        window.minSize = NSSize(width: 620, height: 400)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildContent() {
        guard let content = window?.contentView else {
            return
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        content.addSubview(stack)

        headline.font = .preferredFont(forTextStyle: .title2)
        headline.maximumNumberOfLines = 0
        headline.lineBreakMode = .byWordWrapping
        headline.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        headline.setAccessibilityLabel("Run status")
        stack.addArrangedSubview(headline)

        runMetadataLabel.font = .preferredFont(forTextStyle: .caption1)
        runMetadataLabel.textColor = .secondaryLabelColor
        runMetadataLabel.maximumNumberOfLines = 0
        runMetadataLabel.lineBreakMode = .byCharWrapping
        runMetadataLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        runMetadataLabel.isHidden = true
        runMetadataLabel.setAccessibilityLabel("Run timing and cancellation")
        stack.addArrangedSubview(runMetadataLabel)

        globalDetailLabel.font = .preferredFont(forTextStyle: .body)
        globalDetailLabel.textColor = .secondaryLabelColor
        globalDetailLabel.maximumNumberOfLines = 0
        globalDetailLabel.lineBreakMode = .byCharWrapping
        globalDetailLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        globalDetailLabel.isHidden = true
        globalDetailLabel.setAccessibilityLabel("Run detail")
        stack.addArrangedSubview(globalDetailLabel)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        for rowPresentation in presentationReducer.rows {
            let rowView = RunRowView(presentation: rowPresentation)
            rowViews.append(rowView)
            rowsStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        rowsScrollView.hasVerticalScroller = true
        rowsScrollView.autohidesScrollers = true
        rowsScrollView.borderType = .bezelBorder
        rowsScrollView.documentView = rowsStack
        rowsScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(rowsScrollView)
        inlineMessageLabel.isHidden = true
        inlineMessageLabel.textColor = .secondaryLabelColor
        inlineMessageLabel.font = .preferredFont(forTextStyle: .body)
        inlineMessageLabel.maximumNumberOfLines = 0
        inlineMessageLabel.lineBreakMode = .byCharWrapping
        inlineMessageLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        inlineMessageLabel.setAccessibilityLabel("ShadowSync status")
        stack.addArrangedSubview(inlineMessageLabel)
        postRunNoticeLabel.isHidden = true
        postRunNoticeLabel.textColor = .secondaryLabelColor
        postRunNoticeLabel.font = .preferredFont(forTextStyle: .body)
        postRunNoticeLabel.maximumNumberOfLines = 0
        postRunNoticeLabel.lineBreakMode = .byCharWrapping
        postRunNoticeLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        postRunNoticeLabel.setAccessibilityLabel("Run safety notice")
        stack.addArrangedSubview(postRunNoticeLabel)
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        openLogButton.target = self
        openLogButton.action = #selector(openLog)
        openLogButton.setAccessibilityHelp(
            "Opens the one validated current ShadowSync log in its default application."
        )
        cancelButton.target = self
        cancelButton.action = #selector(cancelRun)
        cancelButton.keyEquivalent = ""
        cancelButton.setAccessibilityHelp(
            "Opens a confirmation before asking the active run to stop."
        )
        closeButton.target = self
        closeButton.action = #selector(closeRun)
        closeButton.keyEquivalent = ""
        closeButton.isHidden = true
        closeButton.setAccessibilityHelp(
            "Releases this report window while preserving the latest log and status utility."
        )
        controls.addArrangedSubview(openLogButton)
        controls.addArrangedSubview(cancelButton)
        controls.addArrangedSubview(closeButton)
        stack.addArrangedSubview(controls)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            headline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            runMetadataLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            globalDetailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inlineMessageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            postRunNoticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            rowsStack.leadingAnchor.constraint(equalTo: rowsScrollView.contentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsScrollView.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: rowsScrollView.contentView.topAnchor),
            rowsStack.bottomAnchor.constraint(
                greaterThanOrEqualTo: rowsScrollView.contentView.bottomAnchor
            ),
        ])
        openLogButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = closeButton
        closeButton.nextKeyView = openLogButton
        window?.initialFirstResponder = openLogButton
        window?.defaultButtonCell = nil
    }

    func start(executablePath: String) {
        guard role == .liveRun else {
            return
        }
        #if SHADOW_SYNC_TESTING
        presentFailure("Testing host requires an isolated worker configuration.")
        #else
        guard !plannedOperations.isEmpty,
              authorizedOperations.map(\.operation)
                == plannedOperations else {
            presentFailure(
                "No current repository operations were admitted."
            )
            return
        }
        do {
            start(
                executablePath: executablePath,
                request: try WorkerRequest(
                    authorizedOperations: authorizedOperations,
                    runID: expectedRunID
                ),
                stateLocation: try? StateLocation.production()
            )
        } catch {
            presentFailure(
                Redactor.sanitize(String(describing: error))
            )
        }
        #endif
    }

    #if SHADOW_SYNC_TESTING
    func start(
        executablePath: String,
        isolatedRoot: String,
        transportMapping: TransportMapping,
        ownershipFault: WorkerRequest.OwnershipFault? = nil
    ) {
        guard role == .liveRun else {
            return
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            presentFailure("The isolated M1 worker accepts exactly one repository.")
            return
        }
        start(
            executablePath: executablePath,
            request: WorkerRequest(
                candidate: candidate,
                runID: expectedRunID,
                isolatedRoot: isolatedRoot,
                transportMapping: transportMapping,
                ownershipFault: ownershipFault
            ),
            stateLocation: try? StateLocation.isolated(root: isolatedRoot)
        )
    }
    #endif

    private func start(
        executablePath: String,
        request: WorkerRequest,
        stateLocation: StateLocation?
    ) {
        let requestIsAdmitted = request.operations.isEmpty
            ? WorkerRequest.admitsPayload(request.candidates)
            : WorkerRequest.admitsOperations(request.operations)
        guard requestIsAdmitted else {
            presentFailure(
                request.operations.isEmpty
                    ? "The reviewed selection contains a blocked repository. No worker was started."
                    : "The reviewed Fast-forward selection is no longer valid. No worker was started."
            )
            return
        }
        let binding = WorkerSessionBinding(
            runID: request.runID,
            workerGeneration: request.workerGeneration
        )
        do {
            let client = WorkerClient(executablePath: executablePath)
            let startedSession = try client.start(
                request: request,
                stateLocation: stateLocation,
                installSession: { [weak self] session in
                    self?.installSession(session, binding: binding) == true
                },
                onOwnershipFailure: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.handleProtocolViolation(
                            "The worker ownership frame was missing, malformed, out of order, or did not match the admitted worker.",
                            binding: binding
                        )
                    }
                },
                onMessage: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        self?.accept(message, binding: binding)
                    }
                },
                onExit: { [weak self] status, safety in
                    DispatchQueue.main.async { [weak self] in
                        self?.handleWorkerExit(
                            status: status,
                            evidence: safety,
                            stateLocation: stateLocation,
                            binding: binding
                        )
                    }
                }
            )
            guard session === startedSession else {
                throw WorkerClientError.sessionAssignment
            }
        } catch {
            discardFailedSessionInstallation(binding: binding)
            presentFailure(Redactor.sanitize(String(describing: error)))
        }
    }

    private func installSession(
        _ session: WorkerSession,
        binding: WorkerSessionBinding
    ) -> Bool {
        guard role == .liveRun,
              self.session == nil,
              installedSessionBinding == nil,
              presentationSeal == nil,
              binding.runID == expectedRunID,
              binding.workerGeneration == session.identity.generation,
              !stopConsumedGenerations.contains(binding.workerGeneration),
              case .idle = stopLifecycle else {
            return false
        }
        self.session = session
        installedSessionBinding = binding
        #if SHADOW_SYNC_TESTING
        testingWorkerProcessID = session.processID
        #endif
        return true
    }

    private func discardFailedSessionInstallation(
        binding: WorkerSessionBinding
    ) {
        guard installedSessionBinding == binding,
              !stopConsumedGenerations.contains(binding.workerGeneration),
              case .idle = stopLifecycle else {
            return
        }
        session = nil
        installedSessionBinding = nil
        #if SHADOW_SYNC_TESTING
        testingWorkerProcessID = nil
        #endif
    }

    func presentFailure(
        _ detail: String,
        requiresRecoveryReview: Bool = false
    ) {
        guard report == nil else {
            presentPostRunNotice(PostRunNotice(
                reason: .evidenceConflict,
                detail: detail,
                blocksNewRun: true,
                requiresRecoveryAcknowledgement: requiresRecoveryReview
            ))
            return
        }
        failureRequiresRecoveryReview = requiresRecoveryReview
        cancelPendingTakeover()
        headline.stringValue = "Needs Attention"
        globalDetailLabel.stringValue = detail
        globalDetailLabel.isHidden = false
        finishControls()
    }

    @discardableResult
    func present(report: RunReport) -> Bool {
        present(report: report, source: .historicalOrRecovery)
    }

    @discardableResult
    private func present(
        report: RunReport,
        source: ReportSource
    ) -> Bool {
        if let existing = self.report {
            if existing == report {
                return true
            }
            switch source {
            case let .liveWorker(binding):
                handleProtocolViolation(
                    "The worker returned conflicting final evidence for this run.",
                    binding: binding
                )
            case .historicalOrRecovery:
                presentPostRunNotice(PostRunNotice(
                    reason: .evidenceConflict,
                    detail: "ShadowSync received conflicting final evidence for this run. The first validated report remains displayed. Review the latest log before retrying.",
                    blocksNewRun: true,
                    requiresRecoveryAcknowledgement: true
                ))
            }
            return false
        }

        let staged: StagedRunReportPresentation
        do {
            staged = try presentationReducer.staging(
                report: report,
                policy: {
                    switch source {
                    case .liveWorker:
                        return .liveWorker
                    case .historicalOrRecovery:
                        return .historicalOrRecovery
                    }
                }()
            )
        } catch {
            rejectReport(error, source: source)
            return false
        }

        let requiresRecoveryReview =
            report.summaryOverride == InterruptedRunReconstructor.summary
        let containsNeedsAttention =
            report.results.contains(where: { $0.code == .needsAttention })
        let summary = report.summary
        let metadata = RunReportPresentation.metadata(report)
        let seal = PresentationSeal(
            runID: expectedRunID,
            workerGeneration: {
                if case let .liveWorker(binding) = source {
                    return binding.workerGeneration
                }
                return nil
            }()
        )

        presentationReducer = staged.reducer
        self.report = report
        isFinished = true
        cancellationRequested = false
        failureRequiresRecoveryReview = false
        reportValidationFailure = false
        presentationSeal = seal
        lateWireResidueCount = 0
        recoveryAcknowledged = false
        reportRequiresRecoveryReview = requiresRecoveryReview
        if requiresRecoveryReview || containsNeedsAttention {
            cancelPendingTakeover()
        }
        for index in staged.changedRows {
            updateRow(at: index)
        }
        cancelButton.isEnabled = false
        headline.stringValue = summary
        runMetadataLabel.stringValue = metadata
        runMetadataLabel.isHidden = false
        globalDetailLabel.stringValue = ""
        globalDetailLabel.isHidden = true
        finishControls()
        if case let .terminal(_, .blocked(blocked)) = stopLifecycle {
            presentBlockedStop(blocked)
            return true
        }
        maybeAdvanceTakeover()
        return true
    }

    private func rejectReport(
        _ error: Error,
        source: ReportSource
    ) {
        let sanitized = Redactor.sanitize(String(describing: error))
        switch source {
        case let .liveWorker(binding):
            reportValidationFailure = true
            handleProtocolViolation(
                "The worker returned an invalid final report: \(sanitized)",
                binding: binding
            )
        case .historicalOrRecovery:
            failureRequiresRecoveryReview = true
            cancelPendingTakeover()
            headline.stringValue = "Needs Attention"
            globalDetailLabel.stringValue =
                "The saved report could not be validated. Existing row evidence was preserved. Open the latest log and resolve the recovery condition before retrying."
            globalDetailLabel.isHidden = false
            cancelButton.isEnabled = false
            cancelButton.isHidden = true
            closeButton.isEnabled = false
            closeButton.isHidden = true
        }
    }

    private func presentUnsettledReportFailure(_ detail: String) {
        failureRequiresRecoveryReview = true
        cancelPendingTakeover()
        isFinished = false
        headline.stringValue = "Needs Attention"
        globalDetailLabel.stringValue = detail
        globalDetailLabel.isHidden = false
        cancelButton.isEnabled = false
        cancelButton.isHidden = true
        closeButton.isEnabled = false
        closeButton.isHidden = true
    }

    private func presentPostRunNotice(_ notice: PostRunNotice) {
        if let existing = postRunNotice {
            if existing == notice {
                return
            }
            if existing.blocksNewRun && !notice.blocksNewRun {
                return
            }
        }
        sealedStopNoticeVisible = false
        postRunNotice = notice
        if notice.blocksNewRun && notice.reason != .authorityHeld {
            cancelPendingTakeover()
        }
        closeButton.isEnabled = !notice.blocksNewRun
        postRunNoticeLabel.stringValue = "Needs Attention — \(notice.detail)"
        postRunNoticeLabel.isHidden = false
    }

    private func clearPostRunNotice(reason: PostRunNoticeReason) {
        guard postRunNotice?.reason == reason else {
            return
        }
        postRunNotice = nil
        closeButton.isEnabled = true
        postRunNoticeLabel.stringValue = ""
        postRunNoticeLabel.isHidden = true
    }

    private func presentSafetyBlocker(
        reason: PostRunNoticeReason,
        detail: String
    ) {
        guard report != nil else {
            presentFailure(detail, requiresRecoveryReview: true)
            return
        }
        presentPostRunNotice(PostRunNotice(
            reason: reason,
            detail: detail,
            blocksNewRun: true,
            requiresRecoveryAcknowledgement: true
        ))
    }

    func requestCancellation() {
        guard !isFinished, !terminalEventReceived else {
            return
        }
        if case .terminal = stopLifecycle {
            return
        }
        guard let session else {
            if joinActiveStop(
                intent: .ordinary,
                reason: .operatorRequested
            ) {
                return
            }
            cancelPendingTakeover()
            presentFailure(
                "ShadowSync lost the active worker session before it could request a safe stop. Nothing else was started. Review the latest log before retrying.",
                requiresRecoveryReview: true
            )
            return
        }
        presentStopRequested()
        _ = beginStop(
            intent: .ordinary,
            reason: .operatorRequested,
            session: session
        )
    }

    fileprivate var quitGateDecision: LifecycleGateDecision {
        resolveAuthorityBlockIfPossible()
        return gateDecision(for: .quit)
    }

    fileprivate var hasPendingQuit: Bool {
        if case .pending = quitTransition {
            return true
        }
        return false
    }

    fileprivate func presentStoppingFeedback() {
        if presentationSeal != nil {
            presentSealedStopNotice()
            return
        }
        headline.stringValue = "Stopping…"
        postRunNoticeLabel.stringValue =
            "The current run is still stopping safely. Wait for the verified stop outcome before starting or replacing it."
        postRunNoticeLabel.isHidden = false
    }

    fileprivate func presentQuitInProgressFeedback() {
        if presentationSeal != nil {
            presentSealedStopNotice()
            return
        }
        headline.stringValue = "Quit is already in progress"
        postRunNoticeLabel.stringValue =
            "Quit is already in progress. ShadowSync will close when the current run is safely settled."
        postRunNoticeLabel.isHidden = false
    }

    func presentQuitSafetyBlock() {
        switch quitGateDecision {
        case .block(.authorityHeld):
            presentSafetyBlocker(
                reason: .authorityHeld,
                detail: "Quit was cancelled because the prior run still holds operation authority. The utility remains responsive. Wait for release, then try Quit ShadowSync again."
            )
        case .block(.childDrain), .block(.stopInProgress),
             .block(.workerActive):
            presentSafetyBlocker(
                reason: .childDrainUnverified,
                detail: "Quit was cancelled because ShadowSync could not verify complete child drainage and a safe stop outcome. The utility remains responsive. Review the latest log."
            )
        case .allow, .stopThenReevaluate, .block:
            break
        }
    }

    fileprivate func requestQuitAfterConfirmation() -> QuitTransitionResult {
        cancelPendingTakeover()
        resolveAuthorityBlockIfPossible()
        switch gateDecision(for: .quit) {
        case .allow:
            quitTransition = .finished
            return .terminateNow
        case .stopThenReevaluate:
            establishPendingQuit()
            if joinActiveStop(
                intent: .quit,
                reason: .operatorRequested
            ) {
                return .stopping
            }
            guard let session else {
                cancelPendingQuit()
                presentSafetyBlocker(
                    reason: .childDrainUnverified,
                    detail: "ShadowSync could not verify or reap the worker needed for safe quit. Quit was cancelled; the utility remains available. Review the latest log."
                )
                return .blocked
            }
            presentStopRequested()
            guard beginStop(
                intent: .quit,
                reason: .operatorRequested,
                session: session
            ) != .blocked else {
                cancelPendingQuit()
                presentQuitSafetyBlock()
                return .blocked
            }
            return .stopping
        case .block(.stopInProgress):
            establishPendingQuit()
            _ = joinActiveStop(
                intent: .quit,
                reason: .operatorRequested
            )
            return .stopping
        case .block(.authorityHeld), .block(.awaitingReport):
            establishPendingQuit()
            return .stopping
        case .block(.childDrain)
            where !hasBlockedStopTerminal
                && postReapEvidence?.recordedChildDrain == .noneRecorded
                && (postReapEvidence?.runAuthority == .held
                    || postReapEvidence?.runAuthority == .error):
            establishPendingQuit()
            return .stopping
        case .block:
            quitTransition = .finished
            presentQuitSafetyBlock()
            onQuitBlocked?()
            return .blocked
        }
    }

    private func establishPendingQuit() {
        guard case .pending = quitTransition else {
            quitTransition = .pending
            quitStartedAt = Date().timeIntervalSinceReferenceDate
            let token = RunIdentity.make()
            quitTimeoutToken = token
            scheduleQuitProbe(token: token)
            return
        }
    }

    private func scheduleQuitProbe(token: String) {
        DispatchQueue.global().asyncAfter(
            deadline: .now() + 0.25
        ) { [weak self] in
            Task { @MainActor in
                self?.handleQuitProbe(token: token)
            }
        }
    }

    private func handleQuitProbe(token: String) {
        guard quitTimeoutToken == token,
              case .pending = quitTransition,
              let quitStartedAt else {
            return
        }
        maybeAdvancePendingTransitions()
        guard quitTimeoutToken == token,
              case .pending = quitTransition else {
            return
        }
        if TakeoverWatchdog.hasExpired(
            startedAt: quitStartedAt,
            now: Date().timeIntervalSinceReferenceDate
        ) {
            resolveAuthorityBlockIfPossible()
            if gateDecision(for: .quit) == .allow {
                maybeAdvancePendingTransitions()
                return
            }
            quitTransition = .finished
            quitTimeoutToken = nil
            self.quitStartedAt = nil
            presentQuitSafetyBlock()
            onQuitBlocked?()
            return
        }
        scheduleQuitProbe(token: token)
    }

    @discardableResult
    fileprivate func requestTakeover(
        afterDrain: @escaping () -> Bool
    ) -> TakeoverRequestResult {
        if case .pending = quitTransition {
            presentQuitInProgressFeedback()
            return .blockedByQuit
        }
        return requestTakeoverWithoutPendingQuit(afterDrain: afterDrain)
    }

    private func requestTakeoverWithoutPendingQuit(
        afterDrain: @escaping () -> Bool
    ) -> TakeoverRequestResult {
        resolveAuthorityBlockIfPossible()
        switch gateDecision(for: .takeoverRequest) {
        case .allow:
            establishPendingTakeover(afterDrain)
            maybeAdvanceTakeover()
            return .accepted
        case .stopThenReevaluate:
            establishPendingTakeover(afterDrain)
            if joinActiveStop(
                intent: .takeover,
                reason: .operatorRequested
            ) {
                return .accepted
            }
            if case let .terminal(_, result) = stopLifecycle,
               result.isVerified {
                maybeAdvanceTakeover()
                return .accepted
            }
            guard let session else {
                cancelPendingTakeover()
                presentSafetyBlocker(
                    reason: .childDrainUnverified,
                    detail: ShadowSyncPresentation.unverifiedOwner
                )
                return .blocked
            }
            presentStopRequested()
            guard beginStop(
                intent: .takeover,
                reason: .operatorRequested,
                session: session
            ) != .blocked else {
                cancelPendingTakeover()
                return .blocked
            }
            return .accepted
        case .block:
            return .blocked
        }
    }

    private func establishPendingTakeover(
        _ continuation: @escaping () -> Bool
    ) {
        guard case .pending = takeoverTransition else {
            takeoverTransition = .pending(continuation)
            armTerminalTakeoverTimeout()
            return
        }
    }

    private func presentStopRequested() {
        if presentationSeal != nil {
            presentSealedStopNotice()
            return
        }
        cancellationRequested = true
        headline.stringValue = "Stopping…"
        if let index = presentationReducer.requestStoppingOverlay() {
            updateRow(at: index)
        }
        cancelButton.isEnabled = false
    }

    private func presentSealedStopNotice() {
        guard presentationSeal != nil else {
            return
        }
        sealedStopNoticeVisible = true
        postRunNoticeLabel.stringValue =
            "The completed report is preserved while ShadowSync safely settles the remaining worker."
        postRunNoticeLabel.isHidden = false
    }

    private func clearSealedStopNotice() {
        guard sealedStopNoticeVisible else {
            return
        }
        sealedStopNoticeVisible = false
        guard postRunNotice == nil else {
            return
        }
        postRunNoticeLabel.stringValue = ""
        postRunNoticeLabel.isHidden = true
    }

    fileprivate var takeoverGateDecision: LifecycleGateDecision {
        resolveAuthorityBlockIfPossible()
        return gateDecision(for: .takeoverPresentation)
    }

    func cancelPendingTakeover() {
        takeoverTimeoutToken = nil
        if case .pending = takeoverTransition {
            takeoverTransition = .finished
        }
    }

    private func armTerminalTakeoverTimeout() {
        guard takeoverTimeoutToken == nil else {
            return
        }
        let token = RunIdentity.make()
        takeoverTimeoutToken = token
        let timeout = TakeoverWatchdog.maximumDuration
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
            Task { @MainActor in
                self?.expireTerminalTakeover(token: token)
            }
        }
    }

    private func expireTerminalTakeover(token: String) {
        guard takeoverTimeoutToken == token,
              case .pending = takeoverTransition else {
            return
        }
        cancelPendingTakeover()
        let safelyReleased = workerExitHandlingSettled
            && naturalExitDrainVerified
            && runAuthorityReleased
        guard report != nil else {
            presentFailure(
                "The completed run did not provide a validated final report before the handoff wait ended. No new run was started. Review the latest log before retrying.",
                requiresRecoveryReview: true
            )
            return
        }
        presentPostRunNotice(PostRunNotice(
            reason: .handoffTimedOut,
            detail: safelyReleased
                ? "The completed run is safe, but opening the new selection timed out. Choose Start New Run to try again."
                : "The completed run did not finish proving child drainage and operation-authority release within the safe wait. Review the latest log before retrying.",
            blocksNewRun: !safelyReleased,
            requiresRecoveryAcknowledgement: !safelyReleased
        ))
    }

    private func accept(
        _ message: WorkerWireMessage,
        binding: WorkerSessionBinding
    ) {
        guard callbackIsCurrent(binding) else {
            return
        }
        #if SHADOW_SYNC_TESTING
        if let event = message.event {
            testingWireTrace.append(
                "event:\(event.sequence):\(event.type.rawValue)"
            )
        } else {
            testingWireTrace.append(message.kind.rawValue)
        }
        #endif
        if let seal = presentationSeal,
           seal.runID == expectedRunID,
           (seal.workerGeneration == nil
                || seal.workerGeneration == binding.workerGeneration) {
            if lateWireResidueCount == 0 {
                lateWireResidueCount = 1
            }
            return
        }
        guard !hasOwnershipStop else {
            return
        }
        guard wirePayloadIsValid(message) else {
            handleProtocolViolation(
                "The worker sent a malformed or out-of-order protocol message.",
                binding: binding
            )
            return
        }
        if !ownershipHandshakeVerified {
            guard message.kind == .ownership,
                  let workerIdentity = message.workerIdentity,
                  let runID = message.runID,
                  session?.ownershipProtocolIsComplete(
                    workerIdentity: workerIdentity,
                    runID: runID
                  ) == true else {
                handleProtocolViolation(
                    "The worker ownership handshake was not validated before progress delivery.",
                    binding: binding
                )
                return
            }
            ownershipHandshakeVerified = true
        }
        if let event = message.event {
            guard event.run == expectedRunID else {
                handleProtocolViolation(
                    "The worker returned an event for a different run.",
                    binding: binding
                )
                return
            }
            if isFinished || terminalEventReceived {
                #if SHADOW_SYNC_TESTING
                testingWireTrace.append(
                    "ignored-event:\(event.sequence):"
                        + "finished=\(isFinished):"
                        + "terminal=\(terminalEventReceived)"
                )
                #endif
                if cancellationRequested,
                   event.type != .runFinished {
                    handleProtocolViolation(
                        "The worker returned a post-terminal event while the run was stopping.",
                        binding: binding
                    )
                }
                return
            }
            let change: RunPresentationChange
            do {
                change = try presentationReducer.apply(event)
            } catch {
                handleProtocolViolation(
                    "The worker returned invalid, missing, reordered, or non-monotonic presentation evidence: \(error)",
                    binding: binding
                )
                return
            }
            #if SHADOW_SYNC_TESTING
            testingWireTrace.append(
                "applied:\(event.sequence):\(event.type.rawValue)"
            )
            #endif
            if event.type == .repositoryPhase, let phase = event.phase {
                observedPhases.append(phase)
            }
            switch change {
            case .runStarted:
                if !cancellationRequested {
                    headline.stringValue = "Running"
                }
            case let .row(index):
                updateRow(at: index)
                if !cancellationRequested,
                   event.type == .repositoryPhase,
                   let phase = event.phase {
                    headline.stringValue = phase == .complete
                        ? "Running"
                        : label(for: phase)
                }
            case let .runFinished(summary):
                terminalEventReceived = true
                cancelButton.isEnabled = false
                headline.stringValue = summary
            case .none:
                if !cancellationRequested,
                   event.type == .repositoryPhase,
                   event.phase == .complete {
                    headline.stringValue = "Running"
                }
            }
        }
        if let report = message.report {
            #if SHADOW_SYNC_TESTING
            testingWireTrace.append(
                "report-state:controller=\(terminalEventReceived):"
                    + "reducer=\(presentationReducer.terminalEventReceived)"
            )
            #endif
            present(report: report, source: .liveWorker(binding))
        }
        if let error = message.error, report == nil {
            presentFailure(
                error,
                requiresRecoveryReview: true
            )
        }
    }

    private func wirePayloadIsValid(_ message: WorkerWireMessage) -> Bool {
        switch message.kind {
        case .ownership:
            return message.workerIdentity != nil
                && message.runID == expectedRunID
                && message.event == nil
                && message.report == nil
                && message.error == nil
                && message.childIdentity == nil
        case .childOwnership:
            return message.childIdentity != nil
                && message.event == nil
                && message.report == nil
                && message.error == nil
                && message.workerIdentity == nil
        case .childReleased:
            return message.childIdentity == nil
                && message.event == nil
                && message.report == nil
                && message.error == nil
                && message.workerIdentity == nil
        case .event:
            return message.event != nil
                && message.report == nil
                && message.error == nil
                && message.workerIdentity == nil
                && message.childIdentity == nil
        case .completion:
            return message.report != nil
                && message.event == nil
                && message.error == nil
                && message.workerIdentity == nil
                && message.childIdentity == nil
        case .failure:
            return message.error != nil
                && message.event == nil
                && message.report == nil
                && message.workerIdentity == nil
                && message.childIdentity == nil
        }
    }

    private func callbackIsCurrent(
        _ binding: WorkerSessionBinding
    ) -> Bool {
        binding.runID == expectedRunID
            && installedSessionBinding == binding
    }

    private func handleProtocolViolation(
        _ detail: String,
        binding: WorkerSessionBinding
    ) {
        guard callbackIsCurrent(binding) else {
            return
        }
        if protocolFailureDetail == nil {
            protocolFailureDetail = detail
        }
        cancellationRequested = true
        terminalEventReceived = true

        if joinActiveStop(
            intent: .ordinary,
            reason: .ownershipFailure
        ) {
            headline.stringValue = "Stopping after protocol error…"
            if report == nil {
                globalDetailLabel.stringValue = protocolFailureDetail ?? detail
                globalDetailLabel.isHidden = false
            }
            if let index = presentationReducer.requestStoppingOverlay() {
                updateRow(at: index)
            }
            cancelButton.isEnabled = false
            return
        }
        if case let .terminal(_, result) = stopLifecycle {
            switch result {
            case .verified:
                presentFailure(
                    "\(protocolFailureDetail ?? detail) The completed stop will not be repeated. Review the latest log before retrying.",
                    requiresRecoveryReview: true
                )
            case let .blocked(blocked):
                presentBlockedStop(blocked)
            }
            return
        }
        guard let session else {
            let transaction = StopTransaction(
                token: RunIdentity.make(),
                binding: binding,
                intent: .ordinary,
                reason: .ownershipFailure,
                workerExitStatus: nil
            )
            stopConsumedGenerations.insert(binding.workerGeneration)
            stopLifecycle = .terminal(
                transaction: transaction,
                result: .blocked(.unverified)
            )
            presentBlockedStop(.unverified)
            return
        }
        cancellationRequested = true
        terminalEventReceived = true
        headline.stringValue = "Stopping after protocol error…"
        if report == nil {
            globalDetailLabel.stringValue = protocolFailureDetail ?? detail
            globalDetailLabel.isHidden = false
        }
        if let index = presentationReducer.requestStoppingOverlay() {
            updateRow(at: index)
        }
        cancelButton.isEnabled = false
        _ = beginStop(
            intent: .ordinary,
            reason: .ownershipFailure,
            session: session
        )
    }

    @discardableResult
    private func joinActiveStop(
        intent: StopIntent,
        reason: StopReason
    ) -> Bool {
        guard case var .stopping(transaction) = stopLifecycle,
              callbackIsCurrent(transaction.binding),
              stopConsumedGenerations.contains(
                  transaction.binding.workerGeneration
              ) else {
            return false
        }
        transaction.intent = intent.takingPrecedence(
            over: transaction.intent
        )
        transaction.reason = reason.preservingSafetyPrecedence(
            over: transaction.reason
        )
        stopLifecycle = .stopping(transaction)
        return true
    }

    @discardableResult
    private func beginStop(
        intent: StopIntent,
        reason: StopReason,
        session: WorkerSession
    ) -> BeginStopResult {
        guard let binding = installedSessionBinding,
              binding.runID == expectedRunID,
              binding.workerGeneration == session.identity.generation else {
            return .blocked
        }
        switch stopLifecycle {
        case .stopping:
            return joinActiveStop(intent: intent, reason: reason)
                ? .joined
                : .blocked
        case .terminal:
            return .blocked
        case .idle:
            break
        }
        guard self.session === session,
              !stopConsumedGenerations.contains(
                  binding.workerGeneration
              ) else {
            return .blocked
        }
        let transaction = StopTransaction(
            token: RunIdentity.make(),
            binding: binding,
            intent: intent,
            reason: reason,
            workerExitStatus: nil
        )
        stopConsumedGenerations.insert(binding.workerGeneration)
        stopLifecycle = .stopping(transaction)
        #if SHADOW_SYNC_TESTING
        testingStopTransactionLaunchCount += 1
        let stopExecutor = testingStopExecutor
        #endif
        Thread.detachNewThread { [weak self] in
            #if SHADOW_SYNC_TESTING
            let outcome = stopExecutor?(session) ?? session.stopSafely()
            #else
            let outcome = session.stopSafely()
            #endif
            Task { @MainActor [weak self] in
                self?.completeStop(
                    outcome: outcome,
                    token: transaction.token,
                    binding: transaction.binding
                )
            }
        }
        return .launched
    }

    private func completeStop(
        outcome: WorkerStopOutcome,
        token: String,
        binding: WorkerSessionBinding
    ) {
        guard callbackIsCurrent(binding),
              case let .stopping(transaction) = stopLifecycle,
              transaction.token == token,
              transaction.binding == binding else {
            return
        }
        let terminal = StopTerminalResult(outcome)
        stopLifecycle = .terminal(
            transaction: transaction,
            result: terminal
        )
        switch terminal {
        case .verified:
            if workerExitHandled {
                clearSealedStopNotice()
            }
            if transaction.reason == .ownershipFailure {
                finalizeProtocolViolationStopIfReady()
            } else {
                maybeAdvanceTakeover()
            }
        case let .blocked(result):
            presentBlockedStop(result)
        }
    }

    private func presentBlockedStop(_ result: BlockedStopResult) {
        if reportValidationFailure, report == nil {
            cancelPendingTakeover()
            cancelPendingQuit()
            let stopDetail: String
            switch result {
            case .unverified:
                stopDetail =
                    "ShadowSync could not verify ownership and drainage of the worker after rejecting its final report."
            case .stillActive:
                stopDetail =
                    "The owned worker remained active after the one permitted stop sequence following an invalid final report."
            }
            presentUnsettledReportFailure([
                protocolFailureDetail,
                stopDetail,
                "No new run was started. Review the latest log before retrying.",
            ].compactMap { $0 }.joined(separator: " "))
            return
        }
        let wasTakeover: Bool
        if case let .terminal(transaction, _) = stopLifecycle {
            wasTakeover = transaction.intent == .takeover
        } else {
            wasTakeover = false
        }
        cancelPendingTakeover()
        cancelPendingQuit()
        if wasTakeover, result == .unverified {
            if report == nil {
                presentFailure(
                    ShadowSyncPresentation.unverifiedOwner,
                    requiresRecoveryReview: true
                )
            } else {
                presentPostRunNotice(PostRunNotice(
                    reason: .childDrainUnverified,
                    detail: ShadowSyncPresentation.unverifiedOwner,
                    blocksNewRun: true,
                    requiresRecoveryAcknowledgement: true
                ))
            }
            return
        }
        let stopDetail: String
        switch result {
        case .unverified:
            stopDetail =
                "ShadowSync could not verify ownership and drainage of the prior run. It will not signal that session again."
        case .stillActive:
            stopDetail =
                "The owned worker remained active after the one permitted TERM/KILL stop sequence. ShadowSync will not signal that session again."
        }
        let detail = [
            protocolFailureDetail,
            stopDetail,
            "No new run was started. Restart ShadowSync to run fresh recovery checks, and review the latest log.",
        ].compactMap { $0 }.joined(separator: " ")
        if report == nil {
            presentFailure(detail, requiresRecoveryReview: true)
            return
        }
        presentPostRunNotice(PostRunNotice(
            reason: .childDrainUnverified,
            detail: detail,
            blocksNewRun: true,
            requiresRecoveryAcknowledgement: true
        ))
    }

    private func finalizeProtocolViolationStopIfReady() {
        guard case let .terminal(transaction, result) = stopLifecycle,
              transaction.reason == .ownershipFailure,
              workerExitHandled,
              let evidence = postReapEvidence else {
            return
        }
        let safelyStopped = result.isVerified
            && evidence.childDrainVerified
            && evidence.authorityReleased
        let detail = protocolFailureDetail
            ?? "The worker protocol could not be verified."
        if safelyStopped {
            let message =
                "\(detail) The owned worker and children were verified reaped and operation authority was released. Review the latest log before retrying."
            if reportValidationFailure {
                presentUnsettledReportFailure(message)
            } else {
                presentFailure(
                    message,
                    requiresRecoveryReview: true
                )
            }
            if let workerExitStatus = transaction.workerExitStatus {
                onWorkerExit?(workerExitStatus)
            }
            maybeAdvancePendingTransitions()
        } else {
            if case let .blocked(blocked) = result {
                presentBlockedStop(blocked)
                return
            }
            let message =
                "\(detail) ShadowSync could not verify complete stop, child drainage, and authority release. No new run was started."
            if reportValidationFailure {
                presentUnsettledReportFailure(message)
            } else {
                presentFailure(
                    message,
                    requiresRecoveryReview: true
                )
            }
            if report != nil {
                presentPostReapSafety(evidence)
            }
        }
    }

    private func cancelPendingQuit() {
        guard case .pending = quitTransition else {
            return
        }
        quitTransition = .finished
        quitTimeoutToken = nil
        quitStartedAt = nil
        onQuitBlocked?()
    }

    fileprivate func maybeAdvancePendingTransitions() {
        resolveAuthorityBlockIfPossible()
        if case .pending = quitTransition {
            guard gateDecision(for: .quit) == .allow else {
                return
            }
            quitTransition = .finished
            quitTimeoutToken = nil
            quitStartedAt = nil
            onQuitReady?()
            return
        }
        advanceTakeoverIfPossible()
    }

    private func maybeAdvanceTakeover() {
        maybeAdvancePendingTransitions()
    }

    private func advanceTakeoverIfPossible() {
        guard case let .pending(continuation) = takeoverTransition,
              gateDecision(for: .takeoverAdvance) == .allow else {
            return
        }
        takeoverTransition = .finished
        takeoverTimeoutToken = nil
        if !continuation() {
            presentPostRunNotice(PostRunNotice(
                reason: .handoffTimedOut,
                detail: "The completed run is safe, but opening the new selection did not complete. Choose Start New Run to try again.",
                blocksNewRun: false,
                requiresRecoveryAcknowledgement: false
            ))
        }
    }

    private func isVerifiedStopOutcome(_ outcome: WorkerStopOutcome) -> Bool {
        VerifiedStopResult(outcome) != nil
    }

    private var hasOwnershipStop: Bool {
        if protocolFailureDetail != nil {
            return true
        }
        switch stopLifecycle {
        case let .stopping(transaction),
             let .terminal(transaction, _):
            return transaction.reason == .ownershipFailure
        case .idle:
            return false
        }
    }

    private var hasBlockedStopTerminal: Bool {
        guard case let .terminal(_, result) = stopLifecycle else {
            return false
        }
        if case .blocked = result {
            return true
        }
        return false
    }

    private func handleWorkerExit(
        status: Int32,
        evidence: WorkerPostReapEvidence,
        stateLocation: StateLocation?,
        binding: WorkerSessionBinding
    ) {
        guard callbackIsCurrent(binding), !workerExitHandled else {
            return
        }
        switch stopLifecycle {
        case let .stopping(transaction),
             let .terminal(transaction, _):
            guard transaction.binding == binding else {
                return
            }
        case .idle:
            break
        }
        workerExitHandled = true
        onWorkerReaped?(status)
        postReapEvidence = evidence
        naturalExitDrainVerified = evidence.childDrainVerified
        runAuthorityReleased = evidence.authorityReleased
        lastStateLocation = stateLocation
        session = nil
        clearSealedStopNotice()
        switch stopLifecycle {
        case var .stopping(transaction):
            guard transaction.binding == binding else {
                return
            }
            transaction.workerExitStatus = status
            stopLifecycle = .stopping(transaction)
            if transaction.reason == .ownershipFailure {
                workerExitHandlingSettled = true
                finalizeProtocolViolationStopIfReady()
                return
            }
        case .terminal(var transaction, let result):
            guard transaction.binding == binding else {
                return
            }
            transaction.workerExitStatus = status
            stopLifecycle = .terminal(
                transaction: transaction,
                result: result
            )
            workerExitHandlingSettled = true
            if transaction.reason == .ownershipFailure {
                finalizeProtocolViolationStopIfReady()
                return
            }
            if case let .blocked(blocked) = result {
                presentBlockedStop(blocked)
                return
            }
        case .idle:
            break
        }
        if report == nil, let stateLocation {
            do {
                let state = try SecureStateDirectory.open(stateLocation)
                recoveredLogRecordCount = try RunLogReader.records(state: state).count
                if let recovered = try RunLogReader.latestReport(
                    state: state,
                    matching: expectedRunID
                ) {
                    present(report: recovered)
                }
            } catch {
                // The terminal failure state below is authoritative when recovery is unavailable.
            }
            if report == nil {
                switch RunRecoveryInspector.inspect(at: stateLocation) {
                case let .previousReport(recovered) where recovered.run == expectedRunID:
                    present(report: recovered)
                case .operationStillActive:
                    presentFailure(
                        "\(InterruptedRunReconstructor.operationContentionTitle). \(InterruptedRunReconstructor.operationContentionMessage) \(InterruptedRunReconstructor.operationContentionRecovery)",
                        requiresRecoveryReview: true
                    )
                case .needsAttention, .none, .previousReport:
                    break
                }
            }
        }
        switch WorkerExitPresentationDecision.resolve(
            status: status,
            hasValidatedCompleteReport: report != nil
        ) {
        case .preserveCompletedReport:
            break
        case let .presentFailure(failureStatus):
            let recovery = recoveredLogRecordCount > 0
                ? " Recovered \(recoveredLogRecordCount) validated partial log records."
                : ""
            presentFailure(
                "The worker ended unexpectedly (status \(failureStatus)).\(recovery) Review the validated latest log before retrying.",
                requiresRecoveryReview: report == nil
            )
        }
        presentPostReapSafety(evidence)
        workerExitHandlingSettled = true
        maybeAdvanceTakeover()
        if naturalExitDrainVerified && runAuthorityReleased {
            onWorkerExit?(status)
        }
    }

    #if SHADOW_SYNC_TESTING
    private func testingCallbackBinding() -> WorkerSessionBinding {
        if let installedSessionBinding {
            return installedSessionBinding
        }
        let binding: WorkerSessionBinding
        switch stopLifecycle {
        case let .stopping(transaction),
             let .terminal(transaction, _):
            binding = transaction.binding
        case .idle:
            binding = WorkerSessionBinding(
                runID: expectedRunID,
                workerGeneration: RunIdentity.make()
            )
        }
        installedSessionBinding = binding
        return binding
    }

    private func accept(_ message: WorkerWireMessage) {
        accept(message, binding: testingCallbackBinding())
    }

    private func handleWorkerExit(
        status: Int32,
        evidence: WorkerPostReapEvidence,
        stateLocation: StateLocation?
    ) {
        handleWorkerExit(
            status: status,
            evidence: evidence,
            stateLocation: stateLocation,
            binding: testingCallbackBinding()
        )
    }

    private func handleWorkerExit(
        status: Int32,
        childDrainVerified: Bool,
        authorityReleased: Bool? = nil,
        stateLocation: StateLocation?
    ) {
        let authorityEvidence: RunAuthorityEvidence
        if let authorityReleased {
            authorityEvidence = authorityReleased ? .released : .held
        } else if runAuthorityReleased {
            authorityEvidence = .released
        } else if stateLocation == nil {
            authorityEvidence = .unavailable
        } else {
            do {
                let proof = try RunAuthority.acquireRun(at: stateLocation!)
                proof.release()
                authorityEvidence = .released
            } catch SecureStateError.contention {
                authorityEvidence = .held
            } catch {
                authorityEvidence = .error
            }
        }
        handleWorkerExit(
            status: status,
            evidence: WorkerPostReapEvidence(
                workerReaped: true,
                ownershipProtocol: .complete,
                recordedChildDrain:
                    childDrainVerified ? .verified : .unverified,
                runAuthority: authorityEvidence
            ),
            stateLocation: stateLocation
        )
    }
    #endif

    func prepareForNewRun() -> Bool {
        guard role == .liveRun else {
            return false
        }
        resolveAuthorityBlockIfPossible()
        return gateDecision(for: .startNewRun) == .allow
    }

    private func presentPostReapSafety(_ evidence: WorkerPostReapEvidence) {
        if evidence.recordedChildDrain == .unverified
            && evidence.runAuthority == .released {
            presentSafetyBlocker(
                reason: .evidenceConflict,
                detail: "The operation authority is released, but a recorded Git child could not be verified as drained. This evidence is inconsistent; the displayed report is unchanged. Review the latest log before retrying."
            )
            return
        }
        if evidence.ownershipProtocol == .incomplete
            || evidence.recordedChildDrain == .unverified {
            presentSafetyBlocker(
                reason: .childDrainUnverified,
                detail: "The worker exited, but ShadowSync could not verify the complete child-ownership protocol and child drainage. The displayed report is unchanged. Review the latest log before retrying."
            )
            return
        }
        switch evidence.runAuthority {
        case .released:
            clearPostRunNotice(reason: .authorityHeld)
        case .held:
            let corroboration = evidence.recordedChildDrain == .noneRecorded
                ? " No child identity was recorded, so release is also required to prove that no admitted Git child survived."
                : ""
            presentSafetyBlocker(
                reason: .authorityHeld,
                detail: "The prior run still holds operation authority.\(corroboration) The displayed report is unchanged. Wait for release, then retry the action."
            )
        case .error:
            presentSafetyBlocker(
                reason: .authorityHeld,
                detail: "ShadowSync could not probe whether the prior run released operation authority. The displayed report is unchanged. Retry the action; no process will be signaled."
            )
        case .unavailable:
            presentSafetyBlocker(
                reason: evidence.recordedChildDrain == .noneRecorded
                    ? .childDrainUnverified
                    : .authorityHeld,
                detail: "The secure state location needed to verify post-run authority is unavailable. The displayed report is unchanged. Review the latest log before retrying."
            )
        }
    }

    private func resolveAuthorityBlockIfPossible() {
        guard let evidence = postReapEvidence,
              evidence.workerReaped,
              evidence.ownershipProtocol == .complete,
              evidence.runAuthority == .held || evidence.runAuthority == .error,
              let lastStateLocation else {
            return
        }
        let authorityEvidence: RunAuthorityEvidence
        do {
            let proof = try RunAuthority.acquireRun(at: lastStateLocation)
            proof.release()
            authorityEvidence = .released
        } catch SecureStateError.contention {
            authorityEvidence = .held
        } catch {
            authorityEvidence = .error
        }
        guard authorityEvidence != evidence.runAuthority else {
            return
        }
        let updated = WorkerPostReapEvidence(
            workerReaped: evidence.workerReaped,
            ownershipProtocol: evidence.ownershipProtocol,
            recordedChildDrain: evidence.recordedChildDrain,
            runAuthority: authorityEvidence
        )
        postReapEvidence = updated
        naturalExitDrainVerified = updated.childDrainVerified
        runAuthorityReleased = updated.authorityReleased
        presentPostReapSafety(updated)
    }

    private func finishControls() {
        isFinished = true
        cancelButton.isEnabled = false
        cancelButton.isHidden = true
        closeButton.isEnabled = true
        closeButton.isHidden = false
        openLogButton.nextKeyView = closeButton
        closeButton.nextKeyView = openLogButton
    }

    private func label(for phase: RepositoryPhase) -> String {
        switch phase {
        case .pending: return "Pending"
        case .checking: return "Checking"
        case .fetching: return "Fetching"
        case .updating: return "Updating"
        case .stopping: return "Stopping…"
        case .complete: return "Complete"
        }
    }

    private func label(for code: ResultCode) -> String {
        ResultCodePresentation.label(for: code)
    }

    private func updateRow(at index: Int) {
        guard presentationReducer.rows.indices.contains(index),
              rowViews.indices.contains(index) else {
            return
        }
        rowViews[index].update(presentationReducer.rows[index])
    }

    func presentInlineMessage(_ text: String?) {
        inlineMessageLabel.stringValue = text ?? ""
        inlineMessageLabel.isHidden = text == nil
    }

    var canPresentStatusItemGuidance: Bool {
        inlineMessageLabel.isHidden
    }

    var repositoryCount: Int {
        candidates.count
    }

    var isPresentationOpen: Bool {
        !closeCompleted && window != nil
    }

    func dismissHistoricalPresentation() {
        guard role == .historicalViewer else {
            return
        }
        closeCompleted = true
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeCompleted {
            return true
        }
        onHide?()
        sender.orderOut(nil)
        return false
    }

    @objc private func openLog() {
        onOpenLog?()
    }

    @objc private func cancelRun() {
        let alert = ShadowSyncAlertFactory.cancellation()
        if alert.runModal() == .alertSecondButtonReturn {
            requestCancellation()
        }
    }

    @objc private func closeRun() {
        if role == .historicalViewer {
            if reportRequiresRecoveryReview && !recoveryAcknowledged {
                guard let report,
                      onRecoveryAcknowledgementRequested?(report) == true else {
                    presentPostRunNotice(PostRunNotice(
                        reason: .evidenceConflict,
                        detail: "Close Report can acknowledge recovery only while the complete report is visible and its bound log evidence is unchanged. Open the latest log and resolve the evidence before retrying.",
                        blocksNewRun: true,
                        requiresRecoveryAcknowledgement: true
                    ))
                    return
                }
                recoveryAcknowledged = true
            }
            guard !closeCompleted else { return }
            closeCompleted = true
            onClose?()
            return
        }
        resolveAuthorityBlockIfPossible()
        switch gateDecision(for: .closeRun) {
        case .allow:
            guard !closeCompleted else { return }
            closeCompleted = true
            onClose?()
        case .block(.recoveryReview):
            guard let report,
                  onRecoveryAcknowledgementRequested?(report) == true else {
                presentPostRunNotice(PostRunNotice(
                    reason: .evidenceConflict,
                    detail: "Close Report can acknowledge recovery only while the complete report is visible and its bound log evidence is unchanged. Open the latest log and resolve the evidence before retrying.",
                    blocksNewRun: true,
                    requiresRecoveryAcknowledgement: true
                ))
                return
            }
            recoveryAcknowledged = true
            closeRun()
        case .block(.needsAttentionResults):
            presentPostRunNotice(PostRunNotice(
                reason: .evidenceConflict,
                detail: "This report contains Needs Attention results. Open the latest log and resolve the reported safety condition before starting or closing this run.",
                blocksNewRun: true,
                requiresRecoveryAcknowledgement: true
            ))
        case .block(.failureRecovery), .block(.awaitingReport):
            presentFailure(
                "Close Report is unavailable because no complete, trustworthy report is bound to stable log evidence. Open the latest log and resolve the recovery condition before retrying.",
                requiresRecoveryReview: true
            )
        case .block:
            return
        case .stopThenReevaluate:
            return
        }
    }

    #if SHADOW_SYNC_TESTING
    var testWorkerDrained: Bool {
        session == nil
    }

    var testingWireTraceSnapshot: [String] {
        testingWireTrace
    }

    var testingHasNoLifecycleEvidence: Bool {
        role == .historicalViewer
            && session == nil
            && installedSessionBinding == nil
            && !workerExitHandled
            && !workerExitHandlingSettled
            && !naturalExitDrainVerified
            && !runAuthorityReleased
            && postReapEvidence == nil
            && stopLifecycle == .idle
            && testingStopTransactionLaunchCount == 0
    }

    var testingStopCount: Int {
        testingStopTransactionLaunchCount
    }

    var testWorkerProcessID: pid_t? {
        testingWorkerProcessID
    }

    func testCloseRun() {
        closeRun()
    }

    func testingHideAsIntent() {
        onHide?()
        window?.orderOut(nil)
    }

    func testingPresentSafeWorkerExit(status: Int32 = 0) {
        handleWorkerExit(
            status: status,
            evidence: WorkerPostReapEvidence(
                workerReaped: true,
                ownershipProtocol: .complete,
                recordedChildDrain: .noneRecorded,
                runAuthority: .released
            ),
            stateLocation: nil
        )
    }

    var testNeedsAttention: Bool {
        headline.stringValue == "Needs Attention"
    }

    var testRecoveredLogRecordCount: Int {
        recoveredLogRecordCount
    }

    var testRowText: String {
        (
            [runMetadataLabel.stringValue, globalDetailLabel.stringValue]
                + rowViews.flatMap {
                    [
                        $0.testingIdentityText,
                        $0.testingPathText,
                        $0.testingStatusText,
                        $0.testingDetailText,
                    ]
                }
        )
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    var testingLocationTexts: [String] {
        rowViews.map(\.testingPathText)
    }

    var testHasSymbol: Bool {
        !rowViews.isEmpty
            && rowViews.allSatisfy { $0.testingSymbolDescription != nil }
    }

    func testingAcceptEvent(_ event: RunEvent) {
        ownershipHandshakeVerified = true
        accept(.event(event))
    }

    func testingAcceptEventAndCompleteRender(_ event: RunEvent) {
        testingAcceptEvent(event)
        if let index = presentationReducer.activeRowIndex,
           rowViews.indices.contains(index) {
            rowViews[index].layoutSubtreeIfNeeded()
            rowViews[index].displayIfNeeded()
        }
    }

    var testingRows: [RunRowPresentation] {
        presentationReducer.rows
    }

    var testingRunID: String {
        expectedRunID
    }

    var testingLastEventSequence: Int {
        presentationReducer.lastEventSequence
    }

    var testingRowObjectIdentifiers: [ObjectIdentifier] {
        rowViews.map(ObjectIdentifier.init)
    }

    var testingRowUpdateCounts: [Int] {
        rowViews.map(\.testingUpdateCount)
    }

    var testingAccessibilitySnapshot: (
        rowLabels: [String?],
        rowValues: [Any?],
        symbolDescriptions: [String?],
        initialResponderIsSafe: Bool,
        keyOrderIsLogical: Bool,
        destructiveButtonsAreNotDefault: Bool
    ) {
        (
            rowViews.map { $0.accessibilityLabel() },
            rowViews.map { $0.accessibilityValue() },
            rowViews.map(\.testingSymbolDescription),
            window?.initialFirstResponder === openLogButton,
            openLogButton.nextKeyView === cancelButton
                && cancelButton.nextKeyView === closeButton
                && closeButton.nextKeyView === openLogButton,
            window?.defaultButtonCell !== cancelButton.cell
                && window?.defaultButtonCell !== closeButton.cell
                && cancelButton.keyEquivalent != "\r"
                && cancelButton.keyEquivalent != "\u{1b}"
                && closeButton.keyEquivalent != "\r"
                && closeButton.keyEquivalent != "\u{1b}"
        )
    }

    var testingAdaptiveSnapshot: (
        resizable: Bool,
        minimumSize: NSSize,
        scrolls: Bool,
        contentExceedsViewport: Bool,
        rowsFillViewport: Bool,
        rowsWrap: Bool,
        usesSemanticColors: Bool
    ) {
        (
            window?.styleMask.contains(.resizable) == true,
            window?.minSize ?? .zero,
            rowsScrollView.hasVerticalScroller,
            rowsStack.frame.height > rowsScrollView.contentView.bounds.height,
            rowsScrollView.documentView === rowsStack
                && rowViews.allSatisfy { rowView in
                    rowsStack.constraints.contains { constraint in
                        let forward =
                            (constraint.firstItem as AnyObject?) === rowView
                                && constraint.firstAttribute == .width
                                && (constraint.secondItem as AnyObject?)
                                    === rowsStack
                                && constraint.secondAttribute == .width
                        let reverse =
                            (constraint.firstItem as AnyObject?) === rowsStack
                                && constraint.firstAttribute == .width
                                && (constraint.secondItem as AnyObject?)
                                    === rowView
                                && constraint.secondAttribute == .width
                        return constraint.relation == .equal
                            && (forward || reverse)
                    }
                },
            rowViews.allSatisfy(\.testingSupportsWrapping),
            runMetadataLabel.textColor == .secondaryLabelColor
                && globalDetailLabel.textColor == .secondaryLabelColor
                && inlineMessageLabel.textColor == .secondaryLabelColor
                && postRunNoticeLabel.textColor == .secondaryLabelColor
                && rowViews.allSatisfy(\.testingUsesSemanticColors)
        )
    }

    var testingInlineMessage: String? {
        inlineMessageLabel.isHidden ? nil : inlineMessageLabel.stringValue
    }

    var testingRunMetadata: String? {
        runMetadataLabel.isHidden ? nil : runMetadataLabel.stringValue
    }

    func testingPresentUnverifiedTakeover() {
        testingSetTerminal(
            reason: .operatorRequested,
            outcome: .unverified,
            intent: .takeover
        )
        presentBlockedStop(.unverified)
    }

    func testingConfigureStoppingForRouting() {
        testingSetStopping(reason: .operatorRequested)
        headline.stringValue = "Stopping…"
    }

    private var rowLabels: [String: String] {
        Dictionary(
            uniqueKeysWithValues: presentationReducer.rows.map {
                ($0.repository.path, $0.status.label)
            }
        )
    }

    func testKillWorker() {
        guard let session else {
            return
        }
        _ = kill(session.processID, SIGKILL)
    }

    @discardableResult
    private func testingSetStopping(
        reason: StopReason,
        intent: StopIntent = .ordinary,
        workerExitStatus: Int32? = nil,
        token: String = RunIdentity.make(),
        generation: String = RunIdentity.make()
    ) -> StopTransaction {
        let binding = WorkerSessionBinding(
            runID: expectedRunID,
            workerGeneration: generation
        )
        let transaction = StopTransaction(
            token: token,
            binding: binding,
            intent: intent,
            reason: reason,
            workerExitStatus: workerExitStatus
        )
        installedSessionBinding = binding
        stopConsumedGenerations.insert(generation)
        stopLifecycle = .stopping(transaction)
        return transaction
    }

    @discardableResult
    private func testingSetTerminal(
        reason: StopReason,
        outcome: WorkerStopOutcome,
        intent: StopIntent = .ordinary,
        workerExitStatus: Int32? = nil,
        token: String = RunIdentity.make(),
        generation: String = RunIdentity.make()
    ) -> StopTransaction {
        let transaction = testingSetStopping(
            reason: reason,
            intent: intent,
            workerExitStatus: workerExitStatus,
            token: token,
            generation: generation
        )
        stopLifecycle = .terminal(
            transaction: transaction,
            result: StopTerminalResult(outcome)
        )
        return transaction
    }

    private func testingCompleteStop(
        outcome: WorkerStopOutcome,
        token: String? = nil,
        binding: WorkerSessionBinding? = nil
    ) {
        guard case let .stopping(transaction) = stopLifecycle else {
            return
        }
        completeStop(
            outcome: outcome,
            token: token ?? transaction.token,
            binding: binding ?? transaction.binding
        )
    }

    static func testingStopLifecycleStateIsCoherent() -> Bool {
        let candidate = RepositoryCandidate(
            id: "fixture-owner/stop-state",
            displayName: "Stop State",
            path: "/private/tmp/stop-state",
            rawOrigin: "https://github.com/fixture-owner/stop-state.git"
        )
        func cancelledResult() -> RepositoryResult {
            RepositoryResult(
                repository: candidate,
                code: .cancelledPending,
                fetched: false,
                mainUpdated: false,
                beforeCommit: nil,
                targetCommit: nil,
                afterCommit: nil,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.000Z",
                durationMilliseconds: 0,
                explanation: "Stable lifecycle fixture."
            )
        }

        let activeWithoutSession = RunWindowController(candidates: [candidate])
        activeWithoutSession.requestCancellation()
        var blockedTakeoverCallbacks = 0
        activeWithoutSession.requestTakeover {
            blockedTakeoverCallbacks += 1
            return true
        }
        guard activeWithoutSession.testNeedsAttention,
              activeWithoutSession.isFinished,
              activeWithoutSession.requiresRecoveryReview,
              activeWithoutSession.headline.stringValue != "Stopping…",
              !activeWithoutSession.cancellationRequested,
              blockedTakeoverCallbacks == 0 else {
            return false
        }

        let terminalWithoutSession = RunWindowController(candidates: [candidate])
        terminalWithoutSession.terminalEventReceived = true
        terminalWithoutSession.headline.stringValue = "Run complete"
        terminalWithoutSession.cancelButton.isEnabled = false
        terminalWithoutSession.requestCancellation()
        guard terminalWithoutSession.headline.stringValue == "Run complete",
              !terminalWithoutSession.cancelButton.isEnabled,
              !terminalWithoutSession.cancellationRequested else {
            return false
        }

        let repeated = RunWindowController(candidates: [candidate])
        repeated.testingSetStopping(
            reason: .operatorRequested,
            workerExitStatus: nil
        )
        repeated.cancellationRequested = true
        repeated.headline.stringValue = "Stopping…"
        repeated.cancelButton.isEnabled = false
        var callbackCount = 0
        repeated.takeoverTransition = .pending {
            callbackCount += 1
            return true
        }
        repeated.requestCancellation()
        repeated.present(report: RunReport(
            run: repeated.expectedRunID,
            startedAt: "2026-09-05T20:00:00.000Z",
            endedAt: "2026-09-05T20:00:00.000Z",
            cancelled: true,
            results: [cancelledResult()]
        ))
        repeated.runAuthorityReleased = true
        repeated.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        repeated.testingCompleteStop(outcome: .alreadyExited(0))
        repeated.testingCompleteStop(outcome: .alreadyExited(0))
        guard callbackCount == 1,
              repeated.workerExitHandled,
              repeated.headline.stringValue != "Stopping…" else {
            return false
        }

        let exitFirst = RunWindowController(candidates: [candidate])
        exitFirst.testingSetStopping(
            reason: .ownershipFailure,
            workerExitStatus: nil
        )
        var exitFirstCallbacks = 0
        exitFirst.onWorkerExit = { _ in exitFirstCallbacks += 1 }
        exitFirst.headline.stringValue = "Stopping unverified worker…"
        exitFirst.handleWorkerExit(
            status: 137,
            childDrainVerified: true,
            authorityReleased: true,
            stateLocation: nil
        )
        guard exitFirst.headline.stringValue == "Stopping unverified worker…",
              !exitFirst.isFinished,
              exitFirstCallbacks == 0 else {
            return false
        }
        exitFirst.testingCompleteStop(outcome: .killed(137))
        let exitFirstCopy = exitFirst.testRowText
        exitFirst.handleWorkerExit(
            status: 137,
            childDrainVerified: true,
            stateLocation: nil
        )
        guard exitFirst.testNeedsAttention,
              exitFirst.requiresRecoveryReview,
              exitFirstCopy.contains("verified reaped"),
              exitFirst.testRowText == exitFirstCopy,
              exitFirstCallbacks == 1 else {
            return false
        }

        let callbackFirst = RunWindowController(candidates: [candidate])
        callbackFirst.testingSetStopping(
            reason: .ownershipFailure,
            workerExitStatus: nil
        )
        var callbackFirstCallbacks = 0
        callbackFirst.onWorkerExit = { _ in callbackFirstCallbacks += 1 }
        callbackFirst.testingCompleteStop(outcome: .alreadyExited(0))
        guard callbackFirstCallbacks == 0 else { return false }
        callbackFirst.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            authorityReleased: true,
            stateLocation: nil
        )
        let callbackFirstCopy = callbackFirst.testRowText
        callbackFirst.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        let lateReport = RunReport(
            run: callbackFirst.expectedRunID,
            startedAt: "fixture",
            endedAt: "fixture",
            cancelled: false,
            results: []
        )
        callbackFirst.accept(.completion(lateReport))
        guard callbackFirst.testNeedsAttention,
              callbackFirst.requiresRecoveryReview,
              callbackFirstCopy.contains("verified reaped"),
              callbackFirst.testRowText == callbackFirstCopy,
              callbackFirst.report == nil,
              callbackFirstCallbacks == 1 else {
            return false
        }

        for outcome in [WorkerStopOutcome.unverified, .stillActive] {
            let uncertain = RunWindowController(candidates: [candidate])
            uncertain.testingSetStopping(
                reason: .ownershipFailure,
                workerExitStatus: nil
            )
            uncertain.testingCompleteStop(outcome: outcome)
            uncertain.handleWorkerExit(
                status: 0,
                childDrainVerified: false,
                stateLocation: nil
            )
            guard uncertain.testNeedsAttention,
                  uncertain.requiresRecoveryReview,
                  uncertain.testRowText.contains(
                      "will not signal that session again"
                  ),
                  !uncertain.testRowText.contains("safely drained") else {
                return false
            }
        }
        do {
            let generation = RunIdentity.make()
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: generation
            )
            var uncertainPipe: [Int32] = [-1, -1]
            guard pipe(&uncertainPipe) == 0 else { return false }
            let uncertainSession = WorkerSession(
                processID: getpid(),
                controlWrite: uncertainPipe[1],
                identity: identity
            )
            uncertainSession.markExited(0, childDrainVerified: false)
            let uncertainOutcome = uncertainSession.stopSafely(
                cooperativeTimeout: 0,
                termTimeout: 0,
                killTimeout: 0
            )
            Darwin.close(uncertainPipe[0])

            var verifiedPipe: [Int32] = [-1, -1]
            guard pipe(&verifiedPipe) == 0 else { return false }
            Darwin.close(verifiedPipe[0])
            let verifiedSession = WorkerSession(
                processID: getpid(),
                controlWrite: verifiedPipe[1],
                identity: identity
            )
            verifiedSession.markExited(0, childDrainVerified: true)
            let verifiedOutcome = verifiedSession.stopSafely(
                cooperativeTimeout: 0,
                termTimeout: 0,
                killTimeout: 0
            )
            guard uncertainOutcome == .unverified,
                  verifiedOutcome == .alreadyExited(0) else {
                return false
            }
        } catch {
            return false
        }
        return true
    }

    fileprivate static func testingSealedPresentationRaces(
        root: String
    ) -> Bool {
        final class BlockingStopExecutor: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)

            func execute() -> WorkerStopOutcome {
                lock.lock()
                count += 1
                lock.unlock()
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return .alreadyExited(0)
            }

            var invocationCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        func fail(_ stage: String) -> Bool {
            fputs("M5 sealed presentation failure: \(stage)\n", stderr)
            return false
        }
        func candidates(_ label: String, count: Int) -> [RepositoryCandidate] {
            (0..<count).map { index in
                RepositoryCandidate(
                    id: "fixture-owner/\(label)-\(index)",
                    displayName: "\(label) \(index)",
                    path: "\(root)/\(label)-\(index)",
                    rawOrigin: "https://github.com/fixture-owner/\(label)-\(index).git"
                )
            }
        }
        func result(
            _ candidate: RepositoryCandidate,
            code: ResultCode
        ) -> RepositoryResult {
            let updated = code == .updated
                || code == .updatedBeforeCancellation
                || code == .updatedWithWarning
            return RepositoryResult(
                repository: candidate,
                code: code,
                fetched: code != .cancelledPending,
                mainUpdated: updated,
                beforeCommit: "1111111111111111111111111111111111111111",
                targetCommit: "2222222222222222222222222222222222222222",
                afterCommit: updated
                    ? "2222222222222222222222222222222222222222"
                    : "1111111111111111111111111111111111111111",
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.125Z",
                durationMilliseconds: 125,
                explanation: "Stable sealed-presentation fixture."
            )
        }
        func report(
            _ controller: RunWindowController,
            cancelled: Bool,
            results: [RepositoryResult]
        ) -> RunReport {
            RunReport(
                run: controller.expectedRunID,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:01.000Z",
                durationMilliseconds: 1_000,
                cancelled: cancelled,
                results: results,
                repositoryModel: "v2"
            )
        }
        func fixture(
            candidates: [RepositoryCandidate]
        ) throws -> (
            RunWindowController,
            WorkerSession,
            WorkerSessionBinding,
            Int32
        ) {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else {
                throw WorkerClientError.pipe("sealed presentation")
            }
            let generation = RunIdentity.make()
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: generation
            )
            let session = WorkerSession(
                processID: getpid(),
                controlWrite: descriptors[1],
                identity: identity
            )
            let controller = RunWindowController(candidates: candidates)
            let binding = WorkerSessionBinding(
                runID: controller.expectedRunID,
                workerGeneration: generation
            )
            guard controller.installSession(session, binding: binding) else {
                Darwin.close(descriptors[0])
                throw WorkerClientError.sessionAssignment
            }
            controller.ownershipHandshakeVerified = true
            return (controller, session, binding, descriptors[0])
        }
        func accept(
            _ controller: RunWindowController,
            binding: WorkerSessionBinding,
            _ event: RunEvent
        ) {
            controller.accept(.event(event), binding: binding)
        }
        func seedReport(
            _ controller: RunWindowController,
            binding: WorkerSessionBinding,
            report: RunReport
        ) {
            var sequence = 1
            accept(controller, binding: binding, RunEvent(
                run: controller.expectedRunID,
                sequence: sequence,
                type: .runStarted
            ))
            if report.cancelled {
                controller.cancellationRequested = true
                _ = controller.presentationReducer.requestStoppingOverlay()
            }
            for row in report.results {
                sequence += 1
                accept(controller, binding: binding, RunEvent(
                    run: controller.expectedRunID,
                    sequence: sequence,
                    type: .repositoryResult,
                    repositoryID: row.repository.path,
                    phase: .complete,
                    result: row
                ))
            }
            sequence += 1
            accept(controller, binding: binding, RunEvent(
                run: controller.expectedRunID,
                sequence: sequence,
                type: .runFinished,
                message: report.summary
            ))
            controller.accept(.completion(report), binding: binding)
        }
        func settle(
            _ controller: RunWindowController,
            session: WorkerSession,
            binding: WorkerSessionBinding,
            evidence: WorkerPostReapEvidence,
            status: Int32 = 0
        ) {
            session.markExited(status, childDrainVerified: evidence.childDrainVerified)
            controller.handleWorkerExit(
                status: status,
                evidence: evidence,
                stateLocation: nil,
                binding: binding
            )
        }
        func waitForTerminal(_ controller: RunWindowController) -> Bool {
            let deadline = MonotonicDeadline(seconds: 2)
            while !deadline.hasExpired {
                if case .terminal = controller.stopLifecycle {
                    return true
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            return false
        }
        let safeEvidence = WorkerPostReapEvidence(
            workerReaped: true,
            ownershipProtocol: .complete,
            recordedChildDrain: .verified,
            runAuthority: .released
        )
        let cases: [(String, [ResultCode], Bool)] = [
            ("cancelled", [.cancelledDuringFetch], true),
            ("successful", [.updated], false),
            ("mixed", [.updated, .skippedDirty, .failedFetch], false),
            ("failed", [.failedFetch], false),
        ]
        var priorBinding: WorkerSessionBinding?

        for (label, codes, cancelled) in cases {
            do {
                let rows = candidates(label, count: codes.count)
                let (
                    controller,
                    session,
                    binding,
                    readDescriptor
                ) = try fixture(candidates: rows)
                defer { Darwin.close(readDescriptor) }
                let results = zip(rows, codes).map {
                    result($0.0, code: $0.1)
                }
                let finalReport = report(
                    controller,
                    cancelled: cancelled,
                    results: results
                )
                seedReport(
                    controller,
                    binding: binding,
                    report: finalReport
                )
                if priorBinding == nil {
                    priorBinding = binding
                }
                let reducer = controller.presentationReducer
                let updates = controller.testingRowUpdateCounts
                let headline = controller.headline.stringValue
                let metadata = controller.runMetadataLabel.stringValue
                let detail = controller.globalDetailLabel.stringValue
                let cancelHidden = controller.cancelButton.isHidden
                let closeHidden = controller.closeButton.isHidden
                let closeEnabled = controller.closeButton.isEnabled
                let sequence = reducer.lastEventSequence
                let conflictingResults = results.enumerated().map {
                    $0.offset == 0
                        ? result(
                            $0.element.repository,
                            code: $0.element.code == .updated
                                ? .alreadyCurrent
                                : .updated
                        )
                        : $0.element
                }
                let conflictingReport = report(
                    controller,
                    cancelled: false,
                    results: conflictingResults
                )
                let lateMessages: [WorkerWireMessage] = [
                    .event(RunEvent(
                        run: controller.expectedRunID,
                        sequence: sequence,
                        type: .runFinished,
                        message: finalReport.summary
                    )),
                    .event(RunEvent(
                        run: controller.expectedRunID,
                        sequence: sequence + 1,
                        type: .repositoryPhase,
                        repositoryID: rows[0].path,
                        phase: .checking
                    )),
                    .event(RunEvent(
                        run: controller.expectedRunID,
                        sequence: 1,
                        type: .runStarted
                    )),
                    .event(RunEvent(
                        run: controller.expectedRunID,
                        sequence: sequence + 2,
                        type: .repositoryResult,
                        repositoryID: rows[0].path,
                        phase: .complete,
                        result: conflictingResults[0]
                    )),
                    .event(RunEvent(
                        run: RunIdentity.make(),
                        sequence: sequence + 3,
                        type: .diagnostic,
                        message: "late cross-run residue"
                    )),
                    .completion(finalReport),
                    .completion(conflictingReport),
                    .failure(GitSafetyError.unsafeRepository(
                        "late failure residue"
                    )),
                    .ownership(
                        session.identity,
                        runID: controller.expectedRunID
                    ),
                    .childReleased(),
                ]
                for _ in 0..<3 {
                    for message in lateMessages {
                        controller.accept(message, binding: binding)
                    }
                }
                guard controller.report == finalReport,
                      controller.isFinished,
                      controller.gateSnapshot.reportSettled,
                      !controller.cancellationRequested,
                      controller.presentationSeal == PresentationSeal(
                          runID: controller.expectedRunID,
                          workerGeneration: binding.workerGeneration
                      ),
                      controller.presentationReducer == reducer,
                      controller.testingRowUpdateCounts == updates,
                      controller.headline.stringValue == headline,
                      controller.runMetadataLabel.stringValue == metadata,
                      controller.globalDetailLabel.stringValue == detail,
                      controller.cancelButton.isHidden == cancelHidden,
                      controller.closeButton.isHidden == closeHidden,
                      controller.closeButton.isEnabled == closeEnabled,
                      controller.protocolFailureDetail == nil,
                      controller.stopLifecycle == .idle,
                      controller.testingStopTransactionLaunchCount == 0,
                      controller.lateWireResidueCount == 1,
                      controller.gateDecision(for: .startNewRun) != .allow,
                      controller.gateDecision(for: .closeRun) != .allow,
                      controller.gateDecision(for: .quit)
                        == .stopThenReevaluate,
                      controller.gateDecision(for: .takeoverRequest)
                        == .stopThenReevaluate else {
                    return fail("\(label) late residue")
                }

                if label == "cancelled" {
                    let executor = BlockingStopExecutor()
                    controller.testingStopExecutor = { _ in
                        executor.execute()
                    }
                    var quitReady = 0
                    controller.onQuitReady = { quitReady += 1 }
                    guard controller.requestQuitAfterConfirmation() == .stopping,
                          executor.started.wait(timeout: .now() + 1) == .success,
                          controller.requestQuitAfterConfirmation() == .stopping,
                          controller.requestTakeover(afterDrain: { true })
                            == .blockedByQuit,
                          controller.report == finalReport,
                          controller.presentationReducer == reducer,
                          controller.testingRowUpdateCounts == updates,
                          controller.headline.stringValue == headline,
                          controller.testingStopTransactionLaunchCount == 1,
                          executor.invocationCount == 1,
                          controller.sealedStopNoticeVisible else {
                        executor.release.signal()
                        return fail("delayed worker stop")
                    }
                    executor.release.signal()
                    guard waitForTerminal(controller) else {
                        return fail("delayed worker stop completion")
                    }
                    settle(
                        controller,
                        session: session,
                        binding: binding,
                        evidence: safeEvidence
                    )
                    guard controller.report == finalReport,
                          controller.presentationReducer == reducer,
                          controller.testingRowUpdateCounts == updates,
                          controller.headline.stringValue == headline,
                          controller.testWorkerDrained,
                          controller.testingStopTransactionLaunchCount == 1,
                          executor.invocationCount == 1,
                          quitReady == 1 else {
                        return fail("delayed worker settlement")
                    }
                } else if label == "failed" {
                    settle(
                        controller,
                        session: session,
                        binding: binding,
                        evidence: WorkerPostReapEvidence(
                            workerReaped: true,
                            ownershipProtocol: .incomplete,
                            recordedChildDrain: .unverified,
                            runAuthority: .released
                        ),
                        status: 9
                    )
                    guard controller.report == finalReport,
                          controller.presentationReducer == reducer,
                          controller.testingRowUpdateCounts == updates,
                          controller.headline.stringValue == headline,
                          controller.postRunNotice?.blocksNewRun == true else {
                        return fail("failed worker exit")
                    }
                } else {
                    settle(
                        controller,
                        session: session,
                        binding: binding,
                        evidence: safeEvidence
                    )
                    guard controller.report == finalReport,
                          controller.presentationReducer == reducer,
                          controller.testingRowUpdateCounts == updates,
                          controller.headline.stringValue == headline,
                          controller.testWorkerDrained else {
                        return fail("\(label) worker exit")
                    }
                }
            } catch {
                return fail("\(label) fixture: \(error)")
            }
        }

        do {
            let newRows = candidates("new-generation", count: 1)
            let (
                controller,
                session,
                binding,
                readDescriptor
            ) = try fixture(candidates: newRows)
            defer { Darwin.close(readDescriptor) }
            let before = controller.presentationReducer
            guard let priorBinding else {
                return fail("missing prior generation")
            }
            accept(controller, binding: priorBinding, RunEvent(
                run: priorBinding.runID,
                sequence: 1,
                type: .runStarted
            ))
            guard controller.presentationSeal == nil,
                  controller.presentationReducer == before,
                  controller.lateWireResidueCount == 0,
                  controller.protocolFailureDetail == nil else {
                return fail("stale prior generation")
            }
            settle(
                controller,
                session: session,
                binding: binding,
                evidence: safeEvidence
            )
        } catch {
            return fail("new generation fixture: \(error)")
        }
        return true
    }

    fileprivate static func testingStoppingOverlayControllerRaces(
        root: String
    ) -> Bool {
        final class BlockingStopExecutor: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)

            func execute() -> WorkerStopOutcome {
                lock.lock()
                count += 1
                lock.unlock()
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return .alreadyExited(0)
            }

            var invocationCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        func fail(_ stage: String) -> Bool {
            fputs("M5 stopping overlay failure: \(stage)\n", stderr)
            return false
        }
        let candidate = RepositoryCandidate(
            id: "fixture-owner/stopping-overlay",
            displayName: "Stopping Overlay",
            path: "\(root)/stopping-overlay",
            rawOrigin: "https://github.com/fixture-owner/stopping-overlay.git"
        )
        func makeResult(_ code: ResultCode) -> RepositoryResult {
            RepositoryResult(
                repository: candidate,
                code: code,
                fetched: true,
                mainUpdated: code == .updatedBeforeCancellation,
                beforeCommit: "1111111111111111111111111111111111111111",
                targetCommit: "2222222222222222222222222222222222222222",
                afterCommit: code == .updatedBeforeCancellation
                    ? "2222222222222222222222222222222222222222"
                    : "1111111111111111111111111111111111111111",
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.125Z",
                durationMilliseconds: 125,
                explanation: "Stable stopping-overlay fixture."
            )
        }
        func makeReport(
            _ controller: RunWindowController,
            result: RepositoryResult
        ) -> RunReport {
            RunReport(
                run: controller.expectedRunID,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:01.000Z",
                durationMilliseconds: 1_000,
                cancelled: true,
                results: [result],
                repositoryModel: "v2"
            )
        }
        func makeController() throws -> (
            RunWindowController,
            WorkerSession,
            WorkerSessionBinding,
            BlockingStopExecutor,
            Int32
        ) {
            var pipeDescriptors: [Int32] = [-1, -1]
            guard pipe(&pipeDescriptors) == 0 else {
                throw WorkerClientError.pipe("stopping overlay")
            }
            let generation = RunIdentity.make()
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: generation
            )
            let session = WorkerSession(
                processID: getpid(),
                controlWrite: pipeDescriptors[1],
                identity: identity
            )
            let controller = RunWindowController(candidates: [candidate])
            let binding = WorkerSessionBinding(
                runID: controller.expectedRunID,
                workerGeneration: generation
            )
            guard controller.installSession(session, binding: binding) else {
                Darwin.close(pipeDescriptors[0])
                throw WorkerClientError.sessionAssignment
            }
            controller.ownershipHandshakeVerified = true
            let executor = BlockingStopExecutor()
            controller.testingStopExecutor = { _ in executor.execute() }
            return (
                controller,
                session,
                binding,
                executor,
                pipeDescriptors[0]
            )
        }
        func send(
            _ controller: RunWindowController,
            binding: WorkerSessionBinding,
            sequence: Int,
            type: RunEventType,
            phase: RepositoryPhase? = nil,
            result: RepositoryResult? = nil,
            message: String? = nil
        ) {
            controller.accept(.event(RunEvent(
                run: controller.expectedRunID,
                sequence: sequence,
                type: type,
                repositoryID: phase == nil && result == nil
                    ? nil
                    : candidate.path,
                phase: phase,
                result: result,
                message: message
            )), binding: binding)
        }
        func settle(
            _ controller: RunWindowController,
            session: WorkerSession,
            binding: WorkerSessionBinding
        ) {
            session.markExited(0, childDrainVerified: true)
            controller.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .verified,
                    runAuthority: .released
                ),
                stateLocation: nil,
                binding: binding
            )
        }
        func waitForTerminal(_ controller: RunWindowController) -> Bool {
            let deadline = MonotonicDeadline(seconds: 2)
            while !deadline.hasExpired {
                if case .terminal = controller.stopLifecycle {
                    return true
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            return false
        }

        do {
            let (
                controller,
                session,
                binding,
                executor,
                readDescriptor
            ) = try makeController()
            defer { Darwin.close(readDescriptor) }
            send(
                controller,
                binding: binding,
                sequence: 1,
                type: .runStarted
            )
            send(
                controller,
                binding: binding,
                sequence: 2,
                type: .repositoryPhase,
                phase: .checking
            )
            controller.requestCancellation()
            guard executor.started.wait(timeout: .now() + 1) == .success,
                  controller.presentationReducer.stoppingOverlayRequested,
                  controller.presentationReducer.rows[0].status == .stopping,
                  controller.presentationReducer.rows[0].authoritativeStatus
                    == .checking,
                  controller.requestTakeover(afterDrain: { true })
                    == .accepted,
                  controller.requestQuitAfterConfirmation() == .stopping,
                  controller.requestTakeover(afterDrain: { true })
                    == .blockedByQuit else {
                executor.release.signal()
                return fail("operator stop precedence")
            }
            controller.requestCancellation()
            send(
                controller,
                binding: binding,
                sequence: 3,
                type: .repositoryPhase,
                phase: .checking
            )
            send(
                controller,
                binding: binding,
                sequence: 4,
                type: .repositoryPhase,
                phase: .fetching
            )
            guard controller.presentationReducer.rows[0].status == .stopping,
                  controller.presentationReducer.rows[0].authoritativeStatus
                    == .fetching else {
                executor.release.signal()
                return fail("fetch race")
            }
            send(
                controller,
                binding: binding,
                sequence: 5,
                type: .repositoryPhase,
                phase: .updating
            )
            let result = makeResult(.updatedBeforeCancellation)
            send(
                controller,
                binding: binding,
                sequence: 6,
                type: .repositoryResult,
                phase: .complete,
                result: result
            )
            send(
                controller,
                binding: binding,
                sequence: 7,
                type: .runFinished,
                message: "Run cancelled normally"
            )
            let report = makeReport(controller, result: result)
            controller.accept(.completion(report), binding: binding)
            let reducerAfterReport = controller.presentationReducer
            let updatesAfterReport = controller.testingRowUpdateCounts
            let staleBinding = WorkerSessionBinding(
                runID: controller.expectedRunID,
                workerGeneration: RunIdentity.make()
            )
            send(
                controller,
                binding: staleBinding,
                sequence: 8,
                type: .repositoryPhase,
                phase: .checking
            )
            guard controller.protocolFailureDetail == nil,
                  controller.report == report,
                  controller.isFinished,
                  controller.presentationReducer == reducerAfterReport,
                  controller.testingRowUpdateCounts == updatesAfterReport,
                  controller.presentationReducer.rows[0].status == .updated,
                  controller.presentationReducer.rows[0].authoritativeStatus
                    == .updated,
                  !controller.presentationReducer.stoppingOverlayRequested,
                  !controller.presentationReducer.rows[0]
                    .stoppingOverlayRequested,
                  controller.testingStopTransactionLaunchCount == 1,
                  executor.invocationCount == 1 else {
                executor.release.signal()
                return fail("normal cancelled completion")
            }
            executor.release.signal()
            guard waitForTerminal(controller) else {
                return fail("normal stop completion")
            }
            settle(controller, session: session, binding: binding)
            guard controller.testWorkerDrained,
                  controller.report == report,
                  controller.testingStopTransactionLaunchCount == 1,
                  executor.invocationCount == 1 else {
                return fail("normal stop settlement")
            }
        } catch {
            return fail("normal fixture: \(error)")
        }

        for postTerminal in [false, true] {
            do {
                let (
                    controller,
                    session,
                    binding,
                    executor,
                    readDescriptor
                ) = try makeController()
                defer { Darwin.close(readDescriptor) }
                send(
                    controller,
                    binding: binding,
                    sequence: 1,
                    type: .runStarted
                )
                send(
                    controller,
                    binding: binding,
                    sequence: 2,
                    type: .repositoryPhase,
                    phase: .checking
                )
                controller.requestCancellation()
                guard executor.started.wait(timeout: .now() + 1) == .success else {
                    executor.release.signal()
                    return fail("invalid stop start")
                }
                let snapshot: RunPresentationReducer
                if postTerminal {
                    let result = makeResult(.cancelledNoUpdate)
                    send(
                        controller,
                        binding: binding,
                        sequence: 3,
                        type: .repositoryResult,
                        phase: .complete,
                        result: result
                    )
                    send(
                        controller,
                        binding: binding,
                        sequence: 4,
                        type: .runFinished,
                        message: "Run cancelled normally"
                    )
                    snapshot = controller.presentationReducer
                    send(
                        controller,
                        binding: binding,
                        sequence: 5,
                        type: .repositoryPhase,
                        phase: .fetching
                    )
                } else {
                    send(
                        controller,
                        binding: binding,
                        sequence: 3,
                        type: .repositoryPhase,
                        phase: .fetching
                    )
                    snapshot = controller.presentationReducer
                    send(
                        controller,
                        binding: binding,
                        sequence: 4,
                        type: .repositoryPhase,
                        phase: .checking
                    )
                }
                let protocolDetail = controller.protocolFailureDetail
                if postTerminal {
                    send(
                        controller,
                        binding: binding,
                        sequence: 5,
                        type: .repositoryPhase,
                        phase: .fetching
                    )
                } else {
                    send(
                        controller,
                        binding: binding,
                        sequence: 4,
                        type: .repositoryPhase,
                        phase: .checking
                    )
                }
                guard protocolDetail != nil,
                      controller.protocolFailureDetail == protocolDetail,
                      controller.presentationReducer == snapshot,
                      controller.testingStopTransactionLaunchCount == 1,
                      executor.invocationCount == 1,
                      case let .stopping(transaction)
                        = controller.stopLifecycle,
                      transaction.reason == .ownershipFailure else {
                    executor.release.signal()
                    return fail(
                        postTerminal
                            ? "post-terminal violation"
                            : "backwards violation"
                    )
                }
                executor.release.signal()
                guard waitForTerminal(controller) else {
                    return fail("invalid stop completion")
                }
                settle(controller, session: session, binding: binding)
                guard controller.testWorkerDrained,
                      controller.testingStopTransactionLaunchCount == 1,
                      executor.invocationCount == 1 else {
                    return fail("invalid stop settlement")
                }
            } catch {
                return fail("invalid fixture: \(error)")
            }
        }
        return true
    }

    fileprivate static func testingReportTransactionsAreAtomic(
        root: String
    ) -> Bool {
        func fail(_ stage: String) -> Bool {
            fputs("M5 report transaction failure: \(stage)\n", stderr)
            return false
        }
        final class Counter {
            var value = 0
        }
        final class BlockingStopExecutor: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)

            func execute() -> WorkerStopOutcome {
                lock.lock()
                count += 1
                lock.unlock()
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return .unverified
            }

            var invocationCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        let candidates = (0..<3).map { index in
            RepositoryCandidate(
                id: "fixture-owner/report-\(index)",
                displayName: "Report \(index)",
                path: "\(root)/report-\(index)",
                rawOrigin: "https://github.com/fixture-owner/report-\(index).git"
            )
        }
        func result(
            _ candidate: RepositoryCandidate,
            code: ResultCode = .alreadyCurrent
        ) -> RepositoryResult {
            let updated = code == .updated
            return RepositoryResult(
                repository: candidate,
                code: code,
                fetched: true,
                mainUpdated: updated,
                beforeCommit: "1111111111111111111111111111111111111111",
                targetCommit: "2222222222222222222222222222222222222222",
                afterCommit: updated
                    ? "2222222222222222222222222222222222222222"
                    : "1111111111111111111111111111111111111111",
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.125Z",
                durationMilliseconds: 125,
                explanation: "Stable transactional report fixture."
            )
        }
        func report(
            for controller: RunWindowController,
            results: [RepositoryResult]
        ) -> RunReport {
            RunReport(
                run: controller.expectedRunID,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:01.000Z",
                durationMilliseconds: 1_000,
                cancelled: false,
                results: results
            )
        }
        func seedTerminalRun(
            _ controller: RunWindowController,
            results: [RepositoryResult]
        ) {
            controller.testingAcceptEvent(RunEvent(
                run: controller.expectedRunID,
                sequence: 1,
                type: .runStarted
            ))
            for (index, result) in results.enumerated() {
                controller.testingAcceptEvent(RunEvent(
                    run: controller.expectedRunID,
                    sequence: index + 2,
                    type: .repositoryResult,
                    repositoryID: result.repository.path,
                    phase: .complete,
                    result: result
                ))
            }
            controller.testingAcceptEvent(RunEvent(
                run: controller.expectedRunID,
                sequence: results.count + 2,
                type: .runFinished,
                message: "Terminal event received"
            ))
        }
        func waitForStop(
            _ controller: RunWindowController
        ) -> Bool {
            let deadline = MonotonicDeadline(seconds: 2)
            while !deadline.hasExpired {
                if case .terminal = controller.stopLifecycle {
                    return true
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            return false
        }

        let validResults = candidates.map { result($0) }

        let historical = RunWindowController(candidates: candidates)
        historical.testingAcceptEvent(RunEvent(
            run: historical.expectedRunID,
            sequence: 1,
            type: .runStarted
        ))
        historical.testingAcceptEvent(RunEvent(
            run: historical.expectedRunID,
            sequence: 2,
            type: .repositoryPhase,
            repositoryID: candidates[0].path,
            phase: .checking
        ))
        let historicalReducer = historical.presentationReducer
        let historicalUpdates = historical.testingRowUpdateCounts
        let historicalHeadline = historical.headline.stringValue
        let malformedHistorical = report(
            for: historical,
            results: [
                validResults[0],
                result(candidates[2]),
                validResults[2],
            ]
        )
        historical.present(report: malformedHistorical)
        guard historical.report == nil,
              !historical.isFinished,
              !historical.gateSnapshot.reportSettled,
              historical.presentationReducer == historicalReducer,
              historical.testingRowUpdateCounts == historicalUpdates,
              historicalHeadline != "Needs Attention",
              historical.headline.stringValue == "Needs Attention",
              historical.failureRequiresRecoveryReview,
              historical.testingStopTransactionLaunchCount == 0,
              historical.stopLifecycle == .idle,
              historical.cancelButton.isHidden,
              !historical.cancelButton.isEnabled,
              historical.closeButton.isHidden,
              !historical.closeButton.isEnabled,
              historical.gateDecision(for: .startNewRun) != .allow,
              historical.gateDecision(for: .closeRun) != .allow,
              historical.gateDecision(for: .quit) != .allow,
              historical.gateDecision(for: .takeoverPresentation) != .allow else {
            return fail("historical rejection")
        }

        let callbacks = Counter()
        historical.onClose = { callbacks.value += 1 }
        historical.onWorkerExit = { _ in callbacks.value += 1 }
        historical.onWorkerReaped = { _ in callbacks.value += 1 }
        historical.onQuitReady = { callbacks.value += 1 }
        historical.onQuitBlocked = { callbacks.value += 1 }
        let validHistorical = report(
            for: historical,
            results: validResults
        )
        historical.present(report: validHistorical)
        let committedReducer = historical.presentationReducer
        let committedUpdates = historical.testingRowUpdateCounts
        guard historical.report == validHistorical,
              historical.isFinished,
              historical.gateSnapshot.reportSettled,
              !historical.failureRequiresRecoveryReview,
              historical.presentationReducer.rows.allSatisfy(
                  \.status.isTerminal
              ),
              zip(historicalUpdates, committedUpdates).allSatisfy({
                  $0.1 == $0.0 + 1
              }),
              historical.headline.stringValue == validHistorical.summary,
              historical.cancelButton.isHidden,
              historical.closeButton.isEnabled,
              !historical.closeButton.isHidden,
              callbacks.value == 0 else {
            return fail("historical commit")
        }
        historical.present(report: validHistorical)
        guard historical.presentationReducer == committedReducer,
              historical.testingRowUpdateCounts == committedUpdates,
              callbacks.value == 0 else {
            return fail("historical duplicate")
        }

        let prior = RunWindowController(candidates: candidates)
        let priorReport = report(for: prior, results: validResults)
        prior.present(report: priorReport)
        let priorReducer = prior.presentationReducer
        let priorUpdates = prior.testingRowUpdateCounts
        let priorHeadline = prior.headline.stringValue
        let conflicting = report(
            for: prior,
            results: [
                result(candidates[0], code: .updated),
                validResults[1],
                validResults[2],
            ]
        )
        prior.present(report: conflicting)
        guard prior.report == priorReport,
              prior.isFinished,
              prior.presentationReducer == priorReducer,
              prior.testingRowUpdateCounts == priorUpdates,
              prior.headline.stringValue == priorHeadline,
              !prior.postRunNoticeLabel.isHidden,
              prior.postRunNoticeLabel.stringValue.contains(
                  "conflicting final evidence"
              ),
              prior.gateDecision(for: .startNewRun) != .allow,
              prior.gateDecision(for: .closeRun) != .allow,
              prior.gateDecision(for: .takeoverPresentation) != .allow else {
            return fail("prior evidence conflict")
        }

        var controlPipe: [Int32] = [-1, -1]
        guard pipe(&controlPipe) == 0 else {
            return fail("live pipe")
        }
        defer { Darwin.close(controlPipe[0]) }
        do {
            let generation = RunIdentity.make()
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: generation
            )
            let worker = WorkerSession(
                processID: getpid(),
                controlWrite: controlPipe[1],
                identity: identity
            )
            let live = RunWindowController(candidates: candidates)
            let binding = WorkerSessionBinding(
                runID: live.expectedRunID,
                workerGeneration: generation
            )
            guard live.installSession(worker, binding: binding) else {
                return fail("live session install")
            }
            let executor = BlockingStopExecutor()
            live.testingStopExecutor = { _ in executor.execute() }
            seedTerminalRun(live, results: validResults)
            let liveReducer = live.presentationReducer
            let liveUpdates = live.testingRowUpdateCounts
            let liveHeadline = live.headline.stringValue
            let malformedLive = report(
                for: live,
                results: [
                    validResults[0],
                    result(candidates[2]),
                    validResults[2],
                ]
            )
            live.accept(.completion(malformedLive), binding: binding)
            guard executor.started.wait(timeout: .now() + 1) == .success else {
                executor.release.signal()
                return fail("live stop start")
            }
            live.accept(.completion(malformedLive), binding: binding)
            guard live.report == nil,
                  !live.isFinished,
                  !live.gateSnapshot.reportSettled,
                  live.presentationReducer.rows == liveReducer.rows,
                  live.presentationReducer.lastEventSequence
                    == liveReducer.lastEventSequence,
                  live.presentationReducer.stoppingOverlayRequested,
                  live.testingRowUpdateCounts == liveUpdates,
                  liveHeadline != live.headline.stringValue,
                  live.headline.stringValue.contains("protocol error"),
                  live.testingStopTransactionLaunchCount == 1,
                  executor.invocationCount == 1,
                  live.gateDecision(for: .startNewRun) != .allow,
                  live.gateDecision(for: .closeRun) != .allow,
                  live.gateDecision(for: .quit) != .allow,
                  live.gateDecision(for: .takeoverPresentation) != .allow else {
                executor.release.signal()
                return fail("live rejection")
            }
            executor.release.signal()
            guard waitForStop(live) else {
                return fail("live stop completion")
            }
            worker.markExited(0, childDrainVerified: true)
            live.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .verified,
                    runAuthority: .released
                ),
                stateLocation: nil,
                binding: binding
            )
            guard live.report == nil,
                  !live.isFinished,
                  !live.gateSnapshot.reportSettled,
                  live.failureRequiresRecoveryReview,
                  live.presentationReducer.rows == liveReducer.rows,
                  live.presentationReducer.lastEventSequence
                    == liveReducer.lastEventSequence,
                  live.presentationReducer.stoppingOverlayRequested,
                  live.testingRowUpdateCounts == liveUpdates,
                  live.testingStopTransactionLaunchCount == 1,
                  executor.invocationCount == 1,
                  live.testWorkerDrained else {
                return fail("live settled rejection")
            }
        } catch {
            return fail("live fixture error: \(error)")
        }
        return true
    }

    fileprivate static func testingControllerStopRaces(
        candidate: RepositoryCandidate
    ) -> Bool {
        final class StopExecutor: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            let outcome: WorkerStopOutcome
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let waitsForRelease: Bool

            init(outcome: WorkerStopOutcome, waitsForRelease: Bool) {
                self.outcome = outcome
                self.waitsForRelease = waitsForRelease
            }

            func execute() -> WorkerStopOutcome {
                lock.lock()
                count += 1
                lock.unlock()
                started.signal()
                if waitsForRelease {
                    _ = release.wait(timeout: .now() + 5)
                }
                return outcome
            }

            var invocationCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        func makeController(
            outcome: WorkerStopOutcome,
            waitsForRelease: Bool
        ) throws -> (
            RunWindowController,
            WorkerSession,
            WorkerSessionBinding,
            StopExecutor,
            Int32
        ) {
            var controlPipe: [Int32] = [-1, -1]
            guard pipe(&controlPipe) == 0 else {
                throw WorkerClientError.pipe("single-flight controller test")
            }
            let generation = RunIdentity.make()
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: generation
            )
            let worker = WorkerSession(
                processID: getpid(),
                controlWrite: controlPipe[1],
                identity: identity
            )
            let controller = RunWindowController(candidates: [candidate])
            let binding = WorkerSessionBinding(
                runID: controller.expectedRunID,
                workerGeneration: generation
            )
            guard controller.installSession(worker, binding: binding) else {
                Darwin.close(controlPipe[0])
                throw WorkerClientError.sessionAssignment
            }
            let executor = StopExecutor(
                outcome: outcome,
                waitsForRelease: waitsForRelease
            )
            controller.testingStopExecutor = { _ in
                executor.execute()
            }
            return (
                controller,
                worker,
                binding,
                executor,
                controlPipe[0]
            )
        }

        func report(for controller: RunWindowController) -> RunReport {
            RunReport(
                run: controller.expectedRunID,
                startedAt: "single-flight",
                endedAt: "single-flight",
                cancelled: true,
                results: []
            )
        }

        func waitForTerminal(
            _ controller: RunWindowController,
            timeout: TimeInterval = 2
        ) -> Bool {
            let deadline = MonotonicDeadline(seconds: timeout)
            while !deadline.hasExpired {
                if case .terminal = controller.stopLifecycle {
                    return true
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            }
            return false
        }

        do {
            let (
                controller,
                _,
                binding,
                executor,
                controlRead
            ) = try makeController(
                outcome: .alreadyExited(0),
                waitsForRelease: true
            )
            defer { Darwin.close(controlRead) }
            var takeoverCallbacks = 0
            var quitCallbacks = 0
            controller.onQuitReady = { quitCallbacks += 1 }
            controller.requestCancellation()
            guard executor.started.wait(timeout: .now() + 1) == .success,
                  controller.requestTakeover(afterDrain: {
                      takeoverCallbacks += 1
                      return true
                  }) == .accepted,
                  controller.requestTakeover(afterDrain: {
                      takeoverCallbacks += 100
                      return true
                  }) == .accepted,
                  controller.requestQuitAfterConfirmation() == .stopping else {
                executor.release.signal()
                return false
            }
            controller.handleProtocolViolation(
                "first protocol violation",
                binding: binding
            )
            controller.handleProtocolViolation(
                "second protocol violation",
                binding: binding
            )
            guard case let .stopping(transaction) = controller.stopLifecycle,
                  transaction.intent == .quit,
                  transaction.reason == .ownershipFailure,
                  controller.protocolFailureDetail
                    == "first protocol violation",
                  controller.testingStopTransactionLaunchCount == 1,
                  executor.invocationCount == 1 else {
                executor.release.signal()
                return false
            }
            controller.present(report: report(for: controller))
            controller.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .verified,
                    runAuthority: .released
                ),
                stateLocation: nil,
                binding: binding
            )
            executor.release.signal()
            guard waitForTerminal(controller),
                  case let .terminal(completed, result)
                    = controller.stopLifecycle,
                  completed.intent == .quit,
                  completed.reason == .ownershipFailure,
                  result.isVerified,
                  takeoverCallbacks == 0,
                  quitCallbacks == 1,
                  executor.invocationCount == 1 else {
                return false
            }
            controller.completeStop(
                outcome: .stillActive,
                token: completed.token,
                binding: completed.binding
            )
            guard quitCallbacks == 1,
                  executor.invocationCount == 1 else {
                return false
            }

            let laterBinding = WorkerSessionBinding(
                runID: controller.expectedRunID,
                workerGeneration: RunIdentity.make()
            )
            let laterTransaction = StopTransaction(
                token: RunIdentity.make(),
                binding: laterBinding,
                intent: .ordinary,
                reason: .operatorRequested,
                workerExitStatus: nil
            )
            controller.installedSessionBinding = laterBinding
            controller.stopConsumedGenerations.insert(
                laterBinding.workerGeneration
            )
            controller.stopLifecycle = .stopping(laterTransaction)
            controller.completeStop(
                outcome: .unverified,
                token: completed.token,
                binding: completed.binding
            )
            guard controller.stopLifecycle == .stopping(laterTransaction) else {
                return false
            }
        } catch {
            return false
        }

        for blockedOutcome in [
            WorkerStopOutcome.unverified,
            WorkerStopOutcome.stillActive,
        ] {
            do {
                let (
                    controller,
                    worker,
                    binding,
                    executor,
                    controlRead
                ) = try makeController(
                    outcome: blockedOutcome,
                    waitsForRelease: false
                )
                defer { Darwin.close(controlRead) }
                controller.requestCancellation()
                guard executor.started.wait(timeout: .now() + 1) == .success,
                      waitForTerminal(controller),
                      case let .terminal(transaction, result)
                        = controller.stopLifecycle,
                      !result.isVerified,
                      controller.testNeedsAttention,
                      controller.postRunNoticeLabel.stringValue.contains(
                          "will not signal that session again"
                      ) || controller.testRowText.contains(
                          "will not signal that session again"
                      ),
                      controller.testingStopTransactionLaunchCount == 1,
                      executor.invocationCount == 1,
                      controller.requestTakeover(afterDrain: { true })
                        == .blocked,
                      controller.requestTakeover(afterDrain: { true })
                        == .blocked,
                      controller.requestQuitAfterConfirmation() == .blocked,
                      !controller.prepareForNewRun(),
                      controller.gateDecision(for: .closeRun)
                        != .allow else {
                    return false
                }
                controller.handleProtocolViolation(
                    "late duplicate protocol violation",
                    binding: binding
                )
                let terminal = controller.stopLifecycle
                controller.stopLifecycle = .idle
                guard controller.beginStop(
                    intent: .quit,
                    reason: .ownershipFailure,
                    session: worker
                ) == .blocked,
                controller.testingStopTransactionLaunchCount == 1,
                executor.invocationCount == 1 else {
                    return false
                }
                controller.stopLifecycle = terminal
                controller.completeStop(
                    outcome: .alreadyExited(0),
                    token: transaction.token,
                    binding: transaction.binding
                )
                guard controller.stopLifecycle == terminal,
                      executor.invocationCount == 1 else {
                    return false
                }
            } catch {
                return false
            }
        }
        return true
    }

    fileprivate static func testingWorkerSessionStopSingleFlight(root: String) -> Bool {
        final class OutcomeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var outcomes: [WorkerStopOutcome] = []

            func append(_ outcome: WorkerStopOutcome) {
                lock.lock()
                outcomes.append(outcome)
                lock.unlock()
            }

            var snapshot: [WorkerStopOutcome] {
                lock.lock()
                defer { lock.unlock() }
                return outcomes
            }
        }

        do {
            let fixture = try NativeFixtureProcess(root: root, role: "worker-stop", behavior: .ignoreTerm)
            defer { fixture.close() }
            let processID = fixture.processID
            let identity = fixture.identity
            var controlPipe: [Int32] = [-1, -1]
            guard pipe(&controlPipe) == 0 else { return false }
            defer { Darwin.close(controlPipe[0]) }
            let session = WorkerSession(
                controlWrite: controlPipe[1],
                testingFixture: fixture
            )
            let reaped = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                guard let status = fixture.wait(seconds: 32) else { return }
                let exitCode: Int32 = (status & 0x7F) == 0
                    ? (status >> 8) & 0xFF
                    : 128 + (status & 0x7F)
                session.markExited(exitCode, childDrainVerified: true)
                reaped.signal()
            }
            let outcomes = OutcomeBox()
            let callers = DispatchGroup()
            callers.enter()
            DispatchQueue.global().async {
                outcomes.append(session.stopSafely(
                    cooperativeTimeout: 0.75,
                    termTimeout: 0.75,
                    killTimeout: 1
                ))
                callers.leave()
            }
            let leaderDeadline = MonotonicDeadline(seconds: 1)
            while session.testingStopMetrics.cancellationCount == 0,
                  !leaderDeadline.hasExpired {
                usleep(10_000)
            }
            guard session.testingStopMetrics.cancellationCount == 1 else {
                return false
            }
            for _ in 0..<8 {
                callers.enter()
                DispatchQueue.global().async {
                    outcomes.append(session.stopSafely(
                        cooperativeTimeout: 0,
                        termTimeout: 0,
                        killTimeout: 0
                    ))
                    callers.leave()
                }
            }
            guard callers.wait(timeout: .now() + 5) == .success,
                  reaped.wait(timeout: .now() + 1) == .success else {
                return false
            }
            let firstOutcomes = outcomes.snapshot
            guard firstOutcomes.count == 9,
                  firstOutcomes.dropFirst().allSatisfy({
                      $0 == firstOutcomes[0]
                  }),
                  firstOutcomes.allSatisfy({
                      if case .killed = $0 { return true }
                      return false
                  }) else {
                return false
            }
            let repeated = session.stopSafely(
                cooperativeTimeout: 0,
                termTimeout: 0,
                killTimeout: 0
            )
            let metrics = session.testingStopMetrics
            guard repeated == firstOutcomes[0]
                && metrics == WorkerSession.StopMetrics(
                    executionCount: 1,
                    cancellationCount: 1,
                    termCount: 1,
                    killCount: 1
                )
                && kill(processID, 0) != 0
                && errno == ESRCH else {
                return false
            }

            var boundaryPipe: [Int32] = [-1, -1]
            guard pipe(&boundaryPipe) == 0 else { return false }
            defer { Darwin.close(boundaryPipe[0]) }
            let boundarySession = WorkerSession(
                processID: getpid(),
                controlWrite: boundaryPipe[1],
                identity: try ProcessIdentity.capture(
                    processID: getpid(),
                    generation: RunIdentity.make()
                )
            )
            guard boundarySession.testingAbandonStopAttempt(
                actionTimeout: 0.05,
                publicationGrace: 0.5
            ) else {
                return false
            }
            let boundaryOutcomes = OutcomeBox()
            let boundaryWaiters = DispatchGroup()
            for _ in 0..<8 {
                boundaryWaiters.enter()
                DispatchQueue.global().async {
                    boundaryOutcomes.append(boundarySession.stopSafely())
                    boundaryWaiters.leave()
                }
            }
            let boundaryPublisher = DispatchGroup()
            boundaryPublisher.enter()
            DispatchQueue.global().async {
                usleep(150_000)
                _ = boundarySession.testingPublishStopOutcome(
                    .alreadyExited(0)
                )
                boundaryPublisher.leave()
            }
            let boundaryOutcome = boundarySession.stopSafely()
            guard boundaryPublisher.wait(timeout: .now() + 1) == .success,
                  boundaryWaiters.wait(timeout: .now() + 1) == .success,
                  boundaryOutcome == .alreadyExited(0),
                  boundaryOutcomes.snapshot.count == 8,
                  boundaryOutcomes.snapshot.allSatisfy({
                      $0 == boundaryOutcome
                  }),
                  boundarySession.stopSafely() == .alreadyExited(0),
                  boundarySession.testingStopMetrics == WorkerSession.StopMetrics(
                      executionCount: 0,
                      cancellationCount: 0,
                      termCount: 0,
                      killCount: 0
                  ) else {
                return false
            }

            var fallbackPipe: [Int32] = [-1, -1]
            guard pipe(&fallbackPipe) == 0 else { return false }
            defer { Darwin.close(fallbackPipe[0]) }
            let fallbackSession = WorkerSession(
                processID: getpid(),
                controlWrite: fallbackPipe[1],
                identity: try ProcessIdentity.capture(
                    processID: getpid(),
                    generation: RunIdentity.make()
                )
            )
            guard fallbackSession.testingAbandonStopAttempt(
                actionTimeout: 0.05,
                publicationGrace: 0.05
            ) else {
                return false
            }
            let fallbackOutcomes = OutcomeBox()
            let fallbackCallers = DispatchGroup()
            for _ in 0..<8 {
                fallbackCallers.enter()
                DispatchQueue.global().async {
                    fallbackOutcomes.append(fallbackSession.stopSafely())
                    fallbackCallers.leave()
                }
            }
            guard fallbackCallers.wait(timeout: .now() + 2) == .success else {
                return false
            }
            let fallbackSnapshot = fallbackOutcomes.snapshot
            let repeatedTimeout = fallbackSession.stopSafely()
            let authoritativeOutcome = fallbackSession.testingPublishStopOutcome(
                .killed(9)
            )
            let immutableOutcome = fallbackSession.testingPublishStopOutcome(
                .cooperative(0)
            )
            return fallbackSnapshot.count == 8
                && fallbackSnapshot.allSatisfy { $0 == .unverified }
                && repeatedTimeout == .unverified
                && authoritativeOutcome == .killed(9)
                && immutableOutcome == .killed(9)
                && fallbackSession.stopSafely() == .killed(9)
                && fallbackSession.testingStopMetrics == WorkerSession.StopMetrics(
                    executionCount: 0,
                    cancellationCount: 0,
                    termCount: 0,
                    killCount: 0
                )
        } catch {
            return false
        }
    }

    static func testingTakeoverTransitionIsCoherent(root: String) -> Bool {
        final class Counter {
            var value = 0
        }
        func snapshot(
            report: Bool = true,
            terminal: Bool = true,
            settled: Bool = true,
            failure: Bool = false,
            review: Bool = false,
            acknowledged: Bool = true,
            needsAttention: Bool = false,
            notice: Bool = false,
            reaped: Bool = true,
            child: Bool = true,
            authority: Bool = true,
            stop: LifecycleGateStopState = .completedVerified,
            pending: Bool = false
        ) -> LifecycleGateSnapshot {
            LifecycleGateSnapshot(
                trustedReport: report,
                terminalRunMatched: terminal,
                reportSettled: settled,
                failureRecoveryRequired: failure,
                reportRecoveryRequired: review,
                recoveryAcknowledged: acknowledged,
                needsAttentionResults: needsAttention,
                postRunNoticeBlocks: notice,
                workerReaped: reaped,
                childDrainVerified: child,
                authorityReleased: authority,
                stopState: stop,
                transitionPending: pending
            )
        }
        func expectedStopMatrixDecision(
            action: LifecycleGateAction,
            state: LifecycleGateStopState
        ) -> LifecycleGateDecision {
            switch state {
            case .idle, .completedVerified:
                switch action {
                case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                     .takeoverRequest, .takeoverAdvance:
                    return .allow
                }
            case .stopping:
                switch action {
                case .quit, .takeoverRequest:
                    return .stopThenReevaluate
                case .startNewRun, .closeRun, .takeoverPresentation,
                     .takeoverAdvance:
                    return .block(.stopInProgress)
                }
            case .completedUnverified:
                switch action {
                case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                     .takeoverRequest, .takeoverAdvance:
                    return .block(.childDrain)
                }
            case .completedStillActive:
                switch action {
                case .startNewRun, .closeRun, .quit, .takeoverPresentation,
                     .takeoverRequest, .takeoverAdvance:
                    return .block(.workerActive)
                }
            }
        }
        let exhaustiveStopMatrix = LifecycleGateStopState.allCases
            .allSatisfy { stopState in
                LifecycleGateAction.allCases.allSatisfy { action in
                    LifecycleGate.decide(
                        action,
                        from: snapshot(
                            stop: stopState,
                            pending: action == .takeoverAdvance
                        )
                    ) == expectedStopMatrixDecision(
                        action: action,
                        state: stopState
                    )
                }
            }
        let evidenceGateCases: [(
            LifecycleGateAction,
            LifecycleGateSnapshot,
            LifecycleGateDecision
        )] = [
            (
                .quit,
                snapshot(child: false),
                .block(.childDrain)
            ),
            (
                .quit,
                snapshot(authority: false),
                .block(.authorityHeld)
            ),
            (
                .takeoverPresentation,
                snapshot(report: false, reaped: false, child: false, authority: false, stop: .idle),
                .stopThenReevaluate
            ),
            (
                .takeoverRequest,
                snapshot(reaped: false, child: false, authority: false, stop: .idle),
                .stopThenReevaluate
            ),
            (
                .startNewRun,
                snapshot(failure: true),
                .block(.failureRecovery)
            ),
            (
                .closeRun,
                snapshot(review: true, acknowledged: false),
                .block(.recoveryReview)
            ),
            (
                .startNewRun,
                snapshot(needsAttention: true),
                .block(.needsAttentionResults)
            ),
            (
                .startNewRun,
                snapshot(notice: true),
                .block(.postRunSafety)
            ),
            (
                .startNewRun,
                snapshot(child: false),
                .block(.childDrain)
            ),
            (
                .startNewRun,
                snapshot(authority: false),
                .block(.authorityHeld)
            ),
            (
                .takeoverPresentation,
                snapshot(pending: true),
                .block(.transitionInProgress)
            ),
            (
                .takeoverAdvance,
                snapshot(terminal: false, stop: .idle, pending: true),
                .block(.awaitingReport)
            ),
            (
                .takeoverAdvance,
                snapshot(settled: false, stop: .idle, pending: true),
                .block(.awaitingReport)
            ),
            (
                .takeoverAdvance,
                snapshot(reaped: false, stop: .idle, pending: true),
                .block(.workerActive)
            ),
            (
                .takeoverAdvance,
                snapshot(child: false, stop: .idle, pending: true),
                .block(.childDrain)
            ),
            (
                .takeoverAdvance,
                snapshot(authority: false, stop: .idle, pending: true),
                .block(.authorityHeld)
            ),
        ]
        guard exhaustiveStopMatrix,
        evidenceGateCases.allSatisfy({
            LifecycleGate.decide($0.0, from: $0.1) == $0.2
        }),
        LifecycleGate.decideRecoveryStart(from: .none) == .allow,
        LifecycleGate.decideRecoveryStart(from: .completedReport) == .allow,
        LifecycleGate.decideRecoveryStart(
            from: .interruptedReport(acknowledgementMatches: false)
        ) == .block(.recoveryReview),
        LifecycleGate.decideRecoveryStart(from: .operationStillActive)
            == .block(.authorityHeld),
        LifecycleGate.decideRecoveryStart(from: .needsAttention)
            == .block(.postRunSafety),
        ProcessOwnershipTiming.workerStopMaximum
            == ProcessOwnershipTiming.cooperativeAcknowledgement
                + ProcessOwnershipTiming.termGrace
                + ProcessOwnershipTiming.postKillReap,
        ProcessOwnershipTiming.ownedChildDrainMaximum
            == ProcessOwnershipTiming.termGrace
                + ProcessOwnershipTiming.postKillReap,
        TakeoverWatchdog.maximumDuration
            == ProcessOwnershipTiming.workerStopMaximum
                + ProcessOwnershipTiming.ownedChildDrainMaximum
                + ProcessOwnershipTiming.handoffSettlement
                + ProcessOwnershipTiming.schedulingMargin,
        !TakeoverWatchdog.hasExpired(
            startedAt: 100,
            now: 100 + TakeoverWatchdog.maximumDuration - 0.001
        ),
        TakeoverWatchdog.hasExpired(
            startedAt: 100,
            now: 100 + TakeoverWatchdog.maximumDuration
        ),
        !TakeoverWatchdog.hasExpired(
            startedAt: 10,
            now: 10.049,
            maximum: 0.05
        ),
        TakeoverWatchdog.hasExpired(
            startedAt: 10,
            now: 10.05,
            maximum: 0.05
        ) else {
            return false
        }
        let candidate = RepositoryCandidate(
            id: "fixture-owner/takeover-state",
            displayName: "Takeover State",
            path: "/private/tmp/takeover-state",
            rawOrigin: "https://github.com/fixture-owner/takeover-state.git"
        )
        func report(for controller: RunWindowController) -> RunReport {
            RunReport(
                run: controller.expectedRunID,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.000Z",
                cancelled: true,
                results: [RepositoryResult(
                    repository: candidate,
                    code: .cancelledPending,
                    fetched: false,
                    mainUpdated: false,
                    beforeCommit: nil,
                    targetCommit: nil,
                    afterCommit: nil,
                    startedAt: "2026-09-05T20:00:00.000Z",
                    endedAt: "2026-09-05T20:00:00.000Z",
                    durationMilliseconds: 0,
                    explanation: "Stable lifecycle fixture."
                )]
            )
        }
        func arm(
            _ controller: RunWindowController,
            counter: Counter
        ) {
            controller.takeoverTransition = .pending {
                counter.value += 1
                return true
            }
        }

        let stopFirst = RunWindowController(candidates: [candidate])
        let stopFirstCount = Counter()
        arm(stopFirst, counter: stopFirstCount)
        stopFirst.testingSetTerminal(
            reason: .operatorRequested,
            outcome: .killed(137),
            workerExitStatus: 137
        )
        let supersedingCount = Counter()
        stopFirst.requestTakeover {
            supersedingCount.value += 1
            return true
        }
        stopFirst.workerExitHandled = true
        stopFirst.naturalExitDrainVerified = true
        stopFirst.runAuthorityReleased = true
        stopFirst.maybeAdvanceTakeover()
        stopFirst.present(report: report(for: stopFirst))
        guard supersedingCount.value == 0 else { return false }
        stopFirst.workerExitHandlingSettled = true
        stopFirst.maybeAdvanceTakeover()
        stopFirst.maybeAdvanceTakeover()
        guard stopFirstCount.value == 1,
              supersedingCount.value == 0 else {
            return false
        }

        let reportFirst = RunWindowController(candidates: [candidate])
        let reportFirstCount = Counter()
        arm(reportFirst, counter: reportFirstCount)
        reportFirst.testingSetStopping(
            reason: .operatorRequested,
            workerExitStatus: nil
        )
        reportFirst.present(report: report(for: reportFirst))
        reportFirst.runAuthorityReleased = true
        reportFirst.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        var stoppingCloseCount = 0
        reportFirst.onClose = { stoppingCloseCount += 1 }
        reportFirst.closeRun()
        reportFirst.presentStoppingFeedback()
        reportFirst.presentStoppingFeedback()
        guard reportFirstCount.value == 0,
              !reportFirst.prepareForNewRun(),
              reportFirst.quitGateDecision == .stopThenReevaluate,
              reportFirst.takeoverGateDecision == .block(.stopInProgress),
              stoppingCloseCount == 0,
              reportFirst.headline.stringValue
                == report(for: reportFirst).summary,
              reportFirst.postRunNoticeLabel.stringValue.contains(
                  "completed report is preserved"
              ) else {
            return false
        }
        reportFirst.testingCompleteStop(outcome: .alreadyExited(0))
        reportFirst.testingCompleteStop(outcome: .alreadyExited(0))
        guard reportFirstCount.value == 1 else { return false }

        let lateStop = RunWindowController(candidates: [candidate])
        let currentTransaction = lateStop.testingSetStopping(
            reason: .operatorRequested,
            workerExitStatus: nil,
            token: "current-generation"
        )
        lateStop.testingCompleteStop(
            outcome: .alreadyExited(0),
            token: "prior-generation"
        )
        guard case .stopping = lateStop.stopLifecycle,
              currentTransaction.token == "current-generation",
              !lateStop.prepareForNewRun() else {
            return false
        }

        let delayedReport = RunWindowController(candidates: [candidate])
        let delayedReportCount = Counter()
        arm(delayedReport, counter: delayedReportCount)
        delayedReport.testingSetTerminal(
            reason: .operatorRequested,
            outcome: .cooperative(0),
            workerExitStatus: 0
        )
        delayedReport.workerExitHandled = true
        delayedReport.workerExitHandlingSettled = true
        delayedReport.naturalExitDrainVerified = true
        delayedReport.runAuthorityReleased = true
        delayedReport.maybeAdvanceTakeover()
        guard delayedReportCount.value == 0 else { return false }
        delayedReport.present(report: report(for: delayedReport))
        guard delayedReportCount.value == 1 else { return false }

        let naturalCompletion = RunWindowController(candidates: [candidate])
        let naturalCount = Counter()
        arm(naturalCompletion, counter: naturalCount)
        naturalCompletion.terminalEventReceived = true
        naturalCompletion.workerExitHandled = true
        naturalCompletion.workerExitHandlingSettled = true
        naturalCompletion.naturalExitDrainVerified = true
        naturalCompletion.runAuthorityReleased = true
        naturalCompletion.present(report: report(for: naturalCompletion))
        naturalCompletion.present(report: report(for: naturalCompletion))
        naturalCompletion.maybeAdvanceTakeover()
        guard case .idle = naturalCompletion.stopLifecycle,
              naturalCount.value == 1 else {
            return false
        }

        let recoveryBlocked = RunWindowController(candidates: [candidate])
        let recoveryBlockedCount = Counter()
        arm(recoveryBlocked, counter: recoveryBlockedCount)
        recoveryBlocked.testingSetTerminal(
            reason: .operatorRequested,
            outcome: .terminated(143),
            workerExitStatus: 143
        )
        recoveryBlocked.workerExitHandled = true
        recoveryBlocked.workerExitHandlingSettled = true
        recoveryBlocked.report = report(for: recoveryBlocked)
        recoveryBlocked.isFinished = true
        recoveryBlocked.presentFailure(
            "Recovery review required.",
            requiresRecoveryReview: true
        )
        recoveryBlocked.maybeAdvanceTakeover()
        guard recoveryBlockedCount.value == 0 else { return false }

        let unverified = RunWindowController(candidates: [candidate])
        let unverifiedCount = Counter()
        arm(unverified, counter: unverifiedCount)
        unverified.testingSetStopping(
            reason: .operatorRequested,
            workerExitStatus: 0
        )
        unverified.workerExitHandled = true
        unverified.workerExitHandlingSettled = true
        unverified.present(report: report(for: unverified))
        unverified.testingCompleteStop(outcome: .unverified)
        unverified.maybeAdvanceTakeover()
        guard unverifiedCount.value == 0 else { return false }

        let quitDuringWait = RunWindowController(candidates: [candidate])
        let quitCount = Counter()
        arm(quitDuringWait, counter: quitCount)
        quitDuringWait.testingSetTerminal(
            reason: .operatorRequested,
            outcome: .cooperative(0),
            workerExitStatus: 0
        )
        quitDuringWait.cancelPendingTakeover()
        quitDuringWait.workerExitHandled = true
        quitDuringWait.workerExitHandlingSettled = true
        quitDuringWait.present(report: report(for: quitDuringWait))
        guard quitCount.value == 0 else { return false }

        let reapedQuit = RunWindowController(candidates: [candidate])
        var reapedCallbacks = 0
        reapedQuit.onWorkerReaped = { _ in reapedCallbacks += 1 }
        reapedQuit.runAuthorityReleased = false
        reapedQuit.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        reapedQuit.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        guard reapedQuit.quitGateDecision == .block(.authorityHeld),
              reapedCallbacks == 1 else {
            return false
        }
        reapedQuit.runAuthorityReleased = true
        reapedQuit.postReapEvidence = WorkerPostReapEvidence(
            workerReaped: true,
            ownershipProtocol: .complete,
            recordedChildDrain: .verified,
            runAuthority: .released
        )
        reapedQuit.clearPostRunNotice(reason: .authorityHeld)
        guard reapedQuit.quitGateDecision == .allow else {
            return false
        }
        let timedOut = RunWindowController(candidates: [candidate])
        let timedOutCount = Counter()
        timedOut.terminalEventReceived = true
        timedOut.takeoverTransition = .pending {
            timedOutCount.value += 1
            return true
        }
        timedOut.armTerminalTakeoverTimeout()
        guard let timeoutToken = timedOut.takeoverTimeoutToken else {
            return false
        }
        timedOut.expireTerminalTakeover(token: RunIdentity.make())
        guard !timedOut.requiresRecoveryReview else { return false }
        timedOut.expireTerminalTakeover(token: timeoutToken)
        guard timedOutCount.value == 0,
              timedOut.requiresRecoveryReview,
              timedOut.postRunNotice == nil,
              timedOut.report == nil,
              timedOut.testNeedsAttention else {
            return false
        }

        let safeTimeout = RunWindowController(candidates: [candidate])
        let safeTimeoutCount = Counter()
        safeTimeout.terminalEventReceived = true
        safeTimeout.takeoverTransition = .pending {
            safeTimeoutCount.value += 1
            return true
        }
        safeTimeout.armTerminalTakeoverTimeout()
        guard let safeTimeoutToken = safeTimeout.takeoverTimeoutToken else {
            return false
        }
        let safeTimeoutReport = report(for: safeTimeout)
        safeTimeout.present(report: safeTimeoutReport)
        let safeTimeoutHeadline = safeTimeout.headline.stringValue
        let safeTimeoutBody = safeTimeout.testRowText
        safeTimeout.testingSetTerminal(
            reason: .operatorRequested,
            outcome: .alreadyExited(0),
            workerExitStatus: 0
        )
        safeTimeout.workerExitHandled = true
        safeTimeout.workerExitHandlingSettled = true
        safeTimeout.naturalExitDrainVerified = true
        safeTimeout.runAuthorityReleased = true
        safeTimeout.expireTerminalTakeover(token: safeTimeoutToken)
        safeTimeout.expireTerminalTakeover(token: safeTimeoutToken)
        guard safeTimeoutCount.value == 0,
              safeTimeout.report == safeTimeoutReport,
              safeTimeout.headline.stringValue == safeTimeoutHeadline,
              safeTimeout.testRowText == safeTimeoutBody,
              safeTimeout.postRunNotice?.reason == .handoffTimedOut,
              safeTimeout.postRunNotice?.blocksNewRun == false,
              !safeTimeout.requiresRecoveryReview,
              safeTimeout.prepareForNewRun() else {
            return false
        }

        let interrupted = RunWindowController(candidates: [candidate])
        let interruptedResult = RepositoryResult(
            repository: candidate,
            code: .needsAttention,
            fetched: true,
            mainUpdated: false,
            beforeCommit: "before",
            targetCommit: "target",
            afterCommit: "after",
            startedAt: "2026-09-05T20:00:00.000Z",
            endedAt: "2026-09-05T20:00:00.012Z",
            durationMilliseconds: 12,
            explanation: "Preserved repository evidence."
        )
        let interruptedReport = RunReport(
            run: interrupted.expectedRunID,
            startedAt: "2026-09-05T20:00:00.000Z",
            endedAt: "2026-09-05T20:00:00.012Z",
            cancelled: true,
            results: [interruptedResult],
            summaryOverride: InterruptedRunReconstructor.summary
        )
        interrupted.present(report: interruptedReport)
        let interruptedHeadline = interrupted.headline.stringValue
        let interruptedBody = interrupted.testRowText
        interrupted.handleWorkerExit(
            status: 0,
            childDrainVerified: false,
            stateLocation: nil
        )
        interrupted.handleWorkerExit(
            status: 0,
            childDrainVerified: false,
            stateLocation: nil
        )
        guard interrupted.report == interruptedReport,
              interrupted.headline.stringValue == interruptedHeadline,
              interrupted.testRowText == interruptedBody,
              interrupted.testRowText.contains("Preserved repository evidence."),
              interrupted.postRunNotice?.reason == .childDrainUnverified,
              interrupted.blocksNewRun,
              interrupted.requiresRecoveryReview else {
            return false
        }

        let blockerFirst = RunWindowController(candidates: [candidate])
        blockerFirst.presentPostRunNotice(PostRunNotice(
            reason: .childDrainUnverified,
            detail: "fixture child blocker",
            blocksNewRun: true,
            requiresRecoveryAcknowledgement: true
        ))
        blockerFirst.presentPostRunNotice(PostRunNotice(
            reason: .childDrainUnverified,
            detail: "fixture child blocker",
            blocksNewRun: true,
            requiresRecoveryAcknowledgement: true
        ))
        let blockerFirstReport = report(for: blockerFirst)
        blockerFirst.present(report: blockerFirstReport)
        guard blockerFirst.report == blockerFirstReport,
              blockerFirst.headline.stringValue == blockerFirstReport.summary,
              blockerFirst.postRunNotice?.reason == .childDrainUnverified,
              blockerFirst.postRunNoticeLabel.stringValue.contains(
                  "fixture child blocker"
              ) else {
            return false
        }

        let acknowledgementReport = RunReport(
            run: RunIdentity.make(),
            startedAt: "2026-09-05T20:00:00.000Z",
            endedAt: "2026-09-05T20:00:00.000Z",
            cancelled: true,
            results: [RepositoryResult(
                repository: candidate,
                code: .cancelledPending,
                fetched: false,
                mainUpdated: false,
                beforeCommit: nil,
                targetCommit: nil,
                afterCommit: nil,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.000Z",
                durationMilliseconds: 0,
                explanation: "Stable recovery fixture."
            )],
            summaryOverride: InterruptedRunReconstructor.summary
        )
        let unstableClose = RunWindowController(
            candidates: [candidate],
            role: .historicalViewer
        )
        var unstableClosed = 0
        unstableClose.present(report: RunReport(
            run: unstableClose.expectedRunID,
            startedAt: acknowledgementReport.startedAt,
            endedAt: acknowledgementReport.endedAt,
            cancelled: acknowledgementReport.cancelled,
            results: acknowledgementReport.results,
            summaryOverride: acknowledgementReport.summaryOverride
        ))
        unstableClose.onClose = { unstableClosed += 1 }
        unstableClose.onRecoveryAcknowledgementRequested = { _ in false }
        unstableClose.closeRun()
        guard unstableClosed == 0,
              unstableClose.postRunNotice?.blocksNewRun == true else {
            return false
        }

        let stableClose = RunWindowController(
            candidates: [candidate],
            role: .historicalViewer
        )
        var stableClosed = 0
        stableClose.present(report: RunReport(
            run: stableClose.expectedRunID,
            startedAt: acknowledgementReport.startedAt,
            endedAt: acknowledgementReport.endedAt,
            cancelled: acknowledgementReport.cancelled,
            results: acknowledgementReport.results,
            summaryOverride: acknowledgementReport.summaryOverride
        ))
        stableClose.onClose = { stableClosed += 1 }
        stableClose.onRecoveryAcknowledgementRequested = { _ in true }
        stableClose.closeRun()
        stableClose.closeRun()
        guard stableClosed == 1,
              !stableClose.requiresRecoveryReview else {
            return false
        }

        let needsAttentionClose = RunWindowController(
            candidates: [candidate],
            role: .historicalViewer
        )
        var needsAttentionClosed = 0
        needsAttentionClose.present(report: RunReport(
            run: needsAttentionClose.expectedRunID,
            startedAt: interruptedReport.startedAt,
            endedAt: interruptedReport.endedAt,
            cancelled: interruptedReport.cancelled,
            results: interruptedReport.results
        ))
        needsAttentionClose.onClose = { needsAttentionClosed += 1 }
        needsAttentionClose.closeRun()
        guard needsAttentionClosed == 1,
              needsAttentionClose.postRunNotice == nil else {
            return false
        }
        let noLogClose = RunWindowController(candidates: [candidate])
        var noLogClosed = 0
        noLogClose.presentFailure(
            "fixture failure",
            requiresRecoveryReview: true
        )
        noLogClose.onClose = { noLogClosed += 1 }
        noLogClose.closeRun()
        guard noLogClosed == 0,
              noLogClose.report == nil,
              noLogClose.testRowText.contains(
                  "no complete, trustworthy report"
              ) else {
            return false
        }
        do {
            let safetyRoot = root + "/worker-exit-safety"
            try FileManager.default.createDirectory(
                atPath: safetyRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let safetyLocation = try StateLocation.isolated(root: safetyRoot)
            try TestIsolation.initializeState(at: safetyLocation)
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: RunIdentity.make()
            )
            func session(
                location: StateLocation?,
                protocolComplete: Bool,
                expectedRunID: String? = nil
            ) throws -> (WorkerSession, Int32) {
                var descriptors: [Int32] = [-1, -1]
                guard pipe(&descriptors) == 0 else {
                    throw WorkerClientError.pipe("safety test")
                }
                return (
                    WorkerSession(
                        processID: getpid(),
                        controlWrite: descriptors[1],
                        identity: identity,
                        stateLocation: location,
                        expectedRunID: expectedRunID,
                        ownershipProtocolComplete: protocolComplete
                    ),
                    descriptors[0]
                )
            }
            let noChild = try session(
                location: safetyLocation,
                protocolComplete: true
            )
            defer { Darwin.close(noChild.1) }
            guard noChild.0.verifySafetyAfterWorkerReap()
                == WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .released
                ) else {
                return false
            }
            let handshakeRunID = RunIdentity.make()
            let handshake = try session(
                location: safetyLocation,
                protocolComplete: false,
                expectedRunID: handshakeRunID
            )
            defer { Darwin.close(handshake.1) }
            let mismatchedIdentity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: RunIdentity.make()
            )
            guard handshake.0.verifySafetyAfterWorkerReap()
                .ownershipProtocol == .incomplete,
                !handshake.0.markOwnershipProtocolComplete(
                    workerIdentity: mismatchedIdentity,
                    runID: handshakeRunID
                ),
                !handshake.0.markOwnershipProtocolComplete(
                    workerIdentity: identity,
                    runID: RunIdentity.make()
                ),
                handshake.0.markOwnershipProtocolComplete(
                    workerIdentity: identity,
                    runID: handshakeRunID
                ),
                handshake.0.markOwnershipProtocolComplete(
                    workerIdentity: identity,
                    runID: handshakeRunID
                ),
                handshake.0.verifySafetyAfterWorkerReap()
                    .ownershipProtocol == .complete else {
                return false
            }
            let raceRunID = RunIdentity.make()
            let handshakeRace = try session(
                location: safetyLocation,
                protocolComplete: false,
                expectedRunID: raceRunID
            )
            defer { Darwin.close(handshakeRace.1) }
            let handshakeGroup = DispatchGroup()
            handshakeGroup.enter()
            DispatchQueue.global().async {
                _ = handshakeRace.0.markOwnershipProtocolComplete(
                    workerIdentity: identity,
                    runID: raceRunID
                )
                handshakeGroup.leave()
            }
            _ = handshakeRace.0.verifySafetyAfterWorkerReap()
            guard handshakeGroup.wait(timeout: .now() + 5) == .success else {
                return false
            }
            guard handshakeRace.0.verifySafetyAfterWorkerReap()
                .ownershipProtocol == .complete else {
                return false
            }
            let unavailable = try session(
                location: nil,
                protocolComplete: true
            )
            defer { Darwin.close(unavailable.1) }
            guard unavailable.0.verifySafetyAfterWorkerReap()
                == WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .unavailable
                ) else {
                return false
            }
            let errorRoot = safetyRoot + "/probe-error"
            try FileManager.default.createDirectory(
                atPath: errorRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let errorLocation = try StateLocation.isolated(root: errorRoot)
            try FileManager.default.removeItem(atPath: errorRoot)
            let probeError = try session(
                location: errorLocation,
                protocolComplete: true
            )
            defer { Darwin.close(probeError.1) }
            guard probeError.0.verifySafetyAfterWorkerReap()
                == WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .error
                ) else {
                return false
            }
            let incomplete = try session(
                location: safetyLocation,
                protocolComplete: false
            )
            defer { Darwin.close(incomplete.1) }
            guard incomplete.0.verifySafetyAfterWorkerReap()
                == WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .incomplete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .released
                ) else {
                return false
            }
            let heldAuthority = try RunAuthority.acquireRun(at: safetyLocation)
            let lostPublication = try session(
                location: safetyLocation,
                protocolComplete: true
            )
            defer { Darwin.close(lostPublication.1) }
            guard lostPublication.0.verifySafetyAfterWorkerReap()
                == WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .held
                ) else {
                heldAuthority.release()
                return false
            }
            heldAuthority.release()
            guard lostPublication.0.verifySafetyAfterWorkerReap()
                == WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .released
                ) else {
                return false
            }
        } catch {
            return false
        }

        do {
            let recoveryRoot = root + "/takeover-log-recovery"
            try FileManager.default.createDirectory(
                atPath: recoveryRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let recoveryLocation = try StateLocation.isolated(root: recoveryRoot)
            try TestIsolation.initializeState(at: recoveryLocation)
            let recoveredController = RunWindowController(candidates: [candidate])
            let recoveredReport = RunReport(
                run: recoveredController.expectedRunID,
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.000Z",
                cancelled: true,
                results: [RepositoryResult(
                    repository: candidate,
                    code: .cancelledPending,
                    fetched: false,
                    mainUpdated: false,
                    beforeCommit: nil,
                    targetCommit: nil,
                    afterCommit: nil,
                    startedAt: "2026-09-05T20:00:00.000Z",
                    endedAt: "2026-09-05T20:00:00.000Z",
                    durationMilliseconds: 0,
                    explanation: "fixture"
                )]
            )
            let authority = try RunAuthority.acquireRun(at: recoveryLocation)
            let writer = try RunLogWriter(
                authority: authority,
                runID: recoveredController.expectedRunID
            )
            try writer.append(type: "run_finished", report: recoveredReport)
            try writer.flush()
            authority.release()
            let recoveredCount = Counter()
            recoveredController.terminalEventReceived = true
            recoveredController.takeoverTransition = .pending {
                recoveredCount.value += 1
                return true
            }
            recoveredController.testingSetTerminal(
                reason: .operatorRequested,
                outcome: .alreadyExited(0),
                workerExitStatus: 0
            )
            recoveredController.handleWorkerExit(
                status: 0,
                childDrainVerified: true,
                stateLocation: recoveryLocation
            )
            recoveredController.maybeAdvanceTakeover()
            guard recoveredCount.value == 1,
                  recoveredController.report == recoveredReport,
                  recoveredController.runAuthorityReleased else {
                return false
            }

            let heldRoot = root + "/takeover-held-authority"
            try FileManager.default.createDirectory(
                atPath: heldRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let heldLocation = try StateLocation.isolated(root: heldRoot)
            try TestIsolation.initializeState(at: heldLocation)
            let heldAuthority = try RunAuthority.acquireRun(at: heldLocation)
            let heldController = RunWindowController(candidates: [candidate])
            let heldCount = Counter()
            heldController.terminalEventReceived = true
            heldController.takeoverTransition = .pending {
                heldCount.value += 1
                return true
            }
            heldController.testingSetTerminal(
                reason: .operatorRequested,
                outcome: .alreadyExited(0),
                workerExitStatus: 0
            )
            let heldReport = report(for: heldController)
            heldController.present(report: heldReport)
            let heldHeadline = heldController.headline.stringValue
            let heldBody = heldController.testRowText
            heldController.handleWorkerExit(
                status: 0,
                childDrainVerified: true,
                stateLocation: heldLocation
            )
            guard heldCount.value == 0,
                  heldController.requiresRecoveryReview,
                  heldController.report == heldReport,
                  heldController.headline.stringValue == heldHeadline,
                  heldController.testRowText == heldBody,
                  heldController.postRunNotice?.reason == .authorityHeld,
                  !heldController.runAuthorityReleased,
                  heldController.quitGateDecision == .block(.authorityHeld),
                  !heldController.prepareForNewRun() else {
                return false
            }
            heldAuthority.release()
            heldController.maybeAdvanceTakeover()
            heldController.maybeAdvanceTakeover()
            guard heldCount.value == 1,
                  heldController.prepareForNewRun(),
                  heldController.postRunNotice == nil,
                  heldController.runAuthorityReleased,
                  heldController.quitGateDecision == .allow,
                  heldController.report == heldReport,
                  heldController.headline.stringValue == heldHeadline,
                  heldController.testRowText == heldBody else {
                return false
            }

            let unknownAuthority = try RunAuthority.acquireRun(at: heldLocation)
            let unknownChild = RunWindowController(candidates: [candidate])
            let unknownCount = Counter()
            unknownChild.terminalEventReceived = true
            unknownChild.takeoverTransition = .pending {
                unknownCount.value += 1
                return true
            }
            unknownChild.present(report: report(for: unknownChild))
            unknownChild.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .held
                ),
                stateLocation: heldLocation
            )
            guard unknownCount.value == 0,
                  !unknownChild.naturalExitDrainVerified,
                  !unknownChild.runAuthorityReleased,
                  unknownChild.postRunNotice?.reason == .authorityHeld else {
                unknownAuthority.release()
                return false
            }
            unknownChild.maybeAdvanceTakeover()
            guard unknownCount.value == 0 else {
                unknownAuthority.release()
                return false
            }
            unknownAuthority.release()
            unknownChild.maybeAdvanceTakeover()
            unknownChild.maybeAdvanceTakeover()
            guard unknownCount.value == 1,
                  unknownChild.naturalExitDrainVerified,
                  unknownChild.runAuthorityReleased,
                  unknownChild.postRunNotice == nil else {
                return false
            }

            let quitAuthority = try RunAuthority.acquireRun(at: heldLocation)
            let pendingQuit = RunWindowController(candidates: [candidate])
            pendingQuit.present(report: report(for: pendingQuit))
            pendingQuit.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .verified,
                    runAuthority: .held
                ),
                stateLocation: heldLocation
            )
            var quitReadyCount = 0
            pendingQuit.onQuitReady = { quitReadyCount += 1 }
            guard pendingQuit.requestQuitAfterConfirmation() == .stopping,
                  pendingQuit.requestQuitAfterConfirmation() == .stopping,
                  quitReadyCount == 0 else {
                quitAuthority.release()
                return false
            }
            quitAuthority.release()
            pendingQuit.maybeAdvancePendingTransitions()
            pendingQuit.maybeAdvancePendingTransitions()
            guard quitReadyCount == 1,
                  pendingQuit.requestQuitAfterConfirmation() == .terminateNow else {
                return false
            }

            let safeDuringConfirmation = RunWindowController(candidates: [candidate])
            safeDuringConfirmation.present(report: report(for: safeDuringConfirmation))
            safeDuringConfirmation.testingPresentSafeWorkerExit()
            guard safeDuringConfirmation.requestQuitAfterConfirmation()
                    == .terminateNow else {
                return false
            }

            let quitTimeout = RunWindowController(candidates: [candidate])
            quitTimeout.present(report: report(for: quitTimeout))
            quitTimeout.postReapEvidence = WorkerPostReapEvidence(
                workerReaped: true,
                ownershipProtocol: .complete,
                recordedChildDrain: .verified,
                runAuthority: .held
            )
            quitTimeout.workerExitHandled = true
            quitTimeout.workerExitHandlingSettled = true
            quitTimeout.naturalExitDrainVerified = true
            quitTimeout.runAuthorityReleased = false
            var quitBlockedCount = 0
            quitTimeout.onQuitBlocked = { quitBlockedCount += 1 }
            guard quitTimeout.requestQuitAfterConfirmation() == .stopping,
                  let quitToken = quitTimeout.quitTimeoutToken else {
                return false
            }
            quitTimeout.quitStartedAt =
                Date().timeIntervalSinceReferenceDate
                - TakeoverWatchdog.maximumDuration
            quitTimeout.handleQuitProbe(token: quitToken)
            quitTimeout.handleQuitProbe(token: quitToken)
            guard quitBlockedCount == 1,
                  quitTimeout.postRunNotice?.blocksNewRun == true else {
                return false
            }

            let quitPrecedence = RunWindowController(candidates: [candidate])
            quitPrecedence.quitTransition = .pending
            let supersededTakeoverCount = Counter()
            guard quitPrecedence.requestTakeover(afterDrain: {
                supersededTakeoverCount.value += 1
                return true
            }) == .blockedByQuit,
            quitPrecedence.requestTakeover(afterDrain: {
                supersededTakeoverCount.value += 1
                return true
            }) == .blockedByQuit,
            supersededTakeoverCount.value == 0,
            quitPrecedence.headline.stringValue
                == "Quit is already in progress" else {
                return false
            }

            let inconsistent = RunWindowController(candidates: [candidate])
            inconsistent.present(report: report(for: inconsistent))
            inconsistent.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .unverified,
                    runAuthority: .released
                ),
                stateLocation: heldLocation
            )
            guard !inconsistent.naturalExitDrainVerified,
                  inconsistent.runAuthorityReleased,
                  inconsistent.postRunNotice?.reason == .evidenceConflict,
                  inconsistent.blocksNewRun else {
                return false
            }

            let unavailable = RunWindowController(candidates: [candidate])
            unavailable.present(report: report(for: unavailable))
            unavailable.handleWorkerExit(
                status: 0,
                evidence: WorkerPostReapEvidence(
                    workerReaped: true,
                    ownershipProtocol: .complete,
                    recordedChildDrain: .noneRecorded,
                    runAuthority: .unavailable
                ),
                stateLocation: nil
            )
            guard !unavailable.naturalExitDrainVerified,
                  !unavailable.runAuthorityReleased,
                  unavailable.postRunNotice?.reason == .childDrainUnverified,
                  !unavailable.prepareForNewRun() else {
                return false
            }
        } catch {
            return false
        }

        do {
            var controlPipe: [Int32] = [-1, -1]
            guard pipe(&controlPipe) == 0 else { return false }
            defer {
                Darwin.close(controlPipe[0])
                Darwin.close(controlPipe[1])
            }
            let identity = try ProcessIdentity.capture(
                processID: getpid(),
                generation: RunIdentity.make()
            )
            let blockedSession = WorkerSession(
                processID: getpid(),
                controlWrite: controlPipe[1],
                identity: identity
            )
            let blockedStop = RunWindowController(candidates: [candidate])
            blockedStop.session = blockedSession
            blockedStop.testingSetTerminal(
                reason: .operatorRequested,
                outcome: .unverified,
                workerExitStatus: nil,
                generation: identity.generation
            )
            guard blockedStop.beginStop(
                intent: .ordinary,
                reason: .operatorRequested,
                session: blockedSession
            ) == .blocked,
            blockedStop.beginStop(
                intent: .ordinary,
                reason: .ownershipFailure,
                session: blockedSession
            ) == .blocked,
            blockedStop.testingStopTransactionLaunchCount == 0,
            blockedStop.requestTakeover(afterDrain: { true }) == .blocked,
            blockedStop.requestTakeover(afterDrain: { true }) == .blocked,
            blockedStop.quitGateDecision == .block(.childDrain),
            !blockedStop.prepareForNewRun() else {
                return false
            }
        } catch {
            return false
        }

        do {
            let fixture = try NativeFixtureProcess(root: root, role: "takeover", behavior: .defaultTerm)
            defer { fixture.close() }
            let processID = fixture.processID
            let identity = fixture.identity
            var controlPipe: [Int32] = [-1, -1]
            guard pipe(&controlPipe) == 0 else { return false }
            defer { Darwin.close(controlPipe[0]) }
            let liveSession = WorkerSession(
                controlWrite: controlPipe[1],
                testingFixture: fixture
            )
            let liveTakeover = RunWindowController(candidates: [candidate])
            let liveBinding = WorkerSessionBinding(
                runID: liveTakeover.expectedRunID,
                workerGeneration: identity.generation
            )
            guard liveTakeover.installSession(
                liveSession,
                binding: liveBinding
            ) else { return false }
            liveTakeover.terminalEventReceived = true
            let liveCount = Counter()
            Thread.detachNewThread {
                guard let status = fixture.wait(seconds: 32) else { return }
                liveSession.markExited(WorkerSession.exitCode(status), childDrainVerified: true)
            }
            liveTakeover.requestTakeover {
                liveCount.value += 1
                return true
            }
            guard let liveTimerToken = liveTakeover.takeoverTimeoutToken else {
                return false
            }
            liveTakeover.requestTakeover {
                liveCount.value += 100
                return true
            }
            guard case .stopping = liveTakeover.stopLifecycle else {
                return false
            }
            guard liveTakeover.takeoverTimeoutToken == liveTimerToken else {
                return false
            }
            liveTakeover.present(report: report(for: liveTakeover))
            let stopDeadline = MonotonicDeadline(seconds: 8)
            while !stopDeadline.hasExpired {
                if case .terminal = liveTakeover.stopLifecycle {
                    break
                }
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.02)
                )
            }
            guard case let .terminal(_, result) = liveTakeover.stopLifecycle,
                  result.isVerified else { return false }
            liveTakeover.runAuthorityReleased = true
            liveTakeover.handleWorkerExit(
                status: 0,
                childDrainVerified: true,
                stateLocation: nil
            )
            liveTakeover.maybeAdvanceTakeover()
            guard liveCount.value == 1,
                  liveTakeover.takeoverTimeoutToken == nil,
                  kill(processID, 0) != 0,
                  errno == ESRCH else {
                return false
            }
        } catch {
            return false
        }

        let failedHostGate = RunWindowController(candidates: [candidate])
        var failedHostGateCount = 0
        failedHostGate.takeoverTransition = .pending {
            failedHostGateCount += 1
            return false
        }
        failedHostGate.testingSetTerminal(
            reason: .operatorRequested,
            outcome: .alreadyExited(0),
            workerExitStatus: 0
        )
        failedHostGate.workerExitHandled = true
        failedHostGate.workerExitHandlingSettled = true
        failedHostGate.naturalExitDrainVerified = true
        failedHostGate.runAuthorityReleased = true
        let failedHostReport = report(for: failedHostGate)
        failedHostGate.present(report: failedHostReport)
        let failedHostHeadline = failedHostGate.headline.stringValue
        let failedHostBody = failedHostGate.testRowText
        failedHostGate.maybeAdvanceTakeover()
        failedHostGate.maybeAdvanceTakeover()
        let finalResult = failedHostGateCount == 1
            && failedHostGate.report == failedHostReport
            && failedHostGate.headline.stringValue == failedHostHeadline
            && failedHostGate.testRowText == failedHostBody
            && failedHostGate.postRunNotice?.reason == .handoffTimedOut
            && failedHostGate.postRunNotice?.blocksNewRun == false
            && !failedHostGate.requiresRecoveryReview
        return finalResult
    }

    static func testingOwnershipFailureLifecycle(
        executablePath: String,
        root: String,
        mapping: TransportMapping,
        candidate: RepositoryCandidate
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: root + "/home",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        do {
            try unrelated.run()
        } catch {
            return false
        }
        defer {
            _ = OwnedProcessReaper.wait(for: unrelated, timeout: 0)
        }
        for fault in [
            WorkerRequest.OwnershipFault.ignoreControl,
            .closedControl,
            .exitImmediately,
            .missingHandshake,
        ] {
            let controller = RunWindowController(candidates: [candidate])
            controller.start(
                executablePath: executablePath,
                isolatedRoot: root,
                transportMapping: mapping,
                ownershipFault: fault
            )
            let deadline = MonotonicDeadline(seconds: 12)
            while !deadline.hasExpired,
                  !controller.testWorkerDrained
                    || !controller.testNeedsAttention
                    || !controller.testRowText.contains(
                        "worker ownership frame"
                    ) {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.02)
                )
            }
            let workerPID = controller.testWorkerProcessID
            let workerGone = workerPID.map {
                kill($0, 0) != 0 && errno == ESRCH
            } ?? false
            guard controller.testWorkerDrained,
                  controller.testNeedsAttention,
                  controller.testRowText.contains(
                      "worker ownership frame"
                  ),
                  workerGone,
                  unrelated.isRunning else {
                return false
            }
            do {
                let authority = try RunAuthority.acquireRun(
                    at: .isolated(root: root)
                )
                authority.release()
            } catch {
                return false
            }
        }
        return unrelated.isRunning
    }
    #endif
}

@MainActor
private final class GlobalShortcut {
    private static let productionKeyCode = UInt32(kVK_ANSI_M)
    private static let productionModifiers =
        UInt32(controlKey | optionKey | cmdKey)
    private let signature: OSType = 0x53485359
    private let identifier: UInt32 = 1
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var registrationStatus: OSStatus?

    init(action: @escaping () -> Void) {
        keyCode = Self.productionKeyCode
        modifiers = Self.productionModifiers
        self.action = action
    }

    #if SHADOW_SYNC_TESTING
    init(
        testingKeyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) {
        keyCode = testingKeyCode
        self.modifiers = modifiers
        self.action = action
    }

    static var testingProductionChord: (
        keyCode: UInt32,
        modifiers: UInt32
    ) {
        (productionKeyCode, productionModifiers)
    }
    #endif

    func register() -> Bool {
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        // The application event target invokes this handler on AppKit's main
        // event loop. Keep the action inline so the Carbon gesture still owns
        // the activation request when the callback returns.
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let owner = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      owner.handle(hotKeyID) == noErr else {
                    return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            1,
            &specification,
            pointer,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            registrationStatus = handlerStatus
            return false
        }
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKey
        )
        self.registrationStatus = registrationStatus
        if registrationStatus != noErr {
            unregister()
            return false
        }
        return true
    }

    private func handle(_ hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == signature,
              hotKeyID.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }
        action()
        return noErr
    }

    #if SHADOW_SYNC_TESTING
    func testingDispatch(
        signature: OSType? = nil,
        identifier: UInt32? = nil
    ) -> OSStatus {
        handle(EventHotKeyID(
            signature: signature ?? self.signature,
            id: identifier ?? self.identifier
        ))
    }
    #endif

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

#if SHADOW_SYNC_TESTING
private extension RunWindowController {
    static func testingThreeRowProgressIsCoherent() -> Bool {
        let candidates = (1...3).map {
            RepositoryCandidate(
                id: "fixture-owner/progress-\($0)",
                displayName: "Progress \($0)",
                path: "/private/tmp/progress-\($0)",
                rawOrigin: "https://github.com/fixture-owner/progress-\($0).git"
            )
        }
        let controller = RunWindowController(candidates: candidates)
        controller.ownershipHandshakeVerified = true
        let runID = controller.expectedRunID
        func event(
            _ type: RunEventType,
            candidate: RepositoryCandidate? = nil,
            phase: RepositoryPhase? = nil,
            result: RepositoryResult? = nil,
            message: String? = nil,
            sequence: Int
        ) -> WorkerWireMessage {
            .event(RunEvent(
                run: runID,
                sequence: sequence,
                type: type,
                repositoryID: candidate?.path,
                phase: phase,
                result: result,
                message: message
            ))
        }
        func result(_ candidate: RepositoryCandidate) -> RepositoryResult {
            RepositoryResult(
                repository: candidate,
                code: .alreadyCurrent,
                fetched: true,
                mainUpdated: false,
                beforeCommit: "fixture",
                targetCommit: "fixture",
                afterCommit: "fixture",
                startedAt: "2026-09-05T20:00:00.000Z",
                endedAt: "2026-09-05T20:00:00.001Z",
                durationMilliseconds: 1,
                explanation: "fixture"
            )
        }

        controller.accept(event(.runStarted, message: "3 repositories admitted", sequence: 1))
        controller.accept(event(
            .repositoryPhase,
            candidate: candidates[0],
            phase: .complete,
            sequence: 2
        ))
        controller.accept(event(
            .repositoryResult,
            candidate: candidates[0],
            phase: .complete,
            result: result(candidates[0]),
            sequence: 3
        ))
        let firstResultRows = controller.rowLabels
        controller.accept(event(
            .repositoryResult,
            candidate: candidates[0],
            phase: .complete,
            result: result(candidates[0]),
            sequence: 4
        ))
        guard controller.headline.stringValue == "Running",
              controller.rowLabels[candidates[0].path] == "Already Current",
              controller.rowLabels[candidates[1].path] == "Pending",
              controller.rowLabels == firstResultRows else {
            return false
        }
        controller.accept(event(
            .repositoryResult,
            candidate: candidates[1],
            phase: .complete,
            result: result(candidates[1]),
            sequence: 5
        ))
        controller.accept(event(
            .repositoryPhase,
            candidate: candidates[2],
            phase: .checking,
            sequence: 6
        ))
        guard controller.headline.stringValue == "Checking",
              controller.rowLabels[candidates[1].path] == "Already Current",
              controller.rowLabels[candidates[2].path] == "Checking",
              !controller.terminalEventReceived else {
            return false
        }
        controller.accept(event(
            .repositoryResult,
            candidate: candidates[2],
            phase: .complete,
            result: result(candidates[2]),
            sequence: 7
        ))
        let finalReport = RunReport(
            run: runID,
            startedAt: "2026-09-05T20:00:00.000Z",
            endedAt: "2026-09-05T20:00:00.003Z",
            cancelled: false,
            results: candidates.map(result),
            repositoryModel: "v2"
        )
        let terminalSummary = finalReport.summary
        controller.accept(event(
            .runFinished,
            message: terminalSummary,
            sequence: 8
        ))
        let terminalRows = controller.rowLabels
        controller.accept(event(
            .runFinished,
            message: "duplicate terminal event",
            sequence: 9
        ))
        controller.accept(event(
            .repositoryPhase,
            candidate: candidates[2],
            phase: .complete,
            sequence: 10
        ))
        controller.accept(event(
            .repositoryResult,
            candidate: candidates[2],
            phase: .complete,
            result: result(candidates[2]),
            sequence: 11
        ))
        controller.accept(event(
            .runStarted,
            message: "late start",
            sequence: 12
        ))
        let terminalHeadline = controller.headline.stringValue
        controller.requestCancellation()
        guard controller.terminalEventReceived,
              controller.isAwaitingFinalReport,
              !controller.cancelButton.isEnabled,
              !controller.cancelButton.isHidden,
              controller.closeButton.isHidden,
              !controller.cancellationRequested,
              terminalHeadline == terminalSummary,
              controller.headline.stringValue == terminalSummary,
              controller.rowLabels == terminalRows else {
            return false
        }
        controller.accept(.completion(finalReport))
        controller.accept(.completion(finalReport))
        let detailedReportBody = controller.testRowText
        let finalHeadline = controller.headline.stringValue
        let finalRows = controller.rowLabels
        controller.accept(event(
            .repositoryPhase,
            candidate: candidates[0],
            phase: .fetching,
            sequence: 13
        ))
        controller.accept(event(
            .repositoryResult,
            candidate: candidates[0],
            phase: .complete,
            result: result(candidates[0]),
            sequence: 14
        ))
        controller.accept(.event(RunEvent(
            run: "stale-run",
            sequence: 15,
            type: .repositoryPhase,
            repositoryID: candidates[0].path,
            phase: .updating
        )))
        var exitCallbacks = 0
        controller.onWorkerExit = { _ in exitCallbacks += 1 }
        controller.runAuthorityReleased = true
        controller.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        controller.handleWorkerExit(
            status: 0,
            childDrainVerified: true,
            stateLocation: nil
        )
        guard controller.report == finalReport,
              controller.isFinished,
              !controller.isAwaitingFinalReport,
              finalHeadline == finalReport.summary,
              controller.headline.stringValue == finalHeadline,
              controller.testRowText == detailedReportBody,
              controller.rowLabels == finalRows,
              controller.cancelButton.isHidden,
              !controller.cancelButton.isEnabled,
              !controller.closeButton.isHidden,
              exitCallbacks == 1,
              !controller.blocksNewRun else {
            return false
        }

        let reportFirst = RunWindowController(candidates: candidates)
        reportFirst.ownershipHandshakeVerified = true
        let reportFirstReport = RunReport(
            run: reportFirst.expectedRunID,
            startedAt: "2026-09-05T20:00:00.000Z",
            endedAt: "2026-09-05T20:00:00.003Z",
            cancelled: false,
            results: candidates.map(result)
        )
        reportFirst.accept(.completion(reportFirstReport))
        let reportFirstBody = reportFirst.testRowText
        let reportFirstHeadline = reportFirst.headline.stringValue
        let reportFirstRows = reportFirst.rowLabels
        reportFirst.accept(.event(RunEvent(
            run: reportFirst.expectedRunID,
            sequence: 1,
            type: .repositoryPhase,
            repositoryID: candidates[0].path,
            phase: .fetching
        )))
        reportFirst.accept(.event(RunEvent(
            run: reportFirst.expectedRunID,
            sequence: 2,
            type: .repositoryResult,
            repositoryID: candidates[0].path,
            phase: .complete,
            result: result(candidates[0])
        )))
        reportFirst.accept(.event(RunEvent(
            run: reportFirst.expectedRunID,
            sequence: 3,
            type: .runFinished,
            message: "late terminal event"
        )))
        reportFirst.accept(.event(RunEvent(
            run: reportFirst.expectedRunID,
            sequence: 4,
            type: .runFinished,
            message: "duplicate late terminal event"
        )))
        reportFirst.accept(.event(RunEvent(
            run: "stale-run",
            sequence: 5,
            type: .runStarted
        )))
        reportFirst.requestCancellation()
        guard reportFirst.report == nil
            && !reportFirst.isFinished
            && reportFirst.terminalEventReceived
            && reportFirst.cancellationRequested
            && reportFirstHeadline == "Needs Attention"
            && reportFirst.headline.stringValue == "Needs Attention"
            && reportFirst.testRowText == reportFirstBody
            && reportFirst.rowLabels == reportFirstRows
            && reportFirst.cancelButton.isHidden
            && !reportFirst.cancelButton.isEnabled
            && reportFirst.closeButton.isHidden
            && !reportFirst.closeButton.isEnabled
            && reportFirst.blocksNewRun else {
            return false
        }

        let staleBeforeTerminal = RunWindowController(candidates: candidates)
        staleBeforeTerminal.ownershipHandshakeVerified = true
        staleBeforeTerminal.accept(.event(RunEvent(
            run: "stale-run",
            sequence: 1,
            type: .runStarted
        )))
        let staleExact = staleBeforeTerminal.isFinished
            && staleBeforeTerminal.report == nil
            && staleBeforeTerminal.headline.stringValue == "Needs Attention"
            && staleBeforeTerminal.cancelButton.isHidden
            && !staleBeforeTerminal.cancelButton.isEnabled
            && !staleBeforeTerminal.closeButton.isHidden
        return staleExact
    }
}
#endif
