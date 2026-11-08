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
    private static func run(_ operation: LifecycleLaunchCommand.Operation,
        context: inout CommandCustodyContext?, registry: RetainedCleanupRegistry,
        diagnostic: Bool = false) throws -> Token {
        if diagnostic {
            let observed = try registry.start(context!.testingInstallationDiagnostic()).wait()
            try H.check(observed.phase == .finished && observed.reason == nil, "completion diagnostic failed")
        }
        var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(operation)
        let handle = try registry.start(command!)
        let result = handle.wait()
        try H.check(result.phase == .finished && result.reason == nil, "completion mutation failed")
        let token = try handle.stagedCompletion()
        // Neither a caller context nor its prepared-resource aliases may survive
        // actual registry removal and masquerade as a completed command scope.
        try H.refuses { _ = try token.validate(operation: operation) }
        context!.close(); context = nil
        try H.refuses { _ = try token.validate(operation: operation) }
        command = nil
        try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
        try until { (try? token.validate(operation: operation)) != nil }
        return token
    }
    // Reuse actual successful bootstrap custody for the separate incomplete
    // kickstart recovery fixture; no decoded record manufactures completion.
    static func bootstrapForRecovery(root: String, admission: InstallationStagedAdmission,
        journal: J, registry: RetainedCleanupRegistry) throws {
        try quiet(root)
        let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
        var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
        let retired = try run(.bootstrap, context: &context, registry: registry)
        _ = try journal.completeBootstrap(after: retired, deadline: .init(seconds: 3))
    }
    static func sequence() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            try quiet(root)
            _ = try journal.completeAdmission(deadline: .init(seconds: 30))
            let bootstrap = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: bootstrap, root: root)
            let first = try run(.bootstrap, context: &context, registry: registry, diagnostic: true)
            try H.refuses { _ = try first.validate(operation: .kickstart) }
            var after = try journal.completeBootstrap(after: first, deadline: .init(seconds: 3))
            try H.check(after.step?.action == .bootstrapCandidate && after.step?.status == .complete
                && after.readinessCommit == nil && after.phase == .active && (try record(location)) == after,
                "bootstrap completion did not persist exact non-ready state")
            let kickstart = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3))
            context = try .testingStaged(admission, intent: kickstart, root: root)
            let second = try run(.kickstart, context: &context, registry: registry)
            let anchored = try second.readinessDeadline().absoluteUptimeNanoseconds
            after = try journal.completeKickstart(after: second, deadline: .init(seconds: 3))
            try H.check(try second.readinessDeadline().absoluteUptimeNanoseconds == anchored,
                "kickstart completion reset original retirement readiness budget")
            try H.check(after.step?.action == .kickstartCandidate && after.step?.status == .complete
                && after.readinessCommit == nil && (try record(location)) == after,
                "missing-PID kickstart became authenticated readiness")
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            let intent = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3))
            context = try .testingStaged(stop, intent: intent, root: root)
            let third = try run(.bootout, context: &context, registry: registry)
            after = try journal.completeCandidateStop(after: third, deadline: .init(seconds: 3))
            try H.check(after.phase == .recovery && after.step?.action == .candidateStop
                && after.step?.status == .complete && after.readinessCommit == nil && (try record(location)) == after,
                "semantic absence did not persist stopped recovery")
            try H.refuses { _ = try journal.completeCandidateStop(after: third, deadline: .init(seconds: 3)) }
            try H.refuses { _ = try journal.completeBootstrap(after: first, deadline: .init(seconds: 3)) }
            try H.check((try record(location)) == after, "replay changed durable completion")
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
