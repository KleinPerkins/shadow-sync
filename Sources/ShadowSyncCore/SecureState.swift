import Darwin
import Foundation

public enum SecureStateError: Error, CustomStringConvertible {
    case accountLookup(Int32)
    case invalidAccountRecord
    case unsafePath(String)
    case systemCall(String, Int32)
    case contention(String)

    public var description: String {
        switch self {
        case let .accountLookup(code):
            return "effective account lookup failed (\(code))"
        case .invalidAccountRecord:
            return "effective account record is incomplete"
        case let .unsafePath(path):
            return "unsafe state path: \(path)"
        case let .systemCall(name, code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        case let .contention(name):
            return "\(name) is already owned"
        }
    }
}

public struct EffectiveAccount: Equatable, Sendable {
    public let uid: uid_t
    public let username: String
    public let homeDirectory: String

    public static func current() throws -> EffectiveAccount {
        let uid = geteuid()
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        let size = suggested > 0 ? Int(suggested) : 16_384
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: size)
        let count = buffer.count
        let code = getpwuid_r(uid, &record, &buffer, count, &result)
        guard code == 0 else {
            throw SecureStateError.accountLookup(code)
        }
        guard result != nil, let name = record.pw_name, let home = record.pw_dir else {
            throw SecureStateError.invalidAccountRecord
        }
        let username = String(cString: name)
        let homeDirectory = String(cString: home)
        guard homeDirectory.hasPrefix("/"), !username.isEmpty else {
            throw SecureStateError.invalidAccountRecord
        }
        return EffectiveAccount(uid: uid, username: username, homeDirectory: homeDirectory)
    }

    #if SHADOW_SYNC_TESTING
    public static func isolated(homeDirectory: String) throws -> EffectiveAccount {
        let root = URL(fileURLWithPath: homeDirectory).deletingLastPathComponent().path
        _ = try TestIsolation.validateRoot(root)
        try TestIsolation.validateContainedDirectory(homeDirectory, root: root)
        let current = try Self.current()
        return EffectiveAccount(
            uid: current.uid,
            username: current.username,
            homeDirectory: homeDirectory
        )
    }
    #endif
}

public struct StateLocation: Equatable, Sendable {
    public let anchorPath: String
    public let components: [String]
    public let uid: uid_t

    public static func production() throws -> StateLocation {
        let account = try EffectiveAccount.current()
        return StateLocation(
            anchorPath: account.homeDirectory,
            components: [".local", "state", "shadow-sync"],
            uid: account.uid
        )
    }

    init(anchorPath: String, components: [String], uid: uid_t) {
        self.anchorPath = anchorPath
        self.components = components
        self.uid = uid
    }

    #if SHADOW_SYNC_TESTING
    public static func isolated(root: String) throws -> StateLocation {
        let root = try TestIsolation.validateRoot(root)
        return StateLocation(
            anchorPath: root,
            components: ["state", "shadow-sync"],
            uid: geteuid()
        )
    }
    #endif

    public var path: String {
        components.reduce(anchorPath) { partial, component in
            URL(fileURLWithPath: partial).appendingPathComponent(component).path
        }
    }
}

#if SHADOW_SYNC_TESTING
public enum TestIsolation {
    public static func initializeState(at location: StateLocation) throws {
        let state = try SecureStateDirectory.testingCreateDirectory(location)
        try state.testingInitializeControls()
    }

    public static func validateRoot(_ root: String) throws -> String {
        guard root.hasPrefix("/private/tmp/"),
              !root.contains("\n"),
              !root.contains("\0"),
              !root.components(separatedBy: "/").contains("."),
              !root.components(separatedBy: "/").contains(".."),
              physicalPath(root) == root else {
            throw SecureStateError.unsafePath(root)
        }
        var info = stat()
        guard lstat(root, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            throw SecureStateError.unsafePath(root)
        }
        return root
    }

    public static func validateContainedDirectory(
        _ path: String,
        root: String
    ) throws {
        let root = try validateRoot(root)
        guard path.hasPrefix(root + "/"),
              !path.components(separatedBy: "/").contains("."),
              !path.components(separatedBy: "/").contains(".."),
              let physical = physicalPath(path),
              physical.hasPrefix(root + "/") else {
            throw SecureStateError.unsafePath(path)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            throw SecureStateError.unsafePath(path)
        }
    }

    private static func physicalPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
#endif

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let owner: UInt32
    public let mode: UInt16
    public let linkCount: UInt16

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        owner = UInt32(value.st_uid)
        mode = UInt16(value.st_mode)
        linkCount = UInt16(value.st_nlink)
    }

    var isDirectory: Bool {
        (mode_t(mode) & S_IFMT) == S_IFDIR
    }

    var isRegular: Bool {
        (mode_t(mode) & S_IFMT) == S_IFREG
    }

    func matchesStableNode(_ other: FileIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && owner == other.owner
            && mode == other.mode
    }
}

final class OwnedFileDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var rawValue: Int32
    enum Retirement: Equatable { case notAttempted, inProgress, succeeded, uncertain(Int32) }
    private var retirement: Retirement = .notAttempted
    #if SHADOW_SYNC_TESTING
    var testingClose: ((Int32) -> Int32)?
    #endif

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    var value: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return rawValue
    }

    /// Duplicate the same open-file description while excluding close/reuse.
    /// CLOEXEC is set by the duplication syscall, not in a later race window.
    func duplicate(minimum: Int32 = 0) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard rawValue >= 0, minimum >= 0 else {
            throw SecureStateError.systemCall("duplicate closed descriptor", EBADF)
        }
        let copy = fcntl(rawValue, F_DUPFD_CLOEXEC, minimum)
        guard copy >= 0 else { throw SecureStateError.systemCall("duplicate descriptor", errno) }
        return copy
    }

    /// Consume the original number once. Uncertainty never permits a numeric retry.
    @discardableResult func retireChecked() -> Retirement {
        lock.lock()
        guard retirement == .notAttempted else { let result = retirement; lock.unlock(); return result }
        let fd = rawValue; rawValue = -1; retirement = .inProgress
        lock.unlock()
        #if SHADOW_SYNC_TESTING
        let code: Int32
        if fd >= 0, let testingClose { code = testingClose(fd) }
        else { code = fd >= 0 && Darwin.close(fd) == 0 ? 0 : (fd < 0 ? EBADF : errno) }
        #else
        let code: Int32 = fd >= 0 && Darwin.close(fd) == 0 ? 0 : (fd < 0 ? EBADF : errno)
        #endif
        lock.lock(); retirement = code == 0 ? .succeeded : .uncertain(code)
        let result = retirement; lock.unlock(); return result
    }
    var retirementObservation: Retirement {
        lock.lock(); defer { lock.unlock() }; return retirement
    }
    /// A synchronous observation of the original description. The caller cannot
    /// close/reuse it while this method holds its existing ownership mutex.
    /// Callers use fixed nonblocking socket queries, never arbitrary work.
    func withOriginalSocket<T>(_ observe: (Int32) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard rawValue >= 0 else { throw SecureStateError.systemCall("closed socket observation", EBADF) }
        return try observe(rawValue)
    }
    /// Interrupt only this original description while excluding close/reuse.
    /// The result grants no retirement proof; checked close and join remain required.
    func interruptSocket() {
        lock.lock(); defer { lock.unlock() }
        if rawValue >= 0 { _ = shutdown(rawValue, SHUT_RDWR) }
    }
    func closeNow() { _ = retireChecked() }

    deinit {
        closeNow()
    }
}

public final class SecureStateDirectory: @unchecked Sendable {
    let descriptor: OwnedFileDescriptor
    public let path: String
    public let uid: uid_t

    private init(descriptor: Int32, path: String, uid: uid_t) {
        self.descriptor = OwnedFileDescriptor(descriptor)
        self.path = path
        self.uid = uid
    }

    fileprivate static func retainedCustodyState(_ inherited: CustodyInheritedCommand) throws -> SecureStateDirectory {
        try inherited.revalidateResources()
        guard let root = inherited.descriptors[.state] else { throw CustodyRecordError.fenced }
        return SecureStateDirectory(descriptor: try root.duplicate(minimum: 201), path: inherited.statePath, uid: inherited.account.uid)
    }

    /// Ordinary startup and state consumers may only open initialized state.
    /// Creation belongs to the signed lifecycle transaction, never path absence.
    public static func open(_ location: StateLocation) throws -> SecureStateDirectory {
        try openExisting(location)
    }

    #if SHADOW_SYNC_TESTING
    /// Explicit isolated fixture setup, deliberately separate from every
    /// production admission path. Existing permissions are never repaired.
    public static func testingCreateDirectory(_ location: StateLocation) throws -> SecureStateDirectory {
        guard location == (try StateLocation.isolated(root: location.anchorPath)) else {
            throw SecureStateError.unsafePath("fixture state location")
        }
        return try open(location, create: true, repairPermissions: false)
    }
    #endif

    public static func openExisting(_ location: StateLocation) throws -> SecureStateDirectory {
        try open(location, create: false, repairPermissions: false)
    }

    private static func open(
        _ location: StateLocation,
        create: Bool,
        repairPermissions: Bool
    ) throws -> SecureStateDirectory {
        let anchor = Darwin.open(location.anchorPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard anchor >= 0 else {
            throw SecureStateError.systemCall("open state anchor", errno)
        }
        var current = anchor
        var currentOwned = true
        defer {
            if currentOwned {
                close(current)
            }
        }
        try validateDirectory(fd: current, uid: location.uid, requirePrivate: false, label: location.anchorPath)

        for (index, component) in location.components.enumerated() {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SecureStateError.unsafePath(component)
            }
            if create, mkdirat(current, component, 0o700) != 0, errno != EEXIST {
                throw SecureStateError.systemCall("mkdirat \(component)", errno)
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                throw SecureStateError.systemCall("openat \(component)", errno)
            }
            if current != anchor || index > 0 {
                close(current)
            } else {
                close(anchor)
            }
            current = next
            try validateDirectory(
                fd: current,
                uid: location.uid,
                requirePrivate: index == location.components.count - 1,
                repairPermissions: repairPermissions,
                label: component
            )
        }
        currentOwned = false
        return SecureStateDirectory(descriptor: current, path: location.path, uid: location.uid)
    }

