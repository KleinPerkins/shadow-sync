import Darwin
import Foundation

// Descriptor observations only. No path, PID, decoded record or opened file
// grants a lease. Callers must retain their original typed authority separately.
extension InstallationStateBinding {
    private struct ObservedNode {
        let descriptor: OwnedFileDescriptor
        let identity: InstallationNodeIdentity
        let parent: Int32?
        let name: String?
    }
    private static func identity(_ fd: Int32, uid: uid_t, directory: Bool) throws -> InstallationNodeIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == uid,
              value.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600),
              directory ? value.st_nlink > 0 : value.st_nlink == 1 else {
            throw CustodyRecordError.unsafeMetadata
        }
        let result = InstallationNodeIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            type: directory ? .directory : .regular, uid: value.st_uid, mode: UInt32(value.st_mode),
            links: UInt64(value.st_nlink),
            aclDigest: CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(fd).utf8)))
        try result.validate(); return result
    }
    private static func open(_ parent: Int32, _ name: String, uid: uid_t, directory: Bool) throws -> ObservedNode {
        let raw = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let owner = OwnedFileDescriptor(raw)
        return try ObservedNode(descriptor: owner, identity: identity(raw, uid: uid, directory: directory), parent: parent, name: name)
    }
    static func capture(stateDescriptor: Int32, uid: uid_t) throws -> Self {
        let state = try identity(stateDescriptor, uid: uid, directory: true)
        let custody = try open(stateDescriptor, "custody", uid: uid, directory: true)
        let namespace = try open(stateDescriptor, "latest.log", uid: uid, directory: false)
        let lifecycle = try open(stateDescriptor, "lifecycle.lock", uid: uid, directory: false)
        let operation = try open(stateDescriptor, "operation.lock", uid: uid, directory: false)
        let run = try open(stateDescriptor, "run.lock", uid: uid, directory: false)
        let launcher = try open(stateDescriptor, "launcher.lock", uid: uid, directory: false)
        let catalog = try open(custody.descriptor.value, "catalog.lock", uid: uid, directory: false)
        // Keep every opened description alive until the entire named set has
        // been rechecked; an earlier close could hide inode substitution.
        for node in [custody, namespace, lifecycle, operation, run, launcher, catalog] {
            let current = try identity(node.descriptor.value, uid: uid, directory: node.identity.type == .directory)
            var named = stat()
            guard current == node.identity, let parent = node.parent, let name = node.name,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  UInt64(named.st_dev) == current.device, UInt64(named.st_ino) == current.inode,
                  named.st_uid == current.uid, UInt32(named.st_mode) == current.mode,
                  UInt64(named.st_nlink) == current.links else { throw CustodyRecordError.unsafeMetadata }
        }
        guard try identity(stateDescriptor, uid: uid, directory: true) == state else { throw CustodyRecordError.unsafeMetadata }
        let result = Self(directory: state, namespace: namespace.identity, lifecycle: lifecycle.identity,
            operation: operation.identity, run: run.identity, launcher: launcher.identity, catalogGuard: catalog.identity)
        try result.validate(); return result
    }
    func validateLive(stateDescriptor: Int32, uid: uid_t, leases: CustodyAuthorityLeaseSet) throws {
        try validate()
        let current = try Self.capture(stateDescriptor: stateDescriptor, uid: uid)
        // Directory link counts may change when valid child directories appear.
        // Both observations must be live/private; only this count is not stable.
        let a = directory, b = current.directory
        guard a.device == b.device, a.inode == b.inode, a.type == b.type, a.uid == b.uid,
              a.mode == b.mode, a.aclDigest == b.aclDigest, a.links > 0, b.links > 0,
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
    private var liveRequests: Set<String> = []
    private var stagedRetirements: [CustodyCatalogStore.StagedRetiredCommand] = []
    private let store: CustodyCatalogStore
    private let installation: CustodyCatalogStore.InstallationCommandPermit?

    init(leases: CustodyAuthorityLeaseSet, releaseSHA256: String, generation: String, installation: CustodyCatalogStore.InstallationCommandPermit? = nil) throws {
        guard CustodyWire.hex(releaseSHA256, bytes: 32), RunIdentity.isValid(generation) else { throw CustodyRecordError.invalidRecord }
        // Staged lease custody is not installation command authority. No generic
        // scope may open this mode before an exact durable continuation exists.
        guard !leases.mode.isInstallationStaged || installation?.observation.stagedMode == leases.mode else { throw CustodyRecordError.fenced }
        self.leases = leases; self.releaseSHA256 = releaseSHA256; self.generation = generation; self.installation = installation
        bootID = try CustodyBootIdentity.current(); uid = geteuid()
        store = try CustodyCatalogStore(leases: leases)
        // Validate all evidence now, then again in the same guarded transition
        // as every reservation. This initial read is never cached admission.
        try installation?.revalidate()
        try store.checkFence(ownRequests: [], scope: id, mode: leases.mode, installation: installation)
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
    func markPending() { mutex.lock(); state = .pending; stagedFailure.recordPending(); mutex.unlock() }
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
            state = .pending; stagedFailure.recordPending(); throw error
        }
    }
    /// Only the retaining registry can construct this proof. The catalog is
    /// checked under its stable guard again; an exited PID alone is insufficient.
    func completeFromRegistry(_ proof: CustodyRetirementProof) throws -> CustodyJournal {
        mutex.lock(); defer { mutex.unlock() }
        let ticket = proof.ticket
        guard ticket.scope === self, proof.resources.scope === self,
              liveRequests.contains(ticket.requestID),
              ticket.journal.binding == (try CustodyRecordBinding(proof.resources.request.binding)) else {
            throw CustodyRecordError.fenced
        }
        do {
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
                try store.replaceJournal(ticket.journal, with: proposed)
                ticket.journal = proposed; terminal = proposed
            case .terminal(let owner, let message):
                mayHaveExecuted = true
                guard case .reaped(0) = owner.observation else { throw CustodyRecordError.fenced }
                terminal = try store.observeTerminal(prepared: ticket.journal, owner: owner, message: message)
            }
            let observation = try proof.callerObservation(journal: terminal)
            _ = try store.archiveAndRetire(terminal, callerObservation: observation)
            if let installation, installation.observation.stagedMode != nil {
                stagedRetirements.append(try store.captureStagedRetirement(request: proof.resources.request,
                    journal: terminal, caller: observation, mayHaveExecuted: mayHaveExecuted))
            }
            ticket.journal = terminal; liveRequests.remove(ticket.requestID)
            if state != .open && liveRequests.isEmpty { state = .terminal }
            return terminal
        } catch { state = .pending; stagedFailure.recordPending(); throw error }
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
    #if SHADOW_SYNC_TESTING
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
    private let leases: CustodyAuthorityLeaseSet
    private let root: OwnedFileDescriptor
    private let uid: uid_t
    private let directory: Node
    private let guardFile: Node
    private let receipts: Node
    private let mutex = NSLock()
    private var poisoned = false
    private var installationCommandPins: [String: Node] = [:]

    init(leases: CustodyAuthorityLeaseSet) throws {
        self.leases = leases
        let state = try leases.duplicateStateDirectory(); root = state.0; uid = state.1
        directory = try Self.openNode(root.value, "custody", uid: uid, directory: true)
        guardFile = try Self.openNode(directory.descriptor.value, "catalog.lock", uid: uid, directory: false)
        receipts = try Self.openNode(directory.descriptor.value, "receipts", uid: uid, directory: true)
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
        try leases.validate()
        try validate(directory, at: root.value, name: "custody", isDirectory: true)
        try validate(guardFile, at: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
        try validate(receipts, at: directory.descriptor.value, name: "receipts", isDirectory: true)
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        guard mutex.try() else { throw CustodyRecordError.busy }
        defer { mutex.unlock() }
        guard !poisoned else { throw CustodyRecordError.fenced }
        try validateBindings()
        guard flock(guardFile.descriptor.value, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw CustodyRecordError.busy }
            throw CustodyRecordError.persistence(errno)
        }
        // This guard is a private, unduplicated metadata lock. No operation or
        // inherited authority descriptor is ever unlocked here.
        defer { _ = flock(guardFile.descriptor.value, LOCK_UN) }
        try validateBindings()
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
        let record = try InstallationControlRecord.decode(file.bytes)
        try record.state.validateLive(stateDescriptor: root.value, uid: uid, leases: leases)
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
            try record.validateReceiptChain(observations: Array(chain.dropLast()))
            try record.validateReplacement(pendingControl, receipts: chain.map(\.receipt))
        } else { try record.validateReceiptChain(observations: chain) }
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
                guard leases.mode == .lifecycleMutation else { throw CustodyRecordError.fenced }
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
    static func precommitWaitObservation(admission: LifecycleAdmissionAuthority) throws -> InstallationControlRecord {
        let store = try Self(leases: admission.retainObservationLeases())
        return try store.locked {
            let raw = try InstallationControlRecord.decode(store.read(InstallationControlRecord.filename,
                maximum: InstallationControlRecord.maximumBytes).bytes)
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
                    controlNode: store.installationCommandNode(controlNode.identity, acl: controlNode.acl), receiptNodes: receiptNodes)
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
    static func precommitObservation(admission: LifecycleAdmissionAuthority) throws -> InstallationControlRecord {
        let control = try precommitWaitObservation(admission: admission)
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
        guard installation.1 == expected, expected.phase == .committed,
              expected.step?.action == .readinessCommit, expected.step?.status == .complete,
              expected.readinessCommit?.commitRevision == expected.revision,
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
    static func committedHostObservation(admission: LifecycleAdmissionAuthority,
                                         expected: InstallationControlRecord,
                                         deadline: MonotonicDeadline) throws -> HostCommittedObservation {
        guard admission.commandAdmissionIsOpen, !deadline.hasExpired else { throw CustodyRecordError.fenced }
        let store = try Self(leases: admission.retainObservationLeases())
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
            guard proof.leases === leases, leases.mode == .mutation else { throw CustodyRecordError.fenced }
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
            guard mode == leases.mode else { throw CustodyRecordError.fenced }
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
            guard journal.authority == leases.mode, journal.binding.scopeID == scope,
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
        try locked {
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
    }
    fileprivate func claimHelper(_ inherited: CustodyInheritedCommand) throws -> CustodyJournal {
        try locked {
            if let installation = inherited.installation { try validateInstallationCommand(installation) }
            else { try installationFence(mode: inherited.request.authority) }
            let s = try snapshot(), request = inherited.request
            let expected = try CustodyJournal(prepared: request, leases: leases.descriptorClaims())
            guard s.1.entries.contains(CustodyCatalogEntry(expected)),
                  s.2[request.binding.requestID] == expected else { throw CustodyRecordError.fenced }
            return expected
        }
    }
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
        guard context.owns(leases) else { throw CustodyRecordError.fenced }
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
    func admit() throws {
        guard current.phase == .prepared else { throw CustodyRecordError.invalidTransition }
        try inherited.revalidateParent()
        try replace(current.advancing(to: .admitted, custodian: helperObservation))
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
    func executing(_ owner: OwnedDirectChild) throws {
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
        try replace(current.advancing(to: .executing, custodian: helperObservation,
            target: CustodyProcessObservation(owner.identity)))
        recordedOwner = owner; serialRetirement = nil
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
        func boundDiagnosticBudget(_ budget: CustodyBudget) throws -> CustodyBudget {
            guard let ready = staged?.ready else { return budget }
            try ready.revalidate(for: staged!.session)
            return try budget.clipped(to: ready.deadline, kind: .launchctlRead, permittedWorkSeconds: 10)
        }
        func validateRequest(_ request: UnvalidatedCustodyRequest) throws {
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
                        controlNode: store.installationCommandNode(anchor.identity, acl: anchor.acl), receiptNodes: nodes)
                    try observation.validate(); try store.validateInstallationCommand(observation)
                    commandsClaimed = true
                    return InstallationCommandPermit(session: self, observation: observation)
                }
            }
        }
        fileprivate func validateCommandPermit(_ permit: InstallationCommandPermit) throws {
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard commandsClaimed, owner.commandAdmissionIsOpen, pending == nil,
                  current == permit.observation.control else { throw CustodyRecordError.fenced }
            try binding.revalidate(for: owner); try capture.validateSource()
            try store.locked { try store.validateInstallationCommand(permit.observation) }
        }
        // Pin exact receipt descriptions across a cut. Identical replacement
        // bytes/inode metadata cannot substitute for this live durability proof.
        private var retainedSteps: [String: Node] = [:]
        #if SHADOW_SYNC_TESTING
        enum Cut { case afterReceipt, beforeControl }
        private var cut: Cut?
        private var receiptFault: CustodyCatalogStore.Fault?
        private var controlFault: CustodyCatalogStore.Fault?
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
            let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
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
            try transaction.validate(state: binding.state)
            try capture.validateSource()
        }
        private static func documents(_ capture: InstallationCapturedSlots) -> [String: InstallationDocumentPreimage] {
            Dictionary(uniqueKeysWithValues: capture.canonicalPreimages.map { ($0.digest, $0.receipt) })
        }
        private func serialized<T>(deadline: MonotonicDeadline, _ action: (MonotonicDeadline) throws -> T) throws -> T {
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            try validateSource(deadline)
            let result = try action(deadline)
            try validateSource(deadline)
            return result
        }
        private func validateSource(_ deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try binding.revalidate(for: owner); try capture.validateSource()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
        private func validateLocked(_ deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired, store.leases.mode == .lifecycleMutation else { throw CustodyRecordError.busy }
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
            try current.validateReplacement(next, receipts: chain + [receipt])
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
        func prepareExclusive(deadline: MonotonicDeadline) throws -> InstallationControlRecord {
            _ = try serialized(deadline: deadline) { deadline in
                guard !preparationClaimed, !commandsClaimed, pending == nil,
                      current.phase == .active, current.step?.action == .reserve,
                      current.step?.status == .complete,
                      transaction.intent == .install || transaction.intent == .repair else { throw CustodyRecordError.fenced }
                try capture.requireExclusiveEmptyInstall()
                preparationClaimed = true
                return try publish(proposal(status: .intent, action: .drainPrior), deadline: deadline)
            }
            // No journal mutex/catalog guard spans command execution/retirement.
            try capture.observeExclusiveServiceAbsence(journal: self, deadline: deadline)
            _ = try serialized(deadline: deadline) { deadline in
                guard commandsClaimed, pending == nil, current.step?.action == .drainPrior,
                      current.step?.status == .intent else { throw CustodyRecordError.fenced }
                return try publish(proposal(status: .complete, action: .drainPrior), deadline: deadline)
            }
            for action: InstallationAction in [.stageApplication, .stagePlist, .retireApplication, .retirePlist,
                .retireCoordination, .translateState, .moveStateForward, .promoteApplication, .promotePlist] {
                _ = try serialized(deadline: deadline) { deadline in
                    guard pending == nil, current.phase == .active, current.step?.status == .complete else { throw CustodyRecordError.fenced }
                    _ = try publish(proposal(status: .intent, action: action), deadline: deadline)
                    try validateSource(deadline)
                    try store.locked { try validateLocked(deadline) }
                    let permit = InstallationExclusiveActionPermit(session: self, capture: capture, action: action, control: current)
                    exclusivePermit = permit; exclusiveDeadline = deadline
                    defer { exclusivePermit = nil; exclusiveDeadline = nil }
                    let after = try capture.executeExclusive(permit)
                    try validateSource(deadline)
                    return try publish(proposal(status: .complete, action: action, postimage: after), deadline: deadline)
                }
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
                store.testingCut = receiptFault; receiptFault = nil
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
                if cut == .afterReceipt { cut = nil; throw CustodyRecordError.injectedFailure }
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
                try current.validateReplacement(pending.control, receipts: chain + [pending.receipt.receipt])
                #if SHADOW_SYNC_TESTING
                if cut == .beforeControl { cut = nil; throw CustodyRecordError.injectedFailure }
                store.testingCut = controlFault; controlFault = nil
                #endif
                guard !deadline.hasExpired else { throw CustodyRecordError.busy }
                try store.write(InstallationControlRecord.filename, bytes: pending.control.encode(), expected: anchor)
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
                try current.validateReplacement(next, receipts: chain)
                return try store.locked {
                    try validateLocked(deadline)
                    #if SHADOW_SYNC_TESTING
                    store.testingCut = controlFault; controlFault = nil
                    #endif
                    try store.write(InstallationControlRecord.filename, bytes: next.encode(), expected: anchor)
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
        guard leases.mode == (binding.stagedMode ?? .lifecycleMutation) else { throw CustodyRecordError.fenced }
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
        private let root: OwnedFileDescriptor
        fileprivate let directory: Node
        fileprivate let receipts: Node
        fileprivate let guardFile: Node
        fileprivate let uid: uid_t
        fileprivate struct Evidence { let node: Node; let bytes: Data }
        fileprivate let control: Evidence
        fileprivate let catalog: Evidence
        fileprivate let receiptFiles: [String: Evidence]
        private let mutex = NSLock()
        private var continuationClaimed = false
        func continueJournal(admission: InstallationStagedAdmission, deadline: MonotonicDeadline) throws -> InstallationStagedJournal {
            try admission.validateOwner(owner, intent: self)
            do { try revalidate(for: owner, deadline: deadline) }
            catch { _ = try? admission.closeStarts(); throw error }
            guard mutex.try() else { throw CustodyRecordError.busy }
            guard !continuationClaimed else { mutex.unlock(); throw CustodyRecordError.fenced }
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
            guard control.bytes == (try expected.encode()), expected.phase == .active,
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
            let claimed = continuationClaimed; mutex.unlock()
            try owner.revalidate(); try slots.revalidate(for: owner, deadline: deadline)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
            defer { mutex.unlock() }
            guard continuationClaimed == claimed else { throw CustodyRecordError.fenced }
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
        fileprivate init(session: InstallationStagedJournal, binding: InstallationCommandBinding,
                         ready: InstallationPrecommitSession.ReadyObservation? = nil) {
            self.session = session; self.binding = binding; self.ready = ready
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

    /// Continuation of the original detached intent. Only metadata descriptions
    /// are retained between calls; a temporary store borrows the SAME live staged
    /// owner's leases for each bounded write. No old exclusive aliases survive.
    final class InstallationStagedJournal: @unchecked Sendable {
        private let owner: InstallationTransactionOwner
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
        private weak var recovery: InstallationStagedRecovery?
        private var recoveryDiagnosticClaimed = false
        private var candidateReady: InstallationPrecommitSession.ReadyObservation?
        private var commitDeliveryReserved = false

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
        private var reconciledStart = false
        private var recoveryStartMayHaveExecuted = false
        // Independent short custody lock: code verification and metadata turns
        // never hold it, so cancellation is bounded even during publisher work.
        private let readinessMutex = NSLock()
        private var readinessClosed = false
        private var readinessSession: InstallationPrecommitSession?
        private var readinessEndpoint: InstallationReadinessEndpoint?
        struct ReadinessContext {
            let journal: InstallationStagedJournal
            let endpoint: InstallationReadinessEndpoint
            let app: PublisherCodeVerifier.Identity
            let uid: uid_t
            let deadline: MonotonicDeadline
            fileprivate init(journal: InstallationStagedJournal, endpoint: InstallationReadinessEndpoint,
                app: PublisherCodeVerifier.Identity, uid: uid_t, deadline: MonotonicDeadline) {
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
            guard !serializing, !failed, pending == nil, stop == nil, !commandsClaimed,
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
            let store = try CustodyCatalogStore(leases: admission.retainStartLeases())
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
                guard !serializing, metadataGeneration == revision, !failed, pending == nil,
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
            guard !serializing else { return nil }
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
            guard !serializing, testingPublicationProbe == nil else { throw CustodyRecordError.fenced }
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
            current = try InstallationControlRecord.decode(anchor.bytes)
            chain = try intent.receiptFiles.filter { $0.key.hasPrefix(InstallationStepReceipt.prefix) }.values.map {
                try InstallationStepReceipt.decode($0.bytes, uid: intent.uid)
            }.sorted { a, b in a.ordinal == b.ordinal ? a.status == .intent && b.status == .complete : a.ordinal < b.ordinal }
            try admission.validateOwner(owner, intent: intent)
            try current.validateReceiptChain(chain)
            try withStore(deadline: deadline) { store in try store.locked { try validateLocked(store, deadline) } }
        }
        private func validateSource(_ deadline: MonotonicDeadline) throws {
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
            let store = try CustodyCatalogStore(leases: leases)
            let result = try body(store)
            try validateSource(deadline)
            return result
        }
        private func serialized<T>(deadline: MonotonicDeadline, completionLeases: CustodyAuthorityLeaseSet? = nil,
                                   requiresOpenReadiness: Bool = false,
                                   _ body: (CustodyCatalogStore) throws -> T) throws -> T {
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing else { mutex.unlock(); throw CustodyRecordError.busy }
            guard !failed, pending == nil, metadataGeneration < UInt64.max else {
                mutex.unlock(); throw CustodyRecordError.fenced
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
                readinessCommit: commit, recoveryReason: current.recoveryReason)
            try current.validateReplacement(next, receipts: chain + [receipt])
            return Pending(control: next, receipt: canonical)
        }
        private func replaceControl(_ next: InstallationControlRecord, store: CustodyCatalogStore,
                                    deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            #if SHADOW_SYNC_TESTING
            if cut == .beforeControl { cut = nil; throw CustodyRecordError.injectedFailure }
            store.testingCut = controlFault; controlFault = nil
            #endif
            try store.write(InstallationControlRecord.filename, bytes: next.encode(), expected: anchor)
            let after = try store.installationSnapshot()
            let pin = try CustodyCatalogStore.openNode(directory.descriptor.value, InstallationControlRecord.filename,
                uid: store.uid, directory: false)
            guard after.1 == next, pin.identity == after.0.identity, pin.acl == after.0.acl,
                  fsync(pin.descriptor.value) == 0, fsync(directory.descriptor.value) == 0 else { throw CustodyRecordError.conflict }
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
                try current.validateReplacement(pending.control, receipts: chain + [pending.receipt.receipt])
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
                requiresOpenReadiness: true) { store in
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
        private func observation(_ store: CustodyCatalogStore, deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            try store.locked {
                try validateLocked(store, deadline)
                var nodes: [String: InstallationNodeIdentity] = [:]
                for (name, pin) in receiptPins where name.hasPrefix(InstallationStepReceipt.prefix) || name.hasPrefix(InstallationDocumentPreimage.prefix) {
                    nodes[name] = try store.installationCommandNode(pin.node.identity, acl: pin.node.acl)
                }
                let binding = try InstallationCommandBinding(control: current,
                    controlNode: store.installationCommandNode(anchor.identity, acl: anchor.acl), receiptNodes: nodes)
                try store.validateInstallationCommand(binding)
                return InstallationStagedCommandObservation(session: self, binding: binding,
                    ready: current.step?.action == .candidateReady ? candidateReady : nil)
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
        /// A separate post-publication edge. Never infer delivery from durable
        /// commit, retry a failed send, or turn transport failure into rollback.
        /// No production caller is enrolled by this source component.
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
        func candidateStopIntent(admission stop: InstallationStagedStopAdmission,
                                 deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            guard !serializing, !failed, pending == nil, metadataGeneration < UInt64.max,
                  (self.stop == nil && current.phase == .active)
                    || (self.stop === stop && current.phase == .recovery && reconciledStart),
                  current.step?.status == .complete,
                  [.openStagedAdmission, .bootstrapCandidate, .kickstartCandidate].contains(current.step!.action) else {
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
            guard !serializing, metadataGeneration == generation, !failed, pending == nil,
                  (self.stop == nil && current.phase == .active)
                    || (self.stop === stop && current.phase == .recovery && reconciledStart),
                  current.step?.status == .complete,
                  [.openStagedAdmission, .bootstrapCandidate, .kickstartCandidate].contains(current.step!.action) else {
                mutex.unlock(); throw CustodyRecordError.fenced
            }
            self.stop = stop; metadataGeneration += 1; mutex.unlock()
            return try serialized(deadline: deadline) { store in
                if current.phase == .active {
                    let recovery = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                        state: current.state, transaction: current.transaction, step: current.step,
                        latestReceiptDigest: current.latestReceiptDigest, readinessCommit: nil, recoveryReason: .readinessFailed)
                    try current.validateReplacement(recovery, receipts: chain)
                    try store.locked { try validateLocked(store, deadline); try replaceControl(recovery, store: store, deadline: deadline) }
                }
                _ = try publish(proposal(.candidateStop, status: .intent), store: store, deadline: deadline)
                return try observation(store, deadline: deadline)
            }
        }
        fileprivate func validate(_ observation: InstallationStagedCommandObservation, deadline: MonotonicDeadline) throws {
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
                guard !commandsClaimed, current == observation.binding.control else { throw CustodyRecordError.fenced }
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
            let leases = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            guard !deadline.hasExpired, mutex.try() else { throw CustodyRecordError.busy }
            do {
                guard !serializing, metadataGeneration < UInt64.max,
                      !failed, pending == nil, self.stop == nil, recovery == nil,
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
                    try current.validateReplacement(next, receipts: chain)
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
    final class StagedRetirementEvidence {
        fileprivate let observation: InstallationStagedCommandObservation
        fileprivate let commands: [StagedRetiredCommand]
        private let failure: CommandCustodyPhaseFailure
        fileprivate init(observation: InstallationStagedCommandObservation, commands: [StagedRetiredCommand],
                         failure: CommandCustodyPhaseFailure) {
            self.observation = observation; self.commands = commands; self.failure = failure
        }
        func validateNoPending() throws {
            guard !failure.cleanupPending else { throw CustodyRecordError.fenced }
        }
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
