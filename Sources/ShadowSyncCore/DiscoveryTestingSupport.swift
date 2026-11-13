#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import Security
import ShadowSyncCatalog

/// Closed, testing-only failure observations: no path, input, child output or
/// arbitrary error text is admitted. These observations never alter a budget.
enum DiscoveryFixtureDiagnostic {
    /// A thread-scoped value observes only the actual throwing spawn attempt.
    /// It never owns a descriptor, changes an error, retries work or emits output.
    enum RepositoryBusyObservation {
        enum Transition: String, CaseIterable { case none, admit, executing }
        enum Site: String, CaseIterable { case none, catalogMutex, catalogFileLock }
        struct Snapshot: Equatable {
            var transition: Transition = .none
            var site: Site = .none
        }
        private final class Scope { var snapshot = Snapshot() }
        private static let key = "shadow-sync-testing-repository-catalog-busy"
        private static var current: Scope? { Thread.current.threadDictionary[key] as? Scope }
        static func transition(_ value: Transition) {
            let saved = errno; defer { errno = saved }
            current?.snapshot.transition = value
        }
        static func busy(_ value: Site) {
            let saved = errno; defer { errno = saved }
            current?.snapshot.site = value
        }
        static func observe<T>(enabled: Bool, failure: (Snapshot) -> Void,
                               _ body: () throws -> T) rethrows -> T {
            guard enabled else { return try body() }
            let saved = errno
            let previous = Thread.current.threadDictionary[key]
            let scope = Scope()
            Thread.current.threadDictionary[key] = scope
            errno = saved
            defer {
                let saved = errno; defer { errno = saved }
                if let previous { Thread.current.threadDictionary[key] = previous }
                else { Thread.current.threadDictionary.removeObject(forKey: key) }
            }
            do { return try body() }
            catch {
                let saved = errno; defer { errno = saved }
                failure(scope.snapshot); throw error
            }
        }
    }

    /// This budget applies only to optional fixture traces. Assertion/failure
    /// reporting and the guardian's stream limits are separate and unchanged.
    final class Sink: @unchecked Sendable {
        static let maximumRecords = 64
        static let maximumBytes = 16_384
        static let maximumLineBytes = 512
        static let suppression = "DISCOVERY FIXTURE DIAGNOSTIC suppressed=remaining reason=budget\n"
        private let lock = NSLock()
        private let enabled: Bool
        private let writer: @Sendable (String) -> Void
        private var records = 0
        private var bytes = 0
        private var closed = false

        init(enabled: Bool, writer: @escaping @Sendable (String) -> Void) {
            self.enabled = enabled
            self.writer = writer
        }

        func emit(_ line: @autoclosure () -> String) {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !closed else { return }
            guard records < Self.maximumRecords else { suppress(); return }
            let text = line(), size = text.utf8.count
            guard size <= Self.maximumLineBytes,
                  bytes + size + Self.suppression.utf8.count <= Self.maximumBytes else {
                suppress(); return
            }
            records += 1; bytes += size
            writer(text)
        }

        func permitsObservation() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return enabled && !closed && records < Self.maximumRecords
                && bytes + Self.maximumLineBytes + Self.suppression.utf8.count <= Self.maximumBytes
        }

