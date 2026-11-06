import Darwin
import Foundation

/// This observation is not an operation-completion or descendant-drain receipt.
public enum OwnedDirectChildObservation: Equatable, Sendable {
    case running
    case reaped(Int32)
    case ownershipFailure(Int32)
}

public enum OwnedDirectChildReapPolicy: Equatable, Sendable {
    case immediate
    case afterGroupDrain
}

/// Exclusive signal/reap custody transferred by the successful posix_spawn caller.
/// Never adopt a borrowed identity or a Foundation.Process-managed child here.
/// There must be no other reaper. Callers retain this owner and their authority
/// leases after an unresolved deadline; destruction does not manufacture cleanup.
public final class OwnedDirectChild: @unchecked Sendable {
    public let identity: ProcessIdentity
    private let mutex = NSLock()
    private var state = OwnedDirectChildObservation.running
    private let reapPolicy: OwnedDirectChildReapPolicy
    private let qualifiedGraph: QualifiedCommandGraph?
    private var preparedGraphObservation: ProcessIdentity?
    private var graphFault = false
    private var heldTerminalStatus: Int32?
    private var neverResumed: Bool
    private var bootstrapResumeClosed = false
    #if SHADOW_SYNC_TESTING
    private let testingObservationLock = NSLock()
    private var testingPollAttempt: OwnedDirectChildTestingPollAttempt?
    private var testingBarrier: OwnedDirectChildTestingBarrier?
    private var testingReapBarrier: OwnedDirectChildTestingBarrier?
    private var testingWaitErrors: [Int32] = []
    private var testingWaitCalls = 0
    private var testingSignalCalls = 0
    private var testingRuntimeResumeGate: ((() -> Bool) -> Bool)?
    private var testingRuntimeResumeBarrier: OwnedDirectChildTestingBarrier?
    private let testingOriginalSuspendedSpawn: Bool
    private var testingInjectedCustodyFailure = false
    #endif

    public convenience init(adoptingSpawnedChild processID: pid_t, identity: ProcessIdentity) throws {
        try self.init(processID: processID, identity: identity, reapPolicy: .immediate, neverResumed: false)
    }

    convenience init(transferringSuspendedSpawn proof: OwnedSpawnAnchor.Proof,
                     identity: ProcessIdentity, reapPolicy: OwnedDirectChildReapPolicy,
                     qualifiedGraph: QualifiedCommandGraph? = nil) throws {
        try self.init(processID: proof.processID, identity: identity, reapPolicy: reapPolicy,
                      neverResumed: true, qualifiedGraph: qualifiedGraph)
    }

    private init(processID: pid_t, identity: ProcessIdentity,
                 reapPolicy: OwnedDirectChildReapPolicy, neverResumed: Bool,
                 qualifiedGraph: QualifiedCommandGraph? = nil) throws {
        guard processID > 1, processID != getpid(),
              identity.processID == processID,
              identity.processGroupID == processID,
              identity.userID == geteuid(),
              identity.isCurrent(expectedGeneration: identity.generation),
              qualifiedGraph.map({ neverResumed && $0.entryPath == identity.executablePath }) ?? true else {
            throw ProcessOwnershipError.identityMismatch
        }
        var info = proc_bsdinfo()
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info,
                          Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_pid == UInt32(processID), info.pbi_ppid == UInt32(getpid()),
              info.pbi_uid == geteuid(),
              UInt64(info.pbi_start_tvsec) == identity.startSeconds,
              UInt64(info.pbi_start_tvusec) == identity.startMicroseconds else {
            throw ProcessOwnershipError.identityMismatch
        }
        self.identity = identity
        self.reapPolicy = reapPolicy
        self.qualifiedGraph = qualifiedGraph
        self.neverResumed = neverResumed
        #if SHADOW_SYNC_TESTING
        self.testingOriginalSuspendedSpawn = neverResumed
        #endif
    }

    public var observation: OwnedDirectChildObservation {
        mutex.lock()
        defer { mutex.unlock() }
        return state
    }

