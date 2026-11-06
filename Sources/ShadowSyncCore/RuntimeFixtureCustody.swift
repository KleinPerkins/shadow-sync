#if SHADOW_SYNC_TESTING
import Foundation

/// Testing-only admission and retention for a runtime suite guardian. This owns
/// callbacks backed by actual child owners; it never adopts a PID or reaps one.
/// The independent control loop calls cancel/tick without waiting on child locks.
final class RuntimeFixtureCustody: @unchecked Sendable {
    enum Reason: String, Sendable { case callerLost, cancelled, deadline, transport, assertion }
    enum ChildState: Sendable { case retained, reaped, ownershipFailure }
    enum Failure: Error { case invalidContract, admissionClosed, outstandingCustody, invalidTicket }
    struct Ticket: Sendable {
        fileprivate let registry: UUID
        fileprivate let sequence: UInt64
    }
    struct Directive: Sendable {
        let reason: Reason?
        let escalate: Bool
    }
    struct Snapshot: Equatable, Sendable {
        let reason: Reason?
        let activeCase: String?
        let reservations: Int
        let children: Int
        let callbacks: Int
        let spawned: Int
        let reaped: Int
        let failedSpawns: Int
        let passedCases: [String]
        let finished: Bool
        var cleanupComplete: Bool { reservations == 0 && children == 0 && callbacks == 0 }
        var succeeded: Bool { finished && reason == nil && cleanupComplete }
    }
    private final class Entry: @unchecked Sendable {
        let step: @Sendable (Directive) -> ChildState
        let queue: DispatchQueue
        var busy = false
        var drainTime: UInt64?
        init(sequence: UInt64, step: @escaping @Sendable (Directive) -> ChildState) {
            self.step = step
            queue = DispatchQueue(label: "shadow-sync.runtime-fixture.\(sequence)")
        }
    }
    private let mutex = NSLock()
    private let identity = UUID()
    private let expected: [String]
    private let workDeadline: UInt64
    private let graceNanoseconds: UInt64
    private let capacity: Int
    private var reason: Reason?
    private var cancelTime: UInt64?
    private var current: String?
    private var caseDrainTime: UInt64?
    private var reservations: Set<UInt64> = []
    private var entries: [UInt64: Entry] = [:]
    private var next: UInt64 = 0
    private var spawned = 0, reaped = 0, failedSpawns = 0
    private var passed: [String] = []
    private var finished = false

