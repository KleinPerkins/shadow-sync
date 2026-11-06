import AppKit
import ShadowSyncCore

@MainActor
enum ShadowSyncAlertFactory {
    static func confirmation(
        candidates: [RepositoryCandidate]
    ) -> NSAlert {
        guard RepositoryOperatorPresentation.canConfirm(candidates) else {
            return make(
                title: ShadowSyncPresentation.locationAttentionTitle,
                text: ShadowSyncPresentation.locationAttentionText,
                buttons: [ShadowSyncPresentation.cancel],
                safeDefaultIndex: 0,
                destructiveIndices: [],
                warning: true
            )
        }
        let rows = candidates.map {
            RepositoryOperatorPresentation.confirmationLabel($0)
        }.joined(separator: "\n")
        return make(
            title: ShadowSyncPresentation.confirmationTitle(
                repositoryCount: candidates.count
            ),
            text: "\(rows)\n\n\(ShadowSyncPresentation.confirmationText)",
            buttons: [
                ShadowSyncPresentation.back,
                ShadowSyncPresentation.cancel,
                ShadowSyncPresentation.startUpdate,
            ],
            safeDefaultIndex: 0,
            escapeIndex: 1,
            destructiveIndices: [2]
        )
    }

    static func cancellation() -> NSAlert {
        make(
            title: ShadowSyncPresentation.stopTitle,
            text: ShadowSyncPresentation.stopText,
            buttons: [
                ShadowSyncPresentation.keepRunning,
                ShadowSyncPresentation.stopRun,
            ],
            safeDefaultIndex: 0,
            destructiveIndices: [1],
            warning: true
        )
    }

    static func activeRun(repositoryCount: Int) -> NSAlert {
        make(
            title: ShadowSyncPresentation.activeRunTitle,
            text: ShadowSyncPresentation.activeRunText(
                repositoryCount: repositoryCount
            ),
            buttons: [
                ShadowSyncPresentation.cancelNewLaunch,
                ShadowSyncPresentation.stopExisting,
            ],
            safeDefaultIndex: 0,
            destructiveIndices: [1],
            warning: true
        )
    }

    static func takeover() -> NSAlert {
        make(
            title: ShadowSyncPresentation.takeoverTitle,
            text: ShadowSyncPresentation.takeoverText,
            buttons: [
                ShadowSyncPresentation.keepExisting,
                ShadowSyncPresentation.stopAndStart,
            ],
            safeDefaultIndex: 0,
            destructiveIndices: [1],
            warning: true
        )
    }

    static func quitActiveRun() -> NSAlert {
        cancellation()
    }

    static func shortcutUnavailable() -> NSAlert {
        make(
            title: ShadowSyncPresentation.shortcutUnavailable,
            text: ShadowSyncPresentation.shortcutUnavailableText,
            buttons: ["OK"],
            safeDefaultIndex: 0,
            destructiveIndices: [],
            warning: true
        )
    }

    static func operationContention() -> NSAlert {
        make(
            title: InterruptedRunReconstructor.operationContentionTitle,
            text: """
            \(InterruptedRunReconstructor.operationContentionMessage)

            \(InterruptedRunReconstructor.operationContentionRecovery)
            """,
            buttons: ["Close"],
            safeDefaultIndex: 0,
            destructiveIndices: [],
            warning: true
        )
    }

    private static func make(
        title: String,
        text: String,
        buttons: [String],
        safeDefaultIndex: Int,
        escapeIndex: Int? = nil,
        destructiveIndices: Set<Int>,
        warning: Bool = false
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = warning ? .warning : .informational
        alert.showsSuppressionButton = false
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            button.keyEquivalent = ""
            button.keyEquivalentModifierMask = []
            button.setAccessibilityLabel(title)
            button.setAccessibilityHelp(
                destructiveIndices.contains(index)
                    ? "Performs this action only after explicit activation."
                    : "Keeps repository state unchanged."
            )
        }
        if buttons.indices.contains(safeDefaultIndex) {
            alert.buttons[safeDefaultIndex].keyEquivalent = "\r"
        }
        if let escapeIndex,
           escapeIndex != safeDefaultIndex,
           buttons.indices.contains(escapeIndex) {
            alert.buttons[escapeIndex].keyEquivalent = "\u{1b}"
        }
        return alert
    }

    #if SHADOW_SYNC_TESTING
    static func testingSnapshot(
        _ alert: NSAlert
    ) -> (
        title: String,
        text: String,
        buttons: [String],
        keyEquivalents: [String],
        accessibilityLabels: [String?],
        accessibilityHelp: [String?],
        showsSuppressionButton: Bool
    ) {
        (
            alert.messageText,
            alert.informativeText,
            alert.buttons.map(\.title),
            alert.buttons.map(\.keyEquivalent),
            alert.buttons.map { $0.accessibilityLabel() },
            alert.buttons.map { $0.accessibilityHelp() },
            alert.showsSuppressionButton
        )
    }
    #endif
}
