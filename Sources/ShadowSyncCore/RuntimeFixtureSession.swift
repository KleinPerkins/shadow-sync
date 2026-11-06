#if SHADOW_SYNC_TESTING
import Foundation

/// Serial assertion-case binding. A suite guardian can close admission while
/// these registries retain registered original children through actual cleanup.
enum RuntimeFixtureSession {
    private final class Binding: @unchecked Sendable {
        let lock = NSLock()
        var current: RuntimeFixtureCustody?
        var ancestors: [RuntimeFixtureCustody] = []
        var guardian: RuntimeSuiteGuardian?
    }
    private static let binding = Binding()
    // Serialize legacy top-level discovery operations, not their parallel Git
    // workers. A whole operation retains one scope until its queue is joined.
    private static let legacyDiscoveryLock = NSRecursiveLock()
    static func withLegacyDiscovery<Value>(_ body: () throws -> Value) throws -> Value {
        legacyDiscoveryLock.lock(); defer { legacyDiscoveryLock.unlock() }
        if try currentIfBound() != nil { return try body() }
        return try withCaseValue("legacy-discovery-operation", body)
    }
    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func installGuardian(_ guardian: RuntimeSuiteGuardian) throws {
        binding.lock.lock(); defer { binding.lock.unlock() }
        guard binding.current == nil, binding.guardian == nil else {
            throw RuntimeFixtureCustody.Failure.invalidContract
        }
        binding.guardian = guardian
    }
    static func removeGuardian(_ guardian: RuntimeSuiteGuardian) {
        binding.lock.lock(); defer { binding.lock.unlock() }
        if binding.current == nil, binding.guardian === guardian { binding.guardian = nil }
    }
    static func guardianProbeTarget() -> String? {
        binding.lock.lock(); defer { binding.lock.unlock() }
        return binding.guardian?.probeTarget
    }

