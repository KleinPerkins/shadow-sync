import Darwin
import Foundation

/// Closed classifications only: never format a caught error or private path.
enum InstallationFailure: Error, Equatable, Sendable {
    case cancelled, deadline, policy, custody, other
    static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is PublisherPolicyError || error is HostPolicyBindingError { return .policy }
        if error is CustodyRecordError { return .custody }
        return .other
    }
}

/// Latch only. No authority work, callbacks or I/O occurs under this mutex.
final class InstallationCancellationGate: @unchecked Sendable {
    private let mutex = NSLock()
    private var requested = false
    func request() { mutex.lock(); requested = true; mutex.unlock() }
    func check() throws {
        mutex.lock(); let refused = requested; mutex.unlock()
        if refused { throw InstallationFailure.cancelled }
    }
}

/// A one-shot notice is observation, never terminal or cleanup authority. The
/// cell/session holds only this ticket; its callback weakly names the lifetime.
final class InstallationObservationSubscription: @unchecked Sendable {
    private let mutex = NSLock()
    private var observer: (@Sendable () -> Void)?
    private let queue: DispatchQueue
    init(on queue: DispatchQueue, observer: @escaping @Sendable () -> Void) {
        self.queue = queue; self.observer = observer
    }
    func publish() {
        mutex.lock(); let callback = observer; observer = nil; mutex.unlock()
        if let callback { queue.async(execute: callback) }
    }
    func cancel() { mutex.lock(); observer = nil; mutex.unlock() }
}

