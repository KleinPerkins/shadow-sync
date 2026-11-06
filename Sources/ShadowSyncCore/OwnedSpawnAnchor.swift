import Darwin
import Foundation

/// Observation of the original suspended spawn, not a command-completion receipt.
enum OwnedSpawnObservation: Equatable, Sendable {
    case suspended
    case transferred
    case reaped(Int32)
    case ownershipFailure(Int32)
}

/// Created only around this type's successful suspended posix_spawn. It owns the
/// child before identity/publisher capture can fail. There is no PID-adoption API.
/// A caller must retain the anchor (and its authority) through unresolved cleanup.
final class OwnedSpawnAnchor: @unchecked Sendable {
    /// Constructible only by this successful spawn's one-shot transfer. A raw
    /// PID/identity cannot select the never-resumed child cleanup path.
    struct Proof {
        let processID: pid_t
        fileprivate init(processID: pid_t) { self.processID = processID }
    }
    struct UnexecutedProof {
        let identity: ProcessIdentity?
        let waitStatus: Int32
        fileprivate init(identity: ProcessIdentity?, waitStatus: Int32) {
            self.identity = identity; self.waitStatus = waitStatus
        }
    }
    /// The anchor or its sole transferred owner must have actually reaped this
    /// never-resumed spawn. Neither a decoded PID nor a boolean is accepted.
    func unexecutedProof() -> UnexecutedProof? {
        mutex.lock(); defer { mutex.unlock() }
        switch state {
        case .reaped(let status): return UnexecutedProof(identity: nil, waitStatus: status)
        case .transferred:
            guard let owner = transferredOwner, let status = owner.neverResumedReapedStatus else { return nil }
            return UnexecutedProof(identity: owner.identity, waitStatus: status)
        default: return nil
        }
    }
    let processID: pid_t
    private let mutex = NSLock()
    private var state = OwnedSpawnObservation.suspended
    private var transferredOwner: OwnedDirectChild?
    #if SHADOW_SYNC_TESTING
    private var testingRuntimeResumeGate: ((() -> Bool) -> Bool)?
    private var testingRuntimeDrainRequest: (() -> Void)?
    private var testingRuntimeRetirement: (() -> Bool)?
    #endif

    private init(processID: pid_t) {
        self.processID = processID
        if processID <= 1 || processID == getpid() { state = .ownershipFailure(EPROTO) }
    }

    static func spawn(
        executable: String,
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?,
        arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) throws -> OwnedSpawnAnchor {
        var flags: Int16 = 0
        var group: pid_t = -1
        let required = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        let allowed = required | Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard actions != nil, attributes != nil, arguments != nil, environment != nil, !executable.isEmpty,
              posix_spawnattr_getflags(&attributes, &flags) == 0,
              posix_spawnattr_getpgroup(&attributes, &group) == 0,
              flags & required == required, flags & ~allowed == 0, group == 0 else {
            throw ProcessOwnershipError.invalidRegistration
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, arguments, environment)
        guard result == 0 else { throw SecureStateError.systemCall("suspended spawn", result) }
        // No fallible identity query or publication occurs before custody exists.
        return OwnedSpawnAnchor(processID: pid)
    }

    var observation: OwnedSpawnObservation {
        mutex.lock(); defer { mutex.unlock() }; return state
    }

    /// Identity capture/adoption and transfer are one ownership transition. A
    /// failed validation leaves this anchor responsible for the suspended child.
    func transfer(expectedExecutable: String, generation: String,
                  reapPolicy: OwnedDirectChildReapPolicy = .immediate,
                  qualifiedGraph: QualifiedCommandGraph? = nil) throws -> OwnedDirectChild {
        mutex.lock(); defer { mutex.unlock() }
        guard state == .suspended else { throw ProcessOwnershipError.invalidRegistration }
        let identity = try ProcessIdentity.capture(processID: processID,
            generation: generation, expectedExecutablePath: expectedExecutable)
        let owner = try OwnedDirectChild(transferringSuspendedSpawn: Proof(processID: processID),
                                        identity: identity, reapPolicy: reapPolicy, qualifiedGraph: qualifiedGraph)
        #if SHADOW_SYNC_TESTING
        if let gate = testingRuntimeResumeGate { owner.testingInstallRuntimeResumeGate(gate) }
        #endif
        transferredOwner = owner
        state = .transferred
        return owner
    }