    private static func validateDirectory(
        fd: Int32,
        uid: uid_t,
        requirePrivate: Bool,
        repairPermissions: Bool = false,
        label: String
    ) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw SecureStateError.systemCall("fstat \(label)", errno)
        }
        let identity = FileIdentity(info)
        guard identity.isDirectory, info.st_uid == uid else {
            throw SecureStateError.unsafePath(label)
        }
        if requirePrivate {
            if repairPermissions {
                guard fchmod(fd, 0o700) == 0 else {
                    throw SecureStateError.systemCall("fchmod state directory", errno)
                }
            }
            guard refreshedPrivateMode(fd) else {
                throw SecureStateError.unsafePath(label)
            }
        }
    }

    private static func refreshedPrivateMode(_ fd: Int32) -> Bool {
        var refreshed = stat()
        return fstat(fd, &refreshed) == 0 && (refreshed.st_mode & 0o7777) == 0o700
    }

    func openRegularFile(
        named name: String,
        flags: Int32,
        create: Bool,
        mode: mode_t = 0o600,
        repairPermissions: Bool = true
    ) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SecureStateError.unsafePath(name)
        }
        let openFlags = flags | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
        let fd = openat(descriptor.value, name, openFlags, mode)
        guard fd >= 0 else {
            throw SecureStateError.systemCall("openat \(name)", errno)
        }
        do {
            try validateRegular(
                fd: fd,
                name: name,
                repairPermissions: repairPermissions
            )
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    func validateRegular(
        fd: Int32,
        name: String,
        repairPermissions: Bool = true
    ) throws {
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            throw SecureStateError.systemCall("fstat \(name)", errno)
        }
        guard FileIdentity(opened).isRegular,
              opened.st_uid == uid,
              opened.st_nlink == 1 else {
            throw SecureStateError.unsafePath(name)
        }
        if repairPermissions {
            guard fchmod(fd, 0o600) == 0 else {
                throw SecureStateError.systemCall("fchmod \(name)", errno)
            }
        } else if (opened.st_mode & 0o7777) != 0o600 {
            throw SecureStateError.unsafePath(name)
        }
        var relative = stat()
        guard fstatat(descriptor.value, name, &relative, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureStateError.systemCall("fstatat \(name)", errno)
        }
        guard opened.st_dev == relative.st_dev,
              opened.st_ino == relative.st_ino,
              FileIdentity(relative).isRegular,
              relative.st_uid == uid,
              (relative.st_mode & 0o7777) == 0o600,
              relative.st_nlink == 1 else {
            throw SecureStateError.unsafePath(name)
        }
    }

    func ownedEntryIdentity(
        named name: String,
        allowSocket: Bool
    ) throws -> FileIdentity {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SecureStateError.unsafePath(name)
        }
        var info = stat()
        guard fstatat(descriptor.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureStateError.systemCall("fstatat \(name)", errno)
        }
        let type = info.st_mode & S_IFMT
        guard info.st_uid == uid,
              ((allowSocket && type == S_IFSOCK)
                || (type == S_IFREG && info.st_nlink == 1)) else {
            throw SecureStateError.unsafePath(name)
        }
        return FileIdentity(info)
    }

    func removeOwnedEntry(
        named name: String,
        expected: FileIdentity
    ) throws {
        guard !["lifecycle.lock", "operation.lock", "run.lock", "launcher.lock"]
            .contains(name) else {
            throw SecureStateError.unsafePath(name)
        }
        let observed = try ownedEntryIdentity(
            named: name,
            allowSocket: (mode_t(expected.mode) & S_IFMT) == S_IFSOCK
        )
        guard observed.matchesStableNode(expected) else {
            throw SecureStateError.unsafePath(name)
        }
        guard unlinkat(descriptor.value, name, 0) == 0 else {
            throw SecureStateError.systemCall("unlinkat \(name)", errno)
        }
    }

    func renameOwnedEntry(
        named source: String,
        to destination: String,
        expected: FileIdentity
    ) throws {
        let protected = [
            "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock",
        ]
        guard !protected.contains(source),
              !protected.contains(destination),
              !source.isEmpty,
              source != ".",
              source != "..",
              !source.contains("/"),
              !destination.isEmpty,
              destination != ".",
              destination != "..",
              !destination.contains("/") else {
            throw SecureStateError.unsafePath(source)
        }
        var destinationInfo = stat()
        guard fstatat(
            descriptor.value,
            destination,
            &destinationInfo,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw SecureStateError.unsafePath(destination)
        }
        let allowSocket = (mode_t(expected.mode) & S_IFMT) == S_IFSOCK
        let observed = try ownedEntryIdentity(
            named: source,
            allowSocket: allowSocket
        )
        guard observed.matchesStableNode(expected),
              renameat(
                descriptor.value,
                source,
                descriptor.value,
                destination
              ) == 0 else {
            throw SecureStateError.unsafePath(source)
        }
        let renamed = try ownedEntryIdentity(
            named: destination,
            allowSocket: allowSocket
        )
        guard renamed.matchesStableNode(expected) else {
            _ = renameat(
                descriptor.value,
                destination,
                descriptor.value,
                source
            )
            throw SecureStateError.unsafePath(destination)
        }
        guard fsync(descriptor.value) == 0 else {
            let code = errno
            _ = renameat(
                descriptor.value,
                destination,
                descriptor.value,
                source
            )
            _ = fsync(descriptor.value)
            throw SecureStateError.systemCall(
                "fsync state namespace",
                code
            )
        }
    }

    func requireStableLockFiles() throws {
        for name in ["lifecycle.lock", "operation.lock", "run.lock", "launcher.lock"] {
            let fd = try openRegularFile(named: name, flags: O_RDWR, create: false, repairPermissions: false)
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size == 0 else { throw SecureStateError.unsafePath(name) }
        }
    }

    #if SHADOW_SYNC_TESTING
    public func testingInitializeControls() throws {
        guard path == (try StateLocation.isolated(root: URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().path)).path else {
            throw SecureStateError.unsafePath("fixture control location")
        }
        for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock"] {
            let fd = try openRegularFile(named: name, flags: O_RDWR, create: true, repairPermissions: false)
            close(fd)
        }
    }
    #endif

    func removeStableLockFiles(
        afterRemoving: (String) throws -> Void = { _ in }
    ) throws {
        let names = ["launcher.lock", "run.lock", "operation.lock", "lifecycle.lock"]
        let identities = try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try ownedEntryIdentity(named: $0, allowSocket: false))
        })
        for name in names {
            guard let expected = identities[name] else {
                throw SecureStateError.unsafePath(name)
            }
            let observed = try ownedEntryIdentity(named: name, allowSocket: false)
            guard observed.matchesStableNode(expected),
                  unlinkat(descriptor.value, name, 0) == 0 else {
                throw SecureStateError.unsafePath(name)
            }
            try afterRemoving(name)
        }
        guard fsync(descriptor.value) == 0 else {
            throw SecureStateError.systemCall("fsync retired state namespace", errno)
        }
    }
}

public final class RunAuthority: @unchecked Sendable {
    private let custodyMutex = NSLock()
    private var custodyBorrowCount = 0
    private var custodyAliasFamilies: [WeakInstallationAliasFamily] = []
    // Retirement, staged admission and release close this scope permanently.
    // A failed/busy transition does not reopen it; only a fresh authority may
    // issue new leases. Existing retained descriptions remain valid until closed.
    private var custodyAdmissionClosed = false
    // Reference-only seal. It can never be reconstructed from an installation
    // record, PID or source path; old aliases cannot release a consumed owner.
    private var installationSeal: InstallationOwnershipSeal?
    private var installationBorrowingClosed = false
    private let state: SecureStateDirectory
    private let namespace: OwnedFileDescriptor
    private let lifecycle: OwnedFileDescriptor
    private let operation: OwnedFileDescriptor
    private let run: OwnedFileDescriptor?
    private let commandMode: CustodyAuthorityMode
    private let releasesInitializationLocksForStaging: Bool
    private let initializationAliases: InstallationPublicationAliases?
    private enum InstallationAdmissionPhase { case exclusive, transferring, staged, failed }
    private var installationAdmissionPhase: InstallationAdmissionPhase = .exclusive
    private var stagedNamespace: OwnedFileDescriptor?
    private var stagedLifecycle: OwnedFileDescriptor?
    private enum InstallationStagedBorrowingPhase { case start, closingStart, stop }
    private var installationStagedBorrowingPhase: InstallationStagedBorrowingPhase = .start
    private var installationCompletionBorrowed = false

    public var stateDirectory: SecureStateDirectory { state }

    private init(
        state: SecureStateDirectory,
        namespace: OwnedFileDescriptor,
        lifecycle: OwnedFileDescriptor,
        operation: OwnedFileDescriptor,
        run: OwnedFileDescriptor?,
        commandMode: CustodyAuthorityMode,
        releasesInitializationLocksForStaging: Bool = false,
        initializationAliases: InstallationPublicationAliases? = nil
    ) {
        self.state = state
        self.namespace = namespace
        self.lifecycle = lifecycle
        self.operation = operation
        self.run = run
        self.commandMode = commandMode
        self.releasesInitializationLocksForStaging = releasesInitializationLocksForStaging
        self.initializationAliases = initializationAliases
    }

    public static func acquireRun(at location: StateLocation) throws -> RunAuthority {
        let state = try SecureStateDirectory.open(location)
        let namespace = try acquireLock(state: state, name: "latest.log", operation: LOCK_SH)
        do {
            try state.requireStableLockFiles()
            let lifecycle = try acquireLock(
                state: state,
                name: "lifecycle.lock",
                operation: LOCK_SH
            )
            do {
                let operation = try acquireLock(
                    state: state,
                    name: "operation.lock",
                    operation: LOCK_EX
                )
                do {
                    let run = try acquireLock(
                        state: state,
                        name: "run.lock",
                        operation: LOCK_EX
                    )
                    return RunAuthority(
                        state: state,
                        namespace: OwnedFileDescriptor(namespace),
                        lifecycle: OwnedFileDescriptor(lifecycle),
                        operation: OwnedFileDescriptor(operation),
                        run: OwnedFileDescriptor(run),
                        commandMode: .mutation
                    )
                } catch {
                    close(operation)
                    throw error
                }
            } catch {
                close(lifecycle)
                throw error
            }
        } catch {
            close(namespace)
            throw error
        }
    }

