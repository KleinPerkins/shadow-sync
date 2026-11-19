#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import Security

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
        // Reserve two inventory-stage summaries plus the terminal refusal.
        // Optional chatter cannot consume these records or their bytes.
        static let optionalRecords = maximumRecords - 3
        private struct Refusal {
            let component: Component, stage: Stage
            let elapsed: UInt64, expired: Bool, resultBits: UInt64
        }
        private let lock = NSLock()
        private let enabled: Bool
        private let writer: @Sendable (String) -> Void
        private let clock: @Sendable () -> UInt64
        private var records = 0
        private var bytes = 0
        private var closed = false
        private var finished = false
        private var refusal: Refusal?
        private var inventoryRecords = 0

        init(enabled: Bool, writer: @escaping @Sendable (String) -> Void,
             clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
            self.enabled = enabled
            self.writer = writer
            self.clock = clock
        }

        func emit(_ line: @autoclosure () -> String) {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !closed, !finished else { return }
            guard records < Self.optionalRecords else { suppress(); return }
            let text = line(), size = text.utf8.count
            guard size <= Self.maximumLineBytes,
                  bytes + size + Self.suppression.utf8.count + (3 - inventoryRecords) * Self.maximumLineBytes <= Self.maximumBytes else {
                suppress(); return
            }
            records += 1; bytes += size
            writer(text)
        }

        func emitInventory(_ line: @autoclosure () -> String) {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !finished, inventoryRecords < 2,
                  records < Self.maximumRecords - 1 else { return }
            let text = line(), size = text.utf8.count
            guard size <= Self.maximumLineBytes,
                  bytes + size + (2 - inventoryRecords) * Self.maximumLineBytes <= Self.maximumBytes else { return }
            inventoryRecords += 1; records += 1; bytes += size; writer(text)
        }

        func beginOperation() {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !finished else { return }
            // Reset cause only; never renew the process-wide trace allowance.
            refusal = nil
        }

        func completeOperation() {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !finished else { return }
            refusal = nil
        }

        func observeRefusal(_ component: Component, stage: Stage, started: UInt64,
                            deadline: UInt64, resultBits: UInt64 = 0) {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !finished, refusal == nil else { return }
            // Explicit refusal observers only. Generic unwinding and registry
            // succeeded=false progress cannot occupy or replace this slot.
            switch component { case .admission, .localAuthority: break; default: return }
            let now = clock()
            refusal = Refusal(component: component, stage: stage,
                elapsed: now >= started ? now - started : 0, expired: now >= deadline, resultBits: resultBits)
        }

        func flushRefusal() {
            lock.lock(); defer { lock.unlock() }
            guard enabled, !finished else { return }
            finished = true
            guard let refusal else { return }
            // Timestamp/expiry describe observation, not this later flush.
            let text = "DISCOVERY FIXTURE REFUSAL component=\(refusal.component.rawValue) stage=\(refusal.stage.rawValue) elapsed_ns=\(refusal.elapsed) deadline_expired=\(refusal.expired) result_bits=\(refusal.resultBits)\n"
            let size = text.utf8.count
            guard records < Self.maximumRecords, size <= Self.maximumLineBytes,
                  bytes + size <= Self.maximumBytes else { return }
            records += 1; bytes += size; writer(text)
        }

        private func suppress() {
            closed = true
            bytes += Self.suppression.utf8.count
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

    /// Fixed counters for the synchronous initial inventory callback only.
    /// Nested intervals overlap; these are observations, never a new budget.
    final class InventoryCost {
        static let maximumTime: UInt64 = 1_000_000_000_000
        var started: UInt64?, deadline: UInt64 = 0
        private var accesses: UInt64 = 0, refusalAccess: UInt64?
        private var counts = [UInt64](repeating: 0, count: 3)
        private var session = [UInt64](repeating: 0, count: 4)
        private var publisher = [UInt64](repeating: 0, count: 3)
        private var transport: UInt64 = 0
        private var capped = false

        private func sum(_ lhs: UInt64, _ rhs: UInt64, limit: UInt64 = maximumTime) -> UInt64 {
            if rhs > limit || lhs > limit - rhs { capped = true; return limit }
            return lhs + rhs
        }
        func access() { accesses = sum(accesses, 1, limit: 10_000) }
        func refusal() { if refusalAccess == nil { refusalAccess = accesses } }
        func add(_ component: Component, started: UInt64, ended: UInt64, milestones: [UInt64]) {
            let index: Int
            switch component { case .session: index = 0; case .publisher: index = 1; case .transport: index = 2; default: return }
            counts[index] = sum(counts[index], 1, limit: 10_000)
            guard ended >= started else { capped = true; return }
            if index == 2 { transport = sum(transport, ended - started); return }
            let count = index == 0 ? 4 : 3
            guard milestones.count < count else { capped = true; return }
            let points = [started] + milestones + [ended]
            for (i, pair) in zip(points, points.dropFirst()).enumerated() {
                guard pair.1 >= pair.0 else { capped = true; return }
                if index == 0 { session[i] = sum(session[i], pair.1 - pair.0) }
                else { publisher[i] = sum(publisher[i], pair.1 - pair.0) }
            }
        }
        func line(ended: UInt64, succeeded: Bool) -> String {
            let elapsed = sum(0, ended >= (started ?? ended) ? ended - (started ?? ended) : 0)
            let sessions = session.map(String.init).joined(separator: ",")
            let publishers = publisher.map(String.init).joined(separator: ",")
            let calls = counts.map(String.init).joined(separator: ",")
            return "DISCOVERY FIXTURE INVENTORY elapsed_ns=\(elapsed) deadline_expired=\(ended >= deadline) succeeded=\(succeeded) accesses=\(accesses) refusal_access=\(refusalAccess.map(String.init) ?? "none") counts=\(calls) session_ns=\(sessions) publisher_ns=\(publishers) transport_ns=\(transport) capped=\(capped)\n"
        }
    }

    private static let inventoryKey = "shadow-sync-fixture-inventory-cost"
    private static var inventoryCost: InventoryCost? {
        Thread.current.threadDictionary[inventoryKey] as? InventoryCost
    }
    private static var activeInventoryCost: InventoryCost? {
        guard let cost = inventoryCost, cost.started != nil else { return nil }
        return cost
    }
    static func requestInventoryCost() -> Bool {
        guard mode == "costs", inventoryCost == nil else { return false }
        Thread.current.threadDictionary[inventoryKey] = InventoryCost()
        return true
    }
    static func cancelInventoryCost() { Thread.current.threadDictionary.removeObject(forKey: inventoryKey) }
    static func beginInventoryStage(deadline: UInt64) -> InventoryCost? {
        guard let cost = inventoryCost, cost.started == nil else { return nil }
        cost.started = DispatchTime.now().uptimeNanoseconds; cost.deadline = deadline
        return cost
    }
    static func endInventoryStage(_ cost: InventoryCost?, succeeded: Bool) {
        guard let cost else { return }
        cancelInventoryCost()
        let ended = DispatchTime.now().uptimeNanoseconds
        sink.emitInventory(cost.line(ended: ended, succeeded: succeeded))
    }
    static func inventoryAccess() { activeInventoryCost?.access() }

    // Read the testing-only opt-in once. The complete type and environment key
    // are absent from production builds. Disabled traces do not format records.
    private static let mode = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS"]
    private static let sink = Sink(
        enabled: mode == "1" || mode == "boundaries" || mode == "costs",
        writer: { fputs($0, stderr); fflush(stderr) })
    private static let revalidationSamples = SampleBudget(enabled: mode == "costs")
    private static let publisherSamples = SampleBudget(enabled: mode == "costs")

    static func sampleRevalidation() -> Bool { activeInventoryCost != nil || revalidationSamples.take() }
    static func samplePublisherRevalidation() -> Bool { activeInventoryCost != nil || publisherSamples.take() }
    static func beginOperation() { sink.beginOperation() }
    static func completeOperation() { sink.completeOperation() }
    static func flushRefusal() { sink.flushRefusal() }
    static func recordRefusal(_ component: Component, stage: Stage, started: UInt64,
                              deadline: UInt64, resultBits: UInt64 = 0) {
        if component == .admission || component == .localAuthority { activeInventoryCost?.refusal() }
        sink.observeRefusal(component, stage: stage, started: started, deadline: deadline, resultBits: resultBits)
    }

    enum Component: String { case catalog, transport, custody, registry, admission, binder, selection, rebind, discovery, session, publisher, localAuthority }
    enum Stage: String {
        case entry, budget, input, authorityBefore, resources, execution
        case authorityAfter, decode, prepare, start, wait, result, postflight, decisions
        case queued, validated, metadata, resumed, ready, admissionQueued, controlFlushed, terminal, retired
        case deadlineBefore, revalidation, deadlineAfter, root, projection, scratch, snapshot
        case resourceFiles, appExecutable, runtimeTree
    }
    static func record(_ component: Component, stage: Stage, started: UInt64,
                        deadline: UInt64?, resultBits: UInt64 = 0, succeeded: Bool = false,
                        milestones: [UInt64] = []) {
        if let cost = activeInventoryCost {
            cost.add(component, started: started, ended: DispatchTime.now().uptimeNanoseconds, milestones: milestones)
            // Aggregate every validation in this stage without consuming the
            // optional trace lane on individual successful revalidations.
            if component == .session || component == .publisher { return }
        }
        // Boundary mode keeps successful helper chatter from consuming the
        // same fixed budget before a later admission failure can be observed.
        if mode == "boundaries" || mode == "costs" {
            switch component {
            case .admission, .session, .binder, .selection, .rebind, .discovery, .publisher, .localAuthority: break
            case .catalog, .transport, .custody: if succeeded { return }
            case .registry: return
            }
        }
        func formatted() -> String {
            let now = DispatchTime.now().uptimeNanoseconds
            let expired = deadline.map { now >= $0 } ?? false
            let points = [started] + milestones + [now]
            let durations = zip(points, points.dropFirst()).map { String($1 - $0) }.joined(separator: ",")
            return "DISCOVERY FIXTURE DIAGNOSTIC component=\(component.rawValue) stage=\(stage.rawValue) elapsed_ns=\(now - started) deadline_expired=\(expired) result_bits=\(resultBits) succeeded=\(succeeded) intervals_ns=\(durations)\n"
        }
        sink.emit(formatted())
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
