import Darwin
import Foundation

#if SHADOW_SYNC_TESTING
/// Synchronous, thread-scoped observations at the actual live capture cuts.
/// The observer cannot supply an identity, lease, result or production bypass.
enum InstallationStateCaptureTesting {
    enum Point { case initial, final }
    private final class Observation {
        let body: (Point, InstallationNodeIdentity) throws -> Void
        init(_ body: @escaping (Point, InstallationNodeIdentity) throws -> Void) { self.body = body }
    }
    private static let key = "shadow-sync-installation-state-capture"
    static func withObservation<T>(_ observer: @escaping (Point, InstallationNodeIdentity) throws -> Void,
                                   _ body: () throws -> T) throws -> T {
        let prior = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = Observation(observer)
        defer {
            if let prior { Thread.current.threadDictionary[key] = prior }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        return try body()
    }
    static func hit(_ point: Point, _ identity: InstallationNodeIdentity) throws {
        try (Thread.current.threadDictionary[key] as? Observation)?.body(point, identity)
    }
}
#endif

#if SHADOW_SYNC_TESTING
/// Independent of the state-root observer: these cuts observe the actual named
/// custody description and cannot supply replacement identities or results.
enum InstallationCustodyCaptureTesting {
    enum Point { case opened, current, named }
    private final class Observation {
        let body: (Point, InstallationNodeIdentity, UInt64?) throws -> Void
        init(_ body: @escaping (Point, InstallationNodeIdentity, UInt64?) throws -> Void) { self.body = body }
    }
    private static let key = "shadow-sync-installation-custody-capture"
    static func withObservation<T>(_ observer: @escaping (Point, InstallationNodeIdentity, UInt64?) throws -> Void,
                                   _ body: () throws -> T) throws -> T {
        let prior = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = Observation(observer)
        defer {
            if let prior { Thread.current.threadDictionary[key] = prior }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        return try body()
    }
    static func hit(_ point: Point, _ identity: InstallationNodeIdentity, namedLinks: UInt64? = nil) throws {
        try (Thread.current.threadDictionary[key] as? Observation)?.body(point, identity, namedLinks)
    }
}
/// Pauses only a fixture's actual catalog writer, after its temporary has been
/// written and synced. No production callback or lock behavior is introduced.
enum CustodyCatalogWriteTesting {
    private final class Observation {
        let body: (Int32) throws -> Void
        init(_ body: @escaping (Int32) throws -> Void) { self.body = body }
    }
    private static let key = "shadow-sync-custody-write-capture"
    static func withObservation<T>(_ observer: @escaping (Int32) throws -> Void, _ body: () throws -> T) throws -> T {
        let prior = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = Observation(observer)
        defer {
            if let prior { Thread.current.threadDictionary[key] = prior }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        return try body()
    }
    static func hit(_ parent: Int32) throws { try (Thread.current.threadDictionary[key] as? Observation)?.body(parent) }
}
#endif

// Descriptor observations only. No path, PID, decoded record or opened file
// grants a lease. Callers must retain their original typed authority separately.
extension InstallationStateBinding {
    private enum ObservedKind { case liveCustodyDirectory, regular }
    private struct ObservedNode {
        let kind: ObservedKind
        let descriptor: OwnedFileDescriptor
        let identity: InstallationNodeIdentity
        let parent: Int32?
        let name: String?
    }
    private static func identity(_ fd: Int32, uid: uid_t, directory: Bool) throws -> InstallationNodeIdentity {
        var value = stat()
#if SHADOW_SYNC_TESTING
        guard InstallationInvocationTesting.check(fstat(fd, &value) == 0, .statCall, syscall: true),
              InstallationInvocationTesting.check(value.st_uid == uid, .owner),
              InstallationInvocationTesting.check(value.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600), .mode),
              InstallationInvocationTesting.check(directory ? value.st_nlink > 0 : value.st_nlink == 1, .links) else {
            throw CustodyRecordError.unsafeMetadata
        }
#else
        guard fstat(fd, &value) == 0, value.st_uid == uid,
              value.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600),
              directory ? value.st_nlink > 0 : value.st_nlink == 1 else {
            throw CustodyRecordError.unsafeMetadata
        }
#endif
        let result = InstallationNodeIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            type: directory ? .directory : .regular, uid: value.st_uid, mode: UInt32(value.st_mode),
            links: UInt64(value.st_nlink),
            aclDigest: CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(fd).utf8)))
        try result.validate(); return result
    }
    private static func open(_ parent: Int32, _ name: String, uid: uid_t, kind: ObservedKind = .regular) throws -> ObservedNode {
        let directory = kind == .liveCustodyDirectory
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen)
        #endif
        let raw = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
#if SHADOW_SYNC_TESTING
        guard InstallationInvocationTesting.check(raw >= 0, .openCall, syscall: true) else { throw CustodyRecordError.unsafeMetadata }
#else
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
#endif
        let owner = OwnedFileDescriptor(raw)
        return try ObservedNode(kind: kind, descriptor: owner, identity: identity(raw, uid: uid, directory: directory), parent: parent, name: name)
    }
    static func capture(stateDescriptor: Int32, uid: uid_t) throws -> Self {
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureIdentity, node: .state)
        #endif
        let state = try identity(stateDescriptor, uid: uid, directory: true)
        #if SHADOW_SYNC_TESTING
        try InstallationStateCaptureTesting.hit(.initial, state)
        #endif
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .custody)
        #endif
        let custody = try open(stateDescriptor, "custody", uid: uid, kind: .liveCustodyDirectory)
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .namespace)
        #endif
        let namespace = try open(stateDescriptor, "latest.log", uid: uid)
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .lifecycle)
        #endif
        let lifecycle = try open(stateDescriptor, "lifecycle.lock", uid: uid)
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .operation)
        #endif
        let operation = try open(stateDescriptor, "operation.lock", uid: uid)
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .run)
        #endif
        let run = try open(stateDescriptor, "run.lock", uid: uid)
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .launcher)
        #endif
        let launcher = try open(stateDescriptor, "launcher.lock", uid: uid)
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureOpen, node: .catalog)
        #endif
        let catalog = try open(custody.descriptor.value, "catalog.lock", uid: uid)
        #if SHADOW_SYNC_TESTING
        try InstallationCustodyCaptureTesting.hit(.opened, custody.identity)
        #endif
        // Keep every opened description alive until the entire named set has
        // been rechecked; an earlier close could hide inode substitution.
        #if SHADOW_SYNC_TESTING
        var diagnosticNodeIndex = 0
        let diagnosticNodes: [InstallationInvocationTesting.Node] = [.custody, .namespace, .lifecycle, .operation, .run, .launcher, .catalog]
        #endif
        for node in [custody, namespace, lifecycle, operation, run, launcher, catalog] {
            #if SHADOW_SYNC_TESTING
            InstallationInvocationTesting.locate(.captureNamed, node: diagnosticNodes[diagnosticNodeIndex])
            diagnosticNodeIndex += 1
            #endif
            let current = try identity(node.descriptor.value, uid: uid, directory: node.identity.type == .directory)
            #if SHADOW_SYNC_TESTING
            InstallationInvocationTesting.locate(.captureNamed)
            #endif
            // Only this typed mutable directory permits positive link-count
            // variation. All regular observations retain exact identity.
            let liveCustody = node.kind == .liveCustodyDirectory
            let sameCurrent = liveCustody ? sameLiveStateNode(current, node.identity) : current == node.identity
            #if SHADOW_SYNC_TESTING
            if liveCustody { try InstallationCustodyCaptureTesting.hit(.current, current) }
            #endif
            var named = stat()
#if SHADOW_SYNC_TESTING
            guard InstallationInvocationTesting.check(sameCurrent, .currentIdentity),
                  InstallationInvocationTesting.check(node.parent != nil, .parentPresent), let parent = node.parent,
                  InstallationInvocationTesting.check(node.name != nil, .namePresent), let name = node.name,
                  InstallationInvocationTesting.check(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, .namedStatCall, syscall: true),
                  InstallationInvocationTesting.check(UInt64(named.st_dev) == current.device, .namedDevice),
                  InstallationInvocationTesting.check(UInt64(named.st_ino) == current.inode, .namedInode),
                  InstallationInvocationTesting.check(named.st_uid == current.uid, .namedOwner),
                  InstallationInvocationTesting.check(UInt32(named.st_mode) == current.mode, .namedMode),
                  InstallationInvocationTesting.check(liveCustody ? named.st_nlink > 0 : UInt64(named.st_nlink) == current.links, .namedLinks) else { throw CustodyRecordError.unsafeMetadata }
#else
            guard sameCurrent, let parent = node.parent, let name = node.name,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  UInt64(named.st_dev) == current.device, UInt64(named.st_ino) == current.inode,
                  named.st_uid == current.uid, UInt32(named.st_mode) == current.mode,
                  (liveCustody ? named.st_nlink > 0 : UInt64(named.st_nlink) == current.links) else { throw CustodyRecordError.unsafeMetadata }
#endif
            #if SHADOW_SYNC_TESTING
            if liveCustody { try InstallationCustodyCaptureTesting.hit(.named, current, namedLinks: UInt64(named.st_nlink)) }
            #endif
        }
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.captureFinal, node: .state)
        #endif
        let finalState = try identity(stateDescriptor, uid: uid, directory: true)
        #if SHADOW_SYNC_TESTING
        try InstallationStateCaptureTesting.hit(.final, finalState)
        #endif
#if SHADOW_SYNC_TESTING
        guard InstallationInvocationTesting.check(sameLiveStateNode(finalState, state), .stateStable) else { throw CustodyRecordError.unsafeMetadata }
#else
        guard sameLiveStateNode(finalState, state) else { throw CustodyRecordError.unsafeMetadata }
#endif
        let result = Self(directory: state, namespace: namespace.identity, lifecycle: lifecycle.identity,
            operation: operation.identity, run: run.identity, launcher: launcher.identity, catalogGuard: catalog.identity)
        try result.validate(); return result
    }
    // Only fresh observations of the mutable state root and typed custody
    // directory use this comparison. Durable records and regular locks stay exact.
    private static func sameLiveStateNode(_ a: InstallationNodeIdentity, _ b: InstallationNodeIdentity) -> Bool {
        a.type == .directory && b.type == .directory && a.device == b.device && a.inode == b.inode
            && a.uid == b.uid && a.mode == b.mode && a.aclDigest == b.aclDigest
            && a.links > 0 && b.links > 0
    }
    func validateLive(stateDescriptor: Int32, uid: uid_t, leases: CustodyAuthorityLeaseSet) throws {
        try validate()
        let current = try Self.capture(stateDescriptor: stateDescriptor, uid: uid)
        // Directory link counts may change when valid state children appear or disappear.
        // Both observations must be live/private; only this count is not stable.
        guard Self.sameLiveStateNode(directory, current.directory),
              namespace == current.namespace, lifecycle == current.lifecycle, operation == current.operation,
              run == current.run, launcher == current.launcher, catalogGuard == current.catalogGuard else {
            throw CustodyRecordError.fenced
        }
        let expected: [CustodyDescriptorClaim.Role: InstallationNodeIdentity] = [
            .state: directory, .namespace: namespace, .lifecycle: lifecycle, .operation: operation, .run: run]
        for held in try leases.descriptorClaims() {
            guard let node = expected[held.role], held.device == node.device, held.inode == node.inode,
                  held.uid == node.uid, held.mode == node.mode,
                  held.role == .state ? held.links > 0 : held.links == node.links else {
                throw CustodyRecordError.fenced
            }
        }
    }
}

/// Live, reference-bound metadata scope. Its random UUID cannot be supplied from
/// disk. It owns actual leases but grants no executable/publisher/candidate trust.
/// The command context will add those checks before any helper spawn.
final class CustodyMetadataScope: @unchecked Sendable {
    enum State { case open, closing, pending, terminal }
    let id = UUID().uuidString.lowercased()
    let bootID: String
    let generation: String
    let releaseSHA256: String
    let uid: uid_t
    let leases: CustodyAuthorityLeaseSet
    private let mutex = NSLock()
    private var state: State = .open
    private let stagedFailure = CommandCustodyPhaseFailure()
    private var pendingRevision: UInt64 = 0
    private func recordPendingLocked() {
        state = .pending; stagedFailure.recordPending()
        if pendingRevision < UInt64.max { pendingRevision += 1 }
    }
    private var liveRequests: Set<String> = []
    private var stagedRetirements: [CustodyCatalogStore.StagedRetiredCommand] = []
    private let store: CustodyCatalogStore
    private let installation: CustodyCatalogStore.InstallationCommandPermit?
    var validationProfile: InstallationValidationProfile { installation?.observation.validationProfile ?? .production }

    init(leases: CustodyAuthorityLeaseSet, releaseSHA256: String, generation: String, installation: CustodyCatalogStore.InstallationCommandPermit? = nil) throws {
        guard CustodyWire.hex(releaseSHA256, bytes: 32), RunIdentity.isValid(generation) else { throw CustodyRecordError.invalidRecord }
        // Staged lease custody is not installation command authority. No generic
        // scope may open this mode before an exact durable continuation exists.
        guard !leases.mode.isInstallationStaged || installation?.observation.stagedMode == leases.mode else { throw CustodyRecordError.fenced }
        self.leases = leases; self.releaseSHA256 = releaseSHA256; self.generation = generation; self.installation = installation
        bootID = try CustodyBootIdentity.current(); uid = geteuid()
        store = try CustodyCatalogStore(leases: leases,
            validationProfile: installation?.observation.validationProfile ?? .production)
        // Validate all evidence now, then again in the same guarded transition
        // as every reservation. This initial read is never cached admission.
        try installation?.revalidate()
        try store.checkFence(ownRequests: [], scope: id, mode: leases.mode, installation: installation)
    }
    func registerInstallationRetirement(in registry: RetainedCleanupRegistry) throws -> InstallationTransactionOwner? {
        guard let owner = installation?.stagedObservation?.session.retirementOwner else { return nil }
        try owner.validateRetirementRegistry(registry)
        return owner
    }
    func revalidateInstallation() throws {
        guard let installation else { return }
        try installation.revalidate()
        mutex.lock(); let requests = liveRequests; let open = state == .open; mutex.unlock()
        guard open else { throw CustodyRecordError.fenced }
        try store.checkFence(ownRequests: requests, scope: id, mode: leases.mode, installation: installation)
    }
    var observation: State { mutex.lock(); defer { mutex.unlock() }; return state }
    func close() {
        mutex.lock(); defer { mutex.unlock() }
        if state == .open { state = liveRequests.isEmpty ? .terminal : .closing }
    }
    func markPending() { mutex.lock(); recordPendingLocked(); mutex.unlock() }
    // These checks use the original prepared ticket, never a decoded request as
    // authority. No owner callback or registry lock is held under this mutex.
    func validateOriginalStagedTicket(_ ticket: PreparedCustodyMetadata,
                                     request: UnvalidatedCustodyRequest) throws -> MonotonicDeadline {
        mutex.lock(); defer { mutex.unlock() }
        guard let staged = installation?.stagedObservation,
              ticket.scope === self, liveRequests.contains(ticket.requestID),
              ticket.journal.binding == (try CustodyRecordBinding(request.binding)),
              ticket.journal.kind == request.kind, ticket.journal.authority == request.authority,
              ticket.journal.budget == request.budget, ticket.journal.inputSHA256 == request.inputSHA256,
              ticket.journal.resourcesSHA256 == request.resourcesSHA256,
              request.inputSHA256 == CustodyRecordBinding.digest(try staged.binding.encode()),
              request.authority == .installationStagedStart,
              [.launchctlMutation, .launchctlRead, .signatureCheck].contains(request.kind),
              stagedRetirements.count < 128,
              !stagedFailure.cleanupPending, state == .open || state == .closing else {
            throw CustodyRecordError.fenced
        }
        try staged.binding.validateCommittedRequest(request)
        return staged.operationDeadline
    }
    func closeForOriginalRefusal(ticket: PreparedCustodyMetadata, request: UnvalidatedCustodyRequest) throws {
        _ = try validateOriginalStagedTicket(ticket, request: request)
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.scope === self, liveRequests.contains(ticket.requestID),
              ticket.journal.phase == .prepared, !stagedFailure.cleanupPending,
              state == .open || state == .closing else { throw CustodyRecordError.fenced }
        state = .closing
    }
    var stagedCleanupPending: Bool { stagedFailure.cleanupPending }
    final class ExpiredOriginalCleanup {
        fileprivate weak var scope: CustodyMetadataScope?
        fileprivate let ticket: ObjectIdentifier
        fileprivate let request: UnvalidatedCustodyRequest
        fileprivate let revision: UInt64
        fileprivate init(scope: CustodyMetadataScope, ticket: PreparedCustodyMetadata,
                         request: UnvalidatedCustodyRequest, revision: UInt64) {
            self.scope = scope; self.ticket = ObjectIdentifier(ticket); self.request = request; self.revision = revision
        }
    }
    func markUnissuedOriginalExpiry(ticket: PreparedCustodyMetadata, request: UnvalidatedCustodyRequest,
                                   effectiveReceipt: UInt64) throws -> ExpiredOriginalCleanup {
        let operation = try validateOriginalStagedTicket(ticket, request: request)
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.scope === self, ticket.journal.phase == .prepared,
              liveRequests.contains(ticket.requestID), !stagedFailure.cleanupPending,
              state == .open || state == .closing, pendingRevision < UInt64.max - 1,
              effectiveReceipt <= request.budget.receipt,
              DispatchTime.now().uptimeNanoseconds >= min(effectiveReceipt, operation.absoluteUptimeNanoseconds) else {
            throw CustodyRecordError.fenced
        }
        recordPendingLocked()
        return ExpiredOriginalCleanup(scope: self, ticket: ticket, request: request, revision: pendingRevision)
    }
    func validateOriginalExpiry(_ expiry: ExpiredOriginalCleanup, ticket: PreparedCustodyMetadata,
                                request: UnvalidatedCustodyRequest) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard expiry.scope === self, expiry.ticket == ObjectIdentifier(ticket), ticket.scope === self,
              expiry.request == request, liveRequests.contains(ticket.requestID),
              ticket.journal.phase == .prepared, state == .pending, stagedFailure.cleanupPending,
              pendingRevision == expiry.revision else { throw CustodyRecordError.fenced }
    }
    // Original retained custody permits this one nonblocking metadata read. It
    // cannot archive, remove durable reservations, change pins or mint a token.
    func observeExpiredOriginalTerminalForCleanup(_ proof: CustodyRetirementProof,
        expiry: ExpiredOriginalCleanup) throws -> CustodyJournal {
        mutex.lock(); defer { mutex.unlock() }
        let ticket = proof.ticket, request = proof.resources.request
        guard expiry.scope === self, expiry.ticket == ObjectIdentifier(ticket),
              expiry.request == request, ticket.scope === self, proof.resources.scope === self,
              installation?.stagedObservation?.binding.stagedMode == .installationStagedStart,
              request.authority == .installationStagedStart,
              [.launchctlMutation, .launchctlRead, .signatureCheck].contains(request.kind),
              liveRequests.contains(ticket.requestID), ticket.journal.phase == .prepared,
              ticket.journal.binding == (try CustodyRecordBinding(request.binding)),
              state == .pending, stagedFailure.cleanupPending, pendingRevision == expiry.revision,
              case .terminal(let owner, let message) = proof.basis,
              case .reaped(0) = owner.observation else { throw CustodyRecordError.fenced }
        return try store.observeTerminal(prepared: ticket.journal, owner: owner, message: message)
    }


    func binding(requestID: String = UUID().uuidString.lowercased(), nonce: String) throws -> CustodyBinding {
        let result = CustodyBinding(requestID: requestID, scopeID: id, nonce: nonce,
            callerGeneration: generation, trustedUID: uid, bootID: bootID, releaseSHA256: releaseSHA256)
        try result.validate(); return result
    }
    func prepare(_ request: UnvalidatedCustodyRequest) throws -> PreparedCustodyMetadata {
        try installation?.revalidate()
        mutex.lock(); defer { mutex.unlock() }
        guard state == .open, request.binding.scopeID == id, request.binding.bootID == bootID,
              request.binding.releaseSHA256 == releaseSHA256, request.binding.callerGeneration == generation,
              request.binding.trustedUID == uid, request.authority == leases.mode else { throw CustodyRecordError.fenced }
        _ = try request.encode()
        try request.budget.validate(kind: request.kind, permittedWorkSeconds: request.kind.maximumWorkSeconds,
                                    now: DispatchTime.now().uptimeNanoseconds)
        let journal = try CustodyJournal(prepared: request, leases: leases.descriptorClaims())
        do {
            if let installation {
                guard !leases.mode.isInstallationStaged || liveRequests.isEmpty else { throw CustodyRecordError.fenced }
                try installation.validateRequest(request)
                guard request.inputSHA256 == CustodyRecordBinding.digest(try installation.observation.encode()) else { throw CustodyRecordError.fenced }
            }
            try store.reserveAndPrepare(journal, ownRequests: liveRequests, scope: id, installation: installation)
            liveRequests.insert(journal.binding.requestID)
            return PreparedCustodyMetadata(scope: self, journal: journal)
        } catch {
            // Even a failure after catalog fsync leaves a known outstanding
            // transaction. Do not reopen this scope or guess a clean retry.
            recordPendingLocked(); throw error
        }
    }
    /// Only the retaining registry can construct this proof. The catalog is
    /// checked under its stable guard again; an exited PID alone is insufficient.
    func completeFromRegistry(_ proof: CustodyRetirementProof, issuanceDeadline: UInt64? = nil) throws -> CustodyJournal {
        mutex.lock(); defer { mutex.unlock() }
        let ticket = proof.ticket
        guard ticket.scope === self, proof.resources.scope === self,
              liveRequests.contains(ticket.requestID),
              ticket.journal.binding == (try CustodyRecordBinding(proof.resources.request.binding)) else {
            throw CustodyRecordError.fenced
        }
        func checkIssuance() throws {
            if issuanceDeadline != nil && stagedFailure.cleanupPending { throw CustodyRecordError.fenced }
            if let issuanceDeadline, DispatchTime.now().uptimeNanoseconds >= issuanceDeadline { throw CustodyRecordError.busy }
        }
        do {
            try checkIssuance()
            let terminal: CustodyJournal
            let mayHaveExecuted: Bool
            switch proof.basis {
            case .noSuccessfulSpawn, .neverResumed:
                mayHaveExecuted = false
                guard ticket.journal.phase == .prepared, proof.reason != .none else { throw CustodyRecordError.fenced }
                let proposed = try ticket.journal.advancing(to: .terminal, outcome: .admissionRefused, reason: proof.reason)
                if ticket.journal.kind == .discoveryGit {
                    let planned = try store.readDiscoveryResource(journal: ticket.journal)
                    guard planned.phase == .planned else { throw CustodyRecordError.fenced }
                    try store.persistDiscoveryResource(journal: ticket.journal, expected: planned,
                                                       next: planned.advancing(to: .retired))
                }
                try checkIssuance()
                try store.replaceJournal(ticket.journal, with: proposed)
                try checkIssuance()
                ticket.journal = proposed; terminal = proposed
            case .terminal(let owner, let message):
                mayHaveExecuted = true
                guard case .reaped(0) = owner.observation else { throw CustodyRecordError.fenced }
                try checkIssuance()
                terminal = try store.observeTerminal(prepared: ticket.journal, owner: owner, message: message)
                try checkIssuance()
            }
            let observation = try proof.callerObservation(journal: terminal)
            try checkIssuance()
            _ = try store.archiveAndRetire(terminal, callerObservation: observation)
            try checkIssuance()
            if let installation, installation.observation.stagedMode != nil {
                stagedRetirements.append(try store.captureStagedRetirement(request: proof.resources.request,
                    journal: terminal, caller: observation, mayHaveExecuted: mayHaveExecuted))
            }
            try checkIssuance()
            ticket.journal = terminal; liveRequests.remove(ticket.requestID)
            if state != .open && liveRequests.isEmpty { state = .terminal }
            return terminal
        } catch { recordPendingLocked(); throw error }
    }
    func stagedRetirementEvidence(for request: UnvalidatedCustodyRequest) throws -> CustodyCatalogStore.StagedRetirementEvidence? {
        mutex.lock(); defer { mutex.unlock() }
        guard let installation, let staged = installation.stagedObservation else { return nil }
        guard state == .open, liveRequests.isEmpty, stagedRetirements.last?.request == request,
              [.launchctlMutation, .launchctlRead, .signatureCheck].contains(request.kind) else { return nil }
        // Evidence retains no scope. Completion later requires its destruction,
        // so any later command is detected by the exact final catalog/name pins.
        return CustodyCatalogStore.StagedRetirementEvidence(observation: staged, commands: stagedRetirements, failure: stagedFailure)
    }
    func closedStagedStartArchive(after proof: CustodyRetirementProof) throws -> CustodyCatalogStore.ClosedStagedStartArchive? {
        mutex.lock(); defer { mutex.unlock() }
        guard let staged = installation?.stagedObservation,
              staged.binding.stagedMode == .installationStagedStart else { return nil }
        guard proof.ticket.scope === self, proof.resources.scope === self,
              proof.resources.request.authority == .installationStagedStart,
              [.launchctlMutation, .launchctlRead, .signatureCheck].contains(proof.resources.request.kind),
              state == .terminal, liveRequests.isEmpty, !stagedFailure.cleanupPending,
              !stagedRetirements.isEmpty, stagedRetirements.count <= 128,
              let last = stagedRetirements.last, last.request == proof.resources.request,
              last.journal == proof.ticket.journal, last.journal.phase == .terminal,
              last.journal.binding == (try CustodyRecordBinding(proof.resources.request.binding)) else {
            throw CustodyRecordError.fenced
        }
        return CustodyCatalogStore.ClosedStagedStartArchive(evidence:
            .init(observation: staged, commands: stagedRetirements, failure: stagedFailure))
    }
    #if SHADOW_SYNC_TESTING
    #if SHADOW_SYNC_SIGNED_FIXTURE
    struct SignedJoinScopeObservation: Equatable {
        let failure: ObjectIdentifier
        let pending: Bool
        let liveRequest: Bool
        let retirements: Int
    }
    func testingSignedJoinScope(_ request: UnvalidatedCustodyRequest) -> SignedJoinScopeObservation {
        mutex.lock(); defer { mutex.unlock() }
        return .init(failure: ObjectIdentifier(stagedFailure), pending: stagedFailure.cleanupPending,
            liveRequest: liveRequests.contains(request.binding.requestID), retirements: stagedRetirements.count)
    }
    #endif
    func testingHoldMetadata(_ barrier: CustodyLeaseTestingBarrier) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return barrier.pause()
    }
    func testingFault(_ cut: CustodyCatalogStore.Fault?) { store.testingFault(cut) }
    func testingRead() throws -> CustodyCatalog { try store.testingRead() }
    func testingAdvance(_ ticket: PreparedCustodyMetadata, to next: CustodyJournal) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.scope === self, liveRequests.contains(ticket.journal.binding.requestID) else { throw CustodyRecordError.fenced }
        // Synthetic metadata tests have no resource creator. Retire only the
        // reservation's untouched planned record, never an acquired resource.
        if next.phase == .terminal, ticket.journal.kind == .discoveryGit {
            let planned = try store.readDiscoveryResource(journal: ticket.journal)
            if planned.phase == .planned {
                try store.persistDiscoveryResource(journal: ticket.journal, expected: planned,
                                                   next: planned.advancing(to: .retired))
            }
        }
        try store.replaceJournal(ticket.journal, with: next); ticket.journal = next
    }
    func testingRetire(_ ticket: PreparedCustodyMetadata) throws -> String {
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.scope === self, liveRequests.contains(ticket.journal.binding.requestID) else { throw CustodyRecordError.fenced }
        let digest = try store.archiveAndRetire(ticket.journal)
        liveRequests.remove(ticket.journal.binding.requestID)
        if state == .closing && liveRequests.isEmpty { state = .terminal }
        return digest
    }
    #endif
}

/// Only returned after catalog reservation and prepared-journal durability.
/// This is not a spawn permit; the registry and verified command context are
/// still required. Writer transfer and terminal proof integration remain closed.
final class PreparedCustodyMetadata: @unchecked Sendable {
    fileprivate let scope: CustodyMetadataScope
    fileprivate var journal: CustodyJournal
    fileprivate init(scope: CustodyMetadataScope, journal: CustodyJournal) { self.scope = scope; self.journal = journal }
    var requestID: String { journal.binding.requestID }
    #if SHADOW_SYNC_TESTING
    var testingJournal: CustodyJournal { journal }
    #endif
}

enum CustodyBootIdentity {
    static func current() throws -> String {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1, count <= 128 else { throw CustodyRecordError.fenced }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
              count == 37, bytes[count - 1] == 0,
              let value = String(bytes: bytes.prefix(count - 1), encoding: .utf8),
              RunIdentity.isValid(value.lowercased()) else { throw CustodyRecordError.fenced }
        return value.lowercased()
    }
}

/// Explicit recovery capability, separate from ordinary command/startup scopes.
/// The production factory verifies the running installed publisher. Fixtures
/// exercise the same metadata and lock path without asserting signed execution.
final class CustodyRecoveryContext {
    let bootID: String
    private let location: StateLocation
    private let leases: CustodyAuthorityLeaseSet
    private let store: CustodyCatalogStore
    private let publisher: CustodyHelperExecutable?

    private init(location: StateLocation, publisher: CustodyHelperExecutable?) throws {
        self.location = location; self.publisher = publisher
        bootID = try CustodyBootIdentity.current()
        leases = try CustodyAuthorityLeaseSet.retainRecoveryLeases(at: location)
        store = try CustodyCatalogStore(leases: leases)
        try revalidate()
    }
    static func production() throws -> CustodyRecoveryContext {
        let publisher = try CustodyHelperExecutable.production()
        return try Self(location: StateLocation.production(), publisher: publisher)
    }
    fileprivate func owns(_ candidate: CustodyAuthorityLeaseSet) -> Bool { leases === candidate }
    private func revalidate() throws {
        guard try CustodyBootIdentity.current() == bootID else { throw CustodyRecordError.fenced }
        if let publisher { try publisher.revalidate() }
        else {
            #if !SHADOW_SYNC_TESTING
            throw CustodyRecordError.fenced
            #endif
        }
        let state = try SecureStateDirectory.openExisting(location)
        let claims = try leases.descriptorClaims()
        var info = stat()
        guard fstat(state.descriptor.value, &info) == 0, let original = claims.first(where: { $0.role == .state }),
              UInt64(info.st_dev) == original.device, UInt64(info.st_ino) == original.inode,
              info.st_uid == original.uid else { throw CustodyRecordError.fenced }
    }
    func recordInterruptedPriorBoot() throws -> [CustodyJournal] {
        try revalidate()
        return try store.recoverPriorBoot(self)
    }
    #if SHADOW_SYNC_TESTING
    static func testing(at location: StateLocation, root: String) throws -> CustodyRecoveryContext {
        _ = try TestIsolation.validateRoot(root)
        guard location == (try StateLocation.isolated(root: root)) else { throw CustodyRecordError.fenced }
        return try Self(location: location, publisher: nil)
    }
    func testingFault(_ cut: CustodyCatalogStore.Fault) { store.testingFault(cut) }
    #endif
}

// Actual receipt descriptions retained by the live capture. Metadata-equivalent
// replacement files cannot replace durability proof, even with identical bytes.
final class InstallationDocumentRetention {
    fileprivate let descriptor: OwnedFileDescriptor
    fileprivate let identity: FileIdentity
    fileprivate let acl: String
    fileprivate init(_ descriptor: OwnedFileDescriptor, identity: FileIdentity, acl: String) {
        self.descriptor = descriptor; self.identity = identity; self.acl = acl
    }
}

/// Descriptor-relative, app-owned metadata only. Its stable guard is acquired
/// last, held only for bounded metadata transitions, and never grants operation
/// authority. No public callbacks run while it is held.
final class CustodyCatalogStore: @unchecked Sendable {
    fileprivate struct Node {
        let descriptor: OwnedFileDescriptor
        let identity: FileIdentity
        let acl: String
    }
    fileprivate struct File {
        let identity: FileIdentity
        let acl: String
        let bytes: Data
    }
    private let validationProfile: InstallationValidationProfile
    private let leasedAuthority: CustodyAuthorityLeaseSet?
    private let stoppedBinding: InstallationStateBinding?
    private var leases: CustodyAuthorityLeaseSet {
        get throws { guard let leasedAuthority else { throw CustodyRecordError.fenced }; return leasedAuthority }
    }
    private let root: OwnedFileDescriptor
    private let uid: uid_t
    private let directory: Node
    private let guardFile: Node
    private let receipts: Node
    private let mutex = NSLock()
    private var poisoned = false
    private var installationCommandPins: [String: Node] = [:]