        private func suppress() {
            closed = true
            writer(Self.suppression)
        }
    }

    /// Each process may sample only its first eight session revalidations.
    /// This is an observation limit, never an operation or deadline allowance.
    final class SampleBudget: @unchecked Sendable {
        static let maximumSamples = 8
        private let lock = NSLock()
        private let enabled: Bool
        private var samples = 0

        init(enabled: Bool) { self.enabled = enabled }

        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard enabled, samples < Self.maximumSamples else { return false }
            samples += 1
            return true
        }
    }

    // Pending observation v1: bit 63 distinguishes these records from the
    // existing caught-error records. Bits 0...7 hold the closed effective
    // reason, 8...39 the raw wait status when reaped, 40...43 owner tags,
    // and 44...52 the closed entry-state flags. Raw zero never means absent.
    static func pendingBits(reason: CustodyReason, owner: OwnedDirectChildObservation?,
                            state: UInt64) -> UInt64 {
        let code: UInt64
        switch reason {
        case .none: code = 0
        case .cancelled: code = 1
        case .timeout: code = 2
        case .protocolFault: code = 3
        case .invalidResource: code = 4
        case .identityFailure: code = 5
        case .outputLimit: code = 6
        case .ioFailure: code = 7
        case .startFailure: code = 8
        case .ownershipLost: code = 9
        case .persistenceFailure: code = 10
        case .bootChanged: code = 11
        }
        var bits = (UInt64(1) << 63) | code | ((state & 0x1ff) << 44)
        if let owner {
            bits |= UInt64(1) << 40
            switch owner {
            case .running: bits |= UInt64(1) << 41
            case .reaped(let status):
                bits |= (UInt64(1) << 42) | (UInt64(UInt32(bitPattern: status)) << 8)
            case .ownershipFailure: bits |= UInt64(1) << 43
            }
        }
        return bits
    }

    // Read the testing-only opt-in once. The complete type and environment key
    // are absent from production builds. Disabled traces do not format records.
    private static let mode = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS"]
    private static let sink = Sink(
        enabled: mode == "1" || mode == "boundaries" || mode == "costs",
        writer: { fputs($0, stderr); fflush(stderr) })
    // First failures retain a separate bounded allowance; successful trace
    // chatter cannot consume the evidence needed to diagnose retained work.
    private static let failureSink = Sink(
        enabled: mode == "1" || mode == "boundaries" || mode == "costs",
        writer: { fputs($0, stderr); fflush(stderr) })
    private static let revalidationSamples = SampleBudget(enabled: mode == "costs")
    private static let publisherSamples = SampleBudget(enabled: mode == "costs")
    // At most eight optional synchronous snapshots per process, including missing
    // or malformed files. Sink exhaustion cannot trigger more filesystem work.
    private static let policyTimingReads = SampleBudget(enabled: isEnabled)
    static func takePolicyTimingRead() -> Bool {
        isEnabled && failureSink.permitsObservation() && policyTimingReads.take()
    }
    static func recordPolicyTiming(_ snapshot: TestingPolicyHelperTiming.Snapshot?, issued: UInt64) {
        failureSink.emit(snapshot?.line(issued: issued) ?? "DISCOVERY POLICY HELPER TIMING unavailable=true\n")
    }

    static var isEnabled: Bool { mode == "1" || mode == "boundaries" || mode == "costs" }

    static func sampleRevalidation() -> Bool { revalidationSamples.take() }
    static func samplePublisherRevalidation() -> Bool { publisherSamples.take() }

    // One exact synchronous Store selection attempt, independent of earlier
    // expected refusals and trace saturation. Fixed slots accumulate costs;
    // nothing records paths, input, child output or arbitrary error text.
    enum CatalogCostStage: Int, CaseIterable { case setup, catalog, bind, discoveryPolicy, metadata }
    final class CatalogCostObservation {
        struct Totals {
            var calls: UInt64 = 0, wall: UInt64 = 0
            var entryRemaining: UInt64?, endRemaining: UInt64?
            var helpers: UInt64 = 0, helperTime: UInt64 = 0
            var sessions: UInt64 = 0, scratch: UInt64 = 0, snapshot: UInt64 = 0
            var resources: UInt64 = 0, postflight: UInt64 = 0
        }
        private var totals = Array(repeating: Totals(), count: CatalogCostStage.allCases.count)
        private var current: CatalogCostStage?
        private var last = CatalogCostStage.setup
        private var failedStage: CatalogCostStage?
        private var originalDeadline: UInt64?
        private var setup = [UInt64](repeating: 0, count: 4)
        private var finished = false
        private var failedSecondPolicyRequest: TestingPolicyHelperWitness.TimingRequest?
        private var postDrainRead = false
        private let output: Sink
        init(output: Sink) { self.output = output }
        private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let sum = lhs.addingReportingOverflow(rhs)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        func measure<Value>(_ stage: CatalogCostStage, _ body: () throws -> Value) rethrows -> Value {
            let previous = current, started = DispatchTime.now().uptimeNanoseconds
            current = stage; last = stage
            let index = stage.rawValue
            totals[index].entryRemaining = originalDeadline.map { $0 > started ? $0 - started : 0 }
            defer {
                let ended = DispatchTime.now().uptimeNanoseconds
                totals[index].calls = Self.add(totals[index].calls, 1)
                // Outer policy wall time includes the nested metadata body;
                // helper/session costs belong only to the innermost stage.
                totals[index].wall = Self.add(totals[index].wall, ended - started)
                totals[index].endRemaining = originalDeadline.map { $0 > ended ? $0 - ended : 0 }
                current = previous
            }
            do { return try body() }
            catch {
                // A nested throw retains its inner stage. A postflight throw
                // after a successful metadata return belongs to the outer call.
                if failedStage == nil { failedStage = stage }
                throw error
            }
        }
        func captureHelper(started: UInt64, ended: UInt64) {
            guard !finished, let current, ended >= started else { return }
            let index = current.rawValue
            totals[index].helpers = Self.add(totals[index].helpers, 1)
            totals[index].helperTime = Self.add(totals[index].helperTime, ended - started)
        }
        func captureFailedPolicyRequest(_ request: TestingPolicyHelperWitness.TimingRequest?) {
            let savedErrno = errno; defer { errno = savedErrno }
            // The fixed first Store catalog has one completed helper before the
            // failing second call. No other stage, ordinal or later request wins.
            guard !finished, current == .catalog, totals[CatalogCostStage.catalog.rawValue].helpers == 1,
                  failedSecondPolicyRequest == nil else { return }
            failedSecondPolicyRequest = request
        }
        func observePolicyTimingAfterDrain(home: String) {
            let savedErrno = errno; defer { errno = savedErrno }
            guard finished, failedStage != nil, !postDrainRead else { return }
            postDrainRead = true
            let request = failedSecondPolicyRequest; failedSecondPolicyRequest = nil
            guard let request else { return }
            let read = request.home == home ? TestingPolicyHelperWitness.readAfterDrain(request)
                : TestingPolicyHelperWitness.TimingRead(snapshot: nil, rejection: .request)
            output.emit("DISCOVERY CATALOG POLICY HELPER TIMING observation=postDrain helper=2 rejection=\(read.rejection?.rawValue ?? "none")\n")
            if let snapshot = read.snapshot { output.emit(snapshot.line(issued: request.budget.issued)) }
        }
        func captureSession(started: UInt64, ended: UInt64, milestones: [UInt64]) {
            guard !finished, let current, ended >= started else { return }
            let points = [started] + Array(milestones.prefix(3)) + [ended]
            guard zip(points, points.dropFirst()).allSatisfy({ $0 <= $1 }) else { return }
            let intervals = zip(points, points.dropFirst()).map { $1 - $0 }
            let index = current.rawValue
            totals[index].sessions = Self.add(totals[index].sessions, 1)
            // On refusal, the incomplete component receives its elapsed time;
            // later unentered components remain zero.
            totals[index].scratch = Self.add(totals[index].scratch, intervals[0])
            if intervals.count > 1 { totals[index].snapshot = Self.add(totals[index].snapshot, intervals[1]) }
            if intervals.count > 2 { totals[index].resources = Self.add(totals[index].resources, intervals[2]) }
            if intervals.count > 3 { totals[index].postflight = Self.add(totals[index].postflight, intervals[3]) }
        }
        func captureSetup(started: UInt64, ended: UInt64, milestones: [UInt64], deadline: UInt64? = nil) {
            guard !finished, current == .setup, ended >= started else { return }
            let points = [started] + Array(milestones.prefix(3)) + [ended]
            guard zip(points, points.dropFirst()).allSatisfy({ $0 <= $1 }) else { return }
            for (index, pair) in zip(points, points.dropFirst()).enumerated() { setup[index] = pair.1 - pair.0 }
            originalDeadline = deadline
        }
        func finish(succeeded: Bool) {
            guard !finished else { return }; finished = true
            guard !succeeded else { return }
            output.emit("DISCOVERY CATALOG COST context=retentionStoreInitial failed_stage=\((failedStage ?? last).rawValue) prebudget_ns=\(setup[0]) publisher_ns=\(setup[1]) snapshot_ns=\(setup[2]) session_binder_ns=\(setup[3])\n")
            for stage in CatalogCostStage.allCases {
                let value = totals[stage.rawValue]
                output.emit("DISCOVERY CATALOG COST stage=\(stage.rawValue) calls=\(value.calls) wall_ns=\(value.wall) helpers=\(value.helpers) helper_ns=\(value.helperTime) sessions=\(value.sessions) scratch_ns=\(value.scratch) snapshot_ns=\(value.snapshot) resources_ns=\(value.resources) postflight_ns=\(value.postflight) setup_entry_remaining_ns=\(value.entryRemaining.map { String($0) } ?? "absent") setup_end_remaining_ns=\(value.endRemaining.map { String($0) } ?? "absent")\n")
            }
        }
    }
    private static let catalogCostKey = "ShadowSync.DiscoveryFixtureDiagnostic.catalogCost"
    private static let firstCatalogCost = FirstAdmissionFailure()
    static var currentCatalogCost: CatalogCostObservation? {
        guard isEnabled else { return nil }
        return Thread.current.threadDictionary[catalogCostKey] as? CatalogCostObservation
    }
    static func withCatalogCost<Value>(observing: Bool,
        failed: ((CatalogCostObservation) -> Void)? = nil, _ body: () throws -> Value) rethrows -> Value {
        guard observing, isEnabled, firstCatalogCost.take() else { return try body() }
        let previous = currentCatalogCost
        let observation = CatalogCostObservation(output: Sink(enabled: true,
            writer: { fputs($0, stderr); fflush(stderr) }))
        Thread.current.threadDictionary[catalogCostKey] = observation
        var succeeded = false
        defer {
            // Emit at most six bounded lines, after the measured call throws.
            // Restore the original thread scope on every return and failure.
            if let previous { Thread.current.threadDictionary[catalogCostKey] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: catalogCostKey) }
            observation.finish(succeeded: succeeded)
            if !succeeded { failed?(observation) }
        }
        let result = try body(); succeeded = true; return result
    }
    static func measureCatalogCost<Value>(_ stage: CatalogCostStage, _ body: () throws -> Value) rethrows -> Value {
        if let observation = currentCatalogCost { return try observation.measure(stage, body) }
        return try body()
    }

    enum Component: String { case catalog, transport, custody, registry, admission, binder, selection, rebind, discovery, session, publisher, policyPreparation, publication, helperPreparation, phase }
    enum Stage: String {
        case entry, budget, input, authorityBefore, resources, execution
        case authorityAfter, decode, prepare, start, wait, result, postflight, decisions
        case queued, validated, metadata, resumed, ready, admissionQueued, controlFlushed, terminal, retired
        case deadlineBefore, revalidation, deadlineAfter, root, projection, scratch, snapshot
        case resourceFiles, appExecutable, runtimeTree
        case suspendedSpawn, suspendedVerification, ownerTransfer
        case authorityConstruction, lockValidation, installationFence, catalogFence, reservationWrite, preparedWrite
        case failure
    }
    static func record(_ component: Component, stage: Stage, started: UInt64,
                        deadline: UInt64?, resultBits: UInt64 = 0, succeeded: Bool = false,
                        milestones: [UInt64] = [], kind: RegistryKind = .policyClassify) {
        // Boundary mode keeps successful helper chatter from consuming the
        // same fixed budget before a later admission failure can be observed.
        if mode == "boundaries" || mode == "costs" {
            switch component {
            case .admission, .session, .binder, .selection, .rebind, .discovery, .publisher: break
            case .catalog, .transport, .custody, .policyPreparation, .publication, .helperPreparation, .phase: if succeeded { return }
            case .registry: if stage != .failure { return }
            }
        }
        func formatted() -> String {
            let now = DispatchTime.now().uptimeNanoseconds
            let expired = deadline.map { now >= $0 } ?? false
            let points = [started] + milestones + [now]
            let durations = zip(points, points.dropFirst()).map { String($1 - $0) }.joined(separator: ",")
            let kindField = component == .registry ? " kind=\(kind.rawValue)" : ""
            return "DISCOVERY FIXTURE DIAGNOSTIC component=\(component.rawValue)\(kindField) stage=\(stage.rawValue) elapsed_ns=\(now - started) deadline_expired=\(expired) result_bits=\(resultBits) succeeded=\(succeeded) intervals_ns=\(durations)\n"
        }
        sinkForRecord(component, stage: stage, succeeded: succeeded,
                      ordinary: sink, failures: failureSink).emit(formatted())
    }

    // Synchronous metadata admission only. Each thread holds at most the
    // current call, restored on return/throw; there is no history or cross-call
    // sample. No diagnostic context is propagated to dispatched work.
    enum AdmissionCaller: String {
        case catalog
        case initial, validate, requireAllowed, prepareAccess, willAccess
        case policyRelativePath, requireSelected, preparationFailure, finalValidation, errorValidation
    }
    private static let callerKey = "ShadowSync.DiscoveryFixtureDiagnostic.caller"
    private static let admissionKey = "ShadowSync.DiscoveryFixtureDiagnostic.admission"
    static func enterCaller(_ caller: AdmissionCaller) -> String? {
        guard isEnabled else { return nil }
        let previous = Thread.current.threadDictionary[callerKey] as? String
        Thread.current.threadDictionary[callerKey] = caller.rawValue
        return previous
    }
    static func leaveCaller(_ previous: String?) {
        guard isEnabled else { return }
        if let previous { Thread.current.threadDictionary[callerKey] = previous }
        else { Thread.current.threadDictionary.removeObject(forKey: callerKey) }
    }
    static var hasCaller: Bool { isEnabled && Thread.current.threadDictionary[callerKey] != nil }
    static var currentAdmission: AdmissionObservation? {
        guard isEnabled else { return nil }
        return Thread.current.threadDictionary[admissionKey] as? AdmissionObservation
    }
    final class AdmissionObservation: @unchecked Sendable {
        struct Sample {
            let stage: Stage
            let started: UInt64
            let ended: UInt64
            let passed: Bool
            let milestones: [UInt64]
        }
        let caller: AdmissionCaller
        let position: RepositorySelectionPathAdmission.TestingPosition
        let started: UInt64
        let deadline: UInt64
        // This object is confined to its synchronous validate call/thread.
        // Components are fixed slots, never an accumulated history.
        var session: Sample?
        var publisher: Sample?
        var phase: Sample?
        init(caller: AdmissionCaller, position: RepositorySelectionPathAdmission.TestingPosition,
             started: UInt64, deadline: UInt64) {
            self.caller = caller; self.position = position
            self.started = started; self.deadline = deadline
        }
        func capture(_ component: Component, stage: Stage, started: UInt64,
                     passed: Bool, milestones: [UInt64] = []) {
            let sample = Sample(stage: stage, started: started,
                ended: DispatchTime.now().uptimeNanoseconds, passed: passed,
                milestones: Array(milestones.prefix(3)))
            switch component {
            case .session: session = sample
            case .publisher: publisher = sample
            case .phase: phase = sample
            default: break
            }
        }
    }
    private final class FirstAdmissionFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !recorded else { return false }
            recorded = true; return true
        }
    }
    private static let firstAdmissionFailure = FirstAdmissionFailure()
    static func beginAdmission(position: RepositorySelectionPathAdmission.TestingPosition,
                               started: UInt64, deadline: UInt64)
        -> RepositorySelectionPathAdmission.TestingValidationCompletion? {
        guard isEnabled,
              let raw = Thread.current.threadDictionary[callerKey] as? String,
              let caller = AdmissionCaller(rawValue: raw) else { return nil }
        let previous = currentAdmission
        let observation = AdmissionObservation(caller: caller, position: position,
            started: started, deadline: deadline)
        Thread.current.threadDictionary[admissionKey] = observation
        return { failed in
            defer {
                if let previous { Thread.current.threadDictionary[admissionKey] = previous }
                else { Thread.current.threadDictionary.removeObject(forKey: admissionKey) }
            }
            guard let failed, firstAdmissionFailure.take() else { return }
            let ended = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline > started ? deadline - started : 0
            failureSink.emit("DISCOVERY ADMISSION FIRST FAILURE caller=\(caller.rawValue)"
                + " position=\(position.rawValue) cut=\(failed.rawValue)"
                + " entry_remaining_ns=\(remaining) elapsed_ns=\(ended - started)"
                + " deadline_expired=\(ended >= deadline)\n")
            func emit(_ component: Component, _ sample: AdmissionObservation.Sample?) {
                guard let sample else {
                    failureSink.emit("DISCOVERY ADMISSION SAMPLE component=\(component.rawValue) observed=false\n")
                    return
                }
                let points = [sample.started] + sample.milestones + [sample.ended]
                let intervals = zip(points, points.dropFirst()).map { String($1 - $0) }.joined(separator: ",")
                failureSink.emit("DISCOVERY ADMISSION SAMPLE component=\(component.rawValue) observed=true"
                    + " stage=\(sample.stage.rawValue) succeeded=\(sample.passed)"
                    + " elapsed_ns=\(sample.ended - sample.started) intervals_ns=\(intervals)\n")
            }
            emit(.session, observation.session)
            emit(.phase, observation.phase)
            emit(.publisher, observation.publisher)
        }
    }

    enum RepositoryReadStage: String {
        case fixture, resources, parallelCommands, parallelResults, drain, onceOnly
        case progress, cleanupDrain, fixtureCleanup
    }
    // Closed mismatch mask: header/count bits0...4, path/selection comparisons
    // bits5...9, root/repository identity scalars bits10...19; bit20 reports
    // an uninspected tail. No original or current field value is emitted.
    static func rebindMismatchBits(original: ValidatedSelectedRepositoryScope,
        current: ValidatedSelectedRepositoryScope) -> UInt64 {
        var bits: UInt64 = 0
        if original.selectionGeneration != current.selectionGeneration { bits |= 1 << 0 }
        if original.policyDigest != current.policyDigest { bits |= 1 << 1 }
        if original.catalogGeneration != current.catalogGeneration { bits |= 1 << 2 }
        if original.governedRootRole != current.governedRootRole { bits |= 1 << 3 }
        if original.repositories.count != current.repositories.count { bits |= 1 << 4 }
        if max(original.repositories.count, current.repositories.count) > 64 { bits |= 1 << 20 }
        for (a, b) in zip(original.repositories.prefix(64), current.repositories.prefix(64)) {
            if a.repositoryID != b.repositoryID { bits |= 1 << 5 }
            if a.locator != b.locator { bits |= 1 << 6 }
            if a.governedRootPath != b.governedRootPath { bits |= 1 << 7 }
            if a.policyRootPath != b.policyRootPath { bits |= 1 << 8 }
            if a.repositoryPath != b.repositoryPath { bits |= 1 << 9 }
            if a.rootIdentity.device != b.rootIdentity.device { bits |= 1 << 10 }
            if a.rootIdentity.inode != b.rootIdentity.inode { bits |= 1 << 11 }
            if a.rootIdentity.owner != b.rootIdentity.owner { bits |= 1 << 12 }
            if a.rootIdentity.mode != b.rootIdentity.mode { bits |= 1 << 13 }
            if a.rootIdentity.linkCount != b.rootIdentity.linkCount { bits |= 1 << 14 }
            if a.repositoryIdentity.device != b.repositoryIdentity.device { bits |= 1 << 15 }
            if a.repositoryIdentity.inode != b.repositoryIdentity.inode { bits |= 1 << 16 }
            if a.repositoryIdentity.owner != b.repositoryIdentity.owner { bits |= 1 << 17 }
            if a.repositoryIdentity.mode != b.repositoryIdentity.mode { bits |= 1 << 18 }
            if a.repositoryIdentity.linkCount != b.repositoryIdentity.linkCount { bits |= 1 << 19 }
        }
        return bits
    }
    private static let firstRebindMismatch = FirstAdmissionFailure()
    static func recordRebindMismatch(original: ValidatedSelectedRepositoryScope,
        current: ValidatedSelectedRepositoryScope) {
        guard isEnabled, firstRebindMismatch.take() else { return }
        let bits = rebindMismatchBits(original: original, current: current)
        failureSink.emit("DISCOVERY REBIND FIRST MISMATCH fields=\(bits)\n")
    }

    enum RepositoryReadErrorFamily: String {
        case repositoryCommand, selectedScope, gitConfiguration, resource, policyAuthority
        case gitSafety, fixture, other
    }
    static func recordRepositoryReadFailure(stage: RepositoryReadStage,
        family: RepositoryReadErrorFamily, outcomes: Int, admitted: Int, retired: Int) {
        guard isEnabled else { return }
        failureSink.emit("DISCOVERY PARALLEL READ FIRST FAILURE stage=\(stage.rawValue)"
            + " family=\(family.rawValue) outcomes=\(outcomes)"
            + " admitted=\(admitted) retired=\(retired)\n")
    }

    enum RegistryKind: String { case policyClassify, retentionArchive, repositoryGit }
    enum RetentionCommand: Int {
        case statusFirst = 1, statusReplay, bundleCreate, bundleVerify, clone
        case checkout, revision, connectivity, restoredStatus
        var family: String {
            switch self {
            case .statusFirst, .statusReplay, .restoredStatus: "status"
            case .bundleCreate: "bundle-create"
            case .bundleVerify: "bundle-verify"
            case .clone: "clone"
            case .checkout: "checkout"
            case .revision: "revision"
            case .connectivity: "connectivity"
            }
        }
    }
    static func recordRetentionResult(_ result: CustodyRegistryResult, command: RetentionCommand) {
        // Mirror the fixture's existing require, including nil journal semantics.
        guard isEnabled, !(result.phase == .finished && result.journal?.waitStatus == 0
            && result.journal?.reason == CustodyReason.none) else { return }
        let phase: String
        switch result.phase {
        case .starting: phase = "starting"
        case .ready: phase = "ready"
        case .running: phase = "running"
        case .cleanupPending: phase = "cleanup-pending"
        case .finished: phase = "finished"
        }
        failureSink.emit("RETENTION FIXTURE COMMAND ordinal=\(command.rawValue) family=\(command.family)"
            + " phase=\(phase) reason=\(result.reason?.rawValue ?? "absent")"
            + " journal_present=\(result.journal != nil)"
            + " journal_reason=\(result.journal?.reason?.rawValue ?? "absent")"
            + " wait_status=\(result.journal?.waitStatus.map { String($0) } ?? "absent")\n")
    }
    static func recordRetentionBody3Entry(_ report: Body3BatchReport,
        beforePrepare: Bool, afterStart: Bool, contextObserved: Bool) {
        guard isEnabled, !afterStart else { return }
        // One closed record at the existing failing fixture assertion. The
        // shared failure allowance and actual retention opt-in remain unchanged.
        let node = report.results.first { $0.node.kind == .retention }
        failureSink.emit("RETENTION BODY3 PRE-STORE node_kind=retention"
            + " node_present=\(node != nil) status=\(node?.status.rawValue ?? "absent")"
            + " before_prepare=\(beforePrepare) after_start=\(afterStart)"
            + " context_observed=\(contextObserved) cancelled=\(report.cancelled) paused=\(report.paused)\n")
    }

    static func recordFixtureCleanup(registryEmpty: Bool, scopeTerminal: Bool,
                                     unsubmittedClosed: Bool, catalogEmpty: Bool?) {
        guard isEnabled, !(registryEmpty && (scopeTerminal || unsubmittedClosed) && catalogEmpty == true) else { return }
        failureSink.emit("RETENTION DISCOVERY FIXTURE CLEANUP registry_empty=\(registryEmpty)"
            + " scope_terminal_or_absent=\(scopeTerminal) unsubmitted_closed=\(unsubmittedClosed)"
            + " catalog_empty=\(catalogEmpty.map { String($0) } ?? "unknown")\n")
    }

    static func recordRepositoryWorkerComparison(_ journal: CustodyJournal,
        helperMatches: Bool, targetMatches: Bool, budgetMatchMask: UInt8,
        budgetCountMatches: Bool) {
        guard isEnabled, !(journal.kind == .repositoryGit
            && journal.outcome == .cancelledDrained && journal.reason == .cancelled
            && helperMatches && targetMatches && budgetCountMatches && budgetMatchMask == 31) else { return }
        failureSink.emit("DISCOVERY REPOSITORY WORKER COMPARISON kind=\(journal.kind.rawValue)"
            + " outcome=\(journal.outcome?.rawValue ?? "absent") reason=\(journal.reason?.rawValue ?? "absent")"
            + " helper_match=\(helperMatches) target_match=\(targetMatches)"
            + " budget_match_mask=\(budgetMatchMask) budget_count_match=\(budgetCountMatches)\n")
    }

    // Reuse the one-shot latch and the existing shared failure allowance. This
    // observes only an actual failing runRepository wait result, never a reread.
    // The helper's diagnostic shares the captured stderr carrier with target
    // output. Project only a complete, final, LF-delimited closed frame; never
    // forward raw bytes or treat this observation as authenticated authority.
    private static let repositoryCustodianFailureProjections: [(bytes: Data, event: String, error: String,
                                                               detail: RepositoryBusyObservation.Snapshot)] = {
        let events = ["spawnTargetFailure", "advanceStageFailure", "repositoryPostflightFailure"]
        let families = [
            "busy", "committed-cleanup", "conflict", "fenced", "git-busy",
            "git-cancelled", "git-command-failed", "git-custom-transport", "git-detached", "git-dirty",
            "git-hidden-index", "git-local-main-missing", "git-main-linked", "git-malformed-config", "git-origin-changed",
            "git-primary-not-main", "git-remote-main-missing", "git-replacement-or-graft", "git-repository-removed", "git-unsafe-repository",
            "git-unsupported-hook", "host-policy-unavailable", "injected", "invalid-record", "invalid-transition",
            "none", "other", "persistence", "policy-file-unavailable", "policy-helper-cleanup-pending",
            "policy-helper-unavailable", "policy-invalid-request", "policy-invalid-response", "protocol-budget", "protocol-message",
            "protocol-sequence", "publisher-unavailable", "resource-closed", "resource-invalid", "resource-limit",
            "resource-system-call", "unsafe-metadata",
        ]
        return events.flatMap { event in
            families.flatMap { error in
                let details: [RepositoryBusyObservation.Snapshot]
                if event == "spawnTargetFailure", error == "busy" {
                    details = RepositoryBusyObservation.Transition.allCases.flatMap { transition in
                        RepositoryBusyObservation.Site.allCases.map { .init(transition: transition, site: $0) }
                    }
                } else { details = [.init()] }
                return details.map { detail in
                    let line = "DISCOVERY REPOSITORY CUSTODIAN FIRST FAILURE event=\(event) error=\(error)"
                        + " transition=\(detail.transition.rawValue) busy_site=\(detail.site.rawValue)\n"
                    return (bytes: Data(line.utf8), event: event, error: error, detail: detail)
                }
            }
        }
    }()
    static func repositoryCustodianFailureProjection(_ bytes: Data)
        -> (event: String, error: String, detail: RepositoryBusyObservation.Snapshot)? {
        for row in repositoryCustodianFailureProjections {
            guard bytes.count >= row.bytes.count,
                  bytes.suffix(row.bytes.count).elementsEqual(row.bytes),
                  bytes.count == row.bytes.count || bytes[bytes.endIndex - row.bytes.count - 1] == 10 else { continue }
            return (event: row.event, error: row.error, detail: row.detail)
        }
        return nil
    }
    /// An earlier expected refusal must not consume the explicitly observed
    /// command's evidence. Each closed lane remains process-wide and one-shot.
    final class RepositoryResultFailureSelection: @unchecked Sendable {
        private let ordinary = FirstAdmissionFailure()
        private let observed = FirstAdmissionFailure()
        func take(enabled: Bool, observeCustodianFailure: Bool) -> Bool {
            guard enabled else { return false }
            return (observeCustodianFailure ? observed : ordinary).take()
        }
    }
    private static let repositoryResultFailureSelection = RepositoryResultFailureSelection()
    static func recordRepositoryResult(_ result: CustodyRegistryResult, observeCustodianFailure: Bool = false) {
        let savedErrno = errno
        defer { errno = savedErrno }
        guard repositoryResultFailureSelection.take(enabled: isEnabled,
            observeCustodianFailure: observeCustodianFailure) else { return }
        let phase: String
        switch result.phase {
        case .starting: phase = "starting"
        case .ready: phase = "ready"
        case .running: phase = "running"
        case .cleanupPending: phase = "cleanup-pending"
        case .finished: phase = "finished"
        }
        failureSink.emit("DISCOVERY REPOSITORY WAIT FIRST FAILURE phase=\(phase)"
            + " observed=\(observeCustodianFailure)"
            + " reason=\(result.reason?.rawValue ?? "absent")"
            + " journal_present=\(result.journal != nil)"
            + " journal_phase=\(result.journal?.phase.rawValue ?? "absent")"
            + " journal_kind=\(result.journal?.kind.rawValue ?? "absent")"
            + " journal_reason=\(result.journal?.reason?.rawValue ?? "absent")"
            + " outcome=\(result.journal?.outcome?.rawValue ?? "absent")"
            + " wait_status=\(result.journal?.waitStatus.map { String($0) } ?? "absent")\n")
        if observeCustodianFailure, result.phase == .finished, result.journal?.kind == .repositoryGit {
            if let projection = repositoryCustodianFailureProjection(result.stderr) {
                failureSink.emit("DISCOVERY REPOSITORY CUSTODIAN FIRST FAILURE carrier=stderr present=true"
                    + " event=\(projection.event) error=\(projection.error)"
                    + " transition=\(projection.detail.transition.rawValue) busy_site=\(projection.detail.site.rawValue)\n")
            } else {
                failureSink.emit("DISCOVERY REPOSITORY CUSTODIAN FIRST FAILURE carrier=stderr present=false\n")
            }
        }
    }

    /// Exact closed result fields for failed fixture commands. No process IDs,
    /// request data, paths, child output or arbitrary errors enter this record.
    static func recordCustodyResult(_ result: CustodyRegistryResult) {
        guard result.phase != .finished || result.journal?.outcome != .completed
            || result.journal?.waitStatus != 0
            || (result.reason != nil && result.reason != CustodyReason.none) else { return }
        let phase: String
        switch result.phase {
        case .starting: phase = "starting"
        case .ready: phase = "ready"
        case .running: phase = "running"
        case .cleanupPending: phase = "cleanup-pending"
        case .finished: phase = "finished"
        }
        failureSink.emit("DISCOVERY CUSTODY RESULT phase=\(phase)"
            + " reason=\(result.reason?.rawValue ?? "absent")"
            + " journal_reason=\(result.journal?.reason?.rawValue ?? "absent")"
            + " outcome=\(result.journal?.outcome?.rawValue ?? "absent")"
            + " wait_status=\(result.journal?.waitStatus.map { String($0) } ?? "absent")"
            + " ordinal=\(result.journal.map { String($0.ordinal) } ?? "absent")"
            + " helper_observed=\(result.journal?.custodian != nil)"
            + " target_observed=\(result.journal?.target != nil)\n")
    }

    // Registry phase observations are progress even though they omit succeeded.
    // Other components report either explicit success or a terminal failure.
    // Keep failure capacity independent of successful/progress trace saturation.
    static func sinkForRecord(_ component: Component, stage: Stage, succeeded: Bool,
                              ordinary: Sink, failures: Sink) -> Sink {
        stage == .failure || (component != .registry && !succeeded) ? failures : ordinary
    }
}

