import Darwin
import Foundation

/// Three observations only. This state machine cannot publish candidate-ready,
/// commit, start an application, release a lease, or execute stop/recovery.
struct InstallationPrecommitTranscript {
    private let hello: InstallationReadinessMessage
    private var next = 0
    private var previous: String?
    private var transcript = Data()
    init(hello: InstallationReadinessMessage) throws {
        try hello.validate()
        guard hello.event == .hello else { throw CustodyProtocolError.invalidSequence }
        self.hello = hello
    }
    mutating func consume(_ message: InstallationReadinessMessage,
                          sender: InstallationReadinessMessage.Endpoint,
                          deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired, next < 3 else { throw CustodyProtocolError.invalidSequence }
        let event: InstallationReadinessMessage.Event = [.hello, .challenge, .ready][next]
        guard message.event == event, message.event.sender == sender,
              message.transactionID == hello.transactionID, message.boot == hello.boot,
              message.controlRevision == hello.controlRevision,
              message.candidateReleaseDigest == hello.candidateReleaseDigest,
              message.stateBindingDigest == hello.stateBindingDigest,
              message.hostGeneration == hello.hostGeneration,
              message.sessionNonce == hello.sessionNonce,
              message.previousMessageDigest == previous else { throw CustodyProtocolError.invalidSequence }
        let bytes = try message.encode(); transcript.append(bytes); transcript.append(0x0a)
        previous = try message.digest(); next += 1
    }
    func message(_ event: InstallationReadinessMessage.Event) throws -> InstallationReadinessMessage {
        guard next < 3, event == [.hello, .challenge, .ready][next] else { throw CustodyProtocolError.invalidSequence }
        return InstallationReadinessMessage(event: event, transactionID: hello.transactionID,
            boot: hello.boot, controlRevision: hello.controlRevision,
            candidateReleaseDigest: hello.candidateReleaseDigest, stateBindingDigest: hello.stateBindingDigest,
            hostGeneration: hello.hostGeneration, sessionNonce: hello.sessionNonce,
            previousMessageDigest: previous)
    }
    var completedDigest: String? { next == 3 ? CustodyRecordBinding.digest(transcript) : nil }
    static func validateHello(_ hello: InstallationReadinessMessage, control: InstallationControlRecord) throws {
        guard let transaction = control.transaction, let candidate = transaction.candidate,
              control.phase == .active, control.readinessCommit == nil,
              control.step?.action == .kickstartCandidate, control.step?.status == .complete,
              hello.event == .hello, hello.transactionID == transaction.id,
              hello.boot == transaction.boot, hello.controlRevision == control.revision,
              hello.candidateReleaseDigest == candidate.release.releaseContractSHA256,
              hello.stateBindingDigest == (try control.state.digest()) else { throw CustodyProtocolError.invalidSequence }
        try hello.validate()
    }
}

/// Read-only pending-kickstart edge. This carries no host/start capability and
/// cannot produce a command retirement or readiness deadline.
enum InstallationPrecommitWait {
    static func completion(of control: InstallationControlRecord) throws -> (InstallationControlRecord, InstallationStepReceipt.CanonicalObservation) {
        guard control.phase == .active, control.readinessCommit == nil,
              let transaction = control.transaction, transaction.candidate != nil,
              let step = control.step, step.action == .kickstartCandidate,
              step.ordinal == 14, step.status == .intent, control.revision < UInt64.max else { throw CustodyRecordError.fenced }
        let receipt = InstallationStepReceipt(transactionID: transaction.id, ordinal: step.ordinal,
            previousReceiptDigest: control.latestReceiptDigest, action: .kickstartCandidate, status: .complete,
            preimage: transaction.slots, postimage: transaction.slots,
            bindingDigest: try transaction.bindingDigest(state: control.state))
        let observation = try InstallationStepReceipt.CanonicalObservation(validating: receipt, uid: control.state.directory.uid)
        return (InstallationControlRecord(revision: control.revision + 1, phase: .active, state: control.state,
            transaction: transaction, step: try receipt.step(), latestReceiptDigest: observation.digest,
            readinessCommit: nil, recoveryReason: nil), observation)
    }
    static func validateSuccessor(_ observed: InstallationControlRecord, of previous: InstallationControlRecord,
                                  deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        if observed == previous { return }
        guard observed == (try completion(of: previous).0) else { throw CustodyRecordError.fenced }
    }
}

enum InstallationPrecommitTransport {
    static func requireQuiet(_ socket: OwnedFileDescriptor) throws {
        let (n, code) = try socket.withOriginalSocket { fd in
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            return (count, count < 0 ? errno : 0)
        }
        guard n < 0 && (code == EAGAIN || code == EWOULDBLOCK) else { throw CustodyProtocolError.invalidSequence }
    }

    /// Preserve the reader across the session, but never advance the host from
    /// a challenge that arrived with already-buffered out-of-order input.
    static func readChallenge(reader: inout HostControlIO.FrameReader, descriptor: Int32,
                              deadline: MonotonicDeadline) throws -> InstallationReadinessMessage {
        let message = try InstallationReadinessMessage.decode(reader.read(descriptor: descriptor, deadline: deadline))
        guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
        return message
    }

    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.persistence(errno) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw CustodyRecordError.persistence(errno)
        }
        try HostControlIO.makeNonblocking(fd)
    }
    static func authenticate(_ socket: OwnedFileDescriptor, identity: PublisherCodeVerifier.Identity,
                             uid: uid_t, original: PublisherCodeVerifier.AuditPeerObservation?) throws -> PublisherCodeVerifier.AuditPeerObservation {
        let observed = try PublisherCodeVerifier.livePeer(socket: socket, expected: identity, expectedUID: uid)
        guard original == nil || original == observed else { throw PublisherPolicyError.unavailable }
        return observed
    }
    static func refuseAdditionalPeer(listener: Int32) throws {
        let extra = accept(listener, nil, nil)
        if extra >= 0 { close(extra); throw CustodyRecordError.conflict }
        guard errno == EAGAIN || errno == EWOULDBLOCK else { throw CustodyRecordError.persistence(errno) }
    }
    static func identity(candidate: InstallationCandidate, coordinator: Bool, team: String,
                         validationProfile: InstallationValidationProfile = .production) throws -> PublisherCodeVerifier.Identity {
        try candidate.validate(profile: validationProfile)
        let hex = coordinator ? candidate.coordinatorCDHash : candidate.appCDHash
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let a = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)!
        }
        return .init(team: team, identifier: coordinator ? LifecyclePublisher.identifier : ReleaseIdentity.bundleIdentifier,
            codeDirectory: Data(bytes))
    }
}

/// Owned bounded serial conversation. It retains the actual journal/owner, not
/// operation duplicates. An unfinished join intentionally retains the fence.
#if SHADOW_SYNC_TESTING
// Closed, bounded observations only; no error descriptions, errno payloads,
// paths or identity values can enter the fixture failure record.
enum InstallationTestingFailure: String {
    case invalidRecord, invalidTransition, conflict, fenced, busy, unsafeMetadata
    case persistence, committedCleanupFailure, injectedFailure
    case authenticationRejected, cancelled, other
    init(_ error: Error) {
        if let error = error as? CustodyRecordError {
            switch error {
            case .invalidRecord: self = .invalidRecord
            case .invalidTransition: self = .invalidTransition
            case .conflict: self = .conflict
            case .fenced: self = .fenced
            case .busy: self = .busy
            case .unsafeMetadata: self = .unsafeMetadata
            case .persistence: self = .persistence
            case .committedCleanupFailure: self = .committedCleanupFailure
            case .injectedFailure: self = .injectedFailure
            }
        } else if let error = error as? InstallationPrecommitSession.Failure {
            switch error {
            case .authenticationRejected: self = .authenticationRejected
            case .cancelled: self = .cancelled
            }
        } else { self = .other }
    }
}

// One caller owns this opt-in record. Weak references do not extend service
// ownership; capture occurs before the original error crosses fixture cleanup.
final class InstallationKickstartFailureObservation {
    enum Stage: String { case deadlineRead, completionCommand, retirementClock, sessionLookup, sessionAnchor }
    struct Failure {
        let stage: Stage
        let error: InstallationTestingFailure
        let session: InstallationPrecommitSession.TestingKickstartState?
        let endpoint: InstallationReadinessEndpoint.TestingRevalidationFailure?
    }
    private weak var session: InstallationPrecommitSession?
    private weak var endpoint: InstallationReadinessEndpoint?
    private(set) var first: Failure?
    init(session: InstallationPrecommitSession?, endpoint: InstallationReadinessEndpoint?) {
        self.session = session; self.endpoint = endpoint
    }
    func capture(stage: Stage, error: Error) {
        guard first == nil else { return }
        // Neither getter nests locks or invokes owner/catalog validation.
        let sessionState = session?.testingKickstartState
        let endpointFailure = endpoint?.testingFirstRevalidationFailure
        first = Failure(stage: stage, error: InstallationTestingFailure(error),
            session: sessionState, endpoint: endpointFailure)
    }
}
#endif

