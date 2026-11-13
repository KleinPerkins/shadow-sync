import ShadowSyncCore
import Foundation

enum ShadowSyncPresentation {
    static let appTitle = "ShadowSync"
    static let selectionTitle = "Update local main branches"
    static let preparingRepositoryList = "Preparing repository list…"
    static let selectAll = "Select All"
    static let clearAll = "Clear All"
    static let reviewSelection = "Review Selection…"
    static let cancelSelection = "Cancel"
    static let zeroSelection = "Select at least one repository to continue."
    static let help = "Eligible clean main working copies can be selected. Blocked repositories stay visible with the first reason they cannot run. Cached origin/main status uses local refs only and is not current GitHub state."
    static let confirmationText = "The utility will fetch origin and update only repositories that can be fast-forwarded safely. It will not switch branches, discard work, or repair repositories."
    static let back = "Back"
    static let cancel = "Cancel"
    static let startUpdate = "Start Update"
    static let shortcutUnavailable = "Keyboard Shortcut Unavailable"
    static let shortcutUnavailableText = "Control-Option-Command-M is already in use by another app. Use the ShadowSync menu to start or restore a run."
    static let hiddenStatusItemGuidance = "macOS is hiding the ShadowSync menu icon. Use ⌃⌥⌘M to open this window. To restore the icon, enable it in System Settings → Menu Bar; macOS may list it under Cursor, and that setting may also show other Cursor menu items."
    static let foregroundUnavailable = "macOS did not foreground ShadowSync. Open the status menu and choose the relevant action to try again."
    static let foregroundUnavailableWithHiddenStatusItem = "macOS did not foreground ShadowSync. Use ⌃⌥⌘M to try again. The menu icon remains hidden until it is enabled in System Settings → Menu Bar."
    static let stopTitle = "Stop this run?"
    static let stopText = "The current Git operation will be asked to stop. Repositories already completed will stay completed. Remaining repositories will be marked Cancelled."
    static let keepRunning = "Keep Running"
    static let stopRun = "Stop Run"
    static let activeRunTitle = "A run is already active"
    static let cancelNewLaunch = "Cancel New Launch"
    static let stopExisting = "Stop Existing & Start New…"
    static let takeoverTitle = "Stop the active run?"
    static let takeoverText = "The current Git operation will be asked to stop first. If it does not exit, only this run’s verified process group will be force-stopped. The existing log remains available until a new run acquires ownership."
    static let keepExisting = "Keep Existing Run"
    static let stopAndStart = "Stop & Start New"
    static let unverifiedOwner = "Nothing was stopped because ShadowSync could not verify ownership of the active process. No new run was started."
    static let openLog = "Open Log"
    static let cancelRun = "Cancel Run"
    static let closeRun = "Close Run"
    static let startNewRun = "Start New Run…"
    static let showCurrentRun = "Show Current Run"
    static let showLastReport = "Show Last Report"
    static let historicalBatchTitle =
        "ShadowSync · Last report (read-only)"
    static let previousReportNeedsAttention =
        "Previous run completed with issues. Show Last Report when convenient."
    static let openAtLogin = "Open ShadowSync at Login"
    static let openLatestLog = "Open Latest Log"
    static let quitUtility = "Quit ShadowSync"
    static let logOpenFailure = "The latest log could not be opened safely. Try again. If it still fails, ask an agent to review ShadowSync’s private state folder."
    static let locationAttentionTitle = "Repository locations need attention"
    static let locationAttentionText = "ShadowSync could not safely distinguish one or more local checkouts. No run was started. Review the repository locations, then try again."

    static func confirmationTitle(repositoryCount: Int) -> String {
        "Ready to update \(repositoryCount) repositories"
    }

    static var confirmationTitle: String {
        confirmationTitle(repositoryCount: 1)
    }

    static func activeRunText(repositoryCount: Int) -> String {
        "ShadowSync is already updating \(repositoryCount) repositories. You can keep that run, or stop it safely and start a new selection. Repositories already completed will not be rolled back."
    }
}

