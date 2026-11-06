import AppKit
import OSLog
import ShadowSyncCore

@MainActor
final class Body3GroupedConfirmationWindowController:
    NSWindowController, NSWindowDelegate {
    var onConfirm: ((Set<String>) -> Void)?
    var onCancel: (() -> Void)?

    private var checks: [String: NSButton] = [:]
    private var closingFromAction = false
    private var callbackSettled = false

    init(
        prepared: [PreparedRemoval],
        operations: [PlannedOperation] = []
    ) {
        let window = NSWindow(
            contentRect: WindowFrameContinuity.initialRect(
                size: NSSize(width: 860, height: 660)
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title =
            "Final grouped removal confirmation"
        super.init(window: window)
        window.delegate = self

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        let heading = NSTextField(
            wrappingLabelWithString:
                "Recovery attempts are complete. Retain only rows you deliberately authorize in their final class. Cancel or deselect preserves every source and completed artifact."
        )
        heading.font = .boldSystemFont(ofSize: 14)
        root.addArrangedSubview(heading)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        if !operations.isEmpty {
            let title = NSTextField(labelWithString:
                "Selected prerequisite/update operations (\(operations.count))"
            )
            title.font = .boldSystemFont(ofSize: 13)
            rows.addArrangedSubview(title)
            for operation in operations {
                rows.addArrangedSubview(
                    NSTextField(
                        wrappingLabelWithString:
                            "  \(operation.kind.rawValue) · \(operation.target.repository.id) · exact default \(operation.target.resolvedDefault.name)"
                    )
                )
            }
        }
        for finalClass in [
            RemovalFinalClass.recommended,
            .recoveryBacked,
            .operatorOverrideRisk,
        ] {
            let members = prepared.filter {
                $0.finalClass == finalClass
            }
            guard !members.isEmpty else { continue }
            let title = NSTextField(labelWithString:
                "\(finalClass.operatorLabel) (\(members.count))"
            )
            title.font = .boldSystemFont(ofSize: 13)
            rows.addArrangedSubview(title)
            for item in members {
                let candidate = item.selection.candidate
                let check = NSButton(
                    checkboxWithTitle:
                        "\(candidate.kind.operatorLabel) · \(candidate.target)",
                    target: nil,
                    action: nil
                )
                check.state = .on
                checks[candidate.id] = check
                rows.addArrangedSubview(check)
                let secretResult: String
                if item.artifact != nil {
                    secretResult =
                        "possible-secret payload explicitly included in the private artifact"
                } else if candidate.requiresRecoveryAttempt {
                    secretResult =
                        "payload not archived; recovery remains incomplete"
                } else {
                    secretResult =
                        "payload recovery not required"
                }
                let detail = NSTextField(
                    wrappingLabelWithString: [
                        "  ref/OID: \(candidate.branch?.fullRef ?? candidate.worktree?.attachedBranchRef ?? "detached") @ \(candidate.expectedOID ?? "unknown")",
                        "  recovery: \(item.artifact?.artifactID ?? "none") · \(secretResult)",
                        "  AWA: \(candidate.worktree?.awaEvidence?.state.rawValue ?? "not managed") · \(candidate.kind == .branch ? "branch command: non-force -d or expected-old CAS" : "force: \(item.forceLevel.rawValue)")",
                        "  consequence: \(item.consequence)",
                        item.historyLossAccepted
                            ? "  HISTORY LOSS AUTHORIZATION: unique local history may become unreachable."
                            : "  History/file preservation follows the displayed verified sink or artifact.",
                    ].joined(separator: "\n")
                )
                detail.font = .systemFont(ofSize: 11)
                detail.textColor =
                    finalClass == .operatorOverrideRisk
                        ? .systemRed : .secondaryLabelColor
                detail.maximumNumberOfLines = 8
                rows.addArrangedSubview(detail)
            }
        }
        scroll.documentView = rows
        root.addArrangedSubview(scroll)

        let cancel = NSButton(
            title: "Cancel — preserve sources",
            target: self,
            action: #selector(cancelAction)
        )
        let confirm = NSButton(
            title: "Confirm retained rows",
            target: self,
            action: #selector(confirmAction)
        )
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
                constant: 18
            ),
            root.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor,
                constant: -18
            ),
            root.topAnchor.constraint(
                equalTo: window.contentView!.topAnchor,
                constant: 18
            ),
            root.bottomAnchor.constraint(
                equalTo: window.contentView!.bottomAnchor,
                constant: -18
            ),
            heading.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            scroll.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            scroll.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 400
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func confirmAction() {
        guard !callbackSettled else { return }
        callbackSettled = true
        closingFromAction = true
        let retained = Set(checks.compactMap {
            $0.value.state == .on ? $0.key : nil
        })
        close()
        onConfirm?(retained)
    }

    @objc private func cancelAction() {
        notifyCancel()
    }

    private func notifyCancel() {
        guard !callbackSettled else { return }
        callbackSettled = true
        closingFromAction = true
        close()
        onCancel?()
    }

    func cancelForBatch() {
        notifyCancel()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingFromAction {
            notifyCancel()
        }
    }

    #if SHADOW_SYNC_TESTING
    func testingConfirm() {
        confirmAction()
    }

    func testingCancel() {
        cancelAction()
    }
    #endif
}

@MainActor
private final class Body3DocumentStackView: NSStackView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private final class Body3ActionRowView: NSView {
    static let childInset: CGFloat = 26
    let textField = NSTextField(
        wrappingLabelWithString: ""
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints =
            false
        textField.alignment = .left
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 8
        textField.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.childInset
            ),
            textField.trailingAnchor.constraint(
                equalTo: trailingAnchor
            ),
            textField.topAnchor.constraint(
                equalTo: topAnchor,
                constant: 2
            ),
            textField.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -2
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var attributedStringValue: NSAttributedString {
        get { textField.attributedStringValue }
        set {
            textField.attributedStringValue = newValue
            setAccessibilityLabel(
                newValue.string
            )
        }
    }

    var stringValue: String {
        textField.stringValue
    }
}

@MainActor
private final class Body3HierarchyStackView:
    NSStackView {
    static let connectorLineWidth: CGFloat = 1
    static let connectorX: CGFloat = 9.5
    static let elbowEndX: CGFloat = 22
    private weak var parentRow: NSView?
    private var childRows: [NSView] = []

    func registerParent(_ row: NSView) {
        parentRow = row
        needsDisplay = true
    }

    func registerChild(_ row: NSView) {
        childRows.append(row)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let segments = connectorSegments
        guard !segments.isEmpty else { return }
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = Self.connectorLineWidth
        for segment in segments {
            path.move(to: segment.start)
            path.line(to: segment.end)
        }
        path.stroke()
    }

    var connectorSegments: [
        (start: NSPoint, end: NSPoint)
    ] {
        guard let parentRow,
              let last = childRows.last else {
            return []
        }
        let firstY = parentRow.frame.midY
        let lastY = last.frame.midY
        var result: [
            (start: NSPoint, end: NSPoint)
        ] = [(
            start: NSPoint(
                x: Self.connectorX,
                y: min(firstY, lastY)
            ),
            end: NSPoint(
                x: Self.connectorX,
                y: max(firstY, lastY)
            )
        )]
        result.append(
            contentsOf: childRows.map { row in
                (
                    start: NSPoint(
                        x: Self.connectorX,
                        y: row.frame.midY
                    ),
                    end: NSPoint(
                        x: Self.elbowEndX,
                        y: row.frame.midY
                    )
                )
            }
        )
        return result
    }

    var registeredChildCount: Int {
        childRows.count
    }
}

struct Body3UIPerformanceEvidence:
    Equatable, Sendable {
    let recordsReceived: Int
    let maximumBacklogDepth: Int
    let coalescedEventBatches: Int
    let visibleLogRenders: Int
    let projectedCharacters: Int
    let maximumUpdateMicroseconds: Int
    let maximumHeartbeatMicroseconds: Int
}

@MainActor
final class Body3RunWindowController:
    NSWindowController, NSWindowDelegate {
    private enum TerminalPresentation: Equatable {
        case none
        case report
        case needsAttention
    }

    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    private let headline = NSTextField(
        labelWithString: "Preparing protected recovery"
    )
    private let progress = NSProgressIndicator()
    private let summary = NSTextField(
        wrappingLabelWithString:
            "No source or Git state has changed."
    )
    private let runMetadata = NSTextField(
        wrappingLabelWithString:
            "Historical timing and outcome totals appear after durable completion."
    )
    private let cards = Body3DocumentStackView()
    private let logToggle = NSButton(
        title: "Live log & immutable plan #1 ▸",
        target: nil,
        action: nil
    )
    private let logScroll = NSScrollView()
    private let logText = NSTextView()
    private let logPerformance = NSTextField(
        wrappingLabelWithString: ""
    )
    private let cancelButton = NSButton(
        title: "Cancel",
        target: nil,
        action: nil
    )
    private var terminal = false
    private var terminalPresentation:
        TerminalPresentation = .none
    private var records: [Body3LogRecord] = []
    private let logProjection = Body3RunLogProjection()
    private var visibleLogRenders = 0
    private var coalescedEventBatches = 0
    private var maximumBacklogDepth = 0
    private var maximumUpdateMicroseconds = 0
    private var maximumHeartbeatMicroseconds = 0
    private var heartbeatScheduled = false
    private var visibleLogIsSynchronized = false
    private var visibleLogIncludesOmissionMarker = false
    private var nodeRows:
        [String: Body3ActionRowView] = [:]
    private var repositoryRows:
        [String: NSTextField] = [:]
    private var repositoryGroups:
        [String: NSBox] = [:]
    private var repositoryGroupStacks:
        [String: Body3HierarchyStackView] = [:]
    private var repositoryNodeIDs:
        [String: [String]] = [:]
    private var nodeStatuses:
        [String: Body3BatchNodeStatus] = [:]
    private var nodeKinds:
        [String: Body3BatchNodeKind] = [:]
    private let plan: Body3BatchPlan
    private let totalNodes: Int
    private var wasPaused = false
    private var didClose = false
    private(set) var report: Body3BatchReport?

    var isPresentationOpen: Bool {
        !didClose && window != nil
    }

    func canQuitImmediately(
        acknowledgedRunID _: String?
    ) -> Bool {
        terminal && report != nil
    }

    var isTerminal: Bool {
        terminal
    }

    var recoverySnapshot: Body3RecoveredRun? {
        report.map {
            Body3RecoveredRun(
                plan: plan,
                report: $0,
                records: records
            )
        }
    }

    var closeAcknowledgementRunID: String? {
        guard terminalPresentation == .report,
              let report,
              !report.requiresReview else {
            return nil
        }
        return plan.run
    }

    var runID: String {
        plan.run
    }

    var reviewRequiredRunID: String? {
        if terminalPresentation == .needsAttention
            || report?.requiresReview == true {
            return plan.run
        }
        return nil
    }

    init(plan: Body3BatchPlan) {
        self.plan = plan
        totalNodes = plan.nodes.count
        let window = NSWindow(
            contentRect: WindowFrameContinuity.initialRect(
                size: NSSize(width: 780, height: 620)
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ShadowSync · Selected batch"
        super.init(window: window)
        window.delegate = self

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 10

        headline.font = .boldSystemFont(ofSize: 16)
        root.addArrangedSubview(headline)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(max(1, plan.nodes.count))
        progress.doubleValue = 0
        root.addArrangedSubview(progress)
        root.addArrangedSubview(summary)
        runMetadata.font = .systemFont(ofSize: 11)
        runMetadata.textColor = .secondaryLabelColor
        root.addArrangedSubview(runMetadata)

        let cardScroll = NSScrollView()
        cardScroll.hasVerticalScroller = true
        cardScroll.borderType = .bezelBorder
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.distribution = .fill
        cards.spacing = 8
        cards.translatesAutoresizingMaskIntoConstraints = false
        var repositoryOrder: [String] = []
        for node in plan.nodes {
            let repository =
                node.repositoryID ?? "Batch safeguards"
            if repositoryNodeIDs[repository] == nil {
                repositoryOrder.append(repository)
            }
            repositoryNodeIDs[
                repository,
                default: []
            ].append(node.id)
            nodeStatuses[node.id] = .queued
        }
        for repository in repositoryOrder {
            let group = NSBox()
            group.boxType = .custom
            group.borderColor = .separatorColor
            group.borderWidth = 1
            group.cornerRadius = 7
            group.contentViewMargins = NSSize(
                width: 12,
                height: 10
            )
            let groupStack =
                Body3HierarchyStackView()
            groupStack.orientation = .vertical
            groupStack.alignment = .leading
            groupStack.spacing = 7
            groupStack.translatesAutoresizingMaskIntoConstraints =
                false
            group.contentView?.addSubview(groupStack)
            let heading = NSTextField(
                labelWithString: ""
            )
            heading.attributedStringValue =
                repositoryPresentation(
                    repository: repository,
                    status: .queued,
                    completed: 0,
                    total:
                        repositoryNodeIDs[
                            repository
                        ]?.count ?? 0
                )
            repositoryRows[repository] = heading
            repositoryGroups[repository] = group
            repositoryGroupStacks[repository] = groupStack
            groupStack.addArrangedSubview(heading)
            groupStack.registerParent(heading)
            for node in plan.nodes where
                (node.repositoryID ?? "Batch safeguards")
                    == repository {
                let row = Body3ActionRowView(
                    frame: .zero
                )
                row.attributedStringValue =
                    operationPresentation(
                        status: .queued,
                        phase: node.kind.phase,
                        detail: ""
                    )
                nodeRows[node.id] = row
                nodeKinds[node.id] = node.kind
                groupStack.addArrangedSubview(row)
                groupStack.registerChild(row)
                row.widthAnchor.constraint(
                    equalTo: groupStack.widthAnchor
                ).isActive = true
            }
            group.setContentHuggingPriority(
                .required,
                for: .vertical
            )
            cards.addArrangedSubview(group)
            group.widthAnchor.constraint(
                equalTo: cards.widthAnchor
            ).isActive = true
            if let content = group.contentView {
                NSLayoutConstraint.activate([
                    groupStack.leadingAnchor.constraint(
                        equalTo: content.leadingAnchor
                    ),
                    groupStack.trailingAnchor.constraint(
                        equalTo: content.trailingAnchor
                    ),
                    groupStack.topAnchor.constraint(
                        equalTo: content.topAnchor
                    ),
                    groupStack.bottomAnchor.constraint(
                        equalTo: content.bottomAnchor
                    ),
                ])
            }
        }
        let bottomSpacer = NSView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints =
            false
        bottomSpacer.setContentHuggingPriority(
            .defaultLow,
            for: .vertical
        )
        cards.addArrangedSubview(bottomSpacer)
        cardScroll.documentView = cards
        root.addArrangedSubview(cardScroll)

        logToggle.target = self
        logToggle.action = #selector(toggleLog)
        logToggle.isBordered = false
        root.addArrangedSubview(logToggle)
        logText.isEditable = false
        logText.isSelectable = true
        logText.font = .monospacedSystemFont(
            ofSize: 10,
            weight: .regular
        )
        logScroll.documentView = logText
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        root.addArrangedSubview(logScroll)
        logPerformance.font =
            .monospacedSystemFont(
                ofSize: 10,
                weight: .regular
            )
        logPerformance.textColor =
            .secondaryLabelColor
        logPerformance.isHidden = true
        root.addArrangedSubview(logPerformance)

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        root.addArrangedSubview(cancelButton)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(
                equalTo: window.contentView!.leadingAnchor,
                constant: 18
            ),
            root.trailingAnchor.constraint(
                equalTo: window.contentView!.trailingAnchor,
                constant: -18
            ),
            root.topAnchor.constraint(
                equalTo: window.contentView!.topAnchor,
                constant: 18
            ),
            root.bottomAnchor.constraint(
                equalTo: window.contentView!.bottomAnchor,
                constant: -18
            ),
            progress.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            summary.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            runMetadata.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            cardScroll.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            cardScroll.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 230
            ),
            logScroll.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            logPerformance.widthAnchor.constraint(
                equalTo: root.widthAnchor
            ),
            logScroll.heightAnchor.constraint(
                equalToConstant: 150
            ),
            cards.widthAnchor.constraint(
                equalTo:
                    cardScroll.contentView.widthAnchor
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPreparing(_ completed: Int, total: Int) {
        guard terminalPresentation == .none else {
            return
        }
        if total == 0 {
            headline.stringValue =
                "Preparing selected operations"
            progress.maxValue = Double(max(1, totalNodes))
            progress.doubleValue = 0
            summary.stringValue =
                "The immutable plan is queued; no child operation has started."
        } else {
            headline.stringValue =
                "Preparing protected recovery"
            progress.maxValue = Double(max(1, total))
            progress.doubleValue = Double(completed)
            summary.stringValue =
                "\(completed)/\(total) recovery attempt\(total == 1 ? "" : "s") complete. Recovery is verified before final permission."
        }
    }

    func showAwaitingConfirmation() {
        guard terminalPresentation == .none else {
            return
        }
        headline.stringValue = "Awaiting final grouped permission"
        summary.stringValue =
            "Recovery attempts are complete. Cancelling preserves every source and completed artifact."
    }

    func update(_ event: Body3CoordinatorEvent) {
        update([event], maximumBacklogDepth: 1)
    }

    func update(
        _ events: [Body3CoordinatorEvent],
        maximumBacklogDepth backlogDepth: Int
    ) {
        guard !events.isEmpty else {
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        coalescedEventBatches += 1
        maximumBacklogDepth = max(
            maximumBacklogDepth,
            backlogDepth
        )
        var appendedRecord = false
        var statusChanged = false
        var logMutations: [
            Body3RunLogProjectionMutation
        ] = []
        for event in events {
            if let progressValue = event.progress,
               terminalPresentation == .none {
                headline.stringValue =
                    "Running · \(progressValue.phase)"
                progress.maxValue = Double(
                    max(1, progressValue.total)
                )
                progress.doubleValue = Double(
                    progressValue.terminal
                )
                summary.stringValue =
                    "\(progressValue.terminal)/\(progressValue.total) terminal · \(progressValue.activeWorkers) active worker\(progressValue.activeWorkers == 1 ? "" : "s") · \(progressValue.elapsedMilliseconds) ms elapsed"
                wasPaused =
                    wasPaused || progressValue.paused
            }
            guard let record = event.record else {
                continue
            }
            appendedRecord = true
            records.append(record)
            let mutation = logProjection.append(record)
            if !logScroll.isHidden {
                logMutations.append(mutation)
            }
            if record.type != "command",
               let operation = record.operation,
               let status = record.status,
               nodeRows[operation] != nil {
                statusChanged = true
                nodeStatuses[operation] = status
                nodeRows[operation]?.attributedStringValue =
                    operationPresentation(
                        status: status,
                        phase:
                            nodeKinds[operation]?.phase
                                ?? record.phase
                                ?? "Operation",
                        detail:
                            record.detail
                                ?? "",
                        technicalDetail:
                            record.technicalDetail
                    )
            }
        }
        if appendedRecord {
            if !logScroll.isHidden {
                applyVisibleLogMutations(
                    logMutations
                )
            }
        }
        if statusChanged {
            refreshRepositoryRows()
        }
        let elapsed = Int(
            (
                ProcessInfo.processInfo.systemUptime
                    - started
            ) * 1_000_000
        )
        maximumUpdateMicroseconds = max(
            maximumUpdateMicroseconds,
            elapsed
        )
        scheduleHeartbeat()
    }

    func finish(_ report: Body3BatchReport) {
        let expectedNodeIDs = Set(plan.nodes.map(\.id))
        let reportedNodeIDs = Set(
            report.results.map(\.node.id)
        )
        guard report.run == plan.run else {
            fail(
                "The final batch report named a different run than this live window; review the validated log before retrying."
            )
            return
        }
        guard report.results.count == plan.nodes.count,
              reportedNodeIDs == expectedNodeIDs else {
            fail(
                "The final batch report did not match the exact live run plan; review the validated log before retrying."
            )
            return
        }
        let metadata: Body3RunMetadataPresentation
        do {
            metadata = try Body3RunMetadataPresentation.make(
                plan: plan,
                report: report
            )
        } catch {
            fail(
                "The final batch timing or outcome totals contradicted the immutable plan; review the validated log before retrying."
            )
            return
        }
        terminal = true
        if self.report == nil {
            self.report = report
        }
        guard terminalPresentation == .none else {
            return
        }
        terminalPresentation = .report
        progress.doubleValue = Double(report.results.count)
        for result in report.results {
            nodeStatuses[result.node.id] =
                result.status
            nodeRows[result.node.id]?
                .attributedStringValue =
                operationPresentation(
                    status: result.status,
                    phase: result.node.kind.phase,
                    detail: result.detail,
                    technicalDetail:
                        result.technicalDetail
                )
        }
        refreshRepositoryRows()
        runMetadata.stringValue = [
            metadata.timing,
            metadata.summary,
        ].joined(separator: "\n")
        headline.stringValue = report.cancelled
            ? "Cancelled · residue checked"
            : (
                report.paused || wasPaused
                    ? "Paused · infrastructure circuit breaker"
                    : "Complete"
            )
        let attention = report.results.filter {
            $0.status == .failed
                || $0.status == .refused
                || $0.status == .cancelled
        }.count
        summary.stringValue =
            "\(report.results.count)/\(totalNodes) terminal across \(report.repositoryCounts.count) repositor\(report.repositoryCounts.count == 1 ? "y" : "ies") · \(attention) need\(attention == 1 ? "s" : "") attention · completed artifacts and completed mutations were preserved."
        cancelButton.title = "Close"
        if !logScroll.isHidden {
            updatePerformanceEvidenceLabel()
        }
        logPerformanceEvidence()
    }

    func fail(_ message: String) {
        guard terminalPresentation == .none else {
            return
        }
        terminal = true
        terminalPresentation = .needsAttention
        headline.stringValue = "Needs Attention"
        summary.stringValue =
            "\(message) No unreported retry will start."
        cancelButton.title = "Close"
    }

    @objc private func toggleLog() {
        logScroll.isHidden.toggle()
        logPerformance.isHidden =
            logScroll.isHidden
        logToggle.title =
            "Live log & immutable plan #1 \(logScroll.isHidden ? "▸" : "▾")"
        if !logScroll.isHidden {
            synchronizeVisibleLog()
            logText.scrollRangeToVisible(
                NSRange(location: 0, length: 0)
            )
        } else {
            visibleLogIsSynchronized = false
            visibleLogIncludesOmissionMarker = false
        }
    }

    private var performanceEvidence:
        Body3UIPerformanceEvidence {
        let projection = logProjection.metrics
        return Body3UIPerformanceEvidence(
            recordsReceived: projection.recordVisits,
            maximumBacklogDepth:
                maximumBacklogDepth,
            coalescedEventBatches:
                coalescedEventBatches,
            visibleLogRenders: visibleLogRenders,
            projectedCharacters:
                projection.renderedCharacterCount,
            maximumUpdateMicroseconds:
                maximumUpdateMicroseconds,
            maximumHeartbeatMicroseconds:
                maximumHeartbeatMicroseconds
        )
    }

    private func performanceEvidenceLine(
        visibleRenderCount: Int
    ) -> String {
        let evidence = performanceEvidence
        return [
            "UI evidence",
            "records \(evidence.recordsReceived)",
            "max backlog \(evidence.maximumBacklogDepth)",
            "event batches \(evidence.coalescedEventBatches)",
            "visible log renders \(visibleRenderCount)",
            "projected characters \(evidence.projectedCharacters)",
            "max update \(evidence.maximumUpdateMicroseconds) µs",
            "max heartbeat \(evidence.maximumHeartbeatMicroseconds) µs",
        ].joined(separator: " · ")
    }

    private func synchronizeVisibleLog() {
        logText.string = logProjection.text
        visibleLogIsSynchronized = true
        visibleLogIncludesOmissionMarker =
            logProjection.isOmittingEarlierEvents
        visibleLogRenders += 1
        updatePerformanceEvidenceLabel()
    }

    private func applyVisibleLogMutations(
        _ mutations: [Body3RunLogProjectionMutation]
    ) {
        guard !mutations.isEmpty else {
            updatePerformanceEvidenceLabel()
            return
        }
        guard visibleLogIsSynchronized else {
            synchronizeVisibleLog()
            return
        }
        guard let storage = logText.textStorage else {
            synchronizeVisibleLog()
            return
        }
        storage.beginEditing()
        for mutation in mutations {
            storage.append(
                NSAttributedString(
                    string: mutation.appendedText
                )
            )
            removeLeadingVisibleLogUTF16Units(
                mutation.removedLeadingUTF16Units,
                from: storage
            )
            if mutation.startedOmittingEarlierEvents {
                storage.insert(
                    NSAttributedString(
                        string:
                            Body3RunLogProjection
                                .omissionMarker
                    ),
                    at: 0
                )
                visibleLogIncludesOmissionMarker = true
            }
        }
        storage.endEditing()
        visibleLogRenders += 1
        updatePerformanceEvidenceLabel()
    }

    private func removeLeadingVisibleLogUTF16Units(
        _ count: Int,
        from storage: NSTextStorage
    ) {
        guard count > 0 else { return }
        let bodyStart =
            visibleLogIncludesOmissionMarker
            ? Body3RunLogProjection
                .omissionMarker.utf16.count
            : 0
        storage.deleteCharacters(
            in: NSRange(
                location: bodyStart,
                length: min(
                    count,
                    max(0, storage.length - bodyStart)
                )
            )
        )
    }

    private func updatePerformanceEvidenceLabel() {
        logPerformance.stringValue =
            performanceEvidenceLine(
                visibleRenderCount:
                    visibleLogRenders
            )
    }

    private func scheduleHeartbeat() {
        guard !heartbeatScheduled else {
            return
        }
        heartbeatScheduled = true
        let started =
            ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = Int(
                (
                    ProcessInfo.processInfo.systemUptime
                        - started
                ) * 1_000_000
            )
            self.maximumHeartbeatMicroseconds = max(
                self.maximumHeartbeatMicroseconds,
                elapsed
            )
            self.heartbeatScheduled = false
        }
    }

    private func logPerformanceEvidence() {
        let evidence = performanceEvidence
        Logger(
            subsystem: "com.kleinperkins.shadow-sync",
            category: "body3-ui-performance"
        ).notice(
            "records=\(evidence.recordsReceived, privacy: .public) max_backlog=\(evidence.maximumBacklogDepth, privacy: .public) event_batches=\(evidence.coalescedEventBatches, privacy: .public) visible_log_renders=\(evidence.visibleLogRenders, privacy: .public) projected_characters=\(evidence.projectedCharacters, privacy: .public) max_update_us=\(evidence.maximumUpdateMicroseconds, privacy: .public) max_heartbeat_us=\(evidence.maximumHeartbeatMicroseconds, privacy: .public)"
        )
    }

    private func operationPresentation(
        status: Body3BatchNodeStatus,
        phase: String,
        detail: String,
        technicalDetail: String? = nil
    ) -> NSAttributedString {
        let state = displayState(status)
        let publicDetail = String(
            Redactor.sanitize(detail).prefix(2_048)
        )
        let boundedTechnicalDetail =
            Body3TechnicalDetail.canonical(technicalDetail)
        var detailLines = [
            state.label,
            publicDetail.isEmpty ? nil : publicDetail,
            boundedTechnicalDetail.map {
                "Technical detail: \($0)"
            },
        ].compactMap { $0 }
        if state.label == "Completed with issues" {
            detailLines.append(
                "ShadowSync stopped this action because the required safety evidence changed or could not be verified. Inspect the repository, then open/copy diagnostics from the Live Log before retrying."
            )
        }
        let title = "\(state.symbol) \(phase)"
        let text = title + "\n"
            + detailLines.joined(separator: "\n")
        let value = NSMutableAttributedString(
            string: text
        )
        value.addAttribute(
            .font,
            value: NSFont.systemFont(
                ofSize: 12,
                weight: .regular
            ),
            range: NSRange(
                location: 0,
                length: title.count
            )
        )
        value.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(
                location: 0,
                length: title.count
            )
        )
        value.addAttribute(
            .foregroundColor,
            value: state.color,
            range: NSRange(
                location: 0,
                length: state.symbol.count
            )
        )
        let detailRange = NSRange(
            location: title.count + 1,
            length:
                max(0, value.length - title.count - 1)
        )
        value.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 11),
            range: detailRange
        )
        value.addAttribute(
            .foregroundColor,
            value: state.color,
            range: detailRange
        )
        if let technicalRange = text.range(
            of: "Technical detail:"
        ) {
            value.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(
                    technicalRange,
                    in: text
                )
            )
        }
        return value
    }

    private func refreshRepositoryRows() {
        for (repository, ids) in repositoryNodeIDs {
            let statuses = ids.compactMap {
                nodeStatuses[$0]
            }
            let status: Body3BatchNodeStatus
            if statuses.contains(where: {
                [.failed, .refused, .cancelled, .skipped]
                    .contains($0)
            }) {
                status = .failed
            } else if statuses.allSatisfy({
                $0 == .succeeded
            }) {
                status = .succeeded
            } else if statuses.contains(.running)
                        || statuses.contains(.succeeded) {
                status = .running
            } else {
                status = .queued
            }
            let row = repositoryRows[repository]
            row?.attributedStringValue =
                repositoryPresentation(
                    repository: repository,
                    status: status,
                    completed: statuses.filter {
                        $0.isTerminal
                    }.count,
                    total: ids.count
                )
        }
    }

    private func repositoryPresentation(
        repository: String,
        status: Body3BatchNodeStatus,
        completed: Int,
        total: Int
    ) -> NSAttributedString {
        let state = displayState(status)
        let title = "\(state.symbol) \(repository)"
        let count =
            "\(completed) of \(total) steps"
        let text = "\(title) · \(count)"
        let value = NSMutableAttributedString(
            string: text
        )
        value.addAttribute(
            .font,
            value: NSFont.systemFont(
                ofSize: 13,
                weight: .semibold
            ),
            range: NSRange(
                location: 0,
                length: value.length
            )
        )
        value.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(
                location: 0,
                length: title.count
            )
        )
        value.addAttribute(
            .foregroundColor,
            value: state.color,
            range: NSRange(
                location: 0,
                length: state.symbol.count
            )
        )
        if let countRange = text.range(of: count) {
            value.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(
                    countRange,
                    in: text
                )
            )
        }
        return value
    }

    private func displayState(
        _ status: Body3BatchNodeStatus
    ) -> (
        symbol: String,
        label: String,
        color: NSColor
    ) {
        switch status {
        case .queued:
            return ("○", "Not started", .secondaryLabelColor)
        case .running:
            return ("◐", "In progress", .systemBlue)
        case .succeeded:
            return ("✓", "Completed successfully", .systemGreen)
        case .skipped, .refused, .failed, .cancelled:
            return ("!", "Completed with issues", .systemOrange)
        }
    }

    @objc private func cancel() {
        if terminal {
            close()
            notifyClose()
        } else {
            cancelButton.isEnabled = false
            cancelButton.title = "Cancelling…"
            onCancel?()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if terminal {
            notifyClose()
            return true
        }
        onCancel?()
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling…"
        return false
    }

    private func notifyClose() {
        guard !didClose else { return }
        didClose = true
        onClose?()
    }

    #if SHADOW_SYNC_TESTING
    var testingTerminalPresentation: (
        headline: String,
        summary: String,
        terminal: Bool,
        hasReport: Bool,
        closeAcknowledgementRunID: String?,
        reviewRequiredRunID: String?
    ) {
        (
            headline.stringValue,
            summary.stringValue,
            terminal,
            report != nil,
            closeAcknowledgementRunID,
            reviewRequiredRunID
        )
    }

    var testingActionRowIdentities: [String: ObjectIdentifier] {
        nodeRows.mapValues(ObjectIdentifier.init)
    }

    var testingRepositoryGroupIdentities:
        [String: ObjectIdentifier] {
        repositoryGroups.mapValues(ObjectIdentifier.init)
    }

    var testingActionRowOrder: [String] {
        plan.nodes.map(\.id)
    }

    var testingRepositoryGroupsAreLeadingAndBounded: Bool {
        cards.alignment == .leading
            && repositoryGroupStacks.values.allSatisfy {
                $0.alignment == .leading
            }
            && repositoryGroups.count
                == repositoryNodeIDs.count
    }

    var testingHierarchyMeetsApprovedGeometry: Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let parentsMatch =
            repositoryRows.allSatisfy {
                repository, row in
                let value =
                    row.attributedStringValue
                let font = value.length > 0
                    ? value.attribute(
                        .font,
                        at: 0,
                        effectiveRange: nil
                    ) as? NSFont
                    : nil
                return font?.pointSize == 13
                    && value.string.contains(" of ")
                    && value.string.contains(" steps")
                    && repositoryNodeIDs[repository]
                        != nil
            }
        let childrenMatch = nodeRows.values.allSatisfy {
            row in
            let value =
                row.attributedStringValue
            let newline = (
                value.string as NSString
            ).range(of: "\n")
            guard value.length > 2,
                  newline.location != NSNotFound,
                  newline.location + 1 < value.length,
                  let titleFont = value.attribute(
                      .font,
                      at: 2,
                      effectiveRange: nil
                  ) as? NSFont,
                  let detailFont = value.attribute(
                      .font,
                      at: newline.location + 1,
                      effectiveRange: nil
                  ) as? NSFont,
                  let titleColor = value.attribute(
                      .foregroundColor,
                      at: 2,
                      effectiveRange: nil
                  ) as? NSColor else {
                return false
            }
            return Body3ActionRowView.childInset >= 24
                && Body3ActionRowView.childInset <= 28
                && titleFont.pointSize == 12
                && detailFont.pointSize == 11
                && titleColor == .labelColor
                && !row.stringValue.isEmpty
                && row.isAccessibilityElement()
                && row.accessibilityLabel()
                    == value.string
                && !row.textField
                    .isAccessibilityElement()
        }
        let connectorsMatch =
            repositoryGroupStacks.values
                .allSatisfy {
                    $0.connectorSegments.count
                        == $0.registeredChildCount + 1
                        && Body3HierarchyStackView
                            .connectorLineWidth == 1
                        && Body3HierarchyStackView
                            .elbowEndX
                            < Body3ActionRowView
                                .childInset
                }
        return parentsMatch
            && childrenMatch
            && connectorsMatch
    }

    var testingActionText: [String: String] {
        nodeRows.mapValues(\.stringValue)
    }

    var testingLiveLogText: String {
        logText.string
    }

    var testingPerformanceEvidence:
        Body3UIPerformanceEvidence {
        performanceEvidence
    }

    var testingPerformanceEvidenceText: String {
        logPerformance.stringValue
    }

    var testingLogIsCollapsed: Bool {
        logScroll.isHidden
    }

    func testingToggleLog() {
        toggleLog()
    }

    var testingRunMetadataText: String {
        runMetadata.stringValue
    }

    func testingCloseTerminalPresentation() {
        cancel()
    }

    #endif
}