    /// The sole pre-identity signal: positive exact child, never a process group,
    /// and only while this successful spawn has never been resumed/transferred.
    @discardableResult func killSuspended() -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard state == .suspended, processID > 1, processID != getpid() else { return false }
        guard pollLocked() == .suspended else { return false }
        return kill(processID, SIGKILL) == 0
    }

    @discardableResult func poll() -> OwnedSpawnObservation {
        mutex.lock(); defer { mutex.unlock() }; return pollLocked()
    }

    private func pollLocked() -> OwnedSpawnObservation {
        guard state == .suspended else { return state }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        let error = errno
        if result == processID {
            let signal = status & 0x7f
            state = signal == 0 || (signal > 0 && signal < 0x7f)
                ? .reaped(status) : .ownershipFailure(EPROTO)
        } else if result < 0 && error != EINTR {
            state = .ownershipFailure(error)
        } else if result != 0 && !(result < 0 && error == EINTR) {
            state = .ownershipFailure(EPROTO)
        }
        return state
    }

    func wait(timeout: TimeInterval) throws -> OwnedSpawnObservation {
        guard timeout.isFinite, timeout >= 0, timeout <= 300 else {
            throw ProcessOwnershipError.invalidRegistration
        }
        let deadline = MonotonicDeadline(seconds: timeout)
        while true {
            let result = poll()
            guard result == .suspended, !deadline.hasExpired else { return result }
            usleep(useconds_t(min(deadline.remainingMilliseconds, 10)) * 1_000)
        }
    }
    #if SHADOW_SYNC_TESTING
    /// Called exactly once before a newly created original spawn is published.
    func testingInstallRuntimeResumeGate(_ gate: @escaping (() -> Bool) -> Bool,
                                        requestDrain: @escaping () -> Void,
                                        retired: @escaping () -> Bool) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard state == .suspended, testingRuntimeResumeGate == nil else { return false }
        testingRuntimeResumeGate = gate
        testingRuntimeDrainRequest = requestDrain
        testingRuntimeRetirement = retired
        return true
    }
    func testingRequestRuntimeDrain() {
        mutex.lock(); let request = testingRuntimeDrainRequest; mutex.unlock()
        request?()
    }
    var testingRuntimeRetired: Bool {
        mutex.lock(); let retired = testingRuntimeRetirement; mutex.unlock()
        return retired?() ?? false
    }
    func testingRuntimeStep(_ directive: RuntimeFixtureCustody.Directive,
                            streamsDrained: Bool,
                            cooperativeStop: (@Sendable () -> Void)? = nil) -> RuntimeFixtureCustody.ChildState {
        mutex.lock()
        let owner = transferredOwner
        if owner == nil {
            if directive.reason != nil && state == .suspended {
                // Successful original, untransferred and never resumed. Keep
                // signal plus sole wait inside the original anchor's mutex.
                if pollLocked() == .suspended { _ = kill(processID, SIGKILL); _ = pollLocked() }
            }
            let result = state
            mutex.unlock()
            switch result {
            case .reaped: return .reaped
            case .ownershipFailure: return .ownershipFailure
            default: return .retained
            }
        }
        mutex.unlock()
        // Never hold the anchor mutex while the transferred owner might pause.
        return owner!.testingRuntimeStep(directive, streamsDrained: streamsDrained, cooperativeStop: cooperativeStop)
    }
    #endif
}
