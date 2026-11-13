#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// A real finite-wait body failure; only the two real wait-return branches construct this.
struct SignedJoinHoldTimeout: Error {
    enum Latch: Equatable, Sendable { case adapter, invocation }
    let latch: Latch, bindingDigest: String, H: UInt64
}
private final class SignedInstallationFixtureJoinControlOwner: SignedInstallationFixtureServiceCustody, @unchecked Sendable {
    let bootstrap: InstallationBootstrap, registry: RetainedCleanupRegistry
    let service: SignedInstallationFixtureService, context: SignedInstallationFixtureContext
    private unowned let custody: InstallationReadinessFixtureCustody
    private let lock = NSLock()
    private var controller: SignedInstallationFixtureJoinController?
    private var invocation: InstallationFixtureWork?
    private var handle: RetainedCleanupRegistry.Handle?
    private var completed = false
    init(bootstrap: InstallationBootstrap, registry: RetainedCleanupRegistry,
         service: SignedInstallationFixtureService, context: SignedInstallationFixtureContext,
         custody: InstallationReadinessFixtureCustody) {
        self.bootstrap = bootstrap; self.registry = registry; self.service = service
        self.context = context; self.custody = custody
    }
    func set(_ controller: SignedInstallationFixtureJoinController) { lock.lock(); self.controller = controller; lock.unlock() }
    func set(_ invocation: InstallationFixtureWork) { lock.lock(); self.invocation = invocation; lock.unlock() }
    func checkpoint(_ operation: LifecycleLaunchCommand.Operation, _ point: InstallationBootstrap.StartCheckpoint) throws {
        guard operation == .bootstrap else { throw CustodyRecordError.fenced }
        lock.lock(); let controller = self.controller; lock.unlock()
        guard let controller else { throw CustodyRecordError.fenced }
        if point == .commandRetained {
            guard let budget = bootstrap.testingStartBudget(kickstart: false), let bound = controller.binding,
                  bound.request.budget == budget else { throw CustodyRecordError.fenced }
            registry.testingDeferNextRead(.outputUntilReleased)
        }
        if point == .submitted {
            guard let handle = bootstrap.testingStartHandle(kickstart: false) else { throw CustodyRecordError.fenced }
            lock.lock(); self.handle = handle; lock.unlock()
            try controller.holdSubmitted() // Bootstrap and registry locks are not held.
        }
    }
    func selectedState() -> (invocation: InstallationFixtureWork?, handle: RetainedCleanupRegistry.Handle?, binding: SignedInstallationFixtureJoinController.Bound?) {
        lock.lock(); defer { lock.unlock() }
        return (invocation, handle, controller?.binding)
    }
    func releaseOnUnwind() {
        lock.lock(); let controller = self.controller, handle = self.handle; lock.unlock()
        controller?.releaseForTeardown()
        if let handle { registry.testingReleaseDeferredRead(handle) }
        registry.testingRequestCancellation()
    }
    func closeFixtureService(deadline: MonotonicDeadline) throws {
        lock.lock()
        let controller = self.controller, invocation = self.invocation, handle = self.handle, done = completed
        lock.unlock()
        if done { return }
        releaseOnUnwind()
        // Try every independent release/join even if another one fails. Failed
        // preconditions retain this owner; they never manufacture disposition.
        var failures: [Error] = []
        do { try service.closeFixtureService(deadline: deadline) } catch { failures.append(error) }
        if let invocation { do { try invocation.join(deadline: deadline) } catch { failures.append(error) } }
        if let handle { registry.testingRevisitFinalization(handle) }
        if !registry.hasRetainedWork {
            do { try bootstrap.testingReleaseFailedStartAliases() } catch { failures.append(error) }
            do { try bootstrap.testingCloseReadiness(deadline: deadline) } catch { failures.append(error) }
            do { try bootstrap.testingRemoveReadinessEndpoint() } catch { failures.append(error) }
        } else { failures.append(CustodyRecordError.busy) }
        if let failure = failures.first { throw failure }
        guard registry.testingOriginalHelpersReaped else { throw CustodyRecordError.busy }
        lock.lock(); completed = true; lock.unlock()
    }
}

