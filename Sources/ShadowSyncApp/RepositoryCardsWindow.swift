import AppKit
import ShadowSyncCore

enum ShadowSyncAppColors {
    static let cleanupInspectionPanelFill = NSColor(
        name: NSColor.Name("ShadowSync.CleanupInspectionPanelFill"),
        dynamicProvider: { appearance in
            resolvedCleanupInspectionPanelFill(for: appearance)
        }
    )

    static func resolvedCleanupInspectionPanelFill(
        for appearance: NSAppearance
    ) -> NSColor {
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let background =
                (
                    NSColor.windowBackgroundColor
                        .usingColorSpace(.deviceRGB)
                        ?? NSColor.windowBackgroundColor
                ).withAlphaComponent(1)
            let label =
                (
                    NSColor.labelColor
                        .usingColorSpace(.deviceRGB)
                        ?? NSColor.labelColor
                ).withAlphaComponent(1)
            resolved =
                (
                    background.blended(
                        withFraction: 0.08,
                        of: label
                    ) ?? background
                ).withAlphaComponent(1)
        }
        return resolved
    }
}

final class CleanupInspectionProgressRelay:
    @unchecked Sendable {
    private weak var controller:
        RepositoryCardSelectionWindowController?

    init(
        controller: RepositoryCardSelectionWindowController
    ) {
        self.controller = controller
    }

    func publish(_ progress: CleanupInspectionProgress) {
        DispatchQueue.main.async { [self] in
            controller?.updateCleanupInspectionProgress(progress)
        }
    }
}