struct Body3RunMetadataPresentation:
    Equatable, Sendable {
    let timing: String
    let summary: String

    static func make(
        plan: Body3BatchPlan,
        report: Body3BatchReport,
        timeZone: TimeZone = .autoupdatingCurrent
    ) throws -> Body3RunMetadataPresentation {
        let metadata = try Body3BatchMetadata.derive(
            plan: plan,
            report: report
        )
        let statusOrder: [Body3BatchNodeStatus] = [
            .succeeded,
            .skipped,
            .refused,
            .failed,
            .cancelled,
            .cleanupPending,
        ]
        let labels: [Body3BatchNodeStatus: String] = [
            .succeeded: "succeeded",
            .skipped: "skipped",
            .refused: "refused",
            .failed: "failed",
            .cancelled: "cancelled",
            .cleanupPending: "cleanup pending",
        ]
        let outcomeText = statusOrder.compactMap {
            status -> String? in
            guard let count = metadata.outcomeCounts[status],
                  count > 0 else {
                return nil
            }
            return "\(count) \(labels[status]!)"
        }.joined(separator: " · ")
        return Body3RunMetadataPresentation(
            timing:
                "Started \(try localTimestamp(metadata.startedAt, timeZone: timeZone)) · \(report.cleanupPending ? "Observed" : "Ended") \(try localTimestamp(metadata.endedAt, timeZone: timeZone)) · Duration \(duration(metadata.durationMilliseconds))",
            summary:
                "\(metadata.repositoryIDs.count) repositor\(metadata.repositoryIDs.count == 1 ? "y" : "ies") · "
                + "\(metadata.attemptedActionCount) attempted action\(metadata.attemptedActionCount == 1 ? "" : "s")"
                + (outcomeText.isEmpty ? "" : " · \(outcomeText)")
        )
    }

    static func localTimestamp(
        _ persistedUTC: String,
        timeZone: TimeZone
    ) throws -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: persistedUTC)
                ?? wholeSeconds.date(from: persistedUTC) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 report timestamp is invalid"
            )
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a zzz"
        return formatter.string(from: date)
    }

    static func duration(_ milliseconds: Int64) -> String {
        let wholeSeconds =
            milliseconds / 1_000
            + (milliseconds % 1_000 >= 500 ? 1 : 0)
        let days = wholeSeconds / 86_400
        let hours = (wholeSeconds % 86_400) / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let seconds = wholeSeconds % 60
        let parts = [
            durationPart(days, "day"),
            durationPart(hours, "hour"),
            durationPart(minutes, "minute"),
            durationPart(seconds, "second"),
        ].compactMap { $0 }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    private static func durationPart(
        _ value: Int64,
        _ unit: String
    ) -> String? {
        guard value > 0 else {
            return nil
        }
        return "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}

enum RunRowStatus: Equatable, Sendable {
    case pending
    case checking
    case fetching
    case updating
    case updated
    case alreadyCurrent
    case skipped
    case updatedWithWarning
    case failed
    case needsAttention
    case cleanupPending
    case stopping
    case cancelled

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .checking: return "Checking"
        case .fetching: return "Fetching"
        case .updating: return "Updating"
        case .updated: return "Updated"
        case .alreadyCurrent: return "Already Current"
        case .skipped: return "Skipped"
        case .updatedWithWarning: return "Updated with Warning"
        case .failed: return "Failed"
        case .needsAttention: return "Needs Attention"
        case .cleanupPending: return "Cleanup Pending"
        case .stopping: return "Stopping…"
        case .cancelled: return "Cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .updated, .alreadyCurrent, .skipped, .updatedWithWarning,
             .failed, .needsAttention, .cancelled:
            return true
        case .pending, .checking, .fetching, .updating, .stopping, .cleanupPending:
            return false
        }
    }

    static func result(_ code: ResultCode) -> RunRowStatus {
        switch code {
        case .updated, .updatedBeforeCancellation:
            return .updated
        case .alreadyCurrent:
            return .alreadyCurrent
        case .updatedWithWarning:
            return .updatedWithWarning
        case .failedInspection, .failedFetchAuthentication, .failedFetchNetwork,
             .failedFetch, .failedUpdate:
            return .failed
        case .needsAttention:
            return .needsAttention
        case .cleanupPending:
            return .cleanupPending
        case .cancelledPending, .cancelledDuringFetch, .cancelledNoUpdate:
            return .cancelled
        case .skippedAhead, .skippedDiverged, .skippedDirty, .skippedBusy,
             .skippedDetachedHead, .skippedPrimaryNotOnMain,
             .skippedMainInLinkedWorktree,
             .skippedLocalMainMissing, .skippedRemoteMainMissing,
             .skippedHiddenIndexState, .skippedUnsupportedHookFramework,
             .skippedRepositoryRemoved, .skippedOriginChanged,
             .skippedIgnoredFileCollision:
            return .skipped
        }
    }
}