    init(leases: CustodyAuthorityLeaseSet, validationProfile: InstallationValidationProfile = .production) throws {
        self.validationProfile = validationProfile
        self.leasedAuthority = leases; stoppedBinding = nil
        let state = try leases.duplicateStateDirectory(); root = state.0; uid = state.1
        try validationProfile.validateStateDescriptor(root.value)
        directory = try Self.openNode(root.value, "custody", uid: uid, directory: true)
        guardFile = try Self.openNode(directory.descriptor.value, "catalog.lock", uid: uid, directory: false)
        receipts = try Self.openNode(directory.descriptor.value, "receipts", uid: uid, directory: true)
    }
    // This view never escapes the stopped repair turn. Its descriptors remain
    // owned by the original journal; closing the view cannot close their owners.
    private init(stoppedRoot: OwnedFileDescriptor, binding: InstallationStateBinding,
                 directory: Node, guardFile: Node, receipts: Node,
                 validationProfile: InstallationValidationProfile) {
        self.validationProfile = validationProfile
        leasedAuthority = nil; stoppedBinding = binding
        root = stoppedRoot; uid = binding.directory.uid
        self.directory = directory; self.guardFile = guardFile; self.receipts = receipts
    }
    private static func node(_ fd: OwnedFileDescriptor, uid: uid_t, directory: Bool) throws -> Node {
        var info = stat()
        guard fstat(fd.value, &info) == 0, info.st_uid == uid,
              info.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600),
              directory || info.st_nlink == 1 else { throw CustodyRecordError.unsafeMetadata }
        return Node(descriptor: fd, identity: FileIdentity(info), acl: try PolicyAuthorityFile.privateStateACL(fd.value))
    }
    private static func openNode(_ parent: Int32, _ name: String, uid: uid_t, directory: Bool) throws -> Node {
        let fd = openat(parent, name, (directory ? O_RDONLY | O_DIRECTORY : O_RDWR | O_NONBLOCK) | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }
        return try node(OwnedFileDescriptor(fd), uid: uid, directory: directory)
    }
    private func validate(_ node: Node, at parent: Int32, name: String, isDirectory: Bool) throws {
        let current = try Self.node(node.descriptor, uid: uid, directory: isDirectory)
        var named = stat()
        guard current.identity.matchesStableNode(node.identity), current.acl == node.acl,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(named).matchesStableNode(node.identity), isDirectory || named.st_nlink == 1 else {
            throw CustodyRecordError.unsafeMetadata
        }
    }
    private func validateBindings() throws {
        try validationProfile.validateStateDescriptor(root.value)
        if let leasedAuthority { try leasedAuthority.validate() }
        else {
            guard let stoppedBinding else { throw CustodyRecordError.fenced }
            let actual = try Self.node(root, uid: uid, directory: true)
            guard UInt64(actual.identity.device) == stoppedBinding.directory.device,
                  UInt64(actual.identity.inode) == stoppedBinding.directory.inode,
                  actual.identity.owner == stoppedBinding.directory.uid,
                  UInt32(actual.identity.mode) == stoppedBinding.directory.mode,
                  CustodyRecordBinding.digest(Data(actual.acl.utf8)) == stoppedBinding.directory.aclDigest else {
                throw CustodyRecordError.fenced
            }
            // Full publisher/owner validation occurs outside this metadata guard.
            // These are named identity checks only, without open/flock/dup on op.
            for (name, expected) in [("latest.log", stoppedBinding.namespace), ("lifecycle.lock", stoppedBinding.lifecycle),
                ("operation.lock", stoppedBinding.operation), ("run.lock", stoppedBinding.run), ("launcher.lock", stoppedBinding.launcher)] {
                var named = stat()
                guard fstatat(root.value, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      UInt64(named.st_dev) == expected.device, UInt64(named.st_ino) == expected.inode,
                      named.st_uid == expected.uid, UInt32(named.st_mode) == expected.mode,
                      UInt64(named.st_nlink) == expected.links else { throw CustodyRecordError.fenced }
            }
        }
        try validate(directory, at: root.value, name: "custody", isDirectory: true)
        try validate(guardFile, at: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
        try validate(receipts, at: directory.descriptor.value, name: "receipts", isDirectory: true)
    }
    private struct AdmissionWait {
        let deadline: UInt64
        let revalidate: () throws -> Void
    }
    /// A false result proves that neither lock was acquired together and no
    /// catalog action ran. Other errors are not retryable acquisition results.
    private func tryAcquireCatalog() throws -> Bool {
        guard mutex.try() else {
            #if SHADOW_SYNC_TESTING
            DiscoveryFixtureDiagnostic.RepositoryBusyObservation.busy(.catalogMutex)
            #endif
            return false
        }
        var acquired = false
        defer { if !acquired { mutex.unlock() } }
        guard !poisoned else { throw CustodyRecordError.fenced }
        try validateBindings()
        guard flock(guardFile.descriptor.value, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK {
                #if SHADOW_SYNC_TESTING
                DiscoveryFixtureDiagnostic.RepositoryBusyObservation.busy(.catalogFileLock)
                #endif
                return false
            }
            throw CustodyRecordError.persistence(failure)
        }
        acquired = true
        return true
    }
    private func locked<T>(admission: AdmissionWait? = nil, _ action: () throws -> T) throws -> T {
        while true {
            if let admission {
                guard DispatchTime.now().uptimeNanoseconds < admission.deadline else { throw CustodyRecordError.busy }
                // No catalog mutex or file lock spans control/liveness checks.
                try admission.revalidate()
                guard DispatchTime.now().uptimeNanoseconds < admission.deadline else { throw CustodyRecordError.busy }
            }
            if try tryAcquireCatalog() { break }
            guard let admission else { throw CustodyRecordError.busy }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < admission.deadline else { throw CustodyRecordError.busy }
            // Retry acquisition only, yielding with neither catalog lock held.
            // The supplied absolute limit is never restarted or stretched.
            usleep(useconds_t(min(1_000, (admission.deadline - now) / 1_000)))
        }
        defer { mutex.unlock() }
        // This guard is a private, unduplicated metadata lock. No operation or
        // inherited authority descriptor is ever unlocked here.
        defer { _ = flock(guardFile.descriptor.value, LOCK_UN) }
        try validateBindings()
        if let admission {
            guard DispatchTime.now().uptimeNanoseconds < admission.deadline else { throw CustodyRecordError.busy }
        }
        // The action is outside the acquisition loop. Its errors, including a
        // possibly applied durable write, must propagate without replay.
        return try action()
    }
    private func read(_ name: String, at parent: Int32? = nil, maximum: Int) throws -> File {
        let fd = openat(parent ?? directory.descriptor.value, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let owner = OwnedFileDescriptor(fd), checked = try Self.node(owner, uid: uid, directory: false)
        var before = stat(); guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= maximum else { throw CustodyRecordError.unsafeMetadata }
        var bytes = Data(), block = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &block, min(block.count, maximum + 1 - bytes.count))
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw CustodyRecordError.persistence(errno) }
            if n == 0 { break }; bytes.append(contentsOf: block.prefix(n))
            guard bytes.count <= maximum else { throw CustodyRecordError.unsafeMetadata }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, FileIdentity(after) == checked.identity,
              after.st_size == before.st_size, bytes.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              try PolicyAuthorityFile.privateStateACL(fd) == checked.acl else { throw CustodyRecordError.unsafeMetadata }
        var named = stat()
        guard fstatat(parent ?? directory.descriptor.value, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(named) == checked.identity else { throw CustodyRecordError.unsafeMetadata }
        return File(identity: checked.identity, acl: checked.acl, bytes: bytes)
    }
    private func names() throws -> [String] {
        let fd = openat(directory.descriptor.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }
        guard let stream = fdopendir(fd) else { close(fd); throw CustodyRecordError.unsafeMetadata }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let row = readdir(stream) else {
                guard errno == 0 else { throw CustodyRecordError.persistence(errno) }; break
            }
            let name = withUnsafePointer(to: row.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= 260 else { throw CustodyRecordError.fenced }
        }
        return result.sorted()
    }
    private func installationSnapshot(pendingPreimages: [String: InstallationDocumentPreimage] = [:],
                                      pendingStep: InstallationStepReceipt.CanonicalObservation? = nil,
                                      pendingControl: InstallationControlRecord? = nil) throws -> (File, InstallationControlRecord) {
        let file = try read(InstallationControlRecord.filename, maximum: InstallationControlRecord.maximumBytes)
        let record = try InstallationControlRecord.decode(file.bytes, profile: validationProfile)
        if let leasedAuthority { try record.state.validateLive(stateDescriptor: root.value, uid: uid, leases: leasedAuthority) }
        else { guard record.state == stoppedBinding else { throw CustodyRecordError.fenced }; try validateBindings() }
        let fd = openat(receipts.descriptor.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }
        guard let stream = fdopendir(fd) else { close(fd); throw CustodyRecordError.unsafeMetadata }
        defer { closedir(stream) }
        var chain: [InstallationStepReceipt.CanonicalObservation] = []
        var documents: [String: InstallationDocumentPreimage] = [:]
        // A local metadata ceiling consumes caller time; it never renews a
        // command's absolute admission/work deadline. Historical command receipt
        // count is not a new retention/deletion policy.
        let scanLimit = MonotonicDeadline(seconds: 0.250)
        while true {
            guard !scanLimit.hasExpired else { throw CustodyRecordError.busy }
            errno = 0
            guard let row = readdir(stream) else {
                guard errno == 0 else { throw CustodyRecordError.persistence(errno) }; break
            }
            let name = withUnsafePointer(to: row.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if name.hasPrefix(InstallationDocumentPreimage.prefix) {
                guard documents.count < 1024 else { throw CustodyRecordError.fenced }
                let observation = try InstallationDocumentPreimage.CanonicalObservation(decoding: read(name, at: receipts.descriptor.value,
                    maximum: InstallationDocumentPreimage.maximumBytes).bytes, uid: uid)
                let document = observation.receipt, digest = observation.digest
                guard name == observation.filename, documents.updateValue(document, forKey: digest) == nil else {
                    throw CustodyRecordError.fenced
                }
            } else if name.hasPrefix(InstallationStepReceipt.prefix) {
                guard chain.count < 256 else { throw CustodyRecordError.fenced }
                let observation = try InstallationStepReceipt.CanonicalObservation(decoding: read(name, at: receipts.descriptor.value,
                    maximum: InstallationStepReceipt.maximumBytes).bytes, uid: uid)
                guard observation.filename == name,
                      observation.receipt.transactionID == record.transaction?.id
                        || (observation.filename == pendingStep?.filename && observation.receipt == pendingStep?.receipt) else {
                    throw CustodyRecordError.fenced
                }
                chain.append(observation)
            } else {
                // Preserve existing command archives. Unknown names, including
                // incomplete atomic-write temporaries, are evidence of uncertainty.
                let uuid: String
                if name.hasPrefix("discovery-resource-"), name.hasSuffix(".json") {
                    uuid = String(name.dropFirst("discovery-resource-".count).dropLast(5))
                } else if name.hasSuffix(".caller.json") { uuid = String(name.dropLast(12)) }
                else if name.hasSuffix(".recovery.json") { uuid = String(name.dropLast(14)) }
                else if name.hasSuffix(".json") { uuid = String(name.dropLast(5)) }
                else { throw CustodyRecordError.fenced }
                guard RunIdentity.isValid(uuid) else { throw CustodyRecordError.fenced }
                let node = try Self.openNode(receipts.descriptor.value, name, uid: uid, directory: false)
                try validate(node, at: receipts.descriptor.value, name: name, isDirectory: false)
            }
        }
        chain.sort { a, b in
            let a = a.receipt, b = b.receipt
            return a.ordinal == b.ordinal ? a.status == .intent && b.status == .complete : a.ordinal < b.ordinal
        }
        // Only a retained live session supplies this exact single successor.
        // Validate the old referenced prefix independently before the next edge.
        if let pendingStep, record.latestReceiptDigest != pendingStep.digest,
           let index = chain.firstIndex(where: { $0.digest == pendingStep.digest }) {
            guard index == chain.count - 1, chain[index].receipt == pendingStep.receipt,
                  let pendingControl else { throw CustodyRecordError.fenced }
            try record.validateReceiptChain(observations: Array(chain.dropLast()), profile: validationProfile)
            try record.validateReplacement(pendingControl, receipts: chain.map(\.receipt), profile: validationProfile)
        } else { try record.validateReceiptChain(observations: chain, profile: validationProfile) }
        // Every referenced document must resolve to complete recoverable bytes,
        // in the exact transaction/namespace/document slot. Unreferenced bytes
        // are permitted ONLY for the same live factory's pending capture.
        var referenced = Set<String>()
        var snapshots = chain.flatMap { [$0.receipt.preimage, $0.receipt.postimage].compactMap { $0 } }
        if let current = record.transaction?.slots { snapshots.append(current) }
        for snapshot in snapshots {
            for slot in [InstallationSlot.stateSource, .stateDestination] {
                guard let image = snapshot.images[slot], let node = image.node else { continue }
                guard let refs = image.documentReceipts else { throw CustodyRecordError.fenced }
                for document in InstallationDocument.allCases {
                    guard let digest = refs[document] ?? nil else { continue }
                    guard let receipt = documents[digest], receipt.transactionID == (record.transaction?.id ?? pendingControl?.transaction?.id),
                          receipt.slot == slot, receipt.document == document, receipt.namespace == node else {
                        throw CustodyRecordError.fenced
                    }
                    referenced.insert(digest)
                }
            }
        }
        for (digest, document) in documents where !referenced.contains(digest) {
            guard pendingPreimages[digest] == document else { throw CustodyRecordError.fenced }
        }
        return (file, record)
    }
    /// A privately minted live capture selects a closed set of document receipts;
    /// callers cannot supply a filename, bytes, fd or arbitrary replacement.
    /// Original owner validation and bundle/code work stay OUTSIDE catalog.lock.
    func validateInstallationPreimages(_ capture: InstallationCapturedSlots) throws {
        try capture.validateSource()
        let pending = Dictionary(uniqueKeysWithValues: capture.canonicalPreimages.map { ($0.digest, $0.receipt) })
        try locked {
            let record = try installationSnapshot(pendingPreimages: pending).1
            guard record.state == capture.stateBinding else { throw CustodyRecordError.fenced }
            try validateRetainedInstallationPreimages(capture)
            try validateBindings()
        }
        try capture.validateSource()
    }
    private func validateRetainedInstallationPreimages(_ capture: InstallationCapturedSlots) throws {
            guard Set(capture.retainedPreimages.keys) == Set(capture.canonicalPreimages.map(\.filename)) else {
                throw CustodyRecordError.fenced
            }
            for observation in capture.canonicalPreimages {
                guard let retained = capture.retainedPreimages[observation.filename] else { throw CustodyRecordError.fenced }
                let held = try Self.node(retained.descriptor, uid: uid, directory: false)
                let current = try read(observation.filename, at: receipts.descriptor.value, maximum: InstallationDocumentPreimage.maximumBytes)
                guard held.identity == retained.identity, held.acl == retained.acl,
                      current.identity == held.identity, current.acl == held.acl,
                      current.bytes == observation.bytes else { throw CustodyRecordError.fenced }
            }
    }
    func persistInstallationPreimages(_ capture: InstallationCapturedSlots) throws -> [String: InstallationDocumentRetention] {
        try capture.validateSource()
        var retained: [String: InstallationDocumentRetention] = [:]
        let pending = Dictionary(uniqueKeysWithValues: capture.canonicalPreimages.map { ($0.digest, $0.receipt) })
        try locked {
            do {
                guard try leases.mode == .lifecycleMutation else { throw CustodyRecordError.fenced }
                let record = try installationSnapshot(pendingPreimages: pending).1
                // Historical committed rollover requires its separate full-chain
                // retention design. Capture cannot silently start that migration.
                guard record.phase == .initial || record.transaction?.id == capture.transactionID,
                      record.state == capture.stateBinding, record.phase != .committed,
                      try snapshot().1.entries.isEmpty else { throw CustodyRecordError.fenced }
                for observation in capture.canonicalPreimages {
                    let name = observation.filename, bytes = observation.bytes
                    var info = stat()
                    if fstatat(receipts.descriptor.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                        let existing = try read(name, at: receipts.descriptor.value, maximum: InstallationDocumentPreimage.maximumBytes)
                        guard existing.bytes == bytes else { throw CustodyRecordError.conflict }
                        let raw = openat(receipts.descriptor.value, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
                        let retained = OwnedFileDescriptor(raw)
                        let node = try Self.node(retained, uid: uid, directory: false)
                        guard node.identity == existing.identity, node.acl == existing.acl,
                              fsync(raw) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
                        let after = try read(name, at: receipts.descriptor.value, maximum: InstallationDocumentPreimage.maximumBytes)
                        guard after.identity == existing.identity, after.acl == existing.acl, after.bytes == bytes else {
                            throw CustodyRecordError.conflict
                        }
                    } else {
                        guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }
                        try write(name, at: receipts.descriptor.value, bytes: bytes, expected: nil)
                    }
                }
                _ = try installationSnapshot(pendingPreimages: pending)
                for observation in capture.canonicalPreimages {
                    let raw = openat(receipts.descriptor.value, observation.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
                    let owned = OwnedFileDescriptor(raw), held = try Self.node(owned, uid: uid, directory: false)
                    let named = try read(observation.filename, at: receipts.descriptor.value, maximum: InstallationDocumentPreimage.maximumBytes)
                    guard named.identity == held.identity, named.acl == held.acl, named.bytes == observation.bytes,
                          fsync(raw) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.fenced }
                    try validate(held, at: receipts.descriptor.value, name: observation.filename, isDirectory: false)
                    retained[observation.filename] = InstallationDocumentRetention(owned, identity: held.identity, acl: held.acl)
                }
                try validateBindings()
            } catch { poisoned = true; throw error }
        }
        try capture.validateSource()
        return retained
    }
    /// Safe readiness wait only. Full private storage, current boot, exact
    /// kickstart edge and all pending command records remain required. The
    /// optional exact next receipt is observation of publication in progress,
    /// never permission to reconcile or write it from the host.
    static func precommitWaitObservation(admission: LifecycleAdmissionAuthority,
                                          validationProfile: InstallationValidationProfile = .production) throws -> InstallationControlRecord {
        try validationProfile.revalidate()
        let store = try Self(leases: admission.retainObservationLeases(), validationProfile: validationProfile)
        return try store.locked {
            let raw = try InstallationControlRecord.decode(store.read(InstallationControlRecord.filename,
                maximum: InstallationControlRecord.maximumBytes).bytes, profile: validationProfile)
            let pending = raw.step?.action == .kickstartCandidate && raw.step?.status == .intent
                ? try InstallationPrecommitWait.completion(of: raw) : nil
            let control = try store.installationSnapshot(pendingStep: pending?.1, pendingControl: pending?.0).1
            let catalog = try store.snapshot()
            guard control.phase == .active, control.readinessCommit == nil,
                  control.step?.action == .kickstartCandidate, let transaction = control.transaction,
                  transaction.boot == (try CustodyBootIdentity.current()), transaction.candidate != nil,
                  control.transaction?.slots.images[.installationSocket]?.node?.type == .socket else { throw CustodyRecordError.fenced }
            if control.step?.status == .complete {
                guard catalog.1.entries.isEmpty else { throw CustodyRecordError.fenced }
            } else {
                guard control.step?.status == .intent else { throw CustodyRecordError.fenced }
                var receiptNodes: [String: InstallationNodeIdentity] = [:]
                for name in try InstallationStagedAdmissionIntent.names(store.receipts.descriptor.value)
                    where (name.hasPrefix(InstallationStepReceipt.prefix) || name.hasPrefix(InstallationDocumentPreimage.prefix))
                        && name != pending?.1.filename {
                    let node = try Self.openNode(store.receipts.descriptor.value, name, uid: store.uid, directory: false)
                    receiptNodes[name] = try store.installationCommandNode(node.identity, acl: node.acl)
                }
                let controlNode = try Self.openNode(store.directory.descriptor.value, InstallationControlRecord.filename,
                    uid: store.uid, directory: false)
                let binding = try InstallationCommandBinding(control: control,
                    controlNode: store.installationCommandNode(controlNode.identity, acl: controlNode.acl), receiptNodes: receiptNodes,
                    validationProfile: store.validationProfile)
                let inputDigest = CustodyRecordBinding.digest(try binding.encode())
                for entry in catalog.1.entries {
                    guard entry.authority == .installationStagedStart,
                          entry.kind == .launchctlMutation || entry.kind == .launchctlRead || entry.kind == .signatureCheck,
                          entry.bootID == transaction.boot, entry.releaseSHA256 == transaction.sourceReleaseDigest,
                          let journal = catalog.2[entry.requestID], journal.binding.uid == control.state.directory.uid,
                          journal.inputSHA256 == inputDigest,
                          journal.phase != .cleanupPending, journal.phase != .draining,
                          journal.phase != .recoveredAfterBoot else { throw CustodyRecordError.fenced }
                }
            }
            return control
        }
    }
    static func requiresStagedHost(admission: LifecycleAdmissionAuthority,
                                   validationProfile: InstallationValidationProfile = .production) throws -> Bool {
        try validationProfile.revalidate()
        let store = try Self(leases: admission.retainObservationLeases(), validationProfile: validationProfile)
        return try store.locked {
            let control = try InstallationControlRecord.decode(store.read(InstallationControlRecord.filename,
                maximum: InstallationControlRecord.maximumBytes).bytes, profile: validationProfile)
            if control.phase == .active { return true }
            guard control.phase == .committed else { throw CustodyRecordError.fenced }
            _ = try store.installationSnapshot()
            return false
        }
    }
    static func precommitObservation(admission: LifecycleAdmissionAuthority,
                                     validationProfile: InstallationValidationProfile = .production) throws -> InstallationControlRecord {
        let control = try precommitWaitObservation(admission: admission, validationProfile: validationProfile)
        guard control.step?.status == .complete else { throw CustodyRecordError.fenced }
        return control
    }
    /// Read-only durable observation. Neither this type nor decoded control can
    /// construct host admission; only the current authenticated host may do so.
    final class HostCommittedObservation {
        private let store: CustodyCatalogStore
        let control: InstallationControlRecord
        private let files: [String: File]
        private let pins: [String: Node]
        fileprivate init(store: CustodyCatalogStore, control: InstallationControlRecord,
                         files: [String: File], pins: [String: Node]) {
            self.store = store; self.control = control; self.files = files; self.pins = pins
        }
        func revalidate(deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            let current = try store.hostCommittedFiles(expected: control, deadline: deadline)
            guard Set(current.keys) == Set(files.keys) else { throw CustodyRecordError.fenced }
            for (name, file) in files {
                guard let observed = current[name], let pin = pins[name],
                      file.identity == observed.identity, file.acl == observed.acl,
                      file.bytes == observed.bytes else { throw CustodyRecordError.fenced }
                let parent = name.hasPrefix("receipts/") ? store.receipts.descriptor.value : store.directory.descriptor.value
                try store.validate(pin, at: parent, name: String(name.split(separator: "/").last!), isDirectory: false)
            }
            try store.validateBindings()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
    }
    // This private store is never shared with a writer. Optimistic before/after
    // readback refuses changes; no catalog/ownership/registry mutex spans IO.
    private func hostCommittedFiles(expected: InstallationControlRecord,
                                    deadline: MonotonicDeadline) throws -> [String: File] {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        try validateBindings()
        let installation = try installationSnapshot(), catalog = try snapshot()
        guard installation.1 == expected,
              expected.phase == .committed || (expected.phase == .recovery && expected.recoveryReason == .startupUncertain),
              expected.step?.action == .readinessCommit, expected.step?.status == .complete,
              expected.readinessCommit?.commitRevision == (expected.phase == .committed ? expected.revision : expected.revision - 1),
              catalog.1.entries.isEmpty else { throw CustodyRecordError.fenced }
        var files = [InstallationControlRecord.filename: installation.0, "catalog.json": catalog.0]
        for name in try InstallationStagedAdmissionIntent.names(receipts.descriptor.value) {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if name.hasPrefix(InstallationStepReceipt.prefix) || name.hasPrefix(InstallationDocumentPreimage.prefix) {
                let maximum = name.hasPrefix(InstallationStepReceipt.prefix)
                    ? InstallationStepReceipt.maximumBytes : InstallationDocumentPreimage.maximumBytes
                files["receipts/" + name] = try read(name, at: receipts.descriptor.value, maximum: maximum)
            }
        }
        // Revalidate the full accepted chain after capturing its exact bytes.
        let after = try installationSnapshot()
        guard after.1 == expected, after.0.identity == installation.0.identity,
              after.0.acl == installation.0.acl, after.0.bytes == installation.0.bytes,
              try snapshot().1.entries.isEmpty else { throw CustodyRecordError.fenced }
        try validateBindings()
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        return files
    }
    static func readinessStopHostObservation(admission: LifecycleAdmissionAuthority,
        expected: InstallationControlRecord, deadline: MonotonicDeadline,
        validationProfile: InstallationValidationProfile = .production) throws {
        try validationProfile.revalidate()
        guard admission.commandAdmissionIsOpen, !deadline.hasExpired,
              expected.phase == .recovery, expected.readinessCommit == nil,
              expected.recoveryReason == .readinessFailed, expected.step?.action == .candidateStop,
              expected.step?.status == .intent, expected.step?.ordinal == 16,
              expected.transaction?.boot == (try CustodyBootIdentity.current()) else { throw CustodyRecordError.fenced }
        let store = try Self(leases: admission.retainObservationLeases(), validationProfile: validationProfile)
        try store.locked {
            guard try store.installationSnapshot().1 == expected,
                  try store.snapshot().1.entries.isEmpty else { throw CustodyRecordError.fenced }
            try store.validateBindings()
        }
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
    }
    static func committedHostObservation(admission: LifecycleAdmissionAuthority,
                                         expected: InstallationControlRecord,
                                         deadline: MonotonicDeadline,
                                         validationProfile: InstallationValidationProfile = .production) throws -> HostCommittedObservation {
        guard admission.commandAdmissionIsOpen, !deadline.hasExpired else { throw CustodyRecordError.fenced }
        try validationProfile.revalidate()
        let store = try Self(leases: admission.retainObservationLeases(), validationProfile: validationProfile)
        let files = try store.hostCommittedFiles(expected: expected, deadline: deadline)
        var pins: [String: Node] = [:]
        for (name, file) in files {
            let parent = name.hasPrefix("receipts/") ? store.receipts.descriptor.value : store.directory.descriptor.value
            let pin = try Self.openNode(parent, String(name.split(separator: "/").last!), uid: store.uid, directory: false)
            guard pin.identity == file.identity, pin.acl == file.acl else { throw CustodyRecordError.fenced }
            pins[name] = pin
        }
        let result = HostCommittedObservation(store: store, control: expected, files: files, pins: pins)
        try result.revalidate(deadline: deadline)
        return result
    }
    private func installationFence(mode: CustodyAuthorityMode) throws {
        let record = try installationSnapshot().1
        switch record.phase {
        case .committed: break // Exact installed residual slots remain a separate live installation gate.
        case .active, .recovery:
            guard mode == .observation else { throw CustodyRecordError.fenced }
        case .initial:
            // Initial diagnostics use the initializer's typed inspection below;
            // they cannot spawn an ordinary lifecycle observation command.
            throw CustodyRecordError.fenced
        }
    }
    func checkFreshInitializationFence(_ proof: FreshStateInitialization.ControlInspection) throws {
        try locked {
            guard try proof.leases === leases, try leases.mode == .mutation else { throw CustodyRecordError.fenced }
            let record = try installationSnapshot().1
            guard record.phase == .initial,
                  Set(try names()) == ["catalog.lock", "catalog.json", "receipts", InstallationControlRecord.filename],
                  try CustodyCatalog.decode(read("catalog.json", maximum: CustodyCatalog.maximumBytes).bytes) == .initialized else {
                throw CustodyRecordError.fenced
            }
            // Fresh state has no command or installation history at all.
            let fd = openat(receipts.descriptor.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }
            guard let stream = fdopendir(fd) else { close(fd); throw CustodyRecordError.unsafeMetadata }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let row = readdir(stream) else {
                    guard errno == 0 else { throw CustodyRecordError.persistence(errno) }; break
                }
                let name = withUnsafePointer(to: row.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                guard name == "." || name == ".." else { throw CustodyRecordError.fenced }
            }
        }
    }

    private func snapshot() throws -> (File, CustodyCatalog, [String: CustodyJournal]) {
        let file = try read("catalog.json", maximum: CustodyCatalog.maximumBytes), catalog = try CustodyCatalog.decode(file.bytes)
        var journals: [String: CustodyJournal] = [:]
        let expected = Set(catalog.entries.map(\.filename)), all = Set(try names())
        guard expected.isSubset(of: all), all.contains("catalog.lock"), all.contains("receipts") else { throw CustodyRecordError.fenced }
        for name in all.subtracting(["catalog.json", "catalog.lock", "receipts", InstallationControlRecord.filename]) {
            guard name.hasSuffix(".json"), RunIdentity.isValid(String(name.dropLast(5))) else { throw CustodyRecordError.fenced }
            let bytes = try read(name, maximum: CustodyJournal.maximumBytes).bytes
            let journal = try CustodyJournal.decode(bytes)
            guard name == journal.binding.requestID + ".json" else { throw CustodyRecordError.fenced }
            if journal.kind == .discoveryGit {
                let resource = try discoveryResource(journal)
                if journal.phase == .terminal, resource.phase != .retired { throw CustodyRecordError.fenced }
            }
            if journal.phase == .recoveredAfterBoot { _ = try recoveryPreimage(for: journal) }
            var archiveInfo = stat()
            if fstatat(receipts.descriptor.value, name, &archiveInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                guard journal.phase.isTerminal else { throw CustodyRecordError.fenced }
                _ = try archived(journal, expected: bytes)
            } else if errno != ENOENT { throw CustodyRecordError.unsafeMetadata }
            if let entry = catalog.entries.first(where: { $0.filename == name }) {
                guard entry == CustodyCatalogEntry(journal) else { throw CustodyRecordError.fenced }
            } else {
                // A crash after catalog retirement is safe only with the exact
                // durable terminal archive, never by UUID/phase alone.
                guard journal.phase.isTerminal else { throw CustodyRecordError.fenced }
                _ = try archived(journal, expected: bytes)
            }
            journals[journal.binding.requestID] = journal
        }
        return (file, catalog, journals)
    }
    private func fence(_ catalog: CustodyCatalog, journals: [String: CustodyJournal], ownRequests: Set<String>, scope: String, mode: CustodyAuthorityMode) throws {
        for entry in catalog.entries {
            guard let journal = journals[entry.requestID] else { throw CustodyRecordError.fenced }
            // Boot recovery establishes interruption, never a successful Git
            // postflight. The policy-gated operation recovery must be integrated
            // before this evidence can be retired. Fixed diagnostics may observe.
            if journal.phase == .recoveredAfterBoot {
                guard mode == .observation else { throw CustodyRecordError.fenced }
                continue
            }
            if journal.phase.isTerminal {
                guard !mode.isInstallationStaged || (ownRequests.contains(entry.requestID) && entry.scopeID == scope) else { throw CustodyRecordError.fenced }
                continue
            }
            if ownRequests.contains(entry.requestID), entry.scopeID == scope {
                // A live reference permits in-flight work, never reuse after
                // drainage or expiry. This also applies to observation scopes;
                // only a separate diagnostic scope may coexist with that fence.
                guard journal.phase != .draining, journal.phase != .cleanupPending,
                      DispatchTime.now().uptimeNanoseconds < journal.budget.work else {
                    throw CustodyRecordError.fenced
                }
                continue
            }
            if mode == .observation { continue } // Fixed diagnostics only; malformed evidence already refused.
            throw CustodyRecordError.fenced
        }
    }
    func checkFence(ownRequests: Set<String>, scope: String, mode: CustodyAuthorityMode, installation: InstallationCommandPermit? = nil) throws {
        try locked {
            guard try mode == leases.mode else { throw CustodyRecordError.fenced }
            if let installation { try validateInstallationCommand(installation.observation) }
            else { try installationFence(mode: mode) }
            let s = try snapshot(); try fence(s.1, journals: s.2, ownRequests: ownRequests, scope: scope, mode: mode)
        }
    }
    fileprivate func reserveAndPrepare(_ journal: CustodyJournal, ownRequests: Set<String>, scope: String, installation: InstallationCommandPermit? = nil) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.lockValidation
        var diagnosticPassed = false
        var diagnosticMilestones: [UInt64] = []
        // Emit only after releasing the store guard, and only for the parent
        // policy reservation. No request identity or persisted bytes are logged.
        defer {
            if journal.kind == .policyClassify {
                DiscoveryFixtureDiagnostic.record(.publication, stage: diagnosticStage,
                    started: diagnosticStart, deadline: journal.budget.work, succeeded: diagnosticPassed,
                    milestones: diagnosticMilestones)
            }
        }
        #endif
        try locked {
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .installationFence
            #endif
            guard try journal.authority == leases.mode, journal.binding.scopeID == scope,
                  journal.binding.uid == uid, journal.phase == .prepared else { throw CustodyRecordError.fenced }
            if let installation { try validateInstallationCommand(installation.observation) }
            else { try installationFence(mode: journal.authority) }
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .catalogFence
            #endif
            let s = try snapshot(); try fence(s.1, journals: s.2, ownRequests: ownRequests, scope: scope, mode: journal.authority)
            guard s.2[journal.binding.requestID] == nil else { throw CustodyRecordError.conflict }
            var archivedInfo = stat()
            guard fstatat(receipts.descriptor.value, journal.binding.requestID + ".json", &archivedInfo, AT_SYMLINK_NOFOLLOW) == -1,
                  errno == ENOENT else { throw CustodyRecordError.conflict }
            let resourceName = "discovery-resource-" + journal.binding.requestID + ".json"
            if journal.kind == .discoveryGit {
                guard fstatat(receipts.descriptor.value, resourceName, &archivedInfo, AT_SYMLINK_NOFOLLOW) == -1,
                      errno == ENOENT else { throw CustodyRecordError.conflict }
            }
            // Catalog is durable first. Failure before prepared publication is
            // detectable as a missing expected journal, never as no transaction.
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .reservationWrite
            #endif
            try write("catalog.json", bytes: s.1.reserving(journal).encode(), expected: s.0)
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .preparedWrite
            try fault(.afterReservation)
            #endif
            if journal.kind == .discoveryGit {
                try write(resourceName, at: receipts.descriptor.value,
                          bytes: DiscoveryResourceReceipt(planned: journal.binding).encode(), expected: nil)
            }
            try write(journal.binding.requestID + ".json", bytes: journal.encode(), expected: nil)
            #if SHADOW_SYNC_TESTING
            try fault(.afterPrepared)
            #endif
        }
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
    }
    fileprivate func replaceJournal(_ expected: CustodyJournal, with next: CustodyJournal) throws {
        try locked { try replaceJournalLocked(expected, with: next) }
    }
    fileprivate func admitJournal(_ expected: CustodyJournal, with next: CustodyJournal,
                                 deadline: UInt64, revalidate: @escaping () throws -> Void) throws {
        guard expected.phase == .prepared, next.phase == .admitted else { throw CustodyRecordError.invalidTransition }
        guard deadline <= expected.budget.work else { throw CustodyProtocolError.invalidBudget }
        try locked(admission: AdmissionWait(deadline: deadline, revalidate: revalidate)) {
            try replaceJournalLocked(expected, with: next)
        }
    }
    /// The child is still suspended under its original owner while execution
    /// metadata waits for an unrelated writer. Retry only unacquired guards;
    /// the durable comparison/write remains a single action.
    fileprivate func executeJournal(_ expected: CustodyJournal, with next: CustodyJournal,
                                   deadline: UInt64, revalidate: @escaping () throws -> Void) throws {
        guard [.admitted, .executing].contains(expected.phase), next.phase == .executing else {
            throw CustodyRecordError.invalidTransition
        }
        guard deadline <= expected.budget.work else { throw CustodyProtocolError.invalidBudget }
        try locked(admission: AdmissionWait(deadline: deadline, revalidate: revalidate)) {
            try replaceJournalLocked(expected, with: next)
        }
    }
    private func replaceJournalLocked(_ expected: CustodyJournal, with next: CustodyJournal) throws {
        let s = try snapshot()
        guard s.1.entries.contains(CustodyCatalogEntry(expected)), s.2[expected.binding.requestID] == expected,
              expected.binding == next.binding, expected.kind == next.kind, expected.authority == next.authority,
              expected.budget == next.budget, expected.inputSHA256 == next.inputSHA256,
              expected.resourcesSHA256 == next.resourcesSHA256, expected.leases == next.leases,
              expected.ordinal < UInt64.max, next.ordinal == expected.ordinal + 1 else { throw CustodyRecordError.conflict }
        // The proposed transition must be obtainable from the closed model.
        let proposal = try next.phase == .recoveredAfterBoot ? expected.recoveredAfterBoot()
            : expected.advancing(to: next.phase, custodian: next.custodian, target: next.target,
                outcome: next.outcome, reason: next.reason, waitStatus: next.waitStatus)
        guard proposal == next else { throw CustodyRecordError.invalidTransition }
        if next.kind == .discoveryGit, next.phase == .terminal {
            guard try discoveryResource(expected).phase == .retired else { throw CustodyRecordError.fenced }
        }
        let name = expected.binding.requestID + ".json", file = try read(name, maximum: CustodyJournal.maximumBytes)
        try write(name, bytes: next.encode(), expected: file)
    }
    fileprivate func claimHelper(_ inherited: CustodyInheritedCommand) throws -> CustodyJournal {
        try locked {
            if let installation = inherited.installation { try validateInstallationCommand(installation) }
            else { try installationFence(mode: inherited.request.authority) }
            return try claimPrepared(inherited.request)
        }
    }
    /// Called under catalog.lock after the unchanged installation fence. Keep
    /// the durable prepared bytes as the exact preimage; fresh live lease
    /// observations validate their bindings, not a mutable directory child count.
    private func claimPrepared(_ request: UnvalidatedCustodyRequest) throws -> CustodyJournal {
        let s = try snapshot()
        guard let recorded = s.2[request.binding.requestID] else { throw CustodyRecordError.fenced }
        let live = try leases.descriptorClaims().sorted { $0.role.number < $1.role.number }
        guard recorded.leases.count == live.count,
              zip(live, recorded.leases).allSatisfy({ CustodyInheritedCommand.matchesInheritedClaim($0.0, $0.1) }) else {
            throw CustodyRecordError.fenced
        }
        let expected = try CustodyJournal(prepared: request, leases: recorded.leases)
        guard s.1.entries.contains(CustodyCatalogEntry(expected)), recorded == expected else { throw CustodyRecordError.fenced }
        return recorded
    }
    #if SHADOW_SYNC_TESTING
    /// Exercises the actual admission persistence/acquisition path with synthetic
    /// process observations only; this cannot spawn or grant helper authority.
    @_silgen_name("shadowSyncTesting_testingAdmitJournal")
    @inline(never)
    func testingAdmitJournal(_ expected: CustodyJournal, with next: CustodyJournal,
                             deadline: UInt64, revalidate: @escaping () throws -> Void) throws {
        try admitJournal(expected, with: next, deadline: deadline, revalidate: revalidate)
    }
    /// Synthetic observations exercise execution persistence only. No child,
    /// helper authority, resume operation or replacement owner is constructed.
    func testingExecuteJournal(_ expected: CustodyJournal, with next: CustodyJournal,
                               deadline: UInt64, revalidate: @escaping () throws -> Void) throws {
        try executeJournal(expected, with: next, deadline: deadline, revalidate: revalidate)
    }
    /// Metadata-only fixture entry through the same guarded comparison. It
    /// neither constructs a helper nor transfers writer/process authority.
    func testingClaimPrepared(_ request: UnvalidatedCustodyRequest) throws -> CustodyJournal {
        try locked {
            try installationFence(mode: request.authority)
            return try claimPrepared(request)
        }
    }
    #endif
    /// Narrow persistence primitive for the discovery resource owner. The
    /// existing outstanding journal supplies the durable admission fence. This
    /// does not create or delete scratch resources or grant target admission.
    func persistDiscoveryResource(journal: CustodyJournal, expected: DiscoveryResourceReceipt?,
                                  next: DiscoveryResourceReceipt) throws {
        try locked {
            let s = try snapshot()
            guard journal.kind == .discoveryGit, !journal.phase.isTerminal,
                  s.2[journal.binding.requestID] == journal,
                  s.1.entries.contains(CustodyCatalogEntry(journal)), next.binding == journal.binding else {
                throw CustodyRecordError.fenced
            }
            try next.validate()
            guard let expected else { throw CustodyRecordError.fenced }
            try expected.validateSuccessor(next)
            guard journal.phase != .prepared || (expected.phase == .planned && next.phase == .retired) else {
                throw CustodyRecordError.invalidTransition
            }
            let name = "discovery-resource-" + journal.binding.requestID + ".json"
            let bytes = try next.encode()
            var info = stat()
            if fstatat(receipts.descriptor.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                let before = try read(name, at: receipts.descriptor.value, maximum: DiscoveryResourceReceipt.maximumBytes)
                let current = try DiscoveryResourceReceipt.decode(before.bytes)
                // A prior write may have committed before reporting an error.
                // Exact-byte retry re-proves durability without another swap.
                if current == next {
                    let node = try Self.openNode(receipts.descriptor.value, name, uid: uid, directory: false)
                    guard node.identity == before.identity, node.acl == before.acl,
                          fsync(node.descriptor.value) == 0, fsync(receipts.descriptor.value) == 0 else {
                        throw CustodyRecordError.unsafeMetadata
                    }
                    try validate(node, at: receipts.descriptor.value, name: name, isDirectory: false)
                    return
                }
                guard current == expected else { throw CustodyRecordError.conflict }
                try write(name, at: receipts.descriptor.value, bytes: bytes, expected: before)
            } else {
                // The planned receipt is mandatory from reservation onward.
                // Missing evidence cannot be recreated by a later owner.
                throw CustodyRecordError.fenced
            }
        }
    }
    func readDiscoveryResource(journal: CustodyJournal) throws -> DiscoveryResourceReceipt {
        try locked {
            let s = try snapshot()
            guard journal.kind == .discoveryGit, s.2[journal.binding.requestID] == journal,
                  s.1.entries.contains(CustodyCatalogEntry(journal)) else { throw CustodyRecordError.fenced }
            return try discoveryResource(journal)
        }
    }
    private func discoveryResource(_ journal: CustodyJournal) throws -> DiscoveryResourceReceipt {
        let file = try read("discovery-resource-" + journal.binding.requestID + ".json",
            at: receipts.descriptor.value, maximum: DiscoveryResourceReceipt.maximumBytes)
        let receipt = try DiscoveryResourceReceipt.decode(file.bytes)
        guard receipt.binding == journal.binding else { throw CustodyRecordError.fenced }
        return receipt
    }
    fileprivate func observeTerminal(prepared: CustodyJournal, owner: OwnedDirectChild, message: CustodyMessage) throws -> CustodyJournal {
        try locked {
            let s = try snapshot()
            guard let journal = s.2[prepared.binding.requestID], journal.phase == .terminal,
                  s.1.entries.contains(CustodyCatalogEntry(prepared)),
                  journal.binding == prepared.binding, journal.kind == prepared.kind,
                  journal.authority == prepared.authority, journal.budget == prepared.budget,
                  journal.inputSHA256 == prepared.inputSHA256, journal.resourcesSHA256 == prepared.resourcesSHA256,
                  journal.leases == prepared.leases, journal.ordinal > prepared.ordinal,
                  journal.custodian == (try CustodyProcessObservation(owner.identity)),
                  message.event == .terminal, message.outcome?.rawValue == journal.outcome?.rawValue,
                  message.waitStatus == journal.waitStatus,
                  (try CustodyRecordBinding(message.binding)) == journal.binding,
                  message.receiptSHA256 == CustodyRecordBinding.digest(try journal.encode()) else {
                throw CustodyRecordError.fenced
            }
            return journal
        }
    }
    private func archiveBytes(_ journal: CustodyJournal, bytes: Data) throws -> Data {
        guard journal.phase.isTerminal else { throw CustodyRecordError.invalidTransition }
        var fields: [String: PolicyWireValue] = ["schema": .string("shadow-sync-custody-receipt/v1"),
            "journal_sha256": .string(CustodyRecordBinding.digest(bytes)), "journal": journal.wire]
        if journal.kind == .discoveryGit {
            let resource = try discoveryResource(journal)
            guard journal.phase != .terminal || resource.phase == .retired else { throw CustodyRecordError.fenced }
            fields["schema"] = .string("shadow-sync-custody-receipt/v2")
            fields["discovery_resource"] = resource.wire
            fields["discovery_resource_sha256"] = .string(CustodyRecordBinding.digest(try resource.encode()))
        }
        return try CustodyWire.encode(.object(fields), maximum: 65_536)
    }
    private func archived(_ journal: CustodyJournal, expected: Data) throws -> String {
        let file = try read(journal.binding.requestID + ".json", at: receipts.descriptor.value, maximum: 65_536)
        guard file.bytes == (try archiveBytes(journal, bytes: expected)) else { throw CustodyRecordError.fenced }
        return CustodyRecordBinding.digest(file.bytes)
    }
    fileprivate func archiveAndRetire(_ journal: CustodyJournal, callerObservation: Data? = nil) throws -> String {
        try locked {
            let s = try snapshot(), name = journal.binding.requestID + ".json"
            guard journal.phase == .terminal, s.2[journal.binding.requestID] == journal,
                  s.1.entries.contains(CustodyCatalogEntry(journal)) else { throw CustodyRecordError.conflict }
            let bytes = try journal.encode(), archive = try archiveBytes(journal, bytes: bytes)
            var info = stat()
            if fstatat(receipts.descriptor.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                _ = try archived(journal, expected: bytes)
                let fd = openat(receipts.descriptor.value, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }; defer { close(fd) }
                guard fsync(fd) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
            } else {
                guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }
                try write(name, at: receipts.descriptor.value, bytes: archive, expected: nil)
            }
            if let callerObservation {
                let observerName = journal.binding.requestID + ".caller.json"
                var observerInfo = stat()
                if fstatat(receipts.descriptor.value, observerName, &observerInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                    let current = try read(observerName, at: receipts.descriptor.value, maximum: 65_536)
                    guard current.bytes == callerObservation else { throw CustodyRecordError.conflict }
                    let fd = openat(receipts.descriptor.value, observerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }; defer { close(fd) }
                    guard fsync(fd) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
                } else {
                    guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }
                    try write(observerName, at: receipts.descriptor.value, bytes: callerObservation, expected: nil)
                }
            }
            #if SHADOW_SYNC_TESTING
            try fault(.afterArchive)
            #endif
            try write("catalog.json", bytes: s.1.retiring(journal).encode(), expected: s.0)
            #if SHADOW_SYNC_TESTING
            try fault(.afterRetirement)
            #endif
            // Retirement has become durable. Only the exact known terminal
            // journal is removed; its archive remains under recovery retention.
            let current = try read(name, maximum: CustodyJournal.maximumBytes)
            guard current.bytes == bytes, unlinkat(directory.descriptor.value, name, 0) == 0,
                  fsync(directory.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
            return CustodyRecordBinding.digest(archive)
        }
    }

    private func recoveryBytes(_ original: CustodyJournal, boot: String) throws -> Data {
        guard RunIdentity.isValid(boot), original.binding.bootID != boot,
              !original.phase.isTerminal else { throw CustodyRecordError.fenced }
        let recovered = try original.recoveredAfterBoot()
        return try CustodyWire.encode(.object([
            "schema": .string("shadow-sync-custody-boot-recovery/v1"),
            "observed_boot": .string(boot), "original": original.wire,
            "original_sha256": .string(CustodyRecordBinding.digest(try original.encode())),
            "recovered_sha256": .string(CustodyRecordBinding.digest(try recovered.encode())),
        ]), maximum: 65_536)
    }
    private func checkedRecoveryPreimage(_ requestID: String) throws -> (original: CustodyJournal, bytes: Data) {
        let bytes = try read(requestID + ".recovery.json",
                             at: receipts.descriptor.value, maximum: 65_536).bytes
        let wire = try CustodyWire.decode(bytes, maximum: 65_536).object(keys:
            ["schema", "observed_boot", "original", "original_sha256", "recovered_sha256"])
        guard let originalWire = wire["original"] else { throw CustodyRecordError.fenced }
        let original = try CustodyJournal.decode(CustodyWire.encode(originalWire, maximum: CustodyJournal.maximumBytes))
        let boot = try CustodyWire.text(wire["observed_boot"])
        guard original.binding.requestID == requestID,
              bytes == (try recoveryBytes(original, boot: boot)) else { throw CustodyRecordError.fenced }
        return (original, bytes)
    }
    private func recoveryPreimage(for recovered: CustodyJournal) throws -> Data {
        let receipt = try checkedRecoveryPreimage(recovered.binding.requestID)
        guard recovered == (try receipt.original.recoveredAfterBoot()) else { throw CustodyRecordError.fenced }
        return receipt.bytes
    }

    /// Called only by the typed recovery context with fresh exclusive original
    /// authority. This preserves the complete preimage before publishing unknown
    /// interruption; it does not signal, spawn, access candidates or retire work.
    fileprivate func recoverPriorBoot(_ context: CustodyRecoveryContext) throws -> [CustodyJournal] {
        guard try context.owns(leases) else { throw CustodyRecordError.fenced }
        let claims = try leases.descriptorClaims()
        return try locked {
            let snapshot = try snapshot()
            let journals = try snapshot.1.entries.map { entry -> CustodyJournal in
                guard let journal = snapshot.2[entry.requestID] else { throw CustodyRecordError.fenced }
                // Old and new leases may have different read/write access, but
                // must designate the very same original state and lock inodes.
                for previous in journal.leases {
                    guard let current = claims.first(where: { $0.role == previous.role }),
                          current.device == previous.device, current.inode == previous.inode,
                          current.uid == previous.uid, current.mode == previous.mode,
                          previous.role == .state || current.links == previous.links else {
                        throw CustodyRecordError.fenced
                    }
                }
                guard journal.phase.isTerminal || journal.binding.bootID != context.bootID else {
                    throw CustodyRecordError.fenced
                }
                return journal
            }
            // Validate the entire expected set before the first write. A mixed
            // current/prior-boot set cannot be partially cleared.
            for journal in journals where !journal.phase.isTerminal {
                var info = stat(); let name = journal.binding.requestID + ".recovery.json"
                if fstatat(receipts.descriptor.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    // A previous recovery boot may itself have ended before
                    // journal publication. Preserve its valid receipt rather
                    // than rewriting the observed boot or abandoning the retry.
                    guard try checkedRecoveryPreimage(journal.binding.requestID).original == journal else {
                        throw CustodyRecordError.fenced
                    }
                } else if errno != ENOENT { throw CustodyRecordError.unsafeMetadata }
            }
            var results: [CustodyJournal] = []
            for journal in journals {
                if journal.phase == .terminal { continue }
                if journal.phase == .recoveredAfterBoot { results.append(journal); continue }
                let preimageName = journal.binding.requestID + ".recovery.json"
                let preimage = try recoveryBytes(journal, boot: context.bootID)
                var info = stat()
                if fstatat(receipts.descriptor.value, preimageName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard try checkedRecoveryPreimage(journal.binding.requestID).original == journal else {
                        throw CustodyRecordError.fenced
                    }
                    let fd = openat(receipts.descriptor.value, preimageName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }; defer { close(fd) }
                    guard fsync(fd) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
                } else {
                    guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }
                    try write(preimageName, at: receipts.descriptor.value, bytes: preimage, expected: nil)
                }
                #if SHADOW_SYNC_TESTING
                try fault(.afterRecoveryPreimage)
                #endif
                let name = journal.binding.requestID + ".json", before = try read(name, maximum: CustodyJournal.maximumBytes)
                guard before.bytes == (try journal.encode()) else { throw CustodyRecordError.conflict }
                let recovered = try journal.recoveredAfterBoot()
                try write(name, bytes: recovered.encode(), expected: before)
                #if SHADOW_SYNC_TESTING
                try fault(.afterRecoveryJournal)
                #endif
                results.append(recovered)
            }
            return results
        }
    }
    private func write(_ name: String, at parent: Int32? = nil, bytes: Data, expected: File?) throws {
        let parent = parent ?? directory.descriptor.value
        let temp = ".custody-pending-" + UUID().uuidString.lowercased()
        let fd = openat(parent, temp, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CustodyRecordError.persistence(errno) }
        let owner = OwnedFileDescriptor(fd), created = try Self.node(owner, uid: uid, directory: false)
        var touched = false, complete = false
        defer {
            if !touched {
                var info = stat()
                if fstatat(parent, temp, &info, AT_SYMLINK_NOFOLLOW) == 0 && FileIdentity(info) == created.identity { _ = unlinkat(parent, temp, 0) }
            }
            if !complete { poisoned = true }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CustodyRecordError.persistence(errno) }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        #if SHADOW_SYNC_TESTING
        try CustodyCatalogWriteTesting.hit(parent)
        try fault(.beforeSwap)
        #endif
        if let expected {
            let current = try read(name, at: parent, maximum: max(CustodyCatalog.maximumBytes, bytes.count))
            guard current.identity == expected.identity, current.acl == expected.acl, current.bytes == expected.bytes else { throw CustodyRecordError.conflict }
            guard renameatx_np(parent, temp, parent, name, UInt32(RENAME_SWAP)) == 0 else { throw CustodyRecordError.persistence(errno) }
            touched = true
            let old = try read(temp, at: parent, maximum: CustodyCatalog.maximumBytes)
            guard old.identity == expected.identity, old.acl == expected.acl, old.bytes == expected.bytes else { throw CustodyRecordError.conflict }
        } else {
            guard renameatx_np(parent, temp, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw CustodyRecordError.persistence(errno) }
            touched = true
        }
        #if SHADOW_SYNC_TESTING
        try fault(.afterSwap)
        #endif
        guard fsync(parent) == 0 else { throw CustodyRecordError.persistence(errno) }
        #if SHADOW_SYNC_TESTING
        try fault(.afterDirectorySync)
        #endif
        if expected != nil {
            // The new record is already directory-fsynced. Cleanup errors must
            // preserve that committed-state distinction, including when the
            // obsolete preimage has been unlinked but its deletion is not synced.
            guard unlinkat(parent, temp, 0) == 0 else { throw CustodyRecordError.committedCleanupFailure(errno) }
            #if SHADOW_SYNC_TESTING
            do { try fault(.afterPreimageUnlink) }
            catch { throw CustodyRecordError.committedCleanupFailure(EIO) }
            #endif
            guard fsync(parent) == 0 else { throw CustodyRecordError.committedCleanupFailure(errno) }
        }
        complete = true
    }
    #if SHADOW_SYNC_TESTING
    enum Fault { case beforeSwap, afterSwap, afterDirectorySync, afterPreimageUnlink, afterReservation, afterPrepared, afterArchive, afterRetirement, afterRecoveryPreimage, afterRecoveryJournal }
    private func fault(_ cut: Fault) throws {
        #if SHADOW_SYNC_TESTING
        if testingCut == cut { testingCut = nil; poisoned = true; throw CustodyRecordError.injectedFailure }
        #endif
    }
    private var testingCut: Fault?
    func testingFault(_ cut: Fault?) { mutex.lock(); testingCut = cut; mutex.unlock() }
    func testingRead() throws -> CustodyCatalog { try locked { try snapshot().1 } }
    func testingInstallationRecord() throws -> InstallationControlRecord {
        try locked { _ = try snapshot(); return try installationSnapshot().1 }
    }
    // Synthetic metadata for isolated command/lease tests, never an installer
    // completion receipt or evidence of authenticated readiness. Only testing
    // builds can seed it; production has no corresponding bypass or path API.
    static func testingSeedCommittedInstallation(leases: CustodyAuthorityLeaseSet, root fixtureRoot: String) throws {
        let fixture = try TestIsolation.validateRoot(fixtureRoot)
        let state = try leases.duplicateStateDirectory()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(state.0.value, F_GETPATH, &path) == 0, String(cString: path).hasPrefix(fixture + "/"),
              leases.mode == .mutation || leases.mode == .lifecycleMutation else { throw CustodyRecordError.unsafeMetadata }
        let store = try Self(leases: leases)
        try store.locked {
            guard try store.names().allSatisfy({ ["catalog.lock", "catalog.json", "receipts", InstallationControlRecord.filename].contains($0) }),
                  try CustodyCatalog.decode(store.read("catalog.json", maximum: CustodyCatalog.maximumBytes).bytes) == .initialized else {
                throw CustodyRecordError.fenced
            }
            let binding = try InstallationStateBinding.capture(stateDescriptor: state.0.value, uid: state.1)
            let expected: File?
            var existing = stat()
            if fstatat(store.directory.descriptor.value, InstallationControlRecord.filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                expected = try store.read(InstallationControlRecord.filename, maximum: InstallationControlRecord.maximumBytes)
                guard expected!.bytes == (try InstallationControlRecord.initial(state: binding).encode()) else { throw CustodyRecordError.fenced }
            } else {
                guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }; expected = nil
            }
            var harness = try InstallationControlFixtures.Harness(state: binding)
            try harness.throughReady(); try harness.commitReady()
            for action in [InstallationAction.cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish] { try harness.pair(action) }
            try harness.record.validateReceiptChain(harness.receipts)
            for receipt in harness.receipts {
                try store.write(receipt.filename(uid: state.1), at: store.receipts.descriptor.value,
                                bytes: receipt.encode(uid: state.1), expected: nil)
            }
            try store.write(InstallationControlRecord.filename, bytes: harness.record.encode(), expected: expected)
        }
    }
    static func testingInitialize(leases: CustodyAuthorityLeaseSet, root fixtureRoot: String) throws {
        let root = try TestIsolation.validateRoot(fixtureRoot)
        let state = try leases.duplicateStateDirectory()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(state.0.value, F_GETPATH, &path) == 0, String(cString: path).hasPrefix(root + "/"),
              leases.mode == .mutation || leases.mode == .lifecycleMutation else { throw CustodyRecordError.unsafeMetadata }
        guard mkdirat(state.0.value, "custody", 0o700) == 0 else { throw CustodyRecordError.conflict }
        let directory = try openNode(state.0.value, "custody", uid: state.1, directory: true)
        guard mkdirat(directory.descriptor.value, "receipts", 0o700) == 0 else { throw CustodyRecordError.persistence(errno) }
        for (name, bytes) in [("catalog.lock", Data()), ("catalog.json", try CustodyCatalog.initialized.encode())] {
            let fd = openat(directory.descriptor.value, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CustodyRecordError.persistence(errno) }; defer { close(fd) }
            try bytes.withUnsafeBytes { buffer in
                if !buffer.isEmpty { guard Darwin.write(fd, buffer.baseAddress, buffer.count) == buffer.count else { throw CustodyRecordError.persistence(errno) } }
            }
            guard fsync(fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        guard fsync(directory.descriptor.value) == 0, fsync(state.0.value) == 0 else { throw CustodyRecordError.persistence(errno) }
        try testingSeedCommittedInstallation(leases: leases, root: fixtureRoot)
    }
    #endif
}

/// One helper-local writer acquired from authenticated inherited resources and
/// an exact outstanding prepared record. It never initializes missing state or
/// adopts a PID from a journal. The caller retains a separate observation role.
final class CustodyHelperJournal {
    let inherited: CustodyInheritedCommand
    let leases: CustodyAuthorityLeaseSet
    private let store: CustodyCatalogStore
    private(set) var current: CustodyJournal
    #if SHADOW_SYNC_TESTING
    enum TestingTerminalStage: String {
        case notAttempted, retirement, discoveryResource, recordConstruction
        case persistenceResources, storeReplace, completed
    }
    private(set) var testingTerminalStage: TestingTerminalStage = .notAttempted
    func testingRecordedOwnerMatches(_ owner: OwnedDirectChild?) -> Bool {
        owner != nil && recordedOwner === owner
    }
    #endif
    private let helperObservation: CustodyProcessObservation
    private var recordedOwner: OwnedDirectChild?
    private struct SerialRetirement {
        let owner: OwnedDirectChild
        let waitStatus: Int32
    }
    private var serialRetirement: SerialRetirement?
    private(set) var discoveryResource: DiscoveryFrozenResource?
    private init(_ inherited: CustodyInheritedCommand, leases: CustodyAuthorityLeaseSet,
                 store: CustodyCatalogStore, prepared: CustodyJournal) throws {
        self.inherited = inherited; self.leases = leases; self.store = store; current = prepared
        helperObservation = try CustodyProcessObservation(inherited.identity)
    }
    static func begin(_ inherited: CustodyInheritedCommand) throws -> CustodyHelperJournal {
        try inherited.revalidateResources(); try inherited.revalidateParent()
        let leases = try CustodyAuthorityLeaseSet.importing(inherited), store = try CustodyCatalogStore(leases: leases)
        #if SHADOW_SYNC_TESTING
        if let mode = inherited.fixtureMode, ["state-capture-named", "state-capture-unlinked"].contains(mode) {
            let prepared = try CustodyStateCaptureFixtures.claimHelper(leases: leases, unlinking: mode == "state-capture-unlinked") {
                try store.claimHelper(inherited)
            }
            return try Self(inherited, leases: leases, store: store, prepared: prepared)
        }
        #endif
        return try Self(inherited, leases: leases, store: store, prepared: store.claimHelper(inherited))
    }
    private func replace(_ next: CustodyJournal) throws {
        // Parent liveness deliberately is not needed to drain/persist after EOF.
        #if SHADOW_SYNC_TESTING
        if next.phase == .terminal { testingTerminalStage = .persistenceResources }
        #endif
        try inherited.revalidatePersistenceResources(); try leases.validate()
        #if SHADOW_SYNC_TESTING
        if next.phase == .terminal { testingTerminalStage = .storeReplace }
        #endif
        try store.replaceJournal(current, with: next); current = next
    }
    func admit(deadline: UInt64, revalidateAdmission: @escaping () throws -> Void) throws {
        guard current.phase == .prepared else { throw CustodyRecordError.invalidTransition }
        try inherited.revalidatePersistenceResources(); try leases.validate()
        let next = try current.advancing(to: .admitted, custodian: helperObservation)
        try store.admitJournal(current, with: next, deadline: deadline) { [self] in
            try inherited.revalidateParent()
            try revalidateAdmission()
        }
        current = next
    }
    private func recordSerialRetirement(_ owner: OwnedDirectChild, streamsDrained: Bool) throws -> Int32 {
        guard [.repositoryGit, .retentionArchive, .discoveryGit, .launchctlMutation].contains(inherited.request.kind), current.phase == .executing,
              serialRetirement == nil, recordedOwner === owner,
              owner.graphRetirementPermitted, streamsDrained,
              case .reaped(let raw) = owner.observation, raw >= 0,
              current.target == (try CustodyProcessObservation(owner.identity)) else { throw CustodyRecordError.fenced }
        serialRetirement = SerialRetirement(owner: owner, waitStatus: raw)
        return raw
    }
    /// Only the first serial child is the fixed system-configuration probe.
    /// Decode its actual retired status and bounded complete output here; a
    /// caller-supplied preflight value cannot authorize nonzero retirement.
    func retireSystemConfigurationChild(_ owner: OwnedDirectChild, stdout: Data,
                                         stderr: Data, streamsDrained: Bool) throws -> GitConfigurationPreflight {
        guard current.ordinal == 2, case .reaped(let raw) = owner.observation else { throw CustodyRecordError.fenced }
        let preflight = try GitConfigurationPreflight.completedSystemOutput(waitStatus: raw,
            stdout: stdout, stderr: stderr, account: inherited.account)
        guard try recordSerialRetirement(owner, streamsDrained: streamsDrained) == raw else { throw CustodyRecordError.fenced }
        return preflight
    }
    func retireLifecyclePreflightChild(_ owner: OwnedDirectChild, stdout: Data,
                                      stderr: Data, streamsDrained: Bool) throws -> LaunchAgentState {
        guard current.ordinal == 2, inherited.request.kind == .launchctlMutation,
              let command = inherited.lifecycleCommand, case .reaped(let raw) = owner.observation else { throw CustodyRecordError.fenced }
        let state = try command.state(waitStatus: raw, stdout: stdout, stderr: stderr)
        try command.validatePreflight(state)
        guard try recordSerialRetirement(owner, streamsDrained: streamsDrained) == raw else { throw CustodyRecordError.fenced }
        return state
    }
    func retireSerialChild(_ owner: OwnedDirectChild, streamsDrained: Bool) throws {
        guard current.ordinal > 2, case .reaped(0) = owner.observation else { throw CustodyRecordError.fenced }
        _ = try recordSerialRetirement(owner, streamsDrained: streamsDrained)
    }
    func retireRepositoryProbe(_ owner: OwnedDirectChild, index: Int, stdout: Data,
                               stderr: Data, streamsDrained: Bool) throws {
        guard let repository = inherited.repository, current.ordinal > 2,
              case .reaped(let raw) = owner.observation, streamsDrained else { throw CustodyRecordError.fenced }
        try repository.validateProbe(index, waitStatus: raw, stdout: stdout, stderr: stderr)
        guard try recordSerialRetirement(owner, streamsDrained: streamsDrained) == raw else { throw CustodyRecordError.fenced }
    }
    private func validateExecutionOwner(_ owner: OwnedDirectChild) throws {
        guard owner.observation == .running, owner.identity.userID == inherited.account.uid else {
            throw CustodyRecordError.invalidTransition
        }
        if current.phase == .executing {
            guard let retirement = serialRetirement, retirement.owner === recordedOwner,
                  retirement.owner !== owner, retirement.owner.graphRetirementPermitted,
                  case .reaped(let raw) = retirement.owner.observation, raw == retirement.waitStatus,
                  current.target == (try CustodyProcessObservation(retirement.owner.identity)) else { throw CustodyRecordError.fenced }
        } else {
            guard current.phase == .admitted, recordedOwner == nil else { throw CustodyRecordError.invalidTransition }
        }
    }
    func executing(_ owner: OwnedDirectChild, deadline: UInt64,
                   revalidateExecution: @escaping () throws -> Void) throws {
        try validateExecutionOwner(owner)
        let next = try current.advancing(to: .executing, custodian: helperObservation,
            target: CustodyProcessObservation(owner.identity))
        try store.executeJournal(current, with: next, deadline: deadline) { [self] in
            // No catalog guard spans retained authority, parent, control or
            // suspended-owner validation. Never call full resource validation
            // here: installation validation can itself acquire catalog.lock.
            try inherited.revalidatePersistenceResources(); try leases.validate()
            try inherited.revalidateParent(); try validateExecutionOwner(owner)
            try revalidateExecution()
        }
        current = next; recordedOwner = owner; serialRetirement = nil
    }
    /// Retain before the first fallible write or filesystem operation. A failed
    /// create leaves the original object here for explicit drained cleanup.
    func prepareDiscoveryResource(_ captured: CapturedGitConfiguration,
                                  admission: @escaping () throws -> Void) throws -> DiscoveryFrozenResource {
        guard inherited.request.kind == .discoveryGit, current.phase == .executing,
              current.ordinal > 2, discoveryResource == nil,
              let retirement = serialRetirement, retirement.owner === recordedOwner,
              retirement.owner.graphRetirementPermitted,
              case .reaped(let raw) = retirement.owner.observation, raw == 0, raw == retirement.waitStatus,
              current.target == (try CustodyProcessObservation(retirement.owner.identity)),
              DispatchTime.now().uptimeNanoseconds < current.budget.work else { throw CustodyRecordError.fenced }
        try inherited.revalidateResources(); try inherited.revalidateParent(); try admission()
        let resource = try DiscoveryFrozenResource(helper: self, captured: captured, admission: admission)
        discoveryResource = resource
        try resource.create()
        return resource
    }
    func persistDiscoveryResource(expected: DiscoveryResourceReceipt?, next: DiscoveryResourceReceipt) throws {
        try leases.validate()
        // A failed metadata write poisons that store instance. A fresh reader
        // may retry only the exact expected/next transition under the same lease.
        try CustodyCatalogStore(leases: leases).persistDiscoveryResource(journal: current, expected: expected, next: next)
    }
    func readDiscoveryResource() throws -> DiscoveryResourceReceipt {
        try leases.validate()
        return try CustodyCatalogStore(leases: leases).readDiscoveryResource(journal: current)
    }
    func retireDiscoveryResource(owner: OwnedDirectChild?, unexecuted: OwnedSpawnAnchor.UnexecutedProof?,
                                 noSuccessfulSpawn: Bool, reason: CustodyReason, streamsDrained: Bool) throws {
        guard current.kind == .discoveryGit else { return }
        guard streamsDrained else { throw CustodyRecordError.fenced }
        _ = try verifiedRetirement(owner: owner, unexecuted: unexecuted,
                                   noSuccessfulSpawn: noSuccessfulSpawn, reason: reason)
        if let discoveryResource {
            try discoveryResource.retire()
            guard discoveryResource.isRetired, try readDiscoveryResource() == discoveryResource.receipt else {
                throw CustodyRecordError.fenced
            }
        } else {
            let planned = try readDiscoveryResource()
            if planned.phase == .retired, planned.ordinal == 1 { return }
            guard planned.phase == .planned else { throw CustodyRecordError.fenced }
            try persistDiscoveryResource(expected: planned, next: planned.advancing(to: .retired))
        }
    }
    func draining(reason: CustodyReason) throws {
        guard !current.phase.isTerminal else { throw CustodyRecordError.invalidTransition }
        if current.phase == .draining || current.phase == .cleanupPending { return }
        try replace(current.advancing(to: .draining, custodian: helperObservation))
    }
    func pending(reason: CustodyReason) throws {
        if current.phase == .cleanupPending { return }
        try draining(reason: reason)
        try replace(current.advancing(to: .cleanupPending, custodian: helperObservation))
    }
    private func verifiedRetirement(owner: OwnedDirectChild?, unexecuted: OwnedSpawnAnchor.UnexecutedProof?,
                                    noSuccessfulSpawn: Bool, reason: CustodyReason) throws -> (OwnedDirectChild?, UInt32?) {
        let status: UInt32?
        // A failure while preparing/spawning the next stage must still prove
        // that new child drained. It cannot discard the preceding durable
        // target merely because no replacement journal was committed.
        var terminalOwner = owner
        if let retirement = serialRetirement, retirement.owner === recordedOwner,
           owner !== retirement.owner, reason != .none {
            let retired = retirement.owner
            guard retired.graphRetirementPermitted, case .reaped(let raw) = retired.observation,
                  raw == retirement.waitStatus,
                  current.target == (try CustodyProcessObservation(retired.identity)) else { throw CustodyRecordError.fenced }
            if let owner {
                guard owner.graphRetirementPermitted, owner.neverResumedReapedStatus != nil else { throw CustodyRecordError.fenced }
            } else {
                guard noSuccessfulSpawn || unexecuted != nil else { throw CustodyRecordError.fenced }
            }
            terminalOwner = retired
        }
        if let owner = terminalOwner {
            guard owner.graphRetirementPermitted, case .reaped(let raw) = owner.observation,
                  current.target == (try CustodyProcessObservation(owner.identity)), raw >= 0 else { throw CustodyRecordError.fenced }
            status = UInt32(raw)
        } else {
            guard current.target == nil, noSuccessfulSpawn || unexecuted != nil else { throw CustodyRecordError.fenced }
            status = nil
        }
        return (terminalOwner, status)
    }
    func terminal(owner: OwnedDirectChild?, unexecuted: OwnedSpawnAnchor.UnexecutedProof?,
                  noSuccessfulSpawn: Bool, reason: CustodyReason, admitted: Bool) throws -> CustodyJournal {
        #if SHADOW_SYNC_TESTING
        testingTerminalStage = .retirement
        #endif
        let (terminalOwner, status) = try verifiedRetirement(owner: owner, unexecuted: unexecuted,
            noSuccessfulSpawn: noSuccessfulSpawn, reason: reason)
        #if SHADOW_SYNC_TESTING
        testingTerminalStage = .discoveryResource
        #endif
        if current.kind == .discoveryGit {
            let resource = try readDiscoveryResource()
            guard resource.phase == .retired else { throw CustodyRecordError.fenced }
            if let discoveryResource {
                guard discoveryResource.isRetired, resource == discoveryResource.receipt else { throw CustodyRecordError.fenced }
            } else {
                guard resource.ordinal == 1 else { throw CustodyRecordError.fenced }
            }
        }
        let outcome: CustodyOutcome
        if !admitted { outcome = .admissionRefused }
        else if reason == .cancelled { outcome = .cancelledDrained }
        else if reason == .timeout { outcome = .timedOutDrained }
        else if let owner = terminalOwner, owner.neverResumedReapedStatus == nil {
            outcome = reason == .none && status == 0 ? .completed : .commandFailed
        } else { outcome = .admissionRefused }
        #if SHADOW_SYNC_TESTING
        testingTerminalStage = .recordConstruction
        #endif
        try replace(current.advancing(to: .terminal, custodian: helperObservation,
            outcome: outcome, reason: reason, waitStatus: status))
        #if SHADOW_SYNC_TESTING
        testingTerminalStage = .completed
        #endif
        return current
    }
}

extension InstallationTransactionOwner {
    /// The consumed original owner is the sole factory. No decoded transaction,
    /// caller UUID, slot map or arbitrary control proposal is accepted here.
    func installationJournal(intent: InstallationTransactionIntent,
                             lifecycle: InstallationLifecycle) throws -> CustodyCatalogStore.InstallationJournalSession {
        try claimInstallationJournal()
        return try CustodyCatalogStore.InstallationJournalSession(owner: self, intent: intent, lifecycle: lifecycle)
    }
}

extension CustodyCatalogStore {
    /// One retained live owner/session, not restart or historical recovery.
    /// Command permits remain limited to reserve and exact drain-prior intent.
    final class InstallationCommandPermit {
        let observation: InstallationCommandBinding
        private let session: InstallationJournalSession?
        private let staged: InstallationStagedCommandObservation?
        private let commandMutex = NSLock()
        private var mutationClaimed = false
        private var committedKindsClaimed = Set<CustodyCommandKind>()
        private var recoveryDiagnosticClaimed = false
        fileprivate init(staged: InstallationStagedCommandObservation) {
            self.staged = staged; session = nil; observation = staged.binding
        }
        fileprivate init(session: InstallationJournalSession, observation: InstallationCommandBinding) {
            self.session = session; self.observation = observation; staged = nil
        }
        fileprivate var stagedObservation: InstallationStagedCommandObservation? { staged }
        var generation: String { observation.control.transaction!.coordinator.process.generation }
        func revalidate() throws {
            if let staged { try staged.revalidate(deadline: .init(seconds: 0.750)) }
            else if let session { try session.validateCommandPermit(self) }
            else { throw CustodyRecordError.fenced }
        }
        func boundCommittedBudget(_ budget: CustodyBudget, kind: CustodyCommandKind) throws -> CustodyBudget {
            guard let deadline = staged?.session.committedStopDeadline(for: staged!) else { return budget }
            return try budget.clipped(to: deadline, kind: kind, permittedWorkSeconds: 10)
        }
        func boundDiagnosticBudget(_ budget: CustodyBudget) throws -> CustodyBudget {
            guard let ready = staged?.ready else { return budget }
            try ready.revalidate(for: staged!.session)
            return try budget.clipped(to: ready.deadline, kind: .launchctlRead, permittedWorkSeconds: 10)
        }
        func validateRequest(_ request: UnvalidatedCustodyRequest) throws {
            if observation.isCommittedStop {
                try observation.validateCommittedRequest(request)
                commandMutex.lock(); defer { commandMutex.unlock() }
                guard committedKindsClaimed.insert(request.kind).inserted else { throw CustodyRecordError.fenced }
                return
            }
            if let ready = staged?.ready {
                // prepare already revalidated the live session before taking its
                // scope mutex. This section performs only bounded value checks.
                guard !ready.deadline.hasExpired, request.kind == .launchctlRead, request.budget.receipt <= ready.deadline.absoluteUptimeNanoseconds else {
                    throw CustodyRecordError.fenced
                }
                commandMutex.lock(); defer { commandMutex.unlock() }
                guard !recoveryDiagnosticClaimed else { throw CustodyRecordError.fenced }
                recoveryDiagnosticClaimed = true
            }
            guard request.authority == (observation.stagedMode ?? .lifecycleMutation) else { throw CustodyRecordError.fenced }
            if observation.control.phase == .recovery && observation.control.step?.action != .candidateStop {
                commandMutex.lock(); defer { commandMutex.unlock() }
                guard request.kind == .launchctlRead, !recoveryDiagnosticClaimed else { throw CustodyRecordError.fenced }
                recoveryDiagnosticClaimed = true
            }
            if observation.stagedMode != nil {
                guard [.launchctlRead, .signatureCheck, .launchctlMutation].contains(request.kind) else { throw CustodyRecordError.fenced }
                if request.kind == .launchctlMutation {
                    guard let first = request.arguments.first, let operation = LifecycleLaunchCommand.Operation(rawValue: first) else { throw CustodyRecordError.fenced }
                    try observation.validateStagedOperation(mode: request.authority, operation: operation)
                    commandMutex.lock(); defer { commandMutex.unlock() }
                    guard !mutationClaimed else { throw CustodyRecordError.fenced }
                    mutationClaimed = true
                }
            } else { guard request.kind == .launchctlRead else { throw CustodyRecordError.fenced } }
        }
        func validateOwner(_ owner: InstallationTransactionOwner) throws {
            guard session?.owner === owner else { throw CustodyRecordError.fenced }; try revalidate()
        }
        func validatePublisher(_ caller: ProcessIdentity, helper: CustodyHelperExecutable) throws {
            try observation.validateParent(caller, helper: helper)
        }
        func sealedInput() throws -> Data { try revalidate(); return try observation.encode() }
    }
    /// Constructed only by the live journal after publishing its exact intent.
    /// A caller cannot supply an action, slots, path or postimage to mint one.
    final class InstallationExclusiveActionPermit {
        fileprivate let session: InstallationJournalSession
        fileprivate let capture: InstallationCapturedSlots
        let action: InstallationAction
        fileprivate let control: InstallationControlRecord
        fileprivate init(session: InstallationJournalSession, capture: InstallationCapturedSlots,
                         action: InstallationAction, control: InstallationControlRecord) {
            self.session = session; self.capture = capture; self.action = action; self.control = control
        }
        func revalidate(for capture: InstallationCapturedSlots) throws {
            guard self.capture === capture else { throw CustodyRecordError.fenced }
            try session.validateExclusivePermit(self)
        }
    }
    final class InstallationJournalSession {
        fileprivate let owner: InstallationTransactionOwner
        private let binding: InstallationLiveBinding
        private let capture: InstallationCapturedSlots
        private let store: CustodyCatalogStore
        private let transaction: InstallationTransaction
        private let mutex = NSLock()
        private var serializing = false
        private var metadataGeneration: UInt64 = 0
        private var anchor: File
        private var current: InstallationControlRecord
        private var chain: [InstallationStepReceipt] = []
        private struct Pending {
            let control: InstallationControlRecord
            let receipt: InstallationStepReceipt.CanonicalObservation
        }
        private var pending: Pending?
        private var commandsClaimed = false
        private var preparationClaimed = false
        private var stagedIntentClaimed = false
        private var exclusivePermit: InstallationExclusiveActionPermit?
        private var exclusiveDeadline: MonotonicDeadline?
        fileprivate func validateExclusivePermit(_ permit: InstallationExclusiveActionPermit) throws {
            // The private permit never escapes the serialized action call. No
            // callback, arbitrary closure or caller-provided writer is involved.
            guard exclusivePermit === permit, permit.control == current, pending == nil,
                  current.phase == .active, current.step?.action == permit.action,
                  current.step?.status == .intent, let deadline = exclusiveDeadline else { throw CustodyRecordError.fenced }
            try validateSource(deadline)
            try store.locked { try validateLocked(deadline) }
        }
        func commandPermit(for candidate: InstallationTransactionOwner, deadline: MonotonicDeadline) throws -> InstallationCommandPermit {
            try serialized(deadline: deadline) { deadline in
                guard owner === candidate, owner.commandAdmissionIsOpen, !commandsClaimed, pending == nil else { throw CustodyRecordError.fenced }
                return try store.locked {
                    try validateLocked(deadline)
                    var nodes = try retainedSteps.mapValues { try store.installationCommandNode($0.identity, acl: $0.acl) }
                    for (name, retained) in capture.retainedPreimages {
                        nodes[name] = try store.installationCommandNode(retained.identity, acl: retained.acl)
                    }
                    let observation = try InstallationCommandBinding(control: current,
                        controlNode: store.installationCommandNode(anchor.identity, acl: anchor.acl), receiptNodes: nodes,
                        validationProfile: store.validationProfile)
                    try observation.validate(); try store.validateInstallationCommand(observation)
                    commandsClaimed = true
                    return InstallationCommandPermit(session: self, observation: observation)
                }
            }
        }
        fileprivate func validateCommandPermit(_ permit: InstallationCommandPermit) throws {
            try withTurn {
                guard commandsClaimed, owner.commandAdmissionIsOpen, pending == nil,
                      current == permit.observation.control else { throw CustodyRecordError.fenced }
                try binding.revalidate(for: owner); try capture.validateSource()
                try store.locked { try store.validateInstallationCommand(permit.observation) }
            }
        }
        // Pin exact receipt descriptions across a cut. Identical replacement
        // bytes/inode metadata cannot substitute for this live durability proof.
        private var retainedSteps: [String: Node] = [:]
        #if SHADOW_SYNC_TESTING
        enum Cut { case afterReceipt, beforeControl }
        private var cut: Cut?
        private var receiptFault: CustodyCatalogStore.Fault?
        private var controlFault: CustodyCatalogStore.Fault?
        private func takeReceiptFault() -> CustodyCatalogStore.Fault? {
            mutex.lock(); defer { mutex.unlock() }; let value = receiptFault; receiptFault = nil; return value
        }
        private func takeControlFault() -> CustodyCatalogStore.Fault? {
            mutex.lock(); defer { mutex.unlock() }; let value = controlFault; controlFault = nil; return value
        }
        private func consumeCut(_ value: Cut) -> Bool {
            mutex.lock(); defer { mutex.unlock() }; guard cut == value else { return false }; cut = nil; return true
        }
        func testingCut(_ value: Cut?) { mutex.lock(); cut = value; mutex.unlock() }
        func testingWriteFault(receipt: CustodyCatalogStore.Fault? = nil, control: CustodyCatalogStore.Fault? = nil) {
            mutex.lock(); receiptFault = receipt; controlFault = control; mutex.unlock()
        }
        #endif

        fileprivate init(owner: InstallationTransactionOwner, intent: InstallationTransactionIntent,
                         lifecycle: InstallationLifecycle) throws {
            self.owner = owner
            let binding = try owner.installationBinding()
            let capture = try lifecycle.captureInstallationSlots(owner: owner, binding: binding, transactionID: RunIdentity.make())
            let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases(), validationProfile: owner.validationProfile)
            let observed = try store.locked {
                let value = try store.installationSnapshot(pendingPreimages: Self.documents(capture))
                guard value.1.phase == .initial, value.1.state == binding.state,
                      try store.snapshot().1.entries.isEmpty else { throw CustodyRecordError.fenced }
                try store.validateRetainedInstallationPreimages(capture)
                return value
            }
            self.binding = binding; self.capture = capture; self.store = store
            anchor = observed.0; current = observed.1
            transaction = InstallationTransaction(id: capture.transactionID, boot: binding.boot, intent: intent,
                coordinator: binding.coordinator, sourceReleaseDigest: binding.sourceReleaseDigest,
                candidate: intent == .remove ? nil : binding.candidate, priorCommitDigest: nil, slots: try capture.snapshot)
            try transaction.validate(state: binding.state, profile: owner.validationProfile)
            try capture.validateSource()
        }
        private static func documents(_ capture: InstallationCapturedSlots) -> [String: InstallationDocumentPreimage] {
            Dictionary(uniqueKeysWithValues: capture.canonicalPreimages.map { ($0.digest, $0.receipt) })
        }
        private func withTurn<T>(_ action: () throws -> T) throws -> T {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, metadataGeneration < UInt64.max else { mutex.unlock(); throw CustodyRecordError.busy }
            serializing = true; metadataGeneration += 1
            let generation = metadataGeneration; mutex.unlock()
            defer { mutex.lock(); serializing = false; mutex.unlock() }
            let result = try action()
            mutex.lock(); let unchanged = serializing && metadataGeneration == generation; mutex.unlock()
            guard unchanged else { throw CustodyRecordError.fenced }
            return result
        }
        private func serialized<T>(deadline: MonotonicDeadline, _ action: (MonotonicDeadline) throws -> T) throws -> T {
            try withTurn {
                try validateSource(deadline)
                let result = try action(deadline)
                try validateSource(deadline)
                return result
            }
        }
        private func validateSource(_ deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try binding.revalidate(for: owner); try capture.validateSource()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
        private func validateLocked(_ deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired, try store.leases.mode == .lifecycleMutation else { throw CustodyRecordError.busy }
            let value = try store.installationSnapshot(pendingPreimages: Self.documents(capture),
                pendingStep: pending?.receipt, pendingControl: pending?.control)
            guard value.0.identity == anchor.identity, value.0.acl == anchor.acl,
                  value.0.bytes == anchor.bytes, value.1 == current,
                  try store.snapshot().1.entries.isEmpty else { throw CustodyRecordError.conflict }
            try store.validateRetainedInstallationPreimages(capture)
            for (name, node) in retainedSteps {
                try store.validate(node, at: store.receipts.descriptor.value, name: name, isDirectory: false)
            }
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try store.validateBindings()
        }
        private func proposal(status: InstallationStepStatus, action: InstallationAction = .reserve,
                              postimage: InstallationSlotSnapshot? = nil) throws -> Pending {
            let prior = current.transaction?.slots ?? transaction.slots
            let preimage = status == .complete ? (chain.last?.preimage ?? prior) : prior
            let ordinal: UInt64 = action == .reserve ? 1 : status == .complete ? current.step!.ordinal : current.step!.ordinal + 1
            let after = status == .complete ? (postimage ?? prior) : nil
            let nextTransaction = InstallationTransaction(id: transaction.id, boot: transaction.boot, intent: transaction.intent,
                coordinator: transaction.coordinator, sourceReleaseDigest: transaction.sourceReleaseDigest,
                candidate: transaction.candidate, priorCommitDigest: transaction.priorCommitDigest, slots: after ?? prior)
            let receipt = InstallationStepReceipt(transactionID: transaction.id, ordinal: ordinal,
                previousReceiptDigest: current.latestReceiptDigest, action: action, status: status,
                preimage: preimage, postimage: after,
                bindingDigest: try transaction.bindingDigest(state: binding.state))
            let canonical = try InstallationStepReceipt.CanonicalObservation(validating: receipt, uid: binding.state.directory.uid)
            guard current.revision < UInt64.max else { throw InstallationRecordError.limit }
            let next = InstallationControlRecord(revision: current.revision + 1, phase: current.phase == .initial ? .active : current.phase,
                state: binding.state, transaction: nextTransaction, step: try receipt.step(), latestReceiptDigest: canonical.digest,
                readinessCommit: nil, recoveryReason: current.recoveryReason)
            try current.validateReplacement(next, receipts: chain + [receipt], profile: owner.validationProfile)
            return Pending(control: next, receipt: canonical)
        }
        func begin(deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try serialized(deadline: deadline) { deadline in
                guard pending == nil, current.phase == .initial else { throw CustodyRecordError.fenced }
                return try publish(proposal(status: .intent), deadline: deadline)
            }
        }
        func completeReservation(deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try serialized(deadline: deadline) { deadline in
                guard pending == nil, current.phase == .active, current.step?.action == .reserve,
                      current.step?.ordinal == 1, current.step?.status == .intent else { throw CustodyRecordError.fenced }
                // validateSource recaptures every fixed slot/document. Reserve
                // has no action, so its only legal completion is exact equality.
                return try publish(proposal(status: .complete), deadline: deadline)
            }
        }
        /// One fixed attempt through exclusive preparation. Failure preserves
        /// the latest durable intent and any real partial effect; it is never
        /// replayed or silently turned into completion by a fresh observation.
        func prepareExclusive(deadline: MonotonicDeadline, forwardAdmission: CoordinatorInstallationAdmission) throws -> InstallationControlRecord {
            try prepareExclusiveImpl(deadline: deadline, forwardAdmission: .production(forwardAdmission))
        }
        #if SHADOW_SYNC_TESTING
        func prepareExclusive(deadline: MonotonicDeadline, cancellation: InstallationCancellationGate = InstallationCancellationGate()) throws -> InstallationControlRecord {
            try prepareExclusiveImpl(deadline: deadline, forwardAdmission: .fixture(cancellation))
        }
        #endif
        private enum PreparationAdmission {
            case production(CoordinatorInstallationAdmission)
            #if SHADOW_SYNC_TESTING
            case fixture(InstallationCancellationGate)
            #endif
            func revalidateForward() throws {
                switch self {
                case let .production(admission): try admission.revalidateForward()
                #if SHADOW_SYNC_TESTING
                case let .fixture(gate): try gate.check()
                #endif
                }
            }
            var cancellation: InstallationCancellationGate {
                switch self {
                case let .production(admission): return admission.cancellation
                #if SHADOW_SYNC_TESTING
                case let .fixture(gate): return gate
                #endif
                }
            }
            func checkCancellation() throws {
                switch self {
                case let .production(admission): try admission.cancellation.check()
                #if SHADOW_SYNC_TESTING
                case let .fixture(gate): try gate.check()
                #endif
                }
            }
        }
        private func prepareExclusiveImpl(deadline: MonotonicDeadline,
            forwardAdmission: PreparationAdmission) throws -> InstallationControlRecord {
            try forwardAdmission.revalidateForward()
            _ = try serialized(deadline: deadline) { deadline in
                guard !preparationClaimed, !commandsClaimed, pending == nil,
                      current.phase == .active, current.step?.action == .reserve,
                      current.step?.status == .complete,
                      transaction.intent == .install || transaction.intent == .repair else { throw CustodyRecordError.fenced }
                try capture.requireExclusiveEmptyInstall()
                try forwardAdmission.checkCancellation()
                preparationClaimed = true
                return try publish(proposal(status: .intent, action: .drainPrior), deadline: deadline)
            }
            // No journal mutex/catalog guard spans command execution/retirement.
            try forwardAdmission.revalidateForward()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try capture.observeExclusiveServiceAbsence(journal: self, deadline: deadline, cancellation: forwardAdmission.cancellation)
            _ = try serialized(deadline: deadline) { deadline in
                guard commandsClaimed, pending == nil, current.step?.action == .drainPrior,
                      current.step?.status == .intent else { throw CustodyRecordError.fenced }
                return try publish(proposal(status: .complete, action: .drainPrior), deadline: deadline)
            }
            for action: InstallationAction in [.stageApplication, .stagePlist, .retireApplication, .retirePlist,
                .retireCoordination, .translateState, .moveStateForward, .promoteApplication, .promotePlist] {
                try forwardAdmission.revalidateForward()
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                _ = try serialized(deadline: deadline) { deadline in
                    guard pending == nil, current.phase == .active, current.step?.status == .complete else { throw CustodyRecordError.fenced }
                    try forwardAdmission.checkCancellation()
                    _ = try publish(proposal(status: .intent, action: action), deadline: deadline)
                    try validateSource(deadline)
                    try store.locked { try validateLocked(deadline) }
                    let permit = InstallationExclusiveActionPermit(session: self, capture: capture, action: action, control: current)
                    exclusivePermit = permit; exclusiveDeadline = deadline
                    defer { exclusivePermit = nil; exclusiveDeadline = nil }
                    try forwardAdmission.checkCancellation()
                    let after = try capture.executeExclusive(permit)
                    try validateSource(deadline)
                    return try publish(proposal(status: .complete, action: action, postimage: after), deadline: deadline)
                }
                try forwardAdmission.revalidateForward()
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            }
            // Staged admission needs the separately authenticated transfer and
            // readiness protocol. The original exclusive owner remains retained.
            return current
        }

        /// Mint only after this live session completed the real fixed actions.
        /// Releasing this journal removes its borrowed admission descriptions;
        /// the returned proof cannot borrow, execute or publish completion.
        func stagedAdmissionIntent(deadline: MonotonicDeadline) throws -> InstallationStagedAdmissionIntent {
            try serialized(deadline: deadline) { deadline in
                guard preparationClaimed, !stagedIntentClaimed, pending == nil,
                      current.phase == .active, current.step?.action == .promotePlist,
                      current.step?.status == .complete, current.step?.ordinal == 11 else { throw CustodyRecordError.fenced }
                stagedIntentClaimed = true
                _ = try publish(proposal(status: .intent, action: .openStagedAdmission), deadline: deadline)
                let slots = try capture.preparedSlotObservation()
                let intent = try store.locked {
                    try validateLocked(deadline)
                    return try InstallationStagedAdmissionIntent(owner: owner, slots: slots, store: store, expected: current)
                }
                try intent.revalidate(for: owner, deadline: deadline)
                return intent
            }
        }

        private func publish(_ proposed: Pending, deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try store.locked {
                try validateLocked(deadline)
                pending = proposed
                #if SHADOW_SYNC_TESTING
                store.testingCut = takeReceiptFault()
                #endif
                let receipt = proposed.receipt
                try store.write(receipt.filename, at: store.receipts.descriptor.value,
                                bytes: receipt.receipt.encode(uid: receipt.uid), expected: nil)
                let node = try Self.retainReceipt(store, receipt)
                retainedSteps[receipt.filename] = node
                // Re-read the complete old-prefix + one exact successor and all
                // documents before leaving this guard interval.
                try validateLocked(deadline)
                #if SHADOW_SYNC_TESTING
                if consumeCut(.afterReceipt) { throw CustodyRecordError.injectedFailure }
                #endif
            }
            try validateSource(deadline)
            return try finishPending(deadline)
        }
        fileprivate static func retainReceipt(_ store: CustodyCatalogStore,
                                          _ receipt: InstallationStepReceipt.CanonicalObservation) throws -> Node {
            let node = try CustodyCatalogStore.openNode(store.receipts.descriptor.value, receipt.filename, uid: store.uid, directory: false)
            let file = try store.read(receipt.filename, at: store.receipts.descriptor.value, maximum: InstallationStepReceipt.maximumBytes)
            guard file.identity == node.identity, file.acl == node.acl,
                  file.bytes == (try receipt.receipt.encode(uid: receipt.uid)),
                  fsync(node.descriptor.value) == 0, fsync(store.receipts.descriptor.value) == 0 else {
                throw CustodyRecordError.fenced
            }
            try store.validate(node, at: store.receipts.descriptor.value, name: receipt.filename, isDirectory: false)
            return node
        }
        /// Exact receipt-before-control interruption only. No discovery/adoption
        /// of a next receipt and no reconstruction from a persisted transaction.
        func reconcileNextReceipt(deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try serialized(deadline: deadline) { deadline in
                guard let pending, retainedSteps[pending.receipt.filename] != nil else { throw CustodyRecordError.fenced }
                return try finishPending(deadline)
            }
        }
        private func finishPending(_ deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try store.locked {
                guard let pending, let held = retainedSteps[pending.receipt.filename] else { throw CustodyRecordError.fenced }
                try validateLocked(deadline)
                let file = try store.read(pending.receipt.filename, at: store.receipts.descriptor.value,
                                          maximum: InstallationStepReceipt.maximumBytes)
                guard file.identity == held.identity, file.acl == held.acl,
                      file.bytes == (try pending.receipt.receipt.encode(uid: pending.receipt.uid)),
                      fsync(held.descriptor.value) == 0, fsync(store.receipts.descriptor.value) == 0 else {
                    throw CustodyRecordError.fenced
                }
                try current.validateReplacement(pending.control, receipts: chain + [pending.receipt.receipt], profile: owner.validationProfile)
                #if SHADOW_SYNC_TESTING
                if consumeCut(.beforeControl) { throw CustodyRecordError.injectedFailure }
                store.testingCut = takeControlFault()
                #endif
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                try store.write(InstallationControlRecord.filename, bytes: pending.control.encode(profile: owner.validationProfile), expected: anchor)
                let after = try store.installationSnapshot()
                guard after.1 == pending.control else { throw CustodyRecordError.conflict }
                try store.validateRetainedInstallationPreimages(capture); try store.validateBindings()
                anchor = after.0; current = after.1; chain.append(pending.receipt.receipt); self.pending = nil
                return current
            }
        }
        func recordFailure(_ reason: InstallationRecoveryReason, deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try serialized(deadline: deadline) { deadline in
                guard pending == nil, current.phase == .active || current.phase == .recovery,
                      current.step?.action == .reserve, reason != .restoredStopped,
                      current.revision < UInt64.max else { throw CustodyRecordError.fenced }
                let next = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                    state: current.state, transaction: current.transaction, step: current.step,
                    latestReceiptDigest: current.latestReceiptDigest, readinessCommit: current.readinessCommit, recoveryReason: reason)
                try current.validateReplacement(next, receipts: chain, profile: owner.validationProfile)
                return try store.locked {
                    try validateLocked(deadline)
                    #if SHADOW_SYNC_TESTING
                    store.testingCut = takeControlFault()
                    #endif
                    try store.write(InstallationControlRecord.filename, bytes: next.encode(profile: owner.validationProfile), expected: anchor)
                    let after = try store.installationSnapshot()
                    guard after.1 == next else { throw CustodyRecordError.conflict }
                    try store.validateRetainedInstallationPreimages(capture); try store.validateBindings()
                    anchor = after.0; current = next
                    return next
                }
            }
        }
    }
}


