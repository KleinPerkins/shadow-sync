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
    private var liveRequests: Set<String> = []
    private let store: CustodyCatalogStore
    private let installation: CustodyCatalogStore.InstallationCommandPermit?

    init(leases: CustodyAuthorityLeaseSet, releaseSHA256: String, generation: String, installation: CustodyCatalogStore.InstallationCommandPermit? = nil) throws {
        guard CustodyWire.hex(releaseSHA256, bytes: 32), RunIdentity.isValid(generation) else { throw CustodyRecordError.invalidRecord }
        // Staged lease custody is not installation command authority. No generic
        // scope may open this mode before an exact durable continuation exists.
        guard !leases.mode.isInstallationStaged else { throw CustodyRecordError.fenced }
        self.leases = leases; self.releaseSHA256 = releaseSHA256; self.generation = generation; self.installation = installation
        bootID = try CustodyBootIdentity.current(); uid = geteuid()
        store = try CustodyCatalogStore(leases: leases)
        // Validate all evidence now, then again in the same guarded transition
        // as every reservation. This initial read is never cached admission.
        try installation?.revalidate()
        try store.checkFence(ownRequests: [], scope: id, mode: leases.mode, installation: installation)
    }
    func revalidateInstallation() throws { try installation?.revalidate() }
    var observation: State { mutex.lock(); defer { mutex.unlock() }; return state }
    func close() {
        mutex.lock(); defer { mutex.unlock() }
        if state == .open { state = liveRequests.isEmpty ? .terminal : .closing }
    }
    func markPending() { mutex.lock(); state = .pending; mutex.unlock() }
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
                guard request.kind == .launchctlRead,
                      request.inputSHA256 == CustodyRecordBinding.digest(try installation.observation.encode()) else { throw CustodyRecordError.fenced }
            }
            try store.reserveAndPrepare(journal, ownRequests: liveRequests, scope: id, installation: installation)
            liveRequests.insert(journal.binding.requestID)
            return PreparedCustodyMetadata(scope: self, journal: journal)
        } catch {
            // Even a failure after catalog fsync leaves a known outstanding
            // transaction. Do not reopen this scope or guess a clean retry.
            state = .pending; throw error
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
            switch proof.basis {
            case .noSuccessfulSpawn, .neverResumed:
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
                guard case .reaped(0) = owner.observation else { throw CustodyRecordError.fenced }
                terminal = try store.observeTerminal(prepared: ticket.journal, owner: owner, message: message)
            }
            let observation = try proof.callerObservation(journal: terminal)
            _ = try store.archiveAndRetire(terminal, callerObservation: observation)
            ticket.journal = terminal; liveRequests.remove(ticket.requestID)
            if state != .open && liveRequests.isEmpty { state = .terminal }
            return terminal
        } catch { state = .pending; throw error }
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
            if journal.phase.isTerminal { continue }
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
        try locked {
            guard journal.authority == leases.mode, journal.binding.scopeID == scope,
                  journal.binding.uid == uid, journal.phase == .prepared else { throw CustodyRecordError.fenced }
            if let installation { try validateInstallationCommand(installation.observation) }
            else { try installationFence(mode: journal.authority) }
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
            try write("catalog.json", bytes: s.1.reserving(journal).encode(), expected: s.0)
            #if SHADOW_SYNC_TESTING
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
        try inherited.revalidatePersistenceResources(); try leases.validate()
        try store.replaceJournal(current, with: next); current = next
    }
    func admit() throws {
        guard current.phase == .prepared else { throw CustodyRecordError.invalidTransition }
        try inherited.revalidateParent()
        try replace(current.advancing(to: .admitted, custodian: helperObservation))
    }
    private func recordSerialRetirement(_ owner: OwnedDirectChild, streamsDrained: Bool) throws -> Int32 {
        guard [.discoveryGit, .launchctlMutation].contains(inherited.request.kind), current.phase == .executing,
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
        let (terminalOwner, status) = try verifiedRetirement(owner: owner, unexecuted: unexecuted,
            noSuccessfulSpawn: noSuccessfulSpawn, reason: reason)
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
        try replace(current.advancing(to: .terminal, custodian: helperObservation,
            outcome: outcome, reason: reason, waitStatus: status))
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
        fileprivate let observation: InstallationCommandBinding
        private let session: InstallationJournalSession
        fileprivate init(session: InstallationJournalSession, observation: InstallationCommandBinding) {
            self.session = session; self.observation = observation
        }
        var generation: String { observation.control.transaction!.coordinator.process.generation }
        func revalidate() throws { try session.validateCommandPermit(self) }
        func validateOwner(_ owner: InstallationTransactionOwner) throws {
            guard session.owner === owner else { throw CustodyRecordError.fenced }; try revalidate()
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
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !continuationClaimed else { throw CustodyRecordError.fenced }
            continuationClaimed = true
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
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard self.owner === owner, !deadline.hasExpired else { throw CustodyRecordError.fenced }
            try owner.revalidate(); try slots.revalidate(for: owner)
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
            try slots.revalidate(for: owner); try owner.revalidate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
    }
}


