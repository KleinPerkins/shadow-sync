#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationStagedReconciliationFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    typealias R = CustodyCatalogStore.InstallationStagedRecovery
    typealias T = RetainedCleanupRegistry.StagedRecoveryRetirement
    private static func refusesInvalidResource(_ body: () throws -> Void) throws {
        do { try body() }
        catch CustodyResourceError.invalidResource { return }
        throw H.Failure(message: "unexpected recovery resource acceptance")
    }
    private static func until(_ predicate: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 8)
        while try !predicate() {
            guard !deadline.hasExpired else { throw H.Failure(message: "staged recovery retirement deadline") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    // Stable raw diagnostic string survives optimization; function names alone
    // are not a reliable production-exclusion marker.
    private static func marker() { fputs("M6 STAGED RECONCILIATION FIXTURE\n", stderr) }
    private static func read(_ location: StateLocation) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
    }
    private static func observe(_ recovery: R, root: String, registry: RetainedCleanupRegistry,
                                mode: String = "installation-absent") throws -> T {
        var context: CommandCustodyContext? = try .testingRecovery(recovery, root: root)
        for operation in LifecycleLaunchCommand.Operation.allCases {
            try H.refuses { _ = try context!.testingStagedLifecycle(operation) }
        }
        var command: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic(mode)
        let handle = try registry.start(command!)
        let result = handle.wait()
        try H.check(result.phase == .finished && result.reason == nil, "recovery diagnostic did not finish")
        let token = try handle.stagedRecoveryRetirement()
        try H.refuses { _ = try token.validate() }
        command = nil; context!.close(); context = nil
        try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
        try until { (try? token.validate()) != nil }
        return token
    }
    static func unclaimedAndAbsentStop() throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let original = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
            let intent = try read(location)
            try H.check(intent.phase == .recovery && intent.step == original.binding.control.step
                && intent.latestReceiptDigest == original.binding.control.latestReceiptDigest,
                "unclaimed recovery altered unresolved intent")
            try H.refuses { _ = try admission.retainStartLeases() }
            let observed = try observe(recovery, root: root, registry: registry)
            let resolved = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3))
            try H.check(resolved.phase == .recovery && resolved.step?.status == .complete
                && resolved.step?.preimageDigest == resolved.step?.postimageDigest
                && resolved.readinessCommit == nil, "unclaimed recovery became success or readiness")
            // A fresh, separately bound observation is needed for no-op stop.
            let stopping = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(stop, intent: stopping, root: root)
            var command: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("installation-absent")
            let handle = try registry.start(command!)
            let result = handle.wait()
            try H.check(result.journal?.outcome == .commandFailed && result.journal?.waitStatus == 113 << 8,
                        "absence lost actual diagnostic failure status")
            let absence = try handle.stagedRecoveryRetirement()
            command = nil; context!.close(); context = nil
            try until { (try? absence.validate()) != nil }
            let stopped = try journal.completeAbsentCandidateStop(after: absence, deadline: .init(seconds: 3))
            try H.check(stopped.phase == .recovery && stopped.step?.action == .candidateStop
                && stopped.step?.status == .complete && stopped.readinessCommit == nil && (try read(location)) == stopped,
                "absent stop escaped recovery")
            try H.refuses { _ = try handle.stagedCompletion() }
            try H.refuses { _ = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3)) }
        }
    }
    static func retiredStarts() throws {
        marker()
        try unpublishedKickstartRecovery()
        // Actual registry proof distinguishes no successful spawn from an owned,
        // never-resumed reaped helper. No decoded outcome grants that authority.
        for cut in [RetainedCleanupRegistry.TestCut.beforeSpawn, .afterAnchor, .afterOwner] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap)
                registry.testingFault(cut)
                let handle = try registry.start(command!)
                let result = handle.wait()
                try H.check(result.phase == .finished && result.journal?.outcome == .admissionRefused,
                            "pre-spawn fixture did not retain actual refused outcome")
                let retired = try handle.stagedRecoveryRetirement()
                command = nil; context!.close(); context = nil
                try until { (try? retired.validate()) != nil }
                let path = location.path + "/custody/receipts/" + result.journal!.binding.requestID + ".json"
                let archived = try Data(contentsOf: URL(fileURLWithPath: path))
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                let recovery = try journal.beginStartRecovery(admission: stop, after: retired, deadline: .init(seconds: 3))
                let observed = try observe(recovery, root: root, registry: registry)
                let resolved = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3))
                try H.check(resolved.phase == .recovery && resolved.step?.status == .complete
                    && (try Data(contentsOf: URL(fileURLWithPath: path))) == archived,
                    "recovery rewrote actual admission-refused archive")
            }
        }
    }
    private static func unpublishedKickstartRecovery() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 30))
            try InstallationStagedCompletionFixtures.bootstrapForRecovery(root: root, admission: admission,
                journal: journal, registry: registry)
            let intent = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
            var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.kickstart)
            let handle = try registry.start(command!), result = handle.wait()
            guard let terminal = result.journal else { throw H.Failure(message: "kickstart original terminal missing") }
            try H.check(result.phase == .finished && result.reason == nil && terminal.outcome == .completed,
                "kickstart recovery did not finish actual command")
            let retired = try handle.stagedRecoveryRetirement()
            command = nil; context!.close(); context = nil
            try until { (try? retired.validate()) != nil }
            _ = try retired.validate()
            try H.check(terminal.waitStatus == 0 && terminal.target != nil,
                "kickstart recovery lacks actual successful terminal")
            // Bootstrap completion deliberately enabled quiet fixture telemetry.
            // The real registry result and opaque retirement proof establish this
            // command and retain its original outcome. Loaded kickstart state
            // alone does not prove the mutation resumed: recovery may resolve
            // that unchanged state even when no mutation ran. The separate
            // resumedOutcomes fixture checks the unsuppressed resume witness.
            // beginStartRecovery below consumes the opaque retirement proof and
            // validates its exact original intent; fixtures do not inspect or
            // widen the production evidence's private representation.
            let path = location.path + "/custody/receipts/" + terminal.binding.requestID + ".json"
            let archive = try Data(contentsOf: URL(fileURLWithPath: path))
            // Deliberately omit successful installation completion. Recovery
            // keeps the actual command outcome, resolving only its intent.
            try H.check((try read(location)) == intent.binding.control, "kickstart published without caller completion")
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            let recovery = try journal.beginStartRecovery(admission: stop, after: retired, deadline: .init(seconds: 3))
            let diagnostic = try observe(recovery, root: root, registry: registry, mode: "installation-loaded")
            let resolved = try journal.reconcileStart(recovery, after: diagnostic, deadline: .init(seconds: 3))
            try H.check(resolved.phase == .recovery && resolved.step?.action == .kickstartCandidate
                && resolved.step?.status == .complete && resolved.readinessCommit == nil
                && (try Data(contentsOf: URL(fileURLWithPath: path))) == archive,
                "kickstart recovery altered outcome or granted readiness")
            try H.refuses { _ = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3)) }
        }
    }
    static func resumedOutcomes() throws {
        marker()
        for mode in ["completed", "lifecycle-mutation-failure", "lifecycle-mutation-cancel", "lifecycle-postflight-timeout"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                if mode != "completed" {
                    let path = root + "/home/.staged-reconciliation-outcome"
                    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw H.Failure(message: "recovery outcome marker create") }
                    let bytes = Data(mode.utf8)
                    let wrote = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    let synced = fsync(fd); close(fd)
                    try H.check(wrote == bytes.count && synced == 0, "recovery outcome marker write")
                }
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let budget = try CustodyBudget.make(kind: .launchctlMutation,
                    workSeconds: mode == "lifecycle-postflight-timeout" ? 2 : 10)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap, budget: budget)
                let handle = try registry.start(command!)
                if mode == "lifecycle-mutation-cancel" {
                    try until { String(decoding: handle.snapshot().stderr, as: UTF8.self)
                        .contains("shadow-sync-fixture-serial:1:ready:") }
                    handle.cancel()
                }
                try until { handle.snapshot().phase == .finished }
                let result = handle.snapshot()
                guard let terminal = result.journal else { throw H.Failure(message: "recovery original terminal missing") }
                let expected: CustodyReason = mode == "completed" ? .none : mode == "lifecycle-mutation-cancel" ? .cancelled
                    : mode == "lifecycle-postflight-timeout" ? .timeout : .invalidResource
                try H.check(terminal.reason == expected && (terminal.outcome == .completed) == (mode == "completed"),
                            "recovery fixture did not reach actual requested outcome")
                try H.check(String(decoding: result.stderr, as: UTF8.self).contains("shadow-sync-fixture-serial:1:resumed:"),
                            "recovery fixture did not resume actual mutation child")
                let token = try handle.stagedRecoveryRetirement()
                command = nil; context!.close(); context = nil
                try until { (try? token.validate()) != nil }
                let path = location.path + "/custody/receipts/" + terminal.binding.requestID + ".json"
                let archived = try Data(contentsOf: URL(fileURLWithPath: path))
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                let recovery = try journal.beginStartRecovery(admission: stop, after: token, deadline: .init(seconds: 3))
                let observed = try observe(recovery, root: root, registry: registry, mode: "installation-loaded")
                let resolved = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3))
                try H.check(resolved.phase == .recovery && resolved.step?.status == .complete
                    && resolved.readinessCommit == nil && (try Data(contentsOf: URL(fileURLWithPath: path))) == archived,
                    "reconciliation rewrote original outcome or granted readiness")
                // Successful tool execution without installation publication is
                // resolved as recovery too; no normal completion is synthesized.
                try H.refuses { _ = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3)) }
            }
        }
    }
    static func semanticStates() throws {
        marker()
        for mode in ["installation-loaded", "installation-foreign", "complete"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
                let before = try read(location)
                let observed = try observe(recovery, root: root, registry: registry, mode: mode)
                // No mutation was ever admitted: even exact candidate loaded
                // output is unexplained and must not be called an after-state.
                if mode == "installation-foreign" {
                    try refusesInvalidResource { _ = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3)) }
                } else {
                    try H.refuses { _ = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3)) }
                }
                try H.check((try read(location)) == before, "unknown semantic state resolved intent")
            }
        }
    }
    static func actionClassifier() throws {
        marker()
        try H.fixture { root, _ in
            let account = try EffectiveAccount.isolated(homeDirectory: root + "/home")
            let command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
            _ = try command.recoveryLayout(action: .bootstrapCandidate, state: .absent)
            _ = try command.recoveryLayout(action: .bootstrapCandidate, state: .loaded(program: command.executable, processID: nil))
            _ = try command.recoveryLayout(action: .kickstartCandidate, state: .loaded(program: command.executable, processID: nil))
            try H.refuses { _ = try command.recoveryLayout(action: .kickstartCandidate, state: .absent) }
            try H.refuses { _ = try command.recoveryLayout(action: .bootstrapCandidate, state: .loaded(program: "/fixture/foreign", processID: nil)) }
            try refusesInvalidResource { _ = try command.state(waitStatus: 1 << 8, stdout: Data(), stderr: command.fixtureAbsentError) }
            try refusesInvalidResource { _ = try command.state(waitStatus: 113 << 8, stdout: Data("extra".utf8), stderr: command.fixtureAbsentError) }
        }
    }
    static func aliasesAndEOF() throws {
        marker()
        try forcedEOFUnwind()
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
            let before = try read(location)
            var context: CommandCustodyContext? = try .testingRecovery(recovery, root: root)
            registry.testingDeferNextRead(.outputUntilReleased)
            var command: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("installation-absent")
            let handle = try registry.start(command!)
            // This fixture owns the injected EOF hold. Release it on every
            // unwind before the enclosing fixture cancels and joins custody.
            defer { registry.testingReleaseDeferredRead(handle) }
            try until {
                guard let state = registry.testingReadObservation(handle) else { return false }
                return state.terminalReceived && !state.outputEOF
            }
            try H.refuses { _ = try handle.stagedRecoveryRetirement() }
            try H.check(registry.hasRetainedWork && (try read(location)) == before, "pending EOF cleared recovery")
            registry.testingReleaseDeferredRead(handle)
            _ = handle.wait()
            let token = try handle.stagedRecoveryRetirement()
            try H.refuses { _ = try journal.reconcileStart(recovery, after: token, deadline: .init(seconds: 3)) }
            command = nil; context!.close(); context = nil
            try until { (try? token.validate()) != nil }
            var alias: CustodyAuthorityLeaseSet? = try stop.retainStopLeases()
            try withExtendedLifetime(alias) {
                try H.refuses { _ = try journal.reconcileStart(recovery, after: token, deadline: .init(seconds: 3)) }
            }
            alias = nil
            _ = try journal.reconcileStart(recovery, after: token, deadline: .init(seconds: 3))
        }
    }
    private enum ForcedUnwind: Error { case afterHeldEOF }
    private static func forcedEOFUnwind() throws {
        var ownedRoot: String?
        var observedRegistry: RetainedCleanupRegistry?
        do {
            try InstallationStagedJournalFixtures.fixture { root, _, _, _, admission, journal, registry in
                ownedRoot = root; observedRegistry = registry
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
                let context = try CommandCustodyContext.testingRecovery(recovery, root: root)
                defer { context.close() }
                registry.testingDeferNextRead(.outputUntilReleased)
                let command = try context.testingInstallationDiagnostic("installation-absent")
                let handle = try registry.start(command)
                defer { registry.testingReleaseDeferredRead(handle) }
                try until {
                    guard let state = registry.testingReadObservation(handle) else { return false }
                    return state.terminalReceived && !state.outputEOF
                }
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                throw ForcedUnwind.afterHeldEOF
            }
            throw H.Failure(message: "forced EOF unwind did not throw")
        } catch ForcedUnwind.afterHeldEOF {
            // This exact error reached us only after the real enclosing fixture
            // cancelled/joined registry and session custody on its throw path.
            guard let root = ownedRoot, let registry = observedRegistry else {
                throw H.Failure(message: "forced EOF unwind lost original observations")
            }
            try H.check(!registry.hasRetainedWork && registry.testingCount == 0
                && registry.testingOriginalHelpersReaped, "forced EOF unwind left owned work")
            var node = stat()
            try H.check(lstat(root, &node) == -1 && errno == ENOENT,
                "forced EOF unwind retained resolved fixture root")
        }
    }
    static func substitutions() throws {
        marker()
        for target in ["catalog", "control", "archive", "caller", "candidate"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
                let receipts = location.path + "/custody/receipts/"
                let before = Set(try FileManager.default.contentsOfDirectory(atPath: receipts))
                let observed = try observe(recovery, root: root, registry: registry)
                let added = try FileManager.default.contentsOfDirectory(atPath: receipts).filter { !before.contains($0) }
                let path: String
                switch target {
                case "catalog": path = location.path + "/custody/catalog.json"
                case "control": path = location.path + "/custody/installation.json"
                case "candidate": path = root + "/home/Library/LaunchAgents/" + InstallationPaths.label + ".plist"
                default:
                    let caller = added.first { $0.hasSuffix(".caller.json") }!
                    path = receipts + (target == "caller" ? caller : String(caller.dropLast(12)) + ".json")
                }
                let held = root + "/held-recovery-evidence"
                try FileManager.default.moveItem(atPath: path, toPath: held)
                try FileManager.default.copyItem(atPath: held, toPath: path)
                try H.refuses { _ = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3)) }
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: held, toPath: path)
                try H.check((try read(location)).step?.status == .intent, "substitution resolved recovery")
            }
        }
    }
    static func receiptCuts() throws {
        marker()
        for cut in [J.Cut.afterReceipt, .beforeControl] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
                let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
                let observed = try observe(recovery, root: root, registry: registry)
                let before = try read(location)
                journal.testingCut(cut)
                try H.refuses { _ = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3)) }
                try H.check(journal.testingHasPending && (try read(location)) == before, "recovery cut lost pinned intent")
                try H.refuses { _ = try journal.reconcileStart(recovery, after: observed, deadline: .init(seconds: 3)) }
                try H.refuses { _ = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3)) }
            }
        }
    }
}
#endif
