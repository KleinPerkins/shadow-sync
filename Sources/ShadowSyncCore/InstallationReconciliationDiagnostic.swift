#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

// Case-local observation only: no owner, lease, request, path, PID or Error is
// retained. The caller is synchronous; this probe adds no lock or validation.
final class InstallationReconciliationDiagnostic {
    enum Part: String { case unpublishedKickstart, beforeSpawn, afterAnchor, afterOwner }
    enum Stage: String {
        case fixtureSetup, completeAdmission, bootstrap, bootstrapIntent, kickstartIntent
        case context, prepare, fault, start, wait, terminal, actualOutcome, retirementToken
        case releaseAliases, retirementWait, retirementValidate, terminalAssertion
        case archiveRead, controlAssertion, stopOnly, beginRecovery, observation, reconcile
        case resolvedAssertion, replayRefusal
        case observationContext, observationLifecycleRefusal, observationPrepare
        case observationStart, observationWait, observationAssertion, observationToken
        case observationAliasRefusal, observationRelease, observationHelpers, observationRetirement
    }
    enum Boundary: String {
        case fixtureEntry, preparedIntent, installationRetirement, transfer, journal, retainJournal
        case bodyEntered, bodyFailed, bodyReturned
        case readinessCloseEntry, readinessCloseFailed, readinessCloseReturned
        case exclusion, preparationCaught, preparationCleanupEntry
        case preparationCleanupFailed, preparationCleanupReturned, preparationRethrow
        case rootCaught, rootCleanupEntry, rootCleanupFailed, rootCleanupReturned, rootRethrow
        case fixtureReturned
    }
    enum Failure: String {
        case none, fenced, busy, conflict, invalidResource, assertion, other
        init(_ error: Error) {
            let savedDiagnosticErrno = errno
            defer { errno = savedDiagnosticErrno }
            switch error {
            case CustodyRecordError.fenced: self = .fenced
            case CustodyRecordError.busy: self = .busy
            case CustodyRecordError.conflict: self = .conflict
            case CustodyResourceError.invalidResource: self = .invalidResource
            case is InstallationStorageFixtures.Failure: self = .assertion
            default: self = .other
            }
        }
    }
    enum Origin: String { case setup, body, bodyRethrow, cleanup, returned }
    enum Edge: String { case entered, firstSetupFailure, firstBodyFailure, firstExclusionFailure, readinessFailure, preparationFailure, outerFailure, returned }
    // A captured record contains only the same closed values sent to stderr.
    // The test sink is a bounded value array, never an escaping callback.
    struct Record: Equatable {
        let part: Part
        let stage: Stage
        let bootstrap: InstallationStagedCompletionFixtures.CompletionPhase?
        let boundary: Boundary
        let origin: Origin
        let edge: Edge
        let failure: Failure
        var line: String {
            "M6 STAGED RECONCILIATION DIAGNOSTIC part=\(part.rawValue) stage=\(stage.rawValue) bootstrap=\(bootstrap?.rawValue ?? "none") boundary=\(boundary.rawValue) origin=\(origin.rawValue) edge=\(edge.rawValue) error=\(failure.rawValue)\n"
        }
    }
    typealias Observer = (Boundary, Failure) -> Void
    private var capturedRecords: [Record]?
    var testingRecords: [Record] { capturedRecords ?? [] }
    private let enabled: Bool
    private var records = 0
    private var part: Part = .unpublishedKickstart
    private var stage: Stage = .fixtureSetup
    private var bootstrap: InstallationStagedCompletionFixtures.CompletionPhase?
    private var boundary: Boundary = .fixtureEntry
    private var origin: Origin = .setup
    private var rootPendingOrigin: Origin?
    private var bodyEntered = false
    private var bodyFailed = false
    private var firstFailureRecorded = false
    private var readinessFailureRecorded = false
    private var preparationFailureRecorded = false
    init() {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        enabled = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_M6_DIAGNOSTICS"] == "1"
    }
    init(testingEnabled: Bool) {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        enabled = testingEnabled
        capturedRecords = []
    }
    func begin(_ part: Part) {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        self.part = part; stage = .fixtureSetup; bootstrap = nil
        boundary = .fixtureEntry; origin = .setup; bodyEntered = false; bodyFailed = false
        emit(.entered)
    }
    func mark(_ stage: Stage) {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        self.stage = stage; bootstrap = nil
        emit(.entered)
    }
    func bootstrapStage(_ phase: InstallationStagedCompletionFixtures.CompletionPhase) {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        stage = .bootstrap; bootstrap = phase
        emit(.entered)
    }
    func observe(_ boundary: Boundary, _ failure: Failure) {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        if (boundary == .preparationCaught || boundary == .rootCaught), !firstFailureRecorded {
            // Exclusion runs after successful body/readiness close. Preserve its
            // initiating error and current boundary before cleanup can replace it.
            // It shares the first-failure reservation with setup/body failures.
            if self.boundary == .exclusion {
                firstFailureRecorded = true
                emit(.firstExclusionFailure, failure, terminal: true)
            } else if !bodyEntered {
                firstFailureRecorded = true
                emit(.firstSetupFailure, failure, terminal: true)
            }
        }
        self.boundary = boundary
        switch boundary {
        case .rootCleanupEntry: rootPendingOrigin = origin; origin = .cleanup
        case .rootCleanupFailed: origin = .cleanup
        case .rootRethrow: origin = rootPendingOrigin ?? .setup
        case .bodyEntered: bodyEntered = true; origin = .body
        case .bodyFailed:
            bodyFailed = true
            if !firstFailureRecorded {
                firstFailureRecorded = true
                emit(.firstBodyFailure, failure, terminal: true)
            }
            return
        case .readinessCloseEntry, .preparationCleanupEntry, .exclusion: origin = .cleanup
        case .readinessCloseFailed:
            origin = .cleanup
            if !readinessFailureRecorded {
                readinessFailureRecorded = true
                emit(.readinessFailure, failure, terminal: true)
            }
            return
        case .preparationCleanupFailed:
            origin = .cleanup
            if !preparationFailureRecorded {
                preparationFailureRecorded = true
                emit(.preparationFailure, failure, terminal: true)
            }
            return
        case .preparationRethrow:
            if !readinessFailureRecorded && !preparationFailureRecorded {
                origin = bodyFailed ? .bodyRethrow : (bodyEntered ? .cleanup : .setup)
            }
        case .fixtureReturned: origin = .returned
        default: break
        }
        emit(.entered, failure)
    }
    func outerFailure(_ error: Error) {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        emit(.outerFailure, Failure(error), terminal: true)
    }
    func returned() {
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        origin = .returned
        emit(.returned, terminal: true)
    }
    private func emit(_ edge: Edge, _ failure: Failure = .none, terminal: Bool = false) {
        // Four slots cover first initiating failure, readiness replacement, preparation
        // replacement, and outer failure. Successful parts use progress slots.
        guard enabled, records < (terminal ? 128 : 124) else { return }
        let savedDiagnosticErrno = errno
        defer { errno = savedDiagnosticErrno }
        records += 1
        let record = Record(part: part, stage: stage, bootstrap: bootstrap,
            boundary: boundary, origin: origin, edge: edge, failure: failure)
        if capturedRecords != nil {
            capturedRecords!.append(record)
        } else {
            fputs(record.line, stderr)
            fflush(stderr)
        }
    }
}
#endif
