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

    static func sampleRevalidation() -> Bool { revalidationSamples.take() }
    static func samplePublisherRevalidation() -> Bool { publisherSamples.take() }

    enum Component: String { case catalog, transport, custody, registry, admission, binder, selection, rebind, discovery, session, publisher }
    enum Stage: String {
        case entry, budget, input, authorityBefore, resources, execution
        case authorityAfter, decode, prepare, start, wait, result, postflight, decisions
        case queued, validated, metadata, resumed, ready, admissionQueued, controlFlushed, terminal, retired
        case deadlineBefore, revalidation, deadlineAfter, root, projection, scratch, snapshot
        case resourceFiles, appExecutable, runtimeTree
        case failure
    }
    static func record(_ component: Component, stage: Stage, started: UInt64,
                        deadline: UInt64?, resultBits: UInt64 = 0, succeeded: Bool = false,
                        milestones: [UInt64] = []) {
        // Boundary mode keeps successful helper chatter from consuming the
        // same fixed budget before a later admission failure can be observed.
        if mode == "boundaries" || mode == "costs" {
            switch component {
            case .admission, .session, .binder, .selection, .rebind, .discovery, .publisher: break
            case .catalog, .transport, .custody: if succeeded { return }
            case .registry: if stage != .failure { return }
            }
        }
        func formatted() -> String {
            let now = DispatchTime.now().uptimeNanoseconds
            let expired = deadline.map { now >= $0 } ?? false
            let points = [started] + milestones + [now]
            let durations = zip(points, points.dropFirst()).map { String($1 - $0) }.joined(separator: ",")
            return "DISCOVERY FIXTURE DIAGNOSTIC component=\(component.rawValue) stage=\(stage.rawValue) elapsed_ns=\(now - started) deadline_expired=\(expired) result_bits=\(resultBits) succeeded=\(succeeded) intervals_ns=\(durations)\n"
        }
        sinkForRecord(component, stage: stage, succeeded: succeeded,
                      ordinary: sink, failures: failureSink).emit(formatted())
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