/// Fixture code identity only. It never manufactures a Developer ID publisher
/// identity and is absent from every production build.
final class DiscoveryFixtureCode: @unchecked Sendable {
    let path: String
    let codeDirectory: Data
    let requirement: SecRequirement
    private let snapshot: PublisherExecutableSnapshot

    init(path: String) throws {
        guard path.hasPrefix("/private/tmp/shadow-sync-") else {
            throw PublisherPolicyError.unavailable
        }
        let before = try PublisherExecutableSnapshot.capture(path: path, owner: geteuid())
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: SecCSFlags.noNetworkAccess.rawValue
            | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw PublisherPolicyError.unavailable
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else {
            throw PublisherPolicyError.unavailable
        }
        let expression = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        var required: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &required) == errSecSuccess,
              let required, SecStaticCodeCheckValidity(code, flags, required) == errSecSuccess,
              before == (try PublisherExecutableSnapshot.capture(path: path, owner: geteuid())) else {
            throw PublisherPolicyError.unavailable
        }
        self.path = path; codeDirectory = hash; requirement = required; snapshot = before
    }

    func revalidate() throws {
        guard snapshot == (try PublisherExecutableSnapshot.capture(path: path, owner: geteuid())) else {
            throw PublisherPolicyError.unavailable
        }
    }

    func validateSuspended(_ pid: pid_t) throws {
        try revalidate()
        var code: SecCode?
        guard pid > 0,
              SecCodeCopyGuestWithAttributes(nil,
                [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, .noNetworkAccess, requirement) == errSecSuccess else {
            throw PublisherPolicyError.unavailable
        }
        try revalidate()
    }
}