extension CustodyCatalogStore {
    /// Observation permit only. No context/helper accepts this type yet. A future
    /// command join must consume it and add semantic postflight plus actual
    /// registry retirement; this value cannot publish command completion.
    final class InstallationStagedCommandObservation {
        let binding: InstallationCommandBinding
        private let session: InstallationStagedJournal
        fileprivate init(session: InstallationStagedJournal, binding: InstallationCommandBinding) {
            self.session = session; self.binding = binding
        }
        func revalidate(deadline: MonotonicDeadline) throws { try session.validate(self, deadline: deadline) }
        func sealedInput(deadline: MonotonicDeadline) throws -> Data {
            try revalidate(deadline: deadline); return try binding.encode()
        }
    }

    /// Continuation of the original detached intent. Only metadata descriptions
    /// are retained between calls; a temporary store borrows the SAME live staged
    /// owner's leases for each bounded write. No old exclusive aliases survive.
    final class InstallationStagedJournal {
        private let owner: InstallationTransactionOwner
        private let admission: InstallationStagedAdmission
        private let intent: InstallationStagedAdmissionIntent
        private let slots: InstallationPreparedSlotObservation
        private let directory: Node
        private let receipts: Node
        private let guardFile: Node
        private var controlPin: Node
        private let catalogPin: InstallationStagedAdmissionIntent.Evidence
        private var receiptPins: [String: InstallationStagedAdmissionIntent.Evidence]
        private var anchor: File
        private var current: InstallationControlRecord
        private var chain: [InstallationStepReceipt]
        private var stop: InstallationStagedStopAdmission?
        private let mutex = NSLock()
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
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if let stop { try stop.validateOwner(owner) }
            else { try admission.validateOwner(owner, intent: intent) }
            try slots.revalidate(for: owner); try owner.revalidate()
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        }
        private func withStore<T>(deadline: MonotonicDeadline, _ body: (CustodyCatalogStore) throws -> T) throws -> T {
            try validateSource(deadline)
            let leases = try stop.map { try $0.retainStopLeases() } ?? admission.retainStartLeases()
            let store = try CustodyCatalogStore(leases: leases)
            let result = try body(store)
            try validateSource(deadline)
            return result
        }
        private func serialized<T>(deadline: MonotonicDeadline,
                                   _ body: (CustodyCatalogStore) throws -> T) throws -> T {
            guard mutex.try() else { throw CustodyRecordError.busy }; defer { mutex.unlock() }
            guard !failed, pending == nil else { throw CustodyRecordError.fenced }
            do { return try withStore(deadline: deadline, body) }
            catch {
                // Temporary stores/lease descendants have unwound before this
                // one-way closure. Keep pending receipt/control and every pin.
                failed = true
                if stop == nil { _ = try? admission.closeStarts() }
                throw error
            }
        }
        private func validateLocked(_ store: CustodyCatalogStore, _ deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try store.validate(directory, at: store.root.value, name: "custody", isDirectory: true)
            try store.validate(guardFile, at: directory.descriptor.value, name: "catalog.lock", isDirectory: false)
            try store.validate(receipts, at: directory.descriptor.value, name: "receipts", isDirectory: true)
            try store.validate(controlPin, at: directory.descriptor.value, name: InstallationControlRecord.filename, isDirectory: false)
            let actual = try store.installationSnapshot(pendingStep: pending?.receipt, pendingControl: pending?.control)
            let catalog = try store.snapshot()
            try store.validate(catalogPin.node, at: directory.descriptor.value, name: "catalog.json", isDirectory: false)
            guard catalog.0.identity == catalogPin.node.identity, catalog.0.acl == catalogPin.node.acl,
                  catalog.0.bytes == catalogPin.bytes, catalog.1.entries.isEmpty,
                  actual.0.identity == anchor.identity, actual.0.acl == anchor.acl,
                  actual.0.bytes == anchor.bytes, actual.1 == current,
                  try InstallationStagedAdmissionIntent.names(receipts.descriptor.value) == Set(receiptPins.keys) else {
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
        private func proposal(_ action: InstallationAction, status: InstallationStepStatus) throws -> Pending {
            guard let transaction = current.transaction, let step = current.step,
                  current.revision < UInt64.max else { throw CustodyRecordError.fenced }
            let receipt = InstallationStepReceipt(transactionID: transaction.id,
                ordinal: status == .complete ? step.ordinal : step.ordinal + 1,
                previousReceiptDigest: current.latestReceiptDigest, action: action, status: status,
                preimage: transaction.slots, postimage: status == .complete ? transaction.slots : nil,
                bindingDigest: try transaction.bindingDigest(state: current.state))
            let canonical = try InstallationStepReceipt.CanonicalObservation(validating: receipt, uid: current.state.directory.uid)
            let next = InstallationControlRecord(revision: current.revision + 1, phase: current.phase,
                state: current.state, transaction: transaction, step: try receipt.step(), latestReceiptDigest: canonical.digest,
                readinessCommit: nil, recoveryReason: current.recoveryReason)
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
            return try store.locked {
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
            try serialized(deadline: deadline) { store in
                guard stop == nil, current.phase == .active, current.step?.action == .openStagedAdmission,
                      current.step?.ordinal == 12, current.step?.status == .intent else { throw CustodyRecordError.fenced }
                // The actual admission capability, original owner, source/slots,
                // complete chain and retained identities were revalidated above.
                return try publish(proposal(.openStagedAdmission, status: .complete), store: store, deadline: deadline)
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
                return InstallationStagedCommandObservation(session: self, binding: binding)
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
        func candidateStopIntent(admission stop: InstallationStagedStopAdmission,
                                 deadline: MonotonicDeadline) throws -> InstallationStagedCommandObservation {
            guard mutex.try() else { throw CustodyRecordError.busy }
            do {
                guard !failed, pending == nil, self.stop == nil, current.phase == .active,
                      current.step?.status == .complete,
                      [.openStagedAdmission, .bootstrapCandidate, .kickstartCandidate].contains(current.step!.action) else { throw CustodyRecordError.fenced }
                try stop.validateOwner(owner)
                self.stop = stop
                mutex.unlock()
            } catch { mutex.unlock(); throw error }
            return try serialized(deadline: deadline) { store in
                let recovery = InstallationControlRecord(revision: current.revision + 1, phase: .recovery,
                    state: current.state, transaction: current.transaction, step: current.step,
                    latestReceiptDigest: current.latestReceiptDigest, readinessCommit: nil, recoveryReason: .readinessFailed)
                try current.validateReplacement(recovery, receipts: chain)
                try store.locked { try validateLocked(store, deadline); try replaceControl(recovery, store: store, deadline: deadline) }
                _ = try publish(proposal(.candidateStop, status: .intent), store: store, deadline: deadline)
                return try observation(store, deadline: deadline)
            }
        }
        fileprivate func validate(_ observation: InstallationStagedCommandObservation, deadline: MonotonicDeadline) throws {
            try serialized(deadline: deadline) { store in
                guard current == observation.binding.control else { throw CustodyRecordError.fenced }
                try store.locked { try validateLocked(store, deadline); try store.validateInstallationCommand(observation.binding) }
            }
        }
        // Deliberately no bootstrap/kickstart/stop completion API. Existing
        // ordinary lifecycle results and stop-only leases do not prove staged
        // candidate semantics, authentication or actual command retirement.
    }
}
