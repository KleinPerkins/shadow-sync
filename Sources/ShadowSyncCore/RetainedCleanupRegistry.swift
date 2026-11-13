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
    var validationProfile: InstallationValidationProfile { lifecyclePublisher?.validationProfile ?? .production }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    var signedInheritedParent: SignedInstallationFixtureParentChannel.Inherited? {
        if case let .signedFixture(profile) = validationProfile { return profile.inheritedParent }; return nil
    }
    #endif
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
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case .signedFixture = validationProfile {
            guard let signedInheritedParent else { throw PublisherPolicyError.unavailable }
            let identity = try signedInheritedParent.authenticateParent(generation: generation, executable: path)
            guard identity.processID == pid else { throw PublisherPolicyError.unavailable }
            return identity
        }
        #endif
        let identity = try ProcessIdentity.capture(processID: pid, generation: generation, expectedExecutablePath: path)
        guard identity.userID == account.uid else { throw PublisherPolicyError.unavailable }
        if let publisher { try PublisherCodeVerifier.suspendedChild(pid, expected: publisher) }
        return identity
    }
    var arguments: [String] {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case .signedFixture = validationProfile { return [path, "--shadow-sync-signed-installation-custodian"] }
        #endif
        #if SHADOW_SYNC_TESTING
        if discoveryFixture { return [path, "--shadow-sync-discovery-custodian-fixture"] }
        if fixture { return [path, custodianFixture ? "--shadow-sync-custodian-fixture" : "--shadow-sync-custody-registry-fixture"] }
        #endif
        return [path, "--shadow-sync-command-custodian"]
    }
    #if SHADOW_SYNC_TESTING
    var testingPolicyTimingEligible: Bool {
        discoveryFixture && arguments == [path, "--shadow-sync-discovery-custodian-fixture"]
    }
    var testingInstallationSourceRoot: String? { fixture ? installationFixtureRoot : nil }
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
    #if SHADOW_SYNC_TESTING
    var testingCancellationObservation: RetainedCleanupRegistry.TestCancellationObservation? = nil
    #endif
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
        private var actualRetirementPublished = false
        private var retirementObservers: [InstallationObservationSubscription] = []
        func observeActualRetirement(on queue: DispatchQueue,
            observer: @escaping @Sendable () -> Void) -> InstallationObservationSubscription {
            let subscription = InstallationObservationSubscription(on: queue, observer: observer)
            mutex.lock()
            let published = actualRetirementPublished
            if !published { retirementObservers.append(subscription) }
            mutex.unlock()
            if published { subscription.publish() }
            return subscription
        }
        func publishActualRetirement() {
            mutex.lock()
            guard !actualRetirementPublished else { mutex.unlock(); return }
            actualRetirementPublished = true
            let observers = retirementObservers; retirementObservers.removeAll()
            mutex.unlock()
            for observer in observers { observer.publish() }
        }
        private var value = CustodyRegistryResult(phase: .starting, reason: nil, journal: nil, stdout: Data(), stderr: Data())
        private var receipt: UInt64 = 0
        private var stagedCompletion: StagedCommandCompletion?
        private var stagedRetirement: StagedRecoveryRetirement?
        func publishStagedRetirement(_ value: StagedRecoveryRetirement) {
            mutex.lock(); stagedRetirement = value; mutex.unlock()
        }
        func readStagedRetirement() throws -> StagedRecoveryRetirement {
            mutex.lock(); defer { mutex.unlock() }
            guard let stagedRetirement, value.phase == .finished else { throw CustodyRecordError.fenced }
            return stagedRetirement
        }
        func publishStagedCompletion(_ value: StagedCommandCompletion) {
            mutex.lock(); stagedCompletion = value; mutex.unlock()
        }
        func readStagedCompletion() throws -> StagedCommandCompletion {
            mutex.lock(); defer { mutex.unlock() }
            guard let stagedCompletion, value.phase == .finished else { throw CustodyRecordError.fenced }
            return stagedCompletion
        }
        init() { completion.enter() }
        // This lock protects value copies only: no disk I/O, queue waits or callbacks.
        func publish(_ result: CustodyRegistryResult, deadline: UInt64) {
            mutex.lock()
            let terminal = result.phase == .finished || result.phase == .cleanupPending
            let wake = !completionPublished && (terminal || receipt != deadline) ? completion : nil
            value = result; receipt = deadline
            #if SHADOW_SYNC_TESTING
            if cancellationRequested { value.testingCancellationObservation?.flags |= 1 }
            #endif
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
        private var cancellationRequested = false, cancellationObservationTaken = false
        func noteCancellationRequest() {
            mutex.lock(); cancellationRequested = true; mutex.unlock()
        }
        func takeCancellationObservation() -> TestCancellationObservation? {
            mutex.lock(); defer { mutex.unlock() }
            guard !cancellationObservationTaken, var sample = value.testingCancellationObservation else { return nil }
            cancellationObservationTaken = true
            if cancellationRequested { sample.flags |= 1 }
            return sample
        }
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
        #if SHADOW_SYNC_TESTING
        fileprivate var testingCancellationObservationArmed = false
        #endif
        fileprivate init(_ entry: Entry, _ registry: RetainedCleanupRegistry) {
            key = entry.resources.request.binding.requestID
            cell = entry.cell; self.registry = registry
        }
        func observeActualRetirement(on queue: DispatchQueue,
            observer: @escaping @Sendable () -> Void) -> InstallationObservationSubscription {
            cell.observeActualRetirement(on: queue, observer: observer)
        }
        func snapshot() -> CustodyRegistryResult { cell.read().0 }
        func stagedCompletion() throws -> StagedCommandCompletion { try cell.readStagedCompletion() }
        func stagedRecoveryRetirement() throws -> StagedRecoveryRetirement { try cell.readStagedRetirement() }
        func cancel() {
            #if SHADOW_SYNC_TESTING
            if testingCancellationObservationArmed { cell.noteCancellationRequest() }
            #endif
            registry.queue.async { if let entry = self.registry.entries[self.key] { self.registry.cancel(entry, reason: .cancelled) } }
        }
        /// Never synchronously waits for the registry's durable metadata queue.
        /// A deadline response leaves actual ownership in that registry.
        func wait() -> CustodyRegistryResult {
            while true {
                let (value, deadline, notification) = cell.read()
                if value.phase == .finished || value.phase == .cleanupPending { return value }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    registry.queue.async {
                        if let entry = self.registry.entries[self.key] { self.registry.observeWaitExpiry(entry) }
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
        func testingTakeCancellationObservation() -> TestCancellationObservation? {
            testingCancellationObservationArmed ? cell.takeCancellationObservation() : nil
        }
        func testingPauseWaiters(_ barriers: [CustodyLeaseTestingBarrier]) { cell.pauseWaiters(barriers) }
        #endif
    }
    fileprivate enum SpawnProgress {
        case notEntered, preparedNoSpawn, attemptingSpawn
        case anchored(ObjectIdentifier), transferred(ObjectIdentifier, ObjectIdentifier)
        case resumeAttempted, resumed
    }
    fileprivate enum StagedStartFinalization { case notAttempted, attempting, archived, failed, retired }
    fileprivate final class ExpiredCleanup {
        enum State { case awaitingOriginalProof, verifyingOnce, closingOnce, removed, uncertain }
        var state: State = .awaitingOriginalProof
        let witness: CustodyMetadataScope.ExpiredOriginalCleanup
        let ticket: ObjectIdentifier, resources: ObjectIdentifier, owner: ObjectIdentifier, record: ObjectIdentifier
        let request: UnvalidatedCustodyRequest
        let operation: UInt64, receipt: UInt64
        init(witness: CustodyMetadataScope.ExpiredOriginalCleanup, entry: Entry,
             ticket: PreparedCustodyMetadata, owner: OwnedDirectChild, record: InstallationCommandRetirement,
             operation: UInt64, receipt: UInt64) {
            self.witness = witness; self.ticket = ObjectIdentifier(ticket); resources = ObjectIdentifier(entry.resources)
            self.owner = ObjectIdentifier(owner); self.record = ObjectIdentifier(record); request = entry.resources.request
            self.operation = operation; self.receipt = receipt
        }
    }
    fileprivate enum RetirementRoute { case originalRefusal, resumedTerminal }
    fileprivate struct OriginalRefusalDrain {
        let ticket: ObjectIdentifier
        let resources: ObjectIdentifier
        let mapping: ObjectIdentifier
        let record: ObjectIdentifier
        let progress: SpawnProgress
    }
    fileprivate final class Entry {
        let cell = ResultCell()
        private var retainedResources: CustodyRequestResources?
        var resources: CustodyRequestResources { retainedResources! }
        let helper: CustodyHelperExecutable
        var command: PreparedCustodyCommand?
        func releaseCommandAliases() { command = nil; retainedResources = nil }
        var repositoryObserver: RepositoryCommandObserver?
        var consumerAdmitted = true
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
        var spawnProgress: SpawnProgress = .notEntered
        var originalRefusal: OriginalRefusalDrain?
        var expiredCleanup: ExpiredCleanup?
        var installationRecord: InstallationCommandRetirement?
        var stagedFinalization: StagedStartFinalization = .notAttempted
        var issuanceRoute: RetirementRoute?
        var issuanceCap: UInt64?
        var issuanceOperationDeadline: UInt64?
        var issuanceEffectiveReceipt: UInt64?
        var archiveStarted: UInt64?
        var archiveCompleted: UInt64?

        #if SHADOW_SYNC_TESTING
        var testingCancellationObservation: TestCancellationObservation?
        func cancellationSnapshot() -> TestCancellationObservation? {
            guard var sample = testingCancellationObservation else { return nil }
            sample.sampled = DispatchTime.now().uptimeNanoseconds
            switch phase {
            case .starting: sample.phase = 0
            case .ready: sample.phase = 1
            case .running: sample.phase = 2
            case .cleanupPending: sample.phase = 3
            case .finished: sample.phase = 4
            }
            switch state.phase {
            case .preparing: sample.protocolPhase = 0
            case .ready: sample.protocolPhase = 1
            case .admitted: sample.protocolPhase = 2
            case .draining: sample.protocolPhase = 3
            case .terminal: sample.protocolPhase = 4
            }
            sample.reason = reason.map { DiscoveryFixtureDiagnostic.pendingBits(reason: $0, owner: nil, state: 0) & 255 } ?? 12
            sample.work = state.budget.work; sample.term = state.budget.term
            sample.kill = state.budget.kill; sample.receipt = state.budget.receipt
            sample.operation = issuanceOperationDeadline ?? 0; sample.cap = issuanceCap ?? 0
            sample.archiveStarted = archiveStarted ?? 0; sample.archiveCompleted = archiveCompleted ?? 0
            // Preserve sticky retirement flags; all lower flags are current state.
            sample.flags &= ~UInt64(0xffffe)
            if cancelled { sample.flags |= 2 }; if resumed { sample.flags |= 4 }
            if state.admitted { sample.flags |= 8 }; if metadataAttempted { sample.flags |= 16 }
            if metadata != nil { sample.flags |= 32 }; if terminal != nil { sample.flags |= 64 }
            if statusEnded { sample.flags |= 128 }; if stdoutEnded { sample.flags |= 256 }
            if stderrEnded { sample.flags |= 512 }; if traceEnded { sample.flags |= 1024 }
            if statusPoisoned { sample.flags |= 2048 }; if outputPoisoned { sample.flags |= 4096 }
            if !control.isEmpty || !queuedControl.isEmpty { sample.flags |= 8192 }
            if let resources = retainedResources {
                if resources.originalRefusalControlClosed { sample.flags |= 16384 }
                if resources.scope.stagedCleanupPending { sample.flags |= 32768 }
                if resources.scope.observation != .open { sample.flags |= 65536 }
            }
            if let owner {
                switch owner.observation {
                case .running: sample.helper = 1
                case .reaped(let raw): sample.helper = 2; sample.rawStatus = UInt64(UInt32(bitPattern: raw))
                case .ownershipFailure: sample.helper = 3
                }
            }
            switch stagedFinalization {
            case .notAttempted: sample.finalization = 0
            case .attempting: sample.finalization = 1
            case .archived: sample.finalization = 2
            case .failed: sample.finalization = 3
            case .retired: sample.finalization = 4
            }
            switch expiredCleanup?.state {
            case nil: sample.expired = 0
            case .awaitingOriginalProof?: sample.expired = 1
            case .verifyingOnce?: sample.expired = 2
            case .closingOnce?: sample.expired = 3
            case .removed?: sample.expired = 4
            case .uncertain?: sample.expired = 5
            }
            testingCancellationObservation = sample
            return sample
        }
        func cancellationFailure(_ error: Error? = nil, point: UInt64) {
            guard testingCancellationObservation?.firstPoint == 0 else { return }
            testingCancellationObservation?.firstPoint = point
            let family: UInt64, system: UInt64
            if let error = error as? CustodyRecordError {
                switch error {
                case .invalidRecord: family = 1; system = 0
                case .invalidTransition: family = 2; system = 0
                case .conflict: family = 3; system = 0
                case .fenced: family = 4; system = 0
                case .busy: family = 5; system = 0
                case .unsafeMetadata: family = 6; system = 0
                case .persistence(let value): family = 7; system = UInt64(UInt32(bitPattern: value))
                case .committedCleanupFailure(let value): family = 8; system = UInt64(UInt32(bitPattern: value))
                case .injectedFailure: family = 9; system = 0
                }
            } else if let error = error as? CustodyResourceError {
                switch error {
                case .invalidResource: family = 10; system = 0
                case .closed: family = 11; system = 0
                case .limit: family = 12; system = 0
                case .systemCall(let value): family = 13; system = UInt64(UInt32(bitPattern: value))
                }
            } else { family = error == nil ? 0 : 255; system = 0 }
            testingCancellationObservation?.firstFamily = family
            testingCancellationObservation?.firstSystem = system
        }
        var stagedTickSchedulingProbe: StagedTickSchedulingProbe?
        var deferredRead: TestReadDeferral?
        var deferredOriginalRefusal = false
        var reapedObservations = 0
        let diagnosticStarted = DispatchTime.now().uptimeNanoseconds
        private var diagnosticKind: DiscoveryFixtureDiagnostic.RegistryKind {
            resources.request.kind == .repositoryGit ? .repositoryGit
                : (resources.request.kind == .retentionArchive ? .retentionArchive : .policyClassify)
        }
        func diagnostic(_ stage: DiscoveryFixtureDiagnostic.Stage) {
            guard command != nil, resources.request.kind == .policyClassify else { return }
            DiscoveryFixtureDiagnostic.record(.registry, stage: stage,
                started: diagnosticStarted, deadline: resources.request.budget.work)
        }
        private var diagnosticFailures: UInt8 = 0
        func diagnosticFailure(_ error: Error, retiring: Bool) {
            cancellationFailure(error, point: retiring ? 2 : 1)
            guard command != nil, (resources.request.kind == .policyClassify || resources.request.kind == .retentionArchive
                || resources.request.kind == .repositoryGit) else { return }
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
                resultBits: bits | (code << 8) | (systemCode << 16), kind: diagnosticKind)
        }
        func diagnosticPending() {
            guard command != nil, (resources.request.kind == .policyClassify || resources.request.kind == .retentionArchive
                || resources.request.kind == .repositoryGit),
                  let reason else { return }
            let observation = owner?.observation
            let reaped: Bool
            if case .some(.reaped) = observation { reaped = true } else { reaped = false }
            // Preserve at most the first pending observation and the first
            // subsequently observed reaped state. Repeated polling is silent.
            guard diagnosticFailures & 4 == 0 || (reaped && diagnosticFailures & 8 == 0) else { return }
            diagnosticFailures |= 4
            if reaped { diagnosticFailures |= 8 }
            var state: UInt64 = 0
            if terminal != nil { state |= 1 }
            if statusEnded { state |= 2 }; if stdoutEnded { state |= 4 }
            if stderrEnded { state |= 8 }; if traceEnded { state |= 16 }
            if metadata != nil { state |= 32 }; if resumed { state |= 64 }
            if statusPoisoned { state |= 128 }; if outputPoisoned { state |= 256 }
            DiscoveryFixtureDiagnostic.record(.registry, stage: .failure,
                started: diagnosticStarted, deadline: resources.request.budget.work,
                resultBits: DiscoveryFixtureDiagnostic.pendingBits(reason: reason,
                    owner: observation, state: state), kind: diagnosticKind)
        }
        #endif
        init(_ resources: CustodyRequestResources, _ helper: CustodyHelperExecutable, command: PreparedCustodyCommand?) throws {
            self.retainedResources = resources; self.helper = helper; self.command = command
            traceEnded = resources.request.traceLimit == 0
            state = try CustodyAdmissionState(binding: resources.request.binding, budget: resources.request.budget)
            publish()
        }
        func publish() { cell.publish(result, deadline: state.budget.receipt) }
        var result: CustodyRegistryResult {
            #if SHADOW_SYNC_TESTING
            var value = CustodyRegistryResult(phase: phase, reason: reason, journal: resultJournal, stdout: stdout, stderr: stderr, trace: trace)
            value.testingCancellationObservation = cancellationSnapshot()
            return value
            #else
            return CustodyRegistryResult(phase: phase, reason: reason, journal: resultJournal, stdout: stdout, stderr: stderr, trace: trace)
            #endif
        }
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
    private var reservationOutputs: [String: UInt64] = [:]
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
        try closed.bindRegistry(self)
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

    fileprivate final class InstallationCommandRetirement {
        weak var owner: InstallationTransactionOwner?
        let request: UnvalidatedCustodyRequest
        weak var scope: CustodyMetadataScope?
        weak var resources: CustodyRequestResources?
        weak var prepared: PreparedCustodyCommand?
        var retired = false
        var resourcesClosedSuccessfully = false
        var exactRemoval = false
        var issuanceQualified = false
        var sealIdentity: ObjectIdentifier?
        enum Delivery { case notAttempted, delivered, failed }
        var delivery: Delivery = .notAttempted

        var evidence: CustodyCatalogStore.ClosedStopArchiveEvidence?
        var archiveRequired = false
        var cleanupOnlyRemoved = false
        init(owner: InstallationTransactionOwner, resources: CustodyRequestResources, prepared: PreparedCustodyCommand?) {
            self.owner = owner; request = resources.request; scope = resources.scope
            self.resources = resources; self.prepared = prepared
        }
    }
    // Reservation lock protects the ledger as well as reservation accounting.
    // Records survive entry removal and weak scope/resource disappearance.
    private var installationCommands: [String: InstallationCommandRetirement] = [:]
    final class InstallationStagedStopRetirement: @unchecked Sendable {
        private let registry: RetainedCleanupRegistry
        private let closed: ClosedInstallationStagedStops
        fileprivate init(registry: RetainedCleanupRegistry, closed: ClosedInstallationStagedStops) {
            self.registry = registry; self.closed = closed
        }
        func revalidate(for owner: InstallationTransactionOwner, registry: RetainedCleanupRegistry) throws {
            guard self.registry === registry, closed.belongs(to: owner) else { throw CustodyRecordError.fenced }
            try registry.validateInstallationStagedStopRetirement(closed)
        }
    }
    private func validateInstallationStagedStopRetirement(_ closed: ClosedInstallationStagedStops) throws {
        try closed.validate(registry: self)
        reservationMutex.lock()
        let records = installationCommands.values.filter { $0.owner.map { closed.belongs(to: $0) } ?? false }
        let empty = reservedIDs.isEmpty && outputReserved == 0
        let retired = records.allSatisfy { $0.retired && $0.resourcesClosedSuccessfully && $0.scope == nil && $0.resources == nil && $0.prepared == nil
            && (!$0.archiveRequired || $0.evidence != nil) }
        reservationMutex.unlock()
        guard empty, retired else { throw CustodyRecordError.fenced }
        // Archive I/O and owner validation occur outside the registry lock.
        for record in records { try record.evidence?.validateClosedStops(closed, request: record.request) }
        try closed.validate(registry: self)
        reservationMutex.lock()
        let unchanged = reservedIDs.isEmpty && outputReserved == 0
            && records.count == installationCommands.values.filter({ $0.owner.map { closed.belongs(to: $0) } ?? false }).count
        reservationMutex.unlock()
        guard unchanged else { throw CustodyRecordError.fenced }
        try closed.validate(registry: self)
    }
    func installationStagedStopRetirement(after closed: ClosedInstallationStagedStops)
        throws -> InstallationStagedStopRetirement {
        try closed.claimRetirement(registry: self)
        try validateInstallationStagedStopRetirement(closed)
        return InstallationStagedStopRetirement(registry: self, closed: closed)
    }

    func start(_ command: PreparedCustodyCommand, repositoryObserver: RepositoryCommandObserver? = nil) throws -> Handle {
        // One-use claim and reservation are in-memory only. The serial owner
        // performs context/publisher/durable validation before any child exists.
        #if SHADOW_SYNC_TESTING
        reservationMutex.lock(); testingPreparedStartCalls += 1; reservationMutex.unlock()
        #endif
        try command.claim(in: self)
        return try start(resources: command.resources, helper: command.helper, command: command, repositoryObserver: repositoryObserver)
    }
    #if SHADOW_SYNC_TESTING
    func start(resources: CustodyRequestResources, helper: CustodyHelperExecutable) throws -> Handle {
        try start(resources: resources, helper: helper, command: nil)
    }
    #endif
    private func start(resources: CustodyRequestResources, helper: CustodyHelperExecutable,
                       command: PreparedCustodyCommand?, repositoryObserver: RepositoryCommandObserver? = nil) throws -> Handle {
        let installationOwner = try resources.scope.registerInstallationRetirement(in: self)
        guard !resources.request.authority.isInstallationStaged || installationOwner != nil else { throw CustodyRecordError.fenced }
        let entry = try Entry(resources, helper, command: command), key = resources.request.binding.requestID
        let handle = Handle(entry, self)
        reservationMutex.lock()
        let expiredInstallationRecords = installationCommands.filter { $0.value.owner == nil }
        // Their archive descriptors are released after the reservation lock.
        defer { withExtendedLifetime(expiredInstallationRecords) {} }
        for key in expiredInstallationRecords.keys { installationCommands.removeValue(forKey: key) }
        guard reservedIDs.count < 128, !reservedIDs.contains(key), installationCommands[key] == nil,
              entry.outputReservation <= 67_108_864 - outputReserved else {
            reservationMutex.unlock(); throw CustodyRecordError.fenced
        }
        reservedIDs.insert(key); reservationOutputs[key] = entry.outputReservation
        outputReserved += entry.outputReservation
        #if SHADOW_SYNC_TESTING
        if let command, testingCancellationCommand == ObjectIdentifier(command) {
            testingCancellationCommand = nil
            entry.testingCancellationObservation = TestCancellationObservation(budget: resources.request.budget)
            handle.testingCancellationObservationArmed = true
        }
        #endif
        if let installationOwner {
            let record = InstallationCommandRetirement(owner: installationOwner, resources: resources, prepared: command)
            installationCommands[key] = record; entry.installationRecord = record
        }
        reservationMutex.unlock()
        #if SHADOW_SYNC_TESTING
        if entry.testingCancellationObservation != nil { entry.publish() }
        #endif
        entry.repositoryObserver = repositoryObserver
        // Resources and the command are already retained and reserved. Consumer
        // acknowledgment runs on the caller, outside registry/authority locks.
        entry.consumerAdmitted = repositoryObserver?.admit() ?? true
        // This queued closure retains actual resources before construction/spawn.
        // Return an independently readable handle before any metadata or signing I/O.
        queue.async { [entry] in
            self.entries[key] = entry; self.order.append(key)
            #if SHADOW_SYNC_TESTING
            entry.deferredRead = self.nextReadDeferral; self.nextReadDeferral = nil
            entry.deferredOriginalRefusal = self.deferNextOriginalRefusal; self.deferNextOriginalRefusal = false
            if entry.resources.request.kind == .repositoryGit, let deferred = self.nextRepositoryReadDeferral {
                entry.deferredRead = deferred; self.nextRepositoryReadDeferral = nil
            }
            entry.diagnostic(.queued)
            #endif
            do {
                guard entry.consumerAdmitted, entry.resources.scope.observation == .open,
                      entry.resources.request.binding.releaseSHA256 == entry.helper.releaseSHA256 else { throw CustodyRecordError.fenced }
                try entry.resources.request.budget.validate(kind: entry.resources.request.kind,
                    permittedWorkSeconds: entry.resources.request.kind.maximumWorkSeconds, now: DispatchTime.now().uptimeNanoseconds)
                try entry.command?.revalidate()
                try entry.resources.validate(); try entry.helper.revalidate()
                #if SHADOW_SYNC_TESTING
                entry.diagnostic(.validated)
                #endif
                entry.metadataAttempted = true
                entry.metadata = try entry.resources.scope.prepare(entry.resources.request)
                #if SHADOW_SYNC_TESTING
                entry.diagnostic(.metadata)
                #endif
                entry.mapping = try entry.resources.takeSpawnResources()
                entry.spawnProgress = .preparedNoSpawn
                if entry.resources.request.authority == .installationStagedStart, let ticket = entry.metadata {
                    entry.issuanceOperationDeadline = try entry.resources.scope.validateOriginalStagedTicket(ticket,
                        request: entry.resources.request).absoluteUptimeNanoseconds
                }
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
                    entry.reason = .invalidResource
                    self.retireAndPublish(entry)
                } else {
                    entry.reason = entry.metadata == nil ? .persistenceFailure : .startFailure
                    do {
                        if try !self.beginOriginalRefusal(entry) {
                            self.pending(entry, reason: entry.reason ?? .startFailure)
                            entry.resources.closeControl(); entry.mapping?.releaseChildCopies()
                            if !entry.resumed { self.killBootstrap(entry) }
                        }
                    } catch {
                        self.pending(entry, reason: .ownershipLost)
                        entry.resources.closeControl(); entry.mapping?.releaseChildCopies()
                        if !entry.resumed { self.killBootstrap(entry) }
                    }
                }
            }
            self.ensureTimer(); self.tick()
        }
        return handle
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
    @discardableResult private func remove(_ entry: Entry) -> Bool {
        let key = entry.resources.request.binding.requestID
        guard entries[key] === entry, order.filter({ $0 == key }).count == 1 else { return false }
        reservationMutex.lock()
        let exact = reservedIDs.contains(key) && outputReserved >= entry.outputReservation
            && (entry.installationRecord == nil || installationCommands[key] === entry.installationRecord)
            && reservationOutputs[key] == entry.outputReservation
            && Set(reservationOutputs.keys) == reservedIDs
            && outputReserved == reservationOutputs.values.reduce(0, +)
        guard exact else {
            reservationMutex.unlock(); return false
        }
        reservedIDs.remove(key); reservationOutputs.removeValue(forKey: key)
        outputReserved -= entry.outputReservation
        reservationMutex.unlock()
        entries.removeValue(forKey: key); order.removeAll { $0 == key }
        return exact
    }
    private func spawn(_ entry: Entry) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.resources
        var diagnosticPassed = false
        var diagnosticMilestones: [UInt64] = []
        // The fixed testing discovery policy helper may receive one observation
        // opt-in. Request/control/status schemas and policy target streams stay fixed.
        defer {
            if entry.resources.request.kind == .policyClassify {
                DiscoveryFixtureDiagnostic.record(.helperPreparation, stage: diagnosticStage,
                    started: diagnosticStart, deadline: entry.resources.request.budget.work,
                    succeeded: diagnosticPassed, milestones: diagnosticMilestones)
            }
        }
        #endif
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
        #if SHADOW_SYNC_TESTING
        // Failure to allocate this optional one-entry environment skips diagnostics.
        // It must not replace the original spawn errno/result or acquire authority.
        let savedEnvironmentErrno = errno
        let timingEnvironment = TestingPolicyHelperTiming.activation(parentEnabled: DiscoveryFixtureDiagnostic.isEnabled,
            fixedHelper: entry.helper.testingPolicyTimingEligible, kind: entry.resources.request.kind)
            ? strdup(TestingPolicyHelperTiming.environmentEntry) : nil
        defer { free(timingEnvironment) }
        if let timingEnvironment { env = [timingEnvironment, nil] }
        errno = savedEnvironmentErrno
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .suspendedSpawn
        #endif
        entry.spawnAttempted = true
        entry.anchor = try args.withUnsafeMutableBufferPointer { argv in
            try env.withUnsafeMutableBufferPointer { envp in
                entry.spawnProgress = .attemptingSpawn
                return try OwnedSpawnAnchor.spawn(executable: entry.helper.path, actions: &actions, attributes: &attr,
                    arguments: argv.baseAddress, environment: envp.baseAddress)
            }
        }
        // Store the real anchor before any fallible publisher or identity work.
        guard let anchor = entry.anchor else { throw CustodyRecordError.fenced }
        entry.spawnProgress = .anchored(ObjectIdentifier(anchor))
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .suspendedVerification
        try testFault(.afterAnchor)
        #endif
        try entry.helper.validateSuspended(anchor)
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .ownerTransfer
        #endif
        entry.owner = try anchor.transfer(expectedExecutable: entry.helper.path, generation: entry.resources.request.binding.callerGeneration)
        entry.spawnProgress = .transferred(ObjectIdentifier(anchor), ObjectIdentifier(entry.owner!))
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .postflight
        try testFault(.afterOwner)
        #endif
        try entry.command?.revalidate()
        try entry.resources.validate(); try entry.helper.revalidate()
        guard entry.command?.admissionClosed != true, entry.resources.scope.observation == .open,
              DispatchTime.now().uptimeNanoseconds < entry.resources.request.budget.work else { throw CustodyRecordError.fenced }
        entry.spawnProgress = .resumeAttempted
        guard entry.owner!.send(SIGCONT) else { throw CustodyRecordError.fenced }
        entry.resumed = true; entry.spawnProgress = .resumed
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
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
    private func observeWaitExpiry(_ entry: Entry) {
        beginExpiredCleanupIfEligible(entry)
        if entry.expiredCleanup == nil { pending(entry, reason: .timeout) }
    }
    private func pending(_ entry: Entry, reason: CustodyReason) {
        guard entry.phase != .finished else { return }
        if let cleanup = entry.expiredCleanup { cleanup.state = .uncertain }
        if entry.originalRefusal != nil || entry.stagedFinalization != .notAttempted {
            entry.stagedFinalization = .failed
        }
        entry.phase = .cleanupPending; entry.reason = entry.reason ?? reason; entry.resources.scope.markPending(); entry.publish()
        #if SHADOW_SYNC_TESTING
        entry.diagnosticPending()
        #endif
    }
    private func cancel(_ entry: Entry, reason: CustodyReason) {
        if entry.expiredCleanup != nil { entry.resources.scope.close(); return }
        if entry.originalRefusal != nil {
            guard entry.phase != .finished, !entry.cancelled else { return }
            entry.cancelled = true; entry.reason = entry.reason ?? reason
            entry.resources.scope.close()
            do { try entry.state.closeAdmission(now: DispatchTime.now().uptimeNanoseconds) }
            catch { pending(entry, reason: .protocolFault) }
            entry.publish()
            return
        }
        guard entry.phase != .finished, !entry.cancelled, entry.terminal == nil else { return }
        entry.cancelled = true; entry.reason = entry.reason ?? reason; entry.resources.scope.close()
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            let message = CustodyMessage(binding: entry.resources.request.binding, sequence: entry.nextControl, event: .cancel,
                outcome: nil, waitStatus: nil, receiptSHA256: nil)
            try entry.state.accept(message, now: now); entry.nextControl += 1
            try enqueueControl(entry, message: message)
            #if SHADOW_SYNC_TESTING
            entry.testingCancellationObservation?.flags |= 1 << 20
            #endif
        } catch {
            #if SHADOW_SYNC_TESTING
            entry.cancellationFailure(error, point: 13)
            #endif
            entry.resources.closeControl(); pending(entry, reason: .protocolFault)
        }
        if !entry.resumed { killBootstrap(entry) }; entry.publish()
    }
    private func originalRecord(_ entry: Entry) throws -> InstallationCommandRetirement {
        let request = entry.resources.request
        reservationMutex.lock()
        let record = entry.installationRecord
        let owner = record?.owner
        let exact = record != nil && installationCommands[request.binding.requestID] === record
            && record?.request == request && record?.scope === entry.resources.scope
            && record?.resources === entry.resources && record?.prepared === entry.command
            && record?.retired == false && reservedIDs.contains(request.binding.requestID)
            && reservationOutputs[request.binding.requestID] == entry.outputReservation
            && Set(reservationOutputs.keys) == reservedIDs
            && outputReserved == reservationOutputs.values.reduce(0, +)
        reservationMutex.unlock()
        guard exact, let record, let owner else { throw CustodyRecordError.fenced }
        try owner.validateRetirementRegistry(self); try owner.revalidate()
        return record
    }
    private func issuanceLimit(_ entry: Entry, ticket: PreparedCustodyMetadata, refusal: Bool) throws -> UInt64 {
        let operation = try entry.resources.scope.validateOriginalStagedTicket(ticket, request: entry.resources.request)
        entry.issuanceOperationDeadline = operation.absoluteUptimeNanoseconds
        entry.issuanceEffectiveReceipt = entry.state.budget.receipt
        let limit = min(entry.state.budget.receipt, operation.absoluteUptimeNanoseconds)
        return refusal ? min(limit, entry.resources.request.budget.work) : limit
    }
    private func beginOriginalRefusal(_ entry: Entry) throws -> Bool {
        guard entry.resources.request.authority == .installationStagedStart,
              [.launchctlMutation, .launchctlRead, .signatureCheck].contains(entry.resources.request.kind) else { return false }
        guard let ticket = entry.metadata, let mapping = entry.mapping,
              !entry.resumed, !entry.statusPoisoned, !entry.outputPoisoned,
              !entry.resources.scope.stagedCleanupPending, entry.originalRefusal == nil else { throw CustodyRecordError.fenced }
        switch entry.spawnProgress {
        case .preparedNoSpawn:
            guard !entry.spawnAttempted, entry.anchor == nil, entry.owner == nil else { throw CustodyRecordError.fenced }
        case .anchored(let anchor):
            guard let original = entry.anchor, ObjectIdentifier(original) == anchor, entry.owner == nil,
                  original.observation == .suspended || original.unexecutedProof() != nil else { throw CustodyRecordError.fenced }
        case .transferred(let anchor, let owner):
            guard let original = entry.anchor, let child = entry.owner,
                  ObjectIdentifier(original) == anchor, ObjectIdentifier(child) == owner,
                  original.observation == .transferred else { throw CustodyRecordError.fenced }
            if case .ownershipFailure = child.observation { throw CustodyRecordError.fenced }
        default: throw CustodyRecordError.fenced
        }
        let record = try originalRecord(entry)
        let cap = try issuanceLimit(entry, ticket: ticket, refusal: true)
        guard DispatchTime.now().uptimeNanoseconds < cap else { throw CustodyRecordError.busy }
        try entry.resources.scope.closeForOriginalRefusal(ticket: ticket, request: entry.resources.request)
        entry.originalRefusal = OriginalRefusalDrain(ticket: ObjectIdentifier(ticket), resources: ObjectIdentifier(entry.resources),
            mapping: ObjectIdentifier(mapping), record: ObjectIdentifier(record), progress: entry.spawnProgress)
        entry.phase = .starting
        entry.resources.closeControl(); mapping.releaseChildCopies()
        guard entry.resources.originalRefusalControlClosed, mapping.childCopiesRetiredSuccessfully,
              DispatchTime.now().uptimeNanoseconds < cap else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        let observer = nextOriginalRefusalObservation; nextOriginalRefusalObservation = nil
        observer?(entry.anchor, entry.owner)
        if entry.deferredOriginalRefusal { return true }
        #endif
        try signalOriginalRefusal(entry)
        advanceOriginalRefusal(entry)
        return true
    }
    private func signalOriginalRefusal(_ entry: Entry) throws {
        guard !entry.bootstrapKilled else { return }
        if entry.anchor != nil {
            if let owner = entry.owner { _ = owner.poll() } else { _ = entry.anchor?.poll() }
            if entry.anchor?.unexecutedProof() == nil {
                entry.bootstrapKilled = true
                let signalled = entry.owner.map { $0.send(SIGKILL) } ?? entry.anchor!.killSuspended()
                if let owner = entry.owner { _ = owner.poll() } else { _ = entry.anchor?.poll() }
                guard signalled || entry.anchor?.unexecutedProof() != nil else { throw CustodyRecordError.fenced }
            }
        }
    }
    private func advanceOriginalRefusal(_ entry: Entry) {
        #if SHADOW_SYNC_TESTING
        if entry.deferredOriginalRefusal {
            if let ticket = entry.metadata,
               let cap = try? issuanceLimit(entry, ticket: ticket, refusal: true),
               DispatchTime.now().uptimeNanoseconds >= cap { pending(entry, reason: .timeout) }
            return
        }
        #endif
        // Even permanently failed entries stay on this exclusive route. Polling
        // the original child is permitted; archive/reconciliation is not retried.
        if let owner = entry.owner { _ = owner.poll() } else { _ = entry.anchor?.poll() }
        guard entry.stagedFinalization == .notAttempted else { return }
        do {
            guard let drain = entry.originalRefusal, let ticket = entry.metadata, let mapping = entry.mapping,
                  drain.ticket == ObjectIdentifier(ticket), drain.resources == ObjectIdentifier(entry.resources),
                  drain.mapping == ObjectIdentifier(mapping), !entry.resumed,
                  !entry.statusPoisoned, !entry.outputPoisoned,
                  entry.resources.originalRefusalControlClosed, mapping.childCopiesRetiredSuccessfully else { throw CustodyRecordError.fenced }
            let record = try originalRecord(entry)
            guard drain.record == ObjectIdentifier(record) else { throw CustodyRecordError.fenced }
            let cap = try issuanceLimit(entry, ticket: ticket, refusal: true)
            guard DispatchTime.now().uptimeNanoseconds < cap else { pending(entry, reason: .timeout); return }
            let basis: CustodyRetirementProof.Basis
            switch drain.progress {
            case .preparedNoSpawn:
                guard !entry.spawnAttempted, entry.anchor == nil, entry.owner == nil else { throw CustodyRecordError.fenced }
                basis = .noSuccessfulSpawn
            case .anchored(let identity):
                guard let anchor = entry.anchor, ObjectIdentifier(anchor) == identity, entry.owner == nil else { throw CustodyRecordError.fenced }
                if case .ownershipFailure = anchor.observation { throw CustodyRecordError.fenced }
                guard let proof = anchor.unexecutedProof() else { return }
                basis = .neverResumed(proof)
            case .transferred(let anchorID, let ownerID):
                guard let anchor = entry.anchor, let owner = entry.owner,
                      ObjectIdentifier(anchor) == anchorID, ObjectIdentifier(owner) == ownerID else { throw CustodyRecordError.fenced }
                if case .ownershipFailure = owner.observation { throw CustodyRecordError.fenced }
                guard let proof = anchor.unexecutedProof() else { return }
                basis = .neverResumed(proof)
            default: throw CustodyRecordError.fenced
            }
            finish(entry, proof: CustodyRetirementProof(ticket: ticket, resources: entry.resources,
                basis: basis, reason: entry.reason ?? .startFailure))
        } catch { pending(entry, reason: .ownershipLost) }
    }
    private func beginExpiredCleanupIfEligible(_ entry: Entry) {
        guard entry.expiredCleanup == nil, entry.originalRefusal == nil,
              entry.stagedFinalization == .notAttempted, entry.archiveStarted == nil,
              entry.resumed, case .resumed = entry.spawnProgress,
              entry.resources.request.authority == .installationStagedStart,
              [.launchctlMutation, .launchctlRead, .signatureCheck].contains(entry.resources.request.kind),
              !entry.statusPoisoned, !entry.outputPoisoned, !entry.resources.scope.stagedCleanupPending,
              let ticket = entry.metadata, let owner = entry.owner,
              let operation = entry.issuanceOperationDeadline,
              DispatchTime.now().uptimeNanoseconds >= min(operation, entry.state.budget.receipt) else { return }
        do {
            if case .ownershipFailure = owner.observation { throw CustodyRecordError.fenced }
            let record = try originalRecord(entry)
            let witness = try entry.resources.scope.markUnissuedOriginalExpiry(ticket: ticket,
                request: entry.resources.request, effectiveReceipt: entry.state.budget.receipt)
            entry.expiredCleanup = ExpiredCleanup(witness: witness, entry: entry, ticket: ticket,
                owner: owner, record: record, operation: operation, receipt: entry.state.budget.receipt)
            entry.stagedFinalization = .failed
            entry.phase = .cleanupPending; entry.reason = entry.reason ?? .timeout
            entry.resources.closeControl(); entry.control.removeAll(); entry.queuedControl.removeAll()
            entry.publish()
        } catch {
            #if SHADOW_SYNC_TESTING
            entry.cancellationFailure(error, point: 12)
            #endif
            pending(entry, reason: .ownershipLost)
        }
    }
    private func advanceExpiredCleanup(_ entry: Entry) {
        guard let cleanup = entry.expiredCleanup, cleanup.state == .awaitingOriginalProof else { return }
        do {
            guard let ticket = entry.metadata, let owner = entry.owner,
                  cleanup.ticket == ObjectIdentifier(ticket), cleanup.resources == ObjectIdentifier(entry.resources),
                  cleanup.owner == ObjectIdentifier(owner), cleanup.request == entry.resources.request,
                  entry.issuanceOperationDeadline == cleanup.operation,
                  entry.state.budget.receipt <= cleanup.receipt, cleanup.receipt <= cleanup.request.budget.receipt,
                  entry.stagedFinalization == .failed, entry.archiveStarted == nil,
                  !entry.statusPoisoned, !entry.outputPoisoned else { throw CustodyRecordError.fenced }
            try entry.resources.scope.validateOriginalExpiry(cleanup.witness, ticket: ticket, request: cleanup.request)
            _ = owner.poll()
            switch owner.observation {
            case .running: return
            case .ownershipFailure: throw CustodyRecordError.fenced
            case .reaped(let status): guard status == 0 else { throw CustodyRecordError.fenced }
            }
            guard let terminal = entry.terminal, entry.statusEnded, entry.stdoutEnded,
                  entry.stderrEnded, entry.traceEnded else { return }
            let record = try originalRecord(entry)
            guard ObjectIdentifier(record) == cleanup.record else { throw CustodyRecordError.fenced }
            cleanup.state = .verifyingOnce
            #if SHADOW_SYNC_TESTING
            if entry.testingCancellationObservation != nil { entry.publish() }
            nextExpiredCleanupObservation?(.beforeRead)
            #endif
            let proof = CustodyRetirementProof(ticket: ticket, resources: entry.resources,
                basis: .terminal(owner, terminal), reason: entry.reason ?? .timeout)
            let journal = try entry.resources.scope.observeExpiredOriginalTerminalForCleanup(proof, expiry: cleanup.witness)
            guard try originalRecord(entry) === record else { throw CustodyRecordError.fenced }
            try entry.resources.scope.validateOriginalExpiry(cleanup.witness, ticket: ticket, request: cleanup.request)
            #if SHADOW_SYNC_TESTING
            nextExpiredCleanupObservation?(.afterRead)
            #endif
            guard entry.resources.installationReadyForCheckedRetirement else { throw CustodyRecordError.fenced }
            cleanup.state = .closingOnce
            #if SHADOW_SYNC_TESTING
            if entry.testingCancellationObservation != nil { entry.publish() }
            #endif
            let scope = entry.resources.scope, resources = entry.resources, cell = entry.cell
            let receipt = min(cleanup.receipt, entry.state.budget.receipt)
            entry.mapping?.releaseChildCopies()
            resources.retire(installationReceipt: min(receipt, cleanup.operation))
            entry.command?.retireRepositoryResources()
            guard resources.installationRetiredSuccessfully,
                  entry.mapping?.childCopiesRetiredSuccessfully ?? false else { throw CustodyRecordError.fenced }
            try scope.validateOriginalExpiry(cleanup.witness, ticket: ticket, request: cleanup.request)
            guard try originalRecord(entry) === record else { throw CustodyRecordError.fenced }
            #if SHADOW_SYNC_TESTING
            nextExpiredCleanupObservation?(.checkedClose)
            #endif
            guard remove(entry) else { throw CustodyRecordError.fenced }
            #if SHADOW_SYNC_TESTING
            _ = entry.cancellationSnapshot()
            #endif
            entry.resultJournal = journal
            entry.mapping = nil; entry.owner = nil; entry.anchor = nil; entry.metadata = nil
            entry.repositoryObserver = nil
            entry.releaseCommandAliases()
            reservationMutex.lock()
            record.retired = true; record.resourcesClosedSuccessfully = true; record.exactRemoval = true
            record.issuanceQualified = false; record.delivery = .failed; record.sealIdentity = nil
            record.archiveRequired = true; record.cleanupOnlyRemoved = true
            reservationMutex.unlock()
            cleanup.state = .removed
            #if SHADOW_SYNC_TESTING
            nextExpiredCleanupObservation?(.removed)
            var copied = CustodyRegistryResult(phase: .cleanupPending, reason: entry.reason,
                journal: journal, stdout: entry.stdout, stderr: entry.stderr, trace: entry.trace)
            if var sample = entry.testingCancellationObservation {
                sample.sampled = DispatchTime.now().uptimeNanoseconds
                sample.expired = 4; sample.flags |= (1 << 22) | (1 << 23)
                copied.testingCancellationObservation = sample
            }
            cell.publish(copied, deadline: receipt)
            #else
            cell.publish(CustodyRegistryResult(phase: .cleanupPending, reason: entry.reason,
                journal: journal, stdout: entry.stdout, stderr: entry.stderr, trace: entry.trace), deadline: receipt)
            #endif
        } catch {
            // Every failed metadata/close attempt is one-way. No archive, second
            // read, raw close retry or replacement resource can repair it.
            cleanup.state = .uncertain
            #if SHADOW_SYNC_TESTING
            entry.cancellationFailure(error, point: 11)
            #endif
            pending(entry, reason: .ioFailure)
        }
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
                #if SHADOW_SYNC_TESTING
                if entry.cancelled && entry.queuedControl.isEmpty,
                   let flags = entry.testingCancellationObservation?.flags, flags & (1 << 20) != 0 {
                    entry.testingCancellationObservation?.flags |= 1 << 21
                }
                #endif
                entry.control.removeAll(); entry.controlOffset = 0
                if !entry.queuedControl.isEmpty { entry.control = entry.queuedControl.removeFirst() }
                else if entry.cancelled { entry.resources.closeControl() }
            }
        } catch {
            #if SHADOW_SYNC_TESTING
            entry.cancellationFailure(error, point: 14)
            #endif
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
    final class StagedCommandCompletion: @unchecked Sendable {
        private weak var scope: CustodyMetadataScope?
        private let registry: RetainedCleanupRegistry
        private let evidence: CustodyCatalogStore.StagedRetirementEvidence
        private let request: UnvalidatedCustodyRequest
        private let result: CustodyRegistryResult
        private let account: EffectiveAccount
        private let readinessLock = NSLock()
        private var retirementDeadline: MonotonicDeadline?
        fileprivate func markActualRetirement(_ deadline: MonotonicDeadline) {
            readinessLock.lock(); defer { readinessLock.unlock() }
            precondition(retirementDeadline == nil)
            retirementDeadline = deadline
        }
        func readinessDeadline() throws -> MonotonicDeadline {
            _ = try validate(operation: .kickstart)
            readinessLock.lock(); defer { readinessLock.unlock() }
            guard let deadline = retirementDeadline, !deadline.hasExpired else { throw CustodyRecordError.busy }
            return deadline
        }
        fileprivate init(registry: RetainedCleanupRegistry, scope: CustodyMetadataScope,
            evidence: CustodyCatalogStore.StagedRetirementEvidence, request: UnvalidatedCustodyRequest,
            result: CustodyRegistryResult, account: EffectiveAccount) {
            self.registry = registry; self.scope = scope; self.evidence = evidence
            self.request = request; self.result = result; self.account = account
        }
        func validate(operation: LifecycleLaunchCommand.Operation) throws -> CustodyCatalogStore.StagedRetirementEvidence {
            guard scope == nil else { throw CustodyRecordError.fenced }
            try evidence.validateNoPending()
            try registry.validateActualInstallationRetirement { guard self.scope == nil else { throw CustodyRecordError.fenced } }
            try evidence.validateCommittedRequest(request)
            let command = try LifecycleLaunchCommand(arguments: request.arguments, account: account)
            guard command.operation == operation else { throw CustodyRecordError.fenced }
            try command.validateStagedCompletion(result, request: request)
            return evidence
        }
    }
    fileprivate enum RecoveryArchive {
        case existingOpen(CustodyCatalogStore.StagedRetirementEvidence)
        case closedStart(CustodyCatalogStore.ClosedStagedStartArchive)
        var owner: InstallationTransactionOwner {
            switch self {
            case .existingOpen(let evidence): return evidence.retirementOwner
            case .closedStart(let archive): return archive.retirementOwner
            }
        }
        func validate(_ request: UnvalidatedCustodyRequest) throws -> CustodyCatalogStore.StagedRetirementEvidence {
            let evidence: CustodyCatalogStore.StagedRetirementEvidence
            switch self {
            case .existingOpen(let value): evidence = value
            case .closedStart(let archive): evidence = try archive.validate(request: request)
            }
            try evidence.validateNoPending(); try evidence.validateCommittedRequest(request)
            return evidence
        }
    }
    fileprivate final class CheckedCommandRetirementSeal {
        let registry: ObjectIdentifier
        let record: InstallationCommandRetirement
        let request: UnvalidatedCustodyRequest
        let checkedSuccess: Bool
        let exactRemoval: Bool
        let route: RetirementRoute?
        let cap: UInt64?
        let operationDeadline: UInt64?
        let effectiveReceipt: UInt64?
        let archiveStarted: UInt64?
        let archiveCompleted: UInt64?
        let retiredAt: UInt64
        fileprivate init(registry: RetainedCleanupRegistry, record: InstallationCommandRetirement,
            checkedSuccess: Bool, exactRemoval: Bool, route: RetirementRoute?, cap: UInt64?,
            operationDeadline: UInt64?, effectiveReceipt: UInt64?, archiveStarted: UInt64?, archiveCompleted: UInt64?, retiredAt: UInt64) {
            self.registry = ObjectIdentifier(registry); self.record = record; request = record.request
            self.checkedSuccess = checkedSuccess; self.exactRemoval = exactRemoval; self.route = route
            self.operationDeadline = operationDeadline; self.effectiveReceipt = effectiveReceipt
            self.cap = cap; self.archiveStarted = archiveStarted; self.archiveCompleted = archiveCompleted; self.retiredAt = retiredAt
        }
        var issuedWithinBounds: Bool {
            guard let route else { return cap == nil && archiveStarted == nil && archiveCompleted == nil }
            guard let cap, let operationDeadline, let effectiveReceipt,
                  effectiveReceipt <= request.budget.receipt,
                  cap == (route == .originalRefusal ? min(request.budget.work, effectiveReceipt, operationDeadline)
                                                   : min(effectiveReceipt, operationDeadline)),
                  let archiveStarted, let archiveCompleted,
                  archiveStarted <= archiveCompleted, archiveCompleted <= retiredAt,
                  retiredAt < cap else { return false }
            return route != .originalRefusal || cap <= request.budget.work
        }
    }
    private func validateCommandRetirement(_ seal: CheckedCommandRetirementSeal,
        record: InstallationCommandRetirement, request: UnvalidatedCustodyRequest,
        archive: RecoveryArchive) throws -> CustodyCatalogStore.StagedRetirementEvidence {
        func check() throws -> InstallationTransactionOwner {
            reservationMutex.lock(); defer { reservationMutex.unlock() }
            guard seal.registry == ObjectIdentifier(self), seal.record === record,
                  installationCommands[request.binding.requestID] === record, record.request == request,
                  seal.request == request, record.sealIdentity == ObjectIdentifier(seal),
                  seal.checkedSuccess, seal.exactRemoval, seal.issuedWithinBounds,
                  record.retired, record.resourcesClosedSuccessfully, record.exactRemoval, record.issuanceQualified,
                  record.delivery == .delivered, let owner = record.owner,
                  record.scope == nil, record.resources == nil, record.prepared == nil,
                  reservedIDs.isEmpty, reservationOutputs.isEmpty, outputReserved == 0 else { throw CustodyRecordError.fenced }
            return owner
        }
        let owner = try check()
        guard owner === archive.owner else { throw CustodyRecordError.fenced }
        try owner.validateRetirementRegistry(self); try owner.revalidate()
        let evidence = try archive.validate(request)
        guard try check() === owner else { throw CustodyRecordError.fenced }
        try owner.validateRetirementRegistry(self); try owner.revalidate()
        try evidence.validateNoPending(); try evidence.validateCommittedRequest(request)
        return evidence
    }
    /// Actual registry retirement, deliberately NOT successful command completion.
    /// It keeps the terminal outcome and caller archive unchanged. Only a fresh
    /// fixed diagnostic can additionally supply current service observation.
    final class StagedRecoveryRetirement: @unchecked Sendable {
        private weak var scope: CustodyMetadataScope?
        private let registry: RetainedCleanupRegistry
        private let archive: RecoveryArchive
        private let record: InstallationCommandRetirement
        private let sealLock = NSLock()
        private var seal: CheckedCommandRetirementSeal?
        fileprivate func sealAfterCheckedRetirement(_ seal: CheckedCommandRetirementSeal) {
            sealLock.lock(); defer { sealLock.unlock() }
            precondition(self.seal == nil && seal.record === record)
            self.seal = seal
        }
        private let request: UnvalidatedCustodyRequest
        private let result: CustodyRegistryResult
        private let account: EffectiveAccount
        fileprivate init(registry: RetainedCleanupRegistry, scope: CustodyMetadataScope,
            archive: RecoveryArchive, record: InstallationCommandRetirement, request: UnvalidatedCustodyRequest,
            result: CustodyRegistryResult, account: EffectiveAccount) {
            self.registry = registry; self.scope = scope; self.archive = archive; self.record = record
            self.request = request; self.result = result; self.account = account
        }
        func validate() throws -> CustodyCatalogStore.StagedRetirementEvidence {
            guard scope == nil, result.phase == .finished else { throw CustodyRecordError.fenced }
            sealLock.lock(); let captured = seal; sealLock.unlock()
            guard let captured else { throw CustodyRecordError.fenced }
            return try registry.validateCommandRetirement(captured, record: record, request: request, archive: archive)
        }
        #if SHADOW_SYNC_TESTING
        struct TestIssuanceObservation {
            let closedArchive: Bool, checkedClose: Bool, exactRemoval: Bool, validBounds: Bool
            let originalWork: UInt64, effectiveReceipt: UInt64?, operation: UInt64?, retiredAt: UInt64
        }
        func testingIssuanceObservation() -> TestIssuanceObservation? {
            sealLock.lock(); defer { sealLock.unlock() }
            guard let seal else { return nil }
            let closed: Bool
            switch archive { case .existingOpen: closed = false; case .closedStart: closed = true }
            return TestIssuanceObservation(closedArchive: closed, checkedClose: seal.checkedSuccess,
                exactRemoval: seal.exactRemoval, validBounds: seal.issuedWithinBounds,
                originalWork: request.budget.work, effectiveReceipt: seal.effectiveReceipt,
                operation: seal.operationDeadline, retiredAt: seal.retiredAt)
        }
        #endif
        func validateReadyHost(_ host: ProcessIdentity) throws {
            let state = try serviceState(mode: .installationStagedStart)
            try LifecycleLaunchCommand(operation: .bootstrap, account: account).validateReadyHost(state, host: host)
        }
        func serviceState() throws -> LaunchAgentState { try serviceState(mode: .installationStagedStop) }
        private func serviceState(mode: CustodyAuthorityMode) throws -> LaunchAgentState {
            _ = try validate()
            let command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
            var fixed = request.arguments == command.printArguments
            #if SHADOW_SYNC_TESTING
            // Fixture bytes still traverse actual custody, complete EOF/reap,
            // raw wait status and exact retirement. No wire value mints a token.
            fixed = fixed || request.arguments == ["installation-absent"]
                || request.arguments == ["installation-loaded"] || request.arguments == ["installation-foreign"]
            #endif
            guard fixed, request.authority == mode, request.kind == .launchctlRead,
                  result.reason == nil, let journal = result.journal,
                  journal.binding == (try CustodyRecordBinding(request.binding)),
                  journal.kind == request.kind, journal.authority == request.authority,
                  journal.budget == request.budget, journal.inputSHA256 == request.inputSHA256,
                  journal.resourcesSHA256 == request.resourcesSHA256,
                  journal.phase == .terminal, journal.reason == CustodyReason.none,
                  let raw = journal.waitStatus,
                  (raw == 0 && journal.outcome == .completed)
                    || (raw == 113 << 8 && journal.outcome == .commandFailed) else { throw CustodyRecordError.fenced }
            return try command.state(waitStatus: Int32(raw), stdout: result.stdout, stderr: result.stderr)
        }
        func classify(_ action: InstallationAction) throws -> LifecycleLaunchCommand.RecoveryLayout {
            let command = LifecycleLaunchCommand(operation: action == .kickstartCandidate ? .kickstart : .bootstrap, account: account)
            return try command.recoveryLayout(action: action, state: serviceState())
        }
    }
    private func retireAndPublish(_ entry: Entry, staged: CustodyCatalogStore.StagedRetirementEvidence? = nil,
                                  recoveryArchive: RecoveryArchive? = nil) {
        let originalScope = entry.resources.scope
        let record = entry.installationRecord
        let archive = recoveryArchive ?? staged.map { RecoveryArchive.existingOpen($0) }
        let stagedCompletion: StagedCommandCompletion?
        if entry.resources.request.kind == .launchctlMutation,
           let staged, let account = entry.command?.stagedCompletionAccount {
            stagedCompletion = StagedCommandCompletion(registry: self, scope: entry.resources.scope,
                evidence: staged, request: entry.resources.request,
                result: CustodyRegistryResult(phase: .finished, reason: entry.reason, journal: entry.resultJournal,
                    stdout: entry.stdout, stderr: entry.stderr, trace: entry.trace), account: account)
        } else { stagedCompletion = nil }
        let recovery: StagedRecoveryRetirement?
        if let archive, let record, let account = entry.command?.stagedCompletionAccount {
            recovery = StagedRecoveryRetirement(registry: self, scope: entry.resources.scope,
                archive: archive, record: record, request: entry.resources.request,
                result: CustodyRegistryResult(phase: .finished, reason: entry.reason, journal: entry.resultJournal,
                    stdout: entry.stdout, stderr: entry.stderr, trace: entry.trace), account: account)
        } else { recovery = nil }
        #if SHADOW_SYNC_TESTING
        // Every caller of retirement passes here; no-spawn and never-resumed
        // routes cannot satisfy this actual-owner/EOF guard. Synchronous lexical
        // reader ownership ends before resource, entry and alias release below.
        if entry.resumed, entry.helper.testingPolicyTimingEligible,
           entry.resources.request.kind == .policyClassify,
           TestingPolicyHelperWitness.shouldObserve(parentReason: entry.reason, terminalReason: entry.resultJournal?.reason),
           let owner = entry.owner, case .reaped = owner.observation,
           entry.statusEnded, entry.stdoutEnded, entry.stderrEnded, entry.traceEnded {
            TestingPolicyHelperWitness.observe(entry.resources.request)
        }
        #endif
        #if SHADOW_SYNC_TESTING
        if let recovery {
            let observer = nextProspectiveRecovery; nextProspectiveRecovery = nil
            do { try observer?(recovery, entry.resources) }
            catch { pending(entry, reason: .invalidResource); return }
        }
        #endif
        if let cap = entry.issuanceCap {
            guard DispatchTime.now().uptimeNanoseconds < cap else {
                #if SHADOW_SYNC_TESTING
                entry.cancellationFailure(point: 3)
                #endif
                pending(entry, reason: .timeout); return
            }
            guard !originalScope.stagedCleanupPending else {
                #if SHADOW_SYNC_TESTING
                entry.cancellationFailure(point: 4)
                #endif
                pending(entry, reason: .invalidResource); return
            }
        }
        reservationMutex.lock()
        if let record, installationCommands[entry.resources.request.binding.requestID] === record {
            record.evidence = staged?.closedStopArchiveEvidence(); record.archiveRequired = entry.metadataAttempted
        }
        reservationMutex.unlock()
        #if SHADOW_SYNC_TESTING
        _ = entry.cancellationSnapshot()
        #endif
        entry.mapping?.releaseChildCopies(); entry.mapping = nil
        entry.resources.retire(); entry.command?.retireRepositoryResources()
        entry.anchor = nil; entry.owner = nil; entry.metadata = nil
        let exactRemoval = remove(entry)
        guard exactRemoval else {
            #if SHADOW_SYNC_TESTING
            entry.cancellationFailure(point: 5)
            #endif
            pending(entry, reason: .invalidResource); return
        }
        let cell = entry.cell, deadline = entry.state.budget.receipt
        let result = CustodyRegistryResult(phase: .finished, reason: entry.reason,
            journal: entry.resultJournal, stdout: entry.stdout, stderr: entry.stderr, trace: entry.trace)
        let retirementObserver = entry.repositoryObserver
        entry.repositoryObserver = nil
        let installationResourcesClosed = entry.resources.installationRetiredSuccessfully
        if record != nil && !installationResourcesClosed { originalScope.markPending() }
        var ownerValid = true
        if let record {
            do {
                guard let owner = record.owner else { throw CustodyRecordError.fenced }
                if let archive { guard archive.owner === owner else { throw CustodyRecordError.fenced } }
                try owner.validateRetirementRegistry(self); try owner.revalidate()
            } catch {
                #if SHADOW_SYNC_TESTING
                entry.cancellationFailure(error, point: 6)
                #endif
                ownerValid = false; originalScope.markPending()
            }
        }
        #if SHADOW_SYNC_TESTING
        var cancellationSample = entry.cancellationSnapshot()
        #endif
        entry.releaseCommandAliases()
        // Keep the existing independent five-second readiness anchor at actual
        // alias release. It is never used as a recovery-token clock.
        let readinessDeadline = MonotonicDeadline(seconds: 5)
        let retiredAt = DispatchTime.now().uptimeNanoseconds
        let issuanceQualified = entry.issuanceCap.map { retiredAt < $0 } ?? true
        let qualified = record == nil || (installationResourcesClosed && exactRemoval
            && ownerValid && issuanceQualified && !originalScope.stagedCleanupPending)
        if !qualified { originalScope.markPending() }
        let seal = record.map { CheckedCommandRetirementSeal(registry: self, record: $0,
            checkedSuccess: installationResourcesClosed, exactRemoval: exactRemoval,
            route: entry.issuanceRoute, cap: entry.issuanceCap,
            operationDeadline: entry.issuanceOperationDeadline, effectiveReceipt: entry.issuanceEffectiveReceipt,
            archiveStarted: entry.archiveStarted, archiveCompleted: entry.archiveCompleted, retiredAt: retiredAt) }
        reservationMutex.lock()
        if let record, installationCommands[record.request.binding.requestID] === record {
            record.retired = exactRemoval
            record.resourcesClosedSuccessfully = installationResourcesClosed
            record.exactRemoval = exactRemoval; record.issuanceQualified = qualified
            record.sealIdentity = seal.map(ObjectIdentifier.init)
            if !qualified { record.delivery = .failed }
        }
        reservationMutex.unlock()
        if entry.stagedFinalization == .archived { entry.stagedFinalization = qualified ? .retired : .failed }
        if qualified, let seal { recovery?.sealAfterCheckedRetirement(seal) }
        if qualified { stagedCompletion?.markActualRetirement(readinessDeadline) }
        let failedReason: CustodyReason = issuanceQualified ? .ioFailure : .timeout
        #if SHADOW_SYNC_TESTING
        if var sample = cancellationSample {
            sample.sampled = retiredAt; sample.retiredAt = retiredAt
            sample.flags |= 1 << 22 // exact removal
            if installationResourcesClosed { sample.flags |= 1 << 23 }
            if ownerValid { sample.flags |= 1 << 24 }; if issuanceQualified { sample.flags |= 1 << 25 }
            sample.finalization = entry.stagedFinalization == .retired ? 4 : (entry.stagedFinalization == .failed ? 3 : sample.finalization)
            if sample.firstPoint == 0 && !qualified {
                sample.firstPoint = !installationResourcesClosed ? 7 : (!issuanceQualified ? 8 : 9)
            }
            sample.publication = 1
            cancellationSample = sample
            // Same phase/deadline, scalar-only copy; never publish finished early.
            var copied = CustodyRegistryResult(phase: entry.phase, reason: entry.reason,
                journal: entry.resultJournal, stdout: entry.stdout, stderr: entry.stderr, trace: entry.trace)
            copied.testingCancellationObservation = sample
            cell.publish(copied, deadline: deadline)
        }
        let publicationSample = cancellationSample
        let barrier = nextRetirementBarrier; nextRetirementBarrier = nil
        let scheduling = nextReadinessSchedulingProbe; nextReadinessSchedulingProbe = nil
        // This cut is BEFORE dispatching delivery, the previously untested gap.
        scheduling?.captureAndPause(readinessDeadline)
        #endif
        // This following turn retains no Entry, prepared command, proof, resource
        // bundle, context or lease. All original finish/tick/start frame aliases
        // have returned before callback/finished delivery. The caller still waits
        // only to its original receipt deadline; no synchronous queue join occurs.
        queue.async {
            #if SHADOW_SYNC_TESTING
            _ = barrier?.pause()
            #endif
            let observed = retirementObserver?.retire() ?? true
            let delivered = qualified && observed
            self.reservationMutex.lock()
            if let record, self.installationCommands[record.request.binding.requestID] === record {
                if record.delivery == .notAttempted { record.delivery = delivered ? .delivered : .failed }
            }
            self.reservationMutex.unlock()
            if delivered, let stagedCompletion {
                // Delivery carries the boundary timestamp unchanged; queued
                // consumers can only spend, never restart, that budget.
                cell.publishStagedCompletion(stagedCompletion)
            }
            if delivered, let recovery { cell.publishStagedRetirement(recovery) }
            #if SHADOW_SYNC_TESTING
            var copied = CustodyRegistryResult(phase: qualified ? .finished : .cleanupPending,
                reason: delivered ? result.reason : (qualified ? .ioFailure : failedReason),
                journal: result.journal, stdout: result.stdout, stderr: result.stderr, trace: result.trace)
            if var sample = publicationSample {
                sample.sampled = DispatchTime.now().uptimeNanoseconds
                sample.publication = delivered ? 2 : 3
                if sample.firstPoint == 0 && !observed { sample.firstPoint = 10 }
                copied.testingCancellationObservation = sample
            }
            cell.publish(copied, deadline: deadline)
            #else
            cell.publish(CustodyRegistryResult(phase: qualified ? .finished : .cleanupPending,
                reason: delivered ? result.reason : (qualified ? .ioFailure : failedReason),
                journal: result.journal, stdout: result.stdout, stderr: result.stderr, trace: result.trace), deadline: deadline)
            #endif
            // Only this following-turn publication follows actual removal and
            // resource/alias release. cleanupPending never publishes this notice.
            if delivered { cell.publishActualRetirement() }
        }
    }
    private func finish(_ entry: Entry, proof: CustodyRetirementProof) {
        let request = entry.resources.request
        let guarded: Bool
        if entry.originalRefusal != nil { guarded = true }
        else if request.authority == .installationStagedStart,
                [.launchctlMutation, .launchctlRead, .signatureCheck].contains(request.kind),
                case .terminal = proof.basis { guarded = true }
        else { guarded = false }
        if guarded && entry.stagedFinalization != .notAttempted { return }
        do {
            if guarded {
                guard proof.resources === entry.resources, proof.ticket === entry.metadata,
                      !entry.statusPoisoned, !entry.outputPoisoned else { throw CustodyRecordError.fenced }
                _ = try originalRecord(entry)
                if entry.originalRefusal == nil {
                    guard case .resumed = entry.spawnProgress, case .terminal(let owner, let terminal) = proof.basis,
                          owner === entry.owner, terminal == entry.terminal, case .reaped(0) = owner.observation,
                          entry.statusEnded, entry.stdoutEnded, entry.stderrEnded, entry.traceEnded else { throw CustodyRecordError.fenced }
                }
                let cap = try issuanceLimit(entry, ticket: proof.ticket, refusal: entry.originalRefusal != nil)
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < cap else {
                    beginExpiredCleanupIfEligible(entry)
                    if entry.expiredCleanup != nil { advanceExpiredCleanup(entry) }
                    else { pending(entry, reason: .timeout) }
                    return
                }
                entry.issuanceRoute = entry.originalRefusal != nil ? .originalRefusal : .resumedTerminal
                entry.issuanceCap = cap; entry.archiveStarted = now
                entry.stagedFinalization = .attempting
                #if SHADOW_SYNC_TESTING
                if entry.testingCancellationObservation != nil { entry.publish() }
                #endif
            }
            #if SHADOW_SYNC_TESTING
            try nextFinalizationObservation?(.beforeArchive)
            #endif
            let journal = try entry.resources.scope.completeFromRegistry(proof, issuanceDeadline: entry.issuanceCap)
            if let cap = entry.issuanceCap, DispatchTime.now().uptimeNanoseconds >= cap { throw CustodyRecordError.busy }
            #if SHADOW_SYNC_TESTING
            entry.diagnostic(.retired)
            try nextFinalizationObservation?(.afterArchive)
            #endif
            entry.resultJournal = journal
            let staged = try entry.resources.scope.stagedRetirementEvidence(for: request)
            let archive: RecoveryArchive?
            if let staged { archive = .existingOpen(staged) }
            else if guarded, let closed = try entry.resources.scope.closedStagedStartArchive(after: proof) { archive = .closedStart(closed) }
            else { archive = nil }
            if guarded {
                guard archive != nil, !entry.resources.scope.stagedCleanupPending else { throw CustodyRecordError.fenced }
                _ = try originalRecord(entry)
                let now = DispatchTime.now().uptimeNanoseconds
                guard let cap = entry.issuanceCap, now < cap else { throw CustodyRecordError.busy }
                entry.archiveCompleted = now; entry.stagedFinalization = .archived
            }
            retireAndPublish(entry, staged: staged, recoveryArchive: archive)
        } catch {
            if guarded { entry.stagedFinalization = .failed }
            #if SHADOW_SYNC_TESTING
            entry.diagnosticFailure(error, retiring: true)
            #endif
            pending(entry, reason: entry.issuanceCap.map { DispatchTime.now().uptimeNanoseconds >= $0 } == true
                ? .timeout : .persistenceFailure)
        }
    }
    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let keys = order
        for key in keys {
            guard let entry = entries[key] else { continue }
            if entry.originalRefusal != nil { advanceOriginalRefusal(entry); continue }
            if entry.expiredCleanup == nil {
                if now >= entry.resources.request.budget.work { cancel(entry, reason: .timeout) }
                flushControl(entry)
            }
            #if SHADOW_SYNC_TESTING
            // One real scheduler cut after this tick's time/cancellation decision
            // and before its EXISTING owner poll and stream consumption. Resume
            // unchanged production operations; add no owner polls or proof.
            if let probe = entry.stagedTickSchedulingProbe,
               entry.resumed, entry.state.admitted, !entry.cancelled, entry.terminal == nil,
               entry.resources.request.authority == .installationStagedStart,
               let operation = entry.issuanceOperationDeadline, let owner = entry.owner,
               now < entry.resources.request.budget.work {
                entry.stagedTickSchedulingProbe = nil
                _ = probe.pause(work: entry.resources.request.budget.work,
                    receipt: entry.state.budget.receipt, operation: operation, sampled: now, original: owner)
            }
            #endif
            if let owner = entry.owner { _ = owner.poll() }
            else { _ = entry.anchor?.poll() }
            beginExpiredCleanupIfEligible(entry)
            if entry.expiredCleanup == nil && now >= entry.state.budget.receipt { pending(entry, reason: entry.reason ?? .timeout) }
        }
        var ioBudget = 1_048_576
        if !keys.isEmpty {
            let start = cursor % keys.count
            for offset in 0..<keys.count where ioBudget > 0 {
                if let entry = entries[keys[(start + offset) % keys.count]], entry.originalRefusal == nil { consume(entry, budget: &ioBudget) }
                cursor = (start + offset + 1) % keys.count
            }
        }
        for key in keys {
            guard let entry = entries[key] else { continue }
            if entry.expiredCleanup != nil { advanceExpiredCleanup(entry); continue }
            guard let ticket = entry.metadata, entry.originalRefusal == nil,
                  entry.stagedFinalization == .notAttempted else { continue }
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
    // Closed scalar observation; carries no command/resource/owner identity or authority.
    struct TestCancellationObservation: Sendable {
        var sampled: UInt64 = 0, phase: UInt64 = 0, protocolPhase: UInt64 = 0, reason: UInt64 = 12
        var flags: UInt64 = 0, helper: UInt64 = 0, rawStatus: UInt64 = 0
        let issued: UInt64, originalWork: UInt64, originalTerm: UInt64, originalKill: UInt64, originalReceipt: UInt64
        var work: UInt64 = 0, term: UInt64 = 0, kill: UInt64 = 0, receipt: UInt64 = 0
        var operation: UInt64 = 0, cap: UInt64 = 0, archiveStarted: UInt64 = 0, archiveCompleted: UInt64 = 0
        var retiredAt: UInt64 = 0, finalization: UInt64 = 0, expired: UInt64 = 0, publication: UInt64 = 0
        var firstPoint: UInt64 = 0, firstFamily: UInt64 = 0, firstSystem: UInt64 = 0
        init(budget: CustodyBudget) {
            issued = budget.issued; originalWork = budget.work; originalTerm = budget.term
            originalKill = budget.kill; originalReceipt = budget.receipt
        }
        func emit() {
            var line = "M6 CANCEL OBSERVATION v1"
            line += " sampled=\(sampled) phase=\(phase) protocol=\(protocolPhase) reason=\(reason) flags=\(flags) helper=\(helper) status=\(rawStatus)"
            line += " issued=\(issued) originalWork=\(originalWork) originalTerm=\(originalTerm) originalKill=\(originalKill) originalReceipt=\(originalReceipt)"
            line += " work=\(work) term=\(term) kill=\(kill) receipt=\(receipt) operation=\(operation) cap=\(cap) archiveStarted=\(archiveStarted) archiveCompleted=\(archiveCompleted)"
            line += " retired=\(retiredAt) finalization=\(finalization) expired=\(expired) publication=\(publication) firstPoint=\(firstPoint) firstFamily=\(firstFamily) firstSystem=\(firstSystem)\n"
            fputs(line, stderr)
        }
    }
    private var testingCancellationCommand: ObjectIdentifier?
    func testingArmCancellationObservation(_ command: PreparedCustodyCommand) throws {
        reservationMutex.lock(); defer { reservationMutex.unlock() }
        guard testingCancellationCommand == nil else { throw CustodyRecordError.fenced }
        testingCancellationCommand = ObjectIdentifier(command)
    }
    final class StagedTickSchedulingProbe: @unchecked Sendable {
        let barrier = CustodyLeaseTestingBarrier()
        private let lock = NSLock()
        private var captured: (work: UInt64, receipt: UInt64, operation: UInt64, sampled: UInt64)?
        private weak var original: OwnedDirectChild?
        fileprivate func pause(work: UInt64, receipt: UInt64, operation: UInt64, sampled: UInt64,
                               original: OwnedDirectChild) -> Bool {
            lock.lock(); captured = (work, receipt, operation, sampled); self.original = original; lock.unlock()
            let released = barrier.pause()
            lock.lock(); self.original = nil; lock.unlock()
            return released
        }
        var originalTerminationAvailable: Bool {
            lock.lock(); let owner = original; lock.unlock()
            return owner?.testingOriginalTerminationAvailable() == true
        }
        var bounds: (work: UInt64, receipt: UInt64, operation: UInt64, sampled: UInt64)? {
            lock.lock(); defer { lock.unlock() }; return captured
        }
    }
    @_silgen_name("shadowSyncTesting_stagedExpiryTickPause")
    @inline(never)
    func testingPauseStagedTick(_ handle: Handle, _ probe: StagedTickSchedulingProbe) throws {
        try queue.sync {
            guard let entry = entries[handle.key], entry.resources.request.authority == .installationStagedStart,
                  entry.stagedTickSchedulingProbe == nil, entry.terminal == nil,
                  DispatchTime.now().uptimeNanoseconds < entry.resources.request.budget.work else {
                throw CustodyRecordError.fenced
            }
            entry.stagedTickSchedulingProbe = probe
        }
    }
    struct TestStagedExpiryObservation {
        let request: UnvalidatedCustodyRequest
        let operation: UInt64, effectiveReceipt: UInt64
        let resumed: Bool, statusPoisoned: Bool, outputPoisoned: Bool
        let cleanupEntered: Bool, cleanupUncertain: Bool, archiveAttempted: Bool
    }
    // Read-only snapshots of the real serialized Entry; never fixture flags.
    func testingStagedExpiryObservation(_ handle: Handle) -> TestStagedExpiryObservation? {
        queue.sync {
            guard let entry = entries[handle.key], let operation = entry.issuanceOperationDeadline,
                  entry.resources.request.authority == .installationStagedStart else { return nil }
            return TestStagedExpiryObservation(request: entry.resources.request, operation: operation,
                effectiveReceipt: entry.state.budget.receipt, resumed: entry.resumed,
                statusPoisoned: entry.statusPoisoned, outputPoisoned: entry.outputPoisoned,
                cleanupEntered: entry.expiredCleanup != nil,
                cleanupUncertain: entry.expiredCleanup?.state == .uncertain,
                archiveAttempted: entry.archiveStarted != nil)
        }
    }
    enum TestExpiredSubstitution: Equatable { case ticket, record, helper, message }
    // Negative-only substitution uses a second actually retained command. Both
    // original owners remain retained; no decoded/fabricated positive proof is
    // introduced, and the original aliases are restored before returning.
    func testingRejectExpiredSubstitution(_ handle: Handle, from other: Handle,
                                         kind: TestExpiredSubstitution) throws {
        guard other.registry !== self else { throw CustodyRecordError.fenced }
        let foreign = try other.registry.queue.sync { () throws -> (PreparedCustodyMetadata, InstallationCommandRetirement, OwnedDirectChild, CustodyMessage) in
            guard let entry = other.registry.entries[other.key], let ticket = entry.metadata,
                  let record = entry.installationRecord, let owner = entry.owner,
                  let terminal = entry.terminal, case .reaped(0) = owner.poll() else { throw CustodyRecordError.fenced }
            return (ticket, record, owner, terminal)
        }
        try queue.sync {
            guard let entry = entries[handle.key], let cleanup = entry.expiredCleanup,
                  cleanup.state == .awaitingOriginalProof, let ticket = entry.metadata,
                  let record = entry.installationRecord, let owner = entry.owner,
                  let terminal = entry.terminal, case .reaped(0) = owner.poll() else { throw CustodyRecordError.fenced }
            entry.deferredRead = nil
            var budget = 1_048_576
            consume(entry, budget: &budget)
            guard entry.statusEnded, entry.stdoutEnded, entry.stderrEnded, entry.traceEnded,
                  cleanup.state == .awaitingOriginalProof else { throw CustodyRecordError.fenced }
            defer { entry.metadata = ticket; entry.installationRecord = record; entry.owner = owner; entry.terminal = terminal }
            switch kind {
            case .ticket: entry.metadata = foreign.0
            case .record: entry.installationRecord = foreign.1
            case .helper: entry.owner = foreign.2
            case .message: entry.terminal = foreign.3
            }
            advanceExpiredCleanup(entry)
            guard cleanup.state == .uncertain, entries[handle.key] === entry,
                  !record.cleanupOnlyRemoved else { throw CustodyRecordError.fenced }
        }
    }
    enum TestExpiredCleanupPoint: Equatable { case beforeRead, afterRead, checkedClose, removed }
    private var nextExpiredCleanupObservation: ((TestExpiredCleanupPoint) -> Void)?
    func testingObserveExpiredCleanup(_ observer: @escaping (TestExpiredCleanupPoint) -> Void) {
        queue.sync { nextExpiredCleanupObservation = observer }
    }
    func testingCleanupOnlyRemoved(_ handle: Handle) -> Bool {
        reservationMutex.lock(); defer { reservationMutex.unlock() }
        guard let record = installationCommands[handle.key] else { return false }
        return record.cleanupOnlyRemoved && record.retired && record.resourcesClosedSuccessfully
            && record.exactRemoval && !record.issuanceQualified && record.sealIdentity == nil && record.delivery == .failed
    }
    private var deferNextOriginalRefusal = false
    private var nextOriginalRefusalObservation: ((OwnedSpawnAnchor?, OwnedDirectChild?) -> Void)?
    func testingHoldNextOriginalRefusal(observer: ((OwnedSpawnAnchor?, OwnedDirectChild?) -> Void)? = nil) {
        queue.sync { deferNextOriginalRefusal = true; nextOriginalRefusalObservation = observer }
    }
    func testingObserveOriginalRefusal(_ observer: @escaping (OwnedSpawnAnchor?, OwnedDirectChild?) -> Void) {
        queue.sync { nextOriginalRefusalObservation = observer }
    }
    struct TestRefusalBounds {
        let work: UInt64, originalReceipt: UInt64, effectiveReceipt: UInt64, operation: UInt64
    }
    func testingRefusalBounds(_ handle: Handle) -> TestRefusalBounds? {
        queue.sync {
            guard let entry = entries[handle.key], entry.originalRefusal != nil,
                  let ticket = entry.metadata,
                  let operation = try? entry.resources.scope.validateOriginalStagedTicket(ticket, request: entry.resources.request) else { return nil }
            return TestRefusalBounds(work: entry.resources.request.budget.work,
                originalReceipt: entry.resources.request.budget.receipt,
                effectiveReceipt: entry.state.budget.receipt, operation: operation.absoluteUptimeNanoseconds)
        }
    }
    func testingReleaseOriginalRefusal(_ handle: Handle) {
        queue.sync {
            guard let entry = entries[handle.key], entry.originalRefusal != nil else { return }
            entry.deferredOriginalRefusal = false
            do { try signalOriginalRefusal(entry) } catch { pending(entry, reason: .ownershipLost) }
            advanceOriginalRefusal(entry)
        }
    }
    enum TestFinalizationPoint { case beforeArchive, afterArchive }
    private var nextFinalizationObservation: ((TestFinalizationPoint) throws -> Void)?
    private var nextProspectiveRecovery: ((StagedRecoveryRetirement, CustodyRequestResources) throws -> Void)?
    func testingObserveFinalization(_ observer: @escaping (TestFinalizationPoint) throws -> Void) {
        queue.sync { nextFinalizationObservation = observer }
    }
    func testingObserveProspectiveRecovery(_ observer: @escaping (StagedRecoveryRetirement, CustodyRequestResources) throws -> Void) {
        queue.sync { nextProspectiveRecovery = observer }
    }
    func testingRevisitFinalization(_ handle: Handle) {
        queue.sync { if entries[handle.key] != nil { tick(); tick() } }
    }
    enum TestReadDeferral { case statusAfterAdmission, outputUntilReleased }
    private var nextReadDeferral: TestReadDeferral?
    private var nextRepositoryReadDeferral: TestReadDeferral?
    private var nextRetirementBarrier: CustodyLeaseTestingBarrier?
    final class ReadinessSchedulingProbe: @unchecked Sendable {
        let barrier = CustodyLeaseTestingBarrier()
        private let lock = NSLock()
        private var captured: UInt64?
        fileprivate func captureAndPause(_ deadline: MonotonicDeadline) {
            lock.lock(); captured = deadline.absoluteUptimeNanoseconds; lock.unlock()
            _ = barrier.pause()
        }
        var absoluteDeadline: UInt64? { lock.lock(); defer { lock.unlock() }; return captured }
    }
    private var nextReadinessSchedulingProbe: ReadinessSchedulingProbe?
    func testingPauseReadinessScheduling(_ probe: ReadinessSchedulingProbe) { queue.sync { nextReadinessSchedulingProbe = probe } }
    func testingPauseNextRetirement(_ barrier: CustodyLeaseTestingBarrier) { queue.sync { nextRetirementBarrier = barrier } }
    func testingDeferNextRepositoryRead() { queue.sync { nextRepositoryReadDeferral = .outputUntilReleased } }
    func testingResources(_ handle: Handle) -> CustodyRequestResources? {
        queue.sync { entries[handle.key]?.resources }
    }
    func testingRepositoryHandle(_ requestID: String) -> Handle? {
        queue.sync { entries[requestID].map { Handle($0, self) } }
    }
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
        let removed = queue.sync {
            guard let entry = entries[handle.key] else { return false }
            entry.deferredRead = nil
            tick()
            return entries[handle.key] == nil
        }
        // Test-only join of the separate retirement publication turn.
        queue.sync {}
        return removed && handle.snapshot().phase == .finished
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
    // Failure-only fixture observation; never consumes or arms an injection.
    func testingFaultIsPending(_ cut: TestCut) -> Bool { queue.sync { nextTestCut == cut } }
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
    private var testingPreparedStartCalls = 0
    var testingPreparedStartCount: Int {
        reservationMutex.lock(); defer { reservationMutex.unlock() }; return testingPreparedStartCalls
    }
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
    #if SHADOW_SYNC_SIGNED_FIXTURE
    struct SignedJoinSnapshot: Equatable {
        let request: UnvalidatedCustodyRequest
        let entry: ObjectIdentifier?, resource: ObjectIdentifier?, ticket: ObjectIdentifier?, helper: ObjectIdentifier?
        let record: ObjectIdentifier
        let originalReceipt: UInt64, effectiveReceipt: UInt64?, operation: UInt64?
        let expiryAwaiting: Bool, expiryUncertain: Bool, archiveNeverAttempted: Bool
        let terminal: Bool, statusEOF: Bool, stdoutEOF: Bool, stderrEOF: Bool, traceEOF: Bool
        let helperZero: Bool, physicallyRetired: Bool, ledgerClosed: Bool, removed: Bool, issuance: Bool, sealed: Bool
        let scope: CustodyMetadataScope.SignedJoinScopeObservation?
    }
    func testingSignedJoinSnapshot(_ handle: Handle) throws -> SignedJoinSnapshot {
        try queue.sync {
            guard handle.registry === self else { throw CustodyRecordError.fenced }
            reservationMutex.lock(); let record = installationCommands[handle.key]; reservationMutex.unlock()
            guard let record else { throw CustodyRecordError.fenced }
            let entry = entries[handle.key]
            if let entry { guard entry.cell === handle.cell, entry.installationRecord === record else { throw CustodyRecordError.fenced } }
            let zero: Bool
            if let owner = entry?.owner, case .reaped(0) = owner.observation { zero = true } else { zero = false }
            reservationMutex.lock()
            let closed = record.resourcesClosedSuccessfully, removed = record.exactRemoval,
                issuance = record.issuanceQualified, sealed = record.sealIdentity != nil
            reservationMutex.unlock()
            return SignedJoinSnapshot(request: record.request,
                entry: entry.map(ObjectIdentifier.init), resource: entry.map { ObjectIdentifier($0.resources) },
                ticket: entry?.metadata.map(ObjectIdentifier.init), helper: entry?.owner.map(ObjectIdentifier.init),
                record: ObjectIdentifier(record), originalReceipt: record.request.budget.receipt,
                effectiveReceipt: entry?.state.budget.receipt, operation: entry?.issuanceOperationDeadline,
                expiryAwaiting: entry?.expiredCleanup?.state == .awaitingOriginalProof,
                expiryUncertain: entry?.expiredCleanup?.state == .uncertain,
                archiveNeverAttempted: entry.map { $0.archiveStarted == nil && $0.archiveCompleted == nil } ?? record.cleanupOnlyRemoved,
                terminal: entry?.terminal != nil, statusEOF: entry?.statusEnded ?? false,
                stdoutEOF: entry?.stdoutEnded ?? false, stderrEOF: entry?.stderrEnded ?? false, traceEOF: entry?.traceEnded ?? false,
                helperZero: zero, physicallyRetired: entry?.resources.installationRetiredSuccessfully ?? closed,
                ledgerClosed: closed, removed: removed, issuance: issuance, sealed: sealed,
                scope: record.scope?.testingSignedJoinScope(record.request))
        }
    }
    struct SignedJoinQuiescence {
        let entries: Int, order: Int, reservations: Int, outputEntries: Int, output: UInt64
        let preceding: Int, precedingRetired: Bool, selectedDelivered: Bool, publicationInactive: Bool
        var empty: Bool { entries == 0 && order == 0 && reservations == 0 && outputEntries == 0 && output == 0 }
    }
    func testingSignedJoinQuiescence(_ selected: Handle? = nil) throws -> SignedJoinQuiescence {
        try queue.sync {
            if let selected { guard selected.registry === self else { throw CustodyRecordError.fenced } }
            reservationMutex.lock(); defer { reservationMutex.unlock() }
            guard reservedIDs == Set(reservationOutputs.keys),
                  reservationOutputs.values.reduce(0, +) == outputReserved else { throw CustodyRecordError.fenced }
            let previous = installationCommands.filter { $0.key != selected?.key }.map { $0.value }
            let retired = previous.allSatisfy {
                $0.retired && $0.resourcesClosedSuccessfully && $0.exactRemoval && $0.issuanceQualified
                    && $0.delivery == .delivered && $0.resources == nil && $0.prepared == nil && $0.scope == nil
            }
            let record = selected.flatMap { installationCommands[$0.key] }
            if selected != nil && record == nil { throw CustodyRecordError.fenced }
            let inactive = record.map { $0.delivery != .notAttempted || !$0.issuanceQualified } ?? true
            let value = SignedJoinQuiescence(entries: entries.count, order: order.count,
                reservations: reservedIDs.count, outputEntries: reservationOutputs.count, output: outputReserved,
                preceding: previous.count, precedingRetired: retired,
                selectedDelivered: record?.delivery == .delivered, publicationInactive: inactive)
            guard !entries.isEmpty || value.empty else { throw CustodyRecordError.fenced }
            return value
        }
    }
    /// Separate signed fixture disposal, never checkedClose/removed production
    /// evidence. Only the original, now-drained owner may end its test bookkeeping.
    func testingDisposeSignedJoin(_ handle: Handle, controller: SignedInstallationFixtureJoinController,
                                  context: SignedInstallationFixtureContext,
                                  custody: InstallationReadinessFixtureCustody,
                                  invocation: InstallationFixtureWork, deadline: MonotonicDeadline) throws {
        try controller.requireOwner(context: context, custody: custody)
        try invocation.join(deadline: deadline)
        try controller.requireTeardownJoin()
        // Drains queued cancellation/publication callbacks before the serialized
        // preflight. The negative route never queued a success publication.
        queue.sync {}
        try queue.sync {
            guard handle.registry === self, let entry = entries[handle.key], entry.cell === handle.cell,
                  entries.count == 1, entry.expiredCleanup?.state == .uncertain,
                  entry.stagedFinalization == .failed, entry.archiveStarted == nil, entry.archiveCompleted == nil,
                  entry.resources.testingSignedJoinMatches(controller),
                  entry.resources.scope.validationProfile == context.profile,
                  let owner = entry.owner, case .reaped(0) = owner.poll(),
                  entry.terminal != nil, entry.statusEnded, entry.stdoutEnded, entry.stderrEnded, entry.traceEnded,
                  !entry.statusPoisoned, !entry.outputPoisoned,
                  entry.resources.installationRetiredSuccessfully,
                  entry.mapping?.childCopiesRetiredSuccessfully == true,
                  let record = entry.installationRecord else { throw CustodyRecordError.busy }
            reservationMutex.lock()
            let exact = installationCommands[handle.key] === record && !record.retired
                && !record.resourcesClosedSuccessfully && !record.exactRemoval && !record.issuanceQualified
                && record.sealIdentity == nil && !record.cleanupOnlyRemoved
                && reservedIDs == Set([handle.key])
            reservationMutex.unlock()
            guard exact else { throw CustodyRecordError.fenced }
            // No retirement retry, metadata read/write, ledger update, token, or
            // production cleanup observer. Exact reservation debit only.
            guard remove(entry) else { throw CustodyRecordError.fenced }
            timer?.cancel(); timer = nil; timerMilliseconds = nil
        }
    }
    #endif
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