    /// Qualification executors bind legacy disposable prefixes to one exact
    /// attempt. Unknown prefixes and malformed namespaces fail before creation.
    static func fixturePrefix(_ name: String,
        namespace: String? = ProcessInfo.processInfo.environment["SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE"]) throws -> String {
        guard ["shadow-sync-m2.", "shadow-sync-m4.", "shadow-sync-self-tests.", "shadow-sync-custody-anchor-",
               "shadow-sync-m6-self.", "shadow-sync-custody-leases.", "shadow-sync-custody-catalog.",
               "shadow-sync-fresh-state.", "shadow-sync-registry.", "shadow-sync-state-admission.",
               "shadow-sync-policy-input-", "shadow-sync-policy-transport-",
               "shadow-sync-policy-authority-", "shadow-sync-catalog-admission-",
               "shadow-sync-publisher-policy-", "shadow-sync-discovery-spawn.", "shadow-sync-fixture-config.", "shadow-sync-v3-preferences.", "shadow-sync-v3-preferences-pre-rename.", "shadow-sync-v3-preferences-post-rename.", "shadow-sync-v3-catalog.", "shadow-sync-dm4-preflight."].contains(name) else {
            throw RuntimeFixtureCustody.Failure.invalidContract
        }
        guard let namespace else { return "/private/tmp/" + name }
        guard namespace.utf8.count == 32,
              namespace.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RuntimeFixtureCustody.Failure.invalidContract
        }
        return "/private/tmp/" + name + namespace + "."
    }
    /// A guardian may never admit a runner outside its active assertion case.
    /// Developer routes without a guardian retain the runner's ordinary owner.
    static func currentIfBound() throws -> RuntimeFixtureCustody? {
        binding.lock.lock(); defer { binding.lock.unlock() }
        guard binding.guardian == nil || binding.current != nil else {
            throw RuntimeFixtureCustody.Failure.invalidContract
        }
        return binding.current
    }
    static func current() throws -> RuntimeFixtureCustody {
        binding.lock.lock(); defer { binding.lock.unlock() }
        guard let registry = binding.current else { throw RuntimeFixtureCustody.Failure.invalidContract }
        return registry
    }
    /// Every entry observes the same newly spawned original child. An inner
    /// qualification registry may cancel intentionally without cancelling its
    /// outer assertion, but neither registry may bypass the other's admission.
    static func registrationRegistries(for registry: RuntimeFixtureCustody) throws -> [RuntimeFixtureCustody] {
        binding.lock.lock(); defer { binding.lock.unlock() }
        guard binding.guardian == nil || binding.current != nil else {
            throw RuntimeFixtureCustody.Failure.invalidContract
        }
        // All resume closures take the same hierarchy order, including a
        // caller that explicitly supplies an ancestor rather than current.
        var result: [RuntimeFixtureCustody] = []
        for candidate in Array(binding.ancestors.reversed()) + [binding.current].compactMap({ $0 }) + [registry] {
            if !result.contains(where: { $0 === candidate }) { result.append(candidate) }
        }
        return result
    }
    static func drain(_ anchor: OwnedSpawnAnchor) {
        anchor.testingRequestRuntimeDrain()
        var reported = false
        let diagnostic = MonotonicDeadline(seconds: 6)
        while !anchor.testingRuntimeRetired {
            if diagnostic.hasExpired && !reported {
                fputs("RUNTIME FIXTURE CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    static func withCase(_ id: String, _ body: () throws -> Void) throws {
        try withCaseValue(id, body)
    }

    /// Return shared, non-child fixture values only after the full case and
    /// cleanup have succeeded. Failure or cancellation cannot publish a value.
    static func withCaseValue<Value>(_ id: String, _ body: () throws -> Value) throws -> Value {
        try runCase(id, nestedAssertionProbe: false, body)
    }

    /// Closed self-test of assertion unwinding. This is an inner cleanup scope,
    /// not another compiled guardian case or independent source of admission.
    static func withNestedAssertionProbe(_ body: () throws -> Void) throws {
        try runCase("assertion-unwind", nestedAssertionProbe: true, body)
    }

    private static func runCase<Value>(_ id: String, nestedAssertionProbe: Bool,
                                      _ body: () throws -> Value) throws -> Value {
        binding.lock.lock(); let guardian = binding.guardian; binding.lock.unlock()
        try guardian?.requireAdmission()
        let start = now
        let registry = try RuntimeFixtureCustody(cases: [id], now: now,
            deadline: min(start + 60_000_000_000, guardian?.deadline ?? UInt64.max),
            graceNanoseconds: 1_000_000_000)
        try registry.beginCase(id, now: now)
        binding.lock.lock()
        let parent = binding.current
        let ancestors = binding.ancestors
        guard nestedAssertionProbe ? (parent != nil && ancestors.isEmpty) : (parent == nil && ancestors.isEmpty) else {
            binding.lock.unlock(); throw RuntimeFixtureCustody.Failure.invalidContract
        }
        binding.ancestors = [parent].compactMap { $0 }
        binding.current = registry
        binding.lock.unlock()
        defer {
            binding.lock.lock()
            if binding.current === registry {
                binding.current = parent
                binding.ancestors = ancestors
            }
            binding.lock.unlock()
        }
        if !nestedAssertionProbe { try guardian?.beginCase(id, registry: registry) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shadow-sync.runtime-fixture.control"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { registry.tick(now: DispatchTime.now().uptimeNanoseconds) }
        timer.resume()
        var failure: Error?
        var output: Value?
        do { try guardian?.requireAdmission(); output = try body() }
        catch { failure = error; registry.cancel(.assertion, now: now) }
        do { try registry.closeCase(id, now: now) }
        catch { failure = failure ?? error; registry.cancel(.assertion, now: now) }
        var reported = false
        let diagnostic = MonotonicDeadline(seconds: 6)
        while !registry.snapshot().cleanupComplete {
            registry.tick(now: now)
            if diagnostic.hasExpired && !reported {
                fputs("RUNTIME CASE CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        timer.cancel()
        do {
            try registry.finishCase(id, assertionPassed: failure == nil, now: now)
            try registry.finish(now: now)
        } catch { failure = failure ?? error }
        do { if !nestedAssertionProbe { try guardian?.completeCase(id, snapshot: registry.snapshot(), success: failure == nil) } }
        catch { failure = failure ?? error }
        if let failure { throw failure }
        guard let output else { throw RuntimeFixtureCustody.Failure.invalidContract }
        return output
    }
}
#endif
