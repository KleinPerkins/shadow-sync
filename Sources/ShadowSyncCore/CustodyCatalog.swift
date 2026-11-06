import Darwin
import Foundation

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

    init(leases: CustodyAuthorityLeaseSet, releaseSHA256: String, generation: String) throws {
        guard CustodyWire.hex(releaseSHA256, bytes: 32), RunIdentity.isValid(generation) else { throw CustodyRecordError.invalidRecord }
        self.leases = leases; self.releaseSHA256 = releaseSHA256; self.generation = generation
        bootID = try CustodyBootIdentity.current(); uid = geteuid()
        store = try CustodyCatalogStore(leases: leases)
        // Validate all evidence now, then again in the same guarded transition
        // as every reservation. This initial read is never cached admission.
        try store.checkFence(ownRequests: [], scope: id, mode: leases.mode)
    }
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
        mutex.lock(); defer { mutex.unlock() }
        guard state == .open, request.binding.scopeID == id, request.binding.bootID == bootID,
              request.binding.releaseSHA256 == releaseSHA256, request.binding.callerGeneration == generation,
              request.binding.trustedUID == uid, request.authority == leases.mode else { throw CustodyRecordError.fenced }
        _ = try request.encode()
        try request.budget.validate(kind: request.kind, permittedWorkSeconds: request.kind.maximumWorkSeconds,
                                    now: DispatchTime.now().uptimeNanoseconds)
        let journal = try CustodyJournal(prepared: request, leases: leases.descriptorClaims())
        do {
            try store.reserveAndPrepare(journal, ownRequests: liveRequests, scope: id)
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

/// Descriptor-relative, app-owned metadata only. Its stable guard is acquired
/// last, held only for bounded metadata transitions, and never grants operation
/// authority. No public callbacks run while it is held.
final class CustodyCatalogStore: @unchecked Sendable {
    private struct Node {
        let descriptor: OwnedFileDescriptor
        let identity: FileIdentity
        let acl: String
    }
    private struct File {
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
    private func snapshot() throws -> (File, CustodyCatalog, [String: CustodyJournal]) {
        let file = try read("catalog.json", maximum: CustodyCatalog.maximumBytes), catalog = try CustodyCatalog.decode(file.bytes)
        var journals: [String: CustodyJournal] = [:]
        let expected = Set(catalog.entries.map(\.filename)), all = Set(try names())
        guard expected.isSubset(of: all), all.contains("catalog.lock"), all.contains("receipts") else { throw CustodyRecordError.fenced }
        for name in all.subtracting(["catalog.json", "catalog.lock", "receipts"]) {
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
    func checkFence(ownRequests: Set<String>, scope: String, mode: CustodyAuthorityMode) throws {
        try locked { let s = try snapshot(); try fence(s.1, journals: s.2, ownRequests: ownRequests, scope: scope, mode: mode) }
    }
    fileprivate func reserveAndPrepare(_ journal: CustodyJournal, ownRequests: Set<String>, scope: String) throws {
        try locked {
            guard journal.authority == leases.mode, journal.binding.scopeID == scope,
                  journal.binding.uid == uid, journal.phase == .prepared else { throw CustodyRecordError.fenced }
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
        guard inherited.request.kind == .discoveryGit, current.phase == .executing,
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
