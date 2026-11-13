import Darwin
import Foundation

/// Coordinator-only fresh-state creation. Startup cannot construct this from an
/// existing state root. The parent and immutable phase records are retained for
/// the enclosing install transaction; this component never deletes user state.
final class FreshStateInitialization {
    private struct Node: Equatable {
        let device: UInt64, inode: UInt64, uid: UInt32, mode: UInt32
        init(_ s: stat) {
            device = UInt64(s.st_dev); inode = UInt64(s.st_ino); uid = s.st_uid; mode = UInt32(s.st_mode)
        }
        var wire: PolicyWireValue { .object(["device": .unsigned(device), "inode": .unsigned(inode), "uid": .unsigned(UInt64(uid)), "mode": .unsigned(UInt64(mode))]) }
    }
    struct Result: Equatable {
        let transaction: String
        let stateDevice: UInt64
        let stateInode: UInt64
        let publicationReceiptSHA256: String
    }
    /// Only fresh initialization can inspect the fenced initial controls.
    /// This capsule identifies retained leases; it grants no operation permission.
    struct ControlInspection {
        let leases: CustodyAuthorityLeaseSet
        fileprivate init(leases: CustodyAuthorityLeaseSet) { self.leases = leases }
    }
    /// Only this initializer can construct a publication capability. The
    /// installer receives a RunAuthority, never this capsule or raw descriptors.
    struct PublishedState {
        let location: StateLocation
        let result: Result
        let leases: CustodyAuthorityLeaseSet
        #if SHADOW_SYNC_TESTING
        fileprivate(set) var testingFailureAfterCopies: Int?
        #endif
        fileprivate init(location: StateLocation, result: Result, leases: CustodyAuthorityLeaseSet) {
            self.location = location; self.result = result; self.leases = leases
        }
    }
    private let publisher: LifecyclePublisher?
    private let location: StateLocation
    private let parent: SecureStateDirectory
    private let parentIdentity: Node
    private let guardFile: OwnedFileDescriptor
    private let guardIdentity: Node
    private let release: String
    private let mutex = NSLock()
    private var serializing = false
    private var metadataGeneration: UInt64 = 0
    private var leases: CustodyAuthorityLeaseSet?
    private var completed: Result?
    private var installationAuthorityTaken = false
    private static let manifestName = ".shadow-sync-initialization.json"
    private static let guardName = ".shadow-sync-initialization.lock"
    private static let finalName = "shadow-sync"
    private static var legacyName: String { String(LegacyInstallationRelease.bundleIdentifier.split(separator: ".").last!) }
    #if SHADOW_SYNC_TESTING
    enum Fault: Equatable { case afterManifest, afterStage, afterCreated, afterFiles, afterReady, afterPublication, temporaryCreated(String), partialWrite(String) }
    private var fault: Fault?
    private var crashAtFault = false
    #endif

