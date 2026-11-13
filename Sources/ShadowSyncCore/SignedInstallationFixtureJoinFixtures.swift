#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Foundation

/// One original owner, one exact command, two finite scheduling holds. This is
/// compiled fixture control, never wire authority or a command retirement token.
final class SignedInstallationFixtureJoinController: @unchecked Sendable {
    enum JoinPurpose: Equatable { case registryRetire, fixtureTeardown }
    struct Join: Equatable {
        let index: Int, deadline: UInt64, entered: UInt64
        let purpose: JoinPurpose
        var succeeded: Bool?
    }
    struct Bound {
        let channel: ObjectIdentifier
        let request: UnvalidatedCustodyRequest
        let digest: String
        let wireDeadline: UInt64
    }
    let ceiling: MonotonicDeadline
    let operationDeadline: UInt64
    private let contextIdentity: ObjectIdentifier, rootIdentity: ObjectIdentifier
    private let request: SignedInstallationFixtureContext.Request
    private let profile: InstallationValidationProfile
    private let transaction: String, bindingDigest: String
    private let lock = NSLock()
    private let adapterRelease = DispatchSemaphore(value: 0), invocationRelease = DispatchSemaphore(value: 0)
    private var bound: Bound?
    private var ack = false, submitted = false, adapterReleased = false, invocationReleased = false
    private var emergency = false, teardown = false
    private var joins: [Join] = []
    private var traceOverflow = false
    private let timeoutControl: Bool
    enum HoldResult: Int { case signalled = 1, timedOut = 2 }
    struct Hold: Equatable {
        var entered: UInt64?, returned: UInt64?, result: HoldResult?, explicitRelease: UInt64?
    }
    struct HoldObservation: Equatable {
        let adapter: Hold, invocation: Hold
        let H: UInt64, C: UInt64
        let emergency: Bool, traceOverflow: Bool
    }
    private var adapterObservation = Hold(), invocationObservation = Hold()
    func holdObservation() -> HoldObservation {
        lock.lock(); defer { lock.unlock() }
        return HoldObservation(adapter: adapterObservation, invocation: invocationObservation,
            H: ceiling.absoluteUptimeNanoseconds, C: operationDeadline, emergency: emergency, traceOverflow: traceOverflow)
    }
    func requireTimeout(_ error: SignedJoinHoldTimeout, latch: SignedJoinHoldTimeout.Latch) throws {
        guard timeoutControl, error.latch == latch, error.bindingDigest == bindingDigest,
              error.H == ceiling.absoluteUptimeNanoseconds else { throw CustodyRecordError.fenced }
    }