final class FreshInstallationAttempt: @unchecked Sendable {
    enum Phase: String, CaseIterable {
        case unstarted, reserve, exclusive, transfer, journal, readiness, bootstrap, kickstart
        case ready, commit, normalStartup, cleanup, finish, installed, failed
    }
    enum Update {
        case failedBeforeReserve(CoordinatorExitPermit, InstallationFailure)
        case installed(FreshInstallationExitReceipt)
        case failedSettled(FreshInstallationExitReceipt, InstallationFailure)
        case retained(InstallationFailure, Phase)
    }
    let bootstrap: InstallationBootstrap
    let deadline: MonotonicDeadline
    private(set) var phase: Phase = .unstarted
    private(set) var firstFailure: InstallationFailure?
    private(set) var failedPhase: Phase?
    private var started = false
    #if SHADOW_SYNC_TESTING
    var testingBeforePhase: ((Phase) throws -> Void)?
    private(set) var testingTrace: [Phase] = []
    #endif
    private init(bootstrap: InstallationBootstrap, deadline: MonotonicDeadline) {
        self.bootstrap = bootstrap; self.deadline = deadline
    }
    static func production(deadline: MonotonicDeadline) throws -> FreshInstallationAttempt {
        let admission = try CoordinatorInstallationAdmission.current()
        let bootstrap = try InstallationBootstrap.production(admission: admission)
        return FreshInstallationAttempt(bootstrap: bootstrap, deadline: deadline)
    }
    #if SHADOW_SYNC_TESTING
    /// Real fixture owners only; this cannot mint the production admission.
    static func testing(bootstrap: InstallationBootstrap, deadline: MonotonicDeadline) -> FreshInstallationAttempt {
        FreshInstallationAttempt(bootstrap: bootstrap, deadline: deadline)
    }
    #endif
    func requestCancellation() { bootstrap.cancellationGate.request() }
    /// Called only by the original serialized invocation. Each case claims its
    /// phase before invoking a lower-level one-use transition. No action list.
    func runOnce() -> Update {
        guard !started else { return .retained(firstFailure ?? .custody, failedPhase ?? phase) }
        started = true
        do {
            try bootstrap.cancellationGate.check()
            guard !deadline.hasExpired else { throw InstallationFailure.deadline }
            phase = .reserve
            while true {
                #if SHADOW_SYNC_TESTING
                testingTrace.append(phase)
                try testingBeforePhase?(phase)
                #endif
                switch phase {
                case .reserve:
                    try bootstrap.reserve(deadline: deadline); phase = .exclusive
                case .exclusive:
                    try bootstrap.prepareExclusive(); phase = .transfer
                case .transfer:
                    try bootstrap.transferToStagedAdmission(); phase = .journal
                case .journal:
                    try bootstrap.continueStagedJournal(); phase = .readiness
                case .readiness:
                    try bootstrap.openStagedReadiness(); phase = .bootstrap
                case .bootstrap:
                    try bootstrap.bootstrapCandidate(); phase = .kickstart
                case .kickstart:
                    try bootstrap.kickstartCandidate(); phase = .ready
                case .ready:
                    try bootstrap.confirmCandidateReady(); phase = .commit
                case .commit:
                    // External refusal leaves the narrow completed-ready stop
                    // eligible; a failure inside commit remains failed-closed.
                    try bootstrap.checkOriginalForwardAdmission()
                    try bootstrap.commitCandidateReadiness(); phase = .normalStartup
                case .normalStartup:
                    try bootstrap.observeNormalStartup(); phase = .cleanup
                case .cleanup:
                    try bootstrap.cancellationGate.check()
                    try bootstrap.cleanupReadinessCoordination(); phase = .finish
                case .finish:
                    try bootstrap.cancellationGate.check()
                    let receipt = try bootstrap.finishFreshInstallation()
                    // Terminal descriptions are retired: never revalidate them.
                    // Cancellation observed during final closure is still failed,
                    // but this actual receipt authorizes a nonzero settled exit.
                    do { try bootstrap.cancellationGate.check() }
                    catch {
                        firstFailure = .cancelled; failedPhase = .finish; phase = .failed
                        return .failedSettled(receipt, .cancelled)
                    }
                    phase = .installed
                    return .installed(receipt)
                case .unstarted, .installed, .failed:
                    throw InstallationFailure.custody
                }
            }
        } catch {
            let cause = bootstrap.failureObservation().primary ?? InstallationFailure.classify(error)
            if firstFailure == nil { firstFailure = cause }
            // This branch precedes reserve invocation, not merely a low
            // bootstrap stage. No effect-bearing method has been invoked.
            if phase == .unstarted {
                failedPhase = phase; phase = .failed
                return .failedBeforeReserve(.beforeEffects(1), firstFailure!)
            }
            failedPhase = phase; phase = .failed
            switch bootstrap.settleOriginalAttempt(cause: firstFailure!) {
            case let .settled(receipt): return .failedSettled(receipt, firstFailure!)
            case .retained: return .retained(firstFailure!, failedPhase!)
            }
        }
    }
    /// A notice can only collect already-admitted commands within the original
    /// ceiling. It never resumes the forward sequence or changes failed success.
    func observeRetirement() {
        guard firstFailure != nil, !deadline.hasExpired else { return }
        try? bootstrap.collectOriginalRetirement()
    }
}

/// Exit capability constructors stay inside this file. Terminal capabilities
/// must be consumed against the same retained bootstrap before root disposal.
final class CoordinatorExitPermit {
    let status: Int32
    private init(_ status: Int32) { self.status = status }
    fileprivate static func beforeEffects(_ status: Int32) -> CoordinatorExitPermit { .init(status) }
    fileprivate static func terminal(_ receipt: FreshInstallationExitReceipt,
        attempt: FreshInstallationAttempt, failed: Bool) -> CoordinatorExitPermit? {
        guard receipt.consume(for: attempt.bootstrap) else { return nil }
        let uncancelled = (try? attempt.bootstrap.cancellationGate.check()) != nil
        let success = !failed && uncancelled && attempt.firstFailure == nil && receipt.disposition == .installed
        return .init(success ? 0 : 1)
    }
}
enum CoordinatorDisposition {
    case exit(CoordinatorExitPermit)
    case retained(CoordinatorInvocationLifetime)
}