extension CustodyCatalogStore {
    private func installationCommandNode(_ identity: FileIdentity, acl: String) throws -> InstallationNodeIdentity {
        let node = InstallationNodeIdentity(device: identity.device, inode: identity.inode, type: .regular,
            uid: identity.owner, mode: UInt32(identity.mode), links: UInt64(identity.linkCount),
            aclDigest: CustodyRecordBinding.digest(Data(acl.utf8)))
        try node.validate(); return node
    }
    private func validateInstallationCommand(_ binding: InstallationCommandBinding) throws {
        try binding.validate()
        guard try leases.mode == (binding.stagedMode ?? .lifecycleMutation) else { throw CustodyRecordError.fenced }
        let value = try installationSnapshot()
        let receiptNames = try InstallationStagedAdmissionIntent.names(receipts.descriptor.value).filter {
            $0.hasPrefix(InstallationStepReceipt.prefix) || $0.hasPrefix(InstallationDocumentPreimage.prefix)
        }
        guard Set(receiptNames) == Set(binding.receiptNodes.keys) else { throw CustodyRecordError.fenced }
        guard value.1 == binding.control,
              try installationCommandNode(value.0.identity, acl: value.0.acl) == binding.controlNode else { throw CustodyRecordError.fenced }
        try binding.control.state.validateLive(stateDescriptor: root.value, uid: uid, leases: leases)
        // Retain actual control/receipt descriptions too. Matching bytes and
        // recycled inode numbers cannot replace this live validation family.
        let expectedNodes = binding.receiptNodes.merging([InstallationControlRecord.filename: binding.controlNode]) { _, _ in binding.controlNode }
        if !installationCommandPins.isEmpty {
            guard Set(installationCommandPins.keys) == Set(expectedNodes.keys) else { throw CustodyRecordError.fenced }
        }
        for (name, expected) in expectedNodes {
            let parent = name == InstallationControlRecord.filename ? directory.descriptor.value : receipts.descriptor.value
            let node: Node
            if let retained = installationCommandPins[name] { node = retained }
            else { node = try Self.openNode(parent, name, uid: uid, directory: false) }
            try validate(node, at: parent, name: name, isDirectory: false)
            guard try installationCommandNode(node.identity, acl: node.acl) == expected else { throw CustodyRecordError.fenced }
            installationCommandPins[name] = node
        }
    }
    func checkInheritedInstallation(_ inherited: CustodyInheritedCommand) throws {
        guard let binding = inherited.installation else { return }
        try binding.validateParent(inherited.parent, helper: inherited.helper)
        try locked {
            try validateInstallationCommand(binding)
            let s = try snapshot()
            try fence(s.1, journals: s.2, ownRequests: [inherited.request.binding.requestID],
                      scope: inherited.request.binding.scopeID, mode: leases.mode)
        }
    }
}