final class RepositoryCardSelectionWindowController:
    SelectionWindowController {
    private enum CleanupInspectionState: Equatable {
        case notInspected
        case inspecting
        case inspected
        case issues(String)
        case cancelled
        case failed(String)
    }

    private enum RenderingState: String {
        case inventory
        case preparing
        case failure
        case cancelling
    }

    var onReviewOperations: (([PlannedOperation]) -> Void)?
    var onReviewBatch:
        (([PlannedOperation], [RemovalSelection]) -> Void)?
    var onChooseCanonicalRoot: ((RepositoryCard, LocalClone) -> Void)?
    var onManageSelection: (() -> Void)?
    var onInspectCleanup: ((Set<String>) -> Void)?

    private var inventory = RepositoryInventory(
        cards: [],
        onboardingProposals: [],
        authorityFileIdentity: nil
    )
    private var verifiedCapability:
        VerifiedRepositoryAuthorityCapability?
    private var selectedOperationIDs: Set<String> = []
    private var operationButtons: [String: NSButton] = [:]
    private var maintenanceUnavailableRows:
        [String: NSTextField] = [:]
    private var removalCandidates: [RemovalCandidate] = []
    private var selectedRemovalIDs: Set<String> = []
    private var removalsByID: [String: RemovalCandidate] = [:]
    private var removalButtons: [String: NSButton] = [:]
    private var secretButtons: [String: NSButton] = [:]
    private var canonicalMenus: [ObjectIdentifier: (RepositoryCard, NSPopUpButton)] = [:]
    private var canonicalControls: [NSControl] = []
    private var cloneDisclosures:
        [ObjectIdentifier: (NSStackView, String)] = [:]
    private var cleanupStates:
        [String: CleanupInspectionState] = [:]
    private var cleanupProgress:
        [String: CleanupInspectionProgress] = [:]
    private var cleanupBatchRepositoryIDs: [String] = []
    private var cleanupProgressIndicators:
        [String: NSProgressIndicator] = [:]
    private var cleanupProgressLabels:
        [String: NSTextField] = [:]
    private var cleanupBatchOverallIndicator:
        NSProgressIndicator?
    private var cleanupBatchOverallLabel: NSTextField?
    private var cleanupButtons:
        [ObjectIdentifier: String] = [:]
    private var authorityControlsEnabled = true
    private var protectionPaths: [String] = []
    private var protectionBoundaryEstablished = true
    private var renderingState: RenderingState = .inventory
    private var contentInstallationCount = 0
    private let loadingIndicator = NSProgressIndicator()
    private let loadingStatus = NSTextField(
        wrappingLabelWithString:
            ShadowSyncPresentation.preparingRepositoryList
    )
    private let loadingRetry = NSButton(
        title: "Try Again",
        target: nil,
        action: nil
    )
    var onRetryInventory: (() -> Void)?
    private let reviewButton = NSButton(
        title: "Review selected operation…",
        target: nil,
        action: nil
    )
    private let selectionStatus = NSTextField(labelWithString: "")
    private let referencesStack = NSStackView()
    private let referencesToggle = NSButton(
        title: "",
        target: nil,
        action: nil
    )
    private let inspectAllCleanupButton = NSButton(
        title: "Inspect for all repositories",
        target: nil,
        action: nil
    )
    private let selectRecommendedCleanupButton = NSButton(
        title: "Select All Recommended Cleanup",
        target: nil,
        action: nil
    )
    private let manageSelectionButton = NSButton(
        title: "Change/Manage saved selection",
        target: nil,
        action: nil
    )
    private var isClosingFromAction = false
    private var closeNotified = false
    #if SHADOW_SYNC_TESTING
    private var testingDeactivatedControls: [NSControl] = []
    private var testingCleanupCandidateCards: [NSView] = []
    private var testingCleanupCandidateIdentities: [NSTextField] = []
    private var testingCleanupCandidateTypeRows: [NSStackView] = []
    #endif

    init(
        inventory: RepositoryInventory,
        capability: VerifiedRepositoryAuthorityCapability,
        protectedPaths: [String] = [],
        protectionBoundaryEstablished: Bool = true
    ) {
        self.inventory = inventory
        verifiedCapability = capability
        protectionPaths = protectedPaths
        self.protectionBoundaryEstablished =
            protectionBoundaryEstablished
        removalCandidates = RepositoryInventoryRemovalCandidates.make(
            from: inventory,
            capability: capability,
            protectedPaths: protectedPaths,
            protectionBoundaryEstablished:
                protectionBoundaryEstablished
        )
        let cardWindow = NSWindow(
            contentRect: WindowFrameContinuity.initialRect(
                size: NSSize(width: 900, height: 720)
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        cardWindow.title = "Repository lifecycle control center"
        cardWindow.minSize = NSSize(width: 720, height: 520)
        super.init(candidates: [])
        window = cardWindow
        cardWindow.delegate = self
        buildContent()
    }

    #if SHADOW_SYNC_TESTING
    init(
        inventory: RepositoryInventory,
        protectedPaths: [String] = [],
        protectionBoundaryEstablished: Bool = true
    ) {
        self.inventory = inventory
        verifiedCapability = nil
        protectionPaths = protectedPaths
        self.protectionBoundaryEstablished =
            protectionBoundaryEstablished
        removalCandidates = RepositoryInventoryRemovalCandidates.make(
            from: inventory,
            protectedPaths: protectedPaths,
            protectionBoundaryEstablished:
                protectionBoundaryEstablished
        )
        let cardWindow = NSWindow(
            contentRect: WindowFrameContinuity.initialRect(
                size: NSSize(width: 900, height: 720)
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        cardWindow.title = "Repository lifecycle control center"
        cardWindow.minSize = NSSize(width: 720, height: 520)
        super.init(candidates: [])
        window = cardWindow
        cardWindow.delegate = self
        buildContent()
    }
    #endif

    init(preparingRepositoryList: Void = ()) {
        let cardWindow = NSWindow(
            contentRect: WindowFrameContinuity.initialRect(
                size: NSSize(width: 900, height: 520)
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        cardWindow.title = "Repository lifecycle control center"
        cardWindow.minSize = NSSize(width: 720, height: 520)
        super.init(candidates: [])
        window = cardWindow
        cardWindow.delegate = self
        installLoadingContent(
            state: .preparing,
            message: ShadowSyncPresentation.preparingRepositoryList,
            showsRetry: false,
            animates: true
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func closeForConfirmedRun() {
        isClosingFromAction = true
        close()
    }

    func prepareForRedisplay() {
        isClosingFromAction = false
        closeNotified = false
    }

    override func presentInlineMessage(_ message: String?) {
        if let message {
            selectionStatus.stringValue = message
            selectionStatus.textColor = .systemOrange
        } else {
            refreshSelectionStatus()
        }
    }

    override func windowWillClose(_ notification: Notification) {
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .abort)
        }
        if !isClosingFromAction {
            notifyClosed()
        }
    }

    override func setReviewEnabled(_ enabled: Bool) {
        reviewButton.isEnabled = enabled
            && (
                !selectedOperationIDs.isEmpty
                    || !selectedRemovalIDs.isEmpty
            )
    }

    func setAuthorityControlsEnabled(_ enabled: Bool) {
        authorityControlsEnabled = enabled
        for control in canonicalControls {
            control.isEnabled = enabled
        }
    }

    func showPreparingRepositoryList() {
        deactivateInventoryContent()
        installLoadingContent(
            state: .preparing,
            message: ShadowSyncPresentation.preparingRepositoryList,
            showsRetry: false,
            animates: true
        )
    }

    @discardableResult
    func apply(
        inventory: RepositoryInventory,
        capability: VerifiedRepositoryAuthorityCapability,
        protectedPaths: [String],
        protectionBoundaryEstablished: Bool
    ) -> Bool {
        guard renderingState == .preparing,
              !inventory.cards.isEmpty else {
            return false
        }
        self.inventory = inventory
        verifiedCapability = capability
        protectionPaths = protectedPaths
        self.protectionBoundaryEstablished =
            protectionBoundaryEstablished
        removalCandidates = RepositoryInventoryRemovalCandidates.make(
            from: inventory,
            capability: capability,
            protectedPaths: protectedPaths,
            protectionBoundaryEstablished:
                protectionBoundaryEstablished
        )
        renderingState = .inventory
        loadingIndicator.stopAnimation(nil)
        buildContent()
        return true
    }

    #if SHADOW_SYNC_TESTING
    @discardableResult
    func apply(
        inventory: RepositoryInventory,
        protectedPaths: [String],
        protectionBoundaryEstablished: Bool
    ) -> Bool {
        guard renderingState == .preparing,
              !inventory.cards.isEmpty else {
            return false
        }
        self.inventory = inventory
        verifiedCapability = nil
        protectionPaths = protectedPaths
        self.protectionBoundaryEstablished =
            protectionBoundaryEstablished
        removalCandidates = RepositoryInventoryRemovalCandidates.make(
            from: inventory,
            protectedPaths: protectedPaths,
            protectionBoundaryEstablished:
                protectionBoundaryEstablished
        )
        renderingState = .inventory
        loadingIndicator.stopAnimation(nil)
        buildContent()
        return true
    }
    #endif

    func showInventoryFailure(_ message: String) {
        guard renderingState == .preparing else { return }
        installLoadingContent(
            state: .failure,
            message: message,
            showsRetry: true,
            animates: false
        )
    }

    func showInventoryCancellation(_ message: String) {
        guard renderingState == .preparing else { return }
        installLoadingContent(
            state: .cancelling,
            message: message,
            showsRetry: false,
            animates: true
        )
    }

    var isPreparingRepositoryList: Bool {
        renderingState == .preparing
    }

    var inventorySnapshot: RepositoryInventory {
        inventory
    }

    var successfulCleanupInspectionRepositoryIDs: Set<String> {
        Set(cleanupStates.compactMap { id, state in
            switch state {
            case .inspected: return id
            default: return nil
            }
        })
    }

    var isCleanupInspectionInProgress: Bool {
        cleanupStates.values.contains(.inspecting)
    }

    func restoreSuccessfulCleanupInspections(
        _ repositoryIDs: Set<String>
    ) {
        let available = Set(inventory.cards.map(\.id))
        let restored = repositoryIDs.intersection(available)
        guard !restored.isEmpty else { return }
        for id in restored where cleanupStates[id] != .inspecting {
            cleanupStates[id] = .inspected
        }
        buildContent()
    }

    func beginCleanupInspection(
        repositoryIDs: Set<String>
    ) {
        cleanupBatchRepositoryIDs = inventory.writableCards
            .map(\.id)
            .filter(repositoryIDs.contains)
        for (index, id) in cleanupBatchRepositoryIDs.enumerated() {
            cleanupStates[id] =
                index == 0 ? .inspecting : .notInspected
            cleanupProgress[id] = CleanupInspectionProgress(
                repositoryID: id,
                repositoryCompleted: 0,
                repositoryTotal: repositoryIDs.count,
                stage: .topology,
                completed: 0,
                total: 1
            )
        }
        buildContent()
    }

    func updateCleanupInspectionProgress(
        _ progress: CleanupInspectionProgress
    ) {
        guard cleanupBatchRepositoryIDs.contains(
                progress.repositoryID
              ),
              cleanupStates[progress.repositoryID]
                == .inspecting
                || cleanupStates[progress.repositoryID]
                    == .notInspected else {
            return
        }
        if cleanupStates[progress.repositoryID]
            == .notInspected {
            cleanupStates[progress.repositoryID] = .inspecting
        }
        cleanupProgress[progress.repositoryID] = progress
        if progress.stage == .candidateAssembly,
           progress.completed >= max(1, progress.total),
           progress.repositoryCompleted > 0 {
            cleanupStates[progress.repositoryID] = .inspected
        }
        if let indicator =
                cleanupProgressIndicators[progress.repositoryID] {
            configure(
                indicator,
                progress: progress
            )
        }
        cleanupProgressLabels[progress.repositoryID]?
            .stringValue = cleanupProgressText(progress)
        updateBatchProgressPresentation()
    }

    func applyCleanupInspection(
        inventory: RepositoryInventory,
        repositoryIDs: Set<String>
    ) {
        let selectedRemovalEvidence = Dictionary(
            uniqueKeysWithValues: removalCandidates
                .filter {
                    selectedRemovalIDs.contains($0.id)
                }
                .map { ($0.id, $0.evidenceDigest) }
        )
        self.inventory = inventory
        if let verifiedCapability {
            removalCandidates =
                RepositoryInventoryRemovalCandidates.make(
                    from: inventory,
                    capability: verifiedCapability,
                    protectedPaths: protectionPaths,
                    protectionBoundaryEstablished:
                        protectionBoundaryEstablished
                )
        } else {
            #if SHADOW_SYNC_TESTING
            removalCandidates =
                RepositoryInventoryRemovalCandidates.make(
                from: inventory,
                protectedPaths: protectionPaths,
                protectionBoundaryEstablished:
                    protectionBoundaryEstablished
            )
            #endif
        }
        for id in repositoryIDs {
            let warning = inventory.cards.first {
                $0.id == id
            }?.clones.lazy.flatMap(\.warnings).first {
                $0.hasPrefix("Cleanup inspection ")
                    || $0.hasPrefix("Lifecycle inspection ")
            }
            cleanupStates[id] = warning.map {
                if $0.localizedCaseInsensitiveContains(
                    "not started"
                ) {
                    return .notInspected
                }
                return $0.localizedCaseInsensitiveContains(
                    "cancel"
                ) ? .cancelled : .issues($0)
            } ?? .inspected
            if warning == nil {
                let prior = cleanupProgress[id]
                cleanupProgress[id] =
                    CleanupInspectionProgress(
                        repositoryID: id,
                        repositoryCompleted:
                            prior?.repositoryTotal ?? 1,
                        repositoryTotal:
                            prior?.repositoryTotal ?? 1,
                        stage: .candidateAssembly,
                        completed: 1,
                        total: 1,
                        durationMilliseconds:
                            prior?.durationMilliseconds ?? 0,
                        heartbeat:
                            (prior?.heartbeat ?? 0) + 1
                    )
            }
        }
        selectedRemovalIDs = Set(
            removalCandidates.compactMap {
                $0.canSelect
                    && selectedRemovalEvidence[$0.id]
                        == $0.evidenceDigest
                    ? $0.id : nil
            }
        )
        buildContent()
    }

    func failCleanupInspection(
        repositoryIDs: Set<String>,
        message: String
    ) {
        if message.localizedCaseInsensitiveContains("cancel") {
            var currentWasMarked = false
            for id in cleanupBatchRepositoryIDs {
                guard repositoryIDs.contains(id) else { continue }
                switch cleanupStates[id] {
                case .inspected?, .issues?, .failed?, .cancelled?:
                    continue
                default:
                    break
                }
                let progress = cleanupProgress[id]
                let hasStarted =
                    progress?.stage != .topology
                        || (progress?.completed ?? 0) > 0
                        || (progress?.heartbeat ?? 0) > 0
                if !currentWasMarked && hasStarted {
                    cleanupStates[id] = .cancelled
                    currentWasMarked = true
                } else {
                    cleanupStates[id] = .notInspected
                }
            }
            if !currentWasMarked,
               let first = cleanupBatchRepositoryIDs.first(where: {
                   repositoryIDs.contains($0)
                       && cleanupStates[$0] == .notInspected
               }) {
                cleanupStates[first] = .cancelled
            }
            buildContent()
            return
        }
        for id in repositoryIDs {
            cleanupStates[id] = .failed(message)
        }
        buildContent()
    }

    private func deactivateInventoryContent() {
        let retainedControls: [NSControl] =
            Array(operationButtons.values)
            + Array(removalButtons.values)
            + Array(secretButtons.values)
            + canonicalControls
            + [reviewButton, referencesToggle]
        for control in retainedControls {
            control.isEnabled = false
            control.target = nil
            control.action = nil
        }
        #if SHADOW_SYNC_TESTING
        testingDeactivatedControls = retainedControls
        #endif
        selectedOperationIDs.removeAll()
        operationButtons.removeAll()
        selectedRemovalIDs.removeAll()
        removalsByID.removeAll()
        removalButtons.removeAll()
        secretButtons.removeAll()
        canonicalMenus.removeAll()
        canonicalControls.removeAll()
        cloneDisclosures.removeAll()
        maintenanceUnavailableRows.removeAll()
    }

    private func installLoadingContent(
        state: RenderingState,
        message: String,
        showsRetry: Bool,
        animates: Bool
    ) {
        guard let window else { return }
        renderingState = state
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            labelWithString: "Repository lifecycle control center"
        )
        title.font = .boldSystemFont(ofSize: 18)
        root.addArrangedSubview(title)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isHidden = !animates
        if animates {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        loadingIndicator.setAccessibilityLabel("Repository list activity")
        root.addArrangedSubview(loadingIndicator)

        loadingStatus.stringValue = message
        loadingStatus.alignment = .left
        loadingStatus.font = .systemFont(ofSize: 13)
        loadingStatus.textColor =
            state == .failure ? .systemOrange : .secondaryLabelColor
        loadingStatus.maximumNumberOfLines = 0
        loadingStatus.setAccessibilityLabel("Repository inventory status")
        root.addArrangedSubview(loadingStatus)

        loadingRetry.target = self
        loadingRetry.action = #selector(retryInventory)
        loadingRetry.isHidden = !showsRetry
        root.addArrangedSubview(loadingRetry)

        let closeButton = NSButton(
            title: "Hide",
            target: self,
            action: #selector(hideLoading)
        )
        closeButton.bezelStyle = .rounded
        closeButton.toolTip =
            "Hide this window. The repository check continues in the background."
        root.addArrangedSubview(closeButton)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        contentInstallationCount += 1
        NSLayoutConstraint.activate([
            root.centerYAnchor.constraint(
                equalTo: window.contentView!.centerYAnchor
            ),
            root.leadingAnchor.constraint(
                equalTo: window.contentView!.leadingAnchor,
                constant: 32
            ),
            root.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor,
                constant: -32
            ),
        ])
        let firstResponder = showsRetry ? loadingRetry : closeButton
        window.initialFirstResponder = firstResponder
        window.makeFirstResponder(firstResponder)
    }

    @objc private func retryInventory() {
        onRetryInventory?()
    }

    @objc private func hideLoading() {
        isClosingFromAction = true
        close()
        notifyClosed()
    }

    private func buildContent() {
        guard let window else { return }
        renderingState = .inventory
        operationButtons.removeAll()
        removalButtons.removeAll()
        removalsByID.removeAll()
        secretButtons.removeAll()
        canonicalMenus.removeAll()
        canonicalControls.removeAll()
        cloneDisclosures.removeAll()
        maintenanceUnavailableRows.removeAll()
        cleanupButtons.removeAll()
        cleanupProgressIndicators.removeAll()
        cleanupProgressLabels.removeAll()
        cleanupBatchOverallIndicator = nil
        cleanupBatchOverallLabel = nil
        #if SHADOW_SYNC_TESTING
        testingCleanupCandidateCards.removeAll()
        testingCleanupCandidateIdentities.removeAll()
        testingCleanupCandidateTypeRows.removeAll()
        #endif
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let help = NSTextField(wrappingLabelWithString:
            "Each card is one GitHub repository. Branch and Worktree identity, purpose, activity, recommendation, and permission stay separate. Only direct selections retained in the final grouped confirmation can mutate Git."
        )
        help.font = .systemFont(ofSize: 13)
        help.textColor = .secondaryLabelColor
        root.addArrangedSubview(help)

        let fastForwardCount = inventory.selectableOperations.filter {
            $0.kind == .fastForward
        }.count
        let repairCount = inventory.selectableOperations.filter {
            $0.kind == .repairPruneRegistrations
                || $0.kind == .repairMovedWorktree
        }.count
        let initializeCount = inventory.selectableOperations.filter {
            $0.kind == .initializeDefaultBranch
        }.count
        let counts = NSTextField(labelWithString:
            "\(fastForwardCount) Fast-forward · "
                + "\(repairCount) exact Repair · "
                + "\(initializeCount) Initialize · "
                + "\(inventory.writableCards.filter { !$0.isOperationReady }.count) unavailable · "
                + "\(inventory.protectedCards.count) protected · "
                + "\(inventory.referenceCards.count) reference"
        )
        counts.font = .boldSystemFont(ofSize: 12)
        root.addArrangedSubview(counts)
        inspectAllCleanupButton.target = self
        inspectAllCleanupButton.action =
            #selector(inspectAllCleanup)
        inspectAllCleanupButton.isEnabled =
            inventory.writableCards.contains {
                cleanupStates[$0.id] != .inspecting
            }
        root.addArrangedSubview(inspectAllCleanupButton)
        if cleanupBatchRepositoryIDs.count > 1 {
            let batchProgress = cleanupBatchProgressView()
            root.addArrangedSubview(batchProgress)
            batchProgress.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ).isActive = true
        }
        let roadmap = NSTextField(wrappingLabelWithString:
            "Repository actions use the bounded canonical/default check first. Branch, worktree, pull-request, and cleanup evidence is optional and runs only when you request inspection."
        )
        roadmap.font = .systemFont(ofSize: 11)
        roadmap.textColor = .secondaryLabelColor
        root.addArrangedSubview(roadmap)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(
            .defaultLow,
            for: .vertical
        )
        scroll.setContentCompressionResistancePriority(
            .defaultLow,
            for: .vertical
        )
        let document = NSStackView()
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 10
        document.edgeInsets = NSEdgeInsets(
            top: 10, left: 10, bottom: 10, right: 10
        )
        document.translatesAutoresizingMaskIntoConstraints = false
        document.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        if !inventory.writableCards.isEmpty {
            document.addArrangedSubview(sectionTitle(
                "Writable repositories"
            ))
        }
        for card in inventory.writableCards {
            let cardView = makeCard(card)
            document.addArrangedSubview(cardView)
            cardView.widthAnchor.constraint(
                equalTo: document.widthAnchor,
                constant: -20
            ).isActive = true
        }
        if !inventory.protectedCards.isEmpty {
            document.addArrangedSubview(sectionTitle(
                "Protected repositories"
            ))
        }
        for card in inventory.protectedCards {
            let cardView = makeProtectedCard(card)
            document.addArrangedSubview(cardView)
            cardView.widthAnchor.constraint(
                equalTo: document.widthAnchor,
                constant: -20
            ).isActive = true
        }
        configureReferences(in: document)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(
                equalTo: scroll.contentView.leadingAnchor
            ),
            document.trailingAnchor.constraint(
                equalTo: scroll.contentView.trailingAnchor
            ),
            document.topAnchor.constraint(
                equalTo: scroll.contentView.topAnchor
            ),
        ])
        root.addArrangedSubview(scroll)

        selectionStatus.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(selectionStatus)

        let selectAll = NSButton(
            title: "Select All Operations",
            target: self,
            action: #selector(selectAllOperations)
        )
        selectAll.bezelStyle = .rounded
        selectRecommendedCleanupButton.target = self
        selectRecommendedCleanupButton.action =
            #selector(selectAllRecommendedRemoval)
        selectRecommendedCleanupButton.bezelStyle = .rounded
        selectRecommendedCleanupButton.isEnabled =
            !successfulCleanupInspectionRepositoryIDs.isEmpty
        let clearAll = NSButton(
            title: "Clear All",
            target: self,
            action: #selector(clearAllOperations)
        )
        clearAll.bezelStyle = .rounded
        let selectionButtons = NSStackView(
            views: [
                selectAll,
                selectRecommendedCleanupButton,
                clearAll,
            ]
        )
        selectionButtons.orientation = .horizontal
        selectionButtons.spacing = 8
        selectionButtons.distribution = .fillEqually
        root.addArrangedSubview(selectionButtons)

        let cancel = NSButton(
            title: "Cancel",
            target: self,
            action: #selector(cancelCards)
        )
        cancel.bezelStyle = .rounded
        manageSelectionButton.target = self
        manageSelectionButton.action = #selector(manageSelection)
        manageSelectionButton.bezelStyle = .rounded
        manageSelectionButton.isEnabled =
            !cleanupStates.values.contains(.inspecting)
        reviewButton.target = self
        reviewButton.action = #selector(reviewOperations)
        reviewButton.bezelStyle = .rounded
        reviewButton.keyEquivalent = "\r"
        let actions = NSStackView(
            views: [manageSelectionButton, cancel, reviewButton]
        )
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually
        root.addArrangedSubview(actions)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        contentInstallationCount += 1
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(
                equalTo: window.contentView!.leadingAnchor,
                constant: 20
            ),
            root.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor,
                constant: -20
            ),
            root.topAnchor.constraint(
                equalTo: window.contentView!.topAnchor,
                constant: 20
            ),
            root.bottomAnchor.constraint(
                equalTo: window.contentView!.bottomAnchor,
                constant: -20
            ),
            help.widthAnchor.constraint(equalTo: root.widthAnchor),
            roadmap.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            selectionStatus.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            selectionButtons.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            actions.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
        ])
        window.initialFirstResponder = selectAll
        window.makeFirstResponder(selectAll)
        refreshSelectionStatus()
    }

    @objc private func manageSelection() {
        onManageSelection?()
    }

    private func makeCard(_ card: RepositoryCard) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 12, height: 10)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )

        let defaultName = card.repository.resolvedDefault?.name
            ?? "Unavailable"
        let header = NSTextField(labelWithString:
            "\(card.repository.id) · default branch: \(defaultName)"
        )
        header.font = .boldSystemFont(ofSize: 14)
        header.alignment = .left
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(
            sectionTitle("Default branch & repository actions")
        )

        if let canonicalRoot = card.authority.record?.canonicalRoot {
            stack.addArrangedSubview(detail(
                "Canonical root: \(canonicalRoot)"
            ))
        } else {
            let warning = detail(
                "Canonical root: \(card.authority.explanation)"
            )
            warning.textColor = .systemOrange
            stack.addArrangedSubview(warning)
            addCanonicalChooser(for: card, to: stack)
        }
        if let originHead = card.originHeadExplanation {
            let field = detail(originHead)
            field.textColor = .secondaryLabelColor
            stack.addArrangedSubview(field)
        }

        if let canonical = canonicalClone(for: card) {
            let primary = canonical.worktrees.first(where: \.isPrimary)
            let primaryBranch = primary?.attachedBranchRef.map(
                shortBranch
            ) ?? "Detached or unavailable"
            stack.addArrangedSubview(detail(
                "Primary checkout: \(canonical.primaryRoot) · current branch: \(primaryBranch)"
            ))
            let primaryState = primary.map {
                fileStateSummary($0)
            } ?? "Unknown"
            stack.addArrangedSubview(detail(
                "Primary checkout state: \(primaryState)"
            ))
            if let resolved = card.repository.resolvedDefault,
               let branch = canonical.branches.first(where: {
                   $0.fullRef == resolved.localRef
               }),
               let claim = branch.claimingWorktreeIDs.first,
               let worktree = canonical.worktrees.first(where: {
                   $0.id == claim
               }) {
                stack.addArrangedSubview(detail(
                    "Default branch worktree: \(worktree.path)"
                ))
            } else if let resolved = card.repository.resolvedDefault,
                      canonical.branches.contains(where: {
                          $0.fullRef == resolved.localRef
                              && $0.claimingWorktreeIDs.isEmpty
                      }) {
                stack.addArrangedSubview(detail(
                    "Default branch target: ref-only · no worktree claims this branch"
                ))
            }
        }

        let relation = detail(
            "Default relation: \(card.relation.operatorLabel)"
        )
        relation.textColor = card.relation.kind == .ahead
                || card.relation.kind == .diverged
            ? .systemOrange : .secondaryLabelColor
        stack.addArrangedSubview(relation)

        if let operation = card.fastForward, operation.isSelectable {
            let control = NSButton(
                checkboxWithTitle: operation.target.mode == .refOnly
                    ? "Fast-forward default ref (no worktree)"
                    : "Fast-forward default branch",
                target: self,
                action: #selector(operationSelectionChanged(_:))
            )
            control.identifier = NSUserInterfaceItemIdentifier(operation.id)
            operationButtons[operation.id] = control
            control.state = selectedOperationIDs.contains(
                operation.id
            ) ? .on : .off
            stack.addArrangedSubview(control)
            stack.addArrangedSubview(detail(
                "Ready after fresh safety revalidation."
            ))
        } else {
            let refusal = detail(
                "Fast-forward: "
                    + (card.fastForwardRefusal
                        ?? card.fastForward?.refusalReason
                        ?? "Unavailable")
            )
            refusal.textColor = .systemOrange
            stack.addArrangedSubview(refusal)
        }
        for operation in card.maintenanceOperations {
            guard operation.isSelectable else { continue }
            let control = NSButton(
                checkboxWithTitle:
                    operationTitle(operation),
                target: self,
                action:
                    #selector(operationSelectionChanged(_:))
            )
            control.identifier =
                NSUserInterfaceItemIdentifier(operation.id)
            operationButtons[operation.id] = control
            control.state = selectedOperationIDs.contains(
                operation.id
            ) ? .on : .off
            stack.addArrangedSubview(control)
            stack.addArrangedSubview(detail(
                "Runs in the displayed repository order with fresh revalidation."
            ))
        }
        for (index, refusal) in
            card.maintenanceRefusals.enumerated() {
            let unavailable = detail(refusal)
            unavailable.textColor =
                .secondaryLabelColor
            maintenanceUnavailableRows[
                "\(card.id):\(index)"
            ] = unavailable
            stack.addArrangedSubview(unavailable)
        }
        let cleanup = cleanupInspectionSection(for: card)
        stack.addArrangedSubview(cleanup)
        stack.addArrangedSubview(
            diagnosticsDisclosure(for: card)
        )
        for row in stack.arrangedSubviews {
            row.trailingAnchor.constraint(
                lessThanOrEqualTo: stack.trailingAnchor
            ).isActive = true
        }

        let content = box.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor
            ),
            stack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor
            ),
            stack.topAnchor.constraint(
                equalTo: content.topAnchor
            ),
            stack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor
            ),
            cleanup.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
        ])
        return box
    }

    private func fileStateSummary(
        _ worktree: Worktree
    ) -> String {
        guard worktree.verification == .verified else {
            return "Unknown"
        }
        if worktree.fileState?.operationState == .busy {
            return "Busy"
        }
        switch worktree.cleanliness {
        case .clean: return "Clean"
        case .dirty: return "Dirty"
        case .unknown: return "Unknown"
        }
    }

    private func cleanupInspectionSection(
        for card: RepositoryCard
    ) -> NSView {
        let group = NSBox()
        group.boxType = .custom
        group.borderColor = .separatorColor
        group.borderWidth = 1
        group.cornerRadius = 6
        group.fillColor =
            ShadowSyncAppColors.cleanupInspectionPanelFill

        let section = NSStackView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5
        section.addArrangedSubview(
            sectionTitle("Optional cleanup inspection")
        )
        let state = cleanupStates[card.id]
            ?? .notInspected
        switch state {
        case .notInspected:
            section.addArrangedSubview(detail(
                "Not inspected. Repository actions above are complete; cleanup metadata is loaded only on request."
            ))
        case .inspecting:
            let progress = cleanupProgress[card.id]
                ?? CleanupInspectionProgress(
                    repositoryID: card.id,
                    repositoryCompleted: 0,
                    repositoryTotal: 1,
                    stage: .topology,
                    completed: 0,
                    total: 1
                )
            let indicator = inspectionProgressIndicator(
                progress
            )
            cleanupProgressIndicators[card.id] = indicator
            section.addArrangedSubview(indicator)
            let status = detail(cleanupProgressText(progress))
            status.textColor = .systemBlue
            status.setAccessibilityLabel(
                "Cleanup inspection progress for \(card.id)"
            )
            cleanupProgressLabels[card.id] = status
            section.addArrangedSubview(status)
        case .inspected:
            section.addArrangedSubview(
                terminalInspectionProgress(for: card.id)
            )
            section.addArrangedSubview(detail(
                "Inspection complete. Expand cached results below."
            ))
            for clone in card.clones {
                section.addArrangedSubview(
                    cloneDisclosure(clone, card: card)
                )
            }
        case .cancelled:
            section.addArrangedSubview(
                terminalInspectionProgress(for: card.id)
            )
            let warning = detail(
                "Inspection cancelled. Completed evidence remains visible; unfinished candidates are retained."
            )
            warning.textColor = .secondaryLabelColor
            section.addArrangedSubview(warning)
            for clone in card.clones {
                section.addArrangedSubview(
                    cloneDisclosure(clone, card: card)
                )
            }
        case let .issues(message):
            section.addArrangedSubview(
                terminalInspectionProgress(for: card.id)
            )
            let warning = detail(
                "Cleanup inspection completed with issues: \(message)"
            )
            warning.textColor = .systemOrange
            section.addArrangedSubview(warning)
            for clone in card.clones {
                section.addArrangedSubview(
                    cloneDisclosure(clone, card: card)
                )
            }
        case let .failed(message):
            section.addArrangedSubview(
                terminalInspectionProgress(for: card.id)
            )
            let warning = detail(
                "Cleanup inspection failed: \(message)"
            )
            warning.textColor = .systemRed
            section.addArrangedSubview(warning)
        }
        let button = NSButton(
            title: state == .notInspected
                ? "Inspect branches & worktrees"
                : "Reinspect branches & worktrees",
            target: self,
            action: #selector(inspectCleanup(_:))
        )
        button.isHidden = state == .inspecting
        button.alignment = .left
        cleanupButtons[ObjectIdentifier(button)] =
            card.id
        section.addArrangedSubview(button)
        for row in section.arrangedSubviews {
            row.trailingAnchor.constraint(
                lessThanOrEqualTo:
                    section.trailingAnchor
            ).isActive = true
        }

        let content = group.contentView!
        content.addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: 10
            ),
            section.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -10
            ),
            section.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: 8
            ),
            section.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -8
            ),
        ])
        return group
    }

    private func terminalInspectionProgress(
        for repositoryID: String
    ) -> NSProgressIndicator {
        let progress = cleanupProgress[repositoryID]
            ?? CleanupInspectionProgress(
                repositoryID: repositoryID,
                repositoryCompleted: 1,
                repositoryTotal: 1,
                stage: .candidateAssembly,
                completed: 1,
                total: 1
            )
        let indicator = inspectionProgressIndicator(progress)
        return indicator
    }

    private func cleanupBatchProgressView() -> NSView {
        let group = NSBox()
        group.boxType = .custom
        group.borderColor = .separatorColor
        group.borderWidth = 1
        group.cornerRadius = 6
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(
            sectionTitle("Inspection progress")
        )
        let overall = NSProgressIndicator()
        overall.style = .bar
        overall.isIndeterminate = false
        overall.minValue = 0
        overall.maxValue = Double(
            max(1, cleanupBatchRepositoryIDs.count)
        )
        overall.setAccessibilityLabel(
            "Overall repository inspection progress"
        )
        cleanupBatchOverallIndicator = overall
        stack.addArrangedSubview(overall)
        let overallLabel = detail("")
        cleanupBatchOverallLabel = overallLabel
        stack.addArrangedSubview(overallLabel)
        for id in cleanupBatchRepositoryIDs {
            let state = cleanupStates[id] ?? .notInspected
            let label = detail(
                "\(id) · \(cleanupBatchRowText(id: id, state: state))"
            )
            label.maximumNumberOfLines = 2
            label.setAccessibilityLabel(
                "Repository inspection status for \(id)"
            )
            cleanupProgressLabels["batch:\(id)"] = label
            stack.addArrangedSubview(label)
        }
        let content = group.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: 10
            ),
            stack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -10
            ),
            stack.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: 8
            ),
            stack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -8
            ),
            overall.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ),
        ])
        updateBatchProgressPresentation()
        return group
    }

    private func inspectionProgressIndicator(
        _ progress: CleanupInspectionProgress
    ) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.setAccessibilityLabel(
            "Current inspection stage progress"
        )
        configure(indicator, progress: progress)
        return indicator
    }

    private func configure(
        _ indicator: NSProgressIndicator,
        progress: CleanupInspectionProgress
    ) {
        indicator.minValue = 0
        indicator.maxValue = Double(max(1, progress.total))
        indicator.doubleValue = Double(
            min(progress.completed, max(1, progress.total))
        )
    }

    private func cleanupProgressText(
        _ progress: CleanupInspectionProgress
    ) -> String {
        let stage: String
        switch progress.stage {
        case .topology:
            stage = "Reading repository topology"
        case .worktreeEvidence:
            stage = "Reading worktree evidence"
        case .branchRelations:
            stage = "Comparing branches"
        case .pullRequestEvidence:
            stage = "Checking pull requests"
        case .candidateAssembly:
            stage = "Building cleanup candidates"
        }
        let count = progress.total > 0
            ? " \(progress.completed)/\(progress.total)"
            : ""
        let partial = progress.partialCount > 0
            ? " · \(progress.partialCount) unavailable"
            : ""
        return stage + count + partial
    }

    private func cleanupBatchRowText(
        id: String,
        state: CleanupInspectionState
    ) -> String {
        switch state {
        case .notInspected:
            return "Not inspected"
        case .inspecting:
            return cleanupProgress[id].map(
                cleanupProgressText
            ) ?? "Waiting"
        case .inspected:
            return "Complete"
        case .cancelled:
            return "Cancelled"
        case .issues:
            return "Complete with issues"
        case .failed:
            return "Failed"
        }
    }

    private func updateBatchProgressPresentation() {
        guard !cleanupBatchRepositoryIDs.isEmpty else { return }
        let terminal = cleanupBatchRepositoryIDs.filter {
            switch cleanupStates[$0] {
            case .inspected?, .issues?, .failed?, .cancelled?:
                return true
            default: return false
            }
        }.count
        cleanupBatchOverallIndicator?.doubleValue =
            Double(terminal)
        cleanupBatchOverallLabel?.stringValue =
            "\(terminal) of \(cleanupBatchRepositoryIDs.count) repositories complete"
        for id in cleanupBatchRepositoryIDs {
            guard let label =
                    cleanupProgressLabels["batch:\(id)"] else {
                continue
            }
            let state = cleanupStates[id] ?? .notInspected
            label.stringValue =
                "\(id) · \(cleanupBatchRowText(id: id, state: state))"
        }
    }

    private func diagnosticsDisclosure(
        for card: RepositoryCard
    ) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 3
        let title = "Technical diagnostics"
        let toggle = NSButton(
            title: title + " ▸",
            target: self,
            action: #selector(toggleCloneDisclosure(_:))
        )
        toggle.isBordered = false
        toggle.alignment = .left
        let details = NSStackView()
        details.orientation = .vertical
        details.alignment = .width
        details.spacing = 3
        details.isHidden = true
        for clone in card.clones {
            details.addArrangedSubview(detail(
                "Clone \(clone.id) · root \(clone.primaryRoot)"
            ))
            for worktree in clone.worktrees {
                details.addArrangedSubview(detail(
                    "Worktree \(worktree.id) · \(worktree.path) · root \(worktree.rootIdentity.map { "\($0.device):\($0.inode)" } ?? "unverified") · registration \(worktree.registrationIdentity.map { "\($0.device):\($0.inode)" } ?? "none")"
                ))
            }
            for branch in clone.branches {
                details.addArrangedSubview(detail(
                    "Ref \(branch.fullRef) · \(shortOID(branch.tipOID)) · claims \(branch.claimingWorktreeIDs.joined(separator: ", "))"
                ))
            }
            for warning in clone.warnings {
                details.addArrangedSubview(detail(
                    "Evidence: \(warning)"
                ))
            }
        }
        for operation in (
            [card.fastForward].compactMap { $0 }
                + card.maintenanceOperations
        ) {
            details.addArrangedSubview(detail(
                "Operation \(operation.id) · \(operation.consequence) · evidence \(operation.evidenceDigest)"
            ))
        }
        for diagnostic in
            card.maintenanceDiagnostics ?? [] {
            details.addArrangedSubview(detail(
                "Repair evidence: \(diagnostic)"
            ))
        }
        for candidate in removalCandidates
            where candidate.repository.id == card.id {
            if let recovery =
                    candidate.preview.recoveryConsequence {
                details.addArrangedSubview(detail(
                    "Cleanup \(candidate.id) · recovery: \(recovery)"
                ))
            }
            if let override =
                    candidate.preview.overrideConsequence {
                details.addArrangedSubview(detail(
                    "Cleanup \(candidate.id) · override: \(override)"
                ))
            }
        }
        container.addArrangedSubview(toggle)
        container.addArrangedSubview(details)
        cloneDisclosures[ObjectIdentifier(toggle)] =
            (details, title)
        return container
    }

    private func cloneDisclosure(
        _ clone: LocalClone,
        card: RepositoryCard
    ) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 4
        let defaultRef =
            card.repository.resolvedDefault?.localRef
        let hiddenWorktreeIDs = Set(
            clone.worktrees.filter {
                $0.isPrimary
                    || $0.attachedBranchRef == defaultRef
            }.map(\.id)
        )
        let cleanupWorktrees = clone.worktrees.filter {
            !hiddenWorktreeIDs.contains($0.id)
        }
        let cleanupBranches = clone.branches.filter {
            $0.fullRef != defaultRef
        }
        let title =
            "Cleanup candidates · \(clone.primaryRoot) · \(cleanupWorktrees.count) worktree\(cleanupWorktrees.count == 1 ? "" : "s") · \(cleanupBranches.count) branch\(cleanupBranches.count == 1 ? "" : "es")"
        let toggle = NSButton(
            title: title + " ▸",
            target: self,
            action: #selector(toggleCloneDisclosure(_:))
        )
        toggle.isBordered = false
        toggle.alignment = .left
        toggle.font = .systemFont(ofSize: 12, weight: .medium)
        container.addArrangedSubview(toggle)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 5
        stack.isHidden = true
        container.addArrangedSubview(stack)
        NSLayoutConstraint.activate([
            toggle.widthAnchor.constraint(
                equalTo: container.widthAnchor
            ),
            stack.widthAnchor.constraint(
                equalTo: container.widthAnchor
            ),
        ])
        cloneDisclosures[ObjectIdentifier(toggle)] = (stack, title)
        if cleanupWorktrees.isEmpty
            && cleanupBranches.isEmpty {
            stack.addArrangedSubview(detail(
                "No cleanup candidates. The canonical checkout and default branch remain protected at repository level."
            ))
        }
        let attachedBranches = Set(
            cleanupWorktrees.compactMap(
                \.attachedBranchRef
            )
        )
        if !cleanupWorktrees.isEmpty {
            stack.addArrangedSubview(
                sectionTitle(
                    "Worktrees and attached branches"
                )
            )
        }
        for worktree in cleanupWorktrees {
            let attachment = worktree.attachedBranchRef.map {
                shortBranch($0)
            } ?? "Detached @ \(shortOID(worktree.detachedOID))"
            let removal = removalCandidates.first {
                $0.worktree?.id == worktree.id
                    && $0.clone.id == clone.id
                    && $0.repository.id == card.id
            }
            stack.addArrangedSubview(
                worktreeCleanupView(
                    worktree,
                    attachment: attachment,
                    candidate: removal
                )
            )
            if let branchRef = worktree.attachedBranchRef,
               let branch = cleanupBranches.first(where: {
                   $0.fullRef == branchRef
               }) {
                stack.addArrangedSubview(
                    insetCandidateView(
                        branchCleanupView(
                            branch,
                            clone: clone,
                            card: card
                        )
                    )
                )
            }
        }
        let standaloneBranches =
            cleanupBranches.filter {
                !attachedBranches.contains($0.fullRef)
            }
        if !standaloneBranches.isEmpty {
            stack.addArrangedSubview(
                sectionTitle("Branches not checked out")
            )
        }
        for branch in standaloneBranches {
            stack.addArrangedSubview(
                branchCleanupView(
                    branch,
                    clone: clone,
                    card: card
                )
            )
        }
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ).isActive = true
        }
        return container
    }

    private func branchCleanupView(
        _ branch: Branch,
        clone: LocalClone,
        card: RepositoryCard
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let removal = removalCandidates.first {
            $0.branch?.id == branch.id
                && $0.clone.id == clone.id
                && $0.repository.id == card.id
        }
        stack.addArrangedSubview(
            removalIdentityRow(
                kind: .branch,
                title: branch.name,
                candidate: removal
            )
        )
        if let upstream = branch.upstream {
            let label: String
            switch upstream.relation {
            case .equal: label = "Published"
            case .ahead: label = "Ahead"
            case .behind, .diverged: label = "Unknown"
            case .unavailable: label = "Unknown"
            }
            stack.addArrangedSubview(
                labeledCandidateDetail(
                    label: "Upstream provenance",
                    value: label
                )
            )
        } else if removal?.preview.recommendation
                    != .recommended {
            stack.addArrangedSubview(
                labeledCandidateDetail(
                    label: "Upstream provenance",
                    value: "Not published"
                )
            )
        }
        if branch.pullRequestAvailability == .unavailable {
            stack.addArrangedSubview(detail(
                "Pull-request notes: Evidence is unavailable; this candidate remains retained."
            ))
        } else {
            for pullRequest in branch.pullRequests ?? [] {
                stack.addArrangedSubview(
                    pullRequestLink(pullRequest)
                )
            }
        }
        if let removal {
            stack.addArrangedSubview(
                removalControlView(removal)
            )
        }
        return candidateSubcard(containing: stack)
    }

    private func worktreeCleanupView(
        _ worktree: Worktree,
        attachment: String,
        candidate: RemovalCandidate?
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(
            removalIdentityRow(
                kind: .worktree,
                title: "\(worktree.path) · \(attachment)",
                candidate: candidate
            )
        )
        stack.addArrangedSubview(
            labeledCandidateDetail(
                label: "Worktree state",
                value: fileStateSummary(worktree)
            )
        )
        stack.addArrangedSubview(awaSummary(worktree))
        if let candidate {
            stack.addArrangedSubview(
                removalControlView(candidate)
            )
        }
        return candidateSubcard(containing: stack)
    }

    private func candidateSubcard(
        containing stack: NSStackView
    ) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 6
        box.contentViewMargins = .zero
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(
                equalTo: stack.widthAnchor
            ).isActive = true
        }
        let content = box.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: 10
            ),
            stack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -10
            ),
            stack.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: 8
            ),
            stack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -8
            ),
        ])
        #if SHADOW_SYNC_TESTING
        testingCleanupCandidateCards.append(box)
        #endif
        return box
    }

    private func insetCandidateView(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: 18
            ),
            view.trailingAnchor.constraint(
                equalTo: container.trailingAnchor
            ),
            view.topAnchor.constraint(
                equalTo: container.topAnchor
            ),
            view.bottomAnchor.constraint(
                equalTo: container.bottomAnchor
            ),
        ])
        return container
    }

    private func labeledCandidateDetail(
        label: String,
        value: String
    ) -> NSTextField {
        let field = detail("\(label): \(value)")
        field.maximumNumberOfLines = 3
        return field
    }

    private func awaSummary(
        _ worktree: Worktree
    ) -> NSTextField {
        let awa = worktree.awaEvidence
        let managed =
            worktree.locationKind == .awaManaged
                || awa?.state != .notManaged
        let registration: String
        switch awa?.state {
        case .active, .stale, .dead, .untracked:
            registration = "Valid"
        case .unavailable:
            registration =
                awa?.explanation.contains("inconsistent") == true
                    || awa?.explanation.contains(
                        "no verifiable lease"
                    ) == true
                ? "Invalid" : "Unknown"
        case .notManaged, nil:
            registration = "Unknown"
        }
        let heartbeat: String
        if let value = awa?.lastHeartbeatAt,
           let date = ISO8601DateFormatter().date(
               from: value
           ) {
            heartbeat =
                RelativeDateTimeFormatter().localizedString(
                    for: date,
                    relativeTo: Date()
                )
        } else {
            heartbeat = "Unknown"
        }
        let field = detail(
            "AWA / recovery notes: \(managed ? "Managed" : "Unmanaged") · registration \(registration) · heartbeat \(heartbeat)"
        )
        if awa?.blocksRemoval == true {
            field.textColor = .systemOrange
        }
        return field
    }

    private func makeProtectedCard(_ card: RepositoryCard) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 12, height: 8)
        let text = detail(
            "\(card.id) · \(card.repository.policyCategory.operatorLabel) · \(card.clones.count) clone(s) · lifecycle controls unavailable"
        )
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        box.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        let content = box.contentView!
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(
                equalTo: content.leadingAnchor
            ),
            text.trailingAnchor.constraint(
                equalTo: content.trailingAnchor
            ),
            text.topAnchor.constraint(
                equalTo: content.topAnchor
            ),
            text.bottomAnchor.constraint(
                equalTo: content.bottomAnchor
            ),
            box.heightAnchor.constraint(
                greaterThanOrEqualTo:
                    text.heightAnchor,
                constant: 16
            ),
        ])
        return box
    }

    private func operationTitle(
        _ operation: PlannedOperation
    ) -> String {
        switch operation.kind {
        case .fastForward:
            return operation.target.mode == .refOnly
                ? "Fast-forward default ref (no worktree)"
                : "Fast-forward default branch"
        case .repairPruneRegistrations:
            let count: Int
            if case let .prune(items)? =
                operation.maintenanceEvidence {
                count = items.count
            } else {
                count = 0
            }
            return
                "Repair: prune \(count) exact stale registration\(count == 1 ? "" : "s")"
        case .repairMovedWorktree:
            if case let .repairMoved(item)? =
                operation.maintenanceEvidence {
                return
                    "Repair: reconnect moved worktree \(item.verifiedPath)"
            }
            return "Repair: moved worktree unavailable"
        case .initializeDefaultBranch:
            return
                "Initialize: create local \(operation.target.resolvedDefault.name)"
        }
    }

    private func removalIdentityRow(
        kind: RemovalEntityKind,
        title: String,
        candidate: RemovalCandidate?
    ) -> NSView {
        let snapshot = candidate.map {
            RemovalCardPresentationSnapshot(candidate: $0)
        }
        let accent = snapshot?.accent
            ?? (kind == .worktree ? .teal : .purple)
        let accentColor: NSColor =
            accent == .teal ? .systemTeal : .systemIndigo
        let symbolName = snapshot?.identitySystemSymbol
            ?? (
                kind == .worktree
                    ? "folder" : "arrow.triangle.branch"
            )
        let symbolNames = [symbolName]
            + (
                snapshot?.secondaryIdentitySystemSymbol
                    .map { [$0] } ?? []
            )
        let icon: NSView
        let symbolViews = symbolNames.enumerated()
            .compactMap { index, name -> NSImageView? in
                guard let image = NSImage(
                    systemSymbolName: name,
                    accessibilityDescription:
                        kind.operatorLabel
                )?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(
                        pointSize: index == 0 ? 16 : 10,
                        weight: .semibold
                    )
                ) else {
                    return nil
                }
                let imageView = NSImageView(image: image)
                imageView.contentTintColor = accentColor
                return imageView
            }
        if symbolViews.count == symbolNames.count {
            let symbols = NSStackView(views: symbolViews)
            symbols.orientation = .horizontal
            symbols.spacing = 1
            icon = symbols
        } else {
            let fallback = NSTextField(
                labelWithString:
                    snapshot?.identityGlyph
                        ?? (
                            kind == .worktree
                                ? "▱" : "⑂"
                        )
            )
            fallback.font = .systemFont(
                ofSize: 18,
                weight: .semibold
            )
            fallback.textColor = accentColor
            icon = fallback
        }
        let type = detail(
            snapshot?.identityLabel
                ?? (kind == .worktree ? "WORKTREE" : "BRANCH")
        )
        type.font = .systemFont(ofSize: 11, weight: .semibold)
        type.textColor = .secondaryLabelColor
        let identity = NSTextField(
            wrappingLabelWithString: title
        )
        identity.font = .systemFont(ofSize: 14, weight: .semibold)
        identity.textColor = accentColor
        identity.alignment = .left
        identity.maximumNumberOfLines = 2
        identity.lineBreakMode = .byCharWrapping
        identity.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        identity.setAccessibilityLabel(
            "\(kind.operatorLabel) \(title)"
        )
        let badge = NSButton(
            title: candidate?.hardExclusion == nil
                ? (
                    candidate?.preview.recommendation
                        == .keep
                        ? "Keep recommended"
                        : (
                            snapshot?.recommendationLabel
                                ?? "Protected"
                        )
                )
                : "Protected — cannot remove",
            target: nil,
            action: nil
        )
        badge.bezelStyle = .inline
        badge.isEnabled = false
        badge.setContentHuggingPriority(
            .required,
            for: .horizontal
        )
        let typeSpacer = NSView()
        typeSpacer.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        typeSpacer.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let typeRow = NSStackView(
            views: [icon, type, typeSpacer]
        )
        typeRow.orientation = .horizontal
        typeRow.alignment = .centerY
        typeRow.distribution = .fill
        typeRow.spacing = 5
        type.setContentHuggingPriority(
            .required,
            for: .horizontal
        )
        let stack = NSStackView(
            views: [typeRow, identity, badge]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        identity.widthAnchor.constraint(
            equalTo: stack.widthAnchor
        ).isActive = true
        #if SHADOW_SYNC_TESTING
        testingCleanupCandidateIdentities.append(identity)
        testingCleanupCandidateTypeRows.append(typeRow)
        #endif
        return stack
    }

    private func removalControlView(
        _ candidate: RemovalCandidate
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        removalsByID[candidate.id] = candidate

        if let exclusion = candidate.hardExclusion {
            stack.addArrangedSubview(
                labeledCandidateDetail(
                    label: "Available actions",
                    value:
                        "Protected — cannot remove · \(exclusion)"
                )
            )
            return stack
        }

        stack.addArrangedSubview(
            sectionTitle("Available actions")
        )

        let button = NSButton(
            checkboxWithTitle:
                RemovalCardPresentationSnapshot(
                    candidate: candidate
                ).actionLabel,
            target: self,
            action: #selector(removalSelectionChanged(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(
            candidate.id
        )
        button.isEnabled =
            candidate.canSelect
                || dependenciesSatisfied(for: candidate)
        button.state = selectedRemovalIDs.contains(candidate.id)
            ? .on : .off
        removalButtons[candidate.id] = button
        stack.addArrangedSubview(button)

        if candidate.requiresRecoveryAttempt
            && candidate.dependencies.isEmpty {
            let secret = NSButton(
                checkboxWithTitle:
                    "Include possible secrets in protected recovery copy",
                target: self,
                action:
                    #selector(secretSelectionChanged(_:))
            )
            secret.identifier =
                NSUserInterfaceItemIdentifier(
                    candidate.id
                )
            secret.toolTip =
                "Private local artifact only; never uploaded, previewed, expired, or garbage-collected."
            secretButtons[candidate.id] = secret
            stack.addArrangedSubview(secret)
        }

        let recommendation = NSBox()
        recommendation.boxType = .custom
        recommendation.borderColor = .separatorColor
        recommendation.borderWidth = 1
        recommendation.cornerRadius = 5
        recommendation.fillColor =
            ShadowSyncAppColors.cleanupInspectionPanelFill
        let recommendationText = detail(
            "Recommendation: \(candidate.preview.recommendation.operatorLabel) · \(concreteCleanupReason(candidate))"
        )
        recommendationText.translatesAutoresizingMaskIntoConstraints = false
        recommendation.contentView?.addSubview(recommendationText)
        if let content = recommendation.contentView {
            NSLayoutConstraint.activate([
                recommendationText.leadingAnchor.constraint(
                    equalTo: content.leadingAnchor,
                    constant: 8
                ),
                recommendationText.trailingAnchor.constraint(
                    equalTo: content.trailingAnchor,
                    constant: -8
                ),
                recommendationText.topAnchor.constraint(
                    equalTo: content.topAnchor,
                    constant: 6
                ),
                recommendationText.bottomAnchor.constraint(
                    equalTo: content.bottomAnchor,
                    constant: -6
                ),
            ])
        }
        stack.addArrangedSubview(recommendation)
        recommendation.widthAnchor.constraint(
            equalTo: stack.widthAnchor
        ).isActive = true
        if !candidate.dependencies.isEmpty {
            stack.addArrangedSubview(detail(
                "Relevant notes: Select every removable claiming worktree first; ShadowSync will remove those worktrees before this branch and revalidate each step."
            ))
        }
        return stack
    }

    private func concreteCleanupReason(
        _ candidate: RemovalCandidate
    ) -> String {
        let explanation = candidate.preview.explanation
        if explanation.contains("evidence is incomplete") {
            if candidate.kind == .worktree {
                if candidate.worktree?.fileState == nil {
                    return
                        "file and operation-state proof is unavailable."
                }
                if candidate.worktree?.awaEvidence == nil {
                    return
                        "AWA management proof is unavailable."
                }
            } else if candidate.branch?.tipOID == nil {
                return "the branch tip could not be verified."
            } else if candidate.branch?.relationToDefault == nil {
                return
                    "default-branch ancestry proof is unavailable."
            }
        }
        return explanation
    }

    private func dependenciesSatisfied(
        for candidate: RemovalCandidate
    ) -> Bool {
        guard !candidate.dependencies.isEmpty,
              candidate.hardExclusion == nil else {
            return false
        }
        return candidate.dependencies.allSatisfy {
            worktreeID in
            guard let dependency =
                    removalCandidates.first(where: {
                        $0.worktree?.id == worktreeID
                    }),
                  dependency.hardExclusion == nil,
                  dependency.canSelect else {
                return false
            }
            return selectedRemovalIDs.contains(
                dependency.id
            )
        }
    }

    private func pullRequestLink(
        _ pullRequest: PullRequestRecord
    ) -> NSTextField {
        let icon: String
        switch pullRequest.state {
        case .draft: icon = "◌"
        case .open: icon = "●"
        case .merged: icon = "◆"
        case .closed: icon = "○"
        }
        let title =
            "\(icon) PR #\(pullRequest.number) · \(pullRequest.state.operatorLabel) · updated \(pullRequest.updatedAt)"
        let attributed = NSMutableAttributedString(
            string: title
        )
        if let url = URL(string: pullRequest.url) {
            attributed.addAttribute(
                .link,
                value: url,
                range: NSRange(
                    location: 0,
                    length: attributed.length
                )
            )
        }
        let field = NSTextField(labelWithAttributedString: attributed)
        field.font = .systemFont(ofSize: 12)
        let stateColor: NSColor
        switch RemovalPullRequestAccent(pullRequest.state) {
        case .draft: stateColor = .secondaryLabelColor
        case .open: stateColor = .systemGreen
        case .merged: stateColor = .systemPurple
        case .closed: stateColor = .systemRed
        }
        attributed.addAttribute(
            .foregroundColor,
            value: stateColor,
            range: NSRange(
                location: 0,
                length: attributed.length
            )
        )
        field.attributedStringValue = attributed
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        return field
    }

    private func shortOID(_ oid: String?) -> String {
        oid.map { String($0.prefix(12)) } ?? "Unavailable"
    }

    private func addCanonicalChooser(
        for card: RepositoryCard,
        to stack: NSStackView
    ) {
        let clones = card.clones.filter(\.isAuthorityEligible)
        guard !clones.isEmpty else { return }
        let menu = NSPopUpButton()
        for clone in clones {
            menu.addItem(withTitle: clone.primaryRoot)
        }
        let choose = NSButton(
            title: "Choose canonical root…",
            target: self,
            action: #selector(chooseCanonicalRoot(_:))
        )
        choose.bezelStyle = .rounded
        choose.setContentHuggingPriority(
            .required,
            for: .horizontal
        )
        menu.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        canonicalMenus[ObjectIdentifier(choose)] = (card, menu)
        canonicalControls.append(contentsOf: [menu, choose])
        menu.isEnabled = authorityControlsEnabled
        choose.isEnabled = authorityControlsEnabled
        let row = NSStackView(views: [menu, choose])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillProportionally
        stack.addArrangedSubview(row)
    }

    private func configureReferences(in document: NSStackView) {
        let references = inventory.cards.filter(\.isReference)
        guard !references.isEmpty else { return }
        referencesToggle.title =
            "References (\(references.count)) ▸"
        referencesToggle.isBordered = false
        referencesToggle.alignment = .left
        referencesToggle.target = self
        referencesToggle.action = #selector(toggleReferences)
        document.addArrangedSubview(referencesToggle)
        referencesStack.orientation = .vertical
        referencesStack.alignment = .leading
        referencesStack.spacing = 3
        referencesStack.isHidden = true
        for card in references {
            referencesStack.addArrangedSubview(detail(
                "\(card.id) · reference only · "
                    + card.clones.map(\.primaryRoot)
                        .joined(separator: ", ")
            ))
        }
        document.addArrangedSubview(referencesStack)
        referencesStack.widthAnchor.constraint(
            equalTo: document.widthAnchor,
            constant: -20
        ).isActive = true
    }

    private func canonicalClone(for card: RepositoryCard) -> LocalClone? {
        guard let record = card.authority.record else { return nil }
        return card.clones.first(where: record.matches)
    }

    private func detail(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.alignment = .left
        field.maximumNumberOfLines = 3
        return field
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .boldSystemFont(ofSize: 13)
        field.textColor = .labelColor
        field.alignment = .left
        return field
    }

    private func shortBranch(_ reference: String) -> String {
        String(reference.dropFirst("refs/heads/".count))
    }

    @objc private func operationSelectionChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            selectedOperationIDs.insert(id)
        } else {
            selectedOperationIDs.remove(id)
        }
        refreshSelectionStatus()
    }

    @objc private func selectAllOperations() {
        selectedOperationIDs = Set(
            inventory.cards.flatMap { card in
                (
                    [card.fastForward].compactMap { $0 }
                        + card.maintenanceOperations
                ).filter(\.isSelectable).map(\.id)
            }
        )
        for (id, button) in operationButtons {
            button.state = selectedOperationIDs.contains(id)
                ? .on : .off
        }
        refreshSelectionStatus()
    }

    @objc private func selectAllRecommendedRemoval() {
        let inspected =
            successfulCleanupInspectionRepositoryIDs
        for candidate in removalCandidates where
            candidate.selectAllEligible
                && inspected.contains(candidate.repository.id) {
            guard let button =
                    removalButtons[candidate.id] else {
                continue
            }
            selectedRemovalIDs.insert(candidate.id)
            button.state = .on
        }
        refreshSelectionStatus()
    }

    @objc private func removalSelectionChanged(
        _ sender: NSButton
    ) {
        guard let id = sender.identifier?.rawValue,
              let candidate = removalsByID[id],
              candidate.canSelect
                || dependenciesSatisfied(
                    for: candidate
                ) else {
            sender.state = .off
            return
        }
        if sender.state == .on {
            selectedRemovalIDs.insert(id)
        } else {
            selectedRemovalIDs.remove(id)
        }
        refreshDependencyControls()
        refreshSelectionStatus()
    }

    private func refreshDependencyControls() {
        for candidate in removalCandidates
            where !candidate.dependencies.isEmpty {
            guard let button =
                    removalButtons[candidate.id] else {
                continue
            }
            let enabled =
                dependenciesSatisfied(for: candidate)
            button.isEnabled = enabled
            button.title = enabled
                ? "Remove after selected Worktrees"
                : "Remove claiming Worktrees first"
            if !enabled {
                button.state = .off
                selectedRemovalIDs.remove(
                    candidate.id
                )
            }
        }
    }

    @objc private func secretSelectionChanged(
        _ sender: NSButton
    ) {
        guard sender.identifier?.rawValue != nil else {
            sender.state = .off
            return
        }
        refreshSelectionStatus()
    }

    @objc private func clearAllOperations() {
        selectedOperationIDs.removeAll()
        selectedRemovalIDs.removeAll()
        for button in operationButtons.values {
            button.state = .off
        }
        for button in removalButtons.values {
            button.state = .off
        }
        for button in secretButtons.values {
            button.state = .off
        }
        refreshSelectionStatus()
    }

    @objc private func toggleReferences() {
        referencesStack.isHidden.toggle()
        referencesToggle.title =
            "References (\(inventory.referenceCards.count)) "
                + (referencesStack.isHidden ? "▸" : "▾")
    }

    @objc private func toggleCloneDisclosure(_ sender: NSButton) {
        guard let (stack, title) =
                cloneDisclosures[ObjectIdentifier(sender)] else {
            return
        }
        stack.isHidden.toggle()
        sender.title = title + (stack.isHidden ? " ▸" : " ▾")
    }

    @objc private func inspectCleanup(
        _ sender: NSButton
    ) {
        guard let id =
                cleanupButtons[ObjectIdentifier(sender)],
              cleanupStates[id] != .inspecting else {
            return
        }
        onInspectCleanup?([id])
    }

    @objc private func inspectAllCleanup() {
        let ids = Set(
            inventory.writableCards.map(\.id).filter {
                cleanupStates[$0] != .inspecting
            }
        )
        guard !ids.isEmpty else { return }
        onInspectCleanup?(ids)
    }

    @objc private func chooseCanonicalRoot(_ sender: NSButton) {
        guard authorityControlsEnabled else {
            presentInlineMessage(
                "A canonical-root update is already in progress. Wait for it to finish, then confirm again."
            )
            return
        }
        guard let (card, menu) =
                canonicalMenus[ObjectIdentifier(sender)],
              menu.indexOfSelectedItem >= 0 else {
            return
        }
        let clones = card.clones.filter(\.isAuthorityEligible)
        guard menu.indexOfSelectedItem < clones.count else { return }
        onChooseCanonicalRoot?(card, clones[menu.indexOfSelectedItem])
    }

    @objc private func reviewOperations() {
        let operations = inventory.selectableOperations.filter {
            selectedOperationIDs.contains($0.id)
        }
        let removals = selectedRemovalIDs.compactMap {
            removalsByID[$0]
        }.map { candidate in
            let intent: RemovalSelectionIntent
            switch candidate.preview.recommendation {
            case .recommended:
                intent = .remove
            case .recovery:
                intent = .removeWithRecovery
            case .keep:
                intent = .removeAnyway
            case .override:
                intent = .operatorOverride
            case .hardExcluded:
                intent = .operatorOverride
            }
            return try? RemovalSelection(
                candidate: candidate,
                intent: intent,
                includePossibleSecrets:
                    secretButtons[candidate.id]?.state == .on,
                dependenciesSatisfied:
                    dependenciesSatisfied(
                        for: candidate
                    )
            )
        }.compactMap { $0 }.sorted {
            $0.candidate.id < $1.candidate.id
        }
        guard !operations.isEmpty || !removals.isEmpty else {
            return
        }
        if let onReviewBatch {
            onReviewBatch(operations, removals)
        } else if removals.isEmpty {
            onReviewOperations?(operations)
        }
    }

    @objc private func cancelCards() {
        isClosingFromAction = true
        close()
        notifyClosed()
    }

    private func notifyClosed() {
        guard !closeNotified else { return }
        closeNotified = true
        onCancel?()
    }

    private func refreshSelectionStatus() {
        let operationCount = selectedOperationIDs.count
        let removalCount = selectedRemovalIDs.count
        let count = operationCount + removalCount
        selectionStatus.textColor = .secondaryLabelColor
        if count == 0,
           successfulCleanupInspectionRepositoryIDs.isEmpty {
            selectionStatus.stringValue =
                "Inspect cleanup for at least one repository before selecting recommended cleanup in bulk. Manual rows and repository operations remain available."
        } else if count == 0 {
            selectionStatus.stringValue =
                "Select explicit operations or inspected cleanup rows to continue. Recommendations never grant permission."
        } else {
            selectionStatus.stringValue =
                "\(operationCount) repository operation\(operationCount == 1 ? "" : "s") and \(removalCount) cleanup row\(removalCount == 1 ? "" : "s") selected; final permission is still pending."
        }
        reviewButton.isEnabled = count > 0
    }

    #if SHADOW_SYNC_TESTING
    var testingRenderingState: String {
        renderingState.rawValue
    }

    var testingContentViewIdentity: ObjectIdentifier? {
        window?.contentView.map(ObjectIdentifier.init)
    }

    var testingContentInstallationCount: Int {
        contentInstallationCount
    }

    var testingLiveActionControlIdentities: [ObjectIdentifier] {
        guard let content = window?.contentView else { return [] }
        return Self.testingControls(in: content)
            .filter { $0.action != nil }
            .map(ObjectIdentifier.init)
    }

    var testingDeactivatedControlsAreUnreachable: Bool {
        !testingDeactivatedControls.isEmpty
            && testingDeactivatedControls.allSatisfy {
                !$0.isEnabled && $0.target == nil && $0.action == nil
            }
    }

    var testingInventoryStatus: String {
        loadingStatus.stringValue
    }

    var testingInventoryRetryVisible: Bool {
        !loadingRetry.isHidden
    }

    func testingActivateInventoryRetry() {
        retryInventory()
    }

    private static func testingControls(in view: NSView) -> [NSControl] {
        let current = (view as? NSControl).map { [$0] } ?? []
        return current + view.subviews.flatMap(testingControls)
    }

    var testingAuthorityControlsEnabled: Bool {
        authorityControlsEnabled
            && canonicalControls.allSatisfy(\.isEnabled)
    }

    var testingCardStatusMessage: String {
        selectionStatus.stringValue
    }

    var testingMaintenanceUnavailableCopy:
        [String] {
        maintenanceUnavailableRows.values
            .map(\.stringValue)
            .sorted()
    }

    var testingMaintenanceUnavailableIsNeutral: Bool {
        !maintenanceUnavailableRows.isEmpty
            && maintenanceUnavailableRows.values
                .allSatisfy {
                    $0.textColor
                        == .secondaryLabelColor
                }
    }

    var testingRecommendedRemovalIDs: Set<String> {
        Set(removalCandidates.filter(\.selectAllEligible).map(\.id))
    }

    var testingSelectedRemovalIDs: Set<String> {
        selectedRemovalIDs
    }

    var testingSelectRecommendedCleanupEnabled: Bool {
        selectRecommendedCleanupButton.isEnabled
    }

    var testingCleanupBatchRows: [String] {
        cleanupBatchRepositoryIDs.compactMap {
            cleanupProgressLabels["batch:\($0)"]?.stringValue
        }
    }

    var testingCleanupBatchCompletedValue: Double? {
        cleanupBatchOverallIndicator?.doubleValue
    }

    var testingManageSelectionEnabled: Bool {
        manageSelectionButton.isEnabled
    }

    var testingAllRemovalControlsDisabled: Bool {
        removalButtons.values.allSatisfy {
            !$0.isEnabled
        }
    }

    var testingCloneDisclosuresAreCollapsed: Bool {
        cloneDisclosures.values.allSatisfy {
            $0.0.isHidden
        }
    }

    func testingSelectAllRecommendedRemoval() {
        selectAllRecommendedRemoval()
    }

    func testingSetCloneDisclosuresExpanded(_ expanded: Bool) {
        for (stack, _) in cloneDisclosures.values {
            stack.isHidden = !expanded
        }
    }

    var testingBetaV09CandidateHierarchyIsAccessible: Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let identities = testingCleanupCandidateIdentities
        let typeRows = testingCleanupCandidateTypeRows
        let cards = testingCleanupCandidateCards
        let enabledActions = removalButtons.values.filter(\.isEnabled)
        return !identities.isEmpty
            && identities.count == cards.count
            && identities.count == typeRows.count
            && identities.contains {
                $0.stringValue.count >= 59
            }
            && identities.allSatisfy {
                $0.alignment == .left
                    && $0.maximumNumberOfLines == 2
                    && !$0.stringValue.isEmpty
                    && ($0.accessibilityLabel() ?? "").contains(
                        $0.stringValue
                    )
                    && $0.frame.width > 0
            }
            && typeRows.allSatisfy {
                $0.arrangedSubviews.count == 3
                    && $0.distribution == .fill
            }
            && cards.allSatisfy {
                $0.frame.width > 0 && $0.frame.height > 0
            }
            && !enabledActions.isEmpty
            && enabledActions.allSatisfy {
                $0.target != nil
                    && $0.action != nil
                    && !$0.title.isEmpty
            }
    }
    #endif
}