    public static func acquireLifecycleMutation(at location: StateLocation) throws -> RunAuthority {
        let state = try SecureStateDirectory.open(location)
        let namespace = try acquireLock(state: state, name: "latest.log", operation: LOCK_SH)
        do {
            try state.requireStableLockFiles()
            let lifecycle = try acquireLock(
                state: state,
                name: "lifecycle.lock",
                operation: LOCK_EX
            )
            do {
                let operation = try acquireLock(
                    state: state,
                    name: "operation.lock",
                    operation: LOCK_EX
                )
                return RunAuthority(
                    state: state,
                    namespace: OwnedFileDescriptor(namespace),
                    lifecycle: OwnedFileDescriptor(lifecycle),
                    operation: OwnedFileDescriptor(operation),
                    run: nil,
                    commandMode: .lifecycleMutation
                )
            } catch {
                close(lifecycle)
                throw error
            }
        } catch {
            close(namespace)
            throw error
        }
    }

    /// Rebind only the directory name after publication. Every lock descriptor
    /// is a duplicate of the initializer's actual exclusive description.
    static func adoptingPublishedState(_ publication: FreshStateInitialization.PublishedState) throws -> RunAuthority {
        let state = try SecureStateDirectory.openExisting(publication.location)
        let claims = try publication.leases.descriptorClaims()
        var actual = stat()
        guard fstat(state.descriptor.value, &actual) == 0,
              let held = claims.first(where: { $0.role == .state }),
              held.device == UInt64(actual.st_dev), held.inode == UInt64(actual.st_ino),
              held.uid == actual.st_uid,
              held.device == publication.result.stateDevice,
              held.inode == publication.result.stateInode else { throw CustodyRecordError.fenced }
        let locks = try publication.leases.duplicateInitializationLocks(publication)
        #if SHADOW_SYNC_TESTING
        try testingPublicationCapture.captureIfArmed(publication.leases)
        #endif
        guard let namespace = locks[.namespace], let lifecycle = locks[.lifecycle],
              let operation = locks[.operation], let run = locks[.run] else { throw CustodyRecordError.fenced }
        return RunAuthority(state: state, namespace: namespace, lifecycle: lifecycle,
            operation: operation, run: run, commandMode: .lifecycleMutation,
            releasesInitializationLocksForStaging: true,
            initializationAliases: publication.leases.initializationAliases)
    }