enum ResultCodePresentation {
    static func label(for code: ResultCode) -> String {
        RunRowStatus.result(code).label
    }
}

enum ShadowSyncStatusSymbol {
    static func phase(_ phase: RepositoryPhase) -> (name: String, description: String) {
        switch phase {
        case .pending: return ("clock", "Pending")
        case .checking: return ("magnifyingglass", "Checking")
        case .fetching: return ("arrow.down.circle", "Fetching")
        case .updating: return ("arrow.triangle.2.circlepath", "Updating")
        case .stopping: return ("stop.circle", "Stopping")
        case .complete: return ("checkmark.circle", "Complete")
        }
    }

    static func result(_ resultClass: ResultClass?) -> (name: String, description: String) {
        switch resultClass {
        case .success: return ("checkmark.circle", "Success")
        case .warning: return ("exclamationmark.triangle", "Warning")
        case .failure: return ("xmark.octagon", "Failure")
        case .cancelled: return ("stop.circle", "Cancelled")
        case nil: return ("questionmark.circle", "No result")
        }
    }

    static func rowStatus(_ status: RunRowStatus) -> (name: String, description: String) {
        switch status {
        case .pending: return ("clock", status.label)
        case .checking: return ("magnifyingglass", status.label)
        case .fetching: return ("arrow.down.circle", status.label)
        case .updating: return ("arrow.triangle.2.circlepath", status.label)
        case .updated: return ("checkmark.circle.fill", status.label)
        case .alreadyCurrent: return ("checkmark.circle", status.label)
        case .skipped: return ("forward.end.circle", status.label)
        case .updatedWithWarning: return ("exclamationmark.triangle.fill", status.label)
        case .failed: return ("xmark.octagon", status.label)
        case .needsAttention: return ("exclamationmark.octagon", status.label)
        case .cleanupPending: return ("clock.badge.exclamationmark", status.label)
        case .stopping: return ("stop.circle", "Stopping")
        case .cancelled: return ("stop.circle.fill", status.label)
        }
    }
}

struct RunRowPresentation: Equatable, Sendable {
    let repository: RepositoryCandidate
    let showsLocation: Bool
    private(set) var authoritativeStatus: RunRowStatus
    private(set) var stoppingOverlayRequested: Bool
    private(set) var startedAt: String?
    private(set) var result: RepositoryResult?

    init(repository: RepositoryCandidate, showsLocation: Bool = false) {
        self.repository = repository
        self.showsLocation = showsLocation
        authoritativeStatus = .pending
        stoppingOverlayRequested = false
        startedAt = nil
        result = nil
    }

    var status: RunRowStatus {
        if stoppingOverlayRequested,
           result == nil,
           authoritativeStatus != .pending {
            return .stopping
        }
        return authoritativeStatus
    }

    mutating func apply(phase: RepositoryPhase, timestamp: String) throws -> Bool {
        guard result == nil else {
            if phase == .complete {
                return false
            }
            throw RunPresentationError.nonMonotonicState(repository.path)
        }
        guard phase != .complete else {
            return false
        }
        let next = Self.status(for: phase)
        guard Self.canTransition(from: authoritativeStatus, to: next) else {
            throw RunPresentationError.nonMonotonicState(repository.path)
        }
        guard authoritativeStatus != next else {
            return false
        }
        if startedAt == nil, phase != .pending {
            startedAt = timestamp
        }
        authoritativeStatus = next
        return true
    }

    static func status(for phase: RepositoryPhase) -> RunRowStatus {
        switch phase {
        case .pending:
            return .pending
        case .checking:
            return .checking
        case .fetching:
            return .fetching
        case .updating:
            return .updating
        case .stopping:
            return .stopping
        case .complete:
            return .updated
        }
    }

    mutating func requestStoppingOverlay() -> Bool {
        guard result == nil,
              authoritativeStatus != .pending,
              !authoritativeStatus.isTerminal,
              !stoppingOverlayRequested else {
            return false
        }
        stoppingOverlayRequested = true
        return true
    }

