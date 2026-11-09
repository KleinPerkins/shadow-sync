#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import Security
import ShadowSyncCatalog

/// Closed, testing-only failure observations: no path, input, child output or
/// arbitrary error text is admitted. These observations never alter a budget.
enum DiscoveryFixtureDiagnostic {
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

    static var isEnabled: Bool { mode == "1" || mode == "boundaries" || mode == "costs" }

    static func sampleRevalidation() -> Bool { revalidationSamples.take() }
    static func samplePublisherRevalidation() -> Bool { publisherSamples.take() }

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
    private static let firstRepositoryResultFailure = FirstAdmissionFailure()
    static func recordRepositoryResult(_ result: CustodyRegistryResult) {
        guard isEnabled, firstRepositoryResultFailure.take() else { return }
        let phase: String
        switch result.phase {
        case .starting: phase = "starting"
        case .ready: phase = "ready"
        case .running: phase = "running"
        case .cleanupPending: phase = "cleanup-pending"
        case .finished: phase = "finished"
        }
        failureSink.emit("DISCOVERY REPOSITORY WAIT FIRST FAILURE phase=\(phase)"
            + " reason=\(result.reason?.rawValue ?? "absent")"
            + " journal_present=\(result.journal != nil)"
            + " journal_phase=\(result.journal?.phase.rawValue ?? "absent")"
            + " journal_kind=\(result.journal?.kind.rawValue ?? "absent")"
            + " journal_reason=\(result.journal?.reason?.rawValue ?? "absent")"
            + " outcome=\(result.journal?.outcome?.rawValue ?? "absent")"
            + " wait_status=\(result.journal?.waitStatus.map { String($0) } ?? "absent")\n")
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