    /// Observation of this owner's actual suspended spawn, not a caller assertion.
    /// No wait or signal occurs here, and a successful resume permanently excludes it.
    var neverResumedReapedStatus: Int32? {
        mutex.lock(); defer { mutex.unlock() }
        guard neverResumed, case .reaped(let status) = state else { return nil }
        return status
    }

    /// Never blocks while holding the ownership mutex.
    @discardableResult public func poll() -> OwnedDirectChildObservation {
        lockForWait()
        defer { mutex.unlock() }
        guard state == .running else { return state }
        if reapPolicy == .afterGroupDrain && !neverResumed {
            observeTerminalLocked()
            // "running" means custody is unresolved, including terminal-held.
            // Only reapAfterGroupDrain may release this anchor.
            return state
        }
        return reapLocked()
    }

    private func lockForWait() {
        #if SHADOW_SYNC_TESTING
        testingObservationLock.lock()
        let attempt = testingPollAttempt
        testingPollAttempt = nil
        testingObservationLock.unlock()
        // The probe establishes an actual failed try-lock, not elapsed time.
        // Release the instrumentation lock before entering ownership exclusion.
        let alreadyLocked = attempt != nil && mutex.try()
        attempt?.record(contended: !alreadyLocked)
        if !alreadyLocked { mutex.lock() }
        #else
        mutex.lock()
        #endif
    }

    private func reapLocked() -> OwnedDirectChildObservation {
        var status: Int32 = 0
        let waited: pid_t
        let error: Int32
        #if SHADOW_SYNC_TESTING
        if !testingWaitErrors.isEmpty {
            waited = -1
            error = testingWaitErrors.removeFirst()
            if error == ECHILD { testingInjectedCustodyFailure = true }
        } else {
            testingWaitCalls += 1
            waited = waitpid(identity.processID, &status, WNOHANG)
            error = errno
        }
        #else
        waited = waitpid(identity.processID, &status, WNOHANG)
        error = errno
        #endif
        if waited == identity.processID {
            let exited = (status & 0x7F) == 0
            let signaled = (status & 0x7F) > 0 && (status & 0x7F) < 0x7F
            state = (exited || signaled) && (heldTerminalStatus == nil || heldTerminalStatus == status)
                ? .reaped(status) : .ownershipFailure(EPROTO)
        } else if waited < 0 && error != EINTR {
            state = .ownershipFailure(error)
        } else if waited != 0 && !(waited < 0 && error == EINTR) {
            state = .ownershipFailure(EPROTO)
        }
        return state
    }