    private static func acquireLock(
        state: SecureStateDirectory,
        name: String,
        operation: Int32
    ) throws -> Int32 {
        let fd = try state.openRegularFile(named: name, flags: O_RDWR, create: false, repairPermissions: false)
        guard flock(fd, operation | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw SecureStateError.contention(name)
            }
            throw SecureStateError.systemCall("flock \(name)", code)
        }
        let existing = fcntl(fd, F_GETFD)
        guard existing >= 0, fcntl(fd, F_SETFD, existing | FD_CLOEXEC) == 0 else {
            let code = errno
            close(fd)
            throw SecureStateError.systemCall("fcntl \(name)", code)
        }
        return fd
    }

    var commandAdmissionIsOpen: Bool {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        return !custodyAdmissionClosed
    }

    /// Log writers must use the same regular file that anchors this authority.
    /// Never create a missing name or repair modes during ordinary operation.
    func openRetainedLogForWriting(append: Bool = false) throws -> Int32 {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard !custodyAdmissionClosed, commandMode != .lifecycleMutation else {
            throw SecureStateError.contention("closed log authority")
        }
        try state.validateRegular(fd: namespace.value, name: "latest.log", repairPermissions: false)
        let fd = try state.openRegularFile(named: "latest.log",
            flags: O_WRONLY | (append ? O_APPEND : 0), create: false, repairPermissions: false)
        do {
            var retained = stat(), opened = stat()
            guard fstat(namespace.value, &retained) == 0, fstat(fd, &opened) == 0,
                  FileIdentity(retained) == FileIdentity(opened) else {
                throw SecureStateError.unsafePath("replaced log authority")
            }
            try state.validateRegular(fd: fd, name: "latest.log", repairPermissions: false)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    func duplicateOperationLease() throws -> Int32 {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard !custodyAdmissionClosed, commandMode != .lifecycleMutation else {
            throw SecureStateError.contention("untracked lifecycle operation alias")
        }
        return try operation.duplicate()
    }

    func retainCommandLeases() throws -> CustodyAuthorityLeaseSet {
        try retainCustodyLeases(observationOnly: false)
    }

    func retainObservationLeases() throws -> CustodyAuthorityLeaseSet {
        try retainCustodyLeases(observationOnly: true)
    }

    private func retainCustodyLeases(observationOnly: Bool) throws -> CustodyAuthorityLeaseSet {
        #if SHADOW_SYNC_TESTING
        testingCustodyObservationMutex.lock()
        let attempt = testingCustodyBorrowAttempt; testingCustodyBorrowAttempt = nil
        testingCustodyObservationMutex.unlock()
        let acquired = attempt != nil && custodyMutex.try()
        attempt?.record(contended: !acquired)
        if !acquired { custodyMutex.lock() }
        #else
        custodyMutex.lock()
        #endif
        defer { custodyMutex.unlock() }
        guard !custodyAdmissionClosed else { throw SecureStateError.contention("closed command custody") }
        #if SHADOW_SYNC_TESTING
        if let barrier = testingCustodyBarrier {
            testingCustodyBarrier = nil
            guard barrier.pause() else { throw SecureStateError.contention("custody test barrier") }
        }
        #endif
        var members: [(CustodyDescriptorClaim.Role, OwnedFileDescriptor)] = [
            (.state, state.descriptor), (.namespace, namespace), (.lifecycle, lifecycle),
        ]
        if !observationOnly {
            members.append((.operation, operation))
            if commandMode == .mutation, let run { members.append((.run, run)) }
        }
        let mode: CustodyAuthorityMode = observationOnly ? .observation : commandMode
        let result = try CustodyAuthorityLeaseSet.copy(state: state, members: members, mode: mode,
            onRelease: { [weak self] in
                guard let self else { return }
                self.custodyMutex.lock(); self.custodyBorrowCount -= 1; self.custodyMutex.unlock()
            })
        custodyAliasFamilies.removeAll { $0.family == nil }
        custodyAliasFamilies.append(WeakInstallationAliasFamily(result.initializationAliases))
        custodyBorrowCount += 1
        return result
    }

    func permitStagedHostAdmission() throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal == nil else { throw CustodyRecordError.fenced }
        custodyAdmissionClosed = true
        guard custodyBorrowCount == 0 else { throw SecureStateError.contention("command custody") }
        if releasesInitializationLocksForStaging {
            namespace.closeNow()
            run?.closeNow()
        }
        lifecycle.closeNow()
    }

    func acquireRetirementNamespace(timeout: TimeInterval = 5) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal == nil else { throw CustodyRecordError.fenced }
        custodyAdmissionClosed = true
        #if SHADOW_SYNC_TESTING
        if let barrier = testingCustodyRetirementBarrier {
            testingCustodyRetirementBarrier = nil
            guard barrier.pause() else { throw SecureStateError.contention("custody retirement test barrier") }
        }
        #endif
        guard custodyBorrowCount == 0 else { throw SecureStateError.contention("command custody") }
        let deadline = MonotonicDeadline(seconds: timeout)
        repeat {
            if flock(namespace.value, LOCK_EX | LOCK_NB) == 0 {
                return
            }
            let code = errno
            guard code == EWOULDBLOCK else {
                throw SecureStateError.systemCall(
                    "upgrade retained-log authority",
                    code
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while !deadline.hasExpired
        throw SecureStateError.contention("latest.log")
    }

    public func release() {
        #if SHADOW_SYNC_TESTING
        testingCustodyObservationMutex.lock()
        let attempt = testingCustodyReleaseAttempt; testingCustodyReleaseAttempt = nil
        testingCustodyObservationMutex.unlock()
        let acquired = attempt != nil && custodyMutex.try()
        attempt?.record(contended: !acquired)
        if !acquired { custodyMutex.lock() }
        #else
        custodyMutex.lock()
        #endif
        defer { custodyMutex.unlock() }
        guard installationSeal == nil else { return }
        custodyAdmissionClosed = true
        run?.closeNow()
        operation.closeNow()
        lifecycle.closeNow()
        namespace.closeNow()
    }

    fileprivate func consumeInstallation() throws -> InstallationOwnershipSeal {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        // Failure permanently closes OLD borrowing too. The original operation
        // remains owned here so existing registered work can finish draining.
        custodyAdmissionClosed = true
        initializationAliases?.closeAdmission()
        custodyAliasFamilies.forEach { $0.family?.closeAdmission() }
        guard commandMode == .lifecycleMutation, installationSeal == nil,
              custodyBorrowCount == 0 else { throw CustodyRecordError.fenced }
        let binding = try InstallationStateBinding.capture(stateDescriptor: state.descriptor.value, uid: state.uid)
        try validateInstallationDescriptions(binding)
        let seal = InstallationOwnershipSeal(binding)
        installationSeal = seal
        return seal
    }
    private func validateInstallationDescriptions(_ binding: InstallationStateBinding) throws {
        // Observation opens never acquire a lock. All authority remains in the
        // original operation description; its actual descriptor is checked below.
        let current = try InstallationStateBinding.capture(stateDescriptor: state.descriptor.value, uid: state.uid)
        let a = binding.directory, b = current.directory
        guard a.device == b.device, a.inode == b.inode, a.type == b.type, a.uid == b.uid,
              a.mode == b.mode, a.aclDigest == b.aclDigest, a.links > 0, b.links > 0,
              binding.namespace == current.namespace, binding.lifecycle == current.lifecycle,
              binding.operation == current.operation, binding.run == current.run,
              binding.launcher == current.launcher, binding.catalogGuard == current.catalogGuard else {
            throw CustodyRecordError.fenced
        }
        try validateInstallationDescriptor(operation, expected: binding.operation)
        switch installationAdmissionPhase {
        case .exclusive:
            try validateInstallationDescriptor(namespace, expected: binding.namespace)
            try validateInstallationDescriptor(lifecycle, expected: binding.lifecycle)
            if let run { try validateInstallationDescriptor(run, expected: binding.run) }
        case .staged:
            guard let stagedNamespace, let stagedLifecycle, namespace.value < 0,
                  lifecycle.value < 0, run == nil || run!.value < 0 else { throw CustodyRecordError.fenced }
            try validateInstallationDescriptor(stagedNamespace, expected: binding.namespace)
            try validateInstallationDescriptor(stagedLifecycle, expected: binding.lifecycle)
        case .transferring, .failed:
            guard namespace.value < 0, lifecycle.value < 0, run == nil || run!.value < 0,
                  stagedNamespace == nil, stagedLifecycle == nil else { throw CustodyRecordError.fenced }
        }
    }
    private func validateInstallationDescriptor(_ descriptor: OwnedFileDescriptor,
                                                expected: InstallationNodeIdentity) throws {
        let fd = descriptor.value
        var observed = stat()
        let flags = fcntl(fd, F_GETFD), access = fcntl(fd, F_GETFL)
        guard fd >= 0, fstat(fd, &observed) == 0, flags >= 0, flags & FD_CLOEXEC != 0,
              access >= 0, access & O_ACCMODE == O_RDWR,
              UInt64(observed.st_dev) == expected.device, UInt64(observed.st_ino) == expected.inode,
              observed.st_uid == expected.uid, UInt32(observed.st_mode) == expected.mode,
              UInt64(observed.st_nlink) == expected.links,
              CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(fd).utf8)) == expected.aclDigest else {
            throw CustodyRecordError.fenced
        }
    }
    fileprivate func requireExclusiveInstallation(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .exclusive else { throw CustodyRecordError.fenced }
    }
    fileprivate func beginInstallationAdmissionTransfer(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .exclusive,
              installationBorrowingClosed, custodyBorrowCount == 0,
              initializationAliases?.isRetired ?? true else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
        // No alias can be created after consumption. The publication root sends
        // retirement only AFTER closing its actual descriptions; descendants
        // retain that root. These are therefore the last admission descriptions.
        namespace.closeNow(); lifecycle.closeNow(); run?.closeNow()
        installationAdmissionPhase = .transferring
    }
    fileprivate func acquireInstallationStagedDescriptions(_ seal: InstallationOwnershipSeal,
                                                          deadline: MonotonicDeadline) throws {
        // No authority/registry/catalog mutex spans either flock. A prior one-way
        // transition owns this gap; old public APIs cannot close or borrow it.
        guard !deadline.hasExpired else { throw CustodyRecordError.fenced }
        let newNamespace = try acquireInstallationAdmissionDescription(name: "latest.log", expected: seal.binding.namespace)
        guard !deadline.hasExpired else { throw CustodyRecordError.fenced }
        let newLifecycle = try acquireInstallationAdmissionDescription(name: "lifecycle.lock", expected: seal.binding.lifecycle)
        guard !deadline.hasExpired else { throw CustodyRecordError.fenced }
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .transferring,
              custodyBorrowCount == 0 else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
        stagedNamespace = newNamespace; stagedLifecycle = newLifecycle
        installationAdmissionPhase = .staged
    }
    private func acquireInstallationAdmissionDescription(name: String, expected: InstallationNodeIdentity) throws -> OwnedFileDescriptor {
        let fresh = OwnedFileDescriptor(try state.openRegularFile(named: name, flags: O_RDWR,
            create: false, repairPermissions: false))
        // Validate the expected inode and ACL BEFORE attempting even a nonblocking
        // lock. openRegularFile rechecks the no-follow named node; repeat after.
        try validateInstallationDescriptor(fresh, expected: expected)
        guard flock(fresh.value, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { throw SecureStateError.contention(name) }
            throw SecureStateError.systemCall("installation admission lock", code)
        }
        try state.validateRegular(fd: fresh.value, name: name, repairPermissions: false)
        try validateInstallationDescriptor(fresh, expected: expected)
        return fresh
    }
    fileprivate func failInstallationAdmissionTransfer(_ seal: InstallationOwnershipSeal) {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase != .exclusive else { return }
        stagedLifecycle?.closeNow(); stagedNamespace?.closeNow()
        stagedLifecycle = nil; stagedNamespace = nil
        installationAdmissionPhase = .failed
    }
    fileprivate func validateStagedInstallation(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .staged,
              installationBorrowingClosed else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
    }
    fileprivate func validateInstallation(_ seal: InstallationOwnershipSeal, closedBorrowing: Bool = false) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, custodyAdmissionClosed,
              !closedBorrowing || (installationBorrowingClosed && custodyBorrowCount == 0) else {
            throw CustodyRecordError.fenced
        }
        try validateInstallationDescriptions(seal.binding)
    }
    fileprivate func borrowInstallation(_ owner: InstallationTransactionOwner,
                                       seal: InstallationOwnershipSeal) throws -> CustodyAuthorityLeaseSet {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, custodyAdmissionClosed, !installationBorrowingClosed,
              installationAdmissionPhase == .exclusive else {
            throw CustodyRecordError.fenced
        }
        try validateInstallationDescriptions(seal.binding)
        let result = try CustodyAuthorityLeaseSet.copy(state: state, members: [
            (.state, state.descriptor), (.namespace, namespace), (.lifecycle, lifecycle), (.operation, operation),
        ], mode: .lifecycleMutation, onRelease: { [self, owner] in
            // The lease implementation closes every actual duplicate BEFORE
            // calling this hook. Its strong owner reference preserves the
            // original operation description through the last borrowed alias.
            withExtendedLifetime(owner) {
                custodyMutex.lock(); custodyBorrowCount -= 1; custodyMutex.unlock()
            }
        })
        custodyAliasFamilies.removeAll { $0.family == nil }
        custodyAliasFamilies.append(WeakInstallationAliasFamily(result.initializationAliases))
        custodyBorrowCount += 1
        return result
    }
    fileprivate func stagedInstallationCommandsOpen(_ seal: InstallationOwnershipSeal,
                                                     mode: CustodyAuthorityMode) -> Bool {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .staged,
              installationBorrowingClosed else { return false }
        return (mode == .installationStagedStart && installationStagedBorrowingPhase == .start)
            || (mode == .installationStagedStop && installationStagedBorrowingPhase == .stop)
    }
    fileprivate func borrowStagedInstallation(_ owner: InstallationTransactionOwner,
                                             seal: InstallationOwnershipSeal,
                                             mode: CustodyAuthorityMode,
                                             forCompletion: Bool = false) throws -> CustodyAuthorityLeaseSet {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard !installationCompletionBorrowed,
              !forCompletion || (custodyBorrowCount == 0 && custodyAliasFamilies.allSatisfy({ $0.family == nil })),
              installationSeal === seal, custodyAdmissionClosed, installationBorrowingClosed,
              installationAdmissionPhase == .staged,
              (mode == .installationStagedStart && installationStagedBorrowingPhase == .start)
                || (mode == .installationStagedStop && installationStagedBorrowingPhase == .stop),
              let stagedNamespace, let stagedLifecycle else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
        // Duplicate the original EX operation description and the two fresh SH
        // descriptions. No operation open, lock conversion, run or new authority.
        let result = try CustodyAuthorityLeaseSet.copy(state: state, members: [
            (.state, state.descriptor), (.namespace, stagedNamespace),
            (.lifecycle, stagedLifecycle), (.operation, operation),
        ], mode: mode, onRelease: { [self, owner] in
            withExtendedLifetime(owner) {
                custodyMutex.lock(); custodyBorrowCount -= 1
                if forCompletion { installationCompletionBorrowed = false }
                custodyMutex.unlock()
            }
        })
        custodyAliasFamilies.removeAll { $0.family == nil }
        custodyAliasFamilies.append(WeakInstallationAliasFamily(result.initializationAliases))
        custodyBorrowCount += 1
        if forCompletion { installationCompletionBorrowed = true }
        return result
    }
    fileprivate func validateStagedCommandAliasesRetired(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .staged,
              installationBorrowingClosed, custodyBorrowCount == 0,
              custodyAliasFamilies.allSatisfy({ $0.family == nil }) else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
    }
    fileprivate func closeStagedInstallationStarts(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .staged,
              installationStagedBorrowingPhase != .stop else { throw CustodyRecordError.fenced }
        // Close before any drainage or publisher check; a failure never reopens
        // the gate. Every descendant shares the enrolled root alias family.
        installationStagedBorrowingPhase = .closingStart
        custodyAliasFamilies.forEach { $0.family?.closeAdmission() }
        guard custodyBorrowCount == 0 else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
    }
    fileprivate func validateClosedStagedInstallationStarts(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .staged,
              installationStagedBorrowingPhase == .closingStart, installationBorrowingClosed,
              custodyBorrowCount == 0 else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
    }
    fileprivate func enterStagedInstallationStop(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .staged,
              installationStagedBorrowingPhase == .closingStart, custodyBorrowCount == 0 else {
            throw CustodyRecordError.fenced
        }
        try validateInstallationDescriptions(seal.binding)
        installationStagedBorrowingPhase = .stop
    }
    fileprivate func installationCommandsOpen(_ seal: InstallationOwnershipSeal) -> Bool {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        return installationSeal === seal && custodyAdmissionClosed && !installationBorrowingClosed
            && installationAdmissionPhase == .exclusive
    }
    fileprivate func closeInstallationBorrowing(_ seal: InstallationOwnershipSeal) throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal, installationAdmissionPhase == .exclusive else { throw CustodyRecordError.fenced }
        installationBorrowingClosed = true
        custodyAliasFamilies.forEach { $0.family?.closeAdmission() }
        guard custodyBorrowCount == 0 else { throw CustodyRecordError.fenced }
        try validateInstallationDescriptions(seal.binding)
    }
    fileprivate func releaseInstallation(_ seal: InstallationOwnershipSeal) {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard installationSeal === seal else { return }
        // Every borrowed family strongly retains its owner until its descriptors
        // have closed and its release hook has run. No public release method can
        // get here, and the old seal stays consumed after the final close.
        installationBorrowingClosed = true
        stagedLifecycle?.closeNow(); stagedNamespace?.closeNow()
        run?.closeNow(); lifecycle.closeNow(); namespace.closeNow(); operation.closeNow()
    }

    #if SHADOW_SYNC_TESTING
    static let testingPublicationCapture = InstallationPublicationTestingCapture()
    private var testingCustodyBarrier: CustodyLeaseTestingBarrier?
    private var testingCustodyRetirementBarrier: CustodyLeaseTestingBarrier?
    private var testingCustodyBorrowAttempt: CustodyLeaseTestingBarrier?
    func testingPauseCustodyRetirement(_ barrier: CustodyLeaseTestingBarrier) {
        custodyMutex.lock(); testingCustodyRetirementBarrier = barrier; custodyMutex.unlock()
    }
    func testingObserveCustodyBorrow(_ attempt: CustodyLeaseTestingBarrier) {
        testingCustodyObservationMutex.lock(); testingCustodyBorrowAttempt = attempt
        testingCustodyObservationMutex.unlock()
    }
    private let testingCustodyObservationMutex = NSLock()
    private var testingCustodyReleaseAttempt: CustodyLeaseTestingBarrier?
    func testingPauseCustodyDuplication(_ barrier: CustodyLeaseTestingBarrier) {
        custodyMutex.lock(); testingCustodyBarrier = barrier; custodyMutex.unlock()
    }
    func testingObserveCustodyRelease(_ attempt: CustodyLeaseTestingBarrier) {
        testingCustodyObservationMutex.lock(); testingCustodyReleaseAttempt = attempt
        testingCustodyObservationMutex.unlock()
    }
    #endif
}