    mutating func clearStoppingOverlay() {
        stoppingOverlayRequested = false
    }

    mutating func apply(result incoming: RepositoryResult) throws -> Bool {
        guard incoming.repository == repository,
              incoming.resultClass == incoming.code.resultClass else {
            throw RunPresentationError.resultMismatch(repository.path)
        }
        if let result {
            guard result == incoming else {
                throw RunPresentationError.conflictingResult(repository.path)
            }
            return false
        }
        result = incoming
        startedAt = incoming.startedAt
        authoritativeStatus = .result(incoming.code)
        stoppingOverlayRequested = false
        return true
    }

    var detailText: String {
        guard let result else {
            return ""
        }
        let updateLabel = result.defaultBranch.map {
            "Default branch (\($0)) updated"
        } ?? "Main updated"
        return """
        Result: \(result.code.rawValue)
        Fetched: \(result.fetched ? "Yes" : "No") · \(updateLabel): \(result.mainUpdated ? "Yes" : "No")
        Started: \(result.startedAt) · Ended: \(result.endedAt) · Duration: \(result.durationMilliseconds) ms
        Before: \(result.beforeCommit ?? "Unavailable")
        Target: \(result.targetCommit ?? "Unavailable")
        After: \(result.afterCommit ?? "Unavailable")
        \(result.explanation)
        """
    }

    var accessibilityValue: String {
        let location = showsLocation
            ? RepositoryOperatorPresentation.secondaryLocation(repository)
                .map { ", location \($0)" } ?? ""
            : ""
        let identity =
            "\(RepositoryOperatorPresentation.primaryName(repository))\(location)"
        if detailText.isEmpty {
            return "\(identity). \(status.label)."
        }
        return "\(identity). \(status.label). \(detailText)"
    }

    private static func canTransition(
        from current: RunRowStatus,
        to next: RunRowStatus
    ) -> Bool {
        if current == next {
            return true
        }
        switch (current, next) {
        case (.pending, .checking),
             (.checking, .fetching),
             (.fetching, .updating),
             (.checking, .stopping),
             (.fetching, .stopping),
             (.updating, .stopping):
            return true
        default:
            return false
        }
    }
}

enum RunPresentationChange: Equatable, Sendable {
    case none
    case runStarted
    case row(Int)
    case runFinished(String)
}

enum RunPresentationError: Error, CustomStringConvertible, Equatable {
    case wrongRun
    case eventSequence(expected: Int, actual: Int)
    case invalidRunStart
    case unknownRepository(String)
    case malformedEvent
    case nonMonotonicState(String)
    case resultMismatch(String)
    case conflictingResult(String)
    case incompleteTerminalEvent
    case reportMismatch
    case invalidReportTerminalState
    case invalidReportTimestamp
    case invalidReportDuration
    case invalidReportSummary
    #if SHADOW_SYNC_TESTING
    case injectedReportStagingFailure
    #endif

    var description: String {
        switch self {
        case .wrongRun:
            return "the presentation event belongs to a different run"
        case let .eventSequence(expected, actual):
            return "presentation event sequence is not contiguous (expected \(expected), received \(actual))"
        case .invalidRunStart:
            return "the run-start event is missing or out of order"
        case .unknownRepository:
            return "the presentation event names an unknown repository"
        case .malformedEvent:
            return "the presentation event shape is invalid"
        case .nonMonotonicState:
            return "the repository presentation state moved backward"
        case .resultMismatch:
            return "the terminal result does not match its selected repository"
        case .conflictingResult:
            return "the repository received conflicting terminal results"
        case .incompleteTerminalEvent:
            return "the run-finished event arrived before every repository had a terminal result"
        case .reportMismatch:
            return "the final report does not exactly match the selected run"
        case .invalidReportTerminalState:
            return "the final report arrived before the live run reached its terminal event"
        case .invalidReportTimestamp:
            return "the final report contains an invalid timestamp"
        case .invalidReportDuration:
            return "the final report contains an invalid duration"
        case .invalidReportSummary:
            return "the final report contains an invalid summary"
        #if SHADOW_SYNC_TESTING
        case .injectedReportStagingFailure:
            return "the final report staging fault was injected"
        #endif
        }
    }
}

enum RunReportApplicationPolicy: Equatable, Sendable {
    case liveWorker
    case historicalOrRecovery
}

