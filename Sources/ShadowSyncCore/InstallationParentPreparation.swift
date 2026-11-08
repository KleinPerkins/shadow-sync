import Darwin
import Foundation

/// The running publisher may prepare these five fixed parent directories only.
/// This object creates no state root, controls, lock, application or LaunchAgent.
/// Keep it alive across fresh-state publication and installation slot capture,
/// and revalidate it at those boundaries. It is not installation authority.
final class InstallationParentPreparation {
    enum Parent: String, CaseIterable {
        case local, state, applications, library, launchAgents
        fileprivate var name: String {
            switch self {
            case .local: return ".local"
            case .state: return "state"
            case .applications: return "Applications"
            case .library: return "Library"
            case .launchAgents: return "LaunchAgents"
            }
        }
        fileprivate var ancestor: Parent? {
            switch self { case .state: return .local; case .launchAgents: return .library; default: return nil }
        }
    }
    struct Identity: Equatable {
        let device: UInt64, inode: UInt64, uid: UInt32, mode: UInt32, flags: UInt32
        let acl: String
        fileprivate init(_ s: stat, acl: String) {
            device = UInt64(s.st_dev); inode = UInt64(s.st_ino); uid = s.st_uid
            mode = UInt32(s.st_mode); flags = s.st_flags; self.acl = acl
        }
        fileprivate func names(_ s: stat) -> Bool {
            device == UInt64(s.st_dev) && inode == UInt64(s.st_ino) && uid == s.st_uid
                && mode == UInt32(s.st_mode) && flags == s.st_flags && s.st_nlink > 0
        }
    }
    enum Progress: String {
        case absent, observedExisting, observedAfterMkdir, observedNodeSynced, observedParentSynced, indeterminate
    }
    /// Observations only, never mkdir-origin identity or ownership evidence.
    /// mkdirat does not return an inode; a safe node first observed afterward
    /// may have replaced the created node before the first stat. These records
    /// confer no deletion, recovery attribution, or installation authority.
    /// Sync states identify successful fsync calls on retained observations,
    /// not proof that this invocation created the named inode.
    struct Evidence: Equatable {
        let parent: Parent
        let identity: Identity?
        let progress: Progress
    }
    private final class Pin {
        let descriptor: OwnedFileDescriptor
        let identity: Identity
        let parent: Pin?
        let name: String
        let privateMode: Bool
        let owner: uid_t
        let ancestor: Bool
        init(descriptor: OwnedFileDescriptor, identity: Identity, parent: Pin?, name: String,
             privateMode: Bool, owner: uid_t, ancestor: Bool) {
            self.descriptor = descriptor; self.identity = identity; self.parent = parent; self.name = name
            self.privateMode = privateMode; self.owner = owner; self.ancestor = ancestor
        }
    }
    private struct Entry {
        var pin: Pin?
        var progress: Progress
    }
    private let publisher: LifecyclePublisher?
    private let source: LifecyclePublisher.InstallationIdentity?
    private let account: EffectiveAccount
    private let home: Pin
    private let mutex = NSLock()
    private var entries: [Parent: Entry] = [:]
    private var failedClosed = false
    #if SHADOW_SYNC_TESTING
    enum Cut: Equatable { case beforeCreate(Parent), beforeMkdir(Parent), beforeFirstObservation(Parent), afterMkdir(Parent), afterCreate(Parent), afterChildSync(Parent), afterParentSync(Parent) }
    private var cut: Cut?
    private var mutation: ((Cut) throws -> Void)?
    private var rejectPublisher = false
    private var rejectSync: Cut?
    #endif