    init(context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody,
         scenario: SignedInstallationFixtureCase, control: InstallationControlRecord) throws {
        guard (scenario.isStartAdapterJoin || scenario.isStartAdapterJoinControl), case let .signedFixture(profile) = context.profile,
              let transaction = control.transaction,
              custody.root == URL(fileURLWithPath: context.paths.home).deletingLastPathComponent().path else {
            throw CustodyRecordError.fenced
        }
        let request = try profile.joinFixtureRequest()
        guard request.caseID == scenario.rawValue, request.root == custody.root,
              request.deadline == context.deadline.absoluteUptimeNanoseconds,
              request.deadline > RuntimeSuiteGuardian.now + 23_000_000_000 else { throw CustodyRecordError.busy }
        timeoutControl = scenario == .startAdapterJoinHExpiry
        self.request = request; self.profile = context.profile
        contextIdentity = ObjectIdentifier(context); rootIdentity = ObjectIdentifier(custody)
        self.transaction = transaction.id; bindingDigest = try control.bindingDigest()
        operationDeadline = context.deadline.absoluteUptimeNanoseconds
        // H is fixed once, inside C, with time reserved for original-owner
        // teardown. It is never supplied to production resource retirement.
        ceiling = .init(uptimeNanoseconds: request.deadline - 3_000_000_000)
    }
    func requireOwner(context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody) throws {
        try requireOwnerIdentities(context: ObjectIdentifier(context), custody: ObjectIdentifier(custody))
        guard context.profile == profile, custody.root == request.root else { throw CustodyRecordError.fenced }
    }
    private func requireOwnerIdentities(context: ObjectIdentifier, custody: ObjectIdentifier) throws {
        guard context == contextIdentity, custody == rootIdentity else { throw CustodyRecordError.fenced }
    }
    private func validateMatch(context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody,
                               signedRequest: SignedInstallationFixtureContext.Request,
                               command: UnvalidatedCustodyRequest, digest: String,
                               binding: InstallationCommandBinding) throws {
        try requireOwner(context: context, custody: custody)
        let account = try context.destinationAccount
        guard signedRequest.bytes == request.bytes, signedRequest.root == request.root,
              command.authority == .installationStagedStart, command.kind == .launchctlMutation,
              command.arguments == LifecycleLaunchCommand(operation: .bootstrap, account: account).arguments,
              binding.stagedMode == .installationStagedStart, binding.validationProfile == profile,
              binding.control.transaction?.id == transaction, try binding.control.bindingDigest() == bindingDigest,
              digest == CustodyRecordBinding.digest(try command.encode()),
              command.budget.receipt < ceiling.absoluteUptimeNanoseconds,
              command.budget.work <= operationDeadline else { throw CustodyRecordError.fenced }
    }
    func bind(_ channel: SignedInstallationFixtureAdapterChannel, context: SignedInstallationFixtureContext,
              custody: InstallationReadinessFixtureCustody, signedRequest: SignedInstallationFixtureContext.Request,
              request: UnvalidatedCustodyRequest, digest: String, binding: InstallationCommandBinding) throws {
        try validateMatch(context: context, custody: custody, signedRequest: signedRequest,
            command: request, digest: digest, binding: binding)
        lock.lock(); defer { lock.unlock() }
        guard bound == nil, !teardown, !ceiling.hasExpired else { throw CustodyRecordError.fenced }
        bound = Bound(channel: ObjectIdentifier(channel), request: request, digest: digest,
            wireDeadline: min(signedRequest.deadline, request.budget.work))
    }
    /// Actual rejection calls on the same bound controller. No foreign object
    /// is installed, no arm is reset, and no extra command can be submitted.
    func requireRejectedMatches(_ channel: SignedInstallationFixtureAdapterChannel,
                                context: SignedInstallationFixtureContext, custody: InstallationReadinessFixtureCustody,
                                signedRequest: SignedInstallationFixtureContext.Request,
                                command: UnvalidatedCustodyRequest, digest: String,
                                binding: InstallationCommandBinding) throws {
        typealias H = InstallationStorageFixtures
        // Exercise both original object-identity checks without constructing a
        // replacement owner or lending a foreign resource to the command.
        try H.refuses { try requireOwnerIdentities(context: ObjectIdentifier(custody), custody: ObjectIdentifier(custody)) }
        try H.refuses { try requireOwnerIdentities(context: ObjectIdentifier(context), custody: ObjectIdentifier(context)) }
        try H.refuses { try bind(channel, context: context, custody: custody, signedRequest: signedRequest,
            request: command, digest: digest, binding: binding) }
        let foreignProfile = InstallationCommandBinding(control: binding.control, controlNode: binding.controlNode,
            receiptNodes: binding.receiptNodes, committedStopDeadline: binding.committedStopDeadline, validationProfile: .production)
        try H.refuses { try validateMatch(context: context, custody: custody, signedRequest: signedRequest,
            command: command, digest: digest, binding: foreignProfile) }
        let foreignRequest = SignedInstallationFixtureContext.Request(root: signedRequest.root, nonce: signedRequest.nonce,
            source: signedRequest.source, executable: signedRequest.executable, app: signedRequest.app,
            bundle: signedRequest.bundle, release: signedRequest.release, appCDHash: signedRequest.appCDHash,
            helperCDHash: signedRequest.helperCDHash, deadline: signedRequest.deadline, caseID: signedRequest.caseID,
            bytes: signedRequest.bytes + Data([0]))
        try H.refuses { try validateMatch(context: context, custody: custody, signedRequest: foreignRequest,
            command: command, digest: digest, binding: binding) }
        let account = try context.destinationAccount
        for (authority, kind, arguments) in [
            (CustodyAuthorityMode.lifecycleMutation, CustodyCommandKind.launchctlMutation, command.arguments),
            (.installationStagedStart, .launchctlRead, LifecycleLaunchCommand(operation: .kickstart, account: account).printArguments),
            (.installationStagedStart, .launchctlMutation, LifecycleLaunchCommand(operation: .kickstart, account: account).arguments),
        ] {
            let wrong = UnvalidatedCustodyRequest(binding: command.binding, kind: kind, authority: authority,
                arguments: arguments, environment: command.environment, budget: command.budget,
                stdoutLimit: command.stdoutLimit, stderrLimit: command.stderrLimit, inputSHA256: command.inputSHA256,
                resourcesSHA256: command.resourcesSHA256, descriptors: command.descriptors)
            try H.refuses { try validateMatch(context: context, custody: custody, signedRequest: signedRequest,
                command: wrong, digest: digest, binding: binding) }
        }
        try H.check(matches(channel: channel, digest: digest) && matches(request: command),
            "signed adapter rejected matches altered original binding")
    }
    func matches(channel: SignedInstallationFixtureAdapterChannel, digest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bound?.channel == ObjectIdentifier(channel) && bound?.digest == digest
    }
    func matches(request: UnvalidatedCustodyRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }; return bound?.request == request
    }
    var binding: Bound? { lock.lock(); defer { lock.unlock() }; return bound }
    var finalAcknowledgmentHeld: Bool { lock.lock(); defer { lock.unlock() }; return ack && !adapterReleased }
    var invocationSubmitted: Bool { lock.lock(); defer { lock.unlock() }; return submitted }
    var emergencyReleased: Bool { lock.lock(); defer { lock.unlock() }; return emergency }
    var trace: [Join] { lock.lock(); defer { lock.unlock() }; return joins }
    func holdAfterFinalAcknowledgment(channel: SignedInstallationFixtureAdapterChannel) throws {
        lock.lock()
        guard bound?.channel == ObjectIdentifier(channel), !ack else { lock.unlock(); throw CustodyRecordError.fenced }
        ack = true; let released = adapterReleased
        if !released { adapterObservation.entered = RuntimeSuiteGuardian.now }
        lock.unlock()
        if !released {
            let result = adapterRelease.wait(timeout: .init(uptimeNanoseconds: ceiling.absoluteUptimeNanoseconds))
            lock.lock()
            adapterObservation.returned = RuntimeSuiteGuardian.now
            adapterObservation.result = result == .success ? .signalled : .timedOut
            if result != .success { emergency = true; adapterReleased = true }
            lock.unlock()
            if result != .success {
                if timeoutControl { throw SignedJoinHoldTimeout(latch: .adapter, bindingDigest: bindingDigest, H: ceiling.absoluteUptimeNanoseconds) }
                throw CustodyRecordError.busy
            }
        }
    }
    func holdSubmitted() throws {
        lock.lock()
        guard bound != nil, !submitted else { lock.unlock(); throw CustodyRecordError.fenced }
        submitted = true; let released = invocationReleased
        if !released { invocationObservation.entered = RuntimeSuiteGuardian.now }
        lock.unlock()
        if !released {
            let result = invocationRelease.wait(timeout: .init(uptimeNanoseconds: ceiling.absoluteUptimeNanoseconds))
            lock.lock()
            invocationObservation.returned = RuntimeSuiteGuardian.now
            invocationObservation.result = result == .success ? .signalled : .timedOut
            if result != .success { emergency = true; invocationReleased = true }
            lock.unlock()
            if result != .success {
                if timeoutControl { throw SignedJoinHoldTimeout(latch: .invocation, bindingDigest: bindingDigest, H: ceiling.absoluteUptimeNanoseconds) }
                throw CustodyRecordError.busy
            }
        }
    }
    func releaseAdapter() {
        lock.lock(); let signal = !adapterReleased; adapterReleased = true
        if adapterObservation.explicitRelease == nil { adapterObservation.explicitRelease = RuntimeSuiteGuardian.now }
        lock.unlock()
        if signal { adapterRelease.signal() }
    }
    func releaseInvocation() {
        lock.lock(); let signal = !invocationReleased; invocationReleased = true
        if invocationObservation.explicitRelease == nil { invocationObservation.explicitRelease = RuntimeSuiteGuardian.now }
        lock.unlock()
        if signal { invocationRelease.signal() }
    }
    func releaseForTeardown() {
        lock.lock(); teardown = true; lock.unlock()
        releaseAdapter(); releaseInvocation()
    }
    func beginJoin(channel: SignedInstallationFixtureAdapterChannel, deadline: MonotonicDeadline, purpose: JoinPurpose) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard bound?.channel == ObjectIdentifier(channel) else { return nil }
        // A repeated failing root teardown cannot grow an unbounded trace.
        guard joins.count < 32 else { emergency = true; traceOverflow = true; return nil }
        let index = joins.count
        joins.append(Join(index: index, deadline: deadline.absoluteUptimeNanoseconds,
            entered: RuntimeSuiteGuardian.now, purpose: purpose, succeeded: nil))
        return index
    }
    func endJoin(_ index: Int?, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let index, joins.indices.contains(index), joins[index].succeeded == nil else { return }
        joins[index].succeeded = succeeded
    }
    func requireTeardownJoin() throws {
        lock.lock(); defer { lock.unlock() }
        guard teardown, adapterReleased, invocationReleased,
              joins.contains(where: { $0.purpose == .fixtureTeardown && $0.succeeded == true }),
              joins.allSatisfy({ $0.succeeded != nil }) else { throw CustodyRecordError.busy }
    }
}

