#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationStagedCompletionFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    typealias Token = RetainedCleanupRegistry.StagedCommandCompletion
    private static func until(_ predicate: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 8)
        while try !predicate() {
            guard !deadline.hasExpired else { throw H.Failure(message: "staged completion retirement deadline") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    private static func quiet(_ root: String) throws {
        _ = try TestIsolation.validateRoot(root)
        let path = root + "/home/.staged-completion-quiet"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw H.Failure(message: "staged completion marker create") }
        defer { close(fd) }
        let bytes = Data("staged-completion-quiet/v1\n".utf8)
        try bytes.withUnsafeBytes { raw in
            try H.check(Darwin.write(fd, raw.baseAddress, raw.count) == raw.count && fsync(fd) == 0,
                        "staged completion marker write")
        }
    }
    private static func record(_ location: StateLocation) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
    }
    // Sequence-local testing evidence only. Closed labels and a 96-record cap
    // reserve two terminal records so an exhausted progress trace cannot hide
    // the first body failure or the outer fixture result. No error text or paths.
    private enum CompletionPart: String { case fixture, sequence, bootstrap, kickstart, bootout }
    enum CompletionPhase: String {
        case fixtureSetup, fixtureCleanup, fixtureCleanupOrBodyRethrow, fixtureReturned
        case quiet, completeAdmission, bootstrapIntent, bootstrapContext, bootstrapRun
        case wrongOperationRefusal, completeBootstrap, bootstrapRecord
        case kickstartIntent, kickstartContext, kickstartRun, readinessAnchor
        case completeKickstart, readinessUnchanged, kickstartRecord
        case stopOwner, stopIntent, stopContext, stopRun, completeStop, stopRecord
        case stopReplayRefusal, bootstrapReplayRefusal, replayRecord, bodyReturned
        case diagnosticCommand, diagnosticAssertion, prepare, start, wait
        case mutationAssertion, completionToken, contextAliasRefusal, contextClose
        case commandAliasRefusal, commandRelease, helperRetirement, tokenRetirement, commandReturned
    }
    private enum CompletionEdge: String { case entered, firstBodyFailure, outerFailure, returned }
    private final class CompletionDiagnostic {
        private let enabled = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_M6_DIAGNOSTICS"] == "1"
        private var records = 0
        private var part: CompletionPart = .fixture
        private var phase: CompletionPhase = .fixtureSetup
        private var failed = false
        var kickstart: InstallationKickstartFailureObservation?
        func mark(_ part: CompletionPart, _ phase: CompletionPhase) {
            self.part = part; self.phase = phase
            emit(part, phase, .entered, terminal: false)
        }
        func firstBodyFailure() {
            guard !failed else { return }
            failed = true
            emit(part, phase, .firstBodyFailure, terminal: true)
        }
        func outerFailure(bodyEntered: Bool, bodyReturned: Bool) {
            // The original journal wrapper may replace a body error during its
            // cleanup. This boundary reports that ambiguity without changing it.
            let phase: CompletionPhase = !bodyEntered ? .fixtureSetup
                : (bodyReturned ? .fixtureCleanup : .fixtureCleanupOrBodyRethrow)
            emit(.fixture, phase, .outerFailure, terminal: true)
        }
        func returned() { emit(.fixture, .fixtureReturned, .returned, terminal: true) }
        private func emit(_ part: CompletionPart, _ phase: CompletionPhase,
            _ edge: CompletionEdge, terminal: Bool) {
            guard enabled, records < (terminal ? 96 : 94) else { return }
            let savedDiagnosticErrno = errno
            defer { errno = savedDiagnosticErrno }
            records += 1
            var detail = ""
            if edge == .firstBodyFailure, let failure = kickstart?.first {
                detail = " inner=\(failure.stage.rawValue) original=\(failure.error.rawValue)"
                if let session = failure.session {
                    detail += " sessionCancelled=\(session.cancelled) sessionAnchored=\(session.anchorPresent) sessionOutcome=\(session.outcomePresent) serveOriginal=\(session.firstServeFailure?.rawValue ?? "none") serveSite=\(session.firstServeFailureSite?.rawValue ?? "none")"
                    if let invocation = session.serveInvocation {
                        detail += " serveInvocationStage=\(invocation.stage) serveInvocationPhase=\(invocation.phase.rawValue) serveInvocationNode=\(invocation.node.rawValue) serveInvocationAncestor=\(invocation.ancestor) serveInvocationPredicate=\(invocation.predicate.rawValue) serveInvocationSystem=\(invocation.system.rawValue) serveInvocationError=\(invocation.error.rawValue)"
                    }
                    if let anchor = session.anchorAttempt {
                        detail += " anchorCancelled=\(anchor.cancelled) anchorPresent=\(anchor.anchorPresent) anchorOutcome=\(anchor.outcomePresent) retirementExpired=\(anchor.retirementExpired) preanchorExpired=\(anchor.preanchorExpired)"
                    }
                }
                if let endpoint = failure.endpoint {
                    detail += " endpointFirstStage=\(endpoint.stage.rawValue) endpointMetadataCount=\(endpoint.metadataCount)"
                }
            }
            fputs("M6 STAGED COMPLETION DIAGNOSTIC part=\(part.rawValue) phase=\(phase.rawValue) edge=\(edge.rawValue)\(detail)\n", stderr)
            fflush(stderr)
        }
    }
    private static func run(_ operation: LifecycleLaunchCommand.Operation,
        context: inout CommandCustodyContext?, registry: RetainedCleanupRegistry,
        diagnostic: Bool = false, trace: ((CompletionPhase) -> Void)? = nil) throws -> Token {
        if diagnostic {
            trace?(.diagnosticCommand)
            let observed = try registry.start(context!.testingInstallationDiagnostic()).wait()
            trace?(.diagnosticAssertion)
            try H.check(observed.phase == .finished && observed.reason == nil, "completion diagnostic failed")
        }
        trace?(.prepare)
        var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(operation)
        trace?(.start)
        let handle = try registry.start(command!)
        trace?(.wait)
        let result = handle.wait()
        trace?(.mutationAssertion)
        try H.check(result.phase == .finished && result.reason == nil, "completion mutation failed")
        trace?(.completionToken)
        let token = try handle.stagedCompletion()
        // Neither a caller context nor its prepared-resource aliases may survive
        // actual registry removal and masquerade as a completed command scope.
        trace?(.contextAliasRefusal)
        try H.refuses { _ = try token.validate(operation: operation) }
        trace?(.contextClose)
        context!.close(); context = nil
        trace?(.commandAliasRefusal)
        try H.refuses { _ = try token.validate(operation: operation) }
        trace?(.commandRelease)
        command = nil
        trace?(.helperRetirement)
        try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
        trace?(.tokenRetirement)
        try until { (try? token.validate(operation: operation)) != nil }
        trace?(.commandReturned)
        return token
    }
    // Reuse actual successful bootstrap custody for the separate incomplete
    // kickstart recovery fixture; no decoded record manufactures completion.
    static func bootstrapForRecovery(root: String, admission: InstallationStagedAdmission,
        journal: J, registry: RetainedCleanupRegistry, trace: ((CompletionPhase) -> Void)? = nil) throws {
        trace?(.quiet)
        try quiet(root)
        trace?(.bootstrapIntent)
        let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
        trace?(.bootstrapContext)
        var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
        let retired = try run(.bootstrap, context: &context, registry: registry, trace: trace)
        trace?(.completeBootstrap)
        _ = try journal.completeBootstrap(after: retired, deadline: .init(seconds: 3))
    }
    static func sequence() throws {
        let diagnostic = CompletionDiagnostic()
        var bodyEntered = false
        var bodyReturned = false
        diagnostic.mark(.fixture, .fixtureSetup)
        do {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                bodyEntered = true
                do {
                    diagnostic.mark(.sequence, .quiet)
                    try quiet(root)
                    diagnostic.mark(.sequence, .completeAdmission)
                    _ = try journal.completeAdmission(deadline: .init(seconds: 30))
                    diagnostic.kickstart = InstallationKickstartFailureObservation(
                        session: journal.testingSession, endpoint: journal.testingEndpoint)
                    diagnostic.mark(.sequence, .bootstrapIntent)
                    let bootstrap = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                    diagnostic.mark(.sequence, .bootstrapContext)
                    var context: CommandCustodyContext? = try .testingStaged(admission, intent: bootstrap, root: root)
                    diagnostic.mark(.sequence, .bootstrapRun)
                    let first = try run(.bootstrap, context: &context, registry: registry, diagnostic: true) { diagnostic.mark(.bootstrap, $0) }
                    diagnostic.mark(.sequence, .wrongOperationRefusal)
                    try H.refuses { _ = try first.validate(operation: .kickstart) }
                    diagnostic.mark(.sequence, .completeBootstrap)
                    var after = try journal.completeBootstrap(after: first, deadline: .init(seconds: 3))
                    diagnostic.mark(.sequence, .bootstrapRecord)
                    try H.check(after.step?.action == .bootstrapCandidate && after.step?.status == .complete
                        && after.readinessCommit == nil && after.phase == .active && (try record(location)) == after,
                        "bootstrap completion did not persist exact non-ready state")
                    diagnostic.mark(.sequence, .kickstartIntent)
                    let kickstart = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3))
                    diagnostic.mark(.sequence, .kickstartContext)
                    context = try .testingStaged(admission, intent: kickstart, root: root)
                    diagnostic.mark(.sequence, .kickstartRun)
                    let second = try run(.kickstart, context: &context, registry: registry) { diagnostic.mark(.kickstart, $0) }
                    diagnostic.mark(.sequence, .readinessAnchor)
                    let anchored = try second.readinessDeadline().absoluteUptimeNanoseconds
                    diagnostic.mark(.sequence, .completeKickstart)
                    after = try journal.completeKickstart(after: second, deadline: .init(seconds: 3),
                        observation: diagnostic.kickstart)
                    diagnostic.mark(.sequence, .readinessUnchanged)
                    try H.check(try second.readinessDeadline().absoluteUptimeNanoseconds == anchored,
                        "kickstart completion reset original retirement readiness budget")
                    diagnostic.mark(.sequence, .kickstartRecord)
                    try H.check(after.step?.action == .kickstartCandidate && after.step?.status == .complete
                        && after.readinessCommit == nil && (try record(location)) == after,
                        "missing-PID kickstart became authenticated readiness")
                    diagnostic.mark(.sequence, .stopOwner)
                    let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                    diagnostic.mark(.sequence, .stopIntent)
                    let intent = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3))
                    diagnostic.mark(.sequence, .stopContext)
                    context = try .testingStaged(stop, intent: intent, root: root)
                    diagnostic.mark(.sequence, .stopRun)
                    let third = try run(.bootout, context: &context, registry: registry) { diagnostic.mark(.bootout, $0) }
                    diagnostic.mark(.sequence, .completeStop)
                    after = try journal.completeCandidateStop(after: third, deadline: .init(seconds: 3))
                    diagnostic.mark(.sequence, .stopRecord)
                    try H.check(after.phase == .recovery && after.step?.action == .candidateStop
                        && after.step?.status == .complete && after.readinessCommit == nil && (try record(location)) == after,
                        "semantic absence did not persist stopped recovery")
                    diagnostic.mark(.sequence, .stopReplayRefusal)
                    try H.refuses { _ = try journal.completeCandidateStop(after: third, deadline: .init(seconds: 3)) }
                    diagnostic.mark(.sequence, .bootstrapReplayRefusal)
                    try H.refuses { _ = try journal.completeBootstrap(after: first, deadline: .init(seconds: 3)) }
                    diagnostic.mark(.sequence, .replayRecord)
                    try H.check((try record(location)) == after, "replay changed durable completion")
                    diagnostic.mark(.sequence, .bodyReturned)
                    bodyReturned = true
                } catch {
                    diagnostic.firstBodyFailure()
                    throw error
                }
            }
            diagnostic.returned()
        } catch {
            diagnostic.outerFailure(bodyEntered: bodyEntered, bodyReturned: bodyReturned)
            throw error
        }
    }
    static func readinessRetirementScheduling() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            try quiet(root)
            _ = try journal.completeAdmission(deadline: .init(seconds: 30))
            let bootstrap = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: bootstrap, root: root)
            let first = try run(.bootstrap, context: &context, registry: registry)
            _ = try journal.completeBootstrap(after: first, deadline: .init(seconds: 3))
            let kickstart = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3))
            let hostAdmission = try LifecycleAdmissionAuthority.acquire(at: location)
            defer { hostAdmission.release() }
            // Early host arrival sees only safe pending readiness observation.
            let pending = try CustodyCatalogStore.precommitWaitObservation(admission: hostAdmission)
            try H.check(pending == kickstart.binding.control, "early host pending edge lost")
            try H.refuses { _ = try CustodyCatalogStore.precommitObservation(admission: hostAdmission) }
            let probe = RetainedCleanupRegistry.ReadinessSchedulingProbe()
            defer { probe.barrier.release() }
            registry.testingPauseReadinessScheduling(probe)
            let deadline = MonotonicDeadline(seconds: 8)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                var commandContext: CommandCustodyContext? = try .testingStaged(admission, intent: kickstart, root: root)
                let second = try run(.kickstart, context: &commandContext, registry: registry)
                guard let captured = probe.absoluteDeadline else { throw H.Failure(message: "missing retirement boundary") }
                try H.check(try second.readinessDeadline().absoluteUptimeNanoseconds == captured,
                    "delivery recreated five-second readiness clock")
                _ = try journal.completeKickstart(after: second, deadline: deadline)
                try H.check(try second.readinessDeadline().absoluteUptimeNanoseconds == captured,
                    "journal publication reset readiness clock")
            }
            try H.check(probe.barrier.waitUntilEntered(), "retirement scheduling cut did not enter")
            guard let captured = probe.absoluteDeadline else { throw H.Failure(message: "boundary timestamp not captured") }
            try H.check(captured > DispatchTime.now().uptimeNanoseconds, "boundary already expired")
            // Delay BEFORE the delivery closure is even queued. Equality to this
            // captured absolute value proves later scheduling cannot reset it.
            Thread.sleep(forTimeInterval: 0.05)
            try H.check(try CustodyCatalogStore.precommitWaitObservation(admission: hostAdmission) == pending,
                "post-retirement prepublication arrival did not remain waiting")
            probe.barrier.release(); try work.value(deadline: deadline)
            try H.check(try CustodyCatalogStore.precommitObservation(admission: hostAdmission).step?.status == .complete,
                "host did not observe exact completion")
        }
    }
    static func diagnosticAndFailure() throws {
        for failed in [false, true] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                try quiet(root)
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                var command: PreparedCustodyCommand? = try failed ? context!.testingStagedLifecycle(.bootstrap)
                    : context!.testingInstallationDiagnostic()
                if failed { registry.testingFault(.beforeSpawn) }
                let handle = try registry.start(command!)
                _ = handle.wait()
                command = nil; context!.close(); context = nil
                try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
                if failed, let token = try? handle.stagedCompletion() {
                    try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
                } else { try H.refuses { _ = try handle.stagedCompletion() } }
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                // Incomplete action reconciliation is deliberately still absent.
                try H.refuses { _ = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3)) }
                try H.check((try record(location)) == intent.binding.control,
                            "failed or diagnostic command synthesized action success")
            }
        }
    }
    static func pendingEOF() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            try quiet(root)
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
            registry.testingDeferNextRead(.outputUntilReleased)
            var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap)
            let handle = try registry.start(command!)
            try until {
                guard let observation = registry.testingReadObservation(handle) else { return false }
                return observation.terminalReceived && !observation.outputEOF
            }
            try H.refuses { _ = try handle.stagedCompletion() }
            try H.check((try record(location)) == intent.binding.control && registry.hasRetainedWork,
                        "pending EOF completed action")
            registry.testingReleaseDeferredRead(handle)
            _ = handle.wait()
            command = nil; context!.close(); context = nil
            try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
            let token = try handle.stagedCompletion()
            _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3))
        }
    }
    static func retainedAlias() throws {
        try InstallationStagedJournalFixtures.fixture { root, _, _, _, admission, journal, registry in
            try quiet(root)
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var alias: CustodyAuthorityLeaseSet? = try admission.retainStartLeases()
            var descendant: CustodyAuthorityLeaseSet? = try alias!.duplicate()
            alias = nil
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
            let token = try run(.bootstrap, context: &context, registry: registry)
            try withExtendedLifetime(descendant) {
                try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
            }
            descendant = nil
            _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3))
        }
    }
    static func wrongBinding() throws {
        try InstallationStagedJournalFixtures.fixture { root, _, _, _, admission, journal, registry in
            try quiet(root)
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
            let token = try run(.bootstrap, context: &context, registry: registry)
            try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, other, _ in
                _ = try other.completeAdmission(deadline: .init(seconds: 3))
                let otherIntent = try other.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                try H.refuses { _ = try other.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
                try H.check((try record(location)) == otherIntent.binding.control, "foreign token changed intent")
            }
            _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3))
        }
    }
    static func substitution() throws {
        try staleProof()
        for target in ["catalog", "archive", "caller", "control", "candidate"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                try quiet(root)
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let receipts = location.path + "/custody/receipts/"
                let beforeNames = Set(try FileManager.default.contentsOfDirectory(atPath: receipts))
                let token = try run(.bootstrap, context: &context, registry: registry)
                let names = try FileManager.default.contentsOfDirectory(atPath: receipts).filter { !beforeNames.contains($0) }
                let path: String
                switch target {
                case "catalog": path = location.path + "/custody/catalog.json"
                case "control": path = location.path + "/custody/installation.json"
                case "candidate": path = root + "/home/Library/LaunchAgents/" + InstallationPaths.label + ".plist"
                default:
                    let caller = names.first { $0.hasSuffix(".caller.json") }!
                    path = receipts + (target == "caller" ? caller : String(caller.dropLast(12)) + ".json")
                }
                let held = root + "/held-completion-evidence"
                try FileManager.default.moveItem(atPath: path, toPath: held)
                try FileManager.default.copyItem(atPath: held, toPath: path)
                try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
                // Restore this fixture's exact named inode; the refused session
                // stays failed and cannot consume its stale proof afterward.
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: held, toPath: path)
                try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
                try H.check((try record(location)) == intent.binding.control, "substitution completed command")
            }
        }
    }
    private static func staleProof() throws {
        for pending in [false, true] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                try quiet(root)
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap)
                let handle = try registry.start(command!)
                _ = handle.wait()
                let token = try handle.stagedCompletion()
                command = nil
                if pending {
                    let replay = try context!.testingStagedLifecycle(.bootstrap)
                    try H.refuses { _ = try context!.testingScope.prepare(replay.resources.request) }
                    try H.check(context!.testingScope.observation == .pending, "replay did not fence scope")
                } else {
                    let diagnostic = try registry.start(context!.testingInstallationDiagnostic()).wait()
                    try H.check(diagnostic.phase == .finished, "later diagnostic did not retire")
                }
                context!.close(); context = nil
                try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
                try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
                try H.check((try record(location)) == intent.binding.control,
                            "pending scope or later command reused stale completion")
            }
        }
    }
    static func durableCuts() throws {
        for cut in [J.Cut.afterReceipt, .beforeControl] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                try quiet(root)
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let token = try run(.bootstrap, context: &context, registry: registry)
                journal.testingCut(cut)
                try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
                try H.check(journal.testingHasPending && (try record(location)) == intent.binding.control,
                            "completion cut lost old control or pending receipt")
                try H.refuses { _ = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3)) }
                try H.refuses { _ = try journal.completeBootstrap(after: token, deadline: .init(seconds: 3)) }
            }
        }
    }
}
#endif