enum SignedInstallationFixtureJoinControlFixtures {
    private typealias H = InstallationStorageFixtures
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RetainedCleanupRegistry.TestExpiredCleanupPoint] = []
        func append(_ point: RetainedCleanupRegistry.TestExpiredCleanupPoint) { lock.lock(); values.append(point); lock.unlock() }
        var observed: [RetainedCleanupRegistry.TestExpiredCleanupPoint] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private static func wait(_ ceiling: MonotonicDeadline, _ condition: () throws -> Bool) throws {
        while !(try condition()) {
            guard !ceiling.hasExpired else { throw CustodyRecordError.busy }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    private struct Durable: Equatable {
        let control: Data, catalog: Data, journal: Data
        let archive: Bool, caller: Bool
        init(context: SignedInstallationFixtureContext, request: UnvalidatedCustodyRequest) throws {
            let root = context.paths.state.path + "/custody/", id = request.binding.requestID
            control = try Data(contentsOf: URL(fileURLWithPath: root + InstallationControlRecord.filename))
            catalog = try Data(contentsOf: URL(fileURLWithPath: root + "catalog.json"))
            journal = try Data(contentsOf: URL(fileURLWithPath: root + id + ".json"))
            archive = FileManager.default.fileExists(atPath: root + "receipts/" + id + ".json")
            caller = FileManager.default.fileExists(atPath: root + "receipts/" + id + ".caller.json")
        }
    }
    private static func failed(_ bootstrap: InstallationBootstrap, handle: RetainedCleanupRegistry.Handle,
                               context: SignedInstallationFixtureContext) throws {
        try H.check(handle.snapshot().phase == .cleanupPending && bootstrap.observation().failedClosed
            && bootstrap.bootstrapStartObservation() == .failed && (try bootstrap.testingStagedJournalStartsRefused()),
            "signed adapter expiry must preserve failed start and closed admission")
        try H.refuses { _ = try handle.stagedCompletion() }
        try H.refuses { _ = try handle.stagedRecoveryRetirement() }
        try H.refuses { try bootstrap.retireFailedStartCommands() }
        try H.refuses { _ = try bootstrap.testingStartReadinessDeadline() }
        try InstallationOwnershipFixtures.excluded(context.paths.state)
    }
    /// Private one-use reached-state certificate, never request-selected authority.
    private final class Certificate: @unchecked Sendable {
        let scenario: SignedInstallationFixtureCase, requestDigest: String, transactionDigest: String
        let context: ObjectIdentifier, root: ObjectIdentifier, controller: ObjectIdentifier
        let bound: SignedInstallationFixtureJoinController.Bound?
        let snapshot: RetainedCleanupRegistry.SignedJoinSnapshot?
        let invocation: ObjectIdentifier?, handle: ObjectIdentifier?
        let reached: UInt64
        private let lock = NSLock()
        private var consumed = false
        init(_ scenario: SignedInstallationFixtureCase, context: SignedInstallationFixtureContext,
             custody: InstallationReadinessFixtureCustody, controller: SignedInstallationFixtureJoinController,
             request: SignedInstallationFixtureContext.Request, transactionDigest: String,
             owner: SignedInstallationFixtureJoinControlOwner, snapshot: RetainedCleanupRegistry.SignedJoinSnapshot?) {
            self.scenario = scenario; self.context = ObjectIdentifier(context); root = ObjectIdentifier(custody)
            self.controller = ObjectIdentifier(controller); requestDigest = CustodyRecordBinding.digest(request.bytes)
            self.transactionDigest = transactionDigest; bound = controller.binding; self.snapshot = snapshot
            let selected = owner.selectedState()
            invocation = selected.invocation.map(ObjectIdentifier.init); handle = selected.handle.map(ObjectIdentifier.init)
            reached = RuntimeSuiteGuardian.now
        }
        func consume(_ scenario: SignedInstallationFixtureCase, context: SignedInstallationFixtureContext,
                     custody: InstallationReadinessFixtureCustody, controller: SignedInstallationFixtureJoinController,
                     request: SignedInstallationFixtureContext.Request, transactionDigest: String,
                     owner: SignedInstallationFixtureJoinControlOwner) throws {
            lock.lock(); defer { lock.unlock() }
            let selected = owner.selectedState()
            guard invocation == selected.invocation.map(ObjectIdentifier.init), handle == selected.handle.map(ObjectIdentifier.init),
                  !consumed, self.scenario == scenario, self.context == ObjectIdentifier(context),
                  root == ObjectIdentifier(custody), self.controller == ObjectIdentifier(controller),
                  requestDigest == CustodyRecordBinding.digest(request.bytes), self.transactionDigest == transactionDigest,
                  bound?.digest == controller.binding?.digest, bound?.channel == controller.binding?.channel,
                  reached < request.deadline else { throw CustodyRecordError.fenced }
            try controller.requireOwner(context: context, custody: custody)
            if let snapshot, let handle = selected.handle {
                let current = try owner.registry.testingSignedJoinSnapshot(handle)
                guard current.request == snapshot.request, current.record == snapshot.record,
                      current.originalReceipt == snapshot.originalReceipt,
                      current.effectiveReceipt == snapshot.effectiveReceipt, current.operation == snapshot.operation else {
                    throw CustodyRecordError.fenced
                }
            } else { guard snapshot == nil && selected.handle == nil else { throw CustodyRecordError.fenced } }
            consumed = true
        }
    }
    private struct InjectedAssertion: Error { let certificate: Certificate }
    private struct HSubjectFailure: Error { let adapter: SignedJoinHoldTimeout, invocation: SignedJoinHoldTimeout }

    static func requireControlReportTransport() throws {
        var info = stat()
        let flags = fcntl(STDERR_FILENO, F_GETFL)
        guard fstat(STDERR_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
              flags >= 0, (flags & O_ACCMODE) == O_WRONLY, (flags & O_NONBLOCK) != 0 else {
            throw CustodyRecordError.fenced
        }
    }
    /// No buffering, refreshed deadline, or post-spawn descriptor mutation.
    private static func emit(_ report: [String: Any], deadline: MonotonicDeadline) throws {
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes = Data("SIGNED_JOIN_CONTROL_V1 ".utf8) + json + Data([10])
        guard bytes.count <= 4096 else { throw CustodyRecordError.fenced }
        try requireControlReportTransport()
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                let written = Darwin.write(STDERR_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { throw CustodyRecordError.fenced }
                let now = RuntimeSuiteGuardian.now, C = deadline.absoluteUptimeNanoseconds
                guard now < C else { throw CustodyRecordError.busy }
                // Floor milliseconds and bound Int32 conversion. Zero is a poll,
                // not permission to refresh the original absolute cap.
                let milliseconds = min((C - now) / 1_000_000, UInt64(Int32.max))
                var item = pollfd(fd: STDERR_FILENO, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&item, 1, Int32(milliseconds))
                if result < 0 && errno == EINTR { continue }
                guard result >= 0, (item.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) == 0 else {
                    throw CustodyRecordError.fenced
                }
            }
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
    }
    private static func holds(_ observation: SignedInstallationFixtureJoinController.HoldObservation) -> [Any] {
        func row(_ value: SignedInstallationFixtureJoinController.Hold) -> [Any] {
            [value.entered.map { $0 as Any } ?? NSNull(), value.returned.map { $0 as Any } ?? NSNull(),
             value.result.map { $0.rawValue as Any } ?? NSNull(), value.explicitRelease.map { $0 as Any } ?? NSNull()]
        }
        return [row(observation.adapter), row(observation.invocation), observation.emergency ? 1 : 0]
    }
    private static func requireH(_ observation: SignedInstallationFixtureJoinController.HoldObservation, released: Bool) throws {
        for hold in [observation.adapter, observation.invocation] {
            guard let entry = hold.entered, let returned = hold.returned,
                  entry < observation.H, returned >= observation.H, returned < observation.C,
                  hold.result == .timedOut, observation.emergency, !observation.traceOverflow else { throw CustodyRecordError.fenced }
            if released {
                guard let release = hold.explicitRelease, release >= returned, release < observation.C else { throw CustodyRecordError.fenced }
            } else { guard hold.explicitRelease == nil else { throw CustodyRecordError.fenced } }
        }
    }
    private static func requireUncertain(_ value: RetainedCleanupRegistry.SignedJoinSnapshot,
                                         original: RetainedCleanupRegistry.SignedJoinSnapshot,
                                         events: Events) throws {
        try H.check(value.expiryUncertain && value.archiveNeverAttempted
            && value.entry == original.entry && value.record == original.record && value.resource == original.resource
            && value.ticket == original.ticket && value.helper == original.helper
            && value.terminal && value.helperZero && value.statusEOF && value.stdoutEOF && value.stderrEOF && value.traceEOF
            && !value.ledgerClosed && !value.removed && !value.issuance && !value.sealed
            && events.observed == [.beforeRead, .afterRead], "control uncertain proof")
    }
    static func runSubject(_ scenario: SignedInstallationFixtureCase, bootstrap: InstallationBootstrap,
                           context: SignedInstallationFixtureContext, service: SignedInstallationFixtureService,
                           custody: InstallationReadinessFixtureCustody) throws -> Never {
        guard scenario.isStartAdapterJoinControl, case let .signedFixture(profile) = context.profile else { throw CustodyRecordError.fenced }
        let request = try profile.joinFixtureRequest()
        let registry = try bootstrap.testingSignedJoinRegistry(context: context, custody: custody)
        let owner = SignedInstallationFixtureJoinControlOwner(bootstrap: bootstrap, registry: registry,
            service: service, context: context, custody: custody)
        custody.retainService(owner)
        defer { owner.releaseOnUnwind() }
        try bootstrap.testingConfigureStarts(checkpoint: { [weak owner] operation, point in
            guard let owner else { throw CustodyRecordError.fenced }
            try owner.checkpoint(operation, point) })
        try bootstrap.reserve(deadline: context.deadline)
        try bootstrap.prepareExclusive()
        try bootstrap.transferToStagedAdmission()
        try bootstrap.continueStagedJournal()
        try bootstrap.openStagedReadiness()
        let controlPath = context.paths.state.path + "/custody/" + InstallationControlRecord.filename
        let control = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: controlPath)), profile: context.profile)
        let transactionDigest = try control.bindingDigest()
        let controller = try SignedInstallationFixtureJoinController(context: context, custody: custody,
            scenario: scenario, control: control)
        owner.set(controller)
        try service.armJoinFixture(controller)
        try H.refuses { try service.armJoinFixture(controller) }
        let events = Events()
        registry.testingObserveExpiredCleanup { events.append($0) }
        var invocation: InstallationFixtureWork?, handle: RetainedCleanupRegistry.Handle?
        var original: RetainedCleanupRegistry.SignedJoinSnapshot?, expired: RetainedCleanupRegistry.SignedJoinSnapshot?
        var durable: Durable?, cap: UInt64?
        var certificate: Certificate?, timeout: HSubjectFailure?
        var product = 0, disposal = 0, reached: UInt64 = 0
        var invocationResult = 0, bodyResult = 0, ledgerMask = 0
        // Only exerciseCut constructs the sentinel, after positive prerequisites.
        func exerciseCut() throws {
            if scenario == .startAdapterJoinFaultBeforeBind {
                let state = owner.selectedState(), quiet = try registry.testingSignedJoinQuiescence()
                try H.check(controller.binding == nil && state.invocation == nil && state.handle == nil && state.binding == nil
                    && bootstrap.testingStartHandle(kickstart: false) == nil && bootstrap.testingStartBudget(kickstart: false) == nil
                    && controller.trace.isEmpty && !controller.invocationSubmitted
                    && bootstrap.bootstrapStartObservation() == .notAttempted
                    && quiet.empty && quiet.preceding > 0 && quiet.precedingRetired && quiet.publicationInactive,
                    "before-bind prerequisites")
                let value = Certificate(scenario, context: context, custody: custody, controller: controller,
                    request: request, transactionDigest: transactionDigest, owner: owner, snapshot: nil)
                certificate = value; throw InjectedAssertion(certificate: value)
            }
            let work = custody.startWork { [owner] in try owner.bootstrap.bootstrapCandidate() }
            invocation = work; owner.set(work)
            try wait(controller.ceiling) { controller.invocationSubmitted && controller.finalAcknowledgmentHeld }
            guard let selected = bootstrap.testingStartHandle(kickstart: false), let bound = controller.binding,
                  let budget = bootstrap.testingStartBudget(kickstart: false), bound.request.budget == budget else { throw CustodyRecordError.fenced }
            handle = selected
            try wait(controller.ceiling) {
                let value = try registry.testingSignedJoinSnapshot(selected)
                return value.terminal && value.statusEOF && value.helperZero
            }
            let value = try registry.testingSignedJoinSnapshot(selected)
            guard let effective = value.effectiveReceipt, let operation = value.operation else { throw CustodyRecordError.fenced }
            let limit = min(effective, operation); cap = limit; original = value
            try H.check(value.request == bound.request && value.archiveNeverAttempted && !value.stdoutEOF && !value.stderrEOF
                && !value.issuance && !value.sealed && value.entry != nil && value.ticket != nil && value.resource != nil && value.helper != nil
                && operation == controller.operationDeadline && value.originalReceipt == budget.receipt
                && bound.wireDeadline == min(request.deadline, budget.work) && RuntimeSuiteGuardian.now < limit
                && events.observed.isEmpty && controller.trace.isEmpty, "control held original boundary")
            try InstallationOwnershipFixtures.excluded(context.paths.state)
            let bytes = try Durable(context: context, request: bound.request); durable = bytes
            try H.check(!bytes.archive && !bytes.caller, "control no prior archive")
            if scenario != .startAdapterJoinFaultAfterAck {
                try wait(controller.ceiling) { RuntimeSuiteGuardian.now >= limit }
                registry.testingRevisitFinalization(selected)
                let expiry = try registry.testingSignedJoinSnapshot(selected); expired = expiry
                try H.check(expiry.expiryAwaiting && expiry.archiveNeverAttempted && expiry.entry == value.entry
                    && expiry.record == value.record && expiry.ticket == value.ticket && expiry.resource == value.resource
                    && expiry.helper == value.helper && expiry.scope?.pending == true && expiry.scope?.liveRequest == true
                    && expiry.scope?.retirements == 0 && !expiry.issuance && !expiry.sealed
                    && events.observed.isEmpty && controller.trace.isEmpty && !expiry.stdoutEOF && !expiry.stderrEOF,
                    "control original expiry witness")
                if scenario == .startAdapterJoinFaultAfterRefusal {
                    registry.testingReleaseDeferredRead(selected)
                    try wait(controller.ceiling) { try registry.testingSignedJoinSnapshot(selected).expiryUncertain }
                    let measured = try registry.testingSignedJoinSnapshot(selected)
                    try requireUncertain(measured, original: value, events: events)
                    let joins = controller.trace.filter { $0.purpose == .registryRetire }
                    try H.check(controller.finalAcknowledgmentHeld && !measured.physicallyRetired
                        && joins.count == 1 && joins[0].deadline == limit && joins[0].entered >= limit && joins[0].succeeded == false,
                        "control actual refusal before injection")
                }
            }
            if scenario == .startAdapterJoinHExpiry {
                let entry = controller.holdObservation()
                try H.check(entry.adapter.entered != nil && entry.invocation.entered != nil
                    && entry.adapter.returned == nil && entry.invocation.returned == nil
                    && entry.adapter.explicitRelease == nil && entry.invocation.explicitRelease == nil && !entry.emergency,
                    "H entered without release")
                // Observation uses unchanged C, never H or a replacement work cap.
                try wait(context.deadline) {
                    let observed = controller.holdObservation()
                    return observed.adapter.returned != nil && observed.invocation.returned != nil
                }
                let observed = controller.holdObservation(); try requireH(observed, released: false)
                var adapterFailure: SignedJoinHoldTimeout?, invocationFailure: SignedJoinHoldTimeout?
                do { try service.joinFixtureValue(controller, deadline: context.deadline); throw CustodyRecordError.fenced }
                catch let error as SignedJoinHoldTimeout { try controller.requireTimeout(error, latch: .adapter); adapterFailure = error }
                do { try work.value(deadline: context.deadline); throw CustodyRecordError.fenced }
                catch let error as SignedJoinHoldTimeout { try controller.requireTimeout(error, latch: .invocation); invocationFailure = error }
                guard let adapterFailure, let invocationFailure else { throw CustodyRecordError.fenced }
                timeout = HSubjectFailure(adapter: adapterFailure, invocation: invocationFailure)
                invocationResult = 3; bodyResult = 3; reached = RuntimeSuiteGuardian.now
                return
            }
            let current = try registry.testingSignedJoinSnapshot(selected)
            let valueCertificate = Certificate(scenario, context: context, custody: custody, controller: controller,
                request: request, transactionDigest: transactionDigest, owner: owner, snapshot: current)
            certificate = valueCertificate; throw InjectedAssertion(certificate: valueCertificate)
        }
        do { try exerciseCut(); guard timeout != nil else { throw CustodyRecordError.fenced } }
        catch let injection as InjectedAssertion {
            guard let certificate, injection.certificate === certificate else { throw CustodyRecordError.fenced }
            try certificate.consume(scenario, context: context, custody: custody, controller: controller,
                request: request, transactionDigest: transactionDigest, owner: owner)
            reached = certificate.reached
        }
        // No generic catch converts an arbitrary setup/body/closure error into an expected cut.
        owner.releaseOnUnwind()
        if let handle, let invocation, let original, let bound = controller.binding, let cap, let durable {
            if scenario == .startAdapterJoinFaultAfterAck {
                let deadline = MonotonicDeadline(uptimeNanoseconds: cap)
                try service.joinFixtureValue(controller, deadline: deadline); bodyResult = 1
                try wait(deadline) { handle.snapshot().phase == .finished }
                try invocation.value(deadline: deadline); invocationResult = 1
                let measured = try registry.testingSignedJoinSnapshot(handle)
                let quiet = try registry.testingSignedJoinQuiescence(handle)
                let joins = controller.trace.filter { $0.purpose == .registryRetire }
                try H.check(RuntimeSuiteGuardian.now < cap && measured.entry == nil && measured.removed && measured.ledgerClosed
                    && measured.issuance && measured.sealed && quiet.selectedDelivered && quiet.publicationInactive
                    && bootstrap.bootstrapStartObservation() == .complete && events.observed.isEmpty
                    && joins.count == 1 && joins[0].deadline == cap && joins[0].entered < cap && joins[0].succeeded == true
                    && !controller.emergencyReleased, "after-ack must be real ordinary success")
                product = 1; ledgerMask = 31
            } else {
                // Freeze the measured union BEFORE service teardown can join work.
                try wait(context.deadline) {
                    let value = try registry.testingSignedJoinSnapshot(handle)
                    return value.entry == nil || value.expiryUncertain
                }
                let measured = try registry.testingSignedJoinSnapshot(handle)
                let joins = controller.trace.filter { $0.purpose == .registryRetire }
                try H.check(joins.count == 1 && joins[0].deadline == cap && joins[0].entered >= cap,
                    "control exactly one original-cap registry join")
                let uncertain = measured.expiryUncertain
                if uncertain {
                    guard scenario == .startAdapterJoinFaultBeforeJoin || scenario == .startAdapterJoinFaultAfterRefusal else {
                        throw CustodyRecordError.fenced
                    }
                    try requireUncertain(measured, original: original, events: events)
                    try H.check(joins[0].succeeded == false, "control uncertain real failed join")
                } else {
                    guard scenario != .startAdapterJoinFaultAfterRefusal else { throw CustodyRecordError.fenced }
                    try H.check(joins[0].succeeded == true && events.observed == [.beforeRead, .afterRead, .checkedClose, .removed]
                        && registry.testingCleanupOnlyRemoved(handle) && measured.ledgerClosed && measured.removed
                        && !measured.issuance && !measured.sealed, "control cleanup-only real removal")
                }
                try invocation.join(deadline: context.deadline)
                if scenario != .startAdapterJoinHExpiry {
                    do {
                        try invocation.value(deadline: context.deadline)
                        throw CustodyRecordError.injectedFailure
                    } catch CustodyRecordError.fenced {
                        guard bootstrap.stagedReadinessClosureObservation() == .joined else { throw CustodyRecordError.fenced }
                        invocationResult = 2
                    }
                }
                try failed(bootstrap, handle: handle, context: context)
                let aliases = bootstrap.testingStartRetention(kickstart: false)
                let sticky = try registry.testingSignedJoinSnapshot(handle)
                try H.check(sticky.scope == expired?.scope && !sticky.issuance && !sticky.sealed
                    && (try Durable(context: context, request: bound.request)) == durable, "control sticky expiry state")
                // Both H bodies are already joined and remain failed. Non-H work must actually succeed.
                try service.closeFixtureService(deadline: context.deadline)
                if scenario != .startAdapterJoinHExpiry { try service.joinFixtureValue(controller, deadline: context.deadline); bodyResult = 1 }
                registry.testingRevisitFinalization(handle)
                if uncertain {
                    let later = try registry.testingSignedJoinSnapshot(handle)
                    try requireUncertain(later, original: original, events: events)
                    try H.check(later.physicallyRetired && later.scope == sticky.scope
                        && later.originalReceipt == original.originalReceipt && later.effectiveReceipt == sticky.effectiveReceipt
                        && later.operation == original.operation && controller.trace.filter { $0.purpose == .registryRetire }.count == 1,
                        "control physical close cannot heal negative ledger")
                    try failed(bootstrap, handle: handle, context: context)
                }
                try H.check(bootstrap.testingStartRetention(kickstart: false) == aliases
                    && (try Durable(context: context, request: bound.request)) == durable,
                    "control permanent negative aliases and durable bytes")
                if uncertain {
                    // Exactly the two reviewed measured-uncertain routes, never H or in-budget.
                    try registry.testingDisposeSignedJoin(handle, controller: controller, context: context,
                        custody: custody, invocation: invocation, deadline: context.deadline)
                    disposal = 1; product = 3; ledgerMask = 0
                } else { product = scenario == .startAdapterJoinHExpiry ? 4 : 2; ledgerMask = 3 }
            }
        } else { guard scenario == .startAdapterJoinFaultBeforeBind else { throw CustodyRecordError.fenced } }
        if scenario == .startAdapterJoinHExpiry { try requireH(controller.holdObservation(), released: true) }
        else { try H.check(!controller.emergencyReleased, "unexpected hold timeout") }
        try owner.closeFixtureService(deadline: context.deadline)
        let quiet = try registry.testingSignedJoinQuiescence(handle)
        try H.check(quiet.empty && quiet.preceding > 0 && quiet.precedingRetired && quiet.publicationInactive
            && registry.testingOriginalHelpersReaped, "control exact accounting and original retirement")
        try custody.finish(deadline: context.deadline)
        RuntimeFixtureSession.didFinishInstallationRoot(custody)
        let finish = RuntimeSuiteGuardian.now
        let finalHolds = controller.holdObservation()
        if scenario == .startAdapterJoinHExpiry { try requireH(finalHolds, released: true) }
        else { try H.check(!finalHolds.emergency, "sticky unexpected failure") }
        var deadlines: [Any] = [request.deadline, controller.ceiling.absoluteUptimeNanoseconds]
        var command: Any = NSNull(), evidence: [Any] = []
        if let bound = controller.binding, let original, let cap {
            let budget = bound.request.budget
            deadlines += [budget.work, budget.term, budget.kill, budget.receipt,
                          original.effectiveReceipt!, original.operation!, cap]
            command = [bound.digest, 1023] as [Any]
            if product != 1, let durable {
                let after = try Durable(context: context, request: bound.request)
                guard after == durable else { throw CustodyRecordError.fenced }
                evidence = [CustodyRecordBinding.digest(durable.control), CustodyRecordBinding.digest(durable.catalog),
                            CustodyRecordBinding.digest(durable.journal)]
            }
        } else { deadlines += Array(repeating: NSNull(), count: 7) }
        let cut: Int
        switch scenario {
        case .startAdapterJoinFaultBeforeBind: cut = 0
        case .startAdapterJoinFaultAfterAck: cut = 1
        case .startAdapterJoinFaultBeforeJoin: cut = 2
        case .startAdapterJoinFaultAfterRefusal: cut = 3
        case .startAdapterJoinHExpiry: cut = 4
        default: throw CustodyRecordError.fenced
        }
        let trace: [[Any]] = try controller.trace.map { join in
            guard let succeeded = join.succeeded else { throw CustodyRecordError.fenced }
            return [join.purpose == .registryRetire ? 0 : 1, join.deadline, join.entered, succeeded ? 1 : 0]
        }
        guard trace.count <= 32, finish < request.deadline else { throw CustodyRecordError.fenced }
        // Fixed positions/masks are specified and validated by the read-only evaluator.
        let report: [String: Any] = ["schema": "shadow-sync-signed-join-control/v1", "case": scenario.rawValue,
            "nonce": request.nonce, "source_sha256": request.source, "executable_sha256": request.executable,
            "app_sha256": request.app, "request_sha256": CustodyRecordBinding.digest(request.bytes),
            "transaction_digest": transactionDigest, "cut": cut, "reached_ns": reached, "deadlines": deadlines,
            "command": command, "holds": holds(finalHolds), "joins": trace,
            "product": [product, invocationResult, bodyResult, ledgerMask], "fixture": [0, cut],
            "cleanup": [finish, 127, quiet.entries, quiet.order, quiet.reservations, quiet.outputEntries, quiet.output, disposal],
            "evidence": [evidence, product == 2 || product == 4 ? 15 : (product == 3 ? 3 : 0), 31]]
        try emit(report, deadline: context.deadline)
        if let timeout { throw timeout }
        guard let certificate else { throw CustodyRecordError.fenced }
        throw InjectedAssertion(certificate: certificate)
    }
}
#endif