    /// WNOWAIT proves terminal ownership without releasing the PID/group anchor.
    private func observeTerminalLocked() {
        guard state == .running else { return }
        var info = siginfo_t()
        let result: Int32
        let error: Int32
        #if SHADOW_SYNC_TESTING
        if !testingWaitErrors.isEmpty {
            result = -1; error = testingWaitErrors.removeFirst()
            if error == ECHILD { testingInjectedCustodyFailure = true }
        } else {
            testingWaitCalls += 1
            result = waitid(P_PID, id_t(identity.processID), &info, WEXITED | WNOHANG | WNOWAIT)
            error = errno
        }
        #else
        result = waitid(P_PID, id_t(identity.processID), &info, WEXITED | WNOHANG | WNOWAIT)
        error = errno
        #endif
        if result < 0 {
            if error != EINTR { state = .ownershipFailure(error) }
            return
        }
        guard result == 0 else { state = .ownershipFailure(EPROTO); return }
        if info.si_pid == 0 {
            if heldTerminalStatus != nil { state = .ownershipFailure(EPROTO) }
            return
        }
        guard info.si_pid == identity.processID else { state = .ownershipFailure(EPROTO); return }
        let raw: Int32
        if info.si_code == CLD_EXITED && (0...255).contains(info.si_status) {
            raw = info.si_status << 8
        } else if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED)
                    && info.si_status > 0 && info.si_status < 0x7f {
            raw = info.si_status | (info.si_code == CLD_DUMPED ? 0x80 : 0)
        } else { state = .ownershipFailure(EPROTO); return }
        if let heldTerminalStatus, heldTerminalStatus != raw {
            state = .ownershipFailure(EPROTO)
        } else { heldTerminalStatus = raw }
    }

    /// Observation only; not permission to signal and not a cleanup receipt.
    public var terminalStatusHeld: Int32? {
        mutex.lock(); defer { mutex.unlock() }; return heldTerminalStatus
    }

    /// The custodian supplies actual stream-drain evidence. The group check and
    /// sole terminal reap share signal exclusion and retain custody on uncertainty.
    @discardableResult public func reapAfterGroupDrain(streamsDrained: Bool) -> OwnedDirectChildObservation {
        lockForWait(); defer { mutex.unlock() }
        guard state == .running else { return state }
        guard reapPolicy == .afterGroupDrain else { return state }
        // Successful suspended spawn proves that no target code or descendant
        // ran. Do not ask waitid for a terminal-only event while still suspended:
        // Darwin can report its initial CLD_STOPPED event even without WSTOPPED.
        if neverResumed { return reapLocked() }
        observeTerminalLocked()
        guard state == .running, heldTerminalStatus != nil, streamsDrained,
              OwnedProcessGroupSnapshot.capture(anchor: identity.processID) == .onlyAnchor else { return state }
        return reapLocked()
    }

    /// Final identity validation, syscall and waitpid share the same mutex.
    /// A refused/failed signal is never evidence that a child has exited.
    @discardableResult public func send(_ signal: Int32) -> Bool { send(signal, before: nil) }

    func resume(before deadline: MonotonicDeadline) -> Bool { send(SIGCONT, before: deadline) }

    var hasGraphFault: Bool { mutex.lock(); defer { mutex.unlock() }; return graphFault }
    var graphRetirementPermitted: Bool { mutex.lock(); defer { mutex.unlock() }; return !graphFault || neverResumed }

    /// Complete expensive work before the caller's final control/deadline gate.
    /// Each successful preparation is single-use; send does only bounded kernel
    /// identity checks under signal/reap exclusion. The graph is immutable.
    enum GraphSignalPreparation { case ready, retry, refused }
    @discardableResult func prepareGraphSignal() -> GraphSignalPreparation {
        guard let graph = qualifiedGraph else { return .ready }
        mutex.lock()
        preparedGraphObservation = nil
        if reapPolicy == .afterGroupDrain && !neverResumed { observeTerminalLocked() }
        let allowed = state == .running && !graphFault
        let terminal = heldTerminalStatus != nil
        mutex.unlock()
        guard allowed else { return .refused }
        if terminal { return .ready }
        var observation = graph.observe(original: identity)
        // Polling cannot require every intermediate exec image to be observed.
        // Retry only an observed image race inside this same bounded preparation.
        for _ in 0..<2 {
            guard case .transition = observation else { break }
            observation = graph.observe(original: identity)
        }
        mutex.lock(); defer { mutex.unlock() }
        guard state == .running, !graphFault else { return .refused }
        switch observation {
        case .validated(let current):
            preparedGraphObservation = current; return .ready
        case .transition:
            return .retry
        case .noLiveImage:
            if reapPolicy == .afterGroupDrain && !neverResumed { observeTerminalLocked() }
            if state == .running && heldTerminalStatus != nil { return .ready }
            graphFault = true; return .refused
        case .rejected:
            graphFault = true; return .refused
        }
    }

    private func send(_ signal: Int32, before deadline: MonotonicDeadline?) -> Bool {
        guard signal == SIGCONT || signal == SIGTERM || signal == SIGKILL else { return false }
        mutex.lock()
        defer { mutex.unlock() }
        let graphObservation = preparedGraphObservation
        preparedGraphObservation = nil
        guard state == .running else { return false }
        if neverResumed {
            if signal == SIGKILL {
                // Cancellation closes admission even if the signal fails. The
                // successful-spawn proof permits only this positive child PID.
                bootstrapResumeClosed = true
                guard reapLocked() == .running else { return false }
                return kill(identity.processID, SIGKILL) == 0
            }
            guard signal == SIGCONT, !bootstrapResumeClosed,
                  identity.isCurrent(expectedGeneration: identity.generation),
                  !graphFault, qualifiedGraph == nil || graphObservation == identity else { return false }
            #if SHADOW_SYNC_TESTING
            if let barrier = testingRuntimeResumeBarrier {
                testingRuntimeResumeBarrier = nil
                guard barrier.pause() else { return false }
            }
            #endif
            guard resumeSignalLocked(before: deadline) else { return false }
            neverResumed = false
            return true
        }
        if reapPolicy == .afterGroupDrain {
            observeTerminalLocked()
            guard state == .running else { return false }
        }
        guard !graphFault else { return false }
        if heldTerminalStatus != nil {
            guard signal != SIGCONT else { return false }
        } else {
            if let graph = qualifiedGraph {
                guard let observed = graphObservation else { return false }
                guard observed.sameOriginalChild(as: identity), observed.isCurrent(expectedGeneration: identity.generation) else {
                    let current = try? ProcessIdentity.capture(processID: identity.processID, generation: identity.generation)
                    if let current, current.sameOriginalChild(as: identity),
                       current.executablePath != observed.executablePath, graph.permitsImagePath(current.executablePath) {
                        // Known exec race: retain custody, do not signal from a
                        // stale token, and let the caller revalidate outside the
                        // mutex under its original absolute budget.
                        return false
                    }
                    if current == nil && reapPolicy == .afterGroupDrain {
                        observeTerminalLocked()
                        if state == .running && heldTerminalStatus != nil { return false }
                    }
                    graphFault = true
                    return false
                }
            } else {
                guard identity.isCurrent(expectedGeneration: identity.generation) else { return false }
            }
        }
        #if SHADOW_SYNC_TESTING
        if let barrier = testingBarrier {
            testingBarrier = nil
            guard barrier.pause() else { return false }
        }
        if signal != SIGCONT { testingSignalCalls += 1 }
        #endif
        if signal == SIGCONT { return resumeSignalLocked(before: deadline) }
        return kill(-identity.processGroupID, signal) == 0
    }

    private func resumeSignalLocked(before deadline: MonotonicDeadline?) -> Bool {
        #if SHADOW_SYNC_TESTING
        if let gate = testingRuntimeResumeGate {
            return gate {
                guard deadline?.hasExpired != true else { return false }
                if !self.neverResumed { self.testingSignalCalls += 1 }
                return kill(-self.identity.processGroupID, SIGCONT) == 0
            }
        }
        // Existing tests historically counted resumed signals, not bootstrap.
        if !neverResumed { testingSignalCalls += 1 }
        #endif
        guard deadline?.hasExpired != true else { return false }
        return kill(-identity.processGroupID, SIGCONT) == 0
    }

    /// A timeout preserves live custody. It never clears the owner or its leases.
    public func wait(timeout: TimeInterval) throws -> OwnedDirectChildObservation {
        guard timeout.isFinite, timeout >= 0, timeout <= 300 else {
            throw ProcessOwnershipError.invalidRegistration
        }
        let deadline = MonotonicDeadline(seconds: timeout)
        while true {
            let result = poll()
            guard result == .running, !deadline.hasExpired else { return result }
            usleep(useconds_t(min(deadline.remainingMilliseconds, 10)) * 1_000)
        }
    }

    #if SHADOW_SYNC_TESTING
    func testingRestoreOriginalGraphObservation() {
        mutex.lock(); defer { mutex.unlock() }
        precondition(qualifiedGraph != nil && state == .running && !graphFault)
        preparedGraphObservation = identity
    }
    func testingRejectQualifiedGraphObservation() {
        mutex.lock(); defer { mutex.unlock() }
        precondition(qualifiedGraph != nil && state == .running)
        graphFault = true; preparedGraphObservation = nil
    }
    /// Exercise the external verified-signal API while retaining this fixture's
    /// original signal/reap exclusion. The assertion cannot outlive its owner.
    func testingSendVerified(_ signal: Int32, identity candidate: ProcessIdentity,
                             expectedGeneration: String) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard state == .running, !neverResumed, candidate == identity,
              signal == SIGTERM || signal == SIGKILL else { return false }
        return OwnedProcessSignal.send(signal, to: candidate, expectedGeneration: expectedGeneration)
    }
    func testingInstallRuntimeResumeGate(_ gate: @escaping (() -> Bool) -> Bool) {
        mutex.lock(); defer { mutex.unlock() }
        testingRuntimeResumeGate = gate
    }
    func testingPauseRuntimeResume(_ barrier: OwnedDirectChildTestingBarrier) {
        mutex.lock(); testingRuntimeResumeBarrier = barrier; mutex.unlock()
    }
    /// No additional reaper: these are the same synchronized production-owner
    /// methods used by the assertions. Captured-stream fixtures provide their
    /// actual drain state; null/inherited suite streams have no private buffer.
    func testingRuntimeStep(_ directive: RuntimeFixtureCustody.Directive,
                            streamsDrained: Bool,
                            cooperativeStop: (@Sendable () -> Void)? = nil) -> RuntimeFixtureCustody.ChildState {
        if directive.reason != nil {
            testingRecoverInjectedOriginal()
            _ = prepareGraphSignal()
            if neverResumedSnapshot { _ = send(SIGKILL) }
            else if let cooperativeStop { cooperativeStop() }
            else { _ = send(directive.escalate ? SIGKILL : SIGTERM) }
            if reapPolicy == .afterGroupDrain { _ = reapAfterGroupDrain(streamsDrained: streamsDrained) }
            else { _ = poll() }
        }
        switch observation {
        case .running: return .retained
        case .ownershipFailure: return .ownershipFailure
        case .reaped:
            // Observation only after releasing the original PID anchor. A
            // present/reused group is never signalled by this cleanup path.
            return kill(-identity.processGroupID, 0) == -1 && errno == ESRCH && streamsDrained
                ? .reaped : .retained
        }
    }
    /// Fixture-only fallback for an actually injected ECHILD. Normal owner
    /// methods stay closed after failure. This original suspended spawn's
    /// exclusion still protects its one actual child; no PID can be supplied.
    /// Resumed recovery is limited to the two fixed descendant-free fixtures.
    private func testingRecoverInjectedOriginal() {
        mutex.lock(); defer { mutex.unlock() }
        guard testingOriginalSuspendedSpawn, testingInjectedCustodyFailure,
              state == .ownershipFailure(ECHILD),
              neverResumed || identity.executablePath == "/bin/sleep" || identity.executablePath == "/bin/cat" else { return }
        var status: Int32 = 0
        let result = waitpid(identity.processID, &status, WNOHANG)
        let error = errno
        if result == identity.processID {
            let terminal = status & 0x7f
            if (terminal == 0 || (terminal > 0 && terminal < 0x7f))
                && (heldTerminalStatus == nil || heldTerminalStatus == status) {
                state = .reaped(status)
                testingInjectedCustodyFailure = false
            }
        } else if result == 0 {
            // The positive-child wait proved this original unreaped child is
            // still owned. No process-table lookup or group adoption is used.
            bootstrapResumeClosed = true
            _ = kill(identity.processID, SIGKILL)
        } else if result < 0 && error != EINTR {
            // A real ECHILD/observer failure is not a cleanup receipt.
            testingInjectedCustodyFailure = false
        }
    }
    private var neverResumedSnapshot: Bool {
        mutex.lock(); defer { mutex.unlock() }; return neverResumed
    }
    public func testingObserveNextPoll(_ attempt: OwnedDirectChildTestingPollAttempt) {
        testingObservationLock.lock()
        testingPollAttempt = attempt
        testingObservationLock.unlock()
    }

    var testingSuspendedSpawnHasResumed: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return testingOriginalSuspendedSpawn && !neverResumed
    }
    public func testingPauseNextSignal(_ barrier: OwnedDirectChildTestingBarrier) {
        mutex.lock(); testingBarrier = barrier; mutex.unlock()
    }

    public func testingPauseNextReap(_ barrier: OwnedDirectChildTestingBarrier) {
        mutex.lock(); testingReapBarrier = barrier; mutex.unlock()
    }

    /// Runs before the runner attempts poll, with no ownership mutex held.
    public func testingBeforeReap() {
        mutex.lock()
        let barrier = testingReapBarrier
        testingReapBarrier = nil
        mutex.unlock()
        _ = barrier?.pause()
    }

    public func testingInjectWaitErrors(_ errors: [Int32]) {
        precondition(errors.allSatisfy { $0 == EINTR || $0 == ECHILD })
        mutex.lock(); testingWaitErrors = errors; mutex.unlock()
    }

    public var testingSignalSystemCallCount: Int {
        mutex.lock(); defer { mutex.unlock() }; return testingSignalCalls
    }

    public var testingWaitSystemCallCount: Int {
        mutex.lock(); defer { mutex.unlock() }; return testingWaitCalls
    }
    #endif
}