fileprivate final class InstallationOwnershipSeal {
    let binding: InstallationStateBinding
    init(_ binding: InstallationStateBinding) { self.binding = binding }
}

/// One-way ownership of an already acquired/transferred original lifecycle
/// authority. This does not perform an installation action, write a control,
/// create staged command permission, or admit a host. Those require the durable
/// transaction and authenticated readiness integration separately.
final class InstallationTransactionOwner: @unchecked Sendable {
    private let original: RunAuthority
    private let seal: InstallationOwnershipSeal
    private let publisher: LifecyclePublisher?
    private let fixtureRoot: String?
    private let location: StateLocation
    private let bindingMutex = NSLock()
    private var liveBinding: InstallationLiveSnapshot?
    private var installationJournalClaimed = false
    #if SHADOW_SYNC_TESTING
    private var testingBindingSource: InstallationBindingTestingSource?
    #endif

    private init(original: RunAuthority, publisher: LifecyclePublisher?, fixtureRoot: String?, location: StateLocation) throws {
        self.original = original; self.publisher = publisher; self.fixtureRoot = fixtureRoot; self.location = location
        // All fallible checks precede sealing. No temporary consumed owner may
        // unwind and close the original operation after a failed factory return.
        try Self.validateNamedState(original, location: location)
        seal = try original.consumeInstallation()
    }
    private static func validateNamedState(_ original: RunAuthority, location: StateLocation) throws {
        guard original.stateDirectory.path == location.path, original.stateDirectory.uid == location.uid else {
            throw CustodyRecordError.fenced
        }
        let named = try SecureStateDirectory.openExisting(location)
        var a = stat(), b = stat()
        guard fstat(named.descriptor.value, &a) == 0, fstat(original.stateDirectory.descriptor.value, &b) == 0,
              FileIdentity(a).matchesStableNode(FileIdentity(b)) else { throw CustodyRecordError.fenced }
    }
    static func consume(_ authority: RunAuthority, publisher: LifecyclePublisher) throws -> InstallationTransactionOwner {
        try publisher.revalidate()
        guard authority.stateDirectory.uid == publisher.account.uid else { throw CustodyRecordError.fenced }
        return try Self(original: authority, publisher: publisher, fixtureRoot: nil, location: StateLocation.production())
    }
    private func revalidateOriginal() throws {
        if let publisher { try publisher.revalidate() }
        else {
            #if SHADOW_SYNC_TESTING
            guard let fixtureRoot, try TestIsolation.validateRoot(fixtureRoot) == fixtureRoot,
                  original.stateDirectory.path == (try StateLocation.isolated(root: fixtureRoot)).path else {
                throw CustodyRecordError.fenced
            }
            #else
            throw CustodyRecordError.fenced
            #endif
        }
        try Self.validateNamedState(original, location: location)
        try original.validateInstallation(seal)
    }
    func revalidate() throws {
        bindingMutex.lock(); let expected = liveBinding; bindingMutex.unlock()
        try revalidateOriginal()
        if let expected {
            guard try captureLiveBinding(generation: expected.process.generation) == expected else { throw CustodyRecordError.fenced }
        }
        bindingMutex.lock(); defer { bindingMutex.unlock() }
        guard liveBinding == expected else { throw CustodyRecordError.fenced }
    }
    /// Bind once, from live observations only. A later caller cannot choose a
    /// generation, source, candidate, process, boot or replacement state binding.
    // Fixed installer layout must belong to this consumed owner. A public paths
    // value or a metadata-equivalent state never selects a capture authority.
    func validateInstallationPaths(_ paths: InstallationPaths) throws {
        try revalidate()
        if publisher != nil {
            guard paths == (try InstallationPaths.production()) else { throw CustodyRecordError.fenced }
        } else {
            #if SHADOW_SYNC_TESTING
            guard let fixtureRoot, paths == (try InstallationPaths.isolated(root: fixtureRoot)) else {
                throw CustodyRecordError.fenced
            }
            #else
            throw CustodyRecordError.fenced
            #endif
        }
    }
    // A consumed owner issues at most one live journal. Neither wire identity nor
    // a second capture can reconstruct its pending publication capability.
    func claimInstallationJournal() throws {
        try original.requireExclusiveInstallation(seal)
        bindingMutex.lock(); defer { bindingMutex.unlock() }
        try revalidateOriginal()
        guard !installationJournalClaimed else { throw CustodyRecordError.fenced }
        installationJournalClaimed = true
    }
    func installationBinding() throws -> InstallationLiveBinding {
        bindingMutex.lock(); defer { bindingMutex.unlock() }
        let observed = try captureLiveBinding(generation: liveBinding?.process.generation ?? RunIdentity.make())
        if let liveBinding {
            guard observed == liveBinding else { throw CustodyRecordError.fenced }
        } else { liveBinding = observed }
        return InstallationLiveBinding(owner: self, snapshot: observed)
    }
    private func captureLiveBinding(generation: String) throws -> InstallationLiveSnapshot {
        try revalidateOriginal()
        let identity: LifecyclePublisher.InstallationIdentity
        let process: ProcessIdentity
        let boot: String
        if let publisher {
            boot = try CustodyBootIdentity.current()
            identity = try publisher.installationIdentity()
            process = try identity.captureCoordinator(generation: generation)
            try identity.revalidate()
            guard boot == (try CustodyBootIdentity.current()),
                  process == (try identity.captureCoordinator(generation: generation)) else {
                throw CustodyRecordError.fenced
            }
        } else {
            #if SHADOW_SYNC_TESTING
            guard let source = testingBindingSource, source.available else { throw CustodyRecordError.fenced }
            identity = source.identity; process = source.process; boot = source.boot
            #else
            throw CustodyRecordError.fenced
            #endif
        }
        guard RunIdentity.isValid(boot), process.processID > 1,
              process.userID == original.stateDirectory.uid,
              RunIdentity.isValid(process.generation), process.startSeconds > 0,
              process.startMicroseconds < 1_000_000 else { throw CustodyRecordError.fenced }
        try identity.candidate.validate()
        try revalidateOriginal()
        return InstallationLiveSnapshot(boot: boot, process: process, identity: identity, state: seal.binding)
    }
    fileprivate func validateLiveBinding(_ expected: InstallationLiveSnapshot) throws {
        bindingMutex.lock(); let before = liveBinding; bindingMutex.unlock()
        guard before == expected, try captureLiveBinding(generation: expected.process.generation) == expected else {
            throw CustodyRecordError.fenced
        }
        bindingMutex.lock(); defer { bindingMutex.unlock() }
        guard liveBinding == expected else { throw CustodyRecordError.fenced }
    }
    // Metadata/storage and future exclusive command contexts retain this family.
    // A lifecycleMutation lease alone remains blocked by an initial/active
    // installation control; no command permission is synthesized here.
    var commandAdmissionIsOpen: Bool { original.installationCommandsOpen(seal) }
    func installationSourceBundle() throws -> String {
        try original.requireExclusiveInstallation(seal)
        try revalidate()
        if let publisher { return try publisher.installationSourceBundle() }
        #if SHADOW_SYNC_TESTING
        guard let fixtureRoot, try TestIsolation.validateRoot(fixtureRoot) == fixtureRoot else { throw CustodyRecordError.fenced }
        return fixtureRoot + "/candidate/ShadowSync.app"
        #else
        throw CustodyRecordError.fenced
        #endif
    }
    func installationCommandHelper() throws -> CustodyHelperExecutable {
        try original.requireExclusiveInstallation(seal)
        try revalidate()
        guard let publisher else { throw CustodyRecordError.fenced }
        return try CustodyHelperExecutable.lifecycle(publisher)
    }
    func stagedCommandHelper(mode: CustodyAuthorityMode) throws -> CustodyHelperExecutable {
        guard mode.isInstallationStaged else { throw CustodyRecordError.fenced }
        try validateStagedBorrowing(mode: mode)
        guard let publisher else { throw CustodyRecordError.fenced }
        return try CustodyHelperExecutable.lifecycle(publisher)
    }
    func retainExclusiveLeases() throws -> CustodyAuthorityLeaseSet {
        try original.requireExclusiveInstallation(seal)
        try revalidate()
        return try original.borrowInstallation(self, seal: seal)
    }
    func closeBorrowing() throws -> ClosedInstallationBorrowing {
        // Close first, even if publisher revalidation or drainage then fails.
        try original.closeInstallationBorrowing(seal)
        try revalidate()
        return ClosedInstallationBorrowing(self)
    }
    fileprivate func validateClosedBorrowing() throws {
        try revalidate()
        try original.validateInstallation(seal, closedBorrowing: true)
    }
    /// Only this same live consumed owner and the journal's exact durable intent
    /// may enter this exception. The result grants no command or host capability.
    func transferToStagedAdmission(intent: CustodyCatalogStore.InstallationStagedAdmissionIntent,
                                   after retirement: RetainedCleanupRegistry.InstallationRetirement,
                                   deadline: MonotonicDeadline) throws -> InstallationStagedAdmission {
        try original.requireExclusiveInstallation(seal)
        // Even wrong/stale proof and live-alias failures permanently close this
        // owner's borrowing gate. A supplied retirement never closes it for us.
        try original.closeInstallationBorrowing(seal)
        try intent.revalidate(for: self, deadline: deadline)
        try retirement.revalidate(for: self)
        try revalidate()
        guard !deadline.hasExpired else { throw CustodyRecordError.fenced }
        try original.beginInstallationAdmissionTransfer(seal)
        do {
            #if SHADOW_SYNC_TESTING
            if let observation = testingAdmissionTransferObservation {
                testingAdmissionTransferObservation = nil
                try observation()
            }
            #endif
            try intent.revalidate(for: self, deadline: deadline)
            try retirement.revalidate(for: self)
            try original.acquireInstallationStagedDescriptions(seal, deadline: deadline)
            #if SHADOW_SYNC_TESTING
            if let observation = testingAdmissionPostflightObservation {
                testingAdmissionPostflightObservation = nil
                try observation()
            }
            #endif
            try intent.revalidate(for: self, deadline: deadline)
            try retirement.revalidate(for: self)
            try revalidate()
            guard !deadline.hasExpired else { throw CustodyRecordError.fenced }
            return InstallationStagedAdmission(self, intent: intent)
        } catch {
            // Original operation remains retained even after postflight failure.
            // No restoration, old admission reopening or retry is authorized.
            original.failInstallationAdmissionTransfer(seal)
            throw error
        }
    }
    func validateReadinessOwner() throws { try validateStagedAdmission() }
    fileprivate func validateStagedAdmission() throws {
        try revalidate(); try original.validateStagedInstallation(seal)
    }
    fileprivate func retainStagedLeases(mode: CustodyAuthorityMode) throws -> CustodyAuthorityLeaseSet {
        try validateStagedAdmission()
        return try original.borrowStagedInstallation(self, seal: seal, mode: mode)
    }
    fileprivate func validateStagedBorrowing(mode: CustodyAuthorityMode) throws {
        try validateStagedAdmission()
        guard original.stagedInstallationCommandsOpen(seal, mode: mode) else { throw CustodyRecordError.fenced }
    }
    func validateStagedCommandAliasesRetired() throws {
        try revalidate(); try original.validateStagedCommandAliasesRetired(seal)
    }
    func retainStagedCommandCompletionLeases(mode: CustodyAuthorityMode) throws -> CustodyAuthorityLeaseSet {
        try validateStagedBorrowing(mode: mode)
        // Atomically prove zero aliases and exclude every new staged borrow for
        // this bounded metadata transition. Release clears only this temporary
        // exclusion; the consumed command permit is never reopened.
        return try original.borrowStagedInstallation(self, seal: seal, mode: mode, forCompletion: true)
    }
    fileprivate func closeStagedStarts() throws -> ClosedInstallationStagedStarts {
        try original.closeStagedInstallationStarts(seal)
        try revalidate()
        return ClosedInstallationStagedStarts(self)
    }
    fileprivate func validateClosedStagedStarts() throws {
        try revalidate(); try original.validateClosedStagedInstallationStarts(seal)
    }
    fileprivate func stagedStop(after retirement: RetainedCleanupRegistry.InstallationStagedStartRetirement)
        throws -> InstallationStagedStopAdmission {
        // Actual registry removal is checked with no authority mutex held. The
        // closed start gate prevents new aliases throughout this check/gap.
        try retirement.revalidate(for: self)
        try validateClosedStagedStarts()
        try original.enterStagedInstallationStop(seal)
        return InstallationStagedStopAdmission(self)
    }
    deinit { original.releaseInstallation(seal) }
    #if SHADOW_SYNC_TESTING
    // Synchronous one-shot fixture observations. No worker can outlive the
    // caller's stack and trigger root cleanup before this transfer has returned.
    private var testingAdmissionTransferObservation: (() throws -> Void)?
    private var testingAdmissionPostflightObservation: (() throws -> Void)?
    func testingObserveAdmissionPostflight(_ observation: (() throws -> Void)?) {
        testingAdmissionPostflightObservation = observation
    }
    func testingObserveAdmissionTransfer(_ observation: (() throws -> Void)?) {
        testingAdmissionTransferObservation = observation
    }
    func testingSetBindingSource(_ source: InstallationBindingTestingSource) throws {
        bindingMutex.lock(); defer { bindingMutex.unlock() }
        guard publisher == nil, fixtureRoot == source.root, liveBinding == nil else { throw CustodyRecordError.fenced }
        try revalidateOriginal(); testingBindingSource = source
    }
    static func testingConsume(_ authority: RunAuthority, root: String) throws -> InstallationTransactionOwner {
        let root = try TestIsolation.validateRoot(root)
        guard authority.stateDirectory.path == (try StateLocation.isolated(root: root)).path else {
            throw CustodyRecordError.fenced
        }
        return try Self(original: authority, publisher: nil, fixtureRoot: root, location: StateLocation.isolated(root: root))
    }
    #endif
}