/// Fixed resources beneath an isolated HOME. The sealed production request
/// remains unchanged; it contains no fixture command, executable or scratch
/// override. Only the separate compiled testing entrypoint reads these files.
enum DiscoveryFixtureResources {
    static func resourceRoot(home: String) -> String {
        URL(fileURLWithPath: home).deletingLastPathComponent().path
    }
    static func resourcePaths(home: String, requestID: String) throws -> [String] {
        let path = resourceRoot(home: home) + "/owner-resources/"
            + (try DiscoveryResourceReceipt.directoryName(requestID: requestID))
        return [path, path + "/config"]
    }
    static func directory(home: String) throws -> String {
        _ = try EffectiveAccount.isolated(homeDirectory: home)
        let path = home + "/.shadow-sync-fixture"
        try TestIsolation.validateContainedDirectory(path, root: home)
        return path
    }

    static func read(home: String, name: String, maximum: Int = 1_048_576) throws -> PolicyAuthorityFile {
        guard ["framework-location.json", "PolicyAdapter.py", "awa-contract.json",
               "policy-runtime-source.json", "command-graphs.json"].contains(name) else {
            throw PublisherPolicyError.unavailable
        }
        return try PolicyAuthorityFile.read(path: directory(home: home) + "/" + name,
            owner: geteuid(), maximumBytes: maximum)
    }