struct StagedRunReportPresentation: Equatable, Sendable {
    let reducer: RunPresentationReducer
    let changedRows: [Int]
}

struct RunPresentationReducer: Equatable, Sendable {
    let runID: String
    private let indexByPath: [String: Int]
    private(set) var rows: [RunRowPresentation]
    private(set) var lastEventSequence = 0
    private(set) var runStarted = false
    private(set) var terminalEventReceived = false
    private(set) var activeRowIndex: Int?
    private(set) var stoppingOverlayRequested = false

    init(runID: String, candidates: [RepositoryCandidate]) {
        self.runID = runID
        rows = candidates.map {
            RunRowPresentation(
                repository: $0,
                showsLocation: true
            )
        }
        indexByPath = Dictionary(
            uniqueKeysWithValues: candidates.enumerated().map { ($0.element.path, $0.offset) }
        )
    }

    mutating func apply(_ event: RunEvent) throws -> RunPresentationChange {
        guard event.schema == shadowSyncEventSchema, event.run == runID else {
            throw RunPresentationError.wrongRun
        }
        guard !terminalEventReceived else {
            return .none
        }
        let expectedSequence = lastEventSequence + 1
        guard event.sequence == expectedSequence else {
            throw RunPresentationError.eventSequence(
                expected: expectedSequence,
                actual: event.sequence
            )
        }

        let change: RunPresentationChange
        switch event.type {
        case .runStarted:
            guard event.sequence == 1,
                  !runStarted,
                  event.repositoryID == nil,
                  event.phase == nil,
                  event.result == nil else {
                throw RunPresentationError.invalidRunStart
            }
            runStarted = true
            change = .runStarted
        case .repositoryPhase:
            guard runStarted,
                  let path = event.repositoryID,
                  let phase = event.phase,
                  event.result == nil,
                  let index = indexByPath[path] else {
                throw RunPresentationError.malformedEvent
            }
            let phaseChanged = try rows[index].apply(
                phase: phase,
                timestamp: event.timestamp
            )
            var overlayChanged = false
            if phase != .complete, rows[index].result == nil {
                activeRowIndex = index
                if stoppingOverlayRequested {
                    overlayChanged = rows[index].requestStoppingOverlay()
                }
            }
            change = phaseChanged || overlayChanged ? .row(index) : .none
        case .repositoryResult:
            guard runStarted,
                  let path = event.repositoryID,
                  let result = event.result,
                  event.phase == .complete,
                  let index = indexByPath[path],
                  result.repository.path == path else {
                throw RunPresentationError.malformedEvent
            }
            let changed = try rows[index].apply(result: result)
            if activeRowIndex == index {
                activeRowIndex = nil
            }
            change = changed ? .row(index) : .none
        case .runFinished:
            guard runStarted,
                  event.repositoryID == nil,
                  event.phase == nil,
                  event.result == nil else {
                throw RunPresentationError.malformedEvent
            }
            guard rows.allSatisfy(\.authoritativeStatus.isTerminal) else {
                throw RunPresentationError.incompleteTerminalEvent
            }
            terminalEventReceived = true
            activeRowIndex = nil
            change = .runFinished(event.message ?? "Run complete")
        case .diagnostic:
            guard runStarted,
                  event.repositoryID == nil,
                  event.phase == nil,
                  event.result == nil else {
                throw RunPresentationError.malformedEvent
            }
            change = .none
        }
        lastEventSequence = event.sequence
        return change
    }

    mutating func requestStoppingOverlay() -> Int? {
        stoppingOverlayRequested = true
        guard let activeRowIndex,
              rows[activeRowIndex].requestStoppingOverlay() else {
            return nil
        }
        return activeRowIndex
    }

    func staging(
        report: RunReport,
        policy: RunReportApplicationPolicy
    ) throws -> StagedRunReportPresentation {
        try staging(
            report: report,
            policy: policy,
            failAfterAppliedRow: nil
        )
    }

    mutating func apply(
        report: RunReport,
        policy: RunReportApplicationPolicy = .historicalOrRecovery
    ) throws -> [Int] {
        let staged = try staging(report: report, policy: policy)
        self = staged.reducer
        return staged.changedRows
    }