/// Ready is a one-use live observation. Durable publication belongs to the
/// original journal; only its one-use committed capability requests delivery.
/// Delivery is a transport observation, never normal startup or completion.
final class InstallationPrecommitSession: @unchecked Sendable {
    private let journal: CustodyCatalogStore.InstallationStagedJournal
    private let endpoint: InstallationReadinessEndpoint
    private let expected: PublisherCodeVerifier.Identity
    private let uid: uid_t
    private let validationProfile: InstallationValidationProfile
    private let preanchorDeadline: MonotonicDeadline
    private let queue = DispatchQueue(label: "com.kleinperkins.shadow-sync.installation-precommit")
    private let group = DispatchGroup()
    private let state = NSCondition()
    private var anchor: (InstallationControlRecord, MonotonicDeadline)?
    private var cancelled = false
    private enum Work { case reserved, queued, finished }
    private var work: Work = .reserved
    enum Failure: Error { case authenticationRejected, cancelled }
    #if SHADOW_SYNC_TESTING
    struct TestingAnchorState {
        let cancelled: Bool
        let anchorPresent: Bool
        let outcomePresent: Bool
        let retirementExpired: Bool
        let preanchorExpired: Bool
    }
    enum TestingServeFailureSite: String { case initialEndpointRevalidation, other }
    struct TestingKickstartState {
        let cancelled: Bool
        let anchorPresent: Bool
        let outcomePresent: Bool
        let firstServeFailure: InstallationTestingFailure?
        let firstServeFailureSite: TestingServeFailureSite?
        let anchorAttempt: TestingAnchorState?
    }
    private var testingFirstServeFailure: InstallationTestingFailure?
    private var testingFirstServeFailureSite: TestingServeFailureSite?
    private var testingFirstAnchorAttempt: TestingAnchorState?
    var testingKickstartState: TestingKickstartState {
        state.lock(); defer { state.unlock() }
        return TestingKickstartState(cancelled: cancelled, anchorPresent: anchor != nil,
            outcomePresent: outcome != nil, firstServeFailure: testingFirstServeFailure,
            firstServeFailureSite: testingFirstServeFailureSite,
            anchorAttempt: testingFirstAnchorAttempt)
    }
    private var verificationBarrier: CustodyLeaseTestingBarrier?
    enum TestingDeliveryPoint { case afterReadback, afterSendReservation }
    private var deliveryBarrier: (TestingDeliveryPoint, CustodyLeaseTestingBarrier)?
    func testingPauseDelivery(at point: TestingDeliveryPoint, barrier: CustodyLeaseTestingBarrier) throws {
        state.lock(); defer { state.unlock() }
        guard !cancelled, outcome == nil, commitDelivery == nil, deliveryBarrier == nil else {
            throw CustodyRecordError.fenced
        }
        deliveryBarrier = (point, barrier)
    }
    private func testingPauseDelivery(_ point: TestingDeliveryPoint) throws {
        state.lock()
        let barrier = deliveryBarrier.flatMap { $0.0 == point ? $0.1 : nil }
        if barrier != nil { deliveryBarrier = nil }
        state.unlock()
        if let barrier, !barrier.pause() { throw CustodyRecordError.busy }
    }
    func testingPauseVerification(_ barrier: CustodyLeaseTestingBarrier) {
        state.lock(); verificationBarrier = barrier; state.unlock()
    }
    #endif
    private var connection: OwnedFileDescriptor?
    private var retainedSelf: InstallationPrecommitSession?
    private var extraPeerCheckRunning = false
    private var rejectedPeer: OwnedFileDescriptor?
    private var outcome: Result<String, Error>?
    private var readyObservation: ReadyObservation?
    private var readyClaimed = false
    private var commitDelivery: CustodyCatalogStore.InstallationStagedJournal.CommitDelivery?
    private var deliveryState = InstallationCommitDeliveryState()
    private var delivered: CommitDelivered?
    private var started: NormalStarted?
    private var startupCandidate: NormalStarted?
    private var startedClaimed = false
    private var stopDelivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery?
    private var stopped: Stopped?
    private var stoppedJoinAttempted = false