    static func framework(home: String) throws -> (String, PolicyAuthorityFile) {
        let file = try read(home: home, name: "framework-location.json", maximum: 16_384)
        let value = try CustodyWire.decode(file.bytes, maximum: 16_384).object(keys: ["schema", "path"])
        guard try CustodyWire.text(value["schema"]) == "shadow-sync-discovery-fixture/v1" else {
            throw PublisherPolicyError.unavailable
        }
        let path = try CustodyWire.text(value["path"])
        guard path.hasPrefix("/private/tmp/shadow-sync-"),
              URL(fileURLWithPath: path).lastPathComponent == "Python.framework" else {
            throw PublisherPolicyError.unavailable
        }
        _ = try TestIsolation.validateRoot(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        return (path, file)
    }

    static func systemConfiguration(home: String) throws -> String {
        try directory(home: home) + "/fixture-system-config"
    }
}
#endif

#if SHADOW_SYNC_TESTING
/// Eight scalar slots on the actual validated inherited request. Zero is merely
/// storage for an absent slot; presence is always reported separately.
final class TestingPolicyHelperTiming: @unchecked Sendable {
    static let environmentEntry = "SHADOW_SYNC_TEST_POLICY_HELPER_TIMING=1"
    static var childOptedIn: Bool {
        ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_HELPER_TIMING"] == "1"
    }
    static func activation(parentEnabled: Bool, fixedHelper: Bool, kind: CustodyCommandKind) -> Bool {
        parentEnabled && fixedHelper && kind == .policyClassify
    }
    enum Phase: Int { case constructorFinished, journalClaimFinished, readyQueued, admitConsumed
        case suspendedVerificationFinished, resumed, drained, terminalCommitted }
    struct Snapshot {
        var presence: UInt64 = 0
        var constructorFinished: UInt64 = 0, journalClaimFinished: UInt64 = 0
        var readyQueued: UInt64 = 0, admitConsumed: UInt64 = 0
        var suspendedVerificationFinished: UInt64 = 0, resumed: UInt64 = 0
        var drained: UInt64 = 0, terminalCommitted: UInt64 = 0
        var values: [UInt64] { [constructorFinished, journalClaimFinished, readyQueued, admitConsumed,
            suspendedVerificationFinished, resumed, drained, terminalCommitted] }
        static let names = ["constructor_finished", "journal_claim_finished", "ready_queued", "admit_consumed",
            "suspended_verification_finished", "resumed", "drained", "terminal_committed"]
        var fields: [String: Any] {
            var value: [String: Any] = ["presence": presence]
            for (name, stamp) in zip(Self.names, values) { value[name] = stamp }
            return value
        }
        func line(issued: UInt64) -> String {
            // Closed positional elapsed nanoseconds in the documented phase order.
            // Absent slots stay explicit; no timestamp, path or request is emitted.
            let elapsed = values.enumerated().map { index, stamp in
                presence & (UInt64(1) << index) == 0 ? "absent" : String(stamp - issued)
            }.joined(separator: ",")
            return "DISCOVERY POLICY HELPER TIMING presence=\(presence) elapsed_ns=\(elapsed)\n"
        }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func mark(_ phase: Phase) {
        let savedErrno = errno
        defer { errno = savedErrno }
        lock.lock(); defer { lock.unlock() }
        let bit = UInt64(1) << phase.rawValue
        guard value.presence & bit == 0 else { return }
        let stamp = DispatchTime.now().uptimeNanoseconds
        switch phase {
        case .constructorFinished: value.constructorFinished = stamp
        case .journalClaimFinished: value.journalClaimFinished = stamp
        case .readyQueued: value.readyQueued = stamp
        case .admitConsumed: value.admitConsumed = stamp
        case .suspendedVerificationFinished: value.suspendedVerificationFinished = stamp
        case .resumed: value.resumed = stamp
        case .drained: value.drained = stamp
        case .terminalCommitted: value.terminalCommitted = stamp
        }
        value.presence |= bit
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
#endif