/// Holds fresh SH admission descriptions and the SAME continuously held original
/// operation EX through its owner. Lease borrowing alone cannot prepare a command:
/// durable action continuation, publisher binding and helper admission are separate.
final class InstallationStagedAdmission: @unchecked Sendable {
    private let owner: InstallationTransactionOwner
    private let intent: CustodyCatalogStore.InstallationStagedAdmissionIntent
    fileprivate init(_ owner: InstallationTransactionOwner, intent: CustodyCatalogStore.InstallationStagedAdmissionIntent) {
        self.owner = owner; self.intent = intent
    }
    func validateOwner(_ candidate: InstallationTransactionOwner,
                       intent: CustodyCatalogStore.InstallationStagedAdmissionIntent) throws {
        guard owner === candidate, self.intent === intent else { throw CustodyRecordError.fenced }
        try revalidate()
    }
    func continueJournal(deadline: MonotonicDeadline) throws -> CustodyCatalogStore.InstallationStagedJournal {
        try intent.continueJournal(admission: self, deadline: deadline)
    }
    func revalidate() throws { try owner.validateStagedBorrowing(mode: .installationStagedStart) }
    func retainStartLeases() throws -> CustodyAuthorityLeaseSet {
        try owner.retainStagedLeases(mode: .installationStagedStart)
    }
    func closeStarts() throws -> ClosedInstallationStagedStarts { try owner.closeStagedStarts() }
    func stopOnly(after retirement: RetainedCleanupRegistry.InstallationStagedStartRetirement)
        throws -> InstallationStagedStopAdmission { try owner.stagedStop(after: retirement) }
}

/// A closed borrowing family, never command retirement or candidate authentication.
final class ClosedInstallationStagedStarts: @unchecked Sendable {
    private let owner: InstallationTransactionOwner
    fileprivate init(_ owner: InstallationTransactionOwner) { self.owner = owner }
    func validate() throws { try owner.validateClosedStagedStarts() }
    func belongs(to candidate: InstallationTransactionOwner) -> Bool { owner === candidate }
}

/// Start borrowing can never be reopened from this value. It grants only retained
/// stop-mode leases, not authenticated lifecycle-exit, bootout or rollback authority.
final class InstallationStagedStopAdmission: @unchecked Sendable {
    private let owner: InstallationTransactionOwner
    fileprivate init(_ owner: InstallationTransactionOwner) { self.owner = owner }
    func validateOwner(_ candidate: InstallationTransactionOwner) throws {
        guard owner === candidate else { throw CustodyRecordError.fenced }; try revalidate()
    }
    func revalidate() throws { try owner.validateStagedBorrowing(mode: .installationStagedStop) }
    func retainStopLeases() throws -> CustodyAuthorityLeaseSet {
        try owner.retainStagedLeases(mode: .installationStagedStop)
    }
}

fileprivate struct InstallationLiveSnapshot: Equatable {
    let boot: String
    let process: ProcessIdentity
    let identity: LifecyclePublisher.InstallationIdentity
    let state: InstallationStateBinding
}

/// Live evidence only: no staged permission or readiness authority. The journal
/// retains the SAME consumed owner; wire observations cannot mint either one.
final class InstallationLiveBinding {
    private let owner: InstallationTransactionOwner
    private let snapshot: InstallationLiveSnapshot
    fileprivate init(owner: InstallationTransactionOwner, snapshot: InstallationLiveSnapshot) {
        self.owner = owner; self.snapshot = snapshot
    }
    var boot: String { snapshot.boot }
    var state: InstallationStateBinding { snapshot.state }
    var sourceReleaseDigest: String { snapshot.identity.sourceReleaseDigest }
    var candidate: InstallationCandidate { snapshot.identity.candidate }
    var coordinator: InstallationCoordinatorObservation {
        let p = snapshot.process, code = snapshot.identity.coordinatorCode
        return InstallationCoordinatorObservation(process: .init(pid: UInt32(p.processID), uid: p.userID,
            startSeconds: p.startSeconds, startMicroseconds: p.startMicroseconds, generation: p.generation),
            team: code.team, identifier: code.identifier,
            cdHash: code.codeDirectory.map { String(format: "%02x", $0) }.joined())
    }
    func revalidate(for candidate: InstallationTransactionOwner) throws {
        guard owner === candidate else { throw CustodyRecordError.fenced }
        try owner.validateLiveBinding(snapshot)
    }
}

#if SHADOW_SYNC_TESTING
// Only disposable fixture owners accept this source. No production callback,
// current boot, real process capture or installed publisher is involved.
final class InstallationBindingTestingSource {
    let root: String
    var identity: LifecyclePublisher.InstallationIdentity
    var process: ProcessIdentity
    var boot: String
    var available = true
    init(root: String, candidate: InstallationCandidate, process: ProcessIdentity, boot: String) throws {
        self.root = try TestIsolation.validateRoot(root)
        identity = try LifecyclePublisher.InstallationIdentity.testing(root: root, candidate: candidate)
        self.process = process; self.boot = boot
    }
}
#endif

