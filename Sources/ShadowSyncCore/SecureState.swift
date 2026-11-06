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

    func closeNow() {
        lock.lock()
        let fd = rawValue
        rawValue = -1
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
    }

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
    // Retirement, staged admission and release close this scope permanently.
    // A failed/busy transition does not reopen it; only a fresh authority may
    // issue new leases. Existing retained descriptions remain valid until closed.
    private var custodyAdmissionClosed = false
    private let state: SecureStateDirectory
    private let namespace: OwnedFileDescriptor
    private let lifecycle: OwnedFileDescriptor
    private let operation: OwnedFileDescriptor
    private let run: OwnedFileDescriptor?
    private let commandMode: CustodyAuthorityMode
    private let releasesInitializationLocksForStaging: Bool

    public var stateDirectory: SecureStateDirectory { state }

    private init(
        state: SecureStateDirectory,
        namespace: OwnedFileDescriptor,
        lifecycle: OwnedFileDescriptor,
        operation: OwnedFileDescriptor,
        run: OwnedFileDescriptor?,
        commandMode: CustodyAuthorityMode,
        releasesInitializationLocksForStaging: Bool = false
    ) {
        self.state = state
        self.namespace = namespace
        self.lifecycle = lifecycle
        self.operation = operation
        self.run = run
        self.commandMode = commandMode
        self.releasesInitializationLocksForStaging = releasesInitializationLocksForStaging
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
        guard let namespace = locks[.namespace], let lifecycle = locks[.lifecycle],
              let operation = locks[.operation], let run = locks[.run] else { throw CustodyRecordError.fenced }
        return RunAuthority(state: state, namespace: namespace, lifecycle: lifecycle,
            operation: operation, run: run, commandMode: .lifecycleMutation,
            releasesInitializationLocksForStaging: true)
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
        guard !custodyAdmissionClosed else {
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
        guard !custodyAdmissionClosed else { throw SecureStateError.contention("closed command custody") }
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
        custodyBorrowCount += 1
        return result
    }

    func permitStagedHostAdmission() throws {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
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
        custodyAdmissionClosed = true
        run?.closeNow()
        operation.closeNow()
        lifecycle.closeNow()
        namespace.closeNow()
    }

    #if SHADOW_SYNC_TESTING
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

public final class LifecycleAdmissionAuthority: @unchecked Sendable {
    private let custodyMutex = NSLock()
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
        return namespace.value >= 0 && lifecycle.value >= 0
    }

    func retainObservationLeases() throws -> CustodyAuthorityLeaseSet {
        custodyMutex.lock(); defer { custodyMutex.unlock() }
        return try CustodyAuthorityLeaseSet.copy(state: stateDirectory, members: [
            (.state, stateDirectory.descriptor), (.namespace, namespace), (.lifecycle, lifecycle),
        ], mode: .observation)
    }
}

/// A retained lease bundle, not permission to admit a command. The future typed
/// custody context must also reconcile/reserve its durable catalog entry. There
/// is no public/raw-FD initializer and no close method that can invalidate another
/// holder. Only the last strong reference closes these duplicated descriptions.
final class CustodyAuthorityLeaseSet: @unchecked Sendable {
    private struct Member {
        let role: CustodyDescriptorClaim.Role
        let descriptor: OwnedFileDescriptor
        let identity: FileIdentity
        let access: Int32
        let acl: String
    }
    let mode: CustodyAuthorityMode
    private let state: SecureStateDirectory
    private let members: [Member]
    private let retainedParent: CustodyAuthorityLeaseSet?
    private let onRelease: (@Sendable () -> Void)?

    private init(state: SecureStateDirectory, members: [Member], mode: CustodyAuthorityMode,
                 parent: CustodyAuthorityLeaseSet?, onRelease: (@Sendable () -> Void)?) {
        self.state = state; self.members = members; self.mode = mode
        retainedParent = parent; self.onRelease = onRelease
    }

    deinit {
        // Closing a duplicate is safe; LOCK_UN would release every holder's lock.
        for member in members.reversed() { member.descriptor.closeNow() }
        onRelease?()
    }

    fileprivate static func copy(state: SecureStateDirectory,
        members inputs: [(CustodyDescriptorClaim.Role, OwnedFileDescriptor)], mode: CustodyAuthorityMode,
        parent: CustodyAuthorityLeaseSet? = nil, onRelease: (@Sendable () -> Void)? = nil
    ) throws -> CustodyAuthorityLeaseSet {
        var members: [Member] = []
        // A failed partial construction closes all prior duplicates through ARC;
        // the release hook is installed only after validation has succeeded.
        for (role, source) in inputs {
            let descriptor = OwnedFileDescriptor(try source.duplicate(minimum: 201))
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
        return CustodyAuthorityLeaseSet(state: state, members: members, mode: mode, parent: parent, onRelease: onRelease)
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

    func duplicate() throws -> CustodyAuthorityLeaseSet {
        try validate()
        return try Self.copy(state: state, members: members.map { ($0.role, $0.descriptor) }, mode: mode, parent: self)
    }

    /// Fresh publication is the only caller. These owners must not retain this
    /// lease family: staged admission later closes namespace/run/lifecycle while
    /// the transferred operation description remains exclusively held.
    fileprivate func duplicateInitializationLocks(_ publication: FreshStateInitialization.PublishedState)
        throws -> [CustodyDescriptorClaim.Role: OwnedFileDescriptor] {
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
        try validate()
        return members.map { m in
            CustodyDescriptorClaim(role: m.role, device: m.identity.device, inode: m.identity.inode,
                uid: m.identity.owner, mode: UInt32(m.identity.mode), links: UInt64(m.identity.linkCount),
                access: m.access == O_RDONLY ? .read : .readWrite)
        }
    }

    /// Register only this bundle's closed roles. The caller retains the bundle
    /// across posix_spawn and separately closes every undeclared inherited FD.
    /// Source copies are above the reserved 190...200 destinations, avoiding cycles.
    func appendSpawnActions(to actions: inout posix_spawn_file_actions_t?) throws {
        try validate()
        for m in members {
            let result = posix_spawn_file_actions_adddup2(&actions, m.descriptor.value, Int32(m.role.number))
            guard result == 0 else { throw SecureStateError.systemCall("custody spawn descriptor", result) }
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

    private static func validate(state: SecureStateDirectory, members: [Member]) throws {
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
        }
    }

    #if SHADOW_SYNC_TESTING
    func testingDescriptorFlags() -> [(Int32, Int32)] {
        members.map { ($0.descriptor.value, fcntl($0.descriptor.value, F_GETFD)) }
    }
    #endif
}

#if SHADOW_SYNC_TESTING
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