    /// Actual authenticated acknowledgment; neither commit bytes nor decoded
    /// frames can construct this observation. It grants no cleanup capability.
    final class NormalStarted {
        private(set) weak var session: InstallationPrecommitSession?
        let control: InstallationControlRecord
        let host: ProcessIdentity
        let messageDigest: String
        let deadline: MonotonicDeadline
        func revalidatePeer() throws {
            guard let session else { throw CustodyRecordError.fenced }
            try session.validateStartupPeer(self)
        }
        fileprivate init(_ session: InstallationPrecommitSession, control: InstallationControlRecord,
                         host: ProcessIdentity, digest: String, deadline: MonotonicDeadline) {
            self.session = session; self.control = control; self.host = host; messageDigest = digest; self.deadline = deadline
        }
    }
    /// The peer acknowledged its application/server drain and checked admission
    /// release. This is NOT process death, launchd inactivity or command retirement.
    final class Stopped {
        fileprivate weak var session: InstallationPrecommitSession?
        fileprivate let delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery
        let control: InstallationControlRecord
        let host: ProcessIdentity
        let messageDigest: String
        let deadline: MonotonicDeadline
        fileprivate init(_ session: InstallationPrecommitSession,
                         delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery,
                         host: ProcessIdentity, digest: String, deadline: MonotonicDeadline) {
            self.session = session; self.delivery = delivery; control = delivery.control
            self.host = host; messageDigest = digest; self.deadline = deadline
        }
    }
    /// Original-session join after its authenticated final stopped frame. This
    /// is separate from committed cleanup and grants no endpoint unlink, host
    /// inactivity, candidate drainage, recovery admission or operation release.
    final class StoppedJoined {
        private let session: InstallationPrecommitSession
        private let acknowledgment: Stopped
        private let claimLock = NSLock()
        private var claimed = false
        var deadline: MonotonicDeadline { acknowledgment.deadline }
        fileprivate init(_ session: InstallationPrecommitSession, acknowledgment: Stopped) {
            self.session = session; self.acknowledgment = acknowledgment
        }
        func revalidate(for delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery,
                        acknowledgment: Stopped) throws {
            guard self.acknowledgment === acknowledgment, acknowledgment.delivery === delivery else {
                throw CustodyRecordError.fenced
            }
            claimLock.lock(); let wasClaimed = claimed; claimLock.unlock()
            guard wasClaimed else { throw CustodyRecordError.fenced }
            try session.validateStoppedJoin(acknowledgment)
        }
        func claim(for delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery) throws {
            guard acknowledgment.delivery === delivery else { throw CustodyRecordError.fenced }
            guard claimLock.try() else { throw CustodyRecordError.busy }
            guard !claimed else { claimLock.unlock(); throw CustodyRecordError.fenced }
            claimed = true; claimLock.unlock()
            try session.validateStoppedJoin(acknowledgment)
        }
    }
    private func validateStoppedJoin(_ acknowledgment: Stopped) throws {
        guard !acknowledgment.deadline.hasExpired else { throw CustodyRecordError.busy }
        state.lock()
        let valid = acknowledgment.session === self && stopped === acknowledgment
            && stopDelivery === acknowledgment.delivery && stoppedJoinAttempted
            && !cancelled && work == .finished && connection == nil
            && rejectedPeer == nil && !extraPeerCheckRunning
            && acknowledgment.deadline.absoluteUptimeNanoseconds == (anchor?.1 ?? preanchorDeadline).absoluteUptimeNanoseconds
        let completed = outcome
        state.unlock()
        guard valid, case .success? = completed else { throw CustodyRecordError.fenced }
        try endpoint.requireServiceClosed()
        guard !acknowledgment.deadline.hasExpired else { throw CustodyRecordError.busy }
    }
    func joinStopped(_ acknowledgment: Stopped,
        delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery) throws -> StoppedJoined {
        state.lock()
        guard acknowledgment.session === self, stopped === acknowledgment,
              acknowledgment.delivery === delivery, stopDelivery === delivery,
              !cancelled, !stoppedJoinAttempted else { state.unlock(); throw CustodyRecordError.fenced }
        stoppedJoinAttempted = true
        let deadline = anchor?.1 ?? preanchorDeadline
        state.unlock()
        guard !deadline.hasExpired,
              deadline.absoluteUptimeNanoseconds == acknowledgment.deadline.absoluteUptimeNanoseconds,
              group.wait(timeout: .init(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success else {
            throw CustodyRecordError.busy
        }
        // The queue itself performed every connection close and listener close.
        // Neither cancellation nor another descriptor-number retry supplies proof.
        try validateStoppedJoin(acknowledgment)
        try journal.didJoinReadiness(self, deadline: deadline)
        state.lock(); retainedSelf = nil; state.unlock()
        return StoppedJoined(self, acknowledgment: acknowledgment)
    }
    func takeNormalStarted() throws -> NormalStarted {
        state.lock(); defer { state.unlock() }
        // A live readiness service alone cannot enter normal startup. Require
        // this session's actual committed delivery before waiting for its ack.
        // Ineligible callers refuse without spending the candidate's budget.
        guard !cancelled, outcome == nil, commitDelivery != nil, delivered != nil else {
            throw CustodyRecordError.fenced
        }
        while started == nil && outcome == nil && !cancelled {
            let deadline = anchor?.1 ?? preanchorDeadline
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            _ = state.wait(until: Date(timeIntervalSinceNow: min(0.02, Double(deadline.remainingMilliseconds) / 1_000)))
        }
        guard !cancelled, outcome == nil, !startedClaimed, let started,
              !(anchor?.1 ?? preanchorDeadline).hasExpired else { throw CustodyRecordError.fenced }
        startedClaimed = true
        return started
    }
    func stoppedAcknowledgment(for delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery) -> Stopped? {
        state.lock(); defer { state.unlock() }
        guard stopDelivery === delivery, stopped?.delivery === delivery else { return nil }
        return stopped
    }
    func stop(_ delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery) throws -> Stopped {
        try delivery.revalidate()
        state.lock()
        let matchesStarted = started.map { startedClaimed && delivery.matches(journal: journal, started: $0) } ?? false
        let matchesReady = readyObservation.map {
            readyClaimed && commitDelivery == nil && started == nil && startupCandidate == nil
                && delivery.matches(journal: journal, ready: $0)
        } ?? false
        guard !cancelled, outcome == nil, matchesStarted || matchesReady, stopDelivery == nil else {
            state.unlock(); throw CustodyRecordError.fenced
        }
        let deadline = anchor?.1 ?? preanchorDeadline
        stopDelivery = delivery; state.broadcast()
        while stopped == nil && outcome == nil && !cancelled && !deadline.hasExpired {
            _ = state.wait(until: Date(timeIntervalSinceNow: min(0.02, Double(deadline.remainingMilliseconds) / 1_000)))
        }
        let result = !cancelled ? stopped : nil
        state.unlock()
        guard let result else { throw CustodyRecordError.fenced }
        return result
    }

    /// Written bytes only. This does not assert that the host consumed commit,
    /// started normally, retired anything, or completed installation.
    struct CommitDelivered {
        let controlRevision: UInt64
        let messageDigest: String
        fileprivate init(controlRevision: UInt64, messageDigest: String) {
            self.controlRevision = controlRevision; self.messageDigest = messageDigest
        }
    }

    /// Constructible only after this actual socket passed mutual authentication
    /// and all three ordered frames. No fixture or decoded value can mint it.
    final class ReadyObservation {
        private weak var session: InstallationPrecommitSession?
        private let validationProfile: InstallationValidationProfile
        let control: InstallationControlRecord
        let host: ProcessIdentity
        let transcriptDigest: String
        let deadline: MonotonicDeadline
        fileprivate let peer: PublisherCodeVerifier.AuditPeerObservation
        fileprivate init(session: InstallationPrecommitSession, control: InstallationControlRecord,
            host: ProcessIdentity, transcript: String, deadline: MonotonicDeadline,
            peer: PublisherCodeVerifier.AuditPeerObservation) {
            self.validationProfile = session.validationProfile
            self.session = session; self.control = control; self.host = host
            transcriptDigest = transcript; self.deadline = deadline; self.peer = peer
        }
        func expectedCommittedControl() throws -> InstallationControlRecord {
            try InstallationHostCommitBinding.expectedControl(after: control,
                host: InstallationProcessObservation(pid: UInt32(host.processID), uid: host.userID,
                    startSeconds: host.startSeconds, startMicroseconds: host.startMicroseconds,
                    generation: host.generation), transcriptDigest: transcriptDigest, validationProfile: validationProfile)
        }
        func deliver(_ delivery: CustodyCatalogStore.InstallationStagedJournal.CommitDelivery) throws -> CommitDelivered {
            guard let session else { throw CustodyRecordError.fenced }
            return try session.deliver(delivery, ready: self)
        }
        func revalidate(for journal: CustodyCatalogStore.InstallationStagedJournal) throws {
            guard let session, session.journal === journal else { throw CustodyRecordError.fenced }
            try session.validateReady(self)
        }
    }
    func takeReady() throws -> ReadyObservation {
        state.lock(); defer { state.unlock() }
        while readyObservation == nil && outcome == nil && !cancelled {
            let deadline = anchor?.1 ?? preanchorDeadline
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            _ = state.wait(until: Date(timeIntervalSinceNow: min(0.02, Double(deadline.remainingMilliseconds) / 1_000)))
        }
        guard !cancelled, outcome == nil, !readyClaimed, let ready = readyObservation,
              !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
        readyClaimed = true
        return ready
    }
    private func validateReady(_ ready: ReadyObservation) throws {
        state.lock()
        let socket = connection
        let valid = !cancelled && work == .queued && outcome == nil && readyObservation === ready && readyClaimed
        state.unlock()
        guard valid, let socket, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
        try rejectExtraPeer()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: ready.peer)
        guard try journal.readinessHost(peer: ready.peer, generation: ready.host.generation,
            deadline: ready.deadline) == ready.host else { throw CustodyRecordError.fenced }
        try InstallationPrecommitTransport.requireQuiet(socket)
        state.lock(); let unchanged = !cancelled && outcome == nil && connection === socket; state.unlock()
        guard unchanged, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
    }

    private func deliver(_ delivery: CustodyCatalogStore.InstallationStagedJournal.CommitDelivery,
                         ready: ReadyObservation) throws -> CommitDelivered {
        // The journal's unforgeable object binds the actual ready observation.
        // No caller-supplied record, socket, bytes, PID or timeout is accepted.
        guard delivery.matches(journal: journal, ready: ready) else { throw CustodyRecordError.fenced }
        state.lock()
        do {
            guard !cancelled, work == .queued, outcome == nil, readyClaimed,
                  readyObservation === ready, stopDelivery == nil, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
            try deliveryState.submit()
            commitDelivery = delivery; state.broadcast(); state.unlock()
        } catch { state.unlock(); throw error }
        // Delivery waits only for bytes. The SAME queue continues reading the
        // authenticated startup acknowledgment under the original deadline.
        state.lock()
        while delivered == nil && outcome == nil && !cancelled && !ready.deadline.hasExpired {
            _ = state.wait(until: Date(timeIntervalSinceNow: min(0.02, Double(ready.deadline.remainingMilliseconds) / 1_000)))
        }
        let result = !cancelled ? delivered : nil
        state.unlock()
        guard let result else { throw CustodyRecordError.fenced }
        return result
    }

    // This constructor consumes a capsule minted only by the actual journal
    // after exact socket completion. Serialized owner IDs cannot construct it.
    init(_ context: CustodyCatalogStore.InstallationStagedJournal.ReadinessContext) {
        validationProfile = context.validationProfile
        journal = context.journal; endpoint = context.endpoint; expected = context.app
        uid = context.uid; preanchorDeadline = context.deadline
        // Reserve before the journal can publish this owner to cancellation.
        group.enter()
        retainedSelf = self
    }
    @discardableResult func start() -> Bool {
        state.lock()
        guard work == .reserved, !cancelled else { state.unlock(); return false }
        work = .queued
        state.unlock()
        // Dispatch and all resource work are outside both state and journal locks.
        queue.async { [self] in
            defer {
                endpoint.closeService()
                state.lock(); work = .finished; state.broadcast(); state.unlock()
                group.leave()
            }
            do { let digest = try serve(); state.lock(); outcome = .success(digest); state.broadcast(); state.unlock() }
            catch {
                state.lock()
                #if SHADOW_SYNC_TESTING
                if testingFirstServeFailure == nil {
                    testingFirstServeFailure = InstallationTestingFailure(error)
                    testingFirstServeFailureSite = .other
                }
                #endif
                deliveryState.fail(); outcome = .failure(error); state.broadcast(); state.unlock()
            }
            state.lock(); readyObservation = nil; commitDelivery = nil
            #if SHADOW_SYNC_TESTING
            let cleanupGate = testingCleanupGate
            #endif
            state.unlock()
            #if SHADOW_SYNC_TESTING
            cleanupGate?.hold()
            #endif
            do { try retireConnection() }
            catch { state.lock(); outcome = .failure(error); state.broadcast(); state.unlock() }
        }
        return true
    }
    func anchorAfterKickstart(_ control: InstallationControlRecord, deadline: MonotonicDeadline) throws {
        state.lock(); defer { state.unlock() }
        #if SHADOW_SYNC_TESTING
        if testingFirstAnchorAttempt == nil {
            testingFirstAnchorAttempt = TestingAnchorState(cancelled: cancelled, anchorPresent: anchor != nil,
                outcomePresent: outcome != nil, retirementExpired: deadline.hasExpired,
                preanchorExpired: preanchorDeadline.hasExpired)
        }
        #endif
        guard !cancelled, anchor == nil, outcome == nil, !deadline.hasExpired else { throw CustodyRecordError.fenced }
        // Retirement supplies the original five-second endpoint; opening the
        // session supplies the original invocation ceiling. Neither may reset
        // or extend the other when kickstart finishes near invocation expiry.
        let bounded = MonotonicDeadline(uptimeNanoseconds: min(deadline.absoluteUptimeNanoseconds,
            preanchorDeadline.absoluteUptimeNanoseconds))
        guard !bounded.hasExpired else { throw CustodyRecordError.busy }
        anchor = (control, bounded); state.broadcast()
    }
    private func currentDeadline() throws -> MonotonicDeadline {
        state.lock(); defer { state.unlock() }
        guard !cancelled else { throw CustodyRecordError.fenced }
        let deadline = anchor?.1 ?? preanchorDeadline
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        return deadline
    }
    private func rejectExtraPeer() throws {
        try endpoint.revalidate(deadline: try currentDeadline())
        state.lock()
        guard !extraPeerCheckRunning, rejectedPeer == nil else { state.unlock(); throw CustodyRecordError.busy }
        extraPeerCheckRunning = true; state.unlock()
        defer { state.lock(); extraPeerCheckRunning = false; state.broadcast(); state.unlock() }
        let listener = try endpoint.listener
        let (extra, code) = try listener.withOriginalSocket { fd in
            let accepted = accept(fd, nil, nil)
            return (accepted, accepted < 0 ? errno : 0)
        }
        if extra >= 0 {
            let owned = OwnedFileDescriptor(extra)
            // The actual extra stream is retained before its one close attempt.
            // Refusal fences this session and preserves any uncertain close.
            state.lock(); rejectedPeer = owned; cancelled = true
            deliveryState.fail(); outcome = .failure(CustodyRecordError.conflict)
            #if SHADOW_SYNC_TESTING
            let cleanupExtra = testingCleanupExtra
            #endif
            state.broadcast(); state.unlock()
            #if SHADOW_SYNC_TESTING
            cleanupExtra?.enroll(owned)
            #endif
            _ = owned.retireChecked()
            throw CustodyRecordError.conflict
        }
        guard code == EAGAIN || code == EWOULDBLOCK else { throw CustodyRecordError.persistence(code) }
    }
    private func serve() throws -> String {
        var socket: OwnedFileDescriptor?
        while socket == nil {
            let deadline = try currentDeadline()
            #if SHADOW_SYNC_TESTING
            // Classify this actual call before connection retirement or another
            // endpoint caller can replace session outcome. No per-poll record.
            let endpointDeadline = try currentDeadline()
            do { try endpoint.revalidate(deadline: endpointDeadline) }
            catch {
                let savedDiagnosticErrno = errno
                state.lock()
                if testingFirstServeFailure == nil {
                    testingFirstServeFailure = InstallationTestingFailure(error)
                    testingFirstServeFailureSite = .initialEndpointRevalidation
                }
                state.unlock()
                errno = savedDiagnosticErrno
                throw error
            }
            #else
            try endpoint.revalidate(deadline: try currentDeadline())
            #endif
            let listener = try endpoint.listener
            let (fd, acceptError) = try listener.withOriginalSocket { original in
                let accepted = accept(original, nil, nil)
                return (accepted, accepted < 0 ? errno : 0)
            }
            if fd >= 0 {
                let owned = OwnedFileDescriptor(fd)
                // Retain the actual accepted stream before configuration may throw.
                socket = owned
                state.lock(); connection = owned; state.unlock()
                try InstallationPrecommitTransport.configure(fd)
            } else {
                guard acceptError == EAGAIN || acceptError == EWOULDBLOCK || acceptError == EINTR else { throw CustodyRecordError.persistence(acceptError) }
                // Poll in bounded slices so post-kickstart anchoring/cancellation
                // can shorten the original preanchor command deadline.
                var item = pollfd(fd: try endpoint.listener.value, events: Int16(POLLIN), revents: 0)
                let n = poll(&item, 1, min(20, deadline.remainingMilliseconds))
                guard n >= 0 || errno == EINTR else { throw CustodyRecordError.persistence(errno) }
            }
        }
        guard let socket else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        state.lock(); let barrier = verificationBarrier; verificationBarrier = nil; state.unlock()
        if let barrier, !barrier.pause() { throw CustodyRecordError.busy }
        #endif
        _ = try currentDeadline()
        var original: PublisherCodeVerifier.AuditPeerObservation
        do { original = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: nil) }
        catch { throw Failure.authenticationRejected }
        var anchored: (InstallationControlRecord, MonotonicDeadline)?
        repeat {
            _ = try currentDeadline(); try rejectExtraPeer()
            state.lock(); anchored = anchor
            if anchored == nil && !cancelled { _ = state.wait(until: Date(timeIntervalSinceNow: 0.02)) }
            state.unlock()
        } while anchored == nil
        guard let (control, deadline) = anchored else { throw CustodyRecordError.fenced }
        var reader = HostControlIO.FrameReader()
        let hello = try InstallationReadinessMessage.decode(reader.read(descriptor: socket.value, deadline: deadline))
        guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
        try rejectExtraPeer()
        original = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
        try journal.validateReadiness(control, deadline: deadline)
        try InstallationPrecommitTranscript.validateHello(hello, control: control)
        let host = try journal.readinessHost(peer: original, generation: hello.hostGeneration, deadline: deadline)
        var transcript = try InstallationPrecommitTranscript(hello: hello)
        try transcript.consume(hello, sender: .host, deadline: deadline)
        let challenge = try transcript.message(.challenge)
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
        try journal.validateReadiness(control, deadline: deadline)
        try rejectExtraPeer()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
        try HostControlIO.writeFrame(challenge.encode(), descriptor: socket.value, deadline: deadline)
        try transcript.consume(challenge, sender: .coordinator, deadline: deadline)
        guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
        let ready = try InstallationReadinessMessage.decode(reader.read(descriptor: socket.value, deadline: deadline))
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
        try journal.validateReadiness(control, deadline: deadline)
        try rejectExtraPeer()
        guard try journal.readinessHost(peer: original, generation: ready.hostGeneration, deadline: deadline) == host else {
            throw CustodyRecordError.fenced
        }
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
        try transcript.consume(ready, sender: .host, deadline: deadline)
        guard !reader.hasBufferedBytes, let digest = transcript.completedDigest else { throw CustodyProtocolError.invalidSequence }
        let readyObservation = ReadyObservation(session: self, control: control, host: host,
            transcript: digest, deadline: deadline, peer: original)
        state.lock()
        guard !cancelled, self.readyObservation == nil else { state.unlock(); throw Failure.cancelled }
        self.readyObservation = readyObservation; state.broadcast(); state.unlock()
        // Keep the sole session queue serviceable while caller-owned custody
        // runs on its own queue. No journal/registry/authority lock spans poll.
        while true {
            _ = try currentDeadline(); try rejectExtraPeer(); try InstallationPrecommitTransport.requireQuiet(socket)
            state.lock(); let delivery = commitDelivery, stop = stopDelivery; state.unlock()
            if let stop {
                guard delivery == nil, stop.matches(journal: journal, ready: readyObservation) else { throw CustodyRecordError.fenced }
                try stop.revalidate()
                _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
                let message = try InstallationReadinessStopBinding.stop(after: ready, control: stop.control, deadline: deadline)
                try HostControlIO.writeFrame(message.encode(), descriptor: socket.value, deadline: deadline)
                let acknowledgment = try InstallationReadinessMessage.decode(reader.read(descriptor: socket.value, deadline: deadline))
                guard !reader.hasBufferedBytes,
                      acknowledgment == (try InstallationReadinessStopBinding.stopped(after: message, deadline: deadline)) else {
                    throw CustodyProtocolError.invalidSequence
                }
                _ = try currentDeadline(); try rejectExtraPeer()
                _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: original)
                try stop.revalidate()
                let result = Stopped(self, delivery: stop, host: host, digest: try acknowledgment.digest(), deadline: deadline)
                state.lock()
                guard !cancelled, commitDelivery == nil else { state.unlock(); throw Failure.cancelled }
                stopped = result; state.broadcast(); state.unlock()
                return digest
            }
            if let delivery {
                try delivery.revalidate()
                #if SHADOW_SYNC_TESTING
                try testingPauseDelivery(.afterReadback)
                #endif
                // Revalidate original native peer/process and quiet input AFTER
                // durable exact chain readback, under the original ready clock.
                try validateReady(readyObservation)
                let message = try InstallationCommitDeliveryBinding.message(ready: ready,
                    committed: delivery.control, deadline: deadline, validationProfile: validationProfile)
                let bytes = try message.encode(), messageDigest = try message.digest()
                _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected,
                    uid: uid, original: readyObservation.peer)
                try InstallationPrecommitTransport.requireQuiet(socket)
                state.lock()
                do {
                    guard !cancelled, !deadline.hasExpired, commitDelivery === delivery,
                          outcome == nil else { throw CustodyRecordError.fenced }
                    try deliveryState.begin(); state.unlock()
                } catch { state.unlock(); throw error }
                // This reservation linearizes against cancellation. No state,
                // journal, catalog or owner mutex spans socket IO. A partial
                // write is terminal; writeFrame continues only this same frame.
                #if SHADOW_SYNC_TESTING
                try testingPauseDelivery(.afterSendReservation)
                #endif
                try HostControlIO.writeFrame(bytes, descriptor: socket.value, deadline: deadline)
                state.lock()
                do {
                    guard !cancelled, !deadline.hasExpired else { throw CustodyRecordError.fenced }
                    try deliveryState.finish()
                    delivered = CommitDelivered(controlRevision: delivery.control.revision,
                        messageDigest: messageDigest)
                    state.broadcast(); state.unlock()
                } catch { state.unlock(); throw error }
                try continueStartup(socket: socket, reader: &reader, commit: message,
                    delivery: delivery, ready: readyObservation, deadline: deadline)
                return digest
            }
            var item = pollfd(fd: socket.value, events: Int16(POLLIN), revents: 0)
            let n = poll(&item, 1, min(20, deadline.remainingMilliseconds))
            guard n >= 0 || errno == EINTR else { throw CustodyRecordError.persistence(errno) }
        }
    }
    private func validateStartupPeer(_ observation: NormalStarted) throws {
        state.lock()
        let socket = connection, ready = readyObservation
        let valid = !cancelled && outcome == nil && startupCandidate === observation
        state.unlock()
        guard valid, let socket, let ready, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: ready.peer)
        guard try ProcessIdentity.capture(processID: ready.peer.pid, generation: observation.host.generation,
            expectedExecutablePath: observation.host.executablePath) == observation.host else { throw CustodyRecordError.fenced }
    }
    private func continueStartup(socket: OwnedFileDescriptor, reader: inout HostControlIO.FrameReader,
        commit: InstallationReadinessMessage, delivery: CustodyCatalogStore.InstallationStagedJournal.CommitDelivery,
        ready: ReadyObservation, deadline: MonotonicDeadline) throws {
        var transcript = try InstallationStartupTranscript(commit: commit)
        let normal = try InstallationReadinessMessage.decode(reader.read(descriptor: socket.value, deadline: deadline))
        guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
        _ = try currentDeadline(); try rejectExtraPeer()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: ready.peer)
        try transcript.consume(normal, sender: .host, deadline: deadline)
        let observation = NormalStarted(self, control: delivery.control, host: ready.host, digest: try normal.digest(), deadline: deadline)
        state.lock(); startupCandidate = observation; state.unlock()
        try journal.validateNormalStartup(observation, delivery: delivery, deadline: deadline)
        state.lock()
        guard !cancelled, started == nil else { state.unlock(); throw Failure.cancelled }
        started = observation; state.broadcast(); state.unlock()
        while true {
            _ = try currentDeadline(); try rejectExtraPeer()
            try InstallationPrecommitTransport.requireQuiet(socket)
            state.lock(); let stop = stopDelivery; state.unlock()
            if let stop {
                try stop.revalidate()
                _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: ready.peer)
                let message = try transcript.message(.stop, deadline: deadline)
                guard message.controlRevision == stop.control.revision else { throw CustodyRecordError.fenced }
                try HostControlIO.writeFrame(message.encode(), descriptor: socket.value, deadline: deadline)
                try transcript.consume(message, sender: .coordinator, deadline: deadline)
                let acknowledgment = try InstallationReadinessMessage.decode(reader.read(descriptor: socket.value, deadline: deadline))
                guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
                _ = try currentDeadline(); try rejectExtraPeer()
                _ = try InstallationPrecommitTransport.authenticate(socket, identity: expected, uid: uid, original: ready.peer)
                try stop.revalidate()
                try transcript.consume(acknowledgment, sender: .host, deadline: deadline)
                let result = Stopped(self, delivery: stop, host: ready.host,
                    digest: try acknowledgment.digest(), deadline: deadline)
                state.lock()
                guard !cancelled else { state.unlock(); throw Failure.cancelled }
                stopped = result; state.broadcast(); state.unlock()
                return
            }
            var item = pollfd(fd: socket.value, events: Int16(POLLIN), revents: 0)
            let count = poll(&item, 1, min(20, deadline.remainingMilliseconds))
            guard count >= 0 || errno == EINTR else { throw CustodyRecordError.persistence(errno) }
        }
    }
    private func retireConnection() throws {
        state.lock(); let socket = connection, extra = rejectedPeer
        let checking = extraPeerCheckRunning; state.unlock()
        guard !checking else { throw CustodyRecordError.busy }
        if let extra {
            guard extra.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            state.lock(); if rejectedPeer === extra { rejectedPeer = nil }; state.unlock()
        }
        if let socket {
            guard socket.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            state.lock(); if connection === socket { connection = nil }; state.unlock()
        }
    }
    /// Issued only after this actual queue and its accepted/extra-peer/listener
    /// owners have all retired. Session cancellation alone cannot construct it.
    final class CleanupJoined {
        private let session: InstallationPrecommitSession
        private let permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit
        fileprivate init(_ session: InstallationPrecommitSession,
                         permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit) {
            self.session = session; self.permit = permit
        }
        func validate(_ permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit) throws {
            guard self.permit === permit else { throw CustodyRecordError.fenced }
            session.state.lock(); defer { session.state.unlock() }
            guard session.cancelled, session.work == .finished, session.connection == nil,
                  session.rejectedPeer == nil, !session.extraPeerCheckRunning,
                  session.retainedSelf == nil else { throw CustodyRecordError.fenced }
        }
    }
    func retireForCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit,
                          started: NormalStarted) throws -> CleanupJoined {
        guard permit.matches(session: self, started: started),
              permit.deadline.absoluteUptimeNanoseconds == started.deadline.absoluteUptimeNanoseconds else {
            throw CustodyRecordError.fenced
        }
        try started.revalidatePeer()
        try cancelAndJoin(deadline: permit.deadline)
        let joined = CleanupJoined(self, permit: permit)
        try joined.validate(permit)
        return joined
    }
    func cancelAndJoin(deadline: MonotonicDeadline) throws {
        state.lock()
        cancelled = true; deliveryState.cancel()
        let unlaunched = work == .reserved
        if unlaunched { work = .finished; outcome = .failure(Failure.cancelled) }
        let socket = connection
        state.broadcast(); state.unlock()
        // Exactly one canceller owns the unlaunched reservation. A queued owner
        // alone leaves its group, even if dispatch has not executed yet.
        if unlaunched { group.leave() }
        socket?.interruptSocket()
        // Interrupt is best effort, never evidence of close or retirement.
        // The final required checks below still fence a busy/uncertain owner.
        if let listener = try? endpoint.listener { listener.interruptSocket() }
        guard group.wait(timeout: DispatchTime(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success else {
            throw CustodyRecordError.busy
        }
        try retireConnection()
        endpoint.closeService()
        try endpoint.requireServiceClosed()
        try journal.didJoinReadiness(self, deadline: deadline)
        state.lock(); retainedSelf = nil; state.unlock()
    }
    #if SHADOW_SYNC_TESTING
    private var testingCleanupGate: InstallationCoordinationCleanupFixtures.QueueGate?
    private var testingCleanupExtra: InstallationCoordinationCleanupFixtures.CloseFault?
    @inline(never)
    func testingArmCleanupQueue(_ gate: InstallationCoordinationCleanupFixtures.QueueGate) throws {
        state.lock(); defer { state.unlock() }
        guard !cancelled, work == .queued, started != nil, testingCleanupGate == nil else { throw CustodyRecordError.fenced }
        testingCleanupGate = gate
    }
    @inline(never)
    func testingArmCleanupAccepted(_ fault: InstallationCoordinationCleanupFixtures.CloseFault) throws {
        state.lock(); defer { state.unlock() }
        guard !cancelled, work == .queued, started != nil, let connection else { throw CustodyRecordError.fenced }
        fault.enroll(connection)
    }
    @inline(never)
    func testingArmCleanupExtra(_ fault: InstallationCoordinationCleanupFixtures.CloseFault) throws {
        state.lock(); defer { state.unlock() }
        guard !cancelled, work == .queued, started != nil, rejectedPeer == nil,
              testingCleanupExtra == nil else { throw CustodyRecordError.fenced }
        testingCleanupExtra = fault
    }
    var testingCleanupResources: (finished: Bool, retained: Bool, connection: OwnedFileDescriptor?, extra: OwnedFileDescriptor?) {
        state.lock(); defer { state.unlock() }
        return (work == .finished, retainedSelf === self, connection, rejectedPeer)
    }
    /// Fixture drainage observes only the real queue. It cannot manufacture a
    /// CleanupJoined or change a descriptor's irreversible retirement result.
    @inline(never)
    func testingJoinCleanupQueue(deadline: MonotonicDeadline) throws {
        guard group.wait(timeout: .init(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success else {
            throw CustodyRecordError.busy
        }
    }
    // Observation only: a fixture cannot set/reset the actual retirement budget.
    var testingAnchoredDeadline: MonotonicDeadline? {
        state.lock(); defer { state.unlock() }; return anchor?.1
    }
    var testingOutcome: Result<String, Error>? { state.lock(); defer { state.unlock() }; return outcome }
    func testingWaitForAuthenticationRefusal(deadline: MonotonicDeadline) throws {
        state.lock(); defer { state.unlock() }
        while outcome == nil && !deadline.hasExpired {
            _ = state.wait(until: Date(timeIntervalSinceNow: min(0.02, Double(deadline.remainingMilliseconds) / 1_000)))
        }
        guard case .failure(Failure.authenticationRejected)? = outcome else { throw CustodyRecordError.fenced }
    }
    #endif
}

/// Distinct current-session readiness admission used only by managed startup.
/// Only actual authenticated commit consumption can hand off the continuously
/// retained namespace SH/lifecycle SH/launcher EX; no operation or run is held.
final class InstallationPrecommitHost: @unchecked Sendable {
    enum Failure: Error { case readinessStopped }
    private let lifecycle: LifecycleAdmissionAuthority
    private let launcher: LauncherAuthority
    private let endpoint: InstallationPrecommitHostEndpoint
    private var control: InstallationControlRecord
    private let paths: InstallationPaths
    private let validationProfile: InstallationValidationProfile
    private let app: PublisherCodeVerifier.Identity
    private let coordinator: PublisherCodeVerifier.Identity
    private let deadline: MonotonicDeadline
    private let generation = RunIdentity.make()
    private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let state = NSLock()
    private enum Phase { case fresh, running, offered, taking, retained, starting, normal, stopping, stopped, closed }
    private var phase: Phase = .fresh
    private var working = false
    private var resourcesReleased = false
    private var retainedSelf: InstallationPrecommitHost?
    private var offered: ObjectIdentifier?
    private struct CommittedContext {
        let durable: CustodyCatalogStore.HostCommittedObservation
        let slots: InstallationCommittedHostSlots
        let host: ProcessIdentity
        let peer: PublisherCodeVerifier.AuditPeerObservation
        let message: InstallationReadinessMessage
    }
    private var committed: CommittedContext?
    private var continuation: InstallationStartupTranscript?
    // The synchronous handshake transfers its SOLE reader to this bounded
    // continuation queue. It never runs concurrently with run()/take().
    private var reader = HostControlIO.FrameReader()
    private let continuationQueue = DispatchQueue(label: "com.kleinperkins.shadow-sync.installation-host")
    private let continuationGroup = DispatchGroup()
    private var continuationRunning = false
    private var stopControl: InstallationControlRecord?
    private var server: HostControlServer?

    /// The constructor is private to this actual host. Taking is one-use and
    /// preserves the original deadline; a decoded observation cannot mint it.
    final class Admission {
        private let owner: InstallationPrecommitHost
        fileprivate init(owner: InstallationPrecommitHost) { self.owner = owner }
        func take() throws -> RetainedOwnership { try owner.take(self) }
        func close() { owner.close() }
        deinit { owner.abandon(self) }
    }
    /// Actual startup retains this entire object until teardown. These are the
    /// exact original owners, not reopened locks or a normal-admission fallback.
    final class RetainedOwnership {
        private let owner: InstallationPrecommitHost
        private let lifecycle: LifecycleAdmissionAuthority
        private let launcher: LauncherAuthority
        let generation: String
        let deadline: MonotonicDeadline
        fileprivate init(owner: InstallationPrecommitHost) {
            self.owner = owner; lifecycle = owner.lifecycle; launcher = owner.launcher
            generation = owner.generation; deadline = owner.deadline
        }
        func validateBeforeStartup() throws { try owner.validateRetained() }
        var stateDirectory: SecureStateDirectory { launcher.stateDirectory }
        func observeCreatedSocket() throws -> InstallationNamedSocketObservation {
            try owner.endpoint.normalSocketObservation()
        }
        func makeServer(executablePath: String, releaseIdentity: ReleaseIdentity,
            onActivation: @escaping @Sendable () -> Bool,
            onLifecycleExit: @escaping @Sendable () -> Bool) throws -> HostControlServer {
            try owner.validateRetained()
            let server = try HostControlServer(staged: self, executablePath: executablePath,
                releaseIdentity: releaseIdentity, onActivation: onActivation, onLifecycleExit: onLifecycleExit)
            try owner.installServer(server)
            return server
        }
        func didInitialize(_ server: HostControlServer, onStop: @escaping @Sendable () -> Void) throws {
            try owner.didInitialize(server, ownership: self, onStop: onStop)
        }
        func applicationDrained(_ server: HostControlServer) throws { try owner.applicationDrained(server, ownership: self) }
        func close() { owner.close() }
        deinit { owner.close() }
    }
    private init(lifecycle: LifecycleAdmissionAuthority, launcher: LauncherAuthority,
        endpoint: InstallationPrecommitHostEndpoint, control: InstallationControlRecord,
        paths: InstallationPaths, app: PublisherCodeVerifier.Identity,
        coordinator: PublisherCodeVerifier.Identity, deadline: MonotonicDeadline,
        validationProfile: InstallationValidationProfile = .production) {
        self.lifecycle = lifecycle; self.launcher = launcher; self.endpoint = endpoint
        self.control = control; self.paths = paths; self.app = app; self.coordinator = coordinator; self.deadline = deadline
        self.validationProfile = validationProfile
        retainedSelf = self
    }
    // Retirement clears the pre-enrolled lifetime fence; deinit never resurrects it.
    /// Cancellation fences transitions before shutdown. IO and owner release
    /// occur outside the short state mutex; there is no background host worker.
    func close() {
        state.lock()
        phase = .closed; offered = nil
        let release = !working && !continuationRunning && server == nil && !resourcesReleased
        if release { resourcesReleased = true }
        var retained = release ? committed : nil
        if release { committed = nil }
        state.unlock()
        endpoint.connection.interruptSocket()
        if release {
            let stream = endpoint.retireFailedHostResources()
            guard stream == .succeeded else {
                state.lock(); resourcesReleased = false
                if committed == nil { committed = retained }; state.unlock()
                return
            }
            withExtendedLifetime(retained) {}
            retained = nil
            // Alias uncertainty preserves BOTH actual admission owners. Do not
            // drop launcher EX before proving every observation alias retired.
            let aliases = lifecycle.closeCommittedHostObservationBorrowing()
            guard aliases == .succeeded else {
                state.lock(); resourcesReleased = false; state.unlock(); return
            }
            let launcherResult = launcher.retireCommittedHostLauncher()
            let result = launcherResult == .succeeded
                ? lifecycle.retireCommittedHostAdmission() : launcherResult
            guard result == .succeeded else {
                state.lock(); resourcesReleased = false; state.unlock(); return
            }
            state.lock(); retainedSelf = nil; state.unlock()
        }
    }
    private func finishWork(success: Bool) {
        state.lock(); working = false
        let keep = success && phase != .closed
        state.unlock()
        if !keep { close() }
    }
    private func abandon(_ admission: Admission) {
        state.lock(); let abandoned = phase == .offered && offered == ObjectIdentifier(admission); state.unlock()
        if abandoned { close() }
    }
    private func requireRunning() throws {
        state.lock(); let active = phase == .running; state.unlock()
        guard active, !deadline.hasExpired, lifecycle.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
    }
    private func validate(_ context: CommittedContext) throws {
        guard !deadline.hasExpired, lifecycle.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        try launcher.validateRetainedInstallation(context.durable.control.state)
        try context.durable.revalidate(deadline: deadline)
        try context.slots.revalidate()
        let identities = try Self.identities(paths: paths, control: context.durable.control, validationProfile: validationProfile)
        guard identities.0 == app, identities.1 == coordinator,
              try ProcessIdentity.capture(processID: getpid(), generation: generation,
                expectedExecutablePath: paths.executable) == context.host else { throw PublisherPolicyError.unavailable }
        try context.durable.revalidate(deadline: deadline)
        try context.slots.revalidate()
        try launcher.validateRetainedInstallation(context.durable.control.state)
        guard !deadline.hasExpired, lifecycle.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
    }
    private func take(_ admission: Admission) throws -> RetainedOwnership {
        state.lock()
        guard phase == .offered, !working, offered == ObjectIdentifier(admission), let context = committed else {
            state.unlock(); throw CustodyRecordError.fenced
        }
        phase = .taking; working = true; state.unlock()
        var returned = false
        defer { finishWork(success: returned) }
        do {
            // Commit has already been consumed. EOF cannot turn it back into
            // precommit; no second peer check or new clock is invented here.
            try validate(context)
            try InstallationHostCommitBinding.requireNoPostcommitInput(endpoint.connection)
            state.lock()
            guard phase == .taking, !deadline.hasExpired else { state.unlock(); throw CustodyRecordError.fenced }
            phase = .retained; offered = nil
            let result = RetainedOwnership(owner: self)
            returned = true
            state.unlock(); return result
        } catch { close(); throw error }
    }
    private func validateRetained() throws {
        state.lock()
        guard phase == .retained, !working, let context = committed else { state.unlock(); throw CustodyRecordError.fenced }
        working = true; state.unlock()
        var validated = false
        defer { finishWork(success: validated) }
        do {
            try validate(context)
            try InstallationHostCommitBinding.requireNoPostcommitInput(endpoint.connection)
            state.lock(); let live = phase == .retained; state.unlock()
            guard live, !deadline.hasExpired else { throw CustodyRecordError.fenced }
            validated = true
        } catch { close(); throw error }
    }
    private func installServer(_ value: HostControlServer) throws {
        state.lock(); defer { state.unlock() }
        guard phase == .retained, server == nil, !working else { throw CustodyRecordError.fenced }
        server = value
    }
    private func authenticateCoordinator(_ context: CommittedContext) throws {
        _ = try InstallationPrecommitTransport.authenticate(endpoint.connection, identity: coordinator,
            uid: context.durable.control.state.directory.uid, original: context.peer)
        guard let process = context.durable.control.transaction?.coordinator.process else { throw CustodyRecordError.fenced }
        let current = try ProcessIdentity.capture(processID: context.peer.pid, generation: process.generation)
        guard current.startSeconds == process.startSeconds, current.startMicroseconds == process.startMicroseconds else {
            throw PublisherPolicyError.unavailable
        }
    }
    private func didInitialize(_ value: HostControlServer, ownership: RetainedOwnership,
                               onStop: @escaping @Sendable () -> Void) throws {
        state.lock()
        guard phase == .retained, server === value, !working, let context = committed else {
            state.unlock(); throw CustodyRecordError.fenced
        }
        phase = .starting; working = true; state.unlock()
        var succeeded = false
        defer { finishWork(success: succeeded) }
        let serverProof = try value.observeStarted(staged: ownership)
        try context.slots.observeNormalServer(serverProof)
        try validate(context)
        try authenticateCoordinator(context)
        var transcript = try InstallationStartupTranscript(commit: context.message)
        let normal = try transcript.message(.normalStarted, deadline: deadline)
        try InstallationHostCommitBinding.requireNoPostcommitInput(endpoint.connection)
        try value.requireStarted(staged: ownership)
        try authenticateCoordinator(context)
        // A transport loss after consumed commit cannot undo commit or release
        // the actual host owners. It prevents acknowledgment/stop observation.
        do { try HostControlIO.writeFrame(normal.encode(), descriptor: endpoint.connection.value, deadline: deadline) }
        catch {
            state.lock(); phase = .normal; state.unlock()
            succeeded = true
            return
        }
        try transcript.consume(normal, sender: .host, deadline: deadline)
        state.lock()
        guard phase == .starting, !deadline.hasExpired else { state.unlock(); throw CustodyRecordError.fenced }
        continuation = transcript; phase = .normal
        continuationRunning = true; continuationGroup.enter()
        state.unlock()
        succeeded = true
        continuationQueue.async { [self] in
            defer {
                state.lock(); continuationRunning = false; state.unlock()
                continuationGroup.leave()
            }
            do {
                // The helper's committed-observation locals die before callback
                // and group leave, so a joined reader cannot retain lock aliases.
                try waitForStop()
                onStop()
            } catch {
                // EOF/timeout/rejection is never stop or rollback. Preserve
                // committed host/server ownership; no synthetic stopped frame.
            }
        }
    }
    private func waitForStop() throws {
        state.lock(); let context = committed; state.unlock()
        guard let context else { throw CustodyRecordError.fenced }
        // No second FrameReader or socket: inherit run's reader after all
        // synchronous handshake work has returned.
        let stop = try InstallationReadinessMessage.decode(reader.read(descriptor: endpoint.connection.value, deadline: deadline))
        guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
        try authenticateCoordinator(context)
        let recovery = try InstallationStartupTranscript.recovery(after: context.durable.control)
        _ = try CustodyCatalogStore.committedHostObservation(admission: lifecycle, expected: recovery, deadline: deadline, validationProfile: validationProfile)
        try context.slots.revalidate()
        try launcher.validateRetainedInstallation(recovery.state)
        try authenticateCoordinator(context)
        state.lock()
        do {
            guard phase == .normal, var transcript = continuation else { throw CustodyRecordError.fenced }
            try transcript.consume(stop, sender: .coordinator, deadline: deadline)
            continuation = transcript; stopControl = recovery; phase = .stopping
            state.unlock()
        } catch { state.unlock(); throw error }
    }
    private func prepareStopCompletion(_ value: HostControlServer, ownership: RetainedOwnership) throws {
        state.lock(); let context = committed, recovery = stopControl; state.unlock()
        guard let context, let recovery else { throw CustodyRecordError.fenced }
        try authenticateCoordinator(context)
        _ = try CustodyCatalogStore.committedHostObservation(admission: lifecycle, expected: recovery, deadline: deadline, validationProfile: validationProfile)
        try context.slots.revalidate()
        try launcher.validateRetainedInstallation(recovery.state)
        try value.stopAndJoin(staged: ownership, deadline: deadline)
        try context.slots.revalidate()
        try launcher.validateRetainedInstallation(recovery.state)
        try authenticateCoordinator(context)
    }
    private func applicationDrained(_ value: HostControlServer, ownership: RetainedOwnership) throws {
        state.lock(); let stopping = phase == .stopping; state.unlock()
        guard stopping else { return }
        guard continuationGroup.wait(timeout: DispatchTime(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success else {
            throw CustodyRecordError.busy
        }
        try prepareStopCompletion(value, ownership: ownership)
        state.lock()
        guard phase == .stopping, var transcript = continuation, let peer = committed?.peer else {
            state.unlock(); throw CustodyRecordError.fenced
        }
        let message: InstallationReadinessMessage
        do { message = try transcript.message(.stopped, deadline: deadline) }
        catch { state.unlock(); throw error }
        committed = nil; server = nil
        state.unlock()
        // No observation local or prepared alias spans this checked barrier.
        guard lifecycle.closeCommittedHostObservationBorrowing() == .succeeded,
              launcher.retireCommittedHostLauncher() == .succeeded,
              lifecycle.retireCommittedHostAdmission() == .succeeded else { throw CustodyRecordError.fenced }
        _ = try InstallationPrecommitTransport.authenticate(endpoint.connection, identity: coordinator,
            uid: control.state.directory.uid, original: peer)
        try HostControlIO.writeFrame(message.encode(), descriptor: endpoint.connection.value, deadline: deadline)
        try transcript.consume(message, sender: .host, deadline: deadline)
        state.lock(); continuation = transcript; phase = .stopped; state.unlock()
        close()
    }
    private static func observe(_ admission: LifecycleAdmissionAuthority, deadline: MonotonicDeadline,
                                validationProfile: InstallationValidationProfile = .production) throws -> InstallationControlRecord {
        while !deadline.hasExpired {
            do { return try CustodyCatalogStore.precommitWaitObservation(admission: admission, validationProfile: validationProfile) }
            catch CustodyRecordError.busy { Thread.sleep(forTimeInterval: 0.005) }
        }
        throw CustodyRecordError.busy
    }
    /// Retain the actual admission before launcher acquisition or readback can
    /// throw. This is construction custody only, never readiness or permission.
    private final class OpeningCustody {
        let lifecycle: LifecycleAdmissionAuthority
        var launcher: LauncherAuthority?
        private var retainedSelf: OpeningCustody?
        private var transferred = false
        init(_ lifecycle: LifecycleAdmissionAuthority) {
            self.lifecycle = lifecycle; retainedSelf = self
        }
        func transfer() { transferred = true; retainedSelf = nil }
        @discardableResult func closeBeforeTransfer() -> Bool {
            guard !transferred else { return false }
            guard lifecycle.closeCommittedHostObservationBorrowing() == .succeeded else { return false }
            if let launcher, launcher.retireCommittedHostLauncher() != .succeeded { return false }
            guard lifecycle.retireCommittedHostAdmission() == .succeeded else { return false }
            retainedSelf = nil
            return true
        }
    }
    static func openIfActive(deadline: MonotonicDeadline) throws -> InstallationPrecommitHost? {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        let paths = try InstallationPaths.production()
        guard Bundle.main.bundleURL.path == paths.app,
              try InstalledStateAdmission.invocationRole(arguments: ProcessInfo.processInfo.arguments) == .managedHost else {
            throw PublisherPolicyError.unavailable
        }
        let lifecycle = try LifecycleAdmissionAuthority.acquire(at: paths.state)
        let opening = OpeningCustody(lifecycle)
        do {
            guard try CustodyCatalogStore.requiresStagedHost(admission: lifecycle) else {
                // This is an explicit verified committed route, never a catch
                // from failed staged authentication. Normal admission rechecks.
                guard opening.closeBeforeTransfer() else { throw CustodyRecordError.fenced }
                return nil
            }
            return try open(lifecycle: lifecycle, opening: opening, paths: paths, deadline: deadline)
        } catch { opening.closeBeforeTransfer(); throw error }
    }
    static func open(deadline: MonotonicDeadline) throws -> InstallationPrecommitHost {
        // The caller supplies its ORIGINAL invocation budget, including any
        // pending kickstart. Never begin a five-second retry clock on arrival.
        // The coordinator independently shortens the sole stream at retirement.
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        let paths = try InstallationPaths.production()
        guard Bundle.main.bundleURL.path == paths.app,
              try InstalledStateAdmission.invocationRole(arguments: ProcessInfo.processInfo.arguments) == .managedHost else {
            throw PublisherPolicyError.unavailable
        }
        let lifecycle = try LifecycleAdmissionAuthority.acquire(at: paths.state)
        let opening = OpeningCustody(lifecycle)
        return try open(lifecycle: lifecycle, opening: opening, paths: paths, deadline: deadline)
    }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    static func openSignedFixture(_ parent: SignedInstallationFixtureHostChannel.Inherited,
                                  profile: InstallationValidationProfile) throws -> InstallationPrecommitHost {
        guard case let .signedFixture(retained) = profile, retained.hostParent === parent else { throw CustodyRecordError.fenced }
        try parent.revalidate(); try profile.revalidate()
        let paths = try InstallationPaths.isolated(root: parent.request.root)
        guard Bundle.main.bundleURL.path == paths.app,
              ProcessInfo.processInfo.arguments.count == 2,
              ProcessInfo.processInfo.arguments[1] == InstallationPaths.managedHostArgument else { throw CustodyRecordError.fenced }
        _ = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make(), expectedExecutablePath: paths.executable)
        let lifecycle = try LifecycleAdmissionAuthority.acquire(at: paths.state)
        let opening = OpeningCustody(lifecycle)
        return try open(lifecycle: lifecycle, opening: opening, paths: paths,
            deadline: .init(uptimeNanoseconds: parent.request.deadline), validationProfile: profile)
    }
    #endif
    private static func validateFixtureHostControl(_ control: InstallationControlRecord,
                                                   profile: InstallationValidationProfile) throws {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(retained) = profile {
            guard let parent = retained.hostParent else { throw CustodyRecordError.fenced }
            try parent.validate(control)
        }
        #endif
    }
    private static func open(lifecycle: LifecycleAdmissionAuthority, opening: OpeningCustody,
                             paths: InstallationPaths, deadline: MonotonicDeadline,
                             validationProfile: InstallationValidationProfile = .production) throws -> InstallationPrecommitHost {
        do {
            let launcher = try LauncherAuthority.acquireForReadiness(admission: lifecycle) { opening.launcher = $0 }
            let control = try observe(lifecycle, deadline: deadline, validationProfile: validationProfile)
            try validateFixtureHostControl(control, profile: validationProfile)
            let identities = try identities(paths: paths, control: control, validationProfile: validationProfile)
            let endpoint = try InstallationPrecommitHostEndpoint(admission: lifecycle, launcher: launcher,
                control: control, deadline: deadline)
            let result = Self(lifecycle: lifecycle, launcher: launcher, endpoint: endpoint, control: control,
                paths: paths, app: identities.0, coordinator: identities.1, deadline: deadline, validationProfile: validationProfile)
            opening.transfer()
            return try finishOpening(result)
        } catch { opening.closeBeforeTransfer(); throw error }
    }
    private static func finishOpening(_ result: InstallationPrecommitHost) throws -> InstallationPrecommitHost {
        do { try result.endpoint.connect(); try result.revalidate(); return result }
        catch { result.close(); throw error }
    }
    private static func identities(paths: InstallationPaths, control: InstallationControlRecord,
                                   validationProfile: InstallationValidationProfile = .production)
        throws -> (PublisherCodeVerifier.Identity, PublisherCodeVerifier.Identity) {
        guard let transaction = control.transaction, let candidate = transaction.candidate,
              transaction.boot == (try CustodyBootIdentity.current()) else { throw CustodyRecordError.fenced }
        try validationProfile.revalidate()
        let artifact = try validationProfile.inspectBundle(paths.app)
        let (_, app) = try PublisherCodeVerifier.runningApplication(path: paths.app)
        let (_, helper) = try PublisherCodeVerifier.verifiedStatic(path: paths.app + LifecyclePublisher.relativeExecutable,
            identifier: LifecyclePublisher.identifier, team: app.team)
        guard artifact.release == candidate.release, artifact.canonicalSHA256 == candidate.bundleDigest,
              app == (try InstallationPrecommitTransport.identity(candidate: candidate, coordinator: false, team: app.team, validationProfile: validationProfile)),
              helper == (try InstallationPrecommitTransport.identity(candidate: candidate, coordinator: true, team: app.team, validationProfile: validationProfile)),
              helper.team == transaction.coordinator.team, helper.identifier == transaction.coordinator.identifier else {
            throw PublisherPolicyError.unavailable
        }
        return (app, helper)
    }
    private func revalidate() throws {
        guard !deadline.hasExpired, lifecycle.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        try launcher.validateRetainedInstallation(control.state)
        let observed = try Self.observe(lifecycle, deadline: deadline, validationProfile: validationProfile)
        try InstallationPrecommitWait.validateSuccessor(observed, of: control, deadline: deadline)
        control = observed
        let identities = try Self.identities(paths: paths, control: control, validationProfile: validationProfile)
        guard identities.0 == app, identities.1 == coordinator else { throw PublisherPolicyError.unavailable }
        try endpoint.revalidate()
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
    }
    /// One live run; refusal closes all retained owners. Successful return
    /// transfers no locks yet: the privately minted admission must be taken once.
    func run() throws -> Admission {
        state.lock()
        guard phase == .fresh else { state.unlock(); throw CustodyRecordError.fenced }
        phase = .running; working = true; state.unlock()
        var returned = false
        defer { finishWork(success: returned) }
        try requireRunning(); try revalidate()
        let host = try ProcessIdentity.capture(processID: getpid(), generation: generation,
            expectedExecutablePath: paths.executable)
        let socket = endpoint.connection
        let original = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: nil)
        guard let transaction = control.transaction, let candidate = transaction.candidate,
              original.pid == pid_t(transaction.coordinator.process.pid) else { throw CustodyRecordError.fenced }
        let coordinatorProcess = try ProcessIdentity.capture(processID: original.pid,
            generation: transaction.coordinator.process.generation)
        guard coordinatorProcess.startSeconds == transaction.coordinator.process.startSeconds,
              coordinatorProcess.startMicroseconds == transaction.coordinator.process.startMicroseconds else { throw CustodyRecordError.fenced }
        // Pending kickstart grants only this authenticated readiness wait. No
        // hello/ready or normal admission is possible until exact completion.
        while control.step?.status == .intent {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
                uid: control.state.directory.uid, original: original)
            let observed: InstallationControlRecord
            do { observed = try CustodyCatalogStore.precommitWaitObservation(admission: lifecycle, validationProfile: validationProfile) }
            catch CustodyRecordError.busy { Thread.sleep(forTimeInterval: 0.005); continue }
            try InstallationPrecommitWait.validateSuccessor(observed, of: control, deadline: deadline)
            control = observed
            try revalidate()
            var item = pollfd(fd: socket.value, events: Int16(POLLIN), revents: 0)
            let n = poll(&item, 1, min(10, deadline.remainingMilliseconds))
            guard n >= 0 || errno == EINTR else { throw CustodyRecordError.persistence(errno) }
            // The coordinator sends nothing before hello. EOF, an unsolicited
            // byte, error or hangup before completion is never a retry signal.
            guard item.revents == 0 else { throw CustodyProtocolError.invalidSequence }
        }
        try revalidate()
        let hello = InstallationReadinessMessage(event: .hello, transactionID: transaction.id, boot: transaction.boot,
            controlRevision: control.revision, candidateReleaseDigest: candidate.release.releaseContractSHA256,
            stateBindingDigest: try control.state.digest(), hostGeneration: generation,
            sessionNonce: nonce, previousMessageDigest: nil)
        try InstallationPrecommitTranscript.validateHello(hello, control: control)
        var transcript = try InstallationPrecommitTranscript(hello: hello)
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        try revalidate()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        try HostControlIO.writeFrame(hello.encode(), descriptor: socket.value, deadline: deadline)
        try transcript.consume(hello, sender: .host, deadline: deadline)
        let challenge = try InstallationPrecommitTransport.readChallenge(reader: &reader,
            descriptor: socket.value, deadline: deadline)
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        try revalidate()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        try transcript.consume(challenge, sender: .coordinator, deadline: deadline)
        let ready = try transcript.message(.ready)
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        try revalidate()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        try HostControlIO.writeFrame(ready.encode(), descriptor: socket.value, deadline: deadline)
        try transcript.consume(ready, sender: .host, deadline: deadline)
        try requireRunning()
        guard let digest = transcript.completedDigest else { throw CustodyProtocolError.invalidSequence }
        let expected = try InstallationHostCommitBinding.expectedControl(after: control,
            host: InstallationProcessObservation(pid: UInt32(host.processID), uid: host.userID,
                startSeconds: host.startSeconds, startMicroseconds: host.startMicroseconds, generation: host.generation),
            transcriptDigest: digest, validationProfile: validationProfile)
        let commit = try InstallationReadinessMessage.decode(reader.read(descriptor: socket.value, deadline: deadline))
        guard !reader.hasBufferedBytes else { throw CustodyProtocolError.invalidSequence }
        try requireRunning()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        guard try ProcessIdentity.capture(processID: original.pid,
            generation: transaction.coordinator.process.generation) == coordinatorProcess else { throw CustodyRecordError.fenced }
        if commit.event == .stop {
            let recovery = try InstallationReadinessStopBinding.expectedControl(after: control, validationProfile: validationProfile)
            guard commit == (try InstallationReadinessStopBinding.stop(after: ready, control: recovery, deadline: deadline)) else {
                throw CustodyProtocolError.invalidSequence
            }
            try CustodyCatalogStore.readinessStopHostObservation(admission: lifecycle, expected: recovery, deadline: deadline, validationProfile: validationProfile)
            try endpoint.revalidate()
            try launcher.validateRetainedInstallation(control.state)
            _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
                uid: control.state.directory.uid, original: original)
            guard try ProcessIdentity.capture(processID: original.pid,
                generation: transaction.coordinator.process.generation) == coordinatorProcess else { throw CustodyRecordError.fenced }
            let acknowledgment = try InstallationReadinessStopBinding.stopped(after: commit, deadline: deadline)
            // No server, AppKit admission or command was created in this branch.
            // Retire observer aliases and both actual admission owners before
            // sending evidence. The retained stream is not an authority alias.
            guard endpoint.retireObservationResources() == .succeeded,
                  lifecycle.closeCommittedHostObservationBorrowing() == .succeeded,
                  launcher.retireCommittedHostLauncher() == .succeeded,
                  lifecycle.retireCommittedHostAdmission() == .succeeded else { throw CustodyRecordError.fenced }
            _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
                uid: control.state.directory.uid, original: original)
            try HostControlIO.writeFrame(acknowledgment.encode(), descriptor: socket.value, deadline: deadline)
            // Keep the original authenticated process alive until the peer has
            // checked the frame and closed its original stream. EOF here only
            // ends this exchange; it is never evidence of process death or
            // admission release (the checked releases above are that evidence).
            while true {
                try HostControlIO.wait(socket.value, events: Int16(POLLIN), deadline: deadline)
                var byte: UInt8 = 0
                let count = recv(socket.value, &byte, 1, MSG_DONTWAIT)
                if count == 0 { break }
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                throw CustodyProtocolError.invalidSequence
            }
            // Refuse normal startup even after the successful stopped frame.
            // finishWork closes this original stream and retains uncertain closes.
            throw Failure.readinessStopped
        }
        try InstallationHostCommitBinding.validateMessage(commit, ready: ready, committed: expected, deadline: deadline)
        let durable = try CustodyCatalogStore.committedHostObservation(admission: lifecycle,
            expected: expected, deadline: deadline, validationProfile: validationProfile)
        let slots = try InstallationCommittedHostSlots(paths: paths, control: durable.control, endpoint: endpoint, validationProfile: validationProfile)
        let context = CommittedContext(durable: durable, slots: slots, host: host, peer: original, message: commit)
        try validate(context)
        try endpoint.revalidate()
        _ = try InstallationPrecommitTransport.authenticate(socket, identity: coordinator,
            uid: control.state.directory.uid, original: original)
        guard try ProcessIdentity.capture(processID: original.pid,
            generation: transaction.coordinator.process.generation) == coordinatorProcess else { throw CustodyRecordError.fenced }
        try InstallationPrecommitTransport.requireQuiet(socket)
        try requireRunning()
        state.lock()
        guard phase == .running, !deadline.hasExpired else { state.unlock(); throw CustodyRecordError.fenced }
        committed = context; phase = .offered
        let result = Admission(owner: self); offered = ObjectIdentifier(result)
        returned = true
        state.unlock()
        return result
    }
}