/// Root-retained before any latch or invocation exists. Every throw keeps the
/// actual Bootstrap, registry, service and work owners reachable for root retry.
private final class SignedInstallationFixtureJoinOwner: SignedInstallationFixtureServiceCustody, @unchecked Sendable {
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
        if failures.isEmpty, registry.hasRetainedWork, let controller, let invocation, let handle {
            do {
                try registry.testingDisposeSignedJoin(handle, controller: controller, context: context,
                    custody: custody, invocation: invocation, deadline: deadline)
            } catch { failures.append(error) }
        }
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

enum SignedInstallationFixtureJoinFixtures {
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
    static func run(_ scenario: SignedInstallationFixtureCase, bootstrap: InstallationBootstrap,
                    context: SignedInstallationFixtureContext, service: SignedInstallationFixtureService,
                    custody: InstallationReadinessFixtureCustody) throws {
        guard scenario.isStartAdapterJoin else { throw CustodyRecordError.fenced }
        let registry = try bootstrap.testingSignedJoinRegistry(context: context, custody: custody)
        let owner = SignedInstallationFixtureJoinOwner(bootstrap: bootstrap, registry: registry,
            service: service, context: context, custody: custody)
        custody.retainService(owner)
        // Root ownership precedes every fallible edge. A throw releases holds
        // immediately; root.finish subsequently retries genuine owned drainage.
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
        let controller = try SignedInstallationFixtureJoinController(context: context, custody: custody,
            scenario: scenario, control: control)
        owner.set(controller)
        try service.armJoinFixture(controller)
        // Duplicate arming is an actual rejected call, not a marker assertion.
        try H.refuses { try service.armJoinFixture(controller) }
        let events = Events()
        registry.testingObserveExpiredCleanup { events.append($0) }
        let invocation = custody.startWork { [owner] in try owner.bootstrap.bootstrapCandidate() }
        owner.set(invocation)
        try wait(controller.ceiling) { controller.invocationSubmitted && controller.finalAcknowledgmentHeld }
        guard let handle = bootstrap.testingStartHandle(kickstart: false), let bound = controller.binding,
              let originalBudget = bootstrap.testingStartBudget(kickstart: false), bound.request.budget == originalBudget else {
            throw CustodyRecordError.fenced
        }
        try wait(controller.ceiling) {
            let current = try registry.testingSignedJoinSnapshot(handle)
            return current.terminal && current.statusEOF && current.helperZero
        }
        let original = try registry.testingSignedJoinSnapshot(handle)
        guard let effective = original.effectiveReceipt, let operation = original.operation else { throw CustodyRecordError.fenced }
        let cap = min(effective, operation)
        try H.check(original.request == bound.request && original.archiveNeverAttempted
            && !original.stdoutEOF && !original.stderrEOF && !original.issuance && !original.sealed
            && original.entry != nil && original.ticket != nil && original.resource != nil && original.helper != nil
            && operation == controller.operationDeadline && original.originalReceipt == originalBudget.receipt
            && bound.wireDeadline == min(context.deadline.absoluteUptimeNanoseconds, originalBudget.work)
            && RuntimeSuiteGuardian.now < cap && events.observed.isEmpty && controller.trace.isEmpty,
            "signed adapter did not reach original pre-archive held-work boundary")
        try InstallationOwnershipFixtures.excluded(context.paths.state)
        let durable = try Durable(context: context, request: bound.request)
        try H.check(!durable.archive && !durable.caller, "signed adapter fixture started with archival evidence")
        if scenario != .startAdapterJoinExpiredPending {
            controller.releaseAdapter()
            // Real group completion and actual result, before the unchanged cap.
            try service.joinFixtureValue(controller, deadline: .init(uptimeNanoseconds: cap))
            try H.check(RuntimeSuiteGuardian.now < cap, "signed adapter positive missed original cap")
        }
        if scenario == .startAdapterJoinInBudget {
            registry.testingReleaseDeferredRead(handle)
            try wait(.init(uptimeNanoseconds: cap)) { handle.snapshot().phase == .finished }
            controller.releaseInvocation()
            try invocation.value(deadline: .init(uptimeNanoseconds: cap))
            let settled = try registry.testingSignedJoinSnapshot(handle)
            let joins = controller.trace.filter { $0.purpose == .registryRetire }
            try H.check(settled.entry == nil && settled.removed && settled.ledgerClosed && settled.issuance && settled.sealed
                && bootstrap.bootstrapStartObservation() == .complete && events.observed.isEmpty
                && joins.count == 1 && joins[0].deadline == cap && joins[0].succeeded == true
                && joins[0].entered < cap && !controller.emergencyReleased,
                "signed adapter command-retirement positive was not genuine in-budget issuance")
            // This is command retirement only; no kickstart/readiness/finish claim.
        } else {
            try wait(controller.ceiling) { RuntimeSuiteGuardian.now >= cap }
            registry.testingRevisitFinalization(handle)
            let expired = try registry.testingSignedJoinSnapshot(handle)
            try H.check(expired.expiryAwaiting && expired.archiveNeverAttempted && expired.entry == original.entry
                && expired.record == original.record && expired.ticket == original.ticket && expired.resource == original.resource
                && expired.helper == original.helper && expired.scope?.pending == true && expired.scope?.liveRequest == true
                && expired.scope?.retirements == 0 && !expired.issuance && !expired.sealed && events.observed.isEmpty,
                "signed adapter did not record original unattempted-archive expiry")
            registry.testingReleaseDeferredRead(handle)
            try wait(controller.ceiling) {
                let state = try registry.testingSignedJoinSnapshot(handle)
                return scenario == .startAdapterJoinExpiredComplete ? state.entry == nil : state.expiryUncertain
            }
            let measured = try registry.testingSignedJoinSnapshot(handle)
            let joins = controller.trace.filter { $0.purpose == .registryRetire }
            try H.check(joins.count == 1 && joins[0].deadline == cap && joins[0].entered >= cap
                && joins[0].succeeded == (scenario == .startAdapterJoinExpiredComplete),
                "signed adapter did not perform one real expired-cap checked join")
            if scenario == .startAdapterJoinExpiredComplete {
                try H.check(events.observed == [.beforeRead, .afterRead, .checkedClose, .removed]
                    && registry.testingCleanupOnlyRemoved(handle) && !measured.issuance && !measured.sealed,
                    "signed adapter completed work did not permit cleanup-only exact removal")
            } else {
                try H.check(controller.finalAcknowledgmentHeld && measured.expiryUncertain
                    && measured.entry == original.entry && measured.record == original.record
                    && measured.resource == original.resource && measured.ticket == original.ticket && measured.helper == original.helper
                    && measured.terminal && measured.helperZero && measured.statusEOF && measured.stdoutEOF && measured.stderrEOF && measured.traceEOF
                    && !measured.physicallyRetired && !measured.ledgerClosed && !measured.removed && !measured.issuance && !measured.sealed
                    && events.observed == [.beforeRead, .afterRead],
                    "signed adapter incomplete real work was incorrectly retired")
            }
            controller.releaseInvocation()
            try invocation.join(deadline: controller.ceiling)
            try H.refuses { try invocation.value(deadline: controller.ceiling) }
            try failed(bootstrap, handle: handle, context: context)
            let aliases = bootstrap.testingStartRetention(kickstart: false)
            let sticky = try registry.testingSignedJoinSnapshot(handle)
            try H.check(sticky.scope == expired.scope && !sticky.issuance && !sticky.sealed
                && (try Durable(context: context, request: bound.request)) == durable,
                "signed adapter expiry changed live request, failure, or durable bytes")
            registry.testingRevisitFinalization(handle)
            if scenario == .startAdapterJoinExpiredPending {
                // Separately labeled original-owner teardown. Physical closure
                // after this point must never repair the measured product ledger.
                controller.releaseForTeardown()
                try service.closeFixtureService(deadline: context.deadline)
                try service.joinFixtureValue(controller, deadline: context.deadline)
                registry.testingRevisitFinalization(handle)
                let later = try registry.testingSignedJoinSnapshot(handle)
                try H.check(later.entry == measured.entry && later.record == measured.record
                    && later.resource == measured.resource && later.ticket == measured.ticket && later.helper == measured.helper
                    && later.expiryUncertain && later.archiveNeverAttempted && later.physicallyRetired
                    && !later.ledgerClosed && !later.removed && !later.issuance && !later.sealed
                    && later.scope == sticky.scope && later.originalReceipt == original.originalReceipt
                    && later.effectiveReceipt == sticky.effectiveReceipt && later.operation == operation
                    && events.observed == [.beforeRead, .afterRead]
                    && controller.trace.filter { $0.purpose == .registryRetire }.count == 1,
                    "later signed owner join healed permanent negative retirement")
                try failed(bootstrap, handle: handle, context: context)
            }
            try H.check(bootstrap.testingStartRetention(kickstart: false) == aliases
                && (try Durable(context: context, request: bound.request)) == durable && !controller.emergencyReleased,
                "signed adapter teardown changed original aliases, bytes, or emergency failure")
        }
        // This is explicit fixture disposal, never the production cleanup
        // success oracle or the existing 750ms/eight-second acceptance branch.
        try owner.closeFixtureService(deadline: context.deadline)
        try H.check(!controller.emergencyReleased && !registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
            "signed adapter fixture did not return genuinely drained ownership")
    }
}
#endif