    /// Authentication occurs before any home/path open. Testing executables can
    /// never take this path, even if packaged or signed like the coordinator.
    static func production() throws -> InstallationParentPreparation {
        #if SHADOW_SYNC_TESTING
        throw CustodyRecordError.fenced
        #else
        let publisher = try LifecyclePublisher.current()
        let source = try publisher.installationIdentity()
        return try production(publisher: publisher, source: source)
        #endif
    }
    /// Share the bootstrap's exact authenticated source, without accepting an
    /// account, path or caller-supplied candidate identity.
    static func production(publisher: LifecyclePublisher,
                           source: LifecyclePublisher.InstallationIdentity) throws -> InstallationParentPreparation {
        #if SHADOW_SYNC_TESTING
        throw CustodyRecordError.fenced
        #else
        try publisher.revalidate(); try source.revalidate()
        guard try publisher.installationIdentity() == source else { throw CustodyRecordError.fenced }
        return try Self(publisher: publisher, source: source, account: publisher.account)
        #endif
    }
    private init(publisher: LifecyclePublisher?, source: LifecyclePublisher.InstallationIdentity?,
                 account: EffectiveAccount) throws {
        self.publisher = publisher; self.source = source; self.account = account
        home = try Self.openHome(account)
        try authenticate()
        // Read-only preflight visits all existing fixed parents before any mkdir.
        for parent in Parent.allCases {
            guard let enclosing = enclosingPin(parent) else {
                entries[parent] = Entry(pin: nil, progress: .absent); continue
            }
            if let pin = try Self.openNamed(parent.name, at: enclosing, uid: account.uid,
                                             privateMode: parent == .state, ancestor: false) {
                entries[parent] = Entry(pin: pin, progress: .observedExisting)
            } else { entries[parent] = Entry(pin: nil, progress: .absent) }
        }
        try validateLocked()
    }
    private func authenticate() throws {
        if let publisher, let source {
            try publisher.revalidate(); try source.revalidate()
            guard publisher.account == account, try EffectiveAccount.current() == account,
                  getuid() == account.uid else { throw CustodyRecordError.fenced }
        } else {
            #if SHADOW_SYNC_TESTING
            guard !rejectPublisher, account.uid == geteuid(), account.uid == getuid() else { throw CustodyRecordError.fenced }
            let root = URL(fileURLWithPath: account.homeDirectory).deletingLastPathComponent().path
            _ = try TestIsolation.validateRoot(root)
            try TestIsolation.validateContainedDirectory(account.homeDirectory, root: root)
            #else
            throw CustodyRecordError.fenced
            #endif
        }
    }
    private static func safeDirectoryMode(_ mode: mode_t) -> Bool {
        mode & 0o022 == 0 && mode & 0o7000 == 0
    }
    private static func identity(_ fd: Int32, owner: uid_t, privateMode: Bool, ancestor: Bool) throws -> Identity {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == owner,
              s.st_nlink > 0, ancestor || s.st_flags == 0 else { throw CustodyRecordError.unsafeMetadata }
        var safeMode = safeDirectoryMode(s.st_mode)
        #if SHADOW_SYNC_TESTING
        // Only the already-validated fixture path may cross the system temp
        // ancestor. This exception is absent from production compilation.
        if ancestor && s.st_uid == 0 && s.st_mode & S_ISVTX != 0 { safeMode = true }
        #endif
        guard safeMode, !privateMode || s.st_mode == S_IFDIR | 0o700 else { throw CustodyRecordError.unsafeMetadata }
        let acl = try privateMode ? PolicyAuthorityFile.privateStateACL(fd) : PolicyAuthorityFile.safeACL(fd)
        return Identity(s, acl: acl)
    }
    private static func openNamed(_ name: String, at parent: Pin, uid: uid_t,
                                  privateMode: Bool, ancestor: Bool) throws -> Pin? {
        try validatePin(parent)
        var before = stat()
        if fstatat(parent.descriptor.value, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }; return nil
        }
        guard before.st_mode & S_IFMT == S_IFDIR else { throw CustodyRecordError.unsafeMetadata }
        let raw = openat(parent.descriptor.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let descriptor = OwnedFileDescriptor(raw)
        let value = try identity(raw, owner: uid, privateMode: privateMode, ancestor: ancestor)
        guard value.names(before) else { throw CustodyRecordError.conflict }
        let pin = Pin(descriptor: descriptor, identity: value, parent: parent, name: name,
                      privateMode: privateMode, owner: uid, ancestor: ancestor)
        try validatePin(pin); return pin
    }
    private static func openHome(_ account: EffectiveAccount) throws -> Pin {
        let path = account.homeDirectory
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), parts.count > 1,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CustodyRecordError.fenced }
        let raw = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let descriptor = OwnedFileDescriptor(raw)
        var current = Pin(descriptor: descriptor, identity: try identity(raw, owner: 0, privateMode: false, ancestor: true),
                          parent: nil, name: "/", privateMode: false, owner: 0, ancestor: true)
        for (index, part) in parts.dropFirst().enumerated() {
            var named = stat()
            guard fstatat(current.descriptor.value, String(part), &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_uid == 0 || named.st_uid == account.uid else { throw CustodyRecordError.unsafeMetadata }
            let last = index == parts.count - 2
            guard !last || named.st_uid == account.uid,
                  let next = try openNamed(String(part), at: current, uid: named.st_uid,
                                           privateMode: false, ancestor: !last) else { throw CustodyRecordError.unsafeMetadata }
            current = next
        }
        return current
    }
    private static func validatePin(_ pin: Pin) throws {
        if let parent = pin.parent { try validatePin(parent) }
        guard try identity(pin.descriptor.value, owner: pin.owner, privateMode: pin.privateMode,
                           ancestor: pin.ancestor) == pin.identity else { throw CustodyRecordError.conflict }
        var named = stat()
        let result: Int32
        if let parent = pin.parent { result = fstatat(parent.descriptor.value, pin.name, &named, AT_SYMLINK_NOFOLLOW) }
        else { result = lstat("/", &named) }
        guard result == 0, pin.identity.names(named) else { throw CustodyRecordError.conflict }
    }
    private func enclosingPin(_ parent: Parent) -> Pin? {
        if let ancestor = parent.ancestor { return entries[ancestor]?.pin }; return home
    }
    private func validateLocked(checkContents: Bool = false) throws {
        guard !failedClosed else { throw CustodyRecordError.fenced }
        try authenticate(); try Self.validatePin(home)
        for parent in Parent.allCases {
            guard let entry = entries[parent] else { throw CustodyRecordError.fenced }
            if let pin = entry.pin {
                try Self.validatePin(pin)
                if checkContents && entry.progress != .observedExisting {
                    let allowed = Set(Parent.allCases.filter { $0.ancestor == parent && entries[$0]?.pin != nil }.map(\.name))
                    guard try Self.children(pin) == allowed else { throw CustodyRecordError.conflict }
                }
            }
            else if let enclosing = enclosingPin(parent) {
                var s = stat()
                guard fstatat(enclosing.descriptor.value, parent.name, &s, AT_SYMLINK_NOFOLLOW) == -1,
                      errno == ENOENT else { throw CustodyRecordError.conflict }
            }
        }
    }
    /// Call after preparation and immediately before/after the downstream
    /// initializer and journal capture. Retains original open descriptions.
    func revalidate() throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateLocked()
        guard entries.values.allSatisfy({ $0.progress == .observedExisting || $0.progress == .observedParentSynced }) else {
            throw CustodyRecordError.fenced
        }
    }
    func evidence() -> [Evidence] {
        mutex.lock(); defer { mutex.unlock() }
        return Parent.allCases.map { Evidence(parent: $0, identity: entries[$0]?.pin?.identity,
                                             progress: entries[$0]?.progress ?? .indeterminate) }
    }
    /// A throw preserves all nodes. This SAME object may finish fsync of its
    /// exact retained observations, without attributing their creation. EEXIST
    /// refuses; an unavailable first observation poisons this object. A fresh
    /// invocation independently validates existing parents and inherits no
    /// ownership, cleanup or recovery rights from a previous mkdir result.
    /// The downstream initializer and journal keep their existing authority.
    func prepare() throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateLocked(checkContents: true)
        for parent in Parent.allCases {
            guard var entry = entries[parent], let enclosing = enclosingPin(parent) else { throw CustodyRecordError.fenced }
            if entry.progress == .observedExisting || entry.progress == .observedParentSynced { continue }
            if entry.progress == .absent {
                #if SHADOW_SYNC_TESTING
                try checkpoint(.beforeCreate(parent))
                #endif
                try validateLocked(checkContents: true)
                #if SHADOW_SYNC_TESTING
                try checkpoint(.beforeMkdir(parent))
                #endif
                guard mkdirat(enclosing.descriptor.value, parent.name, 0o700) == 0 else {
                    failedClosed = true; throw CustodyRecordError.persistence(errno)
                }
                // A successful mkdir supplies no inode identity. First capture
                // a safe named/opened observation, without claiming its origin.
                // An unavailable or unsafe observation fences this invocation.
                entries[parent] = Entry(pin: nil, progress: .indeterminate)
                do {
                    #if SHADOW_SYNC_TESTING
                    try checkpoint(.beforeFirstObservation(parent))
                    #endif
                    var observed = stat()
                    guard fstatat(enclosing.descriptor.value, parent.name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
                          observed.st_mode == S_IFDIR | 0o700, observed.st_uid == account.uid,
                          observed.st_flags == 0 else { throw CustodyRecordError.conflict }
                    #if SHADOW_SYNC_TESTING
                    try checkpoint(.afterMkdir(parent))
                    #endif
                    guard let pin = try Self.openNamed(parent.name, at: enclosing, uid: account.uid,
                                                      privateMode: true, ancestor: false),
                          pin.identity.names(observed), try Self.children(pin).isEmpty else { throw CustodyRecordError.conflict }
                    entry = Entry(pin: pin, progress: .observedAfterMkdir); entries[parent] = entry
                } catch { failedClosed = true; throw error }
                #if SHADOW_SYNC_TESTING
                try checkpoint(.afterCreate(parent))
                #endif
            }
            guard let pin = entry.pin else { throw CustodyRecordError.fenced }
            try validateLocked(checkContents: true)
            if entry.progress == .observedAfterMkdir {
                #if SHADOW_SYNC_TESTING
                if rejectSync == .afterChildSync(parent) { throw CustodyRecordError.persistence(EIO) }
                #endif
                guard fsync(pin.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
                entry.progress = .observedNodeSynced; entries[parent] = entry
                #if SHADOW_SYNC_TESTING
                try checkpoint(.afterChildSync(parent))
                #endif
            }
            try validateLocked(checkContents: true)
            #if SHADOW_SYNC_TESTING
            if rejectSync == .afterParentSync(parent) { throw CustodyRecordError.persistence(EIO) }
            #endif
            guard fsync(enclosing.descriptor.value) == 0 else { throw CustodyRecordError.persistence(errno) }
            try validateLocked(checkContents: true)
            entry.progress = .observedParentSynced; entries[parent] = entry
            #if SHADOW_SYNC_TESTING
            try checkpoint(.afterParentSync(parent))
            #endif
        }
        try validateLocked(checkContents: true)
    }
    private static func children(_ pin: Pin) throws -> Set<String> {
        let fd = openat(pin.descriptor.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CustodyRecordError.unsafeMetadata }
        guard let directory = fdopendir(fd) else { close(fd); throw CustodyRecordError.unsafeMetadata }
        defer { closedir(directory) }
        var result = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw CustodyRecordError.unsafeMetadata }; return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
            guard result.count <= 1024 else { throw CustodyRecordError.unsafeMetadata }
        }
    }
    #if SHADOW_SYNC_TESTING
    // Pure mode-predicate coverage only; this does not construct a live identity
    // or bypass any owner, descriptor, ACL, flag or namespace check.
    static func testingSafeDirectoryMode(_ mode: mode_t) -> Bool {
        safeDirectoryMode(mode)
    }
    static func testing(root: String) throws -> InstallationParentPreparation {
        let root = try TestIsolation.validateRoot(root)
        let account = try EffectiveAccount.isolated(homeDirectory: root + "/home")
        return try Self(publisher: nil, source: nil, account: account)
    }
    static func testingWrongOwner(root: String) throws {
        let root = try TestIsolation.validateRoot(root)
        let raw = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }; defer { close(raw) }
        _ = try identity(raw, owner: geteuid() == 0 ? 1 : 0, privateMode: true, ancestor: false)
    }
    func testingCut(_ cut: Cut?) { self.cut = cut }
    func testingMutation(_ mutation: ((Cut) throws -> Void)?) { self.mutation = mutation }
    func testingRejectPublisher() { rejectPublisher = true }
    func testingSyncFailure(_ cut: Cut?) { rejectSync = cut }
    private func checkpoint(_ stage: Cut) throws {
        try mutation?(stage)
        if cut == stage { cut = nil; throw CustodyRecordError.persistence(EINTR) }
    }
    #endif
}