/// Only the consumed owner can mint this in-memory capsule. It is a permanently
/// closed borrowing family, not evidence that command journals are retired.
final class ClosedInstallationBorrowing: @unchecked Sendable {
    private let owner: InstallationTransactionOwner
    fileprivate init(_ owner: InstallationTransactionOwner) { self.owner = owner }
    func validate() throws { try owner.validateClosedBorrowing() }
    func belongs(to candidate: InstallationTransactionOwner) -> Bool { owner === candidate }
}

public final class LifecycleAdmissionAuthority: @unchecked Sendable {
    private let custodyMutex = NSLock()
    private var observationBorrowingClosed = false
    private var observationAliases = 0
    private var observationRetirementFailure: OwnedFileDescriptor.Retirement?
    private var observationFamilies: [WeakInstallationAliasFamily] = []
    public let stateDirectory: SecureStateDirectory
    private let namespace: OwnedFileDescriptor
    private let lifecycle: OwnedFileDescriptor

    private init(state: SecureStateDirectory, namespace: Int32, lifecycle: Int32) {
        stateDirectory = state
        self.namespace = OwnedFileDescriptor(namespace)
        self.lifecycle = OwnedFileDescriptor(lifecycle)
    }

    public static func acquire(at location: StateLocation) throws -> LifecycleAdmissionAuthority {
        let state = try SecureStateDirectory.openExisting(location)
        let namespace = try state.openRegularFile(
            named: "latest.log",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        guard flock(namespace, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(namespace)
            if code == EWOULDBLOCK {
                throw SecureStateError.contention("latest.log")
            }
            throw SecureStateError.systemCall("flock latest.log", code)
        }
        var ownsNamespace = true
        defer { if ownsNamespace { close(namespace) } }
        let descriptor = try state.openRegularFile(
            named: "lifecycle.lock",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw SecureStateError.contention("lifecycle.lock")
            }
            throw SecureStateError.systemCall("flock lifecycle.lock", code)
        }
        ownsNamespace = false
        return LifecycleAdmissionAuthority(
            state: state,
            namespace: namespace,
            lifecycle: descriptor
        )
    }

    public func release() {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        lifecycle.closeNow()
        namespace.closeNow()
    }

    var commandAdmissionIsOpen: Bool {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        return !observationBorrowingClosed && namespace.value >= 0 && lifecycle.value >= 0
    }

    #if SHADOW_SYNC_TESTING
    var testingReadinessRetirements: [OwnedFileDescriptor.Retirement] {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        return [lifecycle.retirementObservation, namespace.retirementObservation]
    }
    #endif

    /// Closes borrowing permanently before observing alias drainage. Original
    /// lifecycle then namespace are consumed only after every enrolled alias
    /// has reported successful one-shot closure. Pending never means released.
    func closeCommittedHostObservationBorrowing() -> OwnedFileDescriptor.Retirement {
        custodyMutex.lock()
        observationBorrowingClosed = true
        let families = observationFamilies.compactMap(\.family)
        observationFamilies.removeAll()
        custodyMutex.unlock()
        // Never acquire the family mutex while holding the authority mutex.
        // In-flight copies remain enrolled; their publication closes itself.
        for family in families { family.closeAdmission() }
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        guard observationAliases == 0 else { return .inProgress }
        return observationRetirementFailure ?? .succeeded
    }
    func retireCommittedHostAdmission() -> OwnedFileDescriptor.Retirement {
        let aliases = closeCommittedHostObservationBorrowing()
        guard aliases == .succeeded else { return aliases }
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        let first = lifecycle.retireChecked()
        guard first == .succeeded else { return first }
        return namespace.retireChecked()
    }

    func retainObservationLeases() throws -> CustodyAuthorityLeaseSet {
        custodyMutex.lock()
        guard !observationBorrowingClosed else { custodyMutex.unlock(); throw CustodyRecordError.fenced }
        observationAliases += 1
        // The explicit outcome callback runs only after all actual duplicate
        // descriptions have attempted checked close, including construction cuts.
        custodyMutex.unlock()
        let leases = try CustodyAuthorityLeaseSet.copy(state: stateDirectory, members: [
            (.state, stateDirectory.descriptor), (.namespace, namespace), (.lifecycle, lifecycle),
        ], mode: .observation, onCheckedRetirement: { [self] result in
            custodyMutex.lock(); defer { custodyMutex.unlock() }
            observationAliases -= 1
            if result != .succeeded, observationRetirementFailure == nil { observationRetirementFailure = result }
        })
        custodyMutex.lock()
        observationFamilies.removeAll { $0.family == nil }
        observationFamilies.append(WeakInstallationAliasFamily(leases.initializationAliases))
        let closed = observationBorrowingClosed
        custodyMutex.unlock()
        if closed { leases.initializationAliases.closeAdmission() }
        return leases
    }

}

/// A retained lease bundle, not permission to admit a command. The future typed
/// custody context must also reconcile/reserve its durable catalog entry. There
/// is no public/raw-FD initializer and no close method that can invalidate another
/// holder. Only the last strong reference closes these duplicated descriptions.
fileprivate final class WeakInstallationAliasFamily {
    weak var family: InstallationPublicationAliases?
    init(_ family: InstallationPublicationAliases) { self.family = family }
}

fileprivate final class InstallationPublicationAliases: @unchecked Sendable {
    private let mutex = NSLock()
    private var admissionClosed = false
    private var descriptionsClosed = false
    func withOpenAdmission<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard !admissionClosed, !descriptionsClosed else { throw CustodyRecordError.fenced }
        return try body()
    }
    func closeAdmission() { mutex.lock(); admissionClosed = true; mutex.unlock() }
    func didCloseDescriptions() { mutex.lock(); descriptionsClosed = true; mutex.unlock() }
    var isRetired: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return admissionClosed && descriptionsClosed
    }
}

final class CustodyAuthorityLeaseSet: @unchecked Sendable {
    private final class CheckedRetirementResults {
        private let mutex = NSLock()
        private var result: OwnedFileDescriptor.Retirement = .succeeded
        func record(_ observed: OwnedFileDescriptor.Retirement) {
            mutex.lock(); defer { mutex.unlock() }
            if result == .succeeded, observed != .succeeded { result = observed }
        }
        var observation: OwnedFileDescriptor.Retirement { mutex.lock(); defer { mutex.unlock() }; return result }
    }
    private let checkedRetirementResults: CheckedRetirementResults
    private struct Member {
        let role: CustodyDescriptorClaim.Role
        let descriptor: OwnedFileDescriptor
        let identity: FileIdentity
        let access: Int32
        let acl: String
    }
    fileprivate let initializationAliases: InstallationPublicationAliases
    let mode: CustodyAuthorityMode
    private let state: SecureStateDirectory
    private let members: [Member]
    private let retainedParent: CustodyAuthorityLeaseSet?
    private let onRelease: (@Sendable () -> Void)?
    private let onCheckedRetirement: (@Sendable (OwnedFileDescriptor.Retirement) -> Void)?

    private init(state: SecureStateDirectory, members: [Member], mode: CustodyAuthorityMode,
                 parent: CustodyAuthorityLeaseSet?, onRelease: (@Sendable () -> Void)?,
                 onCheckedRetirement: (@Sendable (OwnedFileDescriptor.Retirement) -> Void)? = nil) {
        self.state = state; self.members = members; self.mode = mode
        retainedParent = parent; self.onRelease = onRelease
        checkedRetirementResults = parent?.checkedRetirementResults ?? CheckedRetirementResults()
        self.onCheckedRetirement = onCheckedRetirement
        initializationAliases = parent?.initializationAliases ?? InstallationPublicationAliases()
    }

    deinit {
        // Closing a duplicate is safe; LOCK_UN would release every holder's lock.
        for member in members.reversed() {
            checkedRetirementResults.record(member.descriptor.retireChecked())
        }
        onCheckedRetirement?(checkedRetirementResults.observation)
        if retainedParent == nil, checkedRetirementResults.observation == .succeeded { initializationAliases.didCloseDescriptions() }
        onRelease?()
    }

    fileprivate static func copy(state: SecureStateDirectory,
        members inputs: [(CustodyDescriptorClaim.Role, OwnedFileDescriptor)], mode: CustodyAuthorityMode,
        parent: CustodyAuthorityLeaseSet? = nil, onRelease: (@Sendable () -> Void)? = nil,
        onCheckedRetirement: (@Sendable (OwnedFileDescriptor.Retirement) -> Void)? = nil
    ) throws -> CustodyAuthorityLeaseSet {
        var members: [Member] = []
        var acquired: [OwnedFileDescriptor] = [], transferred = false
        defer {
            if !transferred {
                var result: OwnedFileDescriptor.Retirement = .succeeded
                for descriptor in acquired.reversed() {
                    let observed = descriptor.retireChecked()
                    if result == .succeeded, observed != .succeeded { result = observed }
                }
                parent?.checkedRetirementResults.record(result)
                onCheckedRetirement?(result)
            }
        }
        // Enroll each acquired duplicate before fallible validation. The defer
        // reports every original close outcome even when construction throws.
        for (role, source) in inputs {
            let descriptor = OwnedFileDescriptor(try source.duplicate(minimum: 201))
            acquired.append(descriptor)
            let snapshot = try snapshot(descriptor.value, role: role, uid: state.uid)
            members.append(Member(role: role, descriptor: descriptor, identity: snapshot.0,
                                  access: snapshot.1, acl: snapshot.2))
        }
        let roles = Set(members.map(\.role))
        var expected: Set<CustodyDescriptorClaim.Role> = [.state, .namespace, .lifecycle]
        if mode.needsOperation { expected.insert(.operation) }
        if mode == .mutation { expected.insert(.run) }
        guard roles == expected, roles.count == members.count else { throw SecureStateError.unsafePath("custody roles") }
        try validate(state: state, members: members)
        let result = CustodyAuthorityLeaseSet(state: state, members: members, mode: mode,
            parent: parent, onRelease: onRelease, onCheckedRetirement: onCheckedRetirement)
        transferred = true
        return result
    }

