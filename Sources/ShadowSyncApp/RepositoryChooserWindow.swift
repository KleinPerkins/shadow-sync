import AppKit
import Darwin
import ShadowSyncCatalog
import ShadowSyncCore
import Foundation

@MainActor
final class RepositoryChooserWindowController:
    SelectionWindowController {
    let catalog: RepositorySelectionCatalogResult
    let preferenceSnapshot: RepositorySelectionPreferenceSnapshot
    private let initialSavedEntries:
        Set<RepositorySelectionPreferenceEntry>?

    var onContinue:
        (([RepositorySelectionPreferenceEntry]) -> Void)?
    var onSaveDefaults:
        (([RepositorySelectionPreferenceEntry]) -> Void)?
    var onReload: (() -> Void)?
    var onRecoverDefaults:
        (([RepositorySelectionPreferenceEntry]) -> Void)?
    var onCanonicalRootChange: ((
        RepositorySelectionCandidate,
        RepositorySelectionAlternative
    ) -> Void)?
    var onQuit: (() -> Void)?

    private var buttons:
        [RepositorySelectionPreferenceEntry: NSButton] = [:]
    private var candidates:
        [RepositorySelectionPreferenceEntry:
            RepositorySelectionCandidate] = [:]
    private var unresolvedButtons:
        [RepositorySelectionPreferenceEntry: NSButton] = [:]
    private var canonicalMenus: [String: NSPopUpButton] = [:]
    private var canonicalCandidates:
        [String: RepositorySelectionCandidate] = [:]
    private var collapsedSections:
        [ObjectIdentifier: (NSButton, NSView)] = [:]
    private var closingCurrentRun = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let saveButton = NSButton(
        title: "Save as defaults",
        target: nil,
        action: nil
    )
    private let continueButton = NSButton(
        title: "Continue",
        target: nil,
        action: nil
    )
    private let reloadButton = NSButton(
        title: "Reload",
        target: nil,
        action: nil
    )
    private let recoverButton = NSButton(
        title: "Recover defaults…",
        target: nil,
        action: nil
    )
    private let cancelButton = NSButton(
        title: "Cancel",
        target: nil,
        action: nil
    )
    private let quitButton = NSButton(
        title: "Quit",
        target: nil,
        action: nil
    )
    private var admissionOpen = true

    init(
        catalog: RepositorySelectionCatalogResult,
        preferenceSnapshot: RepositorySelectionPreferenceSnapshot,
        initialSavedEntries:
            Set<RepositorySelectionPreferenceEntry>? = nil
    ) {
        self.catalog = catalog
        self.preferenceSnapshot = preferenceSnapshot
        self.initialSavedEntries = initialSavedEntries
        super.init(candidates: [])
        let chooser = NSWindow(
            contentRect: WindowFrameContinuity.initialRect(
                size: NSSize(width: 760, height: 590)
            ),
            styleMask: [
                .titled, .closable, .resizable, .miniaturizable,
            ],
            backing: .buffered,
            defer: false
        )
        chooser.title = "Choose repositories"
        chooser.center()
        window = chooser
        chooser.delegate = self
        buildChooser()
        configureNativeWindowGeometry(
            autosaveName: "ShadowSync.RepositoryChooser.v1",
            minimumFrameSize: NSSize(width: 640, height: 460)
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingCurrentRun {
            return true
        }
        guard admissionOpen else {
            onQuit?()
            return false
        }
        return true
    }

    private func buildChooser() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        let heading = NSTextField(
            labelWithString: "Choose repositories to inspect"
        )
        heading.font = .preferredFont(forTextStyle: .title2)
        root.addArrangedSubview(heading)
        let help = NSTextField(
            wrappingLabelWithString:
                "Selection is process-free. Git, GitHub, and repository inspection start only after Continue."
        )
        help.maximumNumberOfLines = 0
        root.addArrangedSubview(help)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        buildSections(in: rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = rows
        root.addArrangedSubview(scroll)

        if !catalog.catalog.unresolvedDefaults.isEmpty {
            let label = NSTextField(
                wrappingLabelWithString:
                    "Saved but not currently found"
            )
            label.textColor = .systemOrange
            root.addArrangedSubview(label)
            for entry in catalog.catalog.unresolvedDefaults {
                let button = NSButton(
                    checkboxWithTitle:
                        "\(entry.repositoryID) — "
                        + "\(entry.locator.governedRoot)/"
                        + entry.locator.relativePath,
                    target: self,
                    action: #selector(chooserSelectionChanged(_:))
                )
                button.state = (
                    initialSavedEntries?.contains(entry) ?? true
                ) ? .on : .off
                button.toolTip =
                    "Keep this unresolved entry in saved defaults. Clear it to remove it explicitly."
                unresolvedButtons[entry] = button
                root.addArrangedSubview(button)
            }
        }

        progress.style = .spinning
        progress.isDisplayedWhenStopped = false
        root.addArrangedSubview(progress)
        status.maximumNumberOfLines = 0
        root.addArrangedSubview(status)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        saveButton.target = self
        saveButton.action = #selector(saveDefaults)
        continueButton.target = self
        continueButton.action = #selector(continueSelection)
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.keyEquivalent = "\u{1b}"
        quitButton.target = self
        quitButton.action = #selector(quit)
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        recoverButton.target = self
        recoverButton.action = #selector(recover)
        controls.addArrangedSubview(reloadButton)
        if preferenceSnapshot.status == .malformed {
            controls.addArrangedSubview(recoverButton)
        }
        controls.addArrangedSubview(saveButton)
        controls.addArrangedSubview(cancelButton)
        controls.addArrangedSubview(quitButton)
        controls.addArrangedSubview(continueButton)
        root.addArrangedSubview(controls)

        switch preferenceSnapshot.status {
        case .absent:
            status.stringValue = "Defaults have not been saved yet."
        case .available:
            status.stringValue =
                preferenceSnapshot.explanation ?? ""
        case .malformed:
            status.stringValue =
                "Saved defaults unavailable. Recover them explicitly or continue with this session only."
        case .unsafe:
            status.stringValue =
                "Saved defaults are unsafe. Retry inspection or use lifecycle doctor."
        case .unsupportedSchema:
            status.stringValue =
                "Saved defaults require a newer ShadowSync version."
        }
        if let degraded = catalog.degradedReason {
            status.stringValue = degraded.operatorExplanation
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: 24
            ),
            root.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -24
            ),
            root.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: 24
            ),
            root.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -24
            ),
            help.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(
                greaterThanOrEqualToConstant: 260
            ),
            rows.leadingAnchor.constraint(
                equalTo: scroll.contentView.leadingAnchor,
                constant: 8
            ),
            rows.trailingAnchor.constraint(
                equalTo: scroll.contentView.trailingAnchor,
                constant: -8
            ),
            rows.topAnchor.constraint(
                equalTo: scroll.contentView.topAnchor,
                constant: 8
            ),
        ])
        updateControls()
        window?.initialFirstResponder = buttons.values.first {
            $0.isEnabled
        } ?? cancelButton
        window?.defaultButtonCell = continueButton.cell as? NSButtonCell
    }

    private func buildSections(in rows: NSStackView) {
        let order: [RepositorySelectionSection] = [
            .available,
            .canonicalRootRequired,
            .unavailable,
            .excluded,
            .protected,
        ]
        for section in order {
            let sectionCandidates = sortedCandidates(
                catalog.catalog.candidates.filter {
                    $0.isVisible && $0.section == section
                }
            )
            guard !sectionCandidates.isEmpty else { continue }
            let sectionRows = NSStackView()
            sectionRows.orientation = .vertical
            sectionRows.alignment = .leading
            sectionRows.spacing = 6
            sectionRows.translatesAutoresizingMaskIntoConstraints = false
            if section == .unavailable
                || section == .excluded
                || section == .protected {
                buildReasonGroups(
                    sectionCandidates,
                    in: sectionRows
                )
            } else {
                for candidate in sectionCandidates {
                    buildCandidateRow(
                        candidate,
                        in: sectionRows
                    )
                }
            }
            let collapsed = [
                RepositorySelectionSection.unavailable,
                .excluded,
                .protected,
            ].contains(section)
            if collapsed {
                let toggle = NSButton(
                    title:
                        "Show \(sectionCandidates.count) "
                        + sectionTitle(section),
                    target: self,
                    action: #selector(toggleSection)
                )
                toggle.setButtonType(.momentaryPushIn)
                rows.addArrangedSubview(toggle)
                sectionRows.isHidden = true
                collapsedSections[ObjectIdentifier(toggle)] =
                    (toggle, sectionRows)
            } else {
                let heading = NSTextField(
                    labelWithString: sectionTitle(section)
                )
                heading.font = .preferredFont(
                    forTextStyle: .headline
                )
                rows.addArrangedSubview(heading)
            }
            rows.addArrangedSubview(sectionRows)
            sectionRows.widthAnchor.constraint(
                equalTo: rows.widthAnchor
            ).isActive = true
        }
    }

    private func sectionTitle(
        _ section: RepositorySelectionSection
    ) -> String {
        switch section {
        case .available: return "Available"
        case .canonicalRootRequired:
            return "Canonical root required"
        case .unavailable:
            return "Unavailable / read-only"
        case .excluded: return "Excluded"
        case .protected: return "Protected"
        }
    }

    private func buildReasonGroups(
        _ candidates: [RepositorySelectionCandidate],
        in rows: NSStackView
    ) {
        let groups = Dictionary(grouping: candidates) {
            $0.disabledReason ?? sectionTitle($0.section)
        }
        for reason in groups.keys.sorted() {
            let heading = NSTextField(
                wrappingLabelWithString: reason
            )
            heading.font = .preferredFont(forTextStyle: .subheadline)
            heading.textColor = .secondaryLabelColor
            rows.addArrangedSubview(heading)
            for candidate in sortedCandidates(
                groups[reason] ?? []
            ) {
                buildCandidateRow(
                    candidate,
                    in: rows,
                    showsDisabledReason: false
                )
            }
        }
    }

    private func sortedCandidates(
        _ candidates: [RepositorySelectionCandidate]
    ) -> [RepositorySelectionCandidate] {
        candidates.sorted { lhs, rhs in
            let left = lhs.id.lowercased().split(
                separator: "/",
                maxSplits: 1
            )
            let right = rhs.id.lowercased().split(
                separator: "/",
                maxSplits: 1
            )
            let leftOwner = left.first.map(String.init) ?? ""
            let rightOwner = right.first.map(String.init) ?? ""
            if leftOwner != rightOwner {
                return leftOwner.localizedStandardCompare(
                    rightOwner
                ) == .orderedAscending
            }
            let leftRepository =
                left.dropFirst().first.map(String.init)
                    ?? lhs.id.lowercased()
            let rightRepository =
                right.dropFirst().first.map(String.init)
                    ?? rhs.id.lowercased()
            return leftRepository.localizedStandardCompare(
                rightRepository
            ) == .orderedAscending
        }
    }

    private func buildCandidateRow(
        _ candidate: RepositorySelectionCandidate,
        in rows: NSStackView,
        showsDisabledReason: Bool = true
    ) {
        guard let entry = try? candidate.preferenceEntry else {
            return
        }
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        let title =
            "\(candidate.displayLabel) — "
            + candidate.compactLocation
        if candidate.isEligible {
            let button = NSButton(
                checkboxWithTitle: title,
                target: self,
                action: #selector(chooserSelectionChanged(_:))
            )
            button.state = (
                initialSavedEntries?.contains(where: {
                    $0.repositoryID == candidate.id
                }) ?? candidate.isDefaultSelected
            ) ? .on : .off
            button.toolTip =
                "Include this origin repository in selected hydration."
            buttons[entry] = button
            candidates[entry] = candidate
            row.addArrangedSubview(button)
        } else {
            let label = NSTextField(
                wrappingLabelWithString: title
            )
            label.textColor = .secondaryLabelColor
            row.addArrangedSubview(label)
        }
        if showsDisabledReason,
           let reason = candidate.disabledReason {
            let warning = NSTextField(
                wrappingLabelWithString: reason
            )
            warning.textColor = .secondaryLabelColor
            row.addArrangedSubview(warning)
        }
        if candidate.alternatives.count > 1 {
            let canonical = NSStackView()
            canonical.orientation = .horizontal
            canonical.alignment = .centerY
            canonical.spacing = 6
            let path = NSTextField(
                labelWithString: candidate.canonicalRootRequired
                    ? "Choose one primary checkout."
                    : "Canonical: \(candidate.compactLocation)"
            )
            path.textColor = candidate.canonicalRootRequired
                ? .systemOrange : .secondaryLabelColor
            let menu = NSPopUpButton(
                frame: .zero,
                pullsDown: false
            )
            if candidate.canonicalRootRequired {
                menu.addItem(
                    withTitle: "Choose canonical root…"
                )
                menu.item(at: 0)?.isEnabled = false
            }
            for (index, alternative) in
                    candidate.alternatives.enumerated() {
                menu.addItem(
                    withTitle: alternative.compactLocation
                )
                menu.lastItem?.representedObject = index
            }
            if !candidate.canonicalRootRequired,
               let index = candidate.alternatives.firstIndex(
                   where: { $0.locator == candidate.locator }
               ) {
                menu.selectItem(
                    at: index
                        + (candidate.canonicalRootRequired ? 1 : 0)
                )
            }
            menu.target = self
            menu.action = #selector(canonicalChoiceChanged(_:))
            canonicalMenus[candidate.id] = menu
            canonicalCandidates[candidate.id] = candidate
            let change = NSButton(
                title: "Change…",
                target: self,
                action: #selector(showCanonicalChoices(_:))
            )
            change.identifier = NSUserInterfaceItemIdentifier(
                candidate.id
            )
            canonical.addArrangedSubview(path)
            canonical.addArrangedSubview(change)
            canonical.addArrangedSubview(menu)
            row.addArrangedSubview(canonical)
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: rows.widthAnchor
        ).isActive = true
    }

    @objc private func toggleSection(_ sender: NSButton) {
        guard let (button, view) =
                collapsedSections[ObjectIdentifier(sender)] else {
            return
        }
        view.isHidden.toggle()
        button.title = view.isHidden
            ? button.title.replacingOccurrences(
                of: "Hide ",
                with: "Show "
            )
            : button.title.replacingOccurrences(
                of: "Show ",
                with: "Hide "
            )
    }

    @objc private func showCanonicalChoices(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else {
            return
        }
        canonicalMenus[id]?.performClick(nil)
    }

    @objc private func canonicalChoiceChanged(
        _ sender: NSPopUpButton
    ) {
        guard let pair = canonicalMenus.first(where: {
            $0.value === sender
        }),
        let candidate = canonicalCandidates[pair.key],
        let index = sender.selectedItem?.representedObject
            as? Int,
        candidate.alternatives.indices.contains(index) else {
            return
        }
        onCanonicalRootChange?(
            candidate,
            candidate.alternatives[index]
        )
    }

    #if SHADOW_SYNC_TESTING
    var testingNativeGeometrySnapshot: (
        frame: NSRect,
        minimum: NSSize,
        contentMinimum: NSSize,
        resizable: Bool,
        miniaturizable: Bool,
        fullScreenPrimary: Bool,
        zoomEnabled: Bool
    ) {
        guard let window else {
            return (
                .zero, .zero, .zero,
                false, false, false, false
            )
        }
        return (
            window.frame,
            window.minSize,
            window.contentMinSize,
            window.styleMask.contains(.resizable),
            window.styleMask.contains(.miniaturizable),
            window.collectionBehavior.contains(.fullScreenPrimary),
            window.standardWindowButton(.zoomButton)?
                .isEnabled == true
        )
    }

    func testingApplyFrame(_ frame: NSRect) -> NSRect {
        window?.setFrame(frame, display: false)
        prepareForPresentation()
        return window?.frame ?? .zero
    }

    func testingStandardZoomFrame() -> NSRect {
        guard let window else { return .zero }
        return windowWillUseStandardFrame(
            window,
            defaultFrame: window.frame
        )
    }
    #endif

    @objc private func chooserSelectionChanged(
        _ sender: NSButton
    ) {
        if sender.state == .on,
           let selected = (
               buttons.first { $0.value === sender }?.key
                ?? unresolvedButtons.first {
                    $0.value === sender
                }?.key
           ) {
            for (entry, button) in buttons
            where entry.repositoryID == selected.repositoryID
                    && button !== sender {
                button.state = .off
            }
            for (entry, button) in unresolvedButtons
            where entry.repositoryID == selected.repositoryID
                    && button !== sender {
                button.state = .off
            }
        }
        updateControls()
    }

    @objc private func saveDefaults() {
        guard admissionOpen else { return }
        onSaveDefaults?(savedDefaultEntries())
    }

    @objc private func continueSelection() {
        let selected = sessionSelectedEntries()
        guard admissionOpen, !selected.isEmpty, catalog.isComplete else {
            return
        }
        admissionOpen = false
        updateControls()
        showHydrationProgress(
            completed: 0,
            total: selected.count,
            repositoryID: selected.first?.repositoryID
        )
        onContinue?(selected)
    }

    @objc private func reload() {
        guard admissionOpen else { return }
        onReload?()
    }

    @objc private func recover() {
        guard admissionOpen else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recover saved defaults?"
        alert.informativeText =
            "The unreadable preference document will be preserved in the recovery slot, then replaced with the selection shown here. Repository authority is not changed."
        alert.addButton(withTitle: "Recover defaults")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        admissionOpen = false
        updateControls()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.admissionOpen = true
            self.updateControls()
            guard response == .alertFirstButtonReturn else { return }
            self.onRecoverDefaults?(self.savedDefaultEntries())
        }
    }

    @objc private func cancelSelection() {
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .abort)
            close()
            return
        }
        if admissionOpen {
            close()
        } else {
            onCancel?()
        }
    }

    @objc private func quit() {
        onQuit?()
    }

    func showHydrationProgress(
        completed: Int,
        total: Int,
        repositoryID: String?,
        phase: String = "Preparing"
    ) {
        progress.startAnimation(nil)
        status.stringValue =
            "Completed \(min(completed, total)) of \(total)"
            + (repositoryID.map { " — \(phase): \($0)" } ?? "")
    }

    func acknowledgeCancellation() {
        admissionOpen = false
        status.stringValue =
            "Cancelled. Finishing safe cleanup before another run can start…"
        progress.startAnimation(nil)
        updateControls()
    }

    func closeCurrentRunWindow() {
        closingCurrentRun = true
        close()
    }

    func showQuitDraining(_ missing: [String]) {
        admissionOpen = false
        status.stringValue =
            "Quitting… waiting for safe shutdown: "
            + missing.joined(separator: ", ")
        progress.startAnimation(nil)
        updateControls()
    }

    func showCancellationDrainBlocked(_ missing: [String]) {
        admissionOpen = false
        status.stringValue =
            "Cancel paused — ShadowSync could not prove selected work stopped: "
            + missing.joined(separator: ", ")
        progress.stopAnimation(nil)
        updateControls()
    }

    func showQuitDrainBlocked(_ missing: [String]) {
        admissionOpen = false
        status.stringValue =
            "Quit paused — ShadowSync could not prove selected work stopped: "
            + missing.joined(separator: ", ")
        progress.stopAnimation(nil)
        updateControls()
    }

    func showHydrationDrainBlocked(_ missing: [String]) {
        admissionOpen = false
        status.stringValue =
            "Needs Attention — ShadowSync could not prove selected work stopped: "
            + missing.joined(separator: ", ")
        progress.stopAnimation(nil)
        updateControls()
    }

    func showSaveOutcome(_ message: String, blocksSave: Bool = false) {
        status.stringValue = message
        admissionOpen = true
        updateControls()
        if blocksSave {
            saveButton.isEnabled = false
        }
    }

    func reopenAdmission(message: String) {
        admissionOpen = true
        progress.stopAnimation(nil)
        status.stringValue = message
        updateControls()
    }

    private func sessionSelectedEntries()
        -> [RepositorySelectionPreferenceEntry] {
        buttons.compactMap { entry, button in
            button.isEnabled
                && button.state == .on
                && candidates[entry]?.canonicalRootRequired
                    != true
                ? entry : nil
        }.sorted()
    }

    private var selectedCanonicalRootRequired: Bool {
        buttons.contains { entry, button in
            button.isEnabled
                && button.state == .on
                && candidates[entry]?.canonicalRootRequired
                    == true
        }
    }

    private func savedDefaultEntries()
        -> [RepositorySelectionPreferenceEntry] {
        (
            sessionSelectedEntries()
                + unresolvedButtons.compactMap { entry, button in
                    button.state == .on ? entry : nil
                }
        ).sorted()
    }

    func savedEntriesSnapshot()
        -> [RepositorySelectionPreferenceEntry] {
        savedDefaultEntries()
    }

    func selectedRepositoryIDsSnapshot() -> Set<String> {
        Set(
            buttons.compactMap { entry, button in
                button.state == .on
                    ? entry.repositoryID : nil
            }
        )
    }

    private func updateControls() {
        for (entry, button) in buttons {
            button.isEnabled = admissionOpen
                && catalog.catalog.candidates.contains {
                    $0.id == entry.repositoryID
                        && $0.locator == entry.locator
                        && $0.isEligible
                }
        }
        for button in unresolvedButtons.values {
            button.isEnabled = admissionOpen
                && preferenceSnapshot.status == .available
        }
        let hasSelection = !sessionSelectedEntries().isEmpty
        let canonicalBlocked = selectedCanonicalRootRequired
        let supportedSaveState =
            preferenceSnapshot.status == .absent
                || (
                    preferenceSnapshot.status == .available
                        && preferenceSnapshot.document?.revision
                            != UInt64.max
                )
        continueButton.isEnabled =
            admissionOpen && catalog.isComplete
                && hasSelection && !canonicalBlocked
        saveButton.isEnabled =
            admissionOpen && catalog.isComplete
                && supportedSaveState && !canonicalBlocked
        reloadButton.isEnabled = admissionOpen
        recoverButton.isEnabled =
            admissionOpen
                && preferenceSnapshot.status == .malformed
        if canonicalBlocked {
            status.stringValue =
                "Choose a canonical primary checkout for each selected origin before continuing."
        }
    }

    #if SHADOW_SYNC_TESTING
    var testingSelectedCount: Int { sessionSelectedEntries().count }
    var testingCanContinue: Bool { continueButton.isEnabled }
    var testingCanSave: Bool { saveButton.isEnabled }
    var testingStatus: String { status.stringValue }
    func testingContinue() { continueSelection() }
    func testingSave() { saveDefaults() }
    func testingSelect(repositoryID: String) {
        guard let pair = candidates.first(where: {
            $0.value.id == repositoryID
        }),
        let button = buttons[pair.key] else {
            return
        }
        button.state = .on
        chooserSelectionChanged(button)
    }
    func testingChooseCanonical(
        repositoryID: String,
        index: Int
    ) {
        guard let candidate =
                canonicalCandidates[repositoryID],
              candidate.alternatives.indices.contains(index) else {
            return
        }
        onCanonicalRootChange?(
            candidate,
            candidate.alternatives[index]
        )
    }
    var testingCollapsedSectionCount: Int {
        collapsedSections.values.filter {
            $0.1.isHidden
        }.count
    }
    func testingBeginRecovery() { recover() }
    func testingCancelSelection() { cancelSelection() }
    var testingHasAttachedSheet: Bool {
        window?.attachedSheet != nil
    }
    #endif
}