final class CanonicalRootConfirmationWindowController:
    NSWindowController, NSWindowDelegate {
    var onConfirm: (([CanonicalAuthorityProposal]) -> Void)?
    var onCancel: (() -> Void)?

    private let proposals: [CanonicalAuthorityProposal]
    private var checkboxes: [String: NSButton] = [:]
    private var isClosingFromAction = false
    private var closeNotified = false

    init(proposals: [CanonicalAuthorityProposal]) {
        self.proposals = proposals
        let height = min(620, max(300, 190 + proposals.count * 54))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 720, height: height
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Confirm canonical roots"
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    var isPresentationOpen: Bool {
        !closeNotified && window != nil
    }

    func windowWillClose(_ notification: Notification) {
        if !isClosingFromAction {
            notifyClosed()
        }
    }

    private func buildContent() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let explanation = NSTextField(wrappingLabelWithString:
            "Confirm which local root ShadowSync may update for each unambiguous repository. This records authority only; it does not fetch or update a repository. Deselecting a row leaves it unchanged."
        )
        explanation.font = .systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor
        root.addArrangedSubview(explanation)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(
            top: 10, left: 10, bottom: 10, right: 10
        )
        rows.translatesAutoresizingMaskIntoConstraints = false
        for proposal in proposals {
            let button = NSButton(
                checkboxWithTitle:
                    "\(proposal.repositoryID)\n\(proposal.canonicalRoot)",
                target: nil,
                action: nil
            )
            button.state = .on
            button.lineBreakMode = .byCharWrapping
            button.cell?.wraps = true
            checkboxes[proposal.repositoryID] = button
            rows.addArrangedSubview(button)
            button.widthAnchor.constraint(
                equalTo: rows.widthAnchor,
                constant: -20
            ).isActive = true
        }
        scroll.documentView = rows
        rows.widthAnchor.constraint(
            equalTo: scroll.contentView.widthAnchor
        ).isActive = true
        root.addArrangedSubview(scroll)

        let cancel = NSButton(
            title: "Not now",
            target: self,
            action: #selector(cancel)
        )
        cancel.bezelStyle = .rounded
        let confirm = NSButton(
            title: "Confirm selected roots",
            target: self,
            action: #selector(confirm)
        )
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, confirm])
        actions.orientation = .horizontal
        actions.spacing = 8
        root.addArrangedSubview(actions)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(
                equalTo: window.contentView!.leadingAnchor,
                constant: 20
            ),
            root.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor,
                constant: -20
            ),
            root.topAnchor.constraint(
                equalTo: window.contentView!.topAnchor,
                constant: 20
            ),
            root.bottomAnchor.constraint(
                equalTo: window.contentView!.bottomAnchor,
                constant: -20
            ),
            explanation.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])
    }

    @objc private func confirm() {
        let selected = proposals.filter {
            checkboxes[$0.repositoryID]?.state == .on
        }
        isClosingFromAction = true
        close()
        onConfirm?(selected)
    }

    @objc private func cancel() {
        isClosingFromAction = true
        close()
        notifyClosed()
    }

    private func notifyClosed() {
        guard !closeNotified else { return }
        closeNotified = true
        onCancel?()
    }

    #if SHADOW_SYNC_TESTING
    func testingActivateCancel() {
        cancel()
    }

    func testingActivateConfirm() {
        confirm()
    }
    #endif
}