    init(cases: [String], now: UInt64, deadline: UInt64,
         graceNanoseconds: UInt64 = 2_000_000_000, capacity: Int = 256) throws {
        guard !cases.isEmpty, cases.count <= 2048, Set(cases).count == cases.count,
              cases.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256
                  && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }),
              deadline > now, deadline - now <= 3_600_000_000_000,
              graceNanoseconds <= 5_000_000_000, (1...256).contains(capacity) else {
            throw Failure.invalidContract
        }
        expected = cases; workDeadline = deadline
        self.graceNanoseconds = graceNanoseconds; self.capacity = capacity
    }

    private func closeLocked(_ cause: Reason, now: UInt64) {
        if reason == nil { reason = cause; cancelTime = now }
    }
    private func expireLocked(_ now: UInt64) {
        if !finished && now >= workDeadline { closeLocked(.deadline, now: now) }
    }
    func beginCase(_ id: String, now: UInt64) throws {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard reason == nil, !finished else { throw Failure.admissionClosed }
        guard current == nil, entries.isEmpty, reservations.isEmpty,
              passed.count < expected.count, expected[passed.count] == id else {
            throw Failure.outstandingCustody
        }
        current = id
    }
    /// Must precede the spawn syscall. A crossing cancellation cannot discard
    /// this reservation; register the successful original child or report failure.
    func reserveSpawn(now: UInt64) throws -> Ticket {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard reason == nil, !finished, current != nil, caseDrainTime == nil else { throw Failure.admissionClosed }
        guard entries.count + reservations.count < capacity, next < UInt64.max else {
            throw Failure.outstandingCustody
        }
        let ticket = Ticket(registry: identity, sequence: next); next += 1
        reservations.insert(ticket.sequence)
        return ticket
    }
    func permitsSpawn(_ ticket: Ticket, now: UInt64) -> Bool {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        return ticket.registry == identity && reservations.contains(ticket.sequence)
            && reason == nil && !finished && caseDrainTime == nil
    }
    /// Registration remains legal after cancellation: a successful in-flight
    /// spawn must acquire cleanup ownership before fallible identity validation.
    func register(_ ticket: Ticket, step: @escaping @Sendable (Directive) -> ChildState) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.registry == identity, reservations.remove(ticket.sequence) != nil else {
            throw Failure.invalidTicket
        }
        let entry = Entry(sequence: ticket.sequence, step: step)
        entry.drainTime = caseDrainTime
        entries[ticket.sequence] = entry
        spawned += 1
    }
    func spawnFailed(_ ticket: Ticket) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.registry == identity, reservations.remove(ticket.sequence) != nil else {
            throw Failure.invalidTicket
        }
        failedSpawns += 1
    }
    func permitsResume(now: UInt64) -> Bool {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        return reason == nil && !finished && current != nil && caseDrainTime == nil
    }
    /// Caller already holds the original child owner's signal/reap exclusion.
    /// Only the final nonblocking SIGCONT syscall belongs inside this section;
    /// no owner lock acquisition, identity query or testing barrier runs here.
    func performResume(_ ticket: Ticket, now: UInt64, signal: () -> Bool) -> Bool {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard ticket.registry == identity, let entry = entries[ticket.sequence], entry.drainTime == nil,
              reason == nil, !finished, current != nil, caseDrainTime == nil else { return false }
        return signal()
    }
    /// Normal fixture teardown closes this original child's resume admission
    /// without cancelling the case or preventing its next independent fixture.
    func requestDrain(_ ticket: Ticket, now: UInt64) {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard ticket.registry == identity, let entry = entries[ticket.sequence] else { return }
        if entry.drainTime == nil { entry.drainTime = now }
    }
    func isRetired(_ ticket: Ticket) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return ticket.registry == identity && ticket.sequence < next
            && !reservations.contains(ticket.sequence) && entries[ticket.sequence] == nil
    }
    /// Assertion work is over. In-flight reservations remain retained and any
    /// crossing successful spawn must drain before the case can finish.
    func closeCase(_ id: String, now: UInt64) throws {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard current == id else { throw Failure.invalidContract }
        if caseDrainTime == nil { caseDrainTime = now }
        for entry in entries.values where entry.drainTime == nil { entry.drainTime = now }
    }
    func cancel(_ cause: Reason, now: UInt64) {
        mutex.lock(); defer { mutex.unlock() }
        if !finished { closeLocked(cause, now: now) }
    }
    /// Schedules each original owner's observation/drain callback on its own
    /// serial queue. No owner lock, assertion, wait or I/O runs under mutex.
    func tick(now: UInt64) {
        mutex.lock(); expireLocked(now)
        var work: [(UInt64, Entry, Directive)] = []
        for (key, entry) in entries where !entry.busy {
            let start = [cancelTime, entry.drainTime].compactMap { $0 }.min()
            let directive = Directive(reason: reason ?? (entry.drainTime == nil ? nil : .cancelled),
                escalate: start.map { now >= $0 && now - $0 >= graceNanoseconds } ?? false)
            entry.busy = true
            work.append((key, entry, directive))
        }
        mutex.unlock()
        for (key, entry, directive) in work {
            entry.queue.async {
                let observed = entry.step(directive)
                self.mutex.lock()
                // No caller can delete a pending entry or replace its owner.
                if self.entries[key] === entry {
                    entry.busy = false
                    if case .reaped = observed {
                        self.entries.removeValue(forKey: key); self.reaped += 1
                    }
                    // Unknown ownership remains retained, never counted reaped.
                }
                self.mutex.unlock()
            }
        }
    }
    /// Called only after the assertion body and its defers have returned.
    /// Pending callbacks require another observation, never inferred completion.
    func finishCase(_ id: String, assertionPassed: Bool, now: UInt64) throws {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard current == id else { throw Failure.invalidContract }
        if !assertionPassed { closeLocked(.assertion, now: now) }
        guard entries.isEmpty, reservations.isEmpty else { throw Failure.outstandingCustody }
        current = nil
        caseDrainTime = nil
        guard reason == nil, assertionPassed else { throw Failure.admissionClosed }
        passed.append(id)
    }
    func finish(now: UInt64) throws {
        mutex.lock(); defer { mutex.unlock() }; expireLocked(now)
        guard current == nil, reservations.isEmpty, entries.isEmpty else { throw Failure.outstandingCustody }
        guard reason == nil, passed == expected else { throw Failure.admissionClosed }
        finished = true
    }
    func snapshot() -> Snapshot {
        mutex.lock(); defer { mutex.unlock() }
        return Snapshot(reason: reason, activeCase: current, reservations: reservations.count,
            children: entries.count, callbacks: entries.values.filter(\.busy).count,
            spawned: spawned, reaped: reaped, failedSpawns: failedSpawns,
            passedCases: passed, finished: finished)
    }
}
#endif