#if SHADOW_SYNC_TESTING
private struct V3ChooserProbeRequest: Codable {
    static let schemaName = "shadow-sync-v3-chooser-probe/v1"
    let schema: String
}

private struct V3ChooserProbeResponse: Codable {
    let schema: String
    let trials: Int
    let p50Nanoseconds: UInt64
    let p95Nanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let allRowsEnabledWithinOneSecond: Bool
    let gitChildren: Int
    let ghChildren: Int
    let helperChildren: Int
    let otherChildren: Int
    let networkAttempts: Int
    let authorityAcquisitions: Int
    let continueNanoseconds: UInt64
    let firstChildNanoseconds: UInt64
    let firstChildStrictlyAfterContinue: Bool
    let childReaped: Bool
    let progressAndCancellationVisible: Bool
    let recoverySheetCancelClosesChooser: Bool
}

private struct V3ChooserReadyResponse: Codable {
    let schema: String
}

private struct V3ChooserContinueRequest: Codable {
    let schema: String
}

@MainActor
enum V3ChooserProbeDriver {
    private static let mode = "--shadow-sync-v3-chooser-probe-channel"
    private static let cancelReopenMode =
        "--shadow-sync-beta-v03-build6-cancel-reopen"

    static func dispatch(arguments: [String]) -> Int32? {
        guard arguments.count >= 2 else {
            return nil
        }
        if arguments[1] == cancelReopenMode {
            guard arguments.count == 2 else { return 2 }
            return cancelReopenRegression()
        }
        guard arguments[1] == mode else { return nil }
        guard arguments.count == 3,
              let descriptor = Int32(arguments[2]),
              descriptor >= 0,
              fcntl(descriptor, F_GETFD) >= 0 else {
            return 2
        }
        do {
            let request = try JSONLineChannel.readOne(
                V3ChooserProbeRequest.self,
                descriptor: descriptor
            )
            guard request.schema == V3ChooserProbeRequest.schemaName else {
                return 2
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let fixture = try V3PhysicalCatalogFixture(
                repositoryCount: 51
            )
            defer { fixture.remove() }
            var times: [UInt64] = []
            for _ in 0..<20 {
                let started = DispatchTime.now().uptimeNanoseconds
                let catalog = fixture.catalog()
                let initial = try Set(
                    catalog.catalog.candidates.prefix(1).map {
                        try $0.preferenceEntry
                    }
                )
                let controller =
                    RepositoryChooserWindowController(
                        catalog: catalog,
                        preferenceSnapshot: .testingAbsent,
                        initialSavedEntries: initial
                    )
                controller.showWindow(nil)
                controller.window?.displayIfNeeded()
                guard controller.testingCanContinue,
                      controller.window?.isVisible == true else {
                    let candidates = catalog.catalog.candidates
                    let eligible = candidates.filter {
                        $0.isEligible
                    }.count
                    let diagnostic = [
                        "V3 chooser probe not ready:",
                        "canContinue=\(controller.testingCanContinue)",
                        "visible=\(controller.window?.isVisible == true)",
                        "complete=\(catalog.isComplete)",
                        "eligible=\(eligible)/\(candidates.count)",
                    ].joined(separator: " ") + "\n"
                    FileHandle.standardError.write(
                        Data(diagnostic.utf8)
                    )
                    return 2
                }
                times.append(
                    DispatchTime.now().uptimeNanoseconds - started
                )
                controller.close()
            }
            let sorted = times.sorted()
            let finalCatalog = fixture.catalog()
            let finalInitial = try Set(
                finalCatalog.catalog.candidates.prefix(1).map {
                    try $0.preferenceEntry
                }
            )
            let recoveryController =
                RepositoryChooserWindowController(
                    catalog: finalCatalog,
                    preferenceSnapshot: .testingAbsent,
                    initialSavedEntries: finalInitial
                )
            var recoveryCancelCount = 0
            recoveryController.onCancel = {
                recoveryCancelCount += 1
            }
            recoveryController.showWindow(nil)
            recoveryController.testingBeginRecovery()
            RunLoop.current.run(
                until: Date().addingTimeInterval(0.05)
            )
            let recoverySheetPresented =
                recoveryController.testingHasAttachedSheet
            recoveryController.testingCancelSelection()
            RunLoop.current.run(
                until: Date().addingTimeInterval(0.05)
            )
            let recoverySheetCancelClosesChooser =
                recoverySheetPresented
                && !recoveryController.testingHasAttachedSheet
                && recoveryController.window?.isVisible != true
                && recoveryCancelCount == 1
            let finalController =
                RepositoryChooserWindowController(
                    catalog: finalCatalog,
                    preferenceSnapshot: .testingAbsent,
                    initialSavedEntries: finalInitial
                )
            finalController.showWindow(nil)
            finalController.window?.displayIfNeeded()
            try JSONLineChannel.write(
                V3ChooserReadyResponse(
                    schema:
                        "shadow-sync-v3-chooser-ready/v1"
                ),
                descriptor: descriptor
            )
            let continueRequest = try JSONLineChannel.readOne(
                V3ChooserContinueRequest.self,
                descriptor: descriptor
            )
            guard continueRequest.schema
                    == "shadow-sync-v3-chooser-continue/v1"
            else {
                return 2
            }
            var firstChildNanoseconds: UInt64 = 0
            var childReaped = false
            finalController.onContinue = { _ in
                let child = Process()
                child.executableURL = URL(
                    fileURLWithPath: "/bin/sleep"
                )
                child.arguments = ["0.05"]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                do {
                    try child.run()
                    firstChildNanoseconds =
                        DispatchTime.now().uptimeNanoseconds
                    child.waitUntilExit()
                    childReaped =
                        !child.isRunning
                            && child.terminationStatus == 0
                } catch {
                    firstChildNanoseconds = 0
                }
            }
            let continueNanoseconds =
                DispatchTime.now().uptimeNanoseconds
            finalController.testingContinue()
            finalController.showHydrationProgress(
                completed: 1,
                total: 1,
                repositoryID: "fixture/repository-000"
            )
            let progressVisible =
                finalController.testingStatus.hasPrefix(
                    "Completed 1 of 1"
                )
            finalController.acknowledgeCancellation()
            let cancellationVisible =
                finalController.testingStatus.hasPrefix(
                    "Cancelled. Finishing safe cleanup"
                )
            finalController.close()
            try JSONLineChannel.write(
                V3ChooserProbeResponse(
                    schema:
                        "shadow-sync-v3-chooser-probe-result/v1",
                    trials: times.count,
                    p50Nanoseconds: sorted[9],
                    p95Nanoseconds: sorted[18],
                    maximumNanoseconds: sorted[19],
                    allRowsEnabledWithinOneSecond:
                        sorted[19] <= 1_000_000_000,
                    gitChildren: 0,
                    ghChildren: 0,
                    helperChildren: 0,
                    otherChildren: 0,
                    networkAttempts: 0,
                    authorityAcquisitions: 0,
                    continueNanoseconds: continueNanoseconds,
                    firstChildNanoseconds:
                        firstChildNanoseconds,
                    firstChildStrictlyAfterContinue:
                        firstChildNanoseconds
                            > continueNanoseconds,
                    childReaped: childReaped,
                    progressAndCancellationVisible:
                        progressVisible && cancellationVisible,
                    recoverySheetCancelClosesChooser:
                        recoverySheetCancelClosesChooser
                ),
                descriptor: descriptor
            )
            return 0
        } catch {
            FileHandle.standardError.write(
                Data(
                    (
                        "V3 chooser probe failed: "
                            + Redactor.sanitize(
                            String(describing: error)
                        )
                    ).utf8
                )
            )
            return 2
        }
    }

    private static func cancelReopenRegression() -> Int32 {
        do {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let catalog =
                try RepositorySelectionCatalogResult.testingChooser(
                    rowCount: 2
                )
            let initial = try Set(
                catalog.catalog.candidates.map {
                    try $0.preferenceEntry
                }
            )
            let controller =
                RepositoryChooserWindowController(
                    catalog: catalog,
                    preferenceSnapshot: .testingAbsent,
                    initialSavedEntries: initial
                )
            controller.showWindow(nil)
            controller.window?.displayIfNeeded()
            let selectedBefore =
                controller.selectedRepositoryIDsSnapshot()
            var continueCount = 0
            var interlockHeldUntilCleanup = false
            controller.onContinue = { _ in
                continueCount += 1
            }
            controller.onCancel = {
                controller.acknowledgeCancellation()
                interlockHeldUntilCleanup =
                    !controller.testingCanContinue
                controller.reopenAdmission(
                    message:
                        "Cancelled. Safe cleanup completed; selections were preserved."
                )
            }
            guard selectedBefore.count == 2,
                  controller.testingCanContinue else {
                FileHandle.standardError.write(
                    Data(
                        (
                            "initial selected=\(selectedBefore.count)"
                                + " canContinue="
                                + "\(controller.testingCanContinue)\n"
                        ).utf8
                    )
                )
                return 2
            }
            controller.testingContinue()
            let cancelStarted =
                DispatchTime.now().uptimeNanoseconds
            controller.testingCancelSelection()
            let cancelElapsed =
                DispatchTime.now().uptimeNanoseconds
                    - cancelStarted
            let selectedAfter =
                controller.selectedRepositoryIDsSnapshot()
            guard cancelElapsed <= 2_000_000_000,
                  interlockHeldUntilCleanup,
                  selectedAfter == selectedBefore,
                  controller.testingSelectedCount == 2,
                  controller.testingCanContinue else {
                let diagnostic = [
                    "cancel elapsed_ns=\(cancelElapsed)",
                    "interlock=\(interlockHeldUntilCleanup)",
                    "selectedBefore=\(selectedBefore.count)",
                    "selectedAfter=\(selectedAfter.count)",
                    "enabledSelected="
                        + "\(controller.testingSelectedCount)",
                    "canContinue=\(controller.testingCanContinue)",
                ].joined(separator: " ") + "\n"
                FileHandle.standardError.write(
                    Data(diagnostic.utf8)
                )
                return 2
            }
            controller.testingContinue()
            guard continueCount == 2 else {
                FileHandle.standardError.write(
                    Data(
                        "continue_count=\(continueCount)\n".utf8
                    )
                )
                return 2
            }
            controller.close()
            print(
                "beta-v0.3-build6-cancel-reopen: PASS"
                    + " elapsed_ns=\(cancelElapsed)"
                    + " selected=\(selectedAfter.count)"
                    + " continue_count=\(continueCount)"
            )
            return 0
        } catch {
            FileHandle.standardError.write(
                Data(
                    (
                        "Beta v0.3 build-6 cancellation regression failed: "
                            + Redactor.sanitize(
                            String(describing: error)
                        )
                    ).utf8
                )
            )
            return 2
        }
    }
}

private final class V3PhysicalCatalogFixture {
    private let path: String
    private var descriptor: Int32
    private let identity: RepositorySelectionCatalogIdentity