    #if SHADOW_SYNC_TESTING
    mutating func testingApply(
        report: RunReport,
        policy: RunReportApplicationPolicy = .historicalOrRecovery,
        failAfterAppliedRow: Int
    ) throws -> [Int] {
        let staged = try staging(
            report: report,
            policy: policy,
            failAfterAppliedRow: failAfterAppliedRow
        )
        self = staged.reducer
        return staged.changedRows
    }
    #endif

    private func staging(
        report: RunReport,
        policy: RunReportApplicationPolicy,
        failAfterAppliedRow: Int?
    ) throws -> StagedRunReportPresentation {
        let repositories = rows.map(\.repository)
        let repositoriesArePresentable =
            report.repositoryModel == "v2"
                ? RepositoryOperatorPresentation.canPresent(repositories)
                : RepositoryOperatorPresentation.canConfirm(repositories)
        guard report.schema == "shadow-sync-report/v1",
              report.repositoryModel == nil
                || report.repositoryModel == "v2",
              RunIdentity.isValid(report.run),
              report.run == runID,
              report.results.count == rows.count,
              repositoriesArePresentable,
              rows.allSatisfy({
                  $0.repository.hasValidatedOriginIdentity
              }),
              report.cancellationState
                == (report.cancelled ? .cancelled : .notCancelled) else {
            throw RunPresentationError.reportMismatch
        }
        if policy == .liveWorker {
            guard report.repositoryModel == "v2",
                  runStarted,
                  terminalEventReceived,
                  activeRowIndex == nil,
                  rows.allSatisfy(\.authoritativeStatus.isTerminal) else {
                throw RunPresentationError.invalidReportTerminalState
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        guard let runStartedAt = formatter.date(from: report.startedAt),
              let runEndedAt = formatter.date(from: report.endedAt),
              runEndedAt >= runStartedAt else {
            throw RunPresentationError.invalidReportTimestamp
        }
        guard report.durationMilliseconds >= 0 else {
            throw RunPresentationError.invalidReportDuration
        }
        if let summaryOverride = report.summaryOverride,
           summaryOverride != InterruptedRunReconstructor.summary {
            throw RunPresentationError.invalidReportSummary
        }
        let summary = report.summary
        guard !summary.isEmpty,
              summary.utf8.count <= 1_024,
              !summary.contains("\n"),
              !summary.contains("\r"),
              !summary.contains("\0") else {
            throw RunPresentationError.invalidReportSummary
        }

        for (index, result) in report.results.enumerated() {
            guard result.repository == rows[index].repository,
                  result.repository.hasValidatedOriginIdentity,
                  result.resultClass == result.code.resultClass else {
                throw RunPresentationError.reportMismatch
            }
            guard let resultStartedAt = formatter.date(from: result.startedAt),
                  let resultEndedAt = formatter.date(from: result.endedAt),
                  resultEndedAt >= resultStartedAt else {
                throw RunPresentationError.invalidReportTimestamp
            }
            guard result.durationMilliseconds >= 0 else {
                throw RunPresentationError.invalidReportDuration
            }
            guard !result.explanation.isEmpty,
                  result.explanation.utf8.count <= 4_096,
                  !result.explanation.contains("\0") else {
                throw RunPresentationError.reportMismatch
            }
        }

        var staged = self
        var changed: [Int] = []
        changed.reserveCapacity(rows.count)
        for index in staged.rows.indices {
            if try staged.rows[index].apply(result: report.results[index]) {
                changed.append(index)
            }
            #if SHADOW_SYNC_TESTING
            if failAfterAppliedRow == index {
                throw RunPresentationError.injectedReportStagingFailure
            }
            #endif
        }
        staged.activeRowIndex = nil
        staged.stoppingOverlayRequested = false
        for index in staged.rows.indices {
            staged.rows[index].clearStoppingOverlay()
        }
        staged.terminalEventReceived = true
        return StagedRunReportPresentation(
            reducer: staged,
            changedRows: changed
        )
    }
}

enum RunReportPresentation {
    static func metadata(_ report: RunReport) -> String {
        let model =
            LegacyRunPresentation.isLegacy(report)
            ? "\(LegacyRunPresentation.label) · "
            : ""
        return model
            + "Run started: \(report.startedAt) · Ended: \(report.endedAt) · Duration: \(report.durationMilliseconds) ms · Cancellation: \(report.cancellationState.rawValue)"
    }
}
