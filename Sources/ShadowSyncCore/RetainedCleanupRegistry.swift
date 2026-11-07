import Darwin
import Foundation

/// A private constructor binds the helper to the running canonical publisher.
/// This permits only helper bootstrap; it grants no target-command admission.
final class CustodyHelperExecutable: @unchecked Sendable {
    let path: String
    let releaseSHA256: String
    private let account: EffectiveAccount
    private let owner: uid_t
    private let lifecyclePublisher: LifecyclePublisher?
    private let snapshot: PublisherExecutableSnapshot
    private let publisher: PublisherCodeVerifier.Identity?
    private let files: [PolicyAuthorityFile]
    private let graphResource: PolicyAuthorityFile?
    #if SHADOW_SYNC_TESTING
    private let fixture: Bool
    private var custodianFixture = false
    private var installationFixtureRoot: String?
    private var discoveryFixture = false
    private var discoveryFixtureGraphs: PolicyAuthorityFile?
    #endif

    private init(path: String, release: String, account: EffectiveAccount,
                 snapshot: PublisherExecutableSnapshot, publisher: PublisherCodeVerifier.Identity?,
                 files: [PolicyAuthorityFile], graphResource: PolicyAuthorityFile? = nil,
                 owner: uid_t? = nil, lifecyclePublisher: LifecyclePublisher? = nil) {
        self.path = path; releaseSHA256 = release; self.account = account
        self.snapshot = snapshot; self.publisher = publisher; self.files = files
        self.graphResource = graphResource
        self.owner = owner ?? account.uid; self.lifecyclePublisher = lifecyclePublisher
        #if SHADOW_SYNC_TESTING
        fixture = publisher == nil
        #endif
    }
    static func production() throws -> CustodyHelperExecutable {
        let account = try EffectiveAccount.current(), app = account.homeDirectory + "/Applications/ShadowSync.app"
        guard Bundle.main.bundleURL.path == app else { throw PublisherPolicyError.unavailable }
        let info = try PolicyAuthorityFile.read(path: app + "/Contents/Info.plist", owner: account.uid, maximumBytes: 65_536)
        let contract = try PolicyAuthorityFile.read(path: app + "/Contents/Resources/release-contract.json", owner: account.uid, maximumBytes: 65_536)
        let graphs = try PolicyAuthorityFile.read(path: app + "/Contents/Resources/command-graphs.json", owner: account.uid, maximumBytes: 65_536)
        let seal = try PolicyAuthorityFile.read(path: app + "/Contents/_CodeSignature/CodeResources", owner: account.uid, maximumBytes: 1_048_576)
        guard let dictionary = try PropertyListSerialization.propertyList(from: info.bytes, format: nil) as? [String: Any] else { throw PublisherPolicyError.unavailable }
        let release = try ReleaseIdentity(infoDictionary: dictionary); try release.validate(requireProduction: true)
        guard release.releaseContractSHA256 == contract.sha256 else { throw PublisherPolicyError.unavailable }
        var parser = try PolicyWireParser(contract.bytes, profile: .configuration)
        guard case let .object(fields) = try parser.parse(),
              fields["command_graphs_sha256"] == .string(graphs.sha256) else { throw PublisherPolicyError.unavailable }
        _ = try CommandGraphCatalog.decode(graphs.bytes)
        let (code, publisher) = try PublisherCodeVerifier.runningApplication(path: app)
        try PublisherCodeVerifier.sealed(contract, relativePath: "Resources/release-contract.json", code: code)
        try PublisherCodeVerifier.sealed(graphs, relativePath: "Resources/command-graphs.json", code: code)
        let path = app + "/Contents/MacOS/ShadowSync"
        let result = Self(path: path, release: contract.sha256, account: account,
            snapshot: try PublisherExecutableSnapshot.capture(path: path, owner: account.uid),
            publisher: publisher, files: [info, contract, seal, graphs], graphResource: graphs)
        try result.revalidate(); return result
    }
    /// A separate source-free coordinator role; installed application bootstrap
    /// keeps its canonical-location requirement. No decoded path grants this role.
    static func lifecycle(_ publisher: LifecyclePublisher) throws -> CustodyHelperExecutable {
        let value = try publisher.custodianBootstrap()
        let result = Self(path: value.path, release: publisher.releaseSHA256, account: publisher.account,
            snapshot: value.snapshot, publisher: value.identity, files: [], graphResource: value.graphs,
            owner: value.owner, lifecyclePublisher: publisher)
        try result.revalidate(); return result
    }
    var isLifecycleCoordinator: Bool { lifecyclePublisher != nil }
    func validateInstallationPublisher(_ transaction: InstallationTransaction) throws {
        try revalidate()
        if let lifecyclePublisher {
            let identity = try lifecyclePublisher.installationIdentity()
            let code = identity.coordinatorCode
            guard transaction.sourceReleaseDigest == identity.sourceReleaseDigest,
                  transaction.candidate == (transaction.intent == .remove ? nil : identity.candidate),
                  transaction.coordinator.team == code.team,
                  transaction.coordinator.identifier == code.identifier,
                  transaction.coordinator.cdHash == code.codeDirectory.map({ String(format: "%02x", $0) }).joined() else {
                throw CustodyRecordError.fenced
            }
        } else {
            #if SHADOW_SYNC_TESTING
            // Existing isolated fixture executable, never a production publisher.
            guard fixture, transaction.sourceReleaseDigest == releaseSHA256,
                  transaction.candidate == (try testingBoundInstallationCandidate()),
                  transaction.coordinator.team == ReleaseIdentity.publisherTeamIdentifier,
                  transaction.coordinator.identifier == LifecyclePublisher.identifier,
                  transaction.coordinator.cdHash == transaction.candidate?.coordinatorCDHash else { throw CustodyRecordError.fenced }
            #else
            throw CustodyRecordError.fenced
            #endif
        }
    }
    func productionGraphResource() throws -> PolicyAuthorityFile {
        guard publisher != nil, let graphResource else { throw PublisherPolicyError.unavailable }
        try revalidate()
        return graphResource
    }
    func revalidate() throws {
        guard account == (try EffectiveAccount.current()),
              snapshot == (try PublisherExecutableSnapshot.capture(path: path, owner: owner)) else { throw PublisherPolicyError.unavailable }
        for file in files { try file.revalidate() }
        #if SHADOW_SYNC_TESTING
        try discoveryFixtureGraphs?.revalidate()
        #endif
        if let lifecyclePublisher {
            try lifecyclePublisher.revalidate()
        } else if let publisher {
            let app = account.homeDirectory + "/Applications/ShadowSync.app"
            let (_, current) = try PublisherCodeVerifier.verifiedStatic(path: app, identifier: ReleaseIdentity.bundleIdentifier, team: publisher.team)
            guard current == publisher else { throw PublisherPolicyError.unavailable }
        } else {
            #if !SHADOW_SYNC_TESTING
            throw PublisherPolicyError.unavailable
            #endif
        }
    }
    func validateSuspended(_ anchor: OwnedSpawnAnchor) throws {
        try revalidate()
        if let publisher { try PublisherCodeVerifier.suspendedChild(anchor.processID, expected: publisher) }
    }
    func authenticateParent(_ pid: pid_t, generation: String) throws -> ProcessIdentity {
        try revalidate()
        let identity = try ProcessIdentity.capture(processID: pid, generation: generation, expectedExecutablePath: path)
        guard identity.userID == account.uid else { throw PublisherPolicyError.unavailable }
        if let publisher { try PublisherCodeVerifier.suspendedChild(pid, expected: publisher) }
        return identity
    }
    var arguments: [String] {
        #if SHADOW_SYNC_TESTING
        if discoveryFixture { return [path, "--shadow-sync-discovery-custodian-fixture"] }
        if fixture { return [path, custodianFixture ? "--shadow-sync-custodian-fixture" : "--shadow-sync-custody-registry-fixture"] }
        #endif
        return [path, "--shadow-sync-command-custodian"]
    }
    #if SHADOW_SYNC_TESTING
    func bindTestingInstallationSource(root: String) throws {
        guard fixture, installationFixtureRoot == nil else { throw CustodyRecordError.fenced }
        installationFixtureRoot = try TestIsolation.validateRoot(root)
    }
    private func testingBoundInstallationCandidate() throws -> InstallationCandidate {
        let fixed = try Self.testingInstallationCandidate()
        guard let root = installationFixtureRoot else { return fixed }
        let path = root + "/candidate/ShadowSync.app"
        var node = stat()
        if lstat(path, &node) != 0 {
            guard errno == ENOENT else { throw CustodyRecordError.fenced }; return fixed
        }
        guard try TestIsolation.validateRoot(root) == root else { throw CustodyRecordError.fenced }
        let artifact = try BundleArtifactIdentity.inspect(bundlePath: path, requireProduction: true)
        guard artifact.release == fixed.release else { throw CustodyRecordError.fenced }
        return InstallationCandidate(release: artifact.release, bundleDigest: artifact.canonicalSHA256,
            appCDHash: fixed.appCDHash, coordinatorCDHash: fixed.coordinatorCDHash)
    }
    static func testingInstallationCandidate() throws -> InstallationCandidate {
        let fixture = try InstallationControlFixtures.transaction().candidate!
        let release = try ReleaseIdentity(sourceRevision: fixture.release.sourceRevision,
            sourceInputSHA256: fixture.release.sourceInputSHA256,
            releaseContractSHA256: String(repeating: "c", count: 64), architecture: "arm64", buildMode: "production")
        return InstallationCandidate(release: release, bundleDigest: fixture.bundleDigest,
            appCDHash: fixture.appCDHash, coordinatorCDHash: fixture.coordinatorCDHash)
    }
    var testingAutomaticAdmission: Bool { custodianFixture }
    static func testingDiscovery(home: String? = nil) throws -> CustodyHelperExecutable {
        let result = try testing(releaseSHA256: String(repeating: "c", count: 64))
        result.discoveryFixture = true
        if let home { try result.bindTestingDiscoveryResources(home: home) }
        return result
    }
    func bindTestingDiscoveryResources(home: String) throws {
        guard discoveryFixture, discoveryFixtureGraphs == nil else { throw PublisherPolicyError.unavailable }
        let graphs = try DiscoveryFixtureResources.read(home: home, name: "command-graphs.json", maximum: 65_536)
        _ = try CommandGraphCatalog.decode(graphs.bytes)
        discoveryFixtureGraphs = graphs
        try revalidate()
    }
    func testingDiscoveryGraphResource() throws -> PolicyAuthorityFile? {
        guard discoveryFixture else { return nil }
        guard let discoveryFixtureGraphs else { throw PublisherPolicyError.unavailable }
        try revalidate()
        return discoveryFixtureGraphs
    }
    static func testingCustodian() throws -> CustodyHelperExecutable {
        let result = try testing(releaseSHA256: String(repeating: "c", count: 64))
        result.custodianFixture = true; return result
    }
    static func testing(releaseSHA256: String) throws -> CustodyHelperExecutable {
        let account = try EffectiveAccount.current()
        let path = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()).executablePath
        guard CustodyWire.hex(releaseSHA256, bytes: 32), path.hasPrefix("/private/tmp/shadow-sync-") else { throw PublisherPolicyError.unavailable }
        return Self(path: path, release: releaseSHA256, account: account,
                    snapshot: try PublisherExecutableSnapshot.capture(path: path, owner: account.uid), publisher: nil, files: [])
    }
    #endif
}