extension CustodyCatalogStore {
    /// Live one-owner evidence, never decoded/adopted. Its descriptions are
    /// metadata/state pins only; it intentionally retains no store or journal.
    final class InstallationStagedAdmissionIntent {
        fileprivate let owner: InstallationTransactionOwner
        fileprivate let slots: InstallationPreparedSlotObservation
        fileprivate let root: OwnedFileDescriptor
        fileprivate let directory: Node
        fileprivate let receipts: Node
        fileprivate let guardFile: Node
        fileprivate let uid: uid_t
        fileprivate struct Evidence { let node: Node; let bytes: Data }
        fileprivate let control: Evidence
        fileprivate let catalog: Evidence
        fileprivate let receiptFiles: [String: Evidence]
        fileprivate let mutex = NSLock()
        private var continuationClaimed = false
        fileprivate var terminalPinsClosing = false
        func continueJournal(admission: InstallationStagedAdmission, deadline: MonotonicDeadline) throws -> InstallationStagedJournal {
            try admission.validateOwner(owner, intent: self)
            do { try revalidate(for: owner, deadline: deadline) }
            catch { _ = try? admission.closeStarts(); throw error }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !continuationClaimed, !terminalPinsClosing else { mutex.unlock(); throw CustodyRecordError.fenced }
            continuationClaimed = true
            mutex.unlock()
            // Claim is one-way; construction verifies publisher outside mutex.
            do { return try InstallationStagedJournal(intent: self, admission: admission, deadline: deadline) }
            catch { _ = try? admission.closeStarts(); throw error }
        }
        fileprivate init(owner: InstallationTransactionOwner, slots: InstallationPreparedSlotObservation,
                         store: CustodyCatalogStore, expected: InstallationControlRecord) throws {
            self.owner = owner; self.slots = slots; root = store.root; directory = store.directory
            receipts = store.receipts; uid = store.uid
            // A NEW open description for this metadata guard. Never duplicate or
            // unlock another owner's held metadata guard description.
            guardFile = try CustodyCatalogStore.openNode(directory.descriptor.value, "catalog.lock", uid: uid, directory: false)
            func pin(_ name: String, parent: Int32, maximum: Int) throws -> Evidence {
                let node = try CustodyCatalogStore.openNode(parent, name, uid: store.uid, directory: false)
                let file = try store.read(name, at: parent, maximum: maximum)
                guard node.identity == file.identity, node.acl == file.acl, fsync(node.descriptor.value) == 0 else { throw CustodyRecordError.fenced }
                return Evidence(node: node, bytes: file.bytes)
            }
            control = try pin(InstallationControlRecord.filename, parent: directory.descriptor.value, maximum: InstallationControlRecord.maximumBytes)
            guard control.bytes == (try expected.encode(profile: owner.validationProfile)), expected.phase == .active,
                  expected.step?.action == .openStagedAdmission, expected.step?.status == .intent,
                  expected.step?.ordinal == 12, expected.readinessCommit == nil else { throw CustodyRecordError.fenced }
            catalog = try pin("catalog.json", parent: directory.descriptor.value, maximum: CustodyCatalog.maximumBytes)
            guard try CustodyCatalog.decode(catalog.bytes).entries.isEmpty else { throw CustodyRecordError.fenced }
            var files: [String: Evidence] = [:]
            for name in try Self.names(receipts.descriptor.value) {
                files[name] = try pin(name, parent: receipts.descriptor.value, maximum: InstallationDocumentPreimage.maximumBytes)
            }
            receiptFiles = files
            guard fsync(directory.descriptor.value) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.fenced }
        }
        fileprivate static func names(_ parent: Int32) throws -> Set<String> {
            let fd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0, let stream = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw CustodyRecordError.fenced }
            defer { closedir(stream) }
            var names = Set<String>(); let scan = MonotonicDeadline(seconds: 0.250)
            while true {
                guard !scan.hasExpired else { throw CustodyRecordError.busy }
                errno = 0
                guard let row = readdir(stream) else { guard errno == 0 else { throw CustodyRecordError.persistence(errno) }; return names }
                let name = withUnsafePointer(to: row.pointee.d_name) { p in
                    p.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard names.count < 1_280, names.insert(name).inserted else { throw CustodyRecordError.fenced }
            }
        }
        private func validate(_ node: Node, parent: Int32, name: String, isDirectory: Bool) throws {
            let current = try CustodyCatalogStore.node(node.descriptor, uid: uid, directory: isDirectory)
            var named = stat()
            guard current.identity.matchesStableNode(node.identity), current.acl == node.acl,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(named).matchesStableNode(node.identity), isDirectory || named.st_nlink == 1 else { throw CustodyRecordError.conflict }
        }
        private func validate(_ evidence: Evidence, parent: Int32, name: String) throws {
            try validate(evidence.node, parent: parent, name: name, isDirectory: false)
            var before = stat(); let fd = evidence.node.descriptor.value
            guard fstat(fd, &before) == 0, before.st_size == evidence.bytes.count else { throw CustodyRecordError.conflict }
            var bytes = Data(count: evidence.bytes.count)
            try bytes.withUnsafeMutableBytes { p in
                var offset = 0
                while offset < p.count {
                    let count = pread(fd, p.baseAddress!.advanced(by: offset), p.count - offset, off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CustodyRecordError.fenced }; offset += count
                }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  bytes == evidence.bytes else { throw CustodyRecordError.conflict }
            try validate(evidence.node, parent: parent, name: name, isDirectory: false)
        }
        func revalidate(for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
            guard self.owner === owner, !deadline.hasExpired else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !terminalPinsClosing else { mutex.unlock(); throw CustodyRecordError.fenced }
            let claimed = continuationClaimed; mutex.unlock()
            try owner.revalidate(); try slots.revalidate(for: owner, deadline: deadline)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
            defer { mutex.unlock() }
            guard continuationClaimed == claimed, !terminalPinsClosing else { throw CustodyRecordError.fenced }
            try validate(directory, parent: root.value, name: "custody", isDirectory: true)
            try validate(guardFile, parent: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
            guard flock(guardFile.descriptor.value, LOCK_EX | LOCK_NB) == 0 else { throw CustodyRecordError.busy }
            do {
                defer { _ = flock(guardFile.descriptor.value, LOCK_UN) }
                try validate(guardFile, parent: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
                try validate(receipts, parent: directory.descriptor.value, name: "receipts", isDirectory: true)
                guard try Self.names(directory.descriptor.value) == ["catalog.lock", "catalog.json", "receipts", InstallationControlRecord.filename],
                      try Self.names(receipts.descriptor.value) == Set(receiptFiles.keys) else { throw CustodyRecordError.conflict }
                try validate(control, parent: directory.descriptor.value, name: InstallationControlRecord.filename)
                try validate(catalog, parent: directory.descriptor.value, name: "catalog.json")
                for (name, evidence) in receiptFiles {
                    guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                    try validate(evidence, parent: receipts.descriptor.value, name: name)
                }
                try validate(directory, parent: root.value, name: "custody", isDirectory: true)
            }
            }
            try slots.revalidate(for: owner, deadline: deadline); try owner.revalidate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
    }
}


extension CustodyCatalogStore {
    /// Live journal observation. Only the matching typed admission may borrow
    /// one command scope; wire decoding cannot construct this capability. It
    /// cannot publish command completion, retirement or readiness.
    final class InstallationStagedCommandObservation: @unchecked Sendable {
        let binding: InstallationCommandBinding
        fileprivate let session: InstallationStagedJournal
        fileprivate let ready: InstallationPrecommitSession.ReadyObservation?
        let operationDeadline: MonotonicDeadline
        fileprivate init(session: InstallationStagedJournal, binding: InstallationCommandBinding,
                         operationDeadline: MonotonicDeadline,
                         ready: InstallationPrecommitSession.ReadyObservation? = nil) {
            self.session = session; self.binding = binding; self.ready = ready
            self.operationDeadline = operationDeadline
        }
        func commandPermit(admission: InstallationStagedAdmission, deadline: MonotonicDeadline) throws -> InstallationCommandPermit {
            try session.commandPermit(self, admission: admission, stop: nil, deadline: deadline)
        }
        func commandPermit(admission: InstallationStagedStopAdmission, deadline: MonotonicDeadline) throws -> InstallationCommandPermit {
            try session.commandPermit(self, admission: nil, stop: admission, deadline: deadline)
        }
        func commandHelper() throws -> CustodyHelperExecutable { try session.commandHelper() }
        func revalidate(deadline: MonotonicDeadline) throws { try session.validate(self, deadline: deadline) }
        func sealedInput(deadline: MonotonicDeadline) throws -> Data {
            try revalidate(deadline: deadline); return try binding.encode()
        }
    }

    /// One live recovery observation, bound to the original closed-start owner.
    /// This capability only prepares a fixed diagnostic. It has no forward,
    /// readiness, restoration or command-success methods.
    final class InstallationStagedRecovery {
        fileprivate let observation: InstallationStagedCommandObservation
        private let stop: InstallationStagedStopAdmission
        fileprivate init(observation: InstallationStagedCommandObservation, stop: InstallationStagedStopAdmission) {
            self.observation = observation; self.stop = stop
        }
        func commandPermit(deadline: MonotonicDeadline) throws -> InstallationCommandPermit {
            try observation.session.recoveryDiagnosticPermit(self, deadline: deadline)
        }
        func retainLeases() throws -> CustodyAuthorityLeaseSet { try stop.retainStopLeases() }
        func commandHelper() throws -> CustodyHelperExecutable { try observation.commandHelper() }
    }

    /// One retained committed recovery, subordinate to its unchanged installation
    /// step. Only this journal factory supplies the original owner and stop family.
    final class InstallationCommittedStop {
        fileprivate let observation: InstallationStagedCommandObservation
        fileprivate let stop: InstallationStagedStopAdmission
        let deadline: MonotonicDeadline
        fileprivate init(observation: InstallationStagedCommandObservation,
                         stop: InstallationStagedStopAdmission, deadline: MonotonicDeadline) {
            self.observation = observation; self.stop = stop; self.deadline = deadline
        }
        func commandPermit() throws -> InstallationCommandPermit {
            try observation.session.committedStopPermit(self)
        }
        func retainLeases() throws -> CustodyAuthorityLeaseSet {
            try observation.revalidate(deadline: deadline); return try stop.retainStopLeases()
        }
        func commandHelper() throws -> CustodyHelperExecutable { try observation.commandHelper() }
    }
    /// Actual bootout plus final fixed absence and registry retirement. This is
    /// neither authenticated host drainage nor stopped-exclusive authority.
    final class InstallationCommittedStopCompletion {
        fileprivate let capability: InstallationCommittedStop
        fileprivate let retirement: RetainedCleanupRegistry.StagedCommandCompletion
        fileprivate init(_ capability: InstallationCommittedStop,
                         _ retirement: RetainedCleanupRegistry.StagedCommandCompletion) {
            self.capability = capability; self.retirement = retirement
        }
    }

    /// Continuation of the original detached intent. Only metadata descriptions
    /// are retained between calls; a temporary store borrows the SAME live staged
    /// owner's leases for each bounded write. No old exclusive aliases survive.
    final class InstallationStagedJournal: @unchecked Sendable {
        private let owner: InstallationTransactionOwner
        fileprivate var retirementOwner: InstallationTransactionOwner { owner }
        private let admission: InstallationStagedAdmission
        private let intent: InstallationStagedAdmissionIntent
        private let slots: InstallationPreparedSlotObservation
        private let directory: Node
        private let receipts: Node
        private let guardFile: Node
        private var controlPin: Node
        private var catalogPin: InstallationStagedAdmissionIntent.Evidence
        private var receiptPins: [String: InstallationStagedAdmissionIntent.Evidence]
        private var anchor: File
        private var current: InstallationControlRecord
        private var chain: [InstallationStepReceipt]
        private var stop: InstallationStagedStopAdmission?
        private var commandsClaimed = false
        private var committedStopAttempted = false
        private var committedStopFailed = false
        private var committedStop: InstallationCommittedStop?
        private var committedStopRetired = false
        private var committedStopCompletion: InstallationCommittedStopCompletion?
        private weak var recovery: InstallationStagedRecovery?
        private var recoveryDiagnosticClaimed = false
        private var candidateReady: InstallationPrecommitSession.ReadyObservation?
        private var commitDeliveryReserved = false
        /// Observations of this journal's own writes, never recovery authority.
        /// A proposed commit is deliberately separate from verified fsync. A
        /// poisoned atomic-write cut retains the proposal without adopting it.
        struct CommitOutcome {
            var proposed: InstallationControlRecord?
            var durable: InstallationControlRecord?
            var recovery: InstallationControlRecord?
            var recoveryProposed: InstallationControlRecord?
            var recoveryAttempted = false
        }
        private let commitOutcomeMutex = NSLock()
        private var commitOutcome = CommitOutcome()
        private var postcommitFenceAttempted = false
        func readinessCommitOutcome() -> CommitOutcome {
            commitOutcomeMutex.lock(); defer { commitOutcomeMutex.unlock() }; return commitOutcome
        }
        private func retainCommitOutcome(_ update: (inout CommitOutcome) -> Void) {
            commitOutcomeMutex.lock(); defer { commitOutcomeMutex.unlock() }; update(&commitOutcome)
        }


        /// Only this journal mints a delivery after its own fsynced commit is
        /// read back. The object is not constructible from a decoded record.
        final class CommitDelivery {
            private let journal: InstallationStagedJournal
            private let ready: InstallationPrecommitSession.ReadyObservation
            let control: InstallationControlRecord
            fileprivate init(journal: InstallationStagedJournal,
                ready: InstallationPrecommitSession.ReadyObservation, control: InstallationControlRecord) {
                self.journal = journal; self.ready = ready; self.control = control
            }
            func matches(journal: InstallationStagedJournal,
                         ready: InstallationPrecommitSession.ReadyObservation) -> Bool {
                self.journal === journal && self.ready === ready
            }
            func revalidate() throws { try journal.validateCommitDelivery(self, ready: ready) }
            fileprivate func deliver() throws -> InstallationPrecommitSession.CommitDelivered {
                try ready.deliver(self)
            }
        }
        /// One original journal, one durable cleanup intent and one endpoint.
        /// No decoded record or successful close can construct this authority.
        final class CleanupPermit {
            fileprivate let journal: InstallationStagedJournal
            fileprivate let endpoint: InstallationReadinessEndpoint
            fileprivate let owner: InstallationTransactionOwner
            fileprivate let session: InstallationPrecommitSession
            fileprivate let started: InstallationPrecommitSession.NormalStarted
            fileprivate let control: InstallationControlRecord
            fileprivate let generation: UInt64
            let deadline: MonotonicDeadline
            fileprivate init(journal: InstallationStagedJournal, endpoint: InstallationReadinessEndpoint,
                session: InstallationPrecommitSession, started: InstallationPrecommitSession.NormalStarted) {
                self.journal = journal; self.endpoint = endpoint; owner = journal.owner
                self.session = session; self.started = started; control = journal.current
                generation = journal.metadataGeneration; deadline = started.deadline
            }
            func matches(session: InstallationPrecommitSession,
                         started: InstallationPrecommitSession.NormalStarted) -> Bool {
                self.session === session && self.started === started
            }
            func validateNamedImage(_ image: InstallationSlotImage,
                                    endpoint: InstallationReadinessEndpoint, owner: InstallationTransactionOwner) throws {
                try validate(endpoint: endpoint, owner: owner)
                guard image.node?.type == .socket,
                      control.transaction?.slots.images[.installationSocket] == image else {
                    throw CustodyRecordError.fenced
                }
            }
            func validate(endpoint: InstallationReadinessEndpoint, owner: InstallationTransactionOwner,
                          completion: Bool = false) throws {
                guard self.endpoint === endpoint, self.owner === owner else { throw CustodyRecordError.fenced }
                try journal.validateCleanupPermit(self, completion: completion)
            }
        }
        enum CleanupProgress: String { case notAttempted, intent, joined, unlinked, durable, complete, pending }
        private var cleanupAttempted = false
        private var cleanupPermit: CleanupPermit?
        private var cleanupProgress: CleanupProgress = .notAttempted
        private var cleanupRetirement: InstallationReadinessEndpoint.CleanupPostimage?
        func cleanupObservation() -> CleanupProgress {
            mutex.lock(); defer { mutex.unlock() }; return cleanupProgress
        }
        private func setCleanupProgress(_ value: CleanupProgress) {
            mutex.lock(); cleanupProgress = value; mutex.unlock()
        }
        private func validateCleanupPermit(_ permit: CleanupPermit, completion: Bool) throws {
            guard !permit.deadline.hasExpired else { throw CustodyRecordError.busy }
            try owner.validateReadinessOwner()
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard serializing, !failed, pending == nil, cleanupPermit === permit,
                  cleanupAttempted, !commandsClaimed, stop == nil,
                  current.phase == .committed, current.readinessCommit == permit.control.readinessCommit,
                  current.transaction?.id == permit.control.transaction?.id,
                  current.step?.action == .cleanupCoordination else { throw CustodyRecordError.fenced }
            if completion {
                guard current.step?.status == .complete, current.revision == permit.control.revision + 1,
                      metadataGeneration == permit.generation + 1 else { throw CustodyRecordError.fenced }
            } else {
                guard current == permit.control, metadataGeneration == permit.generation + 1 else {
                    throw CustodyRecordError.fenced
                }
            }
        }
        /// Successful committed-start path only. Every wait uses the actual
        /// ready deadline, outside journal/catalog/owner/registry locks. The
        /// completion family proves zero prior aliases and prevents new borrows
        /// until this turn ends; it is not command retirement by itself.
        func cleanupCoordination(after started: InstallationPrecommitSession.NormalStarted) throws -> InstallationControlRecord {
            guard let session = started.session, !started.deadline.hasExpired else { throw CustodyRecordError.fenced }
            try started.revalidatePeer()
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, !cleanupAttempted, pending == nil, !commandsClaimed,
                  current == started.control, current.phase == .committed,
                  current.step?.action == .readinessCommit, current.step?.status == .complete,
                  current.readinessCommit != nil else { mutex.unlock(); throw CustodyRecordError.fenced }
            cleanupAttempted = true; mutex.unlock()
            do {
                let result = try performCleanup(started: started, session: session)
                return result
            } catch {
                mutex.lock(); failed = true; cleanupProgress = .pending; mutex.unlock()
                // Never replay unlink, receipt publication or the session. An
                // uncertain write remains pending; only an exact durable chain
                // can be restricted to recovery, preserving readinessCommit.
                _ = try? fenceReadinessCommitFailure()
                _ = try? admission.closeStarts()
                throw error
            }
        }
        private func performCleanup(started: InstallationPrecommitSession.NormalStarted,
                                    session: InstallationPrecommitSession) throws -> InstallationControlRecord {
            let deadline = started.deadline
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            let permit = try serialized(deadline: deadline, completionLeases: leases,
                                        requiresOpenReadiness: true) { store in
                try started.revalidatePeer()
                try lockReadiness(deadline)
                let endpoint = readinessSession === session ? readinessEndpoint : nil
                readinessMutex.unlock()
                guard let endpoint, current == started.control else { throw CustodyRecordError.fenced }
                // Preserve exact native-created host nodes while authentication
                // is still live. They remain validated after this stream closes.
                try slots.prepareReadinessRetirement(started, for: owner, deadline: deadline)
                _ = try publish(proposal(.cleanupCoordination, status: .intent), store: store, deadline: deadline)
                try store.locked { try validateLocked(store, deadline) }
                let permit = CleanupPermit(journal: self, endpoint: endpoint, session: session, started: started)
                cleanupPermit = permit; setCleanupProgress(.intent)
                return permit
            }
            #if SHADOW_SYNC_TESTING
            try testingCleanupProbe?(permit)
            #endif
            // Close the service admission first. No serializing turn or catalog
            // guard spans native authentication, queue join or checked closes.
            try lockReadiness(deadline); readinessClosed = true; readinessMutex.unlock()
            let joined = try session.retireForCleanup(permit, started: started)
            setCleanupProgress(.joined)
            let completed = try serialized(deadline: deadline, completionLeases: leases) { store in
                try store.locked { try validateLocked(store, deadline) }
                let postimage = try permit.endpoint.retireForCleanup(permit, joined: joined)
                cleanupRetirement = postimage; setCleanupProgress(.unlinked)
                try slots.acceptReadinessRetirement(postimage, permit: permit, for: owner, deadline: deadline)
                let completed = try publish(proposal(.cleanupCoordination, status: .complete,
                    postimage: slots.readinessSnapshot), store: store, deadline: deadline)
                try store.locked { try validateLocked(store, deadline) }
                setCleanupProgress(.durable)
                try permit.endpoint.completeCleanup(permit, postimage: postimage)
                setCleanupProgress(.complete)
                return completed
            }
            mutex.lock(); cleanupPermit = nil; cleanupRetirement = nil; mutex.unlock()
            return completed
        }
        #if SHADOW_SYNC_TESTING
        var testingCleanupProbe: ((CleanupPermit) throws -> Void)?
        var testingCleanupPermit: CleanupPermit? { cleanupPermit }
        var testingOwner: InstallationTransactionOwner { owner }
        var testingValidationProfile: InstallationValidationProfile { owner.validationProfile }
        #endif

        /// This capability exists only after this journal's actual committed
        /// drain entered ordinary stopped-exclusive. It is never a start permit.
        final class StoppedCleanupPermit {
            fileprivate let journal: InstallationStagedJournal
            fileprivate let exclusive: InstallationStoppedExclusive
            fileprivate let drain: CandidateDrain
            let deadline: MonotonicDeadline
            fileprivate init(_ journal: InstallationStagedJournal, exclusive: InstallationStoppedExclusive,
                             drain: CandidateDrain) {
                self.journal = journal; self.exclusive = exclusive; self.drain = drain
                deadline = drain.acknowledgment.deadline
            }
            func validate(owner: InstallationTransactionOwner, endpoint: InstallationReadinessEndpoint? = nil,
                          action: InstallationAction = .cleanupCoordination, completion: Bool = false) throws {
                guard journal.owner === owner, !deadline.hasExpired,
                      journal.mutex.try() else { throw CustodyRecordError.fenced }
                defer { journal.mutex.unlock() }
                guard let repair = journal.stoppedRepair, repair.permit === self,
                      journal.serializing, journal.failed, journal.pending == nil,
                      journal.current.phase == .recovery, journal.current.readinessCommit == drain.pins.control.readinessCommit,
                      journal.current.transaction?.id == drain.pins.control.transaction?.id,
                      journal.current.step?.action == action,
                      journal.current.step?.status == .intent || journal.current.step?.status == .complete,
                      !completion || journal.current.step?.status == .complete,
                      endpoint == nil || endpoint === journal.slots.retainedReadinessEndpoint else {
                    throw CustodyRecordError.fenced
                }
            }
            func validateOwner() throws { try exclusive.validateRetainedOwner(journal.owner); try journal.owner.revalidate() }
            func validateDrain() throws {
                try drain.delivery.validateCompleted(drain.acknowledgment)
                try exclusive.validateRetainedOwner(journal.owner)
            }
            func matches(slots: InstallationPreparedSlotObservation) -> Bool { journal.slots === slots }
        }
        private final class StoppedRepair {
            let exclusive: InstallationStoppedExclusive
            let drain: CandidateDrain
            let permit: StoppedCleanupPermit
            var store: CustodyCatalogStore?
            var retained: InstallationStagedJournal?
            var running = false
            var finalizing = false
            var complete = false
            init(_ journal: InstallationStagedJournal, exclusive: InstallationStoppedExclusive, drain: CandidateDrain) {
                self.exclusive = exclusive; self.drain = drain
                permit = StoppedCleanupPermit(journal, exclusive: exclusive, drain: drain)
                retained = journal
            }
        }
        private var stoppedRepair: StoppedRepair?
        #if SHADOW_SYNC_TESTING
        func testingStoppedRepairCut(_ cut: InstallationReadinessEndpoint.CleanupCut) throws {
            guard let endpoint = slots.retainedReadinessEndpoint, stoppedRepair == nil else { throw CustodyRecordError.fenced }
            endpoint.testingCleanupCut = cut
        }
        #endif
        /// Original-invocation fresh repair only. A failed publication can be
        /// continued only using this same retained store and known pending pin.
        /// Poisoned atomic replacements, unknown images and uncertain closes
        /// remain fenced, including when their names happen to look correct.
        func repairStoppedFreshInstallation(_ exclusive: InstallationStoppedExclusive,
            parents: InstallationParentPreparation, registry: RetainedCleanupRegistry) throws -> InstallationControlRecord {
            guard mutex.try() else { throw CustodyRecordError.busy }
            let existing = stoppedRepair
            let drain = candidateDrain
            let initialControl = current, initialPending = pending != nil
            let initialCleanup = cleanupProgress
            guard !serializing, !stoppedPinsReading, completionParents === parents,
                  failed, !commandsClaimed, terminalProgress == .notAttempted,
                  current.transaction?.intent == .install, current.transaction?.priorCommitDigest == nil,
                  current.phase == .recovery, current.readinessCommit != nil,
                  let drain, drain.registry === registry, exclusive.permitsCommittedDrain(drain),
                  existing == nil || (existing?.exclusive === exclusive && existing?.running == false
                    && existing?.finalizing == false && existing?.complete == false) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            mutex.unlock()
            if existing == nil {
                // Full immutable drain validation precedes any moving journal pin.
                try exclusive.revalidate()
                try validateCandidateDrain(drain)
                guard initialControl == drain.pins.control, !initialPending,
                      initialControl.step?.action == .readinessCommit, initialControl.step?.status == .complete,
                      initialCleanup == .notAttempted else { throw CustodyRecordError.fenced }
            }
            try exclusive.validateRetainedOwner(owner)
            try owner.revalidate(); try parents.revalidate()
            try drain.delivery.validateCompleted(drain.acknowledgment)
            try drain.retirement.revalidate(for: owner, registry: registry)
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, stoppedRepair === existing, current == initialControl,
                  metadataGeneration < UInt64.max, !drain.acknowledgment.deadline.hasExpired else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let repair = existing ?? StoppedRepair(self, exclusive: exclusive, drain: drain)
            stoppedRepair = repair; repair.running = true; serializing = true; metadataGeneration += 1
            mutex.unlock()
            let deadline = repair.permit.deadline
            do {
                let store: CustodyCatalogStore
                if let original = repair.store { store = original }
                else { store = CustodyCatalogStore(stoppedRoot: intent.root, binding: current.state,
                    directory: directory, guardFile: guardFile, receipts: receipts,
                    validationProfile: owner.validationProfile); repair.store = store }
                // Only an actually retained receipt pin with unchanged old control
                // may finish the receipt->control edge. Store poison refuses first.
                if let proposed = pending {
                    try store.locked {
                        try validateLocked(store, deadline)
                        guard let pin = receiptPins[proposed.receipt.filename],
                              pin.bytes == (try proposed.receipt.receipt.encode(uid: proposed.receipt.uid)),
                              fsync(pin.node.descriptor.value) == 0, fsync(receipts.descriptor.value) == 0 else {
                            throw CustodyRecordError.fenced
                        }
                    }
                    try validateSource(deadline)
                    try store.locked {
                        try validateLocked(store, deadline)
                        try current.validateReplacement(proposed.control, receipts: chain + [proposed.receipt.receipt], profile: owner.validationProfile)
                        try replaceControl(proposed.control, store: store, deadline: deadline)
                        chain.append(proposed.receipt.receipt); pending = nil
                    }
                }
                for action in [InstallationAction.cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish] {
                    guard let step = current.step else { throw CustodyRecordError.fenced }
                    let suffix: [InstallationAction] = [.readinessCommit, .cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish]
                    guard let index = suffix.firstIndex(of: step.action), let target = suffix.firstIndex(of: action) else {
                        throw CustodyRecordError.fenced
                    }
                    if index > target { continue }
                    if index == target && step.status == .complete {
                        if action == .cleanupCoordination { try slots.finishStoppedCoordination(repair.permit) }
                        continue
                    }
                    try repair.permit.validateOwner(); try parents.revalidate()
                    try store.locked { try validateLocked(store, deadline) }
                    if index < target {
                        guard index + 1 == target, step.status == .complete else { throw CustodyRecordError.fenced }
                        _ = try publish(proposal(action, status: .intent), store: store, deadline: deadline)
                    }
                    let after: InstallationSlotSnapshot
                    if action == .cleanupCoordination {
                        after = try slots.cleanupStoppedCoordination(repair.permit)
                    } else {
                        after = try slots.completeStoppedFreshCleanup(repair.permit, action: action)
                    }
                    _ = try publish(proposal(action, status: .complete, postimage: after), store: store, deadline: deadline)
                    try store.locked { try validateLocked(store, deadline) }
                    if action == .cleanupCoordination { try slots.finishStoppedCoordination(repair.permit) }
                }
                // Endpoint and host nodes are causally absent, with checked owned
                // observations retired. No host/start permission is reconstructed.
                try slots.revalidateStoppedRepair(repair.permit, for: owner, deadline: deadline)
                try repair.permit.validateOwner(); try parents.revalidate()
                // Registry callbacks acquire their own short journal read turn.
                // No journal mutex/reservation spans that validation interval.
                let finishedRecovery = current, generation = metadataGeneration
                mutex.lock(); serializing = false; mutex.unlock()
                try drain.retirement.revalidate(for: owner, registry: registry)
                guard mutex.try() else { throw CustodyRecordError.busy }
                guard !serializing, !stoppedPinsReading, stoppedRepair === repair, repair.running,
                      current == finishedRecovery, metadataGeneration == generation else {
                    mutex.unlock(); throw CustodyRecordError.fenced
                }
                serializing = true; mutex.unlock()
                guard current.step?.action == .finish, current.step?.status == .complete,
                      current.phase == .recovery, current.revision < UInt64.max else { throw CustodyRecordError.fenced }
                let committed = InstallationControlRecord(revision: current.revision + 1, phase: .committed,
                    state: current.state, transaction: current.transaction, step: current.step,
                    latestReceiptDigest: current.latestReceiptDigest, readinessCommit: current.readinessCommit, recoveryReason: nil)
                try current.validateReplacement(committed, receipts: chain, profile: owner.validationProfile)
                try store.locked { try validateLocked(store, deadline); try replaceControl(committed, store: store, deadline: deadline) }
                try validateSource(deadline)
                // No further journal turn is allowed after durable finish. This
                // borrowed view owns no descriptions or completion lease to close.
                repair.store = nil; repair.finalizing = true
                cleanupProgress = .complete
                let permit = FinishPermit(self, deadline: deadline)
                terminalPermit = permit; terminalParents = parents; terminalRetainedSelf = self
                terminalProgress = .durable
                mutex.lock(); serializing = false; mutex.unlock()
                try permit.validateOwner(owner)
                setTerminalProgress(.retiring)
                try slots.retireAfterStoppedFinish(permit)
                try parents.retireAfterFinish(permit, owner: owner)
                try retireFinishedMetadata(permit)
                mutex.lock(); terminalResourcesRetired = true; mutex.unlock()
                try owner.finishInstallation(permit)
                setTerminalProgress(.complete)
                mutex.lock(); repair.complete = true; repair.running = false; repair.retained = nil
                terminalPermit = nil; terminalParents = nil; terminalRetainedSelf = nil; mutex.unlock()
                return permit.control
            } catch {
                // Preserve failed and every original stage/pin. Final-close
                // uncertainty cannot be retried or reported as held kernel EX.
                mutex.lock(); serializing = false; repair.running = false
                if repair.finalizing { terminalProgress = .pending }
                mutex.unlock()
                throw error
            }
        }

        /// This capability exists only after this journal's actual readiness-only
        /// drain entered ordinary stopped-exclusive. It is never a start permit.
        final class ReadinessRestorationPermit {
            fileprivate let journal: InstallationStagedJournal
            fileprivate let exclusive: InstallationStoppedExclusive
            fileprivate let drain: ReadinessCandidateDrain
            let deadline: MonotonicDeadline
            fileprivate init(_ journal: InstallationStagedJournal, exclusive: InstallationStoppedExclusive,
                             drain: ReadinessCandidateDrain) {
                self.journal = journal; self.exclusive = exclusive; self.drain = drain
                deadline = drain.acknowledgment.deadline
            }
            func validate(owner: InstallationTransactionOwner, endpoint: InstallationReadinessEndpoint? = nil,
                          action: InstallationAction = .cleanupCoordination, completion: Bool = false) throws {
                guard journal.owner === owner, !deadline.hasExpired,
                      journal.mutex.try() else { throw CustodyRecordError.fenced }
                defer { journal.mutex.unlock() }
                guard let repair = journal.readinessRestoration, repair.permit === self,
                      journal.serializing, journal.failed, journal.pending == nil,
                      journal.current.phase == .recovery, journal.current.readinessCommit == drain.pins.control.readinessCommit,
                      journal.current.transaction?.id == drain.pins.control.transaction?.id,
                      journal.current.step?.action == action,
                      journal.current.step?.status == .intent || journal.current.step?.status == .complete,
                      !completion || journal.current.step?.status == .complete,
                      endpoint == nil || endpoint === journal.slots.retainedReadinessEndpoint else {
                    throw CustodyRecordError.fenced
                }
            }
            func validateOwner() throws { try exclusive.validateRetainedOwner(journal.owner); try journal.owner.revalidate() }
            func validateDrain() throws {
                try drain.delivery.validateCompleted(drain.acknowledgment)
                try exclusive.validateRetainedOwner(journal.owner)
            }
            func matches(slots: InstallationPreparedSlotObservation) -> Bool { journal.slots === slots }
            /// A fresh live check for ONE destructive boundary. It grants no
            /// reusable token: the caller immediately performs its held/named
            /// child check and syscall within the existing serial action.
            func validateMutation(owner: InstallationTransactionOwner, action: InstallationAction) throws {
                guard journal.owner === owner else { throw CustodyRecordError.fenced }
                try journal.validateFreshRestorationMutation(self, action: action)
            }
        }
        /// Metadata is reconciled under its original nonblocking guard. The
        /// source verifier, registry callbacks and retained owner checks run
        /// with neither journal nor catalog mutex held. The running restoration
        /// continues to exclude another writer while registry archive readers
        /// take their existing short read turns. No deadline or pin is renewed.
        private func validateFreshRestorationMutation(_ permit: ReadinessRestorationPermit,
            action: InstallationAction) throws {
            guard [.restoreApplication, .restorePlist].contains(action),
                  !permit.deadline.hasExpired, mutex.try() else { throw CustodyRecordError.fenced }
            guard let repair = readinessRestoration, repair.permit === permit,
                  repair.running, !repair.finalizing, !repair.complete,
                  serializing, !stoppedPinsReading, failed, pending == nil, !commandsClaimed,
                  terminalProgress == .notAttempted, stoppedRepair == nil,
                  readinessDrain === repair.drain, readinessStopCompletion === repair.drain.command,
                  continuationRecovery === repair.drain.delivery,
                  current.phase == .recovery, current.readinessCommit == nil,
                  current.transaction?.intent == .install, current.transaction?.priorCommitDigest == nil,
                  current.step?.action == action, current.step?.status == .intent,
                  let store = repair.store, let parents = completionParents else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let pins = stoppedPins()
            mutex.unlock()
            // Keep the serial reservation while the borrowed store uses the
            // shared guard description. This excludes stopped-pin readers;
            // flock on one open description would not exclude a second reader.
            try store.locked { try validateLocked(store, permit.deadline) }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard serializing, !stoppedPinsReading, readinessRestoration === repair,
                  repair.running, current == pins.control, metadataGeneration == pins.generation,
                  pending == nil, failed, !permit.deadline.hasExpired else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            serializing = false
            mutex.unlock()
            // Every thrown check leaves this invocation fenced. The caller's
            // existing catch clears running; it cannot publish a complete image.
            try validateStoppedPins(pins, deadline: permit.deadline)
            try permit.validateOwner()
            try repair.drain.delivery.validateCompleted(repair.drain.acknowledgment)
            try repair.drain.retirement.revalidate(for: owner, registry: repair.drain.registry)
            try parents.revalidate()
            try slots.revalidateFreshRestoration(permit, for: owner, deadline: permit.deadline)
            // Reconcile the SAME retained pins after outside verification. The
            // partial installed app is checked only by its retained manifest;
            // independently bound source bytes still require normal verification.
            try validateStoppedPins(pins, deadline: permit.deadline)
            try permit.validateOwner()
            guard mutex.try() else { throw CustodyRecordError.busy }
            defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, !commandsClaimed,
                  readinessRestoration === repair, repair.permit === permit, repair.running,
                  !repair.finalizing, !repair.complete, repair.store === store,
                  completionParents === parents, readinessDrain === repair.drain,
                  readinessStopCompletion === repair.drain.command, continuationRecovery === repair.drain.delivery,
                  terminalProgress == .notAttempted, current == pins.control,
                  metadataGeneration == pins.generation, !permit.deadline.hasExpired,
                  controlPin.descriptor === pins.controlPin.node.descriptor,
                  controlPin.identity == pins.controlPin.node.identity, controlPin.acl == pins.controlPin.node.acl,
                  anchor.identity == pins.controlPin.node.identity, anchor.acl == pins.controlPin.node.acl,
                  anchor.bytes == pins.controlPin.bytes, chain == pins.chain,
                  catalogPin.node.descriptor === pins.catalog.node.descriptor,
                  catalogPin.node.identity == pins.catalog.node.identity, catalogPin.node.acl == pins.catalog.node.acl,
                  catalogPin.bytes == pins.catalog.bytes,
                  Set(receiptPins.keys) == Set(pins.receipts.keys),
                  receiptPins.allSatisfy({ name, pin in
                    guard let retained = pins.receipts[name] else { return false }
                    return pin.node.descriptor === retained.node.descriptor && pin.node.identity == retained.node.identity
                        && pin.node.acl == retained.node.acl && pin.bytes == retained.bytes
                  }) else { throw CustodyRecordError.fenced }
            serializing = true
        }
        private final class ReadinessRestoration {
            let exclusive: InstallationStoppedExclusive
            let drain: ReadinessCandidateDrain
            let permit: ReadinessRestorationPermit
            var store: CustodyCatalogStore?
            var retained: InstallationStagedJournal?
            var running = false
            var finalizing = false
            var complete = false
            init(_ journal: InstallationStagedJournal, exclusive: InstallationStoppedExclusive, drain: ReadinessCandidateDrain) {
                self.exclusive = exclusive; self.drain = drain
                permit = ReadinessRestorationPermit(journal, exclusive: exclusive, drain: drain)
                retained = journal
            }
        }
        private var readinessRestoration: ReadinessRestoration?
        #if SHADOW_SYNC_TESTING
        var testingFreshRestorationReachedCut: InstallationFreshRestorationCut? { slots.testingRestorationReachedCut }
        func testingFreshRestorationCut(_ cut: InstallationFreshRestorationCut) throws {
            guard readinessRestoration == nil, stoppedRepair == nil else { throw CustodyRecordError.fenced }
            slots.testingRestorationCut = cut
        }
        var testingFreshRestorationUnlinks: Int { slots.testingRestorationUnlinks }
        var testingFreshRestorationResources: InstallationFreshRestorationResourceObservation? { slots.testingRestorationResourceObservation }
        var testingFreshRestorationRegistry: RetainedCleanupRegistry? { readinessDrain?.registry }
        func testingFreshRestorationMutationBarrier(_ barrier: @escaping (Int, String) throws -> Void) throws {
            guard readinessRestoration == nil, stoppedRepair == nil, readinessDrain != nil else { throw CustodyRecordError.fenced }
            slots.testingRestorationMutationBarrier = barrier
        }
        func testingFreshRestorationResourceFault(_ fault: InstallationFreshRestorationResourceFault) throws {
            guard readinessRestoration == nil, stoppedRepair == nil, readinessDrain != nil else { throw CustodyRecordError.fenced }
            slots.testingRestorationResourceFault = fault
        }
        func testingFreshRestorationProbe(_ probe: @escaping (InstallationAction) throws -> Void) throws {
            guard readinessRestoration == nil, stoppedRepair == nil else { throw CustodyRecordError.fenced }
            slots.testingRestorationProbe = probe
        }
        func testingReadinessRestorationCut(_ cut: InstallationReadinessEndpoint.CleanupCut) throws {
            guard let endpoint = slots.retainedReadinessEndpoint, readinessRestoration == nil else { throw CustodyRecordError.fenced }
            endpoint.testingCleanupCut = cut
        }
        #endif
        /// Original-invocation fresh stopped restoration only. A failed publication can be
        /// continued only using this same retained store and known pending pin.
        /// Poisoned atomic replacements, unknown images and uncertain closes
        /// remain fenced, including when their names happen to look correct.
        func restoreStoppedFreshInstallation(_ exclusive: InstallationStoppedExclusive,
            parents: InstallationParentPreparation, registry: RetainedCleanupRegistry) throws -> InstallationControlRecord {
            guard mutex.try() else { throw CustodyRecordError.busy }
            let existing = readinessRestoration
            let drain = readinessDrain
            let initialControl = current, initialPending = pending != nil
            let initialCleanup = cleanupProgress
            guard !serializing, !stoppedPinsReading, completionParents === parents,
                  failed, !commandsClaimed, terminalProgress == .notAttempted,
                  current.transaction?.intent == .install, current.transaction?.priorCommitDigest == nil,
                  current.phase == .recovery, current.readinessCommit == nil,
                  let drain, drain.registry === registry, exclusive.permitsReadinessDrain(drain),
                  existing == nil || (existing?.exclusive === exclusive && existing?.running == false
                    && existing?.finalizing == false && existing?.complete == false) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            mutex.unlock()
            if existing == nil {
                // Full immutable drain validation precedes any moving journal pin.
                try exclusive.revalidate()
                try validateReadinessCandidateDrain(drain)
                try slots.requireFreshRestorationPreimages()
                guard initialControl == drain.pins.control, !initialPending,
                      initialControl.step?.action == .candidateStop, initialControl.step?.status == .complete,
                      initialCleanup == .notAttempted else { throw CustodyRecordError.fenced }
            }
            try exclusive.validateRetainedOwner(owner)
            try owner.revalidate(); try parents.revalidate()
            try drain.delivery.validateCompleted(drain.acknowledgment)
            try drain.retirement.revalidate(for: owner, registry: registry)
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, readinessRestoration === existing, current == initialControl,
                  metadataGeneration < UInt64.max, !drain.acknowledgment.deadline.hasExpired else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let repair = existing ?? ReadinessRestoration(self, exclusive: exclusive, drain: drain)
            readinessRestoration = repair; repair.running = true; serializing = true; metadataGeneration += 1
            mutex.unlock()
            let deadline = repair.permit.deadline
            do {
                let store: CustodyCatalogStore
                if let original = repair.store { store = original }
                else { store = CustodyCatalogStore(stoppedRoot: intent.root, binding: current.state,
                    directory: directory, guardFile: guardFile, receipts: receipts,
                    validationProfile: owner.validationProfile); repair.store = store }
                // Only an actually retained receipt pin with unchanged old control
                // may finish the receipt->control edge. Store poison refuses first.
                if let proposed = pending {
                    try store.locked {
                        try validateLocked(store, deadline)
                        guard let pin = receiptPins[proposed.receipt.filename],
                              pin.bytes == (try proposed.receipt.receipt.encode(uid: proposed.receipt.uid)),
                              fsync(pin.node.descriptor.value) == 0, fsync(receipts.descriptor.value) == 0 else {
                            throw CustodyRecordError.fenced
                        }
                    }
                    try validateSource(deadline)
                    try store.locked {
                        try validateLocked(store, deadline)
                        try current.validateReplacement(proposed.control, receipts: chain + [proposed.receipt.receipt], profile: owner.validationProfile)
                        try replaceControl(proposed.control, store: store, deadline: deadline)
                        chain.append(proposed.receipt.receipt); pending = nil
                    }
                }
                for action in [InstallationAction.cleanupCoordination, .moveStateBack, .restoreApplication, .restorePlist, .restoreCoordination, .cleanupIncoming, .finish] {
                    guard let step = current.step else { throw CustodyRecordError.fenced }
                    let suffix: [InstallationAction] = [.candidateStop, .cleanupCoordination, .moveStateBack, .restoreApplication, .restorePlist, .restoreCoordination, .cleanupIncoming, .finish]
                    guard let index = suffix.firstIndex(of: step.action), let target = suffix.firstIndex(of: action) else {
                        throw CustodyRecordError.fenced
                    }
                    if index > target { continue }
                    if index == target && step.status == .complete {
                        if action == .cleanupCoordination { try slots.finishReadinessCoordination(repair.permit) }
                        continue
                    }
                    try repair.permit.validateOwner(); try parents.revalidate()
                    try store.locked { try validateLocked(store, deadline) }
                    if index < target {
                        guard index + 1 == target, step.status == .complete else { throw CustodyRecordError.fenced }
                        _ = try publish(proposal(action, status: .intent), store: store, deadline: deadline)
                    }
                    let after: InstallationSlotSnapshot
                    if action == .cleanupCoordination {
                        after = try slots.cleanupReadinessCoordination(repair.permit)
                    } else {
                        after = try slots.completeFreshRestoration(repair.permit, action: action)
                    }
                    _ = try publish(proposal(action, status: .complete, postimage: after), store: store, deadline: deadline)
                    try store.locked { try validateLocked(store, deadline) }
                    if action == .cleanupCoordination { try slots.finishReadinessCoordination(repair.permit) }
                }
                // Endpoint and host nodes are causally absent, with checked owned
                // observations retired. No host/start permission is reconstructed.
                try slots.revalidateFreshRestoration(repair.permit, for: owner, deadline: deadline)
                try repair.permit.validateOwner(); try parents.revalidate()
                // Registry callbacks acquire their own short journal read turn.
                // No journal mutex/reservation spans that validation interval.
                let finishedRecovery = current, generation = metadataGeneration
                mutex.lock(); serializing = false; mutex.unlock()
                try drain.retirement.revalidate(for: owner, registry: registry)
                guard mutex.try() else { throw CustodyRecordError.busy }
                guard !serializing, !stoppedPinsReading, readinessRestoration === repair, repair.running,
                      current == finishedRecovery, metadataGeneration == generation else {
                    mutex.unlock(); throw CustodyRecordError.fenced
                }
                serializing = true; mutex.unlock()
                guard current.step?.action == .finish, current.step?.status == .complete,
                      current.phase == .recovery, current.revision < UInt64.max else { throw CustodyRecordError.fenced }
                let committed = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                    state: current.state, transaction: current.transaction, step: current.step,
                    latestReceiptDigest: current.latestReceiptDigest, readinessCommit: nil, recoveryReason: .restoredStopped)
                try current.validateReplacement(committed, receipts: chain, profile: owner.validationProfile)
                try store.locked { try validateLocked(store, deadline); try replaceControl(committed, store: store, deadline: deadline) }
                try validateSource(deadline)
                // No further journal turn is allowed after durable finish. This
                // borrowed view owns no descriptions or completion lease to close.
                repair.store = nil; repair.finalizing = true
                cleanupProgress = .complete
                let permit = FinishPermit(self, deadline: deadline)
                terminalPermit = permit; terminalParents = parents; terminalRetainedSelf = self
                terminalProgress = .durable
                mutex.lock(); serializing = false; mutex.unlock()
                try permit.validateOwner(owner)
                setTerminalProgress(.retiring)
                try slots.retireAfterRestoredFinish(permit)
                try parents.retireAfterFinish(permit, owner: owner)
                try retireFinishedMetadata(permit)
                mutex.lock(); terminalResourcesRetired = true; mutex.unlock()
                try owner.finishInstallation(permit)
                setTerminalProgress(.complete)
                mutex.lock(); repair.complete = true; repair.running = false; repair.retained = nil
                terminalPermit = nil; terminalParents = nil; terminalRetainedSelf = nil; mutex.unlock()
                return permit.control
            } catch {
                // Preserve failed and every original stage/pin. Final-close
                // uncertainty cannot be retried or reported as held kernel EX.
                mutex.lock(); serializing = false; repair.running = false
                if repair.finalizing { terminalProgress = .pending }
                mutex.unlock()
                throw error
            }
        }

        /// A closed action permit for the original fresh install only. Neither
        /// a decoded finish nor a cleanup observation can construct one.
        final class FreshCleanupPermit {
            fileprivate let journal: InstallationStagedJournal
            let action: InstallationAction
            let deadline: MonotonicDeadline
            fileprivate let control: InstallationControlRecord
            fileprivate init(_ journal: InstallationStagedJournal, action: InstallationAction,
                             deadline: MonotonicDeadline) {
                self.journal = journal; self.action = action; self.deadline = deadline; control = journal.current
            }
            #if SHADOW_SYNC_TESTING
            func testingFail(_ point: TestingTerminalCut) throws { try journal.testingTerminalFail(point) }
            #endif
            func validate(slots: InstallationPreparedSlotObservation, owner: InstallationTransactionOwner) throws {
                guard journal.slots === slots, journal.owner === owner, !deadline.hasExpired,
                      journal.mutex.try() else { throw CustodyRecordError.fenced }
                defer { journal.mutex.unlock() }
                guard journal.serializing, !journal.failed, journal.pending == nil,
                      journal.terminalProgress == .running, journal.current == control,
                      control.transaction?.intent == .install, control.transaction?.priorCommitDigest == nil,
                      control.phase == .committed, control.readinessCommit != nil,
                      control.step?.action == action, control.step?.status == .intent,
                      [.cleanupBackups, .cleanupIncoming, .finish].contains(action) else {
                    throw CustodyRecordError.fenced
                }
            }
        }
        final class FinishPermit {
            fileprivate let journal: InstallationStagedJournal
            let deadline: MonotonicDeadline
            let control: InstallationControlRecord
            let isStoppedRepair: Bool
            let isRestoredStopped: Bool
            var requiresStoppedExclusive: Bool { isStoppedRepair || isRestoredStopped }
            private let lock = NSLock()
            private var consumed = false
            fileprivate init(_ journal: InstallationStagedJournal, deadline: MonotonicDeadline) {
                self.journal = journal; self.deadline = deadline; control = journal.current
                isStoppedRepair = journal.stoppedRepair != nil
                isRestoredStopped = journal.readinessRestoration != nil
            }
            func validateOwner(_ owner: InstallationTransactionOwner) throws {
                guard journal.owner === owner else { throw CustodyRecordError.fenced }
                try journal.validateFinish(self)
            }
            func validateSlots(_ slots: InstallationPreparedSlotObservation) throws {
                guard journal.slots === slots else { throw CustodyRecordError.fenced }
                try journal.validateFinish(self)
            }
            enum Resource: String { case temporaryStore, stagedSlots, stagedParents, bootstrapParents, metadata, admission, state, operation }
            func retire(_ descriptor: OwnedFileDescriptor, resource: Resource) throws {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                #if SHADOW_SYNC_TESTING
                if journal.testingTerminalUncertainClose == resource,
                   descriptor.retirementObservation == .notAttempted {
                    journal.testingTerminalUncertainClose = nil
                    descriptor.testingClose = { raw in
                        guard Darwin.close(raw) == 0 else { return errno }
                        return EIO
                    }
                }
                #endif
                guard descriptor.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
                #if SHADOW_SYNC_TESTING
                if journal.testingTerminalDeadlineAfterSuccessfulClose == resource {
                    journal.testingTerminalDeadlineAfterSuccessfulClose = nil
                    // The real close has succeeded. Let this same original clock
                    // expire; never replace its budget or simulate close failure.
                    while !deadline.hasExpired {
                        Thread.sleep(forTimeInterval: min(0.001, Double(deadline.remainingMilliseconds) / 1_000))
                    }
                }
                #endif
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            }
            func consumeForOriginalRelease() throws {
                try journal.validateFinish(self, retired: true)
                guard lock.try() else { throw CustodyRecordError.busy }; defer { lock.unlock() }
                guard !consumed else { throw CustodyRecordError.fenced }; consumed = true
            }
        }
        enum TerminalProgress: String { case notAttempted, running, durable, retiring, complete, pending }
        private var terminalProgress: TerminalProgress = .notAttempted
        private var terminalPermit: FinishPermit?
        private var terminalStore: CustodyCatalogStore?
        private var terminalParents: InstallationParentPreparation?
        private var completionParents: InstallationParentPreparation?
        func bindCompletionParents(_ parents: InstallationParentPreparation) throws {
            try slots.validateCompletionParents(parents)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, !failed, completionParents == nil,
                  current.step?.action == .openStagedAdmission, current.step?.status == .intent else {
                throw CustodyRecordError.fenced
            }
            completionParents = parents
        }
        private var terminalRetainedSelf: InstallationStagedJournal?
        private var terminalResourcesRetired = false
        func terminalObservation() -> TerminalProgress {
            mutex.lock(); defer { mutex.unlock() }; return terminalProgress
        }
        private func setTerminalProgress(_ progress: TerminalProgress) {
            mutex.lock(); terminalProgress = progress; mutex.unlock()
        }
        private func validateFinish(_ permit: FinishPermit, retired: Bool = false) throws {
            guard !permit.deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            defer { mutex.unlock() }
            guard terminalPermit === permit, !serializing, !stoppedPinsReading, (!failed || permit.isStoppedRepair || permit.isRestoredStopped), pending == nil,
                  current == permit.control,
                  permit.isRestoredStopped
                    ? (current.phase == .recovery && current.readinessCommit == nil && current.recoveryReason == .restoredStopped)
                    : (current.phase == .committed && current.readinessCommit != nil),
                  current.step?.action == .finish, current.step?.status == .complete,
                  cleanupProgress == .complete, terminalProgress == .durable || terminalProgress == .retiring,
                  !retired || terminalResourcesRetired else { throw CustodyRecordError.fenced }
        }
        /// Finite successful fresh-install continuation. The original caller's
        /// parents and registry are retained by Bootstrap, not reconstructed from
        /// disk. Signed repair/migration/rollback are separate, unenrolled paths.
        func finishFreshInstallation(parents: InstallationParentPreparation,
                                     registry: RetainedCleanupRegistry) throws -> InstallationControlRecord {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, !commandsClaimed, stop == nil,
                  terminalProgress == .notAttempted, completionParents === parents, cleanupProgress == .complete,
                  cleanupPermit == nil, cleanupRetirement == nil,
                  current.phase == .committed, current.readinessCommit != nil,
                  current.step?.action == .cleanupCoordination, current.step?.status == .complete,
                  current.transaction?.intent == .install, current.transaction?.priorCommitDigest == nil,
                  let ready = candidateReady, !ready.deadline.hasExpired else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            terminalProgress = .running; terminalRetainedSelf = self; terminalParents = parents; mutex.unlock()
            do {
                try parents.revalidate()
                let permit = try publishFreshFinish(deadline: ready.deadline)
                // The helper has returned: no stack-held store/lease escapes.
                // Retire the exact retained temporary store before closing starts.
                #if SHADOW_SYNC_TESTING
                try testingTerminalFail(.beforeRetirement)
                #endif
                try retireTerminalStore()
                try owner.validateStagedCommandAliasesRetired()
                let closed = try admission.closeStarts()
                let retired = try registry.installationStagedStartRetirement(after: closed)
                try retired.revalidate(for: owner)
                try permit.validateOwner(owner)
                setTerminalProgress(.retiring)
                try slots.retireAfterFinish(permit)
                try parents.retireAfterFinish(permit, owner: owner)
                try retireFinishedMetadata(permit)
                try retired.revalidate(for: owner)
                mutex.lock(); terminalResourcesRetired = true; mutex.unlock()
                try owner.finishInstallation(permit)
                setTerminalProgress(.complete)
                mutex.lock(); terminalPermit = nil; terminalParents = nil; terminalRetainedSelf = nil; mutex.unlock()
                return permit.control
            } catch {
                // Restrict only exact known durable evidence while its actual
                // pins/leases remain available. After retirement starts, no
                // reopened descriptor or decoded observation can repair a cut.
                _ = try? fenceReadinessCommitFailure()
                _ = try? admission.closeStarts()
                mutex.lock(); failed = true; terminalProgress = .pending; mutex.unlock()
                throw error
            }
        }
        private func publishFreshFinish(deadline: MonotonicDeadline) throws -> FinishPermit {
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            let result = try serialized(deadline: deadline, completionLeases: leases, terminal: true) { store in
                // Keep the real store and completion family across every action
                // and publication fault, including post-return validation cuts.
                terminalStore = store
                for action in [InstallationAction.cleanupBackups, .cleanupIncoming, .finish] {
                    _ = try publish(proposal(action, status: .intent), store: store, deadline: deadline)
                    let permit = FreshCleanupPermit(self, action: action, deadline: deadline)
                    let after = try slots.completeFreshCleanup(permit)
                    _ = try publish(proposal(action, status: .complete, postimage: after), store: store, deadline: deadline)
                    try store.locked { try validateLocked(store, deadline) }
                }
                let permit = FinishPermit(self, deadline: deadline)
                terminalPermit = permit
                return permit
            }
            setTerminalProgress(.durable)
            return result
        }
        private func retireTerminalStore() throws {
            guard let permit = terminalPermit, let store = terminalStore else { throw CustodyRecordError.fenced }
            try permit.validateOwner(owner)
            // This store owns independent observation descriptions only. Its
            // completion lease is dropped after checked closure, never unlocked.
            for descriptor in [store.receipts.descriptor, store.guardFile.descriptor,
                               store.directory.descriptor, store.root] {
                try permit.retire(descriptor, resource: .temporaryStore)
            }
            terminalStore = nil
        }
        private func retireFinishedMetadata(_ permit: FinishPermit) throws {
            try permit.validateOwner(owner)
            guard intent.mutex.try() else { throw CustodyRecordError.busy }
            defer { intent.mutex.unlock() }
            guard !intent.terminalPinsClosing else { throw CustodyRecordError.fenced }
            intent.terminalPinsClosing = true
            let descriptors = receiptPins.keys.sorted().map { receiptPins[$0]!.node.descriptor }
                + intent.receiptFiles.keys.sorted().map { intent.receiptFiles[$0]!.node.descriptor }
                + [controlPin.descriptor, catalogPin.node.descriptor, intent.control.node.descriptor,
                   intent.catalog.node.descriptor, receipts.descriptor, guardFile.descriptor,
                   directory.descriptor, intent.root]
            var seen = Set<ObjectIdentifier>()
            for descriptor in descriptors where seen.insert(ObjectIdentifier(descriptor)).inserted {
                try permit.retire(descriptor, resource: .metadata)
            }
        }
        #if SHADOW_SYNC_TESTING
        var testingTerminalPermit: FinishPermit? { terminalPermit }
        var testingTerminalCustodyRetained: Bool { terminalRetainedSelf === self && terminalParents != nil }
        var testingTerminalUncertainClose: FinishPermit.Resource?
        var testingTerminalDeadlineAfterSuccessfulClose: FinishPermit.Resource?
        enum TestingTerminalCut: Equatable { case beforeParentSync, parentSyncFailure(Int), afterParentSync, beforeRetirement }
        var testingTerminalCut: TestingTerminalCut?
        func testingTerminalFail(_ point: TestingTerminalCut) throws {
            if testingTerminalCut == point { testingTerminalCut = nil; throw CustodyRecordError.injectedFailure }
        }
        #endif

        private var continuationRecovery: StopDelivery?
        private var startupStopRequested = false
        /// Minted only while publishing this owner's exact committed recovery.
        /// Retained completion aliases permit readback after starts close; no
        /// command or new admission can be obtained from this object.
        enum StopRetirementProgress: String { case notAttempted, waiting, joining, retiring, complete, pending }
        final class StopDelivery {
            private let journal: InstallationStagedJournal
            private var store: CustodyCatalogStore?
            private let lock = NSLock()
            private var readers = 0
            private var progress: StopRetirementProgress = .notAttempted
            private var acknowledgment: InstallationPrecommitSession.Stopped?
            private var joined: InstallationPrecommitSession.StoppedJoined?
            private let completionClosure: CustodyAuthorityLeaseSet.CheckedClosure
            let control: InstallationControlRecord
            fileprivate let readinessOnly: InstallationPrecommitSession.ReadyObservation?
            fileprivate init(journal: InstallationStagedJournal, store: CustodyCatalogStore,
                             control: InstallationControlRecord,
                             readinessOnly: InstallationPrecommitSession.ReadyObservation? = nil) throws {
                self.journal = journal; self.store = store; self.control = control; self.readinessOnly = readinessOnly
                completionClosure = try store.leases.checkedClosure
            }
            func matches(journal: InstallationStagedJournal, started: InstallationPrecommitSession.NormalStarted) -> Bool {
                self.journal === journal && readinessOnly == nil
                    && (try? InstallationStartupTranscript.recovery(after: started.control)) == control
            }
            func matches(journal: InstallationStagedJournal, ready: InstallationPrecommitSession.ReadyObservation) -> Bool {
                self.journal === journal && readinessOnly === ready
                    && (try? InstallationReadinessStopBinding.expectedControl(after: ready.control,
                        validationProfile: journal.owner.validationProfile)) == control
            }
            var isReadinessOnly: Bool { readinessOnly != nil }
            func revalidate() throws {
                guard lock.try() else { throw CustodyRecordError.busy }
                guard [.notAttempted, .waiting, .joining].contains(progress), let store else {
                    lock.unlock(); throw CustodyRecordError.fenced
                }
                readers += 1; lock.unlock()
                defer { lock.lock(); readers -= 1; lock.unlock() }
                if readinessOnly != nil { try journal.validateReadinessStopDelivery(self, store: store) }
                else { try journal.validateStartupRecovery(self, store: store) }
            }
            fileprivate func begin() throws {
                guard lock.try() else { throw CustodyRecordError.busy }; defer { lock.unlock() }
                guard progress == .notAttempted else { throw CustodyRecordError.fenced }
                progress = .waiting
            }
            fileprivate func received(_ acknowledgment: InstallationPrecommitSession.Stopped) {
                lock.lock(); self.acknowledgment = acknowledgment; progress = .joining; lock.unlock()
            }
            fileprivate func fail() {
                lock.lock(); if progress != .complete { progress = .pending }; lock.unlock()
            }
            fileprivate var observation: (InstallationPrecommitSession.Stopped?, StopRetirementProgress) {
                lock.lock(); defer { lock.unlock() }; return (acknowledgment, progress)
            }
            fileprivate func retire(after joined: InstallationPrecommitSession.StoppedJoined) throws {
                try joined.claim(for: self)
                guard lock.try() else { throw CustodyRecordError.busy }
                guard progress == .joining, acknowledgment != nil, readers == 0 else {
                    progress = .pending; lock.unlock(); throw CustodyRecordError.fenced
                }
                self.joined = joined; progress = .retiring; lock.unlock()
                // This helper's stack must unwind before observing the actual
                // completion lease destructor. A retained receipt is not a lease.
                try retireStore(deadline: joined.deadline)
                guard completionClosure.observation == .succeeded,
                      !joined.deadline.hasExpired else { throw CustodyRecordError.fenced }
                try journal.owner.validateStagedCommandAliasesRetired()
                try journal.owner.validateReadinessOwner()
                guard !joined.deadline.hasExpired else { throw CustodyRecordError.busy }
                lock.lock(); progress = .complete; lock.unlock()
            }
            func validateStoppedOwner(_ owner: InstallationTransactionOwner,
                                      acknowledgment: InstallationPrecommitSession.Stopped) throws {
                guard journal.owner === owner else { throw CustodyRecordError.fenced }
                try validateCompleted(acknowledgment)
            }
            func validateCompleted(_ acknowledgment: InstallationPrecommitSession.Stopped) throws {
                guard lock.try() else { throw CustodyRecordError.busy }
                guard progress == .complete, self.acknowledgment === acknowledgment,
                      store == nil, readers == 0, let joined else {
                    lock.unlock(); throw CustodyRecordError.fenced
                }
                lock.unlock()
                guard completionClosure.observation == .succeeded else { throw CustodyRecordError.fenced }
                try joined.revalidate(for: self, acknowledgment: acknowledgment)
                guard lock.try() else { throw CustodyRecordError.busy }; defer { lock.unlock() }
                guard progress == .complete, self.joined === joined, self.acknowledgment === acknowledgment,
                      store == nil, readers == 0 else { throw CustodyRecordError.fenced }
            }
            #if SHADOW_SYNC_TESTING
            enum TestingCloseCut { case store, completion }
            func testingUncertainClose(_ cut: TestingCloseCut) throws {
                guard lock.try() else { throw CustodyRecordError.busy }; defer { lock.unlock() }
                guard progress == .notAttempted, let store else { throw CustodyRecordError.fenced }
                switch cut {
                case .store:
                    store.guardFile.descriptor.testingClose = { raw in
                        guard Darwin.close(raw) == 0 else { return errno }; return EIO
                    }
                case .completion: try store.leases.testingUncertainInstallationClose()
                }
            }
            func testingRetainCompletion() throws -> CustodyAuthorityLeaseSet {
                guard lock.try() else { throw CustodyRecordError.busy }; defer { lock.unlock() }
                guard progress == .notAttempted, let store else { throw CustodyRecordError.fenced }
                return try store.leases
            }
            var testingCompletionResult: OwnedFileDescriptor.Retirement { completionClosure.observation }
            var testingStoreRetained: Bool { lock.lock(); defer { lock.unlock() }; return store != nil }
            var testingStoreCloseResults: [OwnedFileDescriptor.Retirement] {
                lock.lock(); defer { lock.unlock() }
                guard let store else { return [] }
                return [store.receipts.descriptor, store.guardFile.descriptor, store.directory.descriptor, store.root]
                    .map { $0.retirementObservation }
            }
            @_silgen_name("shadowSyncTesting_testingRefuseRetirementReplay")
            @inline(never)
            func testingRefuseRetirementReplay() throws {
                lock.lock(); let original = joined; lock.unlock()
                guard let original else { throw CustodyRecordError.fenced }
                try retire(after: original)
            }
            #endif
            private func retireStore(deadline: MonotonicDeadline) throws {
                guard !deadline.hasExpired, let store else { throw CustodyRecordError.busy }
                // All delivery readers and the actual IPC queue are joined.
                // Poison this exact store before the first close; any retained
                // alias can no longer perform catalog IO or reopen its guard.
                guard store.mutex.try() else { throw CustodyRecordError.busy }
                guard !store.poisoned else { store.mutex.unlock(); throw CustodyRecordError.fenced }
                store.poisoned = true; store.mutex.unlock()
                let pins = store.installationCommandPins.keys.sorted().map { store.installationCommandPins[$0]!.descriptor }
                var seen = Set<ObjectIdentifier>()
                for descriptor in pins + [store.receipts.descriptor, store.guardFile.descriptor,
                                          store.directory.descriptor, store.root]
                    where seen.insert(ObjectIdentifier(descriptor)).inserted {
                    guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                    guard descriptor.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
                    guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                }
                // On partial/uncertain close, the store remains retained. On
                // success, only its real destructor may release completion
                // leases; other retained aliases keep the receipt pending.
                lock.lock(); self.store = nil; lock.unlock()
            }
        }
        #if SHADOW_SYNC_TESTING
        var testingStopDeliveryProbe: ((StopDelivery) throws -> Void)?
        #endif
        func stoppedHostObservation() -> (InstallationPrecommitSession.Stopped?, StopRetirementProgress) {
            mutex.lock(); let delivery = continuationRecovery; let requested = startupStopRequested; mutex.unlock()
            let value = delivery?.observation ?? (nil, .notAttempted)
            // A failed publication/claim can precede delivery construction.
            // The retained stop attempt remains pending even without a frame.
            return requested && value.1 == .notAttempted ? (value.0, .pending) : value
        }
        func validateNormalStartup(_ started: InstallationPrecommitSession.NormalStarted,
                                   delivery: CommitDelivery, deadline: MonotonicDeadline) throws {
            try started.revalidatePeer()
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, current == delivery.control,
                  current == started.control, let ready = candidateReady,
                  delivery.matches(journal: self, ready: ready) else { mutex.unlock(); throw CustodyRecordError.fenced }
            serializing = true; mutex.unlock()
            do {
                try slots.observeNormalHost(started, for: owner, deadline: deadline)
                mutex.lock(); serializing = false; mutex.unlock()
            } catch { mutex.lock(); serializing = false; failed = true; mutex.unlock(); throw error }
            try delivery.revalidate()
            try started.revalidatePeer()
        }
        func takeNormalStarted() throws -> InstallationPrecommitSession.NormalStarted {
            readinessMutex.lock(); let session = readinessSession; readinessMutex.unlock()
            guard let session else { throw CustodyRecordError.fenced }
            return try session.takeNormalStarted()
        }
        func stopStartedHost(_ started: InstallationPrecommitSession.NormalStarted) throws -> InstallationPrecommitSession.Stopped {
            readinessMutex.lock(); let session = readinessSession; readinessMutex.unlock()
            guard let session, started.session === session else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !startupStopRequested else { mutex.unlock(); throw CustodyRecordError.fenced }
            startupStopRequested = true
            let existing = continuationRecovery
            mutex.unlock()
            // A previously restrictive publication may have won a wrapper
            // postflight failure. Consume only its actual retained capability;
            // never republish/retry a failed or ambiguous recovery write.
            if existing == nil { _ = try fenceReadinessCommitFailure() }
            guard mutex.try() else { throw CustodyRecordError.busy }
            let delivery = !serializing ? continuationRecovery : nil
            mutex.unlock()
            guard let delivery else { throw CustodyRecordError.fenced }
            do {
                #if SHADOW_SYNC_TESTING
                try testingStopDeliveryProbe?(delivery)
                #endif
                try delivery.begin()
                let acknowledgment = try session.stop(delivery)
                delivery.received(acknowledgment)
                let joined = try session.joinStopped(acknowledgment, delivery: delivery)
                try delivery.retire(after: joined)
                try slots.retainStoppedHost(acknowledgment, delivery: delivery, for: owner)
                return acknowledgment
            } catch {
                // A cancellation/close failure can race the waiting caller
                // after the final authenticated frame. Keep that exact frame
                // observation without treating it as a successful queue join.
                if let acknowledgment = session.stoppedAcknowledgment(for: delivery) {
                    delivery.received(acknowledgment)
                }
                delivery.fail(); throw error
            }
        }
        private func validateStartupRecovery(_ delivery: StopDelivery, store: CustodyCatalogStore) throws {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, pending == nil, continuationRecovery === delivery,
                  current == delivery.control, current.phase == .recovery,
                  current.readinessCommit != nil, metadataGeneration < UInt64.max,
                  let ready = candidateReady, !ready.deadline.hasExpired else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            serializing = true; metadataGeneration += 1
            let generation = metadataGeneration, expected = current
            mutex.unlock()
            defer { mutex.lock(); serializing = false; mutex.unlock() }
            try owner.validateReadinessOwner()
            try slots.revalidate(for: owner, deadline: ready.deadline)
            try store.locked { try validateLocked(store, ready.deadline) }
            try owner.validateReadinessOwner()
            try slots.revalidate(for: owner, deadline: ready.deadline)
            mutex.lock(); defer { mutex.unlock() }
            guard serializing, metadataGeneration == generation, current == expected,
                  continuationRecovery === delivery, pending == nil, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
        }
        /// Original candidate-ready-complete only. Unknown/partial ready and
        /// commit publication are separate fenced cuts; no rollback inference.
        func stopReadinessOnlyHost(admission stop: InstallationStagedStopAdmission) throws -> InstallationStagedCommandObservation {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, !startupStopRequested,
                  terminalProgress == .notAttempted, self.stop == nil, !commandsClaimed,
                  !commitDeliveryReserved, current.phase == .active, current.readinessCommit == nil,
                  current.step?.action == .candidateReady, current.step?.status == .complete,
                  let ready = candidateReady, !ready.deadline.hasExpired else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            startupStopRequested = true
            let generation = metadataGeneration; mutex.unlock()
            // Actual native peer revalidation precedes closing start admission.
            // Stop admission was obtained from this owner's real retired starts.
            try ready.revalidate(for: self)
            try stop.validateOwner(owner)
            try lockReadiness(ready.deadline)
            let session = readinessSession
            readinessClosed = true
            readinessMutex.unlock()
            guard let session else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, metadataGeneration == generation,
                  self.stop == nil, candidateReady === ready, !commitDeliveryReserved else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            self.stop = stop; mutex.unlock()
            let observed = try serialized(deadline: ready.deadline) { store in
                guard current.phase == .active, current.step?.action == .candidateReady,
                      current.step?.status == .complete, current.readinessCommit == nil,
                      continuationRecovery == nil else { throw CustodyRecordError.fenced }
                let recovery = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                    state: current.state, transaction: current.transaction, step: current.step,
                    latestReceiptDigest: current.latestReceiptDigest, readinessCommit: nil, recoveryReason: .readinessFailed)
                try current.validateReplacement(recovery, receipts: chain, profile: owner.validationProfile)
                try store.locked { try validateLocked(store, ready.deadline); try replaceControl(recovery, store: store, deadline: ready.deadline) }
                _ = try publish(proposal(.candidateStop, status: .intent), store: store, deadline: ready.deadline)
                guard current == (try InstallationReadinessStopBinding.expectedControl(after: ready.control, validationProfile: owner.validationProfile)) else {
                    throw CustodyRecordError.fenced
                }
                let observed = try observation(store, deadline: ready.deadline)
                continuationRecovery = try StopDelivery(journal: self, store: store, control: current, readinessOnly: ready)
                return observed
            }
            guard mutex.try() else { throw CustodyRecordError.busy }
            let delivery = continuationRecovery; mutex.unlock()
            guard let delivery, delivery.matches(journal: self, ready: ready) else { throw CustodyRecordError.fenced }
            do {
                try delivery.begin()
                let acknowledgment = try session.stop(delivery)
                delivery.received(acknowledgment)
                let joined = try session.joinStopped(acknowledgment, delivery: delivery)
                try delivery.retire(after: joined)
                try slots.retainReadinessStoppedHost(acknowledgment, delivery: delivery, for: owner)
                return observed
            } catch {
                if let acknowledgment = session.stoppedAcknowledgment(for: delivery) { delivery.received(acknowledgment) }
                delivery.fail()
                mutex.lock(); failed = true; mutex.unlock()
                throw error
            }
        }
        private func validateReadinessStopDelivery(_ delivery: StopDelivery, store: CustodyCatalogStore) throws {
            guard let ready = delivery.readinessOnly, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
            try owner.validateReadinessOwner()
            try slots.revalidate(for: owner, deadline: ready.deadline)
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, continuationRecovery === delivery,
                  candidateReady === ready, !commandsClaimed, stop != nil,
                  current == delivery.control,
                  current == (try? InstallationReadinessStopBinding.expectedControl(after: ready.control, validationProfile: owner.validationProfile)) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let generation = metadataGeneration
            serializing = true; mutex.unlock()
            defer { mutex.lock(); serializing = false; mutex.unlock() }
            // The reservation owns the metadata turn, never a held mutex.
            try store.locked { try validateLocked(store, ready.deadline) }
            try owner.validateReadinessOwner()
            try slots.revalidate(for: owner, deadline: ready.deadline)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard metadataGeneration == generation, current == delivery.control,
                  continuationRecovery === delivery, pending == nil, !ready.deadline.hasExpired else { throw CustodyRecordError.fenced }
        }
        private var reconciledStart = false
        private var recoveryStartMayHaveExecuted = false
        // Independent short custody lock: code verification and metadata turns
        // never hold it, so cancellation is bounded even during publisher work.
        private let readinessMutex = NSLock()
        private var readinessClosed = false
        func observeReadinessWorkFinished(on queue: DispatchQueue,
            observer: @escaping @Sendable () -> Void) -> InstallationObservationSubscription? {
            readinessMutex.lock(); let session = readinessSession; readinessMutex.unlock()
            return session?.observeWorkFinished(on: queue, observer: observer)
        }
        private var readinessSession: InstallationPrecommitSession?
        private var readinessEndpoint: InstallationReadinessEndpoint?
        struct ReadinessContext {
            let journal: InstallationStagedJournal
            let endpoint: InstallationReadinessEndpoint
            let app: PublisherCodeVerifier.Identity
            let uid: uid_t
            let deadline: MonotonicDeadline
            let validationProfile: InstallationValidationProfile
            fileprivate init(journal: InstallationStagedJournal, endpoint: InstallationReadinessEndpoint,
                app: PublisherCodeVerifier.Identity, uid: uid_t, deadline: MonotonicDeadline) {
                self.validationProfile = journal.owner.validationProfile
                self.journal = journal; self.endpoint = endpoint; self.app = app; self.uid = uid; self.deadline = deadline
            }
        }
        private func lockReadiness(_ deadline: MonotonicDeadline) throws {
            while !readinessMutex.try() {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        func closeReadiness(deadline: MonotonicDeadline) throws {
            try lockReadiness(deadline)
            readinessClosed = true
            readinessMutex.unlock()
            // Reservation ordering: serialized(requiresOpenReadiness:) reserves
            // under mutex + readinessMutex. Closure prevents every later ready
            // turn. An earlier reserved turn may finish its durable publication;
            // close cannot succeed until that entire turn (including postflight)
            // unwinds, even when a live session was already published.
            // Never hold either mutex or the catalog guard while waiting. A
            // timeout throws busy and retains the session, endpoint and owner.
            while true {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                if mutex.try() {
                    let idle = !serializing; mutex.unlock()
                    if idle { break }
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            try lockReadiness(deadline)
            let session = readinessSession, endpoint = readinessEndpoint ?? slots.retainedReadinessEndpoint
            readinessMutex.unlock()
            if let session { try session.cancelAndJoin(deadline: deadline) }
            else { endpoint?.closeService(); try endpoint?.requireServiceClosed() }
        }
        func didJoinReadiness(_ session: InstallationPrecommitSession, deadline: MonotonicDeadline) throws {
            try lockReadiness(deadline); defer { readinessMutex.unlock() }
            if readinessSession === session { readinessSession = nil }
        }
        func readinessHost(peer: PublisherCodeVerifier.AuditPeerObservation, generation: String,
                           deadline: MonotonicDeadline) throws -> ProcessIdentity {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            return try slots.readinessHost(peer: peer, generation: generation, for: owner, deadline: deadline)
        }
        func validateReadiness(_ control: InstallationControlRecord, deadline: MonotonicDeadline) throws {
            // Snapshot under a short metadata lock; source/publisher work is
            // outside it. Reacquisition refuses a changed/in-flight revision.
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, stop == nil, !commandsClaimed,
                  current == control, current.phase == .active,
                  current.step?.action == .kickstartCandidate, current.step?.status == .complete,
                  current.readinessCommit == nil else { mutex.unlock(); throw CustodyRecordError.fenced }
            let revision = metadataGeneration
            mutex.unlock()
            try lockReadiness(deadline)
            let endpoint = readinessEndpoint; let closed = readinessClosed
            readinessMutex.unlock()
            guard let endpoint, !closed else { throw CustodyRecordError.fenced }
            try owner.validateStagedCommandAliasesRetired()
            try admission.validateOwner(owner, intent: intent)
            try slots.revalidate(for: owner, deadline: deadline); try owner.revalidate(); try endpoint.revalidate(deadline: deadline)
            let store = try CustodyCatalogStore(leases: admission.retainStartLeases(), validationProfile: owner.validationProfile)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
                guard !serializing, !stoppedPinsReading, metadataGeneration == revision, !failed, pending == nil,
                      current == control, stop == nil, !commandsClaimed else { throw CustodyRecordError.fenced }
                // Only bounded metadata checks; no validateSource or code verifier
                // is reachable through validateLocked/store.locked.
                try store.locked { try validateLocked(store, deadline) }
                mutex.unlock()
            } catch { mutex.unlock(); throw error }
            try admission.validateOwner(owner, intent: intent)
            try slots.revalidate(for: owner, deadline: deadline); try owner.revalidate(); try endpoint.revalidate(deadline: deadline)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            let unchanged = !serializing && metadataGeneration == revision && !failed && current == control
            mutex.unlock()
            try lockReadiness(deadline); let stillOpen = !readinessClosed; readinessMutex.unlock()
            guard unchanged, stillOpen else { throw CustodyRecordError.fenced }
        }
        #if SHADOW_SYNC_TESTING
        func testingRemoveReadinessEndpoint() throws {
            try closeReadiness(deadline: .init(seconds: 3))
            try (readinessEndpoint ?? slots.retainedReadinessEndpoint)?.testingRemoveOwnedEndpoint(deadline: .init(seconds: 3))
        }
        func testingReadinessCut(_ cut: InstallationReadinessEndpoint.TestingCut) {
            slots.testingEndpointCut = cut
        }
        var testingEndpoint: InstallationReadinessEndpoint? {
            readinessMutex.lock()
            let published = readinessEndpoint
            readinessMutex.unlock()
            if let published { return published }
            // Partial creation is owned by slots before publication. Observe
            // that same owner only after the serialized turn has unwound.
            guard mutex.try() else { return nil }
            defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading else { return nil }
            return slots.retainedReadinessEndpoint
        }
        var testingSession: InstallationPrecommitSession? {
            readinessMutex.lock(); defer { readinessMutex.unlock() }; return readinessSession
        }
        /// Testing-only observation of the REAL publish path. It cannot mint
        /// readiness, command retirement, a proposal or any successful result.
        enum TestingPublicationPoint { case beforeReceipt, afterReadyValidation, insideControlGuard }
        enum TestingPublicationFailure: CaseIterable {
            case afterReceipt, beforeControl
            case receiptBeforeSwap, receiptAfterSwap, receiptAfterDirectorySync
            case controlBeforeSwap, controlAfterSwap, controlAfterDirectorySync, controlAfterPreimageUnlink
        }
        final class TestingPublicationProbe: @unchecked Sendable {
            let action: InstallationAction
            let status: InstallationStepStatus
            let failure: TestingPublicationFailure?
            let point: TestingPublicationPoint?
            let barrier: CustodyLeaseTestingBarrier?
            private let lock = NSLock()
            private var trace: (InstallationControlRecord, InstallationControlRecord, InstallationStepReceipt)?
            init(action: InstallationAction, status: InstallationStepStatus,
                 failure: TestingPublicationFailure? = nil,
                 point: TestingPublicationPoint? = nil, barrier: CustodyLeaseTestingBarrier? = nil) {
                self.action = action; self.status = status; self.failure = failure
                self.point = point; self.barrier = barrier
            }
            fileprivate func begin(_ before: InstallationControlRecord, _ after: InstallationControlRecord,
                                   _ receipt: InstallationStepReceipt) throws {
                lock.lock(); defer { lock.unlock() }
                guard trace == nil else { throw CustodyRecordError.fenced }
                trace = (before, after, receipt)
            }
            var observed: (before: InstallationControlRecord, after: InstallationControlRecord, receipt: InstallationStepReceipt)? {
                lock.lock(); defer { lock.unlock() }; return trace
            }
            fileprivate func pause(_ point: TestingPublicationPoint) throws {
                if self.point == point, let barrier, !barrier.pause() { throw CustodyRecordError.busy }
            }
        }
        private var testingPublicationProbe: TestingPublicationProbe?
        func testingObservePublication(_ probe: TestingPublicationProbe) throws {
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, testingPublicationProbe == nil else { throw CustodyRecordError.fenced }
            testingPublicationProbe = probe
        }
        private var publicationBarrier: CustodyLeaseTestingBarrier?
        private var sourceBarrier: CustodyLeaseTestingBarrier?
        func testingPausePublication(_ barrier: CustodyLeaseTestingBarrier) { publicationBarrier = barrier }
        func testingPauseSource(_ barrier: CustodyLeaseTestingBarrier) { sourceBarrier = barrier }
        var testingMetadataLockAvailable: Bool {
            guard mutex.try() else { return false }; mutex.unlock(); return true
        }
        #endif
        private let mutex = NSLock()
        // An exclusive turn protects mutable metadata while its mutex is free.
        // Concurrent writers refuse; cancellation uses independent custody.
        private var serializing = false
        private var metadataGeneration: UInt64 = 0
        private var failed = false
        private struct Pending {
            let control: InstallationControlRecord
            let receipt: InstallationStepReceipt.CanonicalObservation
        }
        private var pending: Pending?
        #if SHADOW_SYNC_TESTING
        enum Cut { case afterReceipt, beforeControl }
        private var cut: Cut?
        private var receiptFault: CustodyCatalogStore.Fault?
        private var controlFault: CustodyCatalogStore.Fault?
        func testingCut(_ value: Cut) { mutex.lock(); cut = value; mutex.unlock() }
        func testingWriteFault(receipt: CustodyCatalogStore.Fault? = nil, control: CustodyCatalogStore.Fault? = nil) {
            mutex.lock(); receiptFault = receipt; controlFault = control; mutex.unlock()
        }
        var testingHasPending: Bool { mutex.lock(); defer { mutex.unlock() }; return pending != nil }
        #endif

        fileprivate init(intent: InstallationStagedAdmissionIntent, admission: InstallationStagedAdmission,
                         deadline: MonotonicDeadline) throws {
            self.intent = intent; self.admission = admission; owner = intent.owner; slots = intent.slots
            directory = intent.directory; receipts = intent.receipts; guardFile = intent.guardFile
            controlPin = intent.control.node; catalogPin = intent.catalog; receiptPins = intent.receiptFiles
            anchor = File(identity: intent.control.node.identity, acl: intent.control.node.acl, bytes: intent.control.bytes)
            current = try InstallationControlRecord.decode(anchor.bytes, profile: owner.validationProfile)
            chain = try intent.receiptFiles.filter { $0.key.hasPrefix(InstallationStepReceipt.prefix) }.values.map {
                try InstallationStepReceipt.decode($0.bytes, uid: intent.uid)
            }.sorted { a, b in a.ordinal == b.ordinal ? a.status == .intent && b.status == .complete : a.ordinal < b.ordinal }
            try admission.validateOwner(owner, intent: intent)
            try current.validateReceiptChain(chain, profile: owner.validationProfile)
            try withStore(deadline: deadline) { store in try store.locked { try validateLocked(store, deadline) } }
        }
        private func validateSource(_ deadline: MonotonicDeadline) throws {
            if let restoration = readinessRestoration {
                try restoration.exclusive.validateRetainedOwner(owner)
                try owner.revalidate()
                try slots.revalidateFreshRestoration(restoration.permit, for: owner, deadline: deadline)
                return
            }
            if let repair = stoppedRepair {
                try repair.exclusive.validateRetainedOwner(owner)
                try owner.revalidate()
                try slots.revalidateStoppedRepair(repair.permit, for: owner, deadline: deadline)
                return
            }
            #if SHADOW_SYNC_TESTING
            if let barrier = sourceBarrier { sourceBarrier = nil; guard barrier.pause() else { throw CustodyRecordError.busy } }
            #endif
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if let stop { try stop.validateOwner(owner) }
            else { try admission.validateOwner(owner, intent: intent) }
            try slots.revalidate(for: owner, deadline: deadline); try owner.revalidate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
        private func withStore<T>(deadline: MonotonicDeadline, completionLeases: CustodyAuthorityLeaseSet? = nil, _ body: (CustodyCatalogStore) throws -> T) throws -> T {
            try validateSource(deadline)
            let leases = try completionLeases ?? stop.map { try $0.retainStopLeases() } ?? admission.retainStartLeases()
            let store = try CustodyCatalogStore(leases: leases, validationProfile: owner.validationProfile)
            do {
                let result = try body(store)
                try validateSource(deadline)
                return result
            } catch {
                let failure = error
                // Retain the same live store/lease through a postcommit failure.
                // No new borrowing after serialized closes starts is needed.
                // Failed/poisoned persistence is never reconciled by assumption.
                if current.phase == .committed, pending == nil, !postcommitFenceAttempted {
                    _ = try? recordPostcommitFailure(store: store, deadline: deadline)
                }
                throw failure
            }
        }
        private func serialized<T>(deadline: MonotonicDeadline, completionLeases: CustodyAuthorityLeaseSet? = nil,
                                   requiresOpenReadiness: Bool = false,
                                   fenceExpiredAdmission: Bool = false, terminal: Bool = false,
                                   _ body: (CustodyCatalogStore) throws -> T) throws -> T {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading else { mutex.unlock(); throw CustodyRecordError.busy }
            guard !failed, pending == nil, metadataGeneration < UInt64.max,
                  terminalProgress == .notAttempted || (terminal && terminalProgress == .running) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            if deadline.hasExpired {
                // An expired opening attempt owns no metadata turn and may
                // publish nothing. It must still fence this idle continuation
                // and new starts. Existing aliases remain with their original
                // owner; closure and any later join run outside this mutex.
                // A competing active turn refuses above and is never fenced
                // by this expired-admission branch.
                if fenceExpiredAdmission { failed = true }
                mutex.unlock()
                if fenceExpiredAdmission { _ = try? admission.closeStarts() }
                throw CustodyRecordError.busy
            }
            if requiresOpenReadiness {
                // Reserve the metadata turn while checking closure under its
                // custody lock. Close either prevents this turn or observes it
                // in flight and cannot report completion before it unwinds.
                guard readinessMutex.try() else { mutex.unlock(); throw CustodyRecordError.busy }
                guard !readinessClosed else {
                    readinessMutex.unlock(); mutex.unlock(); throw CustodyRecordError.fenced
                }
                serializing = true; metadataGeneration += 1
                readinessMutex.unlock()
            } else {
                serializing = true; metadataGeneration += 1
            }
            mutex.unlock()
            defer { mutex.lock(); serializing = false; mutex.unlock() }
            do { return try withStore(deadline: deadline, completionLeases: completionLeases, body) }
            catch {
                // The turn still exclusively owns metadata, but no mutex spans
                // source verification, scope closure, IPC or any waiting.
                // If source preflight failed before withStore could construct
                // its store, the caller's original completion lease is still
                // retained here. It can only publish a restrictive failure from
                // this exact known durable commit; no failed write is adopted.
                if current.phase == .committed, pending == nil, !postcommitFenceAttempted,
                   let completionLeases {
                    if let failureStore = try? CustodyCatalogStore(leases: completionLeases, validationProfile: owner.validationProfile) {
                        _ = try? recordPostcommitFailure(store: failureStore, deadline: deadline)
                    }
                }
                failed = true
                if stop == nil { _ = try? admission.closeStarts() }
                throw error
            }
        }
        private func validateLocked(_ store: CustodyCatalogStore, _ deadline: MonotonicDeadline, command: Bool = false) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try store.validate(directory, at: store.root.value, name: "custody", isDirectory: true)
            try store.validate(guardFile, at: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
            try store.validate(receipts, at: directory.descriptor.value, name: "receipts", isDirectory: true)
            try store.validate(controlPin, at: directory.descriptor.value, name: InstallationControlRecord.filename, isDirectory: false)
            let actual = try store.installationSnapshot(pendingStep: pending?.receipt, pendingControl: pending?.control)
            let catalog = try store.snapshot()
            // Phase writes retain the original empty catalog pin. A command
            // scope instead owns exact catalog reservations/retirement; its
            // guarded fence rejects foreign, draining and expired entries.
            if !command {
                try store.validate(catalogPin.node, at: directory.descriptor.value, name: "catalog.json", isDirectory: false)
                guard catalog.0.identity == catalogPin.node.identity, catalog.0.acl == catalogPin.node.acl,
                      catalog.0.bytes == catalogPin.bytes, catalog.1.entries.isEmpty else { throw CustodyRecordError.conflict }
            }
            let names = try InstallationStagedAdmissionIntent.names(receipts.descriptor.value)
            let installationNames = command ? names.filter {
                $0.hasPrefix(InstallationStepReceipt.prefix) || $0.hasPrefix(InstallationDocumentPreimage.prefix)
            } : names
            let expectedNames = command ? Set(receiptPins.keys.filter {
                $0.hasPrefix(InstallationStepReceipt.prefix) || $0.hasPrefix(InstallationDocumentPreimage.prefix)
            }) : Set(receiptPins.keys)
            guard actual.0.identity == anchor.identity, actual.0.acl == anchor.acl,
                  actual.0.bytes == anchor.bytes, actual.1 == current,
                  Set(installationNames) == expectedNames else {
                throw CustodyRecordError.conflict
            }
            for (name, pin) in receiptPins {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                try store.validate(pin.node, at: receipts.descriptor.value, name: name, isDirectory: false)
                let bytes = try store.read(name, at: receipts.descriptor.value, maximum: InstallationDocumentPreimage.maximumBytes)
                guard bytes.identity == pin.node.identity, bytes.acl == pin.node.acl, bytes.bytes == pin.bytes else {
                    throw CustodyRecordError.conflict
                }
            }
            try store.validateBindings()
        }
        private func proposal(_ action: InstallationAction, status: InstallationStepStatus, postimage: InstallationSlotSnapshot? = nil,
                              commit: InstallationReadinessCommit? = nil) throws -> Pending {
            guard let transaction = current.transaction, let step = current.step,
                  current.revision < UInt64.max else { throw CustodyRecordError.fenced }
            let receipt = InstallationStepReceipt(transactionID: transaction.id,
                ordinal: status == .complete ? step.ordinal : step.ordinal + 1,
                previousReceiptDigest: current.latestReceiptDigest, action: action, status: status,
                preimage: transaction.slots, postimage: status == .complete ? (postimage ?? transaction.slots) : nil,
                bindingDigest: try transaction.bindingDigest(state: current.state))
            let canonical = try InstallationStepReceipt.CanonicalObservation(validating: receipt, uid: current.state.directory.uid)
            let successor = InstallationTransaction(id: transaction.id, boot: transaction.boot, intent: transaction.intent,
                coordinator: transaction.coordinator, sourceReleaseDigest: transaction.sourceReleaseDigest,
                candidate: transaction.candidate, priorCommitDigest: transaction.priorCommitDigest,
                slots: postimage ?? transaction.slots)
            let next = InstallationControlRecord(revision: current.revision + 1, phase: commit == nil ? current.phase : .committed,
                state: current.state, transaction: successor, step: try receipt.step(), latestReceiptDigest: canonical.digest,
                readinessCommit: commit ?? current.readinessCommit, recoveryReason: current.recoveryReason)
            try current.validateReplacement(next, receipts: chain + [receipt], profile: owner.validationProfile)
            return Pending(control: next, receipt: canonical)
        }
        private func replaceControl(_ next: InstallationControlRecord, store: CustodyCatalogStore,
                                    deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            #if SHADOW_SYNC_TESTING
            if cut == .beforeControl { cut = nil; throw CustodyRecordError.injectedFailure }
            store.testingCut = controlFault; controlFault = nil
            #endif
            try store.write(InstallationControlRecord.filename, bytes: next.encode(profile: owner.validationProfile), expected: anchor)
            let after = try store.installationSnapshot()
            let pin = try CustodyCatalogStore.openNode(directory.descriptor.value, InstallationControlRecord.filename,
                uid: store.uid, directory: false)
            guard after.1 == next, pin.identity == after.0.identity, pin.acl == after.0.acl,
                  fsync(pin.descriptor.value) == 0, fsync(directory.descriptor.value) == 0 else { throw CustodyRecordError.conflict }
            // The exact readback and both fsyncs have succeeded. Retain this
            // real outcome BEFORE subsequent identity postflight can throw.
            if next.phase == .committed, next.step?.action == .readinessCommit,
               next.step?.status == .complete, next.readinessCommit != nil {
                retainCommitOutcome { $0.durable = next }
            }
            if next.phase == .recovery, next.readinessCommit != nil {
                retainCommitOutcome { $0.recovery = next }
            }
            try store.validate(pin, at: directory.descriptor.value, name: InstallationControlRecord.filename, isDirectory: false)
            try store.validateBindings()
            anchor = after.0; current = next; controlPin = pin
        }
        private func publish(_ proposed: Pending, store: CustodyCatalogStore,
                             deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            let requiresReady = proposed.receipt.receipt.action == .candidateReady
                || proposed.receipt.receipt.action == .readinessCommit
            if requiresReady {
                guard let candidateReady else { throw CustodyRecordError.fenced }
                try candidateReady.revalidate(for: self)
            }
            #if SHADOW_SYNC_TESTING
            let probe = testingPublicationProbe.flatMap {
                $0.action == proposed.receipt.receipt.action && $0.status == proposed.receipt.receipt.status ? $0 : nil
            }
            if let probe {
                try probe.begin(current, proposed.control, proposed.receipt.receipt)
                switch probe.failure {
                case .afterReceipt?: cut = .afterReceipt
                case .beforeControl?: cut = .beforeControl
                case .receiptBeforeSwap?: receiptFault = .beforeSwap
                case .receiptAfterSwap?: receiptFault = .afterSwap
                case .receiptAfterDirectorySync?: receiptFault = .afterDirectorySync
                case .controlBeforeSwap?: controlFault = .beforeSwap
                case .controlAfterSwap?: controlFault = .afterSwap
                case .controlAfterDirectorySync?: controlFault = .afterDirectorySync
                case .controlAfterPreimageUnlink?: controlFault = .afterPreimageUnlink
                case nil: break
                }
                try probe.pause(.beforeReceipt)
            }
            #endif
            try store.locked {
                try validateLocked(store, deadline); pending = proposed
                if proposed.control.phase == .committed, proposed.control.readinessCommit != nil {
                    retainCommitOutcome { $0.proposed = proposed.control }
                }
                #if SHADOW_SYNC_TESTING
                store.testingCut = receiptFault; receiptFault = nil
                #endif
                let receipt = proposed.receipt
                let bytes = try receipt.receipt.encode(uid: receipt.uid)
                try store.write(receipt.filename, at: receipts.descriptor.value, bytes: bytes, expected: nil)
                let pin = try InstallationJournalSession.retainReceipt(store, receipt)
                receiptPins[receipt.filename] = InstallationStagedAdmissionIntent.Evidence(node: pin, bytes: bytes)
                try validateLocked(store, deadline)
                #if SHADOW_SYNC_TESTING
                if cut == .afterReceipt { cut = nil; throw CustodyRecordError.injectedFailure }
                #endif
            }
            try validateSource(deadline)
            // Peer verification is outside the catalog guard, at the exact
            // receipt-to-control publication edge, under the same absolute budget.
            if requiresReady {
                guard let candidateReady else { throw CustodyRecordError.fenced }
                try candidateReady.revalidate(for: self)
            }
            #if SHADOW_SYNC_TESTING
            try probe?.pause(.afterReadyValidation)
            #endif
            return try store.locked {
                #if SHADOW_SYNC_TESTING
                // Bounded fixture-only stall of a real held catalog guard, as
                // for a slow write/fsync; no callback or verifier runs here.
                try probe?.pause(.insideControlGuard)
                #endif
                try validateLocked(store, deadline)
                guard let pending, let pin = receiptPins[pending.receipt.filename],
                      fsync(pin.node.descriptor.value) == 0, fsync(receipts.descriptor.value) == 0 else { throw CustodyRecordError.fenced }
                try current.validateReplacement(pending.control, receipts: chain + [pending.receipt.receipt], profile: owner.validationProfile)
                try replaceControl(pending.control, store: store, deadline: deadline)
                chain.append(pending.receipt.receipt); self.pending = nil
                return current
            }
        }
        func completeAdmission(deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            #if SHADOW_SYNC_TESTING
            var diagnosticStage: UInt8 = 1
            var diagnosticComplete = false
            defer {
                if !diagnosticComplete { InstallationReadinessEndpoint.testingRecordFailure(part: .journal, stage: diagnosticStage) }
            }
            #endif
            do {
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 2
            #endif
            let completed: (InstallationControlRecord, InstallationPrecommitSession) = try serialized(deadline: deadline,
                requiresOpenReadiness: true, fenceExpiredAdmission: true) { store in
                guard stop == nil, current.phase == .active, current.step?.action == .openStagedAdmission,
                      current.step?.ordinal == 12, current.step?.status == .intent,
                      let transaction = current.transaction, let candidate = transaction.candidate else { throw CustodyRecordError.fenced }
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 3
                #endif
                let endpoint = try slots.createReadinessEndpoint(for: owner, deadline: deadline)
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 4
                #endif
                try lockReadiness(deadline)
                readinessEndpoint = endpoint
                let closed = readinessClosed
                readinessMutex.unlock()
                guard !closed else { endpoint.closeService(); throw CustodyRecordError.fenced }
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 5
                #endif
                let record = try publish(proposal(.openStagedAdmission, status: .complete,
                    postimage: slots.readinessSnapshot), store: store, deadline: deadline)
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 6
                #endif
                let app = try InstallationPrecommitTransport.identity(candidate: candidate, coordinator: false,
                    team: transaction.coordinator.team)
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 7
                #endif
                let session = InstallationPrecommitSession(ReadinessContext(journal: self, endpoint: endpoint,
                    app: app, uid: current.state.directory.uid, deadline: deadline))
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 8
                #endif
                try lockReadiness(deadline)
                let canPublish = !readinessClosed && readinessSession == nil
                if canPublish { readinessSession = session }
                readinessMutex.unlock()
                guard canPublish else {
                    try session.cancelAndJoin(deadline: deadline)
                    throw CustodyRecordError.fenced
                }
                #if SHADOW_SYNC_TESTING
                diagnosticStage = 9
                #endif
                return (record, session)
            }
            // Reservation already exists before publication. Queue launch is a
            // one-shot race with cancellation and occurs outside all locks.
            #if SHADOW_SYNC_TESTING
            if let barrier = publicationBarrier {
                publicationBarrier = nil
                guard barrier.pause() else { try completed.1.cancelAndJoin(deadline: deadline); throw CustodyRecordError.busy }
            }
            #endif
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 10
            #endif
            guard completed.1.start() else { throw CustodyRecordError.fenced }
            #if SHADOW_SYNC_TESTING
            diagnosticComplete = true
            #endif
            return completed.0
            } catch {
                let original = error
                // Serialized work has unwound. Close/join actual session work
                // on every failure; a failed bounded join retains its owner.
                try closeReadiness(deadline: deadline)
                throw original
            }
        }
        /// Postflight for the original bootstrap's returned admission completion.
        /// This validates the exact journal generation and actual service owners,
        /// never issues a command/ready capability. This postflight checks the
        /// durable opening generation and retained owners; the running queue
        /// independently validates its live endpoint. completeAdmission already
        /// validated the full slot/socket postimage before launching that queue.
        func validateOpenedAdmission(_ completed: InstallationControlRecord,
                                     deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, stop == nil, !commandsClaimed,
                  current == completed, current.phase == .active,
                  current.step?.action == .openStagedAdmission,
                  current.step?.ordinal == 12, current.step?.status == .complete,
                  current.readinessCommit == nil else { mutex.unlock(); throw CustodyRecordError.fenced }
            let revision = metadataGeneration
            mutex.unlock()
            try lockReadiness(deadline)
            let session = readinessSession, endpoint = readinessEndpoint
            let open = !readinessClosed
            readinessMutex.unlock()
            guard open, let session, let endpoint else { throw CustodyRecordError.fenced }
            try admission.validateOwner(owner, intent: intent)
            try owner.revalidate()
            let store = try CustodyCatalogStore(leases: admission.retainStartLeases(), validationProfile: owner.validationProfile)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
                guard !serializing, !stoppedPinsReading, !failed, metadataGeneration == revision,
                      pending == nil, stop == nil, !commandsClaimed, current == completed else {
                    throw CustodyRecordError.fenced
                }
                try store.locked { try validateLocked(store, deadline) }
                mutex.unlock()
            } catch { mutex.unlock(); throw error }
            try admission.validateOwner(owner, intent: intent)
            try owner.revalidate()
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            let unchanged = !serializing && !failed && metadataGeneration == revision && current == completed
            mutex.unlock()
            try lockReadiness(deadline)
            let sameService = !readinessClosed && readinessSession === session && readinessEndpoint === endpoint
            readinessMutex.unlock()
            guard unchanged, sameService, !deadline.hasExpired else { throw CustodyRecordError.fenced }
        }
        private func observation(_ store: CustodyCatalogStore, deadline: MonotonicDeadline, committedStopDeadline: UInt64? = nil) throws -> InstallationStagedCommandObservation {
            try store.locked {
                try validateLocked(store, deadline)
                var nodes: [String: InstallationNodeIdentity] = [:]
                for (name, pin) in receiptPins where name.hasPrefix(InstallationStepReceipt.prefix) || name.hasPrefix(InstallationDocumentPreimage.prefix) {
                    nodes[name] = try store.installationCommandNode(pin.node.identity, acl: pin.node.acl)
                }
                let binding = try InstallationCommandBinding(control: current,
                    controlNode: store.installationCommandNode(anchor.identity, acl: anchor.acl), receiptNodes: nodes,
                    committedStopDeadline: committedStopDeadline, validationProfile: store.validationProfile)
                try store.validateInstallationCommand(binding)
                return InstallationStagedCommandObservation(session: self, binding: binding,
                    operationDeadline: deadline, ready: current.step?.action == .candidateReady ? candidateReady : nil)
            }
        }
        private func startIntent(_ action: InstallationAction, after previous: InstallationAction,
                                 deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            try serialized(deadline: deadline) { store in
                guard stop == nil, current.phase == .active, current.step?.action == previous,
                      current.step?.status == .complete else { throw CustodyRecordError.fenced }
                _ = try publish(proposal(action, status: .intent), store: store, deadline: deadline)
                return try observation(store, deadline: deadline)
            }
        }
        func bootstrapCandidateIntent(deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            try startIntent(.bootstrapCandidate, after: .openStagedAdmission, deadline: deadline)
        }
        func kickstartCandidateIntent(deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            try startIntent(.kickstartCandidate, after: .bootstrapCandidate, deadline: deadline)
        }
        /// Claim the actual current session's observation once, then publish the
        /// fixed diagnostic intent. No transcript/PID/boolean parameter is accepted.
        func candidateReadyIntent() throws -> InstallationStagedCommandObservation {
            let deadline: MonotonicDeadline
            guard readinessMutex.try() else { throw CustodyRecordError.busy }
            let session = readinessClosed ? nil : readinessSession; readinessMutex.unlock()
            guard let session else { throw CustodyRecordError.fenced }
            let ready = try session.takeReady(); deadline = ready.deadline
            try ready.revalidate(for: self)
            try validateReadiness(ready.control, deadline: deadline)
            return try serialized(deadline: deadline, requiresOpenReadiness: true) { store in
                guard candidateReady == nil, current == ready.control, stop == nil, !commandsClaimed else {
                    throw CustodyRecordError.fenced
                }
                try ready.revalidate(for: self)
                candidateReady = ready
                _ = try publish(proposal(.candidateReady, status: .intent), store: store, deadline: deadline)
                return try observation(store, deadline: deadline)
            }
        }
        /// No successful snapshot substitutes for this original registry token.
        /// Its scope must be destroyed, registry removed and every alias retired.
        func completeCandidateReady(after retired: RetainedCleanupRegistry.StagedRecoveryRetirement) throws -> InstallationControlRecord {
            let evidence = try retired.validate()
            guard evidence.observation.session === self, let ready = evidence.observation.ready else { throw CustodyRecordError.fenced }
            try ready.revalidate(for: self)
            try retired.validateReadyHost(ready.host)
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            return try serialized(deadline: ready.deadline, completionLeases: leases, requiresOpenReadiness: true) { store in
                guard candidateReady === ready, commandsClaimed, stop == nil,
                      current == evidence.observation.binding.control,
                      current.step?.action == .candidateReady, current.step?.status == .intent else { throw CustodyRecordError.fenced }
                try ready.revalidate(for: self)
                try store.locked {
                    try validateLocked(store, ready.deadline, command: true)
                    try refreshRecoveryPins(evidence, store: store, deadline: ready.deadline, diagnosticOnly: true)
                    try validateLocked(store, ready.deadline)
                }
                try ready.revalidate(for: self)
                let result = try publish(proposal(.candidateReady, status: .complete), store: store, deadline: ready.deadline)
                commandsClaimed = false
                return result
            }
        }
        /// Receipt-before-control/fsync is shared with every preceding edge.
        /// The commit references candidate-ready, never itself. This returns
        /// durable observation only; it sends no message or startup permission.
        func publishReadinessCommit() throws -> InstallationControlRecord {
            guard mutex.try() else { throw CustodyRecordError.busy }
            let observedReady = !serializing && !failed ? candidateReady : nil; mutex.unlock()
            guard let ready = observedReady else { throw CustodyRecordError.fenced }
            try ready.revalidate(for: self)
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            return try serialized(deadline: ready.deadline, completionLeases: leases, requiresOpenReadiness: true) { store in
                guard stop == nil, !commandsClaimed, current.phase == .active,
                      current.step?.action == .candidateReady, current.step?.status == .complete,
                      let completedDigest = current.latestReceiptDigest, let transaction = current.transaction,
                      let candidate = transaction.candidate, current.revision <= UInt64.max - 2 else { throw CustodyRecordError.fenced }
                try ready.revalidate(for: self)
                _ = try publish(proposal(.readinessCommit, status: .intent), store: store, deadline: ready.deadline)
                try ready.revalidate(for: self)
                let host = ready.host
                let commit = InstallationReadinessCommit(transactionID: transaction.id, commitRevision: current.revision + 1,
                    candidateReleaseDigest: candidate.release.releaseContractSHA256, candidateBundleDigest: candidate.bundleDigest,
                    candidateAppCDHash: candidate.appCDHash, candidateCoordinatorCDHash: candidate.coordinatorCDHash,
                    stateBindingDigest: try current.state.digest(), completedStepReceiptDigest: completedDigest,
                    host: InstallationProcessObservation(pid: UInt32(host.processID), uid: host.userID,
                        startSeconds: host.startSeconds, startMicroseconds: host.startMicroseconds, generation: host.generation),
                    precommitTranscriptDigest: ready.transcriptDigest)
                return try publish(proposal(.readinessCommit, status: .complete, commit: commit), store: store, deadline: ready.deadline)
            }
        }
        /// This original journal may only restrict its OWN fully durable commit.
        /// It cannot complete an uncertain write, adopt decoded state, restore,
        /// issue commands, clear the commit, or reopen a failed start gate.
        /// Expired/poisoned/ambiguous outcomes remain retained for repair-forward.
        func fenceReadinessCommitFailure() throws -> InstallationControlRecord {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, terminalProgress == .notAttempted,
                  current.step?.action != .finish, !postcommitFenceAttempted, pending == nil,
                  let ready = candidateReady, !ready.deadline.hasExpired,
                  current.phase == .committed, current.readinessCommit != nil,
                  !commandsClaimed, stop == nil, metadataGeneration < UInt64.max else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let deadline = ready.deadline
            serializing = true; failed = true; metadataGeneration += 1
            postcommitFenceAttempted = true
            mutex.unlock()
            retainCommitOutcome { $0.recoveryAttempted = true }
            defer {
                // Permanent closure, never drainage proof. It is safe even if
                // bounded failure prevented the restrictive control publication.
                _ = try? admission.closeStarts()
                mutex.lock(); serializing = false; mutex.unlock()
            }
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            let store = try CustodyCatalogStore(leases: leases, validationProfile: owner.validationProfile)
            return try publishPostcommitFailure(store: store, deadline: deadline)
        }
        private func recordPostcommitFailure(store: CustodyCatalogStore,
                                            deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            guard !postcommitFenceAttempted else { throw CustodyRecordError.fenced }
            postcommitFenceAttempted = true
            retainCommitOutcome { $0.recoveryAttempted = true }
            return try publishPostcommitFailure(store: store, deadline: deadline)
        }
        private func publishPostcommitFailure(store: CustodyCatalogStore,
                                             deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            guard !deadline.hasExpired, let ready = candidateReady,
                  deadline.absoluteUptimeNanoseconds <= ready.deadline.absoluteUptimeNanoseconds,
                  pending == nil, !commandsClaimed,
                  current.phase == .committed, current.readinessCommit != nil,
                  current.readinessCommit == readinessCommitOutcome().durable?.readinessCommit,
                  current.transaction?.id == readinessCommitOutcome().durable?.transaction?.id,
                  current.revision < UInt64.max else { throw CustodyRecordError.fenced }
            // A slot or peer postflight may have failed. Recording that failure
            // preserves the exact old slot evidence; it grants no convergence.
            // Live original source/state authority and every metadata pin remain
            // mandatory. No code verification or wait runs under catalog.lock.
            try owner.revalidate()
            let next = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                state: current.state, transaction: current.transaction, step: current.step,
                latestReceiptDigest: current.latestReceiptDigest, readinessCommit: current.readinessCommit,
                recoveryReason: .startupUncertain)
            try current.validateReplacement(next, receipts: chain, profile: owner.validationProfile)
            retainCommitOutcome { $0.recoveryProposed = next }
            try store.locked {
                try validateLocked(store, deadline)
                try replaceControl(next, store: store, deadline: deadline)
            }
            try owner.revalidate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            continuationRecovery = try StopDelivery(journal: self, store: store, control: next)
            return next
        }
        /// A separate post-publication edge. Never infer delivery from durable
        /// commit, retry a failed send, or turn transport failure into rollback.
        /// The retained Bootstrap owns its continuation; CLI remains unenrolled.
        func deliverReadinessCommit() throws -> InstallationPrecommitSession.CommitDelivered {
            // The helper returns only the capability: its temporary completion
            // leases/store have been destroyed before enqueue or any waiting.
            let delivery = try reserveCommitDelivery()
            return try delivery.deliver()
        }
        private func reserveCommitDelivery() throws -> CommitDelivery {
            guard mutex.try() else { throw CustodyRecordError.busy }
            let observed = !serializing && !failed && !commitDeliveryReserved ? candidateReady : nil
            mutex.unlock()
            guard let ready = observed else { throw CustodyRecordError.fenced }
            try ready.revalidate(for: self)
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            let delivery = try serialized(deadline: ready.deadline, completionLeases: leases,
                requiresOpenReadiness: true) { store in
                guard !commitDeliveryReserved, candidateReady === ready, stop == nil, !commandsClaimed,
                      current == (try ready.expectedCommittedControl()) else { throw CustodyRecordError.fenced }
                // validateLocked checks exact current control bytes/inode/ACL,
                // complete receipt/document chain, pinned file set and empty
                // retired catalog. Publication already fsynced file+directories.
                try store.locked { try validateLocked(store, ready.deadline) }
                commitDeliveryReserved = true
                return CommitDelivery(journal: self, ready: ready, control: current)
            }
            // Serialization/postflight is over before enqueue or any waiting.
            // Close may win this gap; then the sole session rejects submission.
            return delivery
        }
        private func validateCommitDelivery(_ delivery: CommitDelivery,
                                           ready: InstallationPrecommitSession.ReadyObservation) throws {
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStart)
            try serialized(deadline: ready.deadline, completionLeases: leases,
                requiresOpenReadiness: true) { store in
                guard delivery.matches(journal: self, ready: ready), commitDeliveryReserved,
                      candidateReady === ready, stop == nil, !commandsClaimed,
                      current == delivery.control, current == (try ready.expectedCommittedControl()) else {
                    throw CustodyRecordError.fenced
                }
                try store.locked { try validateLocked(store, ready.deadline) }
            }
        }
        /// Mint once from this journal's actual fsynced recovery publication.
        /// No decoded control, caller Boolean or new owner is accepted. The
        /// original failed flag stays set, permanently fencing forward methods.
        func committedCandidateStop(admission stop: InstallationStagedStopAdmission) throws -> InstallationCommittedStop {
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, !commandsClaimed,
                  terminalProgress == .notAttempted, !committedStopAttempted,
                  self.stop == nil, let delivery = continuationRecovery,
                  let ready = candidateReady, !ready.deadline.hasExpired,
                  postcommitFenceAttempted, current == delivery.control,
                  current.phase == .recovery, current.readinessCommit != nil,
                  current.step?.action != .finish, metadataGeneration < UInt64.max else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            committedStopAttempted = true; serializing = true; metadataGeneration += 1
            mutex.unlock()
            defer { mutex.lock(); serializing = false; mutex.unlock() }
            do {
                try stop.validateOwner(owner)
                self.stop = stop
                return try withStore(deadline: ready.deadline) { store in
                    let observed = try observation(store, deadline: ready.deadline,
                        committedStopDeadline: ready.deadline.absoluteUptimeNanoseconds)
                    let capability = InstallationCommittedStop(observation: observed, stop: stop, deadline: ready.deadline)
                    committedStop = capability
                    return capability
                }
            } catch { committedStopFailed = true; throw error }
        }
        /// A distinct restrictive turn, never a reset of serialized/failed.
        /// It cannot publish installation actions or recover uncertain writes.
        private func withCommittedStop<T>(_ capability: InstallationCommittedStop,
            deadline supplied: MonotonicDeadline? = nil,
            completionLeases: CustodyAuthorityLeaseSet? = nil, _ body: (CustodyCatalogStore) throws -> T) throws -> T {
            let deadline = supplied.map {
                $0.absoluteUptimeNanoseconds < capability.deadline.absoluteUptimeNanoseconds ? $0 : capability.deadline
            } ?? capability.deadline
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, !committedStopFailed,
                  committedStop === capability, committedStopAttempted, !committedStopRetired,
                  stop === capability.stop, terminalProgress == .notAttempted,
                  continuationRecovery?.control == current,
                  current == capability.observation.binding.control,
                  current.phase == .recovery, current.readinessCommit != nil,
                  current.step?.action != .finish, metadataGeneration < UInt64.max else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            serializing = true; metadataGeneration += 1; mutex.unlock()
            defer { mutex.lock(); serializing = false; mutex.unlock() }
            do { return try withStore(deadline: deadline, completionLeases: completionLeases, body) }
            catch { committedStopFailed = true; throw error }
        }
        fileprivate func committedStopDeadline(for observation: InstallationStagedCommandObservation) -> MonotonicDeadline? {
            mutex.lock(); defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, committedStop?.observation === observation else { return nil }
            return committedStop?.deadline
        }
        fileprivate func committedStopPermit(_ capability: InstallationCommittedStop) throws -> InstallationCommandPermit {
            try withCommittedStop(capability) { store in
                guard !commandsClaimed else { throw CustodyRecordError.fenced }
                try store.locked {
                    try validateLocked(store, capability.deadline)
                    try store.validateInstallationCommand(capability.observation.binding)
                }
                commandsClaimed = true
                return InstallationCommandPermit(staged: capability.observation)
            }
        }
        /// Retire a failed/cancelled/timed-out bounded command family without
        /// converting its outcome to success or granting another command claim.
        func retireCommittedCandidateStop(_ capability: InstallationCommittedStop,
            after retired: RetainedCleanupRegistry.StagedRecoveryRetirement) throws {
            let evidence = try retired.validate()
            guard evidence.observation === capability.observation else { throw CustodyRecordError.fenced }
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            try withCommittedStop(capability, completionLeases: leases) { store in
                guard commandsClaimed else { throw CustodyRecordError.fenced }
                try store.locked {
                    try validateLocked(store, capability.deadline, command: true)
                    try refreshRecoveryPins(evidence, store: store, deadline: capability.deadline, diagnosticOnly: false)
                    try validateLocked(store, capability.deadline)
                }
                commandsClaimed = false; committedStopRetired = true
            }
        }
        func completeCommittedCandidateStop(_ capability: InstallationCommittedStop,
            after retired: RetainedCleanupRegistry.StagedCommandCompletion) throws -> InstallationCommittedStopCompletion {
            let evidence = try retired.validate(operation: .bootout)
            guard evidence.observation === capability.observation else { throw CustodyRecordError.fenced }
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            return try withCommittedStop(capability, completionLeases: leases) { store in
                guard commandsClaimed else { throw CustodyRecordError.fenced }
                try store.locked {
                    try validateLocked(store, capability.deadline, command: true)
                    try refreshRetiredPins(evidence, store: store, deadline: capability.deadline)
                    try validateLocked(store, capability.deadline)
                }
                let completed = InstallationCommittedStopCompletion(capability, retired)
                // Command archives advance only the command catalog. No call to
                // proposal/publish and no candidate-stop installation receipt.
                commandsClaimed = false; committedStopRetired = true
                committedStopCompletion = completed
                return completed
            }
        }
        /// No decoded control or scalar registry observation can create this.
        /// It retains all four causal owners through exclusive reentry.
        final class CandidateDrain {
            fileprivate let journal: InstallationStagedJournal
            fileprivate let acknowledgment: InstallationPrecommitSession.Stopped
            fileprivate let delivery: StopDelivery
            fileprivate let command: InstallationCommittedStopCompletion
            fileprivate let retirement: RetainedCleanupRegistry.InstallationStagedStopRetirement
            fileprivate let registry: RetainedCleanupRegistry
            fileprivate let pins: StoppedPins
            fileprivate init(_ journal: InstallationStagedJournal,
                acknowledgment: InstallationPrecommitSession.Stopped, delivery: StopDelivery,
                command: InstallationCommittedStopCompletion,
                retirement: RetainedCleanupRegistry.InstallationStagedStopRetirement,
                registry: RetainedCleanupRegistry, pins: StoppedPins) {
                self.journal = journal; self.acknowledgment = acknowledgment; self.delivery = delivery
                self.command = command; self.retirement = retirement; self.registry = registry; self.pins = pins
            }
        }
        final class StoppedRecoveryIntent {
            private enum Evidence { case committed(CandidateDrain), readiness(ReadinessCandidateDrain) }
            private let evidence: Evidence
            private let lock = NSLock()
            private var claimed = false
            var deadline: MonotonicDeadline {
                switch evidence {
                case .committed(let drain): return drain.acknowledgment.deadline
                case .readiness(let drain): return drain.acknowledgment.deadline
                }
            }
            fileprivate init(_ drain: CandidateDrain) { evidence = .committed(drain) }
            fileprivate init(_ drain: ReadinessCandidateDrain) { evidence = .readiness(drain) }
            func revalidate(for owner: InstallationTransactionOwner) throws {
                switch evidence {
                case .committed(let drain):
                    guard drain.journal.owner === owner else { throw CustodyRecordError.fenced }
                    try drain.journal.validateCandidateDrain(drain)
                case .readiness(let drain):
                    guard drain.journal.owner === owner else { throw CustodyRecordError.fenced }
                    try drain.journal.validateReadinessCandidateDrain(drain)
                }
            }
            func matchesCommittedDrain(_ drain: CandidateDrain) -> Bool {
                guard case .committed(let original) = evidence else { return false }
                return original === drain
            }
            func matchesReadinessDrain(_ drain: ReadinessCandidateDrain) -> Bool {
                guard case .readiness(let original) = evidence else { return false }
                return original === drain
            }
            func claim(for owner: InstallationTransactionOwner) throws {
                try revalidate(for: owner)
                guard lock.try() else { throw CustodyRecordError.busy }; defer { lock.unlock() }
                guard !claimed else { throw CustodyRecordError.fenced }; claimed = true
            }
        }
        private var candidateDrain: CandidateDrain?
        private var drainAttempted = false
        private var recoveryIntentIssued = false
        /// The successful bootout completion is journal-owned, so a caller cannot
        /// substitute another handle or a failed-command retirement here.
        func committedCandidateDrain(retirement: RetainedCleanupRegistry.InstallationStagedStopRetirement,
            registry: RetainedCleanupRegistry) throws -> CandidateDrain {
            guard mutex.try() else { throw CustodyRecordError.busy }
            let retainedDelivery = continuationRecovery; mutex.unlock()
            guard let acknowledgment = retainedDelivery?.observation.0 else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, !drainAttempted,
                  terminalProgress == .notAttempted, committedStopRetired, !commandsClaimed,
                  !committedStopFailed, let command = committedStopCompletion,
                  command.capability === committedStop, let delivery = continuationRecovery,
                  current == delivery.control, acknowledgment.control == current,
                  current.phase == .recovery, current.readinessCommit != nil,
                  current.step?.action == .readinessCommit, current.step?.status == .complete,
                  command.capability.deadline.absoluteUptimeNanoseconds == acknowledgment.deadline.absoluteUptimeNanoseconds else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            // This bounded slice handles the original normal-started stream,
            // before coordination cleanup. Cleanup cuts need their own retained
            // causal reconciliation; they cannot be silently adopted here.
            drainAttempted = true
            let pins = stoppedPins(); mutex.unlock()
            let drain = CandidateDrain(self, acknowledgment: acknowledgment, delivery: delivery,
                command: command, retirement: retirement, registry: registry, pins: pins)
            try delivery.validateCompleted(acknowledgment)
            try retirement.revalidate(for: owner, registry: registry)
            try validateStoppedPins(pins, deadline: acknowledgment.deadline)
            try slots.revalidateStopped(for: owner, acknowledgment: acknowledgment, delivery: delivery)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, candidateDrain == nil,
                  metadataGeneration == pins.generation, current == pins.control,
                  terminalProgress == .notAttempted, committedStopCompletion === command,
                  continuationRecovery === delivery else { throw CustodyRecordError.fenced }
            candidateDrain = drain
            return drain
        }
        func stoppedRecoveryIntent(after drain: CandidateDrain) throws -> StoppedRecoveryIntent {
            try validateCandidateDrain(drain)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard candidateDrain === drain, !recoveryIntentIssued else { throw CustodyRecordError.fenced }
            recoveryIntentIssued = true
            return StoppedRecoveryIntent(drain)
        }
        private func validateCandidateDrain(_ drain: CandidateDrain) throws {
            guard drain.journal === self, !drain.acknowledgment.deadline.hasExpired else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            let valid = !serializing && failed && pending == nil && candidateDrain === drain
                && terminalProgress == .notAttempted && metadataGeneration == drain.pins.generation
                && current == drain.pins.control && committedStopCompletion === drain.command
                && continuationRecovery === drain.delivery && committedStopRetired && !commandsClaimed
            mutex.unlock()
            guard valid else { throw CustodyRecordError.fenced }
            try drain.delivery.validateCompleted(drain.acknowledgment)
            try drain.retirement.revalidate(for: owner, registry: drain.registry)
            try validateStoppedPins(drain.pins, deadline: drain.acknowledgment.deadline)
            try slots.revalidateStopped(for: owner, acknowledgment: drain.acknowledgment, delivery: drain.delivery)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, pending == nil, candidateDrain === drain, failed,
                  metadataGeneration == drain.pins.generation, current == drain.pins.control,
                  terminalProgress == .notAttempted else { throw CustodyRecordError.fenced }
        }
        final class ReadinessCandidateDrain {
            fileprivate let journal: InstallationStagedJournal
            fileprivate let acknowledgment: InstallationPrecommitSession.Stopped
            fileprivate let delivery: StopDelivery
            fileprivate let command: RetainedCleanupRegistry.StagedCommandCompletion
            fileprivate let retirement: RetainedCleanupRegistry.InstallationStagedStopRetirement
            fileprivate let registry: RetainedCleanupRegistry
            fileprivate let pins: StoppedPins
            fileprivate init(_ journal: InstallationStagedJournal, acknowledgment: InstallationPrecommitSession.Stopped,
                delivery: StopDelivery, command: RetainedCleanupRegistry.StagedCommandCompletion,
                retirement: RetainedCleanupRegistry.InstallationStagedStopRetirement,
                registry: RetainedCleanupRegistry, pins: StoppedPins) {
                self.journal = journal; self.acknowledgment = acknowledgment; self.delivery = delivery
                self.command = command; self.retirement = retirement; self.registry = registry; self.pins = pins
            }
        }
        private var readinessStopCompletion: RetainedCleanupRegistry.StagedCommandCompletion?
        private var readinessDrain: ReadinessCandidateDrain?
        func readinessCandidateDrain(retirement: RetainedCleanupRegistry.InstallationStagedStopRetirement,
            registry: RetainedCleanupRegistry) throws -> ReadinessCandidateDrain {
            guard mutex.try() else { throw CustodyRecordError.busy }
            let retainedDelivery = continuationRecovery; mutex.unlock()
            guard let delivery = retainedDelivery, delivery.isReadinessOnly,
                  let acknowledgment = delivery.observation.0 else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, !drainAttempted,
                  terminalProgress == .notAttempted, !commandsClaimed, stop != nil,
                  let command = readinessStopCompletion, continuationRecovery === delivery,
                  current.phase == .recovery, current.readinessCommit == nil,
                  current.step?.action == .candidateStop, current.step?.status == .complete,
                  current.step?.ordinal == 16 else { mutex.unlock(); throw CustodyRecordError.fenced }
            drainAttempted = true; failed = true
            let pins = stoppedPins(); mutex.unlock()
            let drain = ReadinessCandidateDrain(self, acknowledgment: acknowledgment, delivery: delivery,
                command: command, retirement: retirement, registry: registry, pins: pins)
            try delivery.validateCompleted(acknowledgment)
            try retirement.revalidate(for: owner, registry: registry)
            try validateStoppedPins(pins, deadline: acknowledgment.deadline)
            try slots.revalidateStopped(for: owner, acknowledgment: acknowledgment, delivery: delivery)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, readinessDrain == nil,
                  metadataGeneration == pins.generation, current == pins.control,
                  readinessStopCompletion === command, continuationRecovery === delivery else { throw CustodyRecordError.fenced }
            readinessDrain = drain
            return drain
        }
        func stoppedRecoveryIntent(after drain: ReadinessCandidateDrain) throws -> StoppedRecoveryIntent {
            try validateReadinessCandidateDrain(drain)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard readinessDrain === drain, !recoveryIntentIssued else { throw CustodyRecordError.fenced }
            recoveryIntentIssued = true
            return StoppedRecoveryIntent(drain)
        }
        private func validateReadinessCandidateDrain(_ drain: ReadinessCandidateDrain) throws {
            guard drain.journal === self, !drain.acknowledgment.deadline.hasExpired else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            let valid = !serializing && failed && pending == nil && readinessDrain === drain
                && terminalProgress == .notAttempted && metadataGeneration == drain.pins.generation
                && current == drain.pins.control && readinessStopCompletion === drain.command
                && continuationRecovery === drain.delivery && !commandsClaimed && stop != nil
            mutex.unlock()
            guard valid else { throw CustodyRecordError.fenced }
            try drain.delivery.validateCompleted(drain.acknowledgment)
            try drain.retirement.revalidate(for: owner, registry: drain.registry)
            try validateStoppedPins(drain.pins, deadline: drain.acknowledgment.deadline)
            try slots.revalidateStopped(for: owner, acknowledgment: drain.acknowledgment, delivery: drain.delivery)
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, failed, pending == nil, readinessDrain === drain,
                  metadataGeneration == drain.pins.generation, current == drain.pins.control,
                  terminalProgress == .notAttempted else { throw CustodyRecordError.fenced }
        }
        fileprivate struct StoppedPins {
            let generation: UInt64
            let control: InstallationControlRecord
            let controlPin: InstallationStagedAdmissionIntent.Evidence
            let catalog: InstallationStagedAdmissionIntent.Evidence
            let receipts: [String: InstallationStagedAdmissionIntent.Evidence]
            let chain: [InstallationStepReceipt]
        }
        // Caller takes the short journal mutex solely for this immutable snapshot.
        private func stoppedPins() -> StoppedPins {
            StoppedPins(generation: metadataGeneration, control: current,
                controlPin: .init(node: controlPin, bytes: anchor.bytes), catalog: catalogPin,
                receipts: receiptPins, chain: chain)
        }
        private var stoppedPinsReading = false
        private func validateStoppedPins(_ pins: StoppedPins, deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, metadataGeneration == pins.generation else {
                mutex.unlock(); throw CustodyRecordError.busy
            }
            // One reader owns this exact catalog guard description. flock on
            // the same open description is not mutual exclusion between readers.
            stoppedPinsReading = true; mutex.unlock()
            defer { mutex.lock(); stoppedPinsReading = false; mutex.unlock() }
            try owner.revalidate()
            guard try InstallationControlRecord.decode(pins.controlPin.bytes, profile: owner.validationProfile) == pins.control else {
                throw CustodyRecordError.conflict
            }
            try pins.control.validateReceiptChain(pins.chain, profile: owner.validationProfile)
            try validatePinnedMetadata(pins, deadline: deadline)
            try owner.revalidate()
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            let unchanged = !serializing && stoppedPinsReading && metadataGeneration == pins.generation && current == pins.control
            mutex.unlock()
            guard unchanged else { throw CustodyRecordError.fenced }
        }
        // The caller owns stoppedPinsReading throughout this metadata-only I/O.
        // Factoring avoids recursively taking the same exclusive reader claim.
        private func validatePinnedMetadata(_ pins: StoppedPins, deadline: MonotonicDeadline) throws {
            let uid = directory.identity.owner
            func validateNode(_ node: Node, parent: Int32, name: String, isDirectory: Bool) throws {
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                let observed = try CustodyCatalogStore.node(node.descriptor, uid: uid, directory: isDirectory)
                var named = stat()
                guard observed.identity.matchesStableNode(node.identity), observed.acl == node.acl,
                      fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      FileIdentity(named).matchesStableNode(node.identity), isDirectory || named.st_nlink == 1 else {
                    throw CustodyRecordError.unsafeMetadata
                }
            }
            func validatePin(_ pin: InstallationStagedAdmissionIntent.Evidence, parent: Int32, name: String) throws {
                try validateNode(pin.node, parent: parent, name: name, isDirectory: false)
                var before = stat(), after = stat()
                guard fstat(pin.node.descriptor.value, &before) == 0, before.st_size == pin.bytes.count,
                      pin.bytes.count <= InstallationDocumentPreimage.maximumBytes else { throw CustodyRecordError.conflict }
                var bytes = Data(count: pin.bytes.count)
                try bytes.withUnsafeMutableBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                        let count = pread(pin.node.descriptor.value, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw CustodyRecordError.persistence(errno) }; offset += count
                    }
                }
                guard fstat(pin.node.descriptor.value, &after) == 0, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                      bytes == pin.bytes else { throw CustodyRecordError.conflict }
                try validateNode(pin.node, parent: parent, name: name, isDirectory: false)
            }
            try validateNode(directory, parent: intent.root.value, name: "custody", isDirectory: true)
            try validateNode(guardFile, parent: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
            // This nonblocking catalog turn contains metadata reads only. Owner,
            // publisher, registry and session checks run outside the catalog lock.
            guard flock(guardFile.descriptor.value, LOCK_EX | LOCK_NB) == 0 else { throw CustodyRecordError.busy }
            do {
                defer { _ = flock(guardFile.descriptor.value, LOCK_UN) }
                try validateNode(guardFile, parent: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
                try validateNode(receipts, parent: directory.descriptor.value, name: "receipts", isDirectory: true)
                try validatePin(pins.controlPin, parent: directory.descriptor.value, name: InstallationControlRecord.filename)
                try validatePin(pins.catalog, parent: directory.descriptor.value, name: "catalog.json")
                guard try CustodyCatalog.decode(pins.catalog.bytes).entries.isEmpty,
                      try InstallationStagedAdmissionIntent.names(receipts.descriptor.value) == Set(pins.receipts.keys) else {
                    throw CustodyRecordError.conflict
                }
                for (name, pin) in pins.receipts { try validatePin(pin, parent: receipts.descriptor.value, name: name) }
                try validateNode(directory, parent: intent.root.value, name: "custody", isDirectory: true)
            }
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
        func candidateStopIntent(admission stop: InstallationStagedStopAdmission,
                                 deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil, metadataGeneration < UInt64.max,
                  (self.stop == nil && current.phase == .active)
                    || (self.stop === stop && current.phase == .recovery && reconciledStart),
                  current.step?.status == .complete,
                  [.openStagedAdmission, .bootstrapCandidate, .kickstartCandidate, .candidateReady].contains(current.step!.action),
                  current.step?.action != .candidateReady || (candidateReady != nil
                    && deadline.absoluteUptimeNanoseconds <= candidateReady!.deadline.absoluteUptimeNanoseconds
                    && !candidateReady!.deadline.hasExpired) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let generation = metadataGeneration; mutex.unlock()
            try stop.validateOwner(owner)
            // Join the original readiness service before slot revalidation. Its
            // accept queue also validates this endpoint, independently of journal
            // serialization. No metadata/catalog/service lock spans this join.
            // Closure is not candidate-stop proof; the durable stop command and
            // its authenticated retirement remain required below.
            try closeReadiness(deadline: deadline)
            try stop.validateOwner(owner)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, metadataGeneration == generation, !failed, pending == nil,
                  (self.stop == nil && current.phase == .active)
                    || (self.stop === stop && current.phase == .recovery && reconciledStart),
                  current.step?.status == .complete,
                  [.openStagedAdmission, .bootstrapCandidate, .kickstartCandidate, .candidateReady].contains(current.step!.action),
                  current.step?.action != .candidateReady || (candidateReady != nil
                    && deadline.absoluteUptimeNanoseconds <= candidateReady!.deadline.absoluteUptimeNanoseconds
                    && !candidateReady!.deadline.hasExpired) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            self.stop = stop; metadataGeneration += 1; mutex.unlock()
            return try serialized(deadline: deadline) { store in
                if current.phase == .active {
                    let recovery = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                        state: current.state, transaction: current.transaction, step: current.step,
                        latestReceiptDigest: current.latestReceiptDigest, readinessCommit: nil, recoveryReason: .readinessFailed)
                    try current.validateReplacement(recovery, receipts: chain, profile: owner.validationProfile)
                    try store.locked { try validateLocked(store, deadline); try replaceControl(recovery, store: store, deadline: deadline) }
                }
                _ = try publish(proposal(.candidateStop, status: .intent), store: store, deadline: deadline)
                return try observation(store, deadline: deadline)
            }
        }
        fileprivate func validate(_ observation: InstallationStagedCommandObservation, deadline: MonotonicDeadline) throws {
            if observation.binding.isCommittedStop {
                mutex.lock(); let retained = serializing ? nil : committedStop; mutex.unlock()
                guard let capability = retained, capability.observation === observation else { throw CustodyRecordError.fenced }
                let bounded = deadline.absoluteUptimeNanoseconds < capability.deadline.absoluteUptimeNanoseconds
                    ? deadline : capability.deadline
                try withCommittedStop(capability, deadline: bounded) { store in
                    try store.locked {
                        try validateLocked(store, bounded, command: commandsClaimed)
                        try store.validateInstallationCommand(observation.binding)
                    }
                }
                return
            }
            try observation.ready?.revalidate(for: self)
            try serialized(deadline: deadline) { store in
                guard current == observation.binding.control else { throw CustodyRecordError.fenced }
                try store.locked { try validateLocked(store, deadline, command: commandsClaimed || recoveryDiagnosticClaimed); try store.validateInstallationCommand(observation.binding) }
            }
        }
        fileprivate func commandHelper() throws -> CustodyHelperExecutable {
            try owner.stagedCommandHelper(mode: stop == nil ? .installationStagedStart : .installationStagedStop)
        }
        fileprivate func commandPermit(_ observation: InstallationStagedCommandObservation,
            admission candidate: InstallationStagedAdmission?, stop candidateStop: InstallationStagedStopAdmission?,
            deadline: MonotonicDeadline) throws -> InstallationCommandPermit {
            try serialized(deadline: deadline) { store in
                guard !observation.binding.isCommittedStop, !commandsClaimed, current == observation.binding.control else { throw CustodyRecordError.fenced }
                if let stop {
                    guard candidate == nil, candidateStop === stop, observation.binding.stagedMode == .installationStagedStop else { throw CustodyRecordError.fenced }
                    try stop.validateOwner(owner)
                } else {
                    guard candidate === admission, candidateStop == nil, observation.binding.stagedMode == .installationStagedStart else { throw CustodyRecordError.fenced }
                    try admission.validateOwner(owner, intent: intent)
                }
                try store.locked { try validateLocked(store, deadline); try store.validateInstallationCommand(observation.binding) }
                commandsClaimed = true
                return InstallationCommandPermit(staged: observation)
            }
        }
        /// Close starts and obtain stop-only admission BEFORE calling. A missing
        /// command token is accepted only when this original journal never issued
        /// its one-use start permit. Empty catalog/PID absence is not that proof.
        func beginStartRecovery(admission stop: InstallationStagedStopAdmission,
            after retired: RetainedCleanupRegistry.StagedRecoveryRetirement? = nil,
            deadline: MonotonicDeadline) throws -> InstallationStagedRecovery {
            let evidence = try retired?.validate()
            if let evidence { guard evidence.observation.session === self else { throw CustodyRecordError.fenced } }
            try stop.validateOwner(owner)
            try owner.validateStagedCommandAliasesRetired()
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, metadataGeneration < UInt64.max,
                  !failed, pending == nil, self.stop == nil, recovery == nil,
                  current.phase == .active, current.step?.status == .intent,
                  current.step?.action == .bootstrapCandidate || current.step?.action == .kickstartCandidate,
                  commandsClaimed == (evidence != nil),
                  evidence == nil || evidence!.observation.binding.control == current else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let generation = metadataGeneration; mutex.unlock()
            // Starts are already permanently closed and their actual commands
            // retired. Join this original readiness queue before recovery slot
            // validation: its deadline/exit closes the service independently of
            // journal serialization and would invalidate a crossing reader.
            // Use the caller's same absolute budget, with no catalog, registry,
            // authority or journal mutex held and no completion lease borrowed.
            try closeReadiness(deadline: deadline)
            try stop.validateOwner(owner)
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
                guard !serializing, !stoppedPinsReading, metadataGeneration == generation,
                      metadataGeneration < UInt64.max, !failed, pending == nil, self.stop == nil, recovery == nil,
                      current.phase == .active, current.step?.status == .intent,
                      current.step?.action == .bootstrapCandidate || current.step?.action == .kickstartCandidate,
                      commandsClaimed == (evidence != nil),
                      evidence == nil || evidence!.observation.binding.control == current else { throw CustodyRecordError.fenced }
                self.stop = stop; metadataGeneration += 1
                recoveryStartMayHaveExecuted = evidence?.commands.contains {
                    $0.request.kind == .launchctlMutation && $0.mayHaveExecuted
                } ?? false
                mutex.unlock()
            } catch { mutex.unlock(); throw error }
            return try serialized(deadline: deadline, completionLeases: leases) { store in
                try store.locked {
                    try validateLocked(store, deadline, command: commandsClaimed)
                    if let evidence { try refreshRecoveryPins(evidence, store: store, deadline: deadline, diagnosticOnly: false) }
                    try validateLocked(store, deadline)
                    let next = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                        state: current.state, transaction: current.transaction, step: current.step,
                        latestReceiptDigest: current.latestReceiptDigest, readinessCommit: nil, recoveryReason: .interrupted)
                    try current.validateReplacement(next, receipts: chain, profile: owner.validationProfile)
                    try replaceControl(next, store: store, deadline: deadline)
                }
                let capability = InstallationStagedRecovery(observation: try observation(store, deadline: deadline), stop: stop)
                recovery = capability
                return capability
            }
        }
        fileprivate func recoveryDiagnosticPermit(_ capability: InstallationStagedRecovery,
            deadline: MonotonicDeadline) throws -> InstallationCommandPermit {
            try serialized(deadline: deadline) { store in
                guard recovery === capability, !recoveryDiagnosticClaimed, !reconciledStart,
                      current == capability.observation.binding.control, current.phase == .recovery,
                      current.step?.status == .intent else { throw CustodyRecordError.fenced }
                try store.locked { try validateLocked(store, deadline); try store.validateInstallationCommand(capability.observation.binding) }
                recoveryDiagnosticClaimed = true
                return InstallationCommandPermit(staged: capability.observation)
            }
        }
        func reconcileStart(_ capability: InstallationStagedRecovery,
            after diagnostic: RetainedCleanupRegistry.StagedRecoveryRetirement,
            deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            let evidence = try diagnostic.validate()
            guard evidence.observation.session === self,
                  evidence.observation === capability.observation,
                  let action = evidence.observation.binding.control.step?.action else { throw CustodyRecordError.fenced }
            // Fresh fixed print ran AFTER durable recovery and closed starts.
            // Parsed output/raw status is separate from the mutation's archive.
            let layout = try diagnostic.classify(action)
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            return try serialized(deadline: deadline, completionLeases: leases) { store in
                guard recovery === capability, recoveryDiagnosticClaimed, !reconciledStart,
                      current == evidence.observation.binding.control, current.phase == .recovery,
                      current.step?.status == .intent else { throw CustodyRecordError.fenced }
                if !recoveryStartMayHaveExecuted {
                    // Actual no-reservation/no-resume authority cannot explain
                    // an after-state. A foreign actor's change is a third state.
                    switch (action, layout) {
                    case (.bootstrapCandidate, .before), (.kickstartCandidate, .unchangedLoaded): break
                    default: throw CustodyRecordError.fenced
                    }
                }
                try store.locked {
                    try validateLocked(store, deadline, command: true)
                    try refreshRecoveryPins(evidence, store: store, deadline: deadline, diagnosticOnly: true)
                    try validateLocked(store, deadline)
                }
                let resolved = try publish(proposal(action, status: .complete), store: store, deadline: deadline)
                // Only the resolved recovery path can now issue candidate-stop.
                // The permanent owner start gate and actual outcomes stay closed.
                reconciledStart = true; commandsClaimed = false; recoveryDiagnosticClaimed = false
                return resolved
            }
        }
        /// Exact positively absent observation resolves candidate-stop as a no-op.
        /// No bootout is issued and no successful mutation token is manufactured.
        func completeAbsentCandidateStop(after diagnostic: RetainedCleanupRegistry.StagedRecoveryRetirement,
            deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            let evidence = try diagnostic.validate()
            guard evidence.observation.session === self, case .absent = try diagnostic.serviceState() else { throw CustodyRecordError.fenced }
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            return try serialized(deadline: deadline, completionLeases: leases) { store in
                guard stop != nil, commandsClaimed, current == evidence.observation.binding.control,
                      current.phase == .recovery, current.step?.action == .candidateStop,
                      current.step?.status == .intent else { throw CustodyRecordError.fenced }
                try store.locked {
                    try validateLocked(store, deadline, command: true)
                    try refreshRecoveryPins(evidence, store: store, deadline: deadline, diagnosticOnly: true)
                    try validateLocked(store, deadline)
                }
                let resolved = try publish(proposal(.candidateStop, status: .complete), store: store, deadline: deadline)
                commandsClaimed = false
                return resolved
            }
        }
        /// Accept only exact successors from real registry archives. Recovery
        /// preserves all outcomes/reasons; this does not reuse success validation.
        fileprivate func validateClosedStopArchives(_ evidence: ClosedStopArchiveEvidence,
            closed: ClosedInstallationStagedStops, request: UnvalidatedCustodyRequest) throws {
            guard closed.belongs(to: owner), !closed.deadline.hasExpired else { throw CustodyRecordError.fenced }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, terminalProgress == .notAttempted, evidence.session === self,
                  evidence.commands.contains(where: { $0.request == request }),
                  !evidence.commands.isEmpty, evidence.commands.count <= 128 else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let pins = stoppedPins(); mutex.unlock()
            try validateStoppedPins(pins, deadline: closed.deadline)
            for command in evidence.commands {
                guard command.journal.phase == .terminal,
                      command.journal.binding == (try CustodyRecordBinding(command.request.binding)),
                      command.request.inputSHA256 == CustodyRecordBinding.digest(try evidence.binding.encode()),
                      command.request.authority == evidence.binding.stagedMode else { throw CustodyRecordError.fenced }
                for (name, pin) in command.files {
                    guard let actual = pins.receipts[name], actual.node.identity == pin.node.identity,
                          actual.node.acl == pin.node.acl, actual.bytes == pin.bytes else { throw CustodyRecordError.conflict }
                }
            }
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !serializing, !stoppedPinsReading, terminalProgress == .notAttempted, metadataGeneration == pins.generation,
                  current == pins.control, !closed.deadline.hasExpired else { throw CustodyRecordError.fenced }
        }
        fileprivate func validateClosedStartArchives(_ archive: ClosedStagedStartArchive,
            request: UnvalidatedCustodyRequest, deadline supplied: MonotonicDeadline) throws {
            let evidence = archive.evidence, observation = evidence.observation
            let deadline = MonotonicDeadline(uptimeNanoseconds: min(supplied.absoluteUptimeNanoseconds,
                observation.operationDeadline.absoluteUptimeNanoseconds))
            try evidence.validateNoPending()
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !stoppedPinsReading, !failed, pending == nil,
                  terminalProgress == .notAttempted, observation.session === self,
                  stop == nil, current == observation.binding.control,
                  observation.binding.stagedMode == .installationStagedStart,
                  !evidence.commands.isEmpty, evidence.commands.count <= 128,
                  evidence.commands.last?.request == request else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            let pins = stoppedPins()
            stoppedPinsReading = true; mutex.unlock()
            defer { mutex.lock(); stoppedPinsReading = false; mutex.unlock() }
            try owner.revalidate()
            try evidence.validateCommittedRequest(request)
            var revision = try CustodyCatalog.decode(pins.catalog.bytes).revision
            var receipts = pins.receipts
            var finalCatalog = pins.catalog
            var previousCommandRevision: UInt64?
            var mutations = 0
            for command in evidence.commands {
                guard !deadline.hasExpired,
                      command.request.binding.scopeID == request.binding.scopeID,
                      command.request.inputSHA256 == CustodyRecordBinding.digest(try observation.binding.encode()),
                      command.request.authority == .installationStagedStart,
                      command.journal.binding == (try CustodyRecordBinding(command.request.binding)),
                      command.journal.kind == command.request.kind,
                      command.journal.authority == command.request.authority,
                      command.journal.budget == command.request.budget,
                      command.journal.inputSHA256 == command.request.inputSHA256,
                      command.journal.resourcesSHA256 == command.request.resourcesSHA256,
                      command.journal.phase == .terminal, let outcome = command.journal.outcome,
                      [.completed, .commandFailed, .admissionRefused, .cancelledDrained, .timedOutDrained].contains(outcome),
                      Set(command.files.keys) == Set([command.request.binding.requestID + ".json",
                                                     command.request.binding.requestID + ".caller.json"]) else {
                    throw CustodyRecordError.fenced
                }
                if command.request.kind == .launchctlMutation { mutations += 1 }
                else { guard [.launchctlRead, .signatureCheck].contains(command.request.kind) else { throw CustodyRecordError.fenced } }
                let catalog = try CustodyCatalog.decode(command.catalog.bytes)
                guard catalog.entries.isEmpty else { throw CustodyRecordError.conflict }
                if let previous = previousCommandRevision {
                    guard previous <= UInt64.max - 2, catalog.revision == previous + 2 else { throw CustodyRecordError.conflict }
                }
                previousCommandRevision = catalog.revision
                let existing = command.files.keys.filter { receipts[$0] != nil }.count
                if existing == command.files.count {
                    // An already incorporated command is counted once, with
                    // exactly the original pins; no general newer-catalog rule.
                    guard catalog.revision <= revision else { throw CustodyRecordError.conflict }
                    for (name, pin) in command.files {
                        guard let held = receipts[name], held.node.identity == pin.node.identity,
                              held.node.acl == pin.node.acl, held.bytes == pin.bytes else { throw CustodyRecordError.conflict }
                    }
                    if catalog.revision == revision {
                        guard finalCatalog.node.identity == command.catalog.node.identity,
                              finalCatalog.node.acl == command.catalog.node.acl,
                              finalCatalog.bytes == command.catalog.bytes else { throw CustodyRecordError.conflict }
                    }
                } else {
                    guard existing == 0, revision <= UInt64.max - 2, catalog.revision == revision + 2 else {
                        throw CustodyRecordError.conflict
                    }
                    revision = catalog.revision; finalCatalog = command.catalog
                    receipts.merge(command.files) { original, _ in original }
                }
            }
            guard mutations <= 1, let last = evidence.commands.last,
                  finalCatalog.node.identity == last.catalog.node.identity,
                  finalCatalog.node.acl == last.catalog.node.acl,
                  finalCatalog.bytes == last.catalog.bytes else { throw CustodyRecordError.conflict }
            let combined = StoppedPins(generation: pins.generation, control: pins.control,
                controlPin: pins.controlPin, catalog: finalCatalog, receipts: receipts, chain: pins.chain)
            guard try InstallationControlRecord.decode(combined.controlPin.bytes, profile: owner.validationProfile) == combined.control else {
                throw CustodyRecordError.conflict
            }
            try combined.control.validateReceiptChain(combined.chain, profile: owner.validationProfile)
            try validatePinnedMetadata(combined, deadline: deadline)
            try owner.revalidate()
            try evidence.validateNoPending()
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            let unchanged = !serializing && stoppedPinsReading && !failed && pending == nil
                && metadataGeneration == pins.generation && current == pins.control
                && current == observation.binding.control && stop == nil
            mutex.unlock()
            guard unchanged else { throw CustodyRecordError.fenced }
            try owner.revalidate()
            try evidence.validateNoPending()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
        private func refreshRecoveryPins(_ evidence: StagedRetirementEvidence,
            store: CustodyCatalogStore, deadline: MonotonicDeadline, diagnosticOnly: Bool) throws {
            guard let last = evidence.commands.last, evidence.commands.count <= 128,
                  !diagnosticOnly || (evidence.commands.count == 1 && last.request.kind == .launchctlRead) else { throw CustodyRecordError.fenced }
            var revision = try CustodyCatalog.decode(catalogPin.bytes).revision
            var added: [String: InstallationStagedAdmissionIntent.Evidence] = [:]
            var mutations = 0
            for command in evidence.commands {
                guard !deadline.hasExpired, revision <= UInt64.max - 2,
                      command.request.binding.scopeID == last.request.binding.scopeID,
                      command.request.inputSHA256 == CustodyRecordBinding.digest(try evidence.observation.binding.encode()),
                      command.request.authority == evidence.observation.binding.stagedMode,
                      command.journal.phase == .terminal,
                      let outcome = command.journal.outcome,
                      [.completed, .commandFailed, .admissionRefused, .cancelledDrained, .timedOutDrained].contains(outcome) else {
                    throw CustodyRecordError.fenced
                }
                let catalog = try CustodyCatalog.decode(command.catalog.bytes)
                guard catalog.revision == revision + 2, catalog.entries.isEmpty else { throw CustodyRecordError.conflict }
                revision = catalog.revision
                if command.request.kind == .launchctlMutation { mutations += 1 }
                else { guard [.launchctlRead, .signatureCheck].contains(command.request.kind) else { throw CustodyRecordError.fenced } }
                for (name, pin) in command.files {
                    guard receiptPins[name] == nil, added[name] == nil else { throw CustodyRecordError.conflict }
                    added[name] = pin
                }
            }
            guard mutations <= (diagnosticOnly ? 0 : 1),
                  try InstallationStagedAdmissionIntent.names(receipts.descriptor.value) == Set(receiptPins.keys).union(added.keys) else { throw CustodyRecordError.conflict }
            func validate(_ pin: InstallationStagedAdmissionIntent.Evidence, parent: Int32, name: String) throws {
                try store.validate(pin.node, at: parent, name: name, isDirectory: false)
                let file = try store.read(name, at: parent, maximum: CustodyCatalog.maximumBytes)
                guard file.identity == pin.node.identity, file.acl == pin.node.acl, file.bytes == pin.bytes,
                      fsync(pin.node.descriptor.value) == 0, fsync(parent) == 0 else { throw CustodyRecordError.conflict }
            }
            try validate(last.catalog, parent: directory.descriptor.value, name: "catalog.json")
            for (name, pin) in added { try validate(pin, parent: receipts.descriptor.value, name: name) }
            catalogPin = last.catalog; receiptPins.merge(added) { original, _ in original }
        }
        func completeBootstrap(after retired: RetainedCleanupRegistry.StagedCommandCompletion,
                               deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try completeCommand(.bootstrapCandidate, operation: .bootstrap, after: retired, deadline: deadline)
        }
        #if SHADOW_SYNC_TESTING
        func completeKickstart(after retired: RetainedCleanupRegistry.StagedCommandCompletion,
                               deadline: MonotonicDeadline,
                               observation: InstallationKickstartFailureObservation? = nil) throws -> InstallationControlRecord {
            var stage: InstallationKickstartFailureObservation.Stage = .deadlineRead
            do {
                let readinessDeadline = try retired.readinessDeadline()
                stage = .completionCommand
                let completed = try completeCommand(.kickstartCandidate, operation: .kickstart, after: retired, deadline: deadline)
                stage = .retirementClock
                guard !readinessDeadline.hasExpired else { throw CustodyRecordError.busy }
                stage = .sessionLookup
                try lockReadiness(deadline); let session = readinessClosed ? nil : readinessSession; readinessMutex.unlock()
                guard let session else { throw CustodyRecordError.fenced }
                stage = .sessionAnchor
                try session.anchorAfterKickstart(completed, deadline: readinessDeadline)
                return completed
            } catch {
                let savedDiagnosticErrno = errno
                observation?.capture(stage: stage, error: error)
                errno = savedDiagnosticErrno
                throw error
            }
        }
        #else
        func completeKickstart(after retired: RetainedCleanupRegistry.StagedCommandCompletion,
                               deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            let readinessDeadline = try retired.readinessDeadline()
            let completed = try completeCommand(.kickstartCandidate, operation: .kickstart, after: retired, deadline: deadline)
            guard !readinessDeadline.hasExpired else { throw CustodyRecordError.busy }
            try lockReadiness(deadline); let session = readinessClosed ? nil : readinessSession; readinessMutex.unlock()
            guard let session else { throw CustodyRecordError.fenced }
            try session.anchorAfterKickstart(completed, deadline: readinessDeadline)
            return completed
        }
        #endif
        func completeCandidateStop(after retired: RetainedCleanupRegistry.StagedCommandCompletion,
                                   deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            try completeCommand(.candidateStop, operation: .bootout, after: retired, deadline: deadline)
        }
        private func completeCommand(_ action: InstallationAction, operation: LifecycleLaunchCommand.Operation,
            after retired: RetainedCleanupRegistry.StagedCommandCompletion,
            deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            // No mutex spans registry validation or process postflight. This
            // requires released scope/prepared/context AND enrolled lease aliases.
            let evidence = try retired.validate(operation: operation)
            guard evidence.observation.session === self else { throw CustodyRecordError.fenced }
            try owner.validateStagedCommandAliasesRetired()
            let leases = try owner.retainStagedCommandCompletionLeases(mode: operation == .bootout
                ? .installationStagedStop : .installationStagedStart)
            return try serialized(deadline: deadline, completionLeases: leases) { store in
                guard commandsClaimed, current == evidence.observation.binding.control,
                      current.step?.action == action, current.step?.status == .intent,
                      (action == .candidateStop) == (stop != nil) else { throw CustodyRecordError.fenced }
                try store.locked {
                    try validateLocked(store, deadline, command: true)
                    try refreshRetiredPins(evidence, store: store, deadline: deadline)
                    try validateLocked(store, deadline)
                }
                let completed = try publish(proposal(action, status: .complete), store: store, deadline: deadline)
                commandsClaimed = false
                if action == .candidateStop, let delivery = continuationRecovery, delivery.isReadinessOnly {
                    guard evidence.observation.binding.control == delivery.control,
                          readinessStopCompletion == nil, let acknowledgment = delivery.observation.0 else { throw CustodyRecordError.fenced }
                    try delivery.validateCompleted(acknowledgment)
                    readinessStopCompletion = retired
                }
                return completed
            }
        }
        private func refreshRetiredPins(_ evidence: StagedRetirementEvidence,
            store: CustodyCatalogStore, deadline: MonotonicDeadline) throws {
            guard let last = evidence.commands.last, !evidence.commands.isEmpty,
                  evidence.commands.count <= 128 else { throw CustodyRecordError.fenced }
            var revision = try CustodyCatalog.decode(catalogPin.bytes).revision
            var added: [String: InstallationStagedAdmissionIntent.Evidence] = [:]
            var mutations = 0
            for command in evidence.commands {
                guard !deadline.hasExpired, revision <= UInt64.max - 2,
                      command.request.binding.scopeID == last.request.binding.scopeID,
                      command.request.inputSHA256 == CustodyRecordBinding.digest(try evidence.observation.binding.encode()),
                      command.request.authority == evidence.observation.binding.stagedMode,
                      command.journal.reason == CustodyReason.none,
                      command.journal.phase == .terminal else { throw CustodyRecordError.fenced }
                let catalog = try CustodyCatalog.decode(command.catalog.bytes)
                // Exactly one reservation and one durable retirement per command.
                guard catalog.revision == revision + 2, catalog.entries.isEmpty else { throw CustodyRecordError.conflict }
                revision = catalog.revision
                if command.request.kind == .launchctlMutation { mutations += 1 }
                else { guard [.launchctlRead, .signatureCheck].contains(command.request.kind),
                             command.journal.outcome == .completed else { throw CustodyRecordError.fenced } }
                for (name, pin) in command.files {
                    guard receiptPins[name] == nil, added[name] == nil else { throw CustodyRecordError.conflict }
                    added[name] = pin
                }
            }
            guard mutations == 1, last.request.kind == .launchctlMutation,
                  try InstallationStagedAdmissionIntent.names(receipts.descriptor.value) == Set(receiptPins.keys).union(added.keys) else {
                throw CustodyRecordError.conflict
            }
            func validate(_ pin: InstallationStagedAdmissionIntent.Evidence, parent: Int32, name: String) throws {
                try store.validate(pin.node, at: parent, name: name, isDirectory: false)
                let file = try store.read(name, at: parent, maximum: CustodyCatalog.maximumBytes)
                guard file.identity == pin.node.identity, file.acl == pin.node.acl, file.bytes == pin.bytes,
                      fsync(pin.node.descriptor.value) == 0, fsync(parent) == 0 else { throw CustodyRecordError.conflict }
            }
            try validate(last.catalog, parent: directory.descriptor.value, name: "catalog.json")
            for (name, pin) in added { try validate(pin, parent: receipts.descriptor.value, name: name) }
            catalogPin = last.catalog; receiptPins.merge(added) { original, _ in original }
        }
    }
}