    /// Read authority is acquired in namespace -> lifecycle -> operation order.
    /// Existing initialized state is required; this cannot initialize/reset catalog
    /// evidence, upgrade a read scope, or touch candidate repositories.
    static func retainReadLeases(at location: StateLocation) throws -> CustodyAuthorityLeaseSet {
        let state = try SecureStateDirectory.openExisting(location)
        var held: [(CustodyDescriptorClaim.Role, OwnedFileDescriptor)] = [(.state, state.descriptor)]
        for (role, name) in [(CustodyDescriptorClaim.Role.namespace, "latest.log"),
                             (.lifecycle, "lifecycle.lock"), (.operation, "operation.lock")] {
            let descriptor = OwnedFileDescriptor(try state.openRegularFile(
                named: name, flags: O_RDONLY, create: false, repairPermissions: false))
            guard flock(descriptor.value, LOCK_SH | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK { throw SecureStateError.contention(name) }
                throw SecureStateError.systemCall("read custody lock", code)
            }
            held.append((role, descriptor))
        }
        return try copy(state: state, members: held, mode: .read)
    }

    /// Recovery starts with fresh exclusive original descriptions in the global
    /// lock order. It never creates missing state/locks, upgrades a shared lease,
    /// or obtains authority from a recorded PID. The caller keeps these alive
    /// until every bounded metadata transition has completed.
    static func retainRecoveryLeases(at location: StateLocation) throws -> CustodyAuthorityLeaseSet {
        let state = try SecureStateDirectory.openExisting(location)
        var held: [(CustodyDescriptorClaim.Role, OwnedFileDescriptor)] = [(.state, state.descriptor)]
        for (role, name) in [(CustodyDescriptorClaim.Role.namespace, "latest.log"),
                             (.lifecycle, "lifecycle.lock"), (.operation, "operation.lock"), (.run, "run.lock")] {
            let descriptor = OwnedFileDescriptor(try state.openRegularFile(
                named: name, flags: O_RDWR, create: false, repairPermissions: false))
            guard flock(descriptor.value, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK { throw SecureStateError.contention(name) }
                throw SecureStateError.systemCall("recovery custody lock", code)
            }
            held.append((role, descriptor))
        }
        return try copy(state: state, members: held, mode: .mutation)
    }

    static func importing(_ inherited: CustodyInheritedCommand) throws -> CustodyAuthorityLeaseSet {
        let state = try SecureStateDirectory.retainedCustodyState(inherited)
        let roles: [CustodyDescriptorClaim.Role] = [.state,.namespace,.lifecycle,.operation,.run]
        let members = roles.compactMap { role in inherited.descriptors[role].map { (role,$0) } }
        let leases = try copy(state: state, members: members, mode: inherited.request.authority)
        let claims = try leases.descriptorClaims()
        guard claims == inherited.request.descriptors.filter({ roles.contains($0.role) }) else { throw CustodyRecordError.fenced }
        return leases
    }

    #if SHADOW_SYNC_TESTING
    func testingUncertainObservationClose(_ closed: @escaping () -> Void) throws {
        guard mode == .observation, let descriptor = members.first(where: { $0.role == .lifecycle })?.descriptor else {
            throw CustodyRecordError.fenced
        }
        descriptor.testingClose = { raw in
            let result = Darwin.close(raw)
            guard result == 0 else { return errno }
            closed(); return EIO
        }
    }
    #endif

    func duplicate() throws -> CustodyAuthorityLeaseSet {
        try initializationAliases.withOpenAdmission {
            try validate()
            return try Self.copy(state: state, members: members.map { ($0.role, $0.descriptor) }, mode: mode, parent: self)
        }
    }

    /// Fresh publication is the only caller. These owners must not retain this
    /// lease family: staged admission later closes namespace/run/lifecycle while
    /// the transferred operation description remains exclusively held.
    fileprivate func duplicateInitializationLocks(_ publication: FreshStateInitialization.PublishedState)
        throws -> [CustodyDescriptorClaim.Role: OwnedFileDescriptor] {
        try initializationAliases.withOpenAdmission {
        guard publication.leases === self, mode == .mutation, retainedParent == nil else { throw CustodyRecordError.fenced }
        try validate()
        var copies: [CustodyDescriptorClaim.Role: OwnedFileDescriptor] = [:]
        for member in members where member.role != .state {
            copies[member.role] = OwnedFileDescriptor(try member.descriptor.duplicate(minimum: 201))
            #if SHADOW_SYNC_TESTING
            if publication.testingFailureAfterCopies == copies.count { throw CustodyRecordError.injectedFailure }
            #endif
        }
        guard Set(copies.keys) == [.namespace, .lifecycle, .operation, .run] else { throw CustodyRecordError.fenced }
        try validate()
        return copies
        }
    }

    func validate() throws { try Self.validate(state: state, members: members) }

    /// App-owned metadata access only; neither a path nor a caller-provided FD
    /// can create this capability. Keep this lease bundle alive for every use.
    func duplicateStateDirectory() throws -> (OwnedFileDescriptor, uid_t) {
        try validate()
        guard let root = members.first(where: { $0.role == .state }) else {
            throw SecureStateError.unsafePath("custody state")
        }
        return (OwnedFileDescriptor(try root.descriptor.duplicate()), state.uid)
    }

    func descriptorClaims() throws -> [CustodyDescriptorClaim] {
        var claims: [CustodyDescriptorClaim] = []
        // Serialize the same fresh observation that passed every existing check.
        // A permitted directory child-count change must not publish stale links.
        try Self.validate(state: state, members: members) { member, observed in
            claims.append(CustodyDescriptorClaim(role: member.role,
                device: observed.device, inode: observed.inode, uid: observed.owner,
                mode: UInt32(observed.mode), links: UInt64(observed.linkCount),
                access: member.access == O_RDONLY ? .read : .readWrite))
        }
        return claims
    }

    /// Register only this bundle's closed roles. The caller retains the bundle
    /// across posix_spawn and separately closes every undeclared inherited FD.
    /// Source copies are above the reserved 190...200 destinations, avoiding cycles.
    func appendSpawnActions(to actions: inout posix_spawn_file_actions_t?) throws {
        try initializationAliases.withOpenAdmission {
        try validate()
        for m in members {
            let result = posix_spawn_file_actions_adddup2(&actions, m.descriptor.value, Int32(m.role.number))
            guard result == 0 else { throw SecureStateError.systemCall("custody spawn descriptor", result) }
        }
        }
    }

    private static func snapshot(_ fd: Int32, role: CustodyDescriptorClaim.Role, uid: uid_t) throws -> (FileIdentity, Int32, String) {
        var info = stat()
        let access = fcntl(fd, F_GETFL), flags = fcntl(fd, F_GETFD)
        guard fd >= 0, fstat(fd, &info) == 0, access >= 0, flags >= 0, flags & FD_CLOEXEC != 0,
              info.st_uid == uid, info.st_mode & 0o7077 == 0,
              (access & O_ACCMODE == O_RDONLY || access & O_ACCMODE == O_RDWR) else {
            throw SecureStateError.unsafePath("custody descriptor")
        }
        let identity = FileIdentity(info)
        if role == .state {
            guard identity.isDirectory, info.st_mode & 0o700 == 0o700 else { throw SecureStateError.unsafePath("custody state") }
        } else {
            guard identity.isRegular, identity.linkCount == 1, info.st_mode & 0o700 == 0o600 else {
                throw SecureStateError.unsafePath("custody lease")
            }
        }
        return (identity, access & O_ACCMODE, try PolicyAuthorityFile.privateStateACL(fd))
    }

    private static func validate(state: SecureStateDirectory, members: [Member],
        observation: ((Member, FileIdentity) -> Void)? = nil) throws {
        guard let root = members.first(where: { $0.role == .state }) else { throw SecureStateError.unsafePath("custody state") }
        let names: [CustodyDescriptorClaim.Role: String] = [.namespace: "latest.log", .lifecycle: "lifecycle.lock",
            .operation: "operation.lock", .run: "run.lock"]
        for member in members {
            let observed = try snapshot(member.descriptor.value, role: member.role, uid: state.uid)
            let sameNode = member.role == .state
                ? observed.0.matchesStableNode(member.identity) : observed.0 == member.identity
            guard sameNode, observed.1 == member.access, observed.2 == member.acl else {
                throw SecureStateError.unsafePath("changed custody descriptor")
            }
            if member.role != .state {
                guard let name = names[member.role] else { throw SecureStateError.unsafePath("custody role") }
                var named = stat()
                guard fstatat(root.descriptor.value, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      FileIdentity(named) == member.identity else { throw SecureStateError.unsafePath("replaced custody lease") }
            }
            observation?(member, observed.0)
        }
    }

    #if SHADOW_SYNC_TESTING
    func testingDescriptorFlags() -> [(Int32, Int32)] {
        members.map { ($0.descriptor.value, fcntl($0.descriptor.value, F_GETFD)) }
    }
    #endif
}

#if SHADOW_SYNC_TESTING
/// One-shot fixture hook at the actual publication boundary. The cell owns real
/// root/descendant descriptor families until the fixture takes and drops them.
final class InstallationPublicationTestingCapture: @unchecked Sendable {
    private let mutex = NSLock()
    private var armed = false
    private var captured: (CustodyAuthorityLeaseSet, CustodyAuthorityLeaseSet)?
    func arm() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !armed, captured == nil else { throw CustodyRecordError.fenced }
        armed = true
    }
    func captureIfArmed(_ root: CustodyAuthorityLeaseSet) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard armed else { return }
        captured = (root, try root.duplicate()); armed = false
    }
    func take() throws -> (CustodyAuthorityLeaseSet, CustodyAuthorityLeaseSet) {
        mutex.lock(); defer { mutex.unlock() }
        guard let result = captured else { throw CustodyRecordError.fenced }
        captured = nil; return result
    }
    func clear() {
        mutex.lock(); armed = false; let old = captured; captured = nil; mutex.unlock()
        withExtendedLifetime(old) {}
    }
}

final class CustodyLeaseTestingBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var contended: Bool?
    func pause() -> Bool {
        condition.lock(); defer { condition.unlock() }
        entered = true; condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 4)
        while !released { if !condition.wait(until: deadline) { return false } }
        return true
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func record(contended: Bool) {
        condition.lock(); self.contended = contended; condition.broadcast(); condition.unlock()
    }
    func waitUntilEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 4)
        while !entered { if !condition.wait(until: deadline) { return false } }
        return true
    }
    func waitUntilContended() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 4)
        while contended == nil { if !condition.wait(until: deadline) { return false } }
        return contended == true
    }
}
#endif