/// Constructed only by a serialized registry entry that still owns its resources.
/// Decoded journal/PID/UUID values cannot construct a retirement proof.
final class CustodyRetirementProof {
    enum Basis { case noSuccessfulSpawn, neverResumed(OwnedSpawnAnchor.UnexecutedProof), terminal(OwnedDirectChild, CustodyMessage) }
    let ticket: PreparedCustodyMetadata
    let resources: CustodyRequestResources
    let basis: Basis
    let reason: CustodyReason
    fileprivate init(ticket: PreparedCustodyMetadata, resources: CustodyRequestResources, basis: Basis, reason: CustodyReason) {
        self.ticket = ticket; self.resources = resources; self.basis = basis; self.reason = reason
    }
    func callerObservation(journal: CustodyJournal) throws -> Data {
        let caller = try ProcessIdentity.capture(processID: getpid(), generation: resources.request.binding.callerGeneration)
        let event: String, helper: CustodyProcessObservation?, status: Int32?
        switch basis {
        case .noSuccessfulSpawn: event = "no-successful-spawn"; helper = nil; status = nil
        case .neverResumed(let proof): event = "never-resumed-reaped"; helper = try proof.identity.map { try CustodyProcessObservation($0) }; status = proof.waitStatus
        case .terminal(let owner, _):
            guard case .reaped(let raw) = owner.observation else { throw CustodyRecordError.fenced }
            event = "custodian-reaped"; helper = try CustodyProcessObservation(owner.identity); status = raw
        }
        guard status.map({ $0 >= 0 && $0 <= 0xffff }) ?? true else { throw CustodyRecordError.fenced }
        return try CustodyWire.encode(.object([
            "schema": .string("shadow-sync-custody-caller/v1"), "binding": journal.binding.wire,
            "journal_sha256": .string(CustodyRecordBinding.digest(try journal.encode())),
            "event": .string(event), "custodian": helper?.wire ?? .null,
            "wait_status": status.map { .unsigned(UInt64($0)) } ?? .null,
            "observer": .object(["pid": .unsigned(UInt64(caller.processID)), "uid": .unsigned(UInt64(caller.userID)),
                "start_seconds": .unsigned(caller.startSeconds), "start_microseconds": .unsigned(caller.startMicroseconds),
                "generation": .string(caller.generation)]),
        ]), maximum: 65_536)
    }
}