final class CoordinatorInvocationLifetime: @unchecked Sendable {
    let attempt: FreshInstallationAttempt
    private let queue = DispatchQueue(label: "shadow-sync.installation.invocation")
    private let signalQueue = DispatchQueue(label: "shadow-sync.installation.cancellation")
    private var signals: [DispatchSourceSignal] = []
    private var subscriptions: [InstallationObservationSubscription] = []
    private var pendingPrinted = false
    private var launched = false
    init(attempt: FreshInstallationAttempt) { self.attempt = attempt }
    fileprivate func launch() {
        // Runtime has strongly installed this exact object before reaching here.
        precondition(CoordinatorProcessRoot.shared.contains(self))
        guard !launched else { return }; launched = true
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // Do not queue the latch behind a blocking installation phase.
                self.attempt.requestCancellation()
                self.queue.async { [weak self] in self?.attempt.observeRetirement() }
            }
            signals.append(source); source.resume()
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.accept(self.attempt.runOnce())
        }
    }
    private func accept(_ update: FreshInstallationAttempt.Update) {
        let permit: CoordinatorExitPermit?
        switch update {
        case let .failedBeforeReserve(noEffects, _): permit = noEffects
        case let .installed(receipt): permit = .terminal(receipt, attempt: attempt, failed: false)
        case let .failedSettled(receipt, _): permit = .terminal(receipt, attempt: attempt, failed: true)
        case .retained: permit = nil
        }
        if let permit {
            for subscription in subscriptions { subscription.cancel() }
            subscriptions.removeAll()
            for source in signals { source.cancel() }
            signals.removeAll()
            CoordinatorProcessRoot.shared.exit(self, permit: permit)
        } else {
            if !pendingPrinted {
                pendingPrinted = true
                // Output failure cannot release ownership or authorize exit.
                try? FileHandle.standardError.write(contentsOf: Data("Installation incomplete; this coordinator is retaining transaction ownership. No further installation work will start.\n".utf8))
            }
            subscriptions = attempt.bootstrap.observeOriginalWork(on: queue) { [weak self] in
                self?.attempt.observeRetirement()
            }
        }
    }
}

/// Exactly one strong process root, installed before queue dispatch or reserve.
/// No deinit release, background transfer or timeout-based root removal exists.
private final class CoordinatorProcessRoot: @unchecked Sendable {
    static let shared = CoordinatorProcessRoot()
    private let mutex = NSLock()
    private var root: CoordinatorInvocationLifetime?
    func install(_ lifetime: CoordinatorInvocationLifetime) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard root == nil else { return false }; root = lifetime; return true
    }
    func contains(_ lifetime: CoordinatorInvocationLifetime) -> Bool {
        mutex.lock(); defer { mutex.unlock() }; return root === lifetime
    }
    func exit(_ lifetime: CoordinatorInvocationLifetime, permit: CoordinatorExitPermit) -> Never {
        mutex.lock()
        precondition(root === lifetime)
        root = nil
        mutex.unlock()
        Darwin.exit(permit.status)
    }
}

extension LifecycleCoordinatorMain {
    /// Public executable plumbing only; capabilities remain internal to Core.
    public static func runRuntime(arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        switch start(arguments: arguments) {
        case let .exit(permit): Darwin.exit(permit.status)
        case let .retained(lifetime):
            lifetime.launch()
            dispatchMain()
        }
    }
    static func start(arguments: [String]) -> CoordinatorDisposition {
        guard arguments.count == 2, arguments[1] == "--install-fresh" else {
            return .exit(.beforeEffects(run(arguments: arguments)))
        }
        #if SHADOW_SYNC_TESTING
        // Refuse before account/path/distribution resolution, including signed fixtures.
        return .exit(.beforeEffects(78))
        #else
        let deadline = MonotonicDeadline(seconds: 30)
        do {
            let attempt = try FreshInstallationAttempt.production(deadline: deadline)
            let lifetime = CoordinatorInvocationLifetime(attempt: attempt)
            guard CoordinatorProcessRoot.shared.install(lifetime) else {
                // This entrypoint is process-only. A second invocation cannot
                // discard the first root or receive an exit capability.
                preconditionFailure("Coordinator runtime entered twice")
            }
            return .retained(lifetime)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("ShadowSync fresh installation admission failed.\n".utf8))
            return .exit(.beforeEffects(1))
        }
        #endif
    }
}
