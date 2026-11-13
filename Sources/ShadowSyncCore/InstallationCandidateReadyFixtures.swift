#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Deterministic value/storage and real custody refusal cases. None mints a
/// ReadyObservation or supplies a positive native authentication substitute.
enum InstallationCandidateReadyFixtures {
    typealias H = InstallationStorageFixtures
    private static func marker() { fputs("M6 CANDIDATE READY FIXTURE\n", stderr) }
    private static func until(_ body: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 8)
        while try !body() {
            guard !deadline.hasExpired else { throw H.Failure(message: "candidate-ready fixture retirement deadline") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    static func unready() throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let path = location.path + "/custody/installation.json"
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            try H.refuses { _ = try journal.candidateReadyIntent() }
            try H.refuses { _ = try journal.publishReadinessCommit() }
            try journal.closeReadiness(deadline: .init(seconds: 3))
            try H.refuses { _ = try journal.candidateReadyIntent() }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: path)) == before, "unready journal mutated durable control")
        }
    }
    static func diagnostic() throws {
        marker()
        try H.fixture { root, _ in
            let account = try EffectiveAccount.isolated(homeDirectory: root + "/home")
            let command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
            // This is an inert semantic observation, NOT an authenticated peer.
            let host = ProcessIdentity(processID: 401, processGroupID: 401, userID: account.uid,
                startSeconds: 1, startMicroseconds: 0, executablePath: command.executable, generation: RunIdentity.make())
            let base = String(decoding: command.fixtureLoadedOutput, as: UTF8.self)
            let exact = Data(base.dropLast(2).appending("\tpid = 401\n}\n").utf8)
            let state = try command.state(waitStatus: 0, stdout: exact, stderr: Data())
            try command.validateReadyHost(state, host: host)
            for bad in [LaunchAgentState.absent, .loaded(program: command.executable, processID: nil),
                        .loaded(program: command.executable, processID: 402), .loaded(program: "/fixture/other", processID: 401)] {
                try H.refuses { try command.validateReadyHost(bad, host: host) }
            }
            for bytes in [Data(String(decoding: exact, as: UTF8.self).replacingOccurrences(of: "pid = 401", with: "pid = 401\n\tpid = 401").utf8),
                          Data(String(decoding: exact, as: UTF8.self).replacingOccurrences(of: command.executable, with: "/fixture/other").utf8)] {
                do { _ = try command.state(waitStatus: 0, stdout: bytes, stderr: Data()) }
                catch CustodyResourceError.invalidResource { continue }
                throw H.Failure(message: "nonexact ready diagnostic accepted")
            }
        }
    }
    static func quietLifetime() throws {
        marker()
        for extra in [false, true] {
            var fds: [Int32] = [-1, -1]
            try H.check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "candidate-ready socket pair")
            let owned = OwnedFileDescriptor(fds[0]), peer = OwnedFileDescriptor(fds[1])
            defer { owned.closeNow(); peer.closeNow() }
            try InstallationPrecommitTransport.configure(owned.value)
            try InstallationPrecommitTransport.configure(peer.value)
            try InstallationPrecommitTransport.requireQuiet(owned)
            if extra {
                var byte: UInt8 = 1
                try H.check(Darwin.write(peer.value, &byte, 1) == 1, "candidate-ready extra byte")
            } else { peer.closeNow() }
            do { try InstallationPrecommitTransport.requireQuiet(owned) }
            catch CustodyProtocolError.invalidSequence { continue }
            throw H.Failure(message: "ready EOF or extra input survived")
        }
        let deadline = MonotonicDeadline(seconds: 0.5)
        let first = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10)
            .clipped(to: deadline, kind: .launchctlRead, permittedWorkSeconds: 10)
        let later = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10)
            .clipped(to: deadline, kind: .launchctlRead, permittedWorkSeconds: 10)
        try H.check(first.receipt == deadline.absoluteUptimeNanoseconds && later.receipt == first.receipt
            && later.work == first.work, "ready diagnostic reset absolute budget")
    }
    static func retiredWrongEdge() throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 20))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
            registry.testingDeferNextRead(.outputUntilReleased)
            var command: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("installation-loaded")
            let handle = try registry.start(command!)
            defer { registry.testingReleaseDeferredRead(handle) }
            try until {
                guard let state = registry.testingReadObservation(handle) else { return false }
                return state.terminalReceived && !state.outputEOF
            }
            try H.refuses { _ = try handle.stagedRecoveryRetirement() }
            registry.testingReleaseDeferredRead(handle)
            _ = handle.wait()
            let retired = try handle.stagedRecoveryRetirement()
            try H.refuses { _ = try retired.validate() }
            command = nil; context!.close(); context = nil
            try until { (try? retired.validate()) != nil }
            try H.check(registry.testingCount == 0 && registry.testingOriginalHelpersReaped, "ready diagnostic helper not retired")
            let path = location.path + "/custody/installation.json"
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            try H.refuses { _ = try journal.completeCandidateReady(after: retired) }
            try H.refuses { _ = try journal.publishReadinessCommit() }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: path)) == before, "wrong-edge retirement published readiness")
        }
    }
    /// Exercises the actual shared publication/close machinery with an actual
    /// live precommit session, without pretending it authenticated a candidate.
    /// The signed harness below repeats these same cuts at the ready edges.
    static func livePublicationClose() throws {
        marker()
        typealias J = CustodyCatalogStore.InstallationStagedJournal
        for point in [J.TestingPublicationPoint.afterReadyValidation, .insideControlGuard] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
                _ = try journal.completeAdmission(deadline: .init(seconds: 20))
                guard let session = journal.testingSession else { throw H.Failure(message: "missing live session") }
                let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 3)
                defer { barrier.release() }
                let probe = J.TestingPublicationProbe(action: .bootstrapCandidate, status: .intent,
                    point: point, barrier: barrier)
                try journal.testingObservePublication(probe)
                let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                    _ = try journal.bootstrapCandidateIntent(deadline: deadline)
                }
                try H.check(barrier.waitUntilEntered(), "actual publication did not reach close cut")
                try H.check(probe.observed != nil, "close cut missed actual publish")
                // On v1 this succeeds and destroys the live session even though
                // the actual publication remains able to change durable control.
                do {
                    try journal.closeReadiness(deadline: .init(seconds: 0.02))
                    throw H.Failure(message: "close completed while publication could still commit")
                } catch CustodyRecordError.busy {}
                try H.check(journal.testingSession === session,
                    "incomplete close discarded the actual session owner")
                barrier.release(); try work.value(deadline: deadline)
                try journal.closeReadiness(deadline: deadline)
                try H.check(journal.testingSession == nil, "close failed to join live session")
                let path = location.path + "/custody/installation.json"
                let frozen = try Data(contentsOf: URL(fileURLWithPath: path))
                try H.refuses { _ = try journal.candidateReadyIntent() }
                try H.refuses { _ = try journal.publishReadinessCommit() }
                try H.check(try Data(contentsOf: URL(fileURLWithPath: path)) == frozen,
                    "readiness publication changed control after successful close")
            }
        }
    }
    static func harnessRequiresActualReady() throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
            let probe = CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe(
                action: .candidateReady, status: .intent, failure: .afterReceipt)
            try journal.testingObservePublication(probe)
            try H.refuses { _ = try journal.candidateReadyIntent() }
            try H.check(probe.observed == nil, "fault harness manufactured ready authority")
            // An early missing-authority refusal must NEVER count as a passing
            // transition cut. The positive driver prerequisite is explicit.
            do {
                _ = try InstallationCandidateReadyTransitionHarness.requireReached(probe)
                throw H.Failure(message: "unreached signed transition counted as coverage")
            } catch InstallationCandidateReadyTransitionHarness.Prerequisite.authenticatedTransitionNotReached {}
            try InstallationOwnershipFixtures.excluded(location)
            _ = try TestIsolation.validateRoot(root)
        }
    }
    static func receiptCuts() throws {
        marker()
        // Isolated storage evidence cuts, not execution of the signed session's
        // journal transitions. Every relevant receipt remains independently required.
        for action in [InstallationAction.candidateReady, .readinessCommit] {
            for status in [InstallationStepStatus.intent, .complete] {
                try H.fixture { root, location in
                    try TestIsolation.initializeState(at: location)
                    var leases: CustodyAuthorityLeaseSet? = try .retainRecoveryLeases(at: location)
                    try CustodyCatalogStore.testingInitialize(leases: leases!, root: root)
                    leases = nil
                    let read = try CustodyAuthorityLeaseSet.retainReadLeases(at: location)
                    let store = try CustodyCatalogStore(leases: read)
                    try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read)
                    let directory = location.path + "/custody/receipts/"
                    let names = try FileManager.default.contentsOfDirectory(atPath: directory)
                    let name = try names.first { name in
                        let receipt = try InstallationStepReceipt.decode(Data(contentsOf: URL(fileURLWithPath: directory + name)), uid: location.uid)
                        return receipt.action == action && receipt.status == status
                    }
                    guard let name else { throw H.Failure(message: "ready receipt cut absent") }
                    let saved = root + "/saved-receipt"
                    try H.check(rename(directory + name, saved) == 0, "ready receipt cut move")
                    try H.refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
                    try H.check(rename(saved, directory + name) == 0, "ready receipt cut restore")
                    try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read)
                }
            }
        }
    }
}
/// Exact-edge harness for a future ISOLATED signed-session driver. This does
/// not create a session/ReadyObservation/retirement or bypass native verification.
/// A driver must first reach actual authenticated ready via the retained original
/// journal; completion additionally needs the actual fixed diagnostic retirement.
/// Ordinary unsigned fixtures cannot supply those prerequisites. Unreached hooks
/// throw Prerequisite rather than passing a negative test or reporting a skip.
enum InstallationCandidateReadyTransitionHarness {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    typealias Retirement = RetainedCleanupRegistry.StagedRecoveryRetirement
    enum Prerequisite: Error { case authenticatedTransitionNotReached, actualDiagnosticRetirementRequired }
    enum Transition: CaseIterable, Sendable {
        case candidateIntent, candidateComplete, commitIntent, commitComplete
        var action: InstallationAction {
            switch self { case .candidateIntent, .candidateComplete: return .candidateReady
            case .commitIntent, .commitComplete: return .readinessCommit }
        }
        var status: InstallationStepStatus {
            switch self { case .candidateIntent, .commitIntent: return .intent
            case .candidateComplete, .commitComplete: return .complete }
        }
        func invoke(_ journal: J, retired: Retirement?) throws {
            switch self {
            case .candidateIntent: _ = try journal.candidateReadyIntent()
            case .candidateComplete:
                guard let retired else { throw Prerequisite.actualDiagnosticRetirementRequired }
                _ = try journal.completeCandidateReady(after: retired)
            case .commitIntent, .commitComplete: _ = try journal.publishReadinessCommit()
            }
        }
    }
    static func requireReached(_ probe: J.TestingPublicationProbe)
        throws -> (before: InstallationControlRecord, after: InstallationControlRecord, receipt: InstallationStepReceipt) {
        guard let trace = probe.observed else { throw Prerequisite.authenticatedTransitionNotReached }
        return trace
    }
    private static func checkedLocation(root: String, location: StateLocation) throws {
        let paths = try InstallationPaths.isolated(root: TestIsolation.validateRoot(root))
        try H.check(paths.state.path == location.path && paths.state.uid == location.uid,
            "signed harness root does not own state")
    }
    private static func read(_ location: StateLocation) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
    }
    /// Four actual publication edges x nine persistence cuts. In particular,
    /// commitComplete targets the SECOND publish inside publishReadinessCommit;
    /// it cannot accidentally pass after cutting the preceding intent.
    static func persistenceCut(_ edge: Transition, failure: J.TestingPublicationFailure,
        journal: J, retired: Retirement? = nil, root: String, location: StateLocation) throws {
        try checkedLocation(root: root, location: location)
        let probe = J.TestingPublicationProbe(action: edge.action, status: edge.status, failure: failure)
        try journal.testingObservePublication(probe)
        var refused = false
        do { try edge.invoke(journal, retired: retired) }
        catch CustodyRecordError.injectedFailure { refused = true }
        catch CustodyRecordError.committedCleanupFailure { refused = true }
        // If another prerequisite fails, propagate it; never count it as this cut.
        let trace = try requireReached(probe)
        try H.check(refused && journal.testingHasPending, "actual transition did not retain failed pending publication")
        let after = try read(location)
        let swapped: Bool
        switch failure {
        case .controlAfterSwap, .controlAfterDirectorySync, .controlAfterPreimageUnlink: swapped = true
        default: swapped = false
        }
        try H.check(after == (swapped ? trace.after : trace.before), "failure cut published an unexpected control")
        let receiptPath = location.path + "/custody/receipts/" + (try trace.receipt.filename(uid: location.uid))
        if failure == .receiptBeforeSwap {
            var node = stat()
            try H.check(lstat(receiptPath, &node) == -1 && errno == ENOENT, "pre-swap receipt unexpectedly exists")
        } else {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
            try H.check(bytes == trace.receipt.encode(uid: location.uid), "retained receipt differs from actual proposed edge")
        }
        try H.check(trace.receipt.previousReceiptDigest == trace.before.latestReceiptDigest,
            "new receipt lost exact predecessor")
        try H.check(trace.after.latestReceiptDigest == trace.receipt.digest(uid: location.uid),
            "proposed control lost exact receipt")
        if edge == .commitComplete {
            try H.check(trace.after.phase == .committed && trace.after.readinessCommit != nil,
                "commit-complete cut never reached actual committed proposal")
            try H.check(trace.after.readinessCommit?.completedStepReceiptDigest != trace.after.latestReceiptDigest,
                "commit references itself")
        }
        // Failure is sticky and the original operation remains excluded. This
        // checks refusal, NOT the unimplemented original-owner reconciliation.
        let beforeRetry = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
        try H.refuses { _ = try journal.publishReadinessCommit() }
        try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")) == beforeRetry,
            "failed journal replayed publication")
        try InstallationOwnershipFixtures.excluded(location)
    }
    /// Run a real external disruption after the first authenticated check and
    /// before receipt persistence: replace control/plist/endpoint, close the real
    /// peer, send extra transcript bytes from that peer, or consume the original
    /// readiness deadline. The driver owns and joins its peer; this callback can
    /// only disrupt an existing real session and grants no positive authority.
    /// A no-op disruption fails this test because the real transition succeeds.
    static func interruption(_ edge: Transition, journal: J, retired: Retirement? = nil,
        root: String, location: StateLocation, disrupt: () throws -> Void) throws {
        try checkedLocation(root: root, location: location)
        let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 3)
        defer { barrier.release() }
        let probe = J.TestingPublicationProbe(action: edge.action, status: edge.status,
            point: .beforeReceipt, barrier: barrier)
        try journal.testingObservePublication(probe)
        let work = try RuntimeFixtureSession.installationRoot(root).startWork {
            try InstallationPrecommitFixtures.rejects { try edge.invoke(journal, retired: retired) }
        }
        try H.check(barrier.waitUntilEntered(), "authenticated interruption edge not reached")
        let trace = try requireReached(probe)
        try disrupt() // no journal/catalog/owner/registry lock is held here
        barrier.release(); try work.value(deadline: deadline)
        try H.check(try read(location) != trace.after, "disrupted transition published its successor")
        try InstallationOwnershipFixtures.excluded(location)
    }
    enum Replacement: CaseIterable { case control, launchPlist, endpoint }
    /// Concrete byte-identical inode replacement (or socket-to-file replacement)
    /// under a validated fixture root. Restoration touches only the two identities
    /// created/retained by this call and propagates every cleanup failure.
    static func replacement(_ edge: Transition, slot: Replacement, journal: J,
        retired: Retirement? = nil, root: String, location: StateLocation) throws {
        try checkedLocation(root: root, location: location)
        let paths = try InstallationPaths.isolated(root: root)
        let path: String
        switch slot {
        case .control: path = location.path + "/custody/installation.json"
        case .launchPlist: path = paths.launchAgent
        case .endpoint: path = location.path + "/installation.sock"
        }
        let saved = root + "/candidate-ready-retained-" + UUID().uuidString.lowercased()
        var original: FileIdentity?, replacement: FileIdentity?, moved = false
        var failure: Error?
        do {
            try interruption(edge, journal: journal, retired: retired, root: root, location: location) {
                var before = stat()
                try H.check(lstat(path, &before) == 0, "replacement original absent")
                original = FileIdentity(before)
                let bytes = slot == .endpoint ? Data("fixture socket replacement".utf8)
                    : try Data(contentsOf: URL(fileURLWithPath: path))
                var unused = stat()
                try H.check(lstat(saved, &unused) == -1 && errno == ENOENT, "replacement backup exists")
                try H.check(rename(path, saved) == 0, "replacement original move")
                moved = true
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                try H.check(fd >= 0, "replacement node create"); defer { close(fd) }
                var created = stat(); try H.check(fstat(fd, &created) == 0, "replacement identity")
                replacement = FileIdentity(created)
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        try H.check(n > 0, "replacement bytes"); offset += n
                    }
                }
                try H.check(fsync(fd) == 0, "replacement fsync")
            }
        } catch { failure = error }
        if moved {
            var held = stat()
            try H.check(lstat(saved, &held) == 0 && original?.matchesStableNode(FileIdentity(held)) == true,
                "retained replacement original changed")
            if let replacement {
                var current = stat()
                try H.check(lstat(path, &current) == 0 && replacement.matchesStableNode(FileIdentity(current)),
                    "replacement cleanup lost identity")
                try H.check(unlink(path) == 0, "replacement owned unlink")
            } else {
                var absent = stat()
                try H.check(lstat(path, &absent) == -1 && errno == ENOENT, "unknown replacement refused")
            }
            try H.check(rename(saved, path) == 0, "replacement original restore")
        }
        if let failure { throw failure }
    }
    /// Expire the actual post-kickstart deadline during a real journal turn.
    /// No test clock, deadline extension or new per-message budget is accepted.
    static func deadlineLoss(_ edge: Transition, journal: J, retired: Retirement? = nil,
        root: String, location: StateLocation) throws {
        guard let deadline = journal.testingSession?.testingAnchoredDeadline else {
            throw Prerequisite.authenticatedTransitionNotReached
        }
        // The bounded barrier itself must not be the reason for refusal. Leave
        // at most one second of the original five-second budget before entering.
        while !deadline.hasExpired && deadline.remainingMilliseconds > 1_000 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try interruption(edge, journal: journal, retired: retired, root: root, location: location) {
            while !deadline.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
        }
    }
    /// Reproduce the reported race on each real ready edge. A short close MUST
    /// time out while either publication barrier is held; it retains the actual
    /// session. The earlier reservation may publish, then close joins everything.
    static func closeRace(_ edge: Transition, point: J.TestingPublicationPoint,
        journal: J, retired: Retirement? = nil, root: String, location: StateLocation) throws {
        try checkedLocation(root: root, location: location)
        guard let session = journal.testingSession else { throw Prerequisite.authenticatedTransitionNotReached }
        let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 3)
        defer { barrier.release() }
        let probe = J.TestingPublicationProbe(action: edge.action, status: edge.status, point: point, barrier: barrier)
        try journal.testingObservePublication(probe)
        let work = try RuntimeFixtureSession.installationRoot(root).startWork {
            try edge.invoke(journal, retired: retired)
        }
        try H.check(barrier.waitUntilEntered(), "authenticated close edge not reached")
        _ = try requireReached(probe)
        do {
            try journal.closeReadiness(deadline: .init(seconds: 0.02))
            throw H.Failure(message: "ready publication outlived successful close")
        } catch CustodyRecordError.busy {}
        try H.check(journal.testingSession === session, "close timeout lost real session")
        barrier.release(); try work.value(deadline: deadline)
        try journal.closeReadiness(deadline: deadline)
        try H.check(journal.testingSession == nil, "ready session survived completed close")
        let frozen = try read(location)
        try H.refuses { _ = try journal.publishReadinessCommit() }
        try H.check(try read(location) == frozen, "closed journal published later control")
    }
}
#endif