struct CustodyRegistryResult: Sendable {
    enum Phase: Sendable { case starting, ready, running, cleanupPending, finished }
    let phase: Phase
    let reason: CustodyReason?
    let journal: CustodyJournal?
    let stdout: Data
    let stderr: Data
    let trace: Data
    init(phase: Phase, reason: CustodyReason?, journal: CustodyJournal?, stdout: Data, stderr: Data, trace: Data = Data()) {
        self.phase = phase; self.reason = reason; self.journal = journal
        self.stdout = stdout; self.stderr = stderr; self.trace = trace
    }
}

/// Process-lifetime ownership precedes every spawn. Only this serial queue may
/// reap its helpers. Resumed helpers receive control/EOF, never deadline KILL.
final class RetainedCleanupRegistry: @unchecked Sendable {
    static let shared = RetainedCleanupRegistry()
    fileprivate final class ResultCell: @unchecked Sendable {
        private let mutex = NSLock()
        private var completion = DispatchGroup()
        private var completionPublished = false
        private var value = CustodyRegistryResult(phase: .starting, reason: nil, journal: nil, stdout: Data(), stderr: Data())
        private var receipt: UInt64 = 0
        init() { completion.enter() }
        // This lock protects value copies only: no disk I/O, queue waits or callbacks.
        func publish(_ result: CustodyRegistryResult, deadline: UInt64) {
            mutex.lock()
            let terminal = result.phase == .finished || result.phase == .cleanupPending
            let wake = !completionPublished && (terminal || receipt != deadline) ? completion : nil
            value = result; receipt = deadline
            if terminal { completionPublished = true }
            else if wake != nil {
                // Cancellation can shorten the receipt while the result is
                // still nonterminal. Replace the notification under this same
                // lock, so each waiter captures its deadline and generation.
                completion = DispatchGroup(); completion.enter()
            }
            mutex.unlock()
            // Pending is caller-terminal while the registry retains the child.
            // Each captured generation wakes every waiter exactly once.
            wake?.leave()
        }
        func read() -> (CustodyRegistryResult, UInt64, DispatchGroup) {
            mutex.lock(); defer { mutex.unlock() }; return (value, receipt, completion)
        }
        #if SHADOW_SYNC_TESTING
        private var waitBarriers: [CustodyLeaseTestingBarrier] = []
        func pauseWaiters(_ barriers: [CustodyLeaseTestingBarrier]) {
            mutex.lock(); waitBarriers = barriers; mutex.unlock()
        }
        func takeWaitBarrier() -> CustodyLeaseTestingBarrier? {
            mutex.lock(); defer { mutex.unlock() }
            return waitBarriers.isEmpty ? nil : waitBarriers.removeFirst()
        }
        #endif
    }
    final class Handle: @unchecked Sendable {
        fileprivate let key: String
        fileprivate let cell: ResultCell
        fileprivate let registry: RetainedCleanupRegistry
        fileprivate init(_ entry: Entry, _ registry: RetainedCleanupRegistry) {
            key = entry.resources.request.binding.requestID
            cell = entry.cell; self.registry = registry
        }
        func snapshot() -> CustodyRegistryResult { cell.read().0 }
        func cancel() { registry.queue.async { if let entry = self.registry.entries[self.key] { self.registry.cancel(entry, reason: .cancelled) } } }
        /// Never synchronously waits for the registry's durable metadata queue.
        /// A deadline response leaves actual ownership in that registry.
        func wait() -> CustodyRegistryResult {
            while true {
                let (value, deadline, notification) = cell.read()
                if value.phase == .finished || value.phase == .cleanupPending { return value }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    registry.queue.async {
                        if let entry = self.registry.entries[self.key] { self.registry.pending(entry, reason: .timeout) }
                    }
                    return CustodyRegistryResult(phase: .cleanupPending, reason: value.reason ?? .timeout,
                        journal: nil, stdout: value.stdout, stderr: value.stderr, trace: value.trace)
                }
                // Publication wakes the caller immediately; the original
                // or shortened monotonic receipt bounds a blocked registry.
                #if SHADOW_SYNC_TESTING
                _ = cell.takeWaitBarrier()?.pause()
                #endif
                _ = notification.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
            }
        }
        #if SHADOW_SYNC_TESTING
        func testingPauseWaiters(_ barriers: [CustodyLeaseTestingBarrier]) { cell.pauseWaiters(barriers) }
        #endif
    }
    fileprivate final class Entry {
        let cell = ResultCell()
        let resources: CustodyRequestResources
        let helper: CustodyHelperExecutable
        let command: PreparedCustodyCommand?
        var metadata: PreparedCustodyMetadata?
        var mapping: CustodySpawnResources?
        var anchor: OwnedSpawnAnchor?
        var owner: OwnedDirectChild?
        var phase: CustodyRegistryResult.Phase = .starting
        var reason: CustodyReason?
        var resultJournal: CustodyJournal?
        var stdout = Data(), stderr = Data(), trace = Data()
        var traceEnded = false
        var stdoutEnded = false, stderrEnded = false, statusEnded = false, statusPoisoned = false, outputPoisoned = false
        var decoder = CustodyFrameDecoder()
        var state: CustodyAdmissionState
        var control = Data(), controlOffset = 0
        var queuedControl: [Data] = []
        var nextControl: UInt64 = 0
        var terminal: CustodyMessage?
        var resumed = false, spawnAttempted = false, bootstrapKilled = false, cancelled = false
        var metadataAttempted = false
        #if SHADOW_SYNC_TESTING
        var deferredRead: TestReadDeferral?
        var reapedObservations = 0
        let diagnosticStarted = DispatchTime.now().uptimeNanoseconds
        func diagnostic(_ stage: DiscoveryFixtureDiagnostic.Stage) {
            guard command != nil, resources.request.kind == .policyClassify else { return }
            DiscoveryFixtureDiagnostic.record(.registry, stage: stage,
                started: diagnosticStarted, deadline: resources.request.budget.work)
        }
        private var diagnosticFailures: UInt8 = 0
        func diagnosticFailure(_ error: Error, retiring: Bool) {
            guard command != nil, resources.request.kind == .policyClassify else { return }
            let flag: UInt8 = retiring ? 2 : 1
            guard diagnosticFailures & flag == 0 else { return }
            diagnosticFailures |= flag
            // Closed numeric observations only; never format arbitrary errors,
            // paths, requests or child output. Retained polling emits at most
            // one start and one retirement failure for this entry.
            let code: UInt64
            var systemCode: UInt64 = 0
            if let error = error as? CustodyRecordError {
                switch error {
                case .invalidRecord: code = 1
                case .invalidTransition: code = 2
                case .conflict: code = 3
                case .fenced: code = 4
                case .busy: code = 5
                case .unsafeMetadata: code = 6
                case .persistence(let value): code = 7; systemCode = UInt64(UInt32(bitPattern: value))
                case .committedCleanupFailure(let value): code = 8; systemCode = UInt64(UInt32(bitPattern: value))
                case .injectedFailure: code = 9
                }
            } else { code = 255 }
            var bits: UInt64 = retiring ? 64 : 0
            if metadataAttempted { bits |= 1 }; if metadata != nil { bits |= 2 }
            if spawnAttempted { bits |= 4 }; if anchor != nil { bits |= 8 }
            if owner != nil { bits |= 16 }; if resumed { bits |= 32 }
            if terminal != nil { bits |= 1 << 48 }; if statusEnded { bits |= 1 << 49 }
            if stdoutEnded { bits |= 1 << 50 }; if stderrEnded { bits |= 1 << 51 }
            if traceEnded { bits |= 1 << 52 }
            if let owner {
                switch owner.observation {
                case .running: bits |= 1 << 53
                case .reaped: bits |= 2 << 53
                case .ownershipFailure: bits |= 3 << 53
                }
            }
            DiscoveryFixtureDiagnostic.record(.registry, stage: .failure,
                started: diagnosticStarted, deadline: resources.request.budget.work,
                resultBits: bits | (code << 8) | (systemCode << 16))
        }
        #endif
        init(_ resources: CustodyRequestResources, _ helper: CustodyHelperExecutable, command: PreparedCustodyCommand?) throws {
            self.resources = resources; self.helper = helper; self.command = command
            traceEnded = resources.request.traceLimit == 0
            state = try CustodyAdmissionState(binding: resources.request.binding, budget: resources.request.budget)
            publish()
        }
        func publish() { cell.publish(result, deadline: state.budget.receipt) }
        var result: CustodyRegistryResult { CustodyRegistryResult(phase: phase, reason: reason, journal: resultJournal, stdout: stdout, stderr: stderr, trace: trace) }
        var outputReservation: UInt64 { resources.request.stdoutLimit + resources.request.stderrLimit + resources.request.traceLimit }
    }
    private let queue = DispatchQueue(label: "com.kleinperkins.shadow-sync.custody-registry")
    private var timer: DispatchSourceTimer?
    private var timerMilliseconds: Int?
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var cursor = 0
    // Fast reservation lock: only bounded in-memory bookkeeping, never I/O.
    // Includes queued construction so concurrent starts cannot exceed capacity.
    private let reservationMutex = NSLock()
    private var reservedIDs: Set<String> = []
    private var outputReserved: UInt64 = 0
    var hasRetainedWork: Bool {
        reservationMutex.lock(); defer { reservationMutex.unlock() }
        return !reservedIDs.isEmpty
    }
    private init() {}

    final class InstallationRetirement: @unchecked Sendable {
        private let registry: RetainedCleanupRegistry
        private let closed: ClosedInstallationBorrowing
        fileprivate init(registry: RetainedCleanupRegistry, closed: ClosedInstallationBorrowing) {
            self.registry = registry; self.closed = closed
        }
        func revalidate(for owner: InstallationTransactionOwner) throws {
            guard closed.belongs(to: owner) else { throw CustodyRecordError.fenced }
            try registry.validateInstallationRetirement(closed)
        }
    }
    private func validateInstallationRetirement(_ closed: ClosedInstallationBorrowing) throws {
        // No owner mutex is held while taking the registry's reservation lock.
        // reservedIDs includes queued admission and remains present until remove.
        // Conversely the closed family cannot reach zero while any prepared,
        // registry or inherited-resource parent alias still owns its leases.
        try validateActualInstallationRetirement { try closed.validate() }
    }
    private func validateActualInstallationRetirement(_ validateClosed: () throws -> Void) throws {
        try validateClosed()
        reservationMutex.lock()
        let empty = reservedIDs.isEmpty && outputReserved == 0
        reservationMutex.unlock()
        guard empty else { throw CustodyRecordError.fenced }
        try validateClosed()
    }
    func installationRetirement(after closed: ClosedInstallationBorrowing) throws -> InstallationRetirement {
        try validateInstallationRetirement(closed)
        return InstallationRetirement(registry: self, closed: closed)
    }

    final class InstallationStagedStartRetirement: @unchecked Sendable {
        private let registry: RetainedCleanupRegistry
        private let closed: ClosedInstallationStagedStarts
        fileprivate init(registry: RetainedCleanupRegistry, closed: ClosedInstallationStagedStarts) {
            self.registry = registry; self.closed = closed
        }
        func revalidate(for owner: InstallationTransactionOwner) throws {
            guard closed.belongs(to: owner) else { throw CustodyRecordError.fenced }
            try registry.validateInstallationStagedStartRetirement(closed)
        }
    }
    private func validateInstallationStagedStartRetirement(_ closed: ClosedInstallationStagedStarts) throws {
        // The same actual-removal accounting used by exclusive transfer. Public
        // finished/terminal observations are deliberately not inputs to this API.
        try validateActualInstallationRetirement { try closed.validate() }
    }
    func installationStagedStartRetirement(after closed: ClosedInstallationStagedStarts)
        throws -> InstallationStagedStartRetirement {
        try validateInstallationStagedStartRetirement(closed)
        return InstallationStagedStartRetirement(registry: self, closed: closed)
    }

    func start(_ command: PreparedCustodyCommand) throws -> Handle {
        // One-use claim and reservation are in-memory only. The serial owner
        // performs context/publisher/durable validation before any child exists.
        try command.claim(in: self)
        return try start(resources: command.resources, helper: command.helper, command: command)
    }
    #if SHADOW_SYNC_TESTING
    func start(resources: CustodyRequestResources, helper: CustodyHelperExecutable) throws -> Handle {
        try start(resources: resources, helper: helper, command: nil)
    }
    #endif
    private func start(resources: CustodyRequestResources, helper: CustodyHelperExecutable,
                       command: PreparedCustodyCommand?) throws -> Handle {
        let entry = try Entry(resources, helper, command: command), key = resources.request.binding.requestID
        reservationMutex.lock()
        guard reservedIDs.count < 128, !reservedIDs.contains(key),
              entry.outputReservation <= 67_108_864 - outputReserved else {
            reservationMutex.unlock(); throw CustodyRecordError.fenced
        }
        reservedIDs.insert(key); outputReserved += entry.outputReservation
        reservationMutex.unlock()
        // This queued closure retains actual resources before construction/spawn.
        // Return an independently readable handle before any metadata or signing I/O.
        queue.async {
            self.entries[key] = entry; self.order.append(key)
            #if SHADOW_SYNC_TESTING
            entry.deferredRead = self.nextReadDeferral; self.nextReadDeferral = nil
            entry.diagnostic(.queued)
            #endif
            do {
                guard resources.scope.observation == .open,
                      resources.request.binding.releaseSHA256 == helper.releaseSHA256 else { throw CustodyRecordError.fenced }
                try resources.request.budget.validate(kind: resources.request.kind,
                    permittedWorkSeconds: resources.request.kind.maximumWorkSeconds, now: DispatchTime.now().uptimeNanoseconds)
                try entry.command?.revalidate()
                try resources.validate(); try helper.revalidate()
                #if SHADOW_SYNC_TESTING
                entry.diagnostic(.validated)
                #endif
                entry.metadataAttempted = true
                entry.metadata = try resources.scope.prepare(resources.request)
                #if SHADOW_SYNC_TESTING
                entry.diagnostic(.metadata)
                #endif
                entry.mapping = try resources.takeSpawnResources()
                #if SHADOW_SYNC_TESTING
                try self.testFault(.beforeSpawn)
                #endif
                try self.spawn(entry)
            } catch {
                #if SHADOW_SYNC_TESTING
                entry.diagnosticFailure(error, retiring: false)
                #endif
                if !entry.metadataAttempted {
                    // No metadata transition or spawn was attempted; no active
                    // transaction can be forgotten by releasing this reservation.
                    entry.reason = .invalidResource; entry.phase = .finished; entry.publish()
                    resources.closeControl(); self.remove(entry)
                } else {
                    entry.reason = entry.metadata == nil ? .persistenceFailure : .startFailure
                    resources.scope.markPending(); entry.phase = .cleanupPending
                    resources.closeControl(); entry.mapping?.releaseChildCopies()
                    if !entry.resumed { self.killBootstrap(entry) }
                }
            }
            self.ensureTimer(); self.tick()
        }
        return Handle(entry, self)
    }
    /// Typed context closure sets its independent admission gate before this
    /// serialized metadata/control transition is queued. Actual entries retain
    /// their leases and anchors until ordinary verified retirement.
    func close(scope: CustodyMetadataScope) {
        queue.async {
            scope.close()
            for entry in self.entries.values where entry.resources.scope === scope {
                self.cancel(entry, reason: .cancelled)
            }
            self.ensureTimer()
        }
    }
    private func remove(_ entry: Entry) {
        let key = entry.resources.request.binding.requestID
        entries.removeValue(forKey: key); order.removeAll { $0 == key }
        reservationMutex.lock()
        if reservedIDs.remove(key) != nil { outputReserved -= entry.outputReservation }
        reservationMutex.unlock()
    }
    private func spawn(_ entry: Entry) throws {
        guard let mapping = entry.mapping else { throw CustodyResourceError.closed }
        defer { mapping.releaseChildCopies() }
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        let a = posix_spawn_file_actions_init(&actions); guard a == 0 else { throw CustodyResourceError.systemCall(a) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let b = posix_spawnattr_init(&attr); guard b == 0 else { throw CustodyResourceError.systemCall(b) }
        defer { posix_spawnattr_destroy(&attr) }
        try mapping.appendActions(to: &actions)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attr, flags) == 0, posix_spawnattr_setpgroup(&attr, 0) == 0 else { throw CustodyResourceError.invalidResource }
        let strings = entry.helper.arguments.map { strdup($0) }; defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw CustodyResourceError.limit }
        var args = strings + [nil], env: [UnsafeMutablePointer<CChar>?] = [nil]
        entry.spawnAttempted = true
        entry.anchor = try args.withUnsafeMutableBufferPointer { argv in
            try env.withUnsafeMutableBufferPointer { envp in
                try OwnedSpawnAnchor.spawn(executable: entry.helper.path, actions: &actions, attributes: &attr,
                    arguments: argv.baseAddress, environment: envp.baseAddress)
            }
        }
        // Store the real anchor before any fallible publisher or identity work.
        guard let anchor = entry.anchor else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        try testFault(.afterAnchor)
        #endif
        try entry.helper.validateSuspended(anchor)
        entry.owner = try anchor.transfer(expectedExecutable: entry.helper.path, generation: entry.resources.request.binding.callerGeneration)
        #if SHADOW_SYNC_TESTING
        try testFault(.afterOwner)
        #endif
        try entry.command?.revalidate()
        try entry.resources.validate(); try entry.helper.revalidate()
        guard entry.command?.admissionClosed != true, entry.resources.scope.observation == .open,
              DispatchTime.now().uptimeNanoseconds < entry.resources.request.budget.work,
              entry.owner!.send(SIGCONT) else { throw CustodyRecordError.fenced }
        entry.resumed = true
        #if SHADOW_SYNC_TESTING
        entry.diagnostic(.resumed)
        #endif
    }
    private func ensureTimer() {
        guard !entries.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = entries.values.contains {
            !$0.cancelled && $0.phase != .cleanupPending && now < $0.state.budget.work
        } ? 2 : 20
        if let timer {
            if timerMilliseconds != interval {
                timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval),
                    leeway: .milliseconds(interval == 2 ? 1 : 5))
                timerMilliseconds = interval
            }
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Active admission uses short bounded polls inside the unchanged 750ms
        // catalog budget. Draining/pending work keeps the prior 20ms cadence;
        // an unresolved transaction must not cause indefinite fast polling.
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval),
            leeway: .milliseconds(interval == 2 ? 1 : 5))
        timerMilliseconds = interval
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
    }
    private func killBootstrap(_ entry: Entry) {
        guard !entry.resumed, !entry.bootstrapKilled else { return }; entry.bootstrapKilled = true
        if let owner = entry.owner { _ = owner.send(SIGKILL) }
        else if let anchor = entry.anchor { _ = anchor.killSuspended() }
    }
    private func pending(_ entry: Entry, reason: CustodyReason) {
        guard entry.phase != .finished else { return }
        entry.phase = .cleanupPending; entry.reason = entry.reason ?? reason; entry.resources.scope.markPending(); entry.publish()
    }
    private func cancel(_ entry: Entry, reason: CustodyReason) {
        guard entry.phase != .finished, !entry.cancelled, entry.terminal == nil else { return }
        entry.cancelled = true; entry.reason = entry.reason ?? reason; entry.resources.scope.close()
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            let message = CustodyMessage(binding: entry.resources.request.binding, sequence: entry.nextControl, event: .cancel,
                outcome: nil, waitStatus: nil, receiptSHA256: nil)
            try entry.state.accept(message, now: now); entry.nextControl += 1
            try enqueueControl(entry, message: message)
        } catch {
            entry.resources.closeControl(); pending(entry, reason: .protocolFault)
        }
        if !entry.resumed { killBootstrap(entry) }; entry.publish()
    }
    private func enqueueControl(_ entry: Entry, message: CustodyMessage) throws {
        let bytes = try CustodyFrameDecoder.frame(message.encode())
        guard entry.queuedControl.count < 2 else { throw CustodyProtocolError.invalidSequence }
        if entry.control.isEmpty { entry.control = bytes; entry.controlOffset = 0 }
        else { entry.queuedControl.append(bytes) }
    }
    private func admitIfPrepared(_ entry: Entry) {
        var eligible = entry.command != nil
        #if SHADOW_SYNC_TESTING
        eligible = eligible || entry.helper.testingAutomaticAdmission
        #endif
        guard eligible, !entry.cancelled, entry.phase == .ready else { return }
        do {
            try entry.command?.revalidate(); try entry.resources.validate(); try entry.helper.revalidate()
            guard entry.command?.admissionClosed != true, entry.resources.scope.observation == .open,
                  DispatchTime.now().uptimeNanoseconds < entry.state.budget.work else { throw CustodyRecordError.fenced }
            let message = CustodyMessage(binding: entry.resources.request.binding,sequence:entry.nextControl,event:.admit,
                outcome:nil,waitStatus:nil,receiptSHA256:nil)
            try entry.state.accept(message,now:DispatchTime.now().uptimeNanoseconds)
            try enqueueControl(entry,message:message); entry.nextControl += 1; entry.phase = .running
            #if SHADOW_SYNC_TESTING
            entry.diagnostic(.admissionQueued)
            #endif
            // Ready was consumed on this serialized loop. The admission is
            // already fully validated; attempt its bounded nonblocking write
            // now instead of imposing another timer interval on the helper.
            // Backpressure and queued frames retain their ordinary tick path.
            flushControl(entry)
        } catch { cancel(entry,reason:.invalidResource) }
    }
    private func flushControl(_ entry: Entry) {
        guard !entry.control.isEmpty else { return }
        do {
            entry.controlOffset += try entry.resources.writeControl(entry.control, offset: entry.controlOffset)
            if entry.controlOffset == entry.control.count {
                #if SHADOW_SYNC_TESTING
                entry.diagnostic(.controlFlushed)
                #endif
                entry.control.removeAll(); entry.controlOffset = 0
                if !entry.queuedControl.isEmpty { entry.control = entry.queuedControl.removeFirst() }
                else if entry.cancelled { entry.resources.closeControl() }
            }
        } catch {
            try? entry.state.closeAdmission(now: DispatchTime.now().uptimeNanoseconds)
            entry.resources.scope.close(); entry.resources.closeControl(); entry.cancelled = true
            entry.control.removeAll(); entry.queuedControl.removeAll(); entry.controlOffset = 0
            pending(entry, reason: .ioFailure)
        }
    }
    private func consume(_ entry: Entry, budget: inout Int) {
        guard entry.resumed else { return }
        // Preserve each entry's prior maximum byte entitlement and the shared
        // tick budget. A second nonblocking sweep observes already-readable EOF
        // after small terminal/output frames without waiting another timer tick.
        // At most eight reads prevents a short-byte producer from monopolizing
        // this queue. EAGAIN, EOF and read errors end that stream's turn.
        var quantum = 4 * 16_388
        var statusReadable = true, outputReadable = true, errorReadable = true, traceReadable = true
        for _ in 0..<2 where budget > 0 && quantum > 0 {
            #if SHADOW_SYNC_TESTING
            let deferStatus = entry.deferredRead == .statusAfterAdmission && entry.state.admitted
            let deferOutput = entry.deferredRead == .outputUntilReleased
            #else
            let deferStatus = false, deferOutput = false
            #endif
            // A poisoned status stream cannot starve output drainage or be repaired
            // by a later valid frame. Continue bounded raw drainage to its real EOF.
            if !deferStatus, statusReadable, !entry.statusEnded, budget > 0, quantum > 0 {
                do {
                    switch try entry.resources.readStatus(maximum: min(16_388, budget, quantum)) {
                    case .wouldBlock: statusReadable = false
                    case .end:
                        statusReadable = false; entry.statusEnded = true
                        if !entry.statusPoisoned { try entry.decoder.finish() }
                    case .bytes(let bytes):
                        budget -= bytes.count; quantum -= bytes.count
                        if !entry.statusPoisoned {
                            for frame in try entry.decoder.append(bytes) {
                                let message = try CustodyMessage.decode(frame, expected: entry.resources.request.binding, channel: .status)
                                try entry.state.accept(message, now: DispatchTime.now().uptimeNanoseconds)
                                switch message.event {
                                case .ready:
                                    #if SHADOW_SYNC_TESTING
                                    entry.diagnostic(.ready)
                                    #endif
                                    if !entry.cancelled && entry.phase != .cleanupPending { entry.phase = .ready; admitIfPrepared(entry) }
                                case .pending: pending(entry, reason: entry.reason ?? .timeout)
                                case .terminal:
                                    entry.terminal = message
                                    #if SHADOW_SYNC_TESTING
                                    entry.diagnostic(.terminal)
                                    #endif
                                default: throw CustodyProtocolError.invalidSequence
                                }
                            }
                        }
                    }
                } catch {
                    statusReadable = false
                    entry.statusPoisoned = true; cancel(entry, reason: .protocolFault); pending(entry, reason: .protocolFault)
                }
            }
            for isError in [false, true] where budget > 0 && quantum > 0 && !deferOutput {
                if isError ? (entry.stderrEnded || !errorReadable) : (entry.stdoutEnded || !outputReadable) { continue }
                do {
                    switch try entry.resources.readOutput(error: isError, maximum: min(16_388, budget, quantum)) {
                    case .wouldBlock: if isError { errorReadable = false } else { outputReadable = false }
                    case .end: if isError { errorReadable = false; entry.stderrEnded = true } else { outputReadable = false; entry.stdoutEnded = true }
                    case .bytes(let bytes):
                        budget -= bytes.count; quantum -= bytes.count
                        let limit = Int(isError ? entry.resources.request.stderrLimit : entry.resources.request.stdoutLimit)
                        let count = isError ? entry.stderr.count : entry.stdout.count
                        if count + bytes.count > limit {
                            entry.outputPoisoned = true; cancel(entry, reason: .outputLimit); pending(entry, reason: .outputLimit)
                        }
                        let retained = bytes.prefix(max(0, limit - count))
                        if isError { entry.stderr.append(contentsOf: retained) } else { entry.stdout.append(contentsOf: retained) }
                    }
                } catch {
                    if isError { errorReadable = false } else { outputReadable = false }
                    entry.outputPoisoned = true; cancel(entry, reason: .ioFailure); pending(entry, reason: .ioFailure)
                }
            }
            if !deferOutput, traceReadable, !entry.traceEnded, budget > 0, quantum > 0 {
                do {
                    switch try entry.resources.readTrace(maximum: min(16_388, budget, quantum)) {
                    case .wouldBlock: traceReadable = false
                    case .end: traceReadable = false; entry.traceEnded = true
                    case .bytes(let bytes):
                        budget -= bytes.count; quantum -= bytes.count
                        let limit = Int(entry.resources.request.traceLimit)
                        if entry.trace.count + bytes.count > limit {
                            entry.outputPoisoned = true; cancel(entry, reason: .outputLimit); pending(entry, reason: .outputLimit)
                        }
                        entry.trace.append(contentsOf: bytes.prefix(max(0, limit - entry.trace.count)))
                    }
                } catch {
                    traceReadable = false
                    entry.outputPoisoned = true; cancel(entry, reason: .ioFailure); pending(entry, reason: .ioFailure)
                }
            }
        }
    }
    private func finish(_ entry: Entry, proof: CustodyRetirementProof) {
        do {
            let journal = try entry.resources.scope.completeFromRegistry(proof)
            #if SHADOW_SYNC_TESTING
            entry.diagnostic(.retired)
            #endif
            entry.resultJournal = journal; entry.phase = .finished
            entry.publish()
            entry.resources.closeControl(); entry.mapping?.releaseChildCopies()
            remove(entry)
        } catch {
            #if SHADOW_SYNC_TESTING
            entry.diagnosticFailure(error, retiring: true)
            #endif
            pending(entry, reason: .persistenceFailure)
        }
    }
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let keys = order
        for key in keys {
            guard let entry = entries[key] else { continue }
            if now >= entry.resources.request.budget.work { cancel(entry, reason: .timeout) }
            flushControl(entry)
            if let owner = entry.owner { _ = owner.poll() }
            else { _ = entry.anchor?.poll() }
            if now >= entry.state.budget.receipt { pending(entry, reason: entry.reason ?? .timeout) }
        }
        var ioBudget = 1_048_576
        if !keys.isEmpty {
            let start = cursor % keys.count
            for offset in 0..<keys.count where ioBudget > 0 {
                if let entry = entries[keys[(start + offset) % keys.count]] { consume(entry, budget: &ioBudget) }
                cursor = (start + offset + 1) % keys.count
            }
        }
        for key in keys {
            guard let entry = entries[key], let ticket = entry.metadata else { continue }
            // Status and child exit arrive independently. A terminal frame may
            // have become readable after this tick's first child observation.
            // Re-observe the same retained owner before evaluating retirement;
            // all stream, journal and actual-reaping proof requirements remain.
            if entry.terminal != nil, let owner = entry.owner { _ = owner.poll() }
            if !entry.resumed {
                if let anchor = entry.anchor {
                    if let proof = anchor.unexecutedProof() {
                        finish(entry, proof: CustodyRetirementProof(ticket: ticket, resources: entry.resources,
                            basis: .neverResumed(proof), reason: entry.reason ?? .startFailure))
                    }
                } else {
                    finish(entry, proof: CustodyRetirementProof(ticket: ticket, resources: entry.resources,
                        basis: .noSuccessfulSpawn, reason: entry.reason ?? .startFailure))
                }
                continue
            }
            if let owner = entry.owner {
                switch owner.observation {
                case .running: break
                case .ownershipFailure: pending(entry, reason: .ownershipLost)
                case .reaped(let status):
                    #if SHADOW_SYNC_TESTING
                    entry.reapedObservations += 1
                    #endif
                    guard status == 0 else { pending(entry, reason: .ioFailure); continue }
                    guard !entry.statusPoisoned, !entry.outputPoisoned else {
                        pending(entry, reason: .protocolFault); continue
                    }
                    if entry.statusEnded && entry.terminal == nil {
                        pending(entry, reason: .protocolFault); continue
                    }
                    // Child exit and pipe consumption have independent ordering.
                    // Retain the actual owner/resources while valid bytes and EOF
                    // remain unread. Deadlines and known faults still fence work.
                    guard let terminal = entry.terminal, entry.statusEnded,
                          entry.stdoutEnded, entry.stderrEnded, entry.traceEnded else { continue }
                    finish(entry, proof: CustodyRetirementProof(ticket: ticket, resources: entry.resources,
                        basis: .terminal(owner, terminal), reason: entry.reason ?? .none))
                }
            }
        }
        for entry in entries.values { entry.publish() }
        if entries.isEmpty { timer?.cancel(); timer = nil; timerMilliseconds = nil; cursor = 0 }
        else { ensureTimer() }
    }
    #if SHADOW_SYNC_TESTING
    enum TestReadDeferral { case statusAfterAdmission, outputUntilReleased }
    private var nextReadDeferral: TestReadDeferral?
    struct TestReadObservation {
        let terminalReceived: Bool, statusEOF: Bool, outputEOF: Bool, traceEOF: Bool
        let reapedObservations: Int
    }
    func testingDeferNextRead(_ mode: TestReadDeferral) { queue.sync { nextReadDeferral = mode } }
    func testingReadObservation(_ handle: Handle) -> TestReadObservation? {
        queue.sync {
            guard let entry = entries[handle.key] else { return nil }
            return TestReadObservation(terminalReceived: entry.terminal != nil,
                statusEOF: entry.statusEnded, outputEOF: entry.stdoutEnded && entry.stderrEnded,
                traceEOF: entry.traceEnded, reapedObservations: entry.reapedObservations)
        }
    }
    func testingReleaseDeferredRead(_ handle: Handle) {
        queue.sync { entries[handle.key]?.deferredRead = nil }
    }
    /// One serialized observation after bytes and EOF are already available.
    /// No timer race or elapsed-time threshold can satisfy this fixture proof.
    func testingReleaseDeferredReadAndTick(_ handle: Handle) -> Bool {
        queue.sync {
            guard let entry = entries[handle.key] else { return false }
            entry.deferredRead = nil
            tick()
            return entries[handle.key] == nil && handle.snapshot().phase == .finished
        }
    }
    func testingDelayQueue() {
        let entered = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); usleep(1_500_000) }
        _ = entered.wait(timeout: .now() + .seconds(3))
    }
    func testingCancelAndPauseQueue(_ handle: Handle, _ barrier: CustodyLeaseTestingBarrier) {
        queue.async {
            if let entry = self.entries[handle.key] { self.cancel(entry, reason: .cancelled) }
            _ = barrier.pause()
        }
    }
    enum TestCut { case beforeSpawn, afterAnchor, afterOwner }
    private var nextTestCut: TestCut?
    func testingFault(_ cut: TestCut) { queue.sync { nextTestCut = cut } }
    private func testFault(_ cut: TestCut) throws {
        if nextTestCut == cut { nextTestCut = nil; throw CustodyRecordError.injectedFailure }
    }
    func testingCloseControl(_ handle: Handle) {
        queue.sync {
            guard let entry = entries[handle.key] else { return }
            try? entry.state.closeAdmission(now: DispatchTime.now().uptimeNanoseconds)
            entry.resources.scope.close(); entry.resources.closeControl(); entry.cancelled = true
        }
    }
    func testingPoll(_ handle: Handle) -> OwnedDirectChildObservation? { queue.sync { entries[handle.key]?.owner?.observation } }
    static func testingInstance() -> RetainedCleanupRegistry { RetainedCleanupRegistry() }
    func testingIdentity(_ handle: Handle) -> ProcessIdentity? { queue.sync { entries[handle.key]?.owner?.identity } }
    func testingTicket(_ handle: Handle) -> PreparedCustodyMetadata? { queue.sync { entries[handle.key]?.metadata } }
    var testingCount: Int { queue.sync { entries.count } }
    /// Observation only, on the existing owner's queue. Fixture teardown must
    /// not exit while an original helper drains, even if its journal is pending.
    /// Reaping does not grant resource retirement or permission to delete state.
    var testingOriginalHelpersReaped: Bool {
        queue.sync {
            entries.values.allSatisfy { entry in
                if let owner = entry.owner {
                    if case .reaped = owner.poll() { return true }
                    return false
                }
                if let anchor = entry.anchor {
                    if case .reaped = anchor.poll() { return true }
                    return false
                }
                return true // No successful original spawn is held by this entry.
            }
        }
    }
    /// Fixture cleanup only: unresolved journal state is never called recovered.
    /// This refuses to abandon any actual unreaped process.
    func testingRequestCancellation() {
        queue.async {
            for entry in self.entries.values { self.cancel(entry, reason: .cancelled) }
            self.ensureTimer()
        }
    }
    func testingDispose() throws {
        try queue.sync {
            for entry in entries.values {
                if let owner = entry.owner { guard case .reaped = owner.poll() else { throw CustodyRecordError.fenced } }
                else if let anchor = entry.anchor { guard case .reaped = anchor.poll() else { throw CustodyRecordError.fenced } }
            }
            for entry in entries.values {
                entry.resources.closeControl(); entry.mapping?.releaseChildCopies(); entry.publish()
            }
            timer?.cancel(); timer = nil; timerMilliseconds = nil
            for entry in Array(entries.values) { remove(entry) }
        }
    }
    #endif
}