extension CustodyCatalogStore {
    fileprivate struct StagedRetiredCommand {
        let request: UnvalidatedCustodyRequest
        let journal: CustodyJournal
        let mayHaveExecuted: Bool
        let catalog: InstallationStagedAdmissionIntent.Evidence
        let files: [String: InstallationStagedAdmissionIntent.Evidence]
        fileprivate init(request: UnvalidatedCustodyRequest, journal: CustodyJournal,
            catalog: InstallationStagedAdmissionIntent.Evidence,
            files: [String: InstallationStagedAdmissionIntent.Evidence], mayHaveExecuted: Bool) {
            self.request = request; self.journal = journal; self.catalog = catalog; self.files = files
            self.mayHaveExecuted = mayHaveExecuted
        }
    }
    /// Actual registry archive custody without retaining the completed journal
    /// or original operation owner through the process-wide registry forever.
    /// A live original session is still mandatory whenever the proof is used.
    final class ClosedStopArchiveEvidence {
        fileprivate weak var session: InstallationStagedJournal?
        fileprivate let binding: InstallationCommandBinding
        fileprivate let commands: [StagedRetiredCommand]
        private let failure: CommandCustodyPhaseFailure
        fileprivate init(_ evidence: StagedRetirementEvidence) {
            session = evidence.observation.session; binding = evidence.observation.binding
            commands = evidence.commands; failure = evidence.failure
        }
        func validateClosedStops(_ closed: ClosedInstallationStagedStops, request: UnvalidatedCustodyRequest) throws {
            guard let session, !failure.cleanupPending else { throw CustodyRecordError.fenced }
            try session.validateClosedStopArchives(self, closed: closed, request: request)
            guard !failure.cleanupPending else { throw CustodyRecordError.fenced }
        }
    }
    // Caller-held only: the registry ledger never retains this live session.
    final class ClosedStagedStartArchive {
        fileprivate let evidence: StagedRetirementEvidence
        fileprivate init(evidence: StagedRetirementEvidence) { self.evidence = evidence }
        var retirementOwner: InstallationTransactionOwner { evidence.retirementOwner }
        func validate(request: UnvalidatedCustodyRequest) throws -> StagedRetirementEvidence {
            try evidence.observation.session.validateClosedStartArchives(self, request: request,
                deadline: evidence.observation.operationDeadline)
            return evidence
        }
    }
    final class StagedRetirementEvidence {
        fileprivate let observation: InstallationStagedCommandObservation
        fileprivate let commands: [StagedRetiredCommand]
        fileprivate let failure: CommandCustodyPhaseFailure
        fileprivate init(observation: InstallationStagedCommandObservation, commands: [StagedRetiredCommand],
                         failure: CommandCustodyPhaseFailure) {
            self.observation = observation; self.commands = commands; self.failure = failure
        }
        var retirementOwner: InstallationTransactionOwner { observation.session.retirementOwner }
        func validateNoPending() throws {
            guard !failure.cleanupPending else { throw CustodyRecordError.fenced }
        }
        func validateCommittedRequest(_ request: UnvalidatedCustodyRequest) throws {
            try observation.binding.validateCommittedRequest(request)
        }
        func closedStopArchiveEvidence() -> ClosedStopArchiveEvidence { ClosedStopArchiveEvidence(self) }
    }
    fileprivate func captureStagedRetirement(request: UnvalidatedCustodyRequest,
        journal: CustodyJournal, caller: Data, mayHaveExecuted: Bool) throws -> StagedRetiredCommand {
        try locked {
            let snapshot = try snapshot()
            guard request.authority.isInstallationStaged, snapshot.1.entries.isEmpty,
                  journal.binding == (try CustodyRecordBinding(request.binding)), journal.phase == .terminal,
                  journal.authority == request.authority, journal.inputSHA256 == request.inputSHA256 else {
                throw CustodyRecordError.fenced
            }
            func pin(_ name: String, parent: Int32, expected: Data) throws -> InstallationStagedAdmissionIntent.Evidence {
                let node = try Self.openNode(parent, name, uid: uid, directory: false)
                let file = try read(name, at: parent, maximum: CustodyCatalog.maximumBytes)
                guard file.bytes == expected, file.identity == node.identity, file.acl == node.acl,
                      fsync(node.descriptor.value) == 0, fsync(parent) == 0 else { throw CustodyRecordError.conflict }
                try validate(node, at: parent, name: name, isDirectory: false)
                return InstallationStagedAdmissionIntent.Evidence(node: node, bytes: file.bytes)
            }
            let name = request.binding.requestID
            let archive = try archiveBytes(journal, bytes: journal.encode())
            return try StagedRetiredCommand(request: request, journal: journal,
                catalog: pin("catalog.json", parent: directory.descriptor.value, expected: snapshot.0.bytes),
                files: [name + ".json": pin(name + ".json", parent: receipts.descriptor.value, expected: archive),
                    name + ".caller.json": pin(name + ".caller.json", parent: receipts.descriptor.value, expected: caller)],
                mayHaveExecuted: mayHaveExecuted)
        }
    }
}