/// Group membership is not ancestry. This is valid only with a still-unreaped
/// leader and a separately qualified non-detaching command graph.
enum OwnedProcessGroupSnapshot: Equatable, Sendable {
    case onlyAnchor
    case otherMembers(Int)
    case unavailable

    static let maximumPIDs = 4_096

    static func capture(anchor: pid_t) -> Self {
        guard anchor > 1 else { return .unavailable }
        let width = MemoryLayout<pid_t>.stride
        errno = 0
        let estimate = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(anchor), nil, 0)
        guard var capacity = initialCapacity(estimatedBytes: estimate, error: errno) else { return .unavailable }
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let written = pids.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(anchor), $0.baseAddress, Int32($0.count))
            }
            let error = errno
            if error != 0 || written <= 0 { return .unavailable }
            if Int(written) >= capacity * width {
                guard capacity < maximumPIDs else { return .unavailable }
                capacity = min(maximumPIDs, capacity * 2)
                continue
            }
            return validate(anchor: anchor, storage: pids, bytesWritten: Int(written), error: error)
        }
        return .unavailable
    }

    /// Darwin's nil-buffer estimate is system-wide, not filtered to this group.
    /// It bounds allocation only. Fullness of the actual group result decides
    /// whether the observation is complete.
    static func initialCapacity(estimatedBytes: Int32, error: Int32) -> Int? {
        let width = MemoryLayout<pid_t>.stride
        guard error == 0, estimatedBytes > 0, Int(estimatedBytes) % width == 0 else { return nil }
        return min(maximumPIDs, max(32, Int(estimatedBytes) / width + 16))
    }

    /// Closed kernel-result validation; no zero/error/absence is treated as clean.
    static func validate(anchor: pid_t, storage: [pid_t], bytesWritten: Int, error: Int32) -> Self {
        let width = MemoryLayout<pid_t>.stride
        guard anchor > 1, error == 0, bytesWritten > 0,
              bytesWritten % width == 0, !storage.isEmpty, storage.count <= maximumPIDs,
              bytesWritten < storage.count * width else { return .unavailable }
        let members = Array(storage.prefix(bytesWritten / width))
        guard members.allSatisfy({ $0 > 1 }), Set(members).count == members.count,
              members.contains(anchor) else { return .unavailable }
        return members.count == 1 ? .onlyAnchor : .otherMembers(members.count - 1)
    }
}

#if SHADOW_SYNC_TESTING
/// One-use observation of the poller's actual ownership-lock attempt.
public final class OwnedDirectChildTestingPollAttempt: @unchecked Sendable {
    private let observed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var contended = false
    public init() {}
    fileprivate func record(contended: Bool) {
        lock.lock(); self.contended = contended; lock.unlock()
        observed.signal()
    }
    public func waitUntilContended() -> Bool {
        guard observed.wait(timeout: .now() + 3) == .success else { return false }
        lock.lock(); defer { lock.unlock() }; return contended
    }
}

/// A concrete test barrier, never an arbitrary callback inside the mutex.
public final class OwnedDirectChildTestingBarrier: @unchecked Sendable {
    private let pauseTimeout: TimeInterval
    public init(pauseTimeout: TimeInterval = 3) {
        precondition(pauseTimeout.isFinite && pauseTimeout > 0 && pauseTimeout <= 30)
        self.pauseTimeout = pauseTimeout
    }
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    fileprivate func pause() -> Bool {
        entered.signal()
        return proceed.wait(timeout: .now() + pauseTimeout) == .success
    }
    public func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    public func release() { proceed.signal() }
}
#endif