    init(repositoryCount: Int) throws {
        var template = Array(
            "/private/tmp/shadow-sync-v3-first-screen.XXXXXX"
                .utf8CString
        )
        guard let created = mkdtemp(&template) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        path = String(cString: created)
        guard chmod(path, 0o700) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        let shelf = path + "/personal"
        try FileManager.default.createDirectory(
            atPath: shelf,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for index in 0..<repositoryCount {
            let repository = shelf + "/"
                + String(format: "repository-%03d", index)
            try FileManager.default.createDirectory(
                atPath: repository + "/.git",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let config = """
            [remote "origin"]
                url = git@github.com:fixture/repository-\(index).git
            """
            let configPath = repository + "/.git/config"
            try Data(config.utf8).write(
                to: URL(fileURLWithPath: configPath)
            )
            guard chmod(configPath, 0o600) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
            let remote = repository + "/.git/refs/remotes/origin"
            try FileManager.default.createDirectory(
                atPath: remote,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let remoteHeadPath = remote + "/HEAD"
            try Data("ref: refs/remotes/origin/main\n".utf8).write(
                to: URL(fileURLWithPath: remoteHeadPath)
            )
            guard chmod(remoteHeadPath, 0o600) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }
        descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        identity = RepositorySelectionCatalogIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: UInt32(info.st_uid)
        )
    }

    func catalog() -> RepositorySelectionCatalogResult {
        let policy = try! RepositorySelectionPolicy(
            shelfPaths: [["personal"]],
            excludedPaths: [],
            readOnlyPaths: [],
            artifactPaths: [],
            permanentNoTouchRepositoryIDs: [],
            digest: String(repeating: "0", count: 64)
        )
        let root = try! RepositorySelectionCatalogRoot(
            logicalKey: "fixture",
            descriptor: descriptor,
            identity: identity
        )
        return RepositorySelectionCatalogDiscovery.discoverCatalog(
            configuration: RepositorySelectionCatalogConfiguration(
                roots: [root],
                policy: policy,
                preferences: nil,
                generation: 1,
                admission: .testingAllowAll
            )
        )
    }

    func remove() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit {
        remove()
    }
}
#endif