    private init(location: StateLocation, release: String, publisher: LifecyclePublisher?) throws {
        guard location.components.last == Self.finalName, CustodyWire.hex(release, bytes: 32) else { throw CustodyRecordError.fenced }
        self.location = location; self.release = release; self.publisher = publisher
        let parentLocation = StateLocation(anchorPath: location.anchorPath, components: Array(location.components.dropLast()), uid: location.uid)
        parent = try SecureStateDirectory.openExisting(parentLocation)
        parentIdentity = try Self.node(parent.descriptor.value, uid: location.uid, directory: true)
        var existing = stat()
        let parentFD = parent.descriptor.value
        func present(_ name: String) throws -> Bool {
            if fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }; return false
        }
        guard try !present(Self.legacyName), try !present(Self.finalName) || present(Self.manifestName) else {
            throw CustodyRecordError.conflict
        }
        // The guard serializes initialization only; it never substitutes for
        // the operation locks that become part of the completed state tree.
        let manifestTemporary = ".shadow-sync-initialization-write." + CustodyRecordBinding.digest(Data(Self.manifestName.utf8))
        let established = try present(Self.manifestName) || present(manifestTemporary)
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (established ? 0 : O_CREAT)
        let raw = openat(parent.descriptor.value, Self.guardName, flags, 0o600)
        guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
        guardFile = OwnedFileDescriptor(raw)
        guardIdentity = try Self.node(raw, uid: location.uid, directory: false)
        var info = stat()
        guard fstat(raw, &info) == 0, info.st_size == 0 else { throw CustodyRecordError.unsafeMetadata }
        guard flock(raw, LOCK_EX | LOCK_NB) == 0 else { throw CustodyRecordError.busy }
        try validate()
        guard fsync(raw) == 0, fsync(parent.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
    }
    static func production() throws -> FreshStateInitialization {
        let publisher = try LifecyclePublisher.current()
        return try production(publisher: publisher, source: publisher.installationIdentity())
    }
    /// Fixed production location from the same authenticated running source as
    /// parent preparation. No testing executable can enter this factory.
    static func production(publisher: LifecyclePublisher,
                           source: LifecyclePublisher.InstallationIdentity) throws -> FreshStateInitialization {
        #if SHADOW_SYNC_TESTING
        throw CustodyRecordError.fenced
        #else
        try publisher.revalidate(); try source.revalidate()
        let location = try StateLocation.production()
        guard try publisher.installationIdentity() == source,
              location.anchorPath == publisher.account.homeDirectory,
              location.uid == publisher.account.uid,
              source.sourceReleaseDigest == publisher.releaseSHA256 else { throw CustodyRecordError.fenced }
        return try Self(location: location, release: publisher.releaseSHA256, publisher: publisher)
        #endif
    }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    static func signedFixture(_ context: SignedInstallationFixtureContext) throws -> FreshStateInitialization {
        try context.revalidate()
        try context.profile.validateLocation(context.paths.state)
        return try Self(location: context.paths.state, release: context.publisher.releaseSHA256,
                        publisher: context.publisher)
    }
    #endif
    private static func node(_ fd: Int32, uid: uid_t, directory: Bool) throws -> Node {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == uid, s.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600),
              directory || s.st_nlink == 1 else { throw CustodyRecordError.unsafeMetadata }
        _ = try PolicyAuthorityFile.privateStateACL(fd)
        return Node(s)
    }
    private func validate() throws {
        if let publisher {
            try publisher.revalidate(); try publisher.validationProfile.validateLocation(location)
        }
        else {
            #if !SHADOW_SYNC_TESTING
            throw CustodyRecordError.fenced
            #endif
        }
        let fresh = try SecureStateDirectory.openExisting(StateLocation(anchorPath: location.anchorPath,
            components: Array(location.components.dropLast()), uid: location.uid))
        guard try Self.node(fresh.descriptor.value, uid: location.uid, directory: true) == parentIdentity,
              try Self.node(parent.descriptor.value, uid: location.uid, directory: true) == parentIdentity,
              try Self.node(guardFile.value, uid: location.uid, directory: false) == guardIdentity else { throw CustodyRecordError.fenced }
        var named = stat()
        guard fstatat(parent.descriptor.value, Self.guardName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Node(named) == guardIdentity, named.st_nlink == 1, named.st_size == 0 else { throw CustodyRecordError.fenced }
        // A legacy namespace requires the accepted identity-migration path.
        guard try !exists(Self.legacyName, at: parent.descriptor.value) else { throw CustodyRecordError.conflict }
        try leases?.validate()
    }
    private func exists(_ name: String, at parent: Int32) throws -> Bool {
        var s = stat()
        if fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }; return false
    }
    private func directory(_ name: String, at parent: Int32) throws -> OwnedFileDescriptor {
        let raw = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let fd = OwnedFileDescriptor(raw); _ = try Self.node(raw, uid: location.uid, directory: true)
        return fd
    }
    private func read(_ name: String, at parent: Int32) throws -> Data {
        let raw = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let fd = OwnedFileDescriptor(raw); let before = try Self.node(raw, uid: location.uid, directory: false)
        var s = stat(); guard fstat(raw, &s) == 0, s.st_size >= 0, s.st_size <= 262_144 else { throw CustodyRecordError.unsafeMetadata }
        let initial = FileIdentity(s); let expected = s.st_size
        let modified = s.st_mtimespec, changed = s.st_ctimespec
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(raw, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw CustodyRecordError.persistence(errno) }
            if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
            guard data.count <= 262_144 else { throw CustodyRecordError.unsafeMetadata }
        }
        var named = stat()
        guard fstat(raw, &s) == 0, FileIdentity(s) == initial, s.st_size == expected, data.count == expected,
              s.st_mtimespec.tv_sec == modified.tv_sec, s.st_mtimespec.tv_nsec == modified.tv_nsec,
              s.st_ctimespec.tv_sec == changed.tv_sec, s.st_ctimespec.tv_nsec == changed.tv_nsec,
              try Self.node(fd.value, uid: location.uid, directory: false) == before,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity(named) == initial else { throw CustodyRecordError.fenced }
        return data
    }
    private func temporaryName(_ name: String) -> String {
        ".shadow-sync-initialization-write." + CustodyRecordBinding.digest(Data(name.utf8))
    }
    private func writeOnce(_ name: String, bytes: Data, at parent: Int32) throws {
        let temporary = temporaryName(name)
        if try exists(name, at: parent) {
            guard try !exists(temporary, at: parent), try read(name, at: parent) == bytes else { throw CustodyRecordError.conflict }
            let raw = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }; defer { close(raw) }
            guard fsync(raw) == 0, fsync(parent) == 0 else { throw CustodyRecordError.persistence(errno) }
            return
        }
        // A fixed per-destination temporary can survive actual process death.
        // Resume only an exact byte prefix; never truncate or overwrite bytes.
        var raw = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if raw < 0 && errno == EEXIST { raw = openat(parent, temporary, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
        let fd = OwnedFileDescriptor(raw); let identity = try Self.node(raw, uid: location.uid, directory: false)
        #if SHADOW_SYNC_TESTING
        try fail(.temporaryCreated(name))
        #endif
        let prefix = try read(temporary, at: parent)
        guard bytes.starts(with: prefix), lseek(raw, off_t(prefix.count), SEEK_SET) == prefix.count else { throw CustodyRecordError.conflict }
        try bytes.withUnsafeBytes { buffer in
            var offset = prefix.count
            while offset < buffer.count {
                var count = buffer.count - offset
                #if SHADOW_SYNC_TESTING
                if fault == .partialWrite(name) { count = max(1, count / 2) }
                #endif
                let written = Darwin.write(fd.value, buffer.baseAddress!.advanced(by: offset), count)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CustodyRecordError.persistence(errno) }; offset += written
                #if SHADOW_SYNC_TESTING
                if fault == .partialWrite(name) { guard fsync(raw) == 0 else { throw CustodyRecordError.persistence(errno) }; try fail(.partialWrite(name)) }
                #endif
            }
        }
        var named = stat()
        guard try Self.node(raw, uid: location.uid, directory: false) == identity,
              fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, Node(named) == identity,
              try read(temporary, at: parent) == bytes else { throw CustodyRecordError.fenced }
        guard fsync(raw) == 0, renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0,
              fsync(parent) == 0 else { throw CustodyRecordError.persistence(errno) }
        guard try read(name, at: parent) == bytes else { throw CustodyRecordError.fenced }
    }
    private func names(_ fd: Int32) throws -> Set<String> {
        let raw = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        guard let stream = fdopendir(raw) else { close(raw); throw CustodyRecordError.unsafeMetadata }
        defer { closedir(stream) }; var result: Set<String> = []
        while true {
            errno = 0
            guard let row = readdir(stream) else { guard errno == 0 else { throw CustodyRecordError.persistence(errno) }; return result }
            let name = withUnsafePointer(to: row.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }; result.insert(name)
            guard result.count <= 32 else { throw CustodyRecordError.fenced }
        }
    }
    private func phase(_ name: String, manifest: Data, state: Node, controls: PolicyWireValue = .object([:])) throws -> Data {
        try CustodyWire.encode(.object(["schema": .string("shadow-sync-state-initialization-phase/v1"),
            "phase": .string(name), "manifest_sha256": .string(CustodyRecordBinding.digest(manifest)), "state": state.wire, "controls": controls]), maximum: 4096)
    }
    private func fill(_ state: OwnedFileDescriptor) throws {
        let expected: Set<String> = ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock", "custody"]
        let pending = Set(expected.subtracting(["custody"]).map { temporaryName($0) })
        guard try names(state.value).isSubset(of: expected.union(pending)) else { throw CustodyRecordError.conflict }
        for name in expected.subtracting(["custody"]).sorted() { try writeOnce(name, bytes: Data(), at: state.value) }
        if try !exists("custody", at: state.value) {
            guard mkdirat(state.value, "custody", 0o700) == 0, fsync(state.value) == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        let custody = try directory("custody", at: state.value)
        guard try names(custody.value).isSubset(of: ["catalog.lock", "catalog.json", InstallationControlRecord.filename, "receipts",
            temporaryName("catalog.lock"), temporaryName("catalog.json"), temporaryName(InstallationControlRecord.filename)]) else { throw CustodyRecordError.conflict }
        if try !exists("receipts", at: custody.value) {
            guard mkdirat(custody.value, "receipts", 0o700) == 0, fsync(custody.value) == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        let receipts = try directory("receipts", at: custody.value)
        guard try names(receipts.value).isEmpty else { throw CustodyRecordError.conflict }
        try writeOnce("catalog.lock", bytes: Data(), at: custody.value)
        try writeOnce("catalog.json", bytes: CustodyCatalog.initialized.encode(), at: custody.value)
        let initial = try InstallationControlRecord.initial(state:
            InstallationStateBinding.capture(stateDescriptor: state.value, uid: location.uid)).encode()
        try writeOnce(InstallationControlRecord.filename, bytes: initial, at: custody.value)
        guard fsync(receipts.value) == 0, fsync(custody.value) == 0, fsync(state.value) == 0 else { throw CustodyRecordError.persistence(errno) }
    }

    /// Readiness binds every control inode, so a retry cannot replace an empty
    /// lock or recreate a lost catalog after another process could have observed it.
    private func controlIdentities(_ state: OwnedFileDescriptor) throws -> PolicyWireValue {
        let files = ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock"]
        guard try names(state.value) == Set(files + ["custody"]) else { throw CustodyRecordError.fenced }
        let custody = try directory("custody", at: state.value), receipts = try directory("receipts", at: custody.value)
        guard try names(custody.value) == ["catalog.lock", "catalog.json", InstallationControlRecord.filename, "receipts"],
              try names(receipts.value).isEmpty else { throw CustodyRecordError.fenced }
        let initial = try InstallationControlRecord.initial(state:
            InstallationStateBinding.capture(stateDescriptor: state.value, uid: location.uid)).encode()
        var controls: [String: PolicyWireValue] = ["custody": try Self.node(custody.value, uid: location.uid, directory: true).wire,
            "custody/receipts": try Self.node(receipts.value, uid: location.uid, directory: true).wire]
        for (fd, name, key, bytes) in files.map({ (state.value, $0, $0, Data()) }) + [
            (custody.value, "catalog.lock", "custody/catalog.lock", Data()),
            (custody.value, "catalog.json", "custody/catalog.json", try CustodyCatalog.initialized.encode()),
            (custody.value, InstallationControlRecord.filename, "custody/" + InstallationControlRecord.filename, initial)] {
            guard try read(name, at: fd) == bytes else { throw CustodyRecordError.fenced }
            let raw = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
            let owned = OwnedFileDescriptor(raw)
            controls[key] = try Self.node(owned.value, uid: location.uid, directory: false).wire
        }
        return .object(controls)
    }
    private func initialManifest() throws -> Data {
        // Deterministic identity permits reconstruction after a partial first
        // manifest write. This identifier binds context; it grants no authority.
        let seed = try CustodyWire.encode(.object(["release": .string(release), "parent": parentIdentity.wire, "guard": guardIdentity.wire]), maximum: 4096)
        let h = Array(CustodyRecordBinding.digest(seed).prefix(32))
        let tx = [String(h[0..<8]), String(h[8..<12]), String(h[12..<16]), String(h[16..<20]), String(h[20..<32])].joined(separator: "-")
        return try CustodyWire.encode(.object(["schema": .string("shadow-sync-state-initialization/v1"),
            "transaction": .string(tx), "release": .string(release), "parent": parentIdentity.wire, "guard": guardIdentity.wire]), maximum: 4096)
    }

    /// Reserve one publication/transfer turn. Only bookkeeping holds the mutex;
    /// source verification, filesystem work and handoff waits execute outside it.
    private func serialized<T>(_ action: () throws -> T) throws -> T {
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

    /// Publishes only initialized state. It does not publish the app, register a
    /// service, change startup preference, activate policy, or access repositories.
    func publish() throws -> Result {
        return try serialized {
            guard !installationAuthorityTaken else { throw CustodyRecordError.fenced }
            try validate()
            if let completed {
                var current = stat()
                guard fstatat(parent.descriptor.value, Self.finalName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      UInt64(current.st_dev) == completed.stateDevice, UInt64(current.st_ino) == completed.stateInode,
                      let leases else { throw CustodyRecordError.fenced }
                try validatePublication(completed, leases: leases)
                return completed
            }
            let p = parent.descriptor.value
            let manifest: Data
            if try exists(Self.manifestName, at: p) { manifest = try read(Self.manifestName, at: p) }
            else {
                guard try !exists(Self.finalName, at: p) else { throw CustodyRecordError.conflict }
                manifest = try initialManifest()
                try writeOnce(Self.manifestName, bytes: manifest, at: p)
            }
            let wire = try CustodyWire.decode(manifest, maximum: 4096).object(keys: ["schema", "transaction", "release", "parent", "guard"])
            let tx = try CustodyWire.text(wire["transaction"])
            guard wire["schema"] == .string("shadow-sync-state-initialization/v1"), wire["release"] == .string(release),
                  wire["parent"] == parentIdentity.wire, wire["guard"] == guardIdentity.wire, RunIdentity.isValid(tx) else { throw CustodyRecordError.fenced }
            let stageName = ".shadow-sync-initialization." + tx
            func record(_ phase: String) -> String { stageName + "." + phase + ".json" }
            #if SHADOW_SYNC_TESTING
            try fail(.afterManifest)
            #endif
            let hasCreated = try exists(record("created"), at: p), hasReady = try exists(record("ready"), at: p)
            let hasPublished = try exists(record("published"), at: p)
            guard (!hasReady || hasCreated) && (!hasPublished || hasReady) else { throw CustodyRecordError.fenced }
            let hasStage = try exists(stageName, at: p), hasFinal = try exists(Self.finalName, at: p)
            guard !(hasStage && hasFinal) else { throw CustodyRecordError.conflict }
            guard !hasFinal || hasReady else { throw CustodyRecordError.conflict }
            guard !hasPublished || hasFinal else { throw CustodyRecordError.fenced }
            if !hasStage && !hasFinal {
                guard !hasCreated, mkdirat(p, stageName, 0o700) == 0, fsync(p) == 0 else { throw CustodyRecordError.fenced }
            }
            let stateName = hasFinal ? Self.finalName : stageName
            let state = try directory(stateName, at: p), identity = try Self.node(state.value, uid: location.uid, directory: true)
            let created = try phase("created", manifest: manifest, state: identity)
            if hasCreated { guard try read(record("created"), at: p) == created else { throw CustodyRecordError.fenced } }
            else {
                // Only a strictly empty owner-private reserved staging directory can
                // bridge the mkdir/created-receipt crash window. Never adopt contents.
                guard !hasFinal, try names(state.value).isEmpty else { throw CustodyRecordError.conflict }
                #if SHADOW_SYNC_TESTING
                try fail(.afterStage)
                #endif
                try writeOnce(record("created"), bytes: created, at: p)
            }
            if hasReady {
                let controls = try controlIdentities(state)
                guard try read(record("ready"), at: p) == phase("ready", manifest: manifest, state: identity, controls: controls) else { throw CustodyRecordError.fenced }
                if hasPublished { guard try read(record("published"), at: p) == phase("published", manifest: manifest, state: identity, controls: controls) else { throw CustodyRecordError.fenced } }
            }
            #if SHADOW_SYNC_TESTING
            try fail(.afterCreated)
            #endif
            if !hasFinal && !hasReady {
                try fill(state)
                #if SHADOW_SYNC_TESTING
                try fail(.afterFiles)
                #endif
            }
            let stateLocation = StateLocation(anchorPath: parent.path, components: [stateName], uid: location.uid)
            if let leases {
                let claim = try leases.descriptorClaims().first { $0.role == .state }
                guard claim?.device == identity.device, claim?.inode == identity.inode else { throw CustodyRecordError.fenced }
            } else { leases = try CustodyAuthorityLeaseSet.retainRecoveryLeases(at: stateLocation) }
            let store = try CustodyCatalogStore(leases: leases!)
            try store.checkFreshInitializationFence(ControlInspection(leases: leases!))
            let controls = try controlIdentities(state)
            let ready = try phase("ready", manifest: manifest, state: identity, controls: controls)
            if hasFinal { guard try read(record("ready"), at: p) == ready else { throw CustodyRecordError.fenced } }
            else { try writeOnce(record("ready"), bytes: ready, at: p) }
            #if SHADOW_SYNC_TESTING
            try fail(.afterReady)
            #endif
            try validate()
            var named = stat()
            guard fstatat(p, stateName, &named, AT_SYMLINK_NOFOLLOW) == 0, Node(named) == identity else { throw CustodyRecordError.fenced }
            if !hasFinal {
                guard renameatx_np(p, stageName, p, Self.finalName, UInt32(RENAME_EXCL)) == 0,
                      fsync(p) == 0 else { throw CustodyRecordError.persistence(errno) }
            }
            #if SHADOW_SYNC_TESTING
            try fail(.afterPublication)
            #endif
            guard fstatat(p, Self.finalName, &named, AT_SYMLINK_NOFOLLOW) == 0, Node(named) == identity else { throw CustodyRecordError.fenced }
            let published = try phase("published", manifest: manifest, state: identity, controls: controls)
            try writeOnce(record("published"), bytes: published, at: p)
            let result = Result(transaction: tx, stateDevice: identity.device, stateInode: identity.inode,
                                publicationReceiptSHA256: CustodyRecordBinding.digest(published))
            completed = result; return result
        }
    }

    /// Transfers original open-file descriptions after publication; no lock is
    /// reopened or unlocked. Failure leaves the initializer's owners intact.
    /// This does not start an installation or permit post-staged commands.
    func takeInstallationAuthority() throws -> RunAuthority {
        return try serialized {
            guard !installationAuthorityTaken, let completed, let leases,
                  leases.mode == .mutation else { throw CustodyRecordError.fenced }
            try validatePublication(completed, leases: leases)
            #if SHADOW_SYNC_TESTING
            var publication = PublishedState(location: location, result: completed, leases: leases)
            mutex.lock(); publication.testingFailureAfterCopies = installationCopyFailureAfter
            installationCopyFailureAfter = nil; mutex.unlock()
            #else
            let publication = PublishedState(location: location, result: completed, leases: leases)
            #endif
            let authority = try RunAuthority.adoptingPublishedState(publication)
            #if SHADOW_SYNC_TESTING
            mutex.lock(); let barrier = installationHandoffBarrier
            installationHandoffBarrier = nil; mutex.unlock()
            if let barrier {
                guard barrier.pause() else { throw CustodyRecordError.busy }
            }
            #endif
            try validatePublication(completed, leases: leases)
            installationAuthorityTaken = true
            self.leases = nil
            // Local publication/store references expire before the caller can use
            // staged admission. The returned owner retains no parent lease family.
            return authority
        }
    }

    private func validatePublication(_ result: Result, leases: CustodyAuthorityLeaseSet) throws {
        try validate()
        let p = parent.descriptor.value
        let manifest = try read(Self.manifestName, at: p)
        guard manifest == (try initialManifest()) else { throw CustodyRecordError.fenced }
        let wire = try CustodyWire.decode(manifest, maximum: 4096)
            .object(keys: ["schema", "transaction", "release", "parent", "guard"])
        guard wire["transaction"] == .string(result.transaction) else { throw CustodyRecordError.fenced }
        let state = try directory(Self.finalName, at: p)
        let identity = try Self.node(state.value, uid: location.uid, directory: true)
        guard identity.device == result.stateDevice, identity.inode == result.stateInode,
              let held = try leases.descriptorClaims().first(where: { $0.role == .state }),
              held.device == identity.device, held.inode == identity.inode else { throw CustodyRecordError.fenced }
        let prefix = ".shadow-sync-initialization." + result.transaction
        guard try !exists(prefix, at: p) else { throw CustodyRecordError.conflict }
        let controls = try controlIdentities(state)
        let published = try phase("published", manifest: manifest, state: identity, controls: controls)
        guard try read(prefix + ".created.json", at: p) == phase("created", manifest: manifest, state: identity),
              try read(prefix + ".ready.json", at: p) == phase("ready", manifest: manifest, state: identity, controls: controls),
              try read(prefix + ".published.json", at: p) == published,
              CustodyRecordBinding.digest(published) == result.publicationReceiptSHA256 else { throw CustodyRecordError.fenced }
        let store = try CustodyCatalogStore(leases: leases)
        try store.checkFreshInitializationFence(ControlInspection(leases: leases))
        try validate()
        var named = stat()
        guard fstatat(p, Self.finalName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Node(named) == identity else { throw CustodyRecordError.fenced }
    }
    #if SHADOW_SYNC_TESTING
    private var installationHandoffBarrier: CustodyLeaseTestingBarrier?
    private var installationCopyFailureAfter: Int?
    func testingFailInstallationCopy(after count: Int) {
        mutex.lock(); installationCopyFailureAfter = count; mutex.unlock()
    }
    func testingPauseInstallationHandoff(_ barrier: CustodyLeaseTestingBarrier) {
        mutex.lock(); installationHandoffBarrier = barrier; mutex.unlock()
    }
    static func testing(root: String, release: String = String(repeating: "e", count: 64)) throws -> FreshStateInitialization {
        let location = try StateLocation.isolated(root: root)
        return try Self(location: location, release: release, publisher: nil)
    }
    func testingFault(_ cut: Fault) { mutex.lock(); fault = cut; mutex.unlock() }
    func testingCrash(_ cut: Fault) { mutex.lock(); fault = cut; crashAtFault = true; mutex.unlock() }
    private func fail(_ cut: Fault) throws {
        mutex.lock(); let fail = fault == cut, crash = crashAtFault
        if fail { fault = nil }; mutex.unlock()
        if fail { if crash { _exit(94) }; throw CustodyRecordError.injectedFailure }
    }
    #endif
}
