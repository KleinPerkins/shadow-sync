import Darwin
import Foundation

/// One helper's live descriptor ownership. A decoded receipt cannot construct
/// this object. The helper retains it BEFORE create() and through every failure;
/// deinit closes descriptors but never pretends to have removed filesystem data.
final class DiscoveryFrozenResource {
    private struct Node {
        let fd: OwnedFileDescriptor
        let identity: FileIdentity
        let acl: String
        static func capture(_ fd: OwnedFileDescriptor, uid: uid_t, directory: Bool) throws -> Self {
            var info = stat()
            guard fstat(fd.value, &info) == 0, info.st_uid == uid,
                  info.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600),
                  directory || info.st_nlink == 1,
                  info.st_flags & ~UInt32(UF_IMMUTABLE) == 0 else { throw CustodyResourceError.invalidResource }
            return Self(fd: fd, identity: FileIdentity(info), acl: try PolicyAuthorityFile.privateStateACL(fd.value))
        }
        func validate(uid: uid_t, directory: Bool, removed: Bool = false) throws -> stat {
            var info = stat()
            guard fstat(fd.value, &info) == 0, FileIdentity(info).matchesStableNode(identity),
                  info.st_uid == uid, directory || info.st_nlink == (removed ? 0 : 1),
                  info.st_flags & ~UInt32(UF_IMMUTABLE) == 0,
                  try PolicyAuthorityFile.privateStateACL(fd.value) == acl else { throw CustodyResourceError.invalidResource }
            return info
        }
    }
    private final class Parent {
        struct Anchor { let name: String; let fd: OwnedFileDescriptor; let identity: FileIdentity; let acl: String }
        let path: String
        private let anchors: [Anchor]
        var fd: Int32 { anchors.last!.fd.value }
        init(testRoot: String?) throws {
            var components = ["private", "tmp"]
            #if SHADOW_SYNC_TESTING
            if let testRoot {
                let root = try TestIsolation.validateRoot(testRoot)
                guard root.hasPrefix("/private/tmp/"), !root.dropFirst("/private/tmp/".count).contains("/") else {
                    throw CustodyResourceError.invalidResource
                }
                components += [String(root.dropFirst("/private/tmp/".count)), "owner-resources"]
            }
            #else
            guard testRoot == nil else { throw CustodyResourceError.invalidResource }
            #endif
            path = "/" + components.joined(separator: "/")
            var result: [Anchor] = []
            for (index, component) in (["/"] + components).enumerated() {
                let raw = index == 0 ? open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    : openat(result.last!.fd.value, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
                let fd = OwnedFileDescriptor(raw); var info = stat()
                guard fstat(raw, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw CustodyResourceError.invalidResource }
                if index <= 1 {
                    guard info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw CustodyResourceError.invalidResource }
                } else if index == 2 {
                    guard info.st_uid == 0, info.st_mode & 0o7777 == 0o1777 else { throw CustodyResourceError.invalidResource }
                } else {
                    guard info.st_uid == geteuid(), info.st_mode == S_IFDIR | 0o700 else { throw CustodyResourceError.invalidResource }
                }
                result.append(Anchor(name: component, fd: fd, identity: FileIdentity(info),
                    acl: try PolicyAuthorityFile.privateStateACL(raw)))
            }
            anchors = result; try validate()
        }
        func validate() throws {
            for (index, anchor) in anchors.enumerated() {
                var opened = stat(), named = stat()
                let result = index == 0 ? lstat("/", &named)
                    : fstatat(anchors[index - 1].fd.value, anchor.name, &named, AT_SYMLINK_NOFOLLOW)
                guard result == 0, fstat(anchor.fd.value, &opened) == 0,
                      FileIdentity(opened).matchesStableNode(anchor.identity),
                      FileIdentity(named).matchesStableNode(anchor.identity),
                      try PolicyAuthorityFile.privateStateACL(anchor.fd.value) == anchor.acl else {
                    throw CustodyResourceError.invalidResource
                }
            }
        }
    }
    private let captured: CapturedGitConfiguration
    private let leases: CustodyAuthorityLeaseSet
    private let admission: () throws -> Void
    private let persist: (DiscoveryResourceReceipt?, DiscoveryResourceReceipt) throws -> Void
    private let readReceipt: () throws -> DiscoveryResourceReceipt
    private let testRoot: String?
    private let name: String
    private var parent: Parent?
    private var rawDirectory: OwnedFileDescriptor?, rawFile: OwnedFileDescriptor?
    private var directory: Node?, file: Node?
    private var directoryCreated = false, fileRemoved = false, directoryRemoved = false
    private var creationAttempted = false, retirementStarted = false
    private var durable: DiscoveryResourceReceipt?
    private var pending: DiscoveryResourceReceipt?
    private(set) var receipt: DiscoveryResourceReceipt
    private(set) var snapshot: GitConfigurationSnapshot?
    var isRetired: Bool { receipt.phase == .retired && durable == receipt && pending == nil }
    var descriptor: Int32? {
        snapshot == nil || retirementStarted || receipt.phase != .sealed || durable != receipt || pending != nil
            ? nil : file?.fd.value
    }

    init(helper: CustodyHelperJournal, captured: CapturedGitConfiguration,
         admission: @escaping () throws -> Void) throws {
        self.captured = captured; leases = helper.leases; self.admission = admission
        #if SHADOW_SYNC_TESTING
        testRoot = helper.inherited.testingDiscovery
            ? DiscoveryFixtureResources.resourceRoot(home: helper.inherited.account.homeDirectory) : nil
        #else
        testRoot = nil
        #endif
        receipt = try helper.readDiscoveryResource()
        guard receipt.phase == .planned else { throw CustodyRecordError.fenced }
        durable = receipt
        name = try DiscoveryResourceReceipt.directoryName(requestID: receipt.binding.requestID)
        persist = { [weak helper] expected, next in
            guard let helper else { throw CustodyRecordError.fenced }
            try helper.persistDiscoveryResource(expected: expected, next: next)
        }
        readReceipt = { [weak helper] in
            guard let helper else { throw CustodyRecordError.fenced }
            return try helper.readDiscoveryResource()
        }
    }
    private func validateLease() throws {
        try leases.validate()
        guard receipt.binding.uid == geteuid(), try CustodyBootIdentity.current() == receipt.binding.bootID else {
            throw CustodyRecordError.fenced
        }
    }
    private func flushPending() throws {
        guard let next = pending else { return }
        try validateLease(); try persist(durable, next)
        guard try readReceipt() == next else { throw CustodyRecordError.fenced }
        durable = next; receipt = next; pending = nil
    }
    private func record(_ next: DiscoveryResourceReceipt) throws {
        guard pending == nil else { throw CustodyRecordError.fenced }
        pending = next; try flushPending()
    }
    private func validateName(_ node: Node, in parent: Int32, name: String, directory: Bool) throws {
        _ = try node.validate(uid: receipt.binding.uid, directory: directory)
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(named).matchesStableNode(node.identity), directory || named.st_nlink == 1 else {
            throw CustodyResourceError.invalidResource
        }
    }
    private func acquireKnownNodes() throws {
        guard let parent else { throw CustodyRecordError.fenced }
        try parent.validate()
        if directoryCreated && directory == nil {
            // mkdir succeeded but open did not: no descriptor identity exists.
            // Do not adopt a later pathname or remove a possible replacement.
            guard let rawDirectory else { throw CustodyRecordError.fenced }
            let node = try Node.capture(rawDirectory, uid: receipt.binding.uid, directory: true)
            try validateName(node, in: parent.fd, name: name, directory: true)
            directory = node
        }
        if let directory, receipt.phase == .intent {
            try record(receipt.advancing(to: .directoryCreated, directory: directory.identity))
        }
        if let rawFile, file == nil {
            guard let directory else { throw CustodyRecordError.fenced }
            let node = try Node.capture(rawFile, uid: receipt.binding.uid, directory: false)
            try validateName(node, in: directory.fd.value, name: "config", directory: false)
            file = node
        }
        if let file, receipt.phase == .directoryCreated {
            try record(receipt.advancing(to: .fileCreated, file: file.identity))
        }
    }
    func create() throws {
        guard !creationAttempted, !retirementStarted else { throw CustodyRecordError.invalidTransition }
        creationAttempted = true
        try validateLease(); try admission()
        try record(receipt.capturing(contentSHA256: CustodyRecordBinding.digest(captured.bytes),
                                    size: UInt64(captured.bytes.count)))
        #if SHADOW_SYNC_TESTING
        try fault(.afterIntent)
        #endif
        try admission(); parent = try Parent(testRoot: testRoot)
        guard let parent else { throw CustodyRecordError.fenced }
        try parent.validate(); try admission()
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw CustodyResourceError.systemCall(errno) }
        directoryCreated = true
        #if SHADOW_SYNC_TESTING
        try fault(.afterMkdir)
        #endif
        let dir = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw CustodyResourceError.systemCall(errno) }
        rawDirectory = OwnedFileDescriptor(dir)
        #if SHADOW_SYNC_TESTING
        try fault(.afterDirectoryOpen)
        #endif
        try acquireKnownNodes()
        guard let directory else { throw CustodyRecordError.fenced }
        guard fsync(directory.fd.value) == 0, fsync(parent.fd) == 0 else { throw CustodyResourceError.systemCall(errno) }
        #if SHADOW_SYNC_TESTING
        try fault(.afterDirectoryReceipt)
        #endif
        try admission(); try parent.validate(); try validateName(directory, in: parent.fd, name: name, directory: true)
        let raw = openat(directory.fd.value, "config", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        rawFile = OwnedFileDescriptor(raw)
        #if SHADOW_SYNC_TESTING
        try fault(.afterFileOpen)
        #endif
        try acquireKnownNodes()
        guard let file else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        try fault(.afterFileReceipt)
        #endif
        try captured.bytes.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try admission()
                let count = Darwin.write(raw, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CustodyResourceError.systemCall(errno) }; offset += count
            }
        }
        #if SHADOW_SYNC_TESTING
        try fault(.afterWrite)
        #endif
        guard fsync(raw) == 0, fsync(directory.fd.value) == 0 else { throw CustodyResourceError.systemCall(errno) }
        try parent.validate(); try validateName(directory, in: parent.fd, name: name, directory: true)
        try validateName(file, in: directory.fd.value, name: "config", directory: false)
        try admission()
        guard fchflags(raw, UInt32(UF_IMMUTABLE)) == 0 else { throw CustodyResourceError.systemCall(errno) }
        #if SHADOW_SYNC_TESTING
        try fault(.afterFileSeal)
        #endif
        guard fchflags(directory.fd.value, UInt32(UF_IMMUTABLE)) == 0 else { throw CustodyResourceError.systemCall(errno) }
        #if SHADOW_SYNC_TESTING
        try fault(.afterDirectorySeal)
        #endif
        let ro = openat(directory.fd.value, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard ro >= 0 else { throw CustodyResourceError.systemCall(errno) }
        let readonly = try Node.capture(OwnedFileDescriptor(ro), uid: receipt.binding.uid, directory: false)
        guard readonly.identity == file.identity, readonly.acl == file.acl,
              flock(ro, LOCK_EX | LOCK_NB) == 0 else { throw CustodyResourceError.invalidResource }
        self.file = readonly; rawFile?.closeNow(); rawFile = nil
        #if SHADOW_SYNC_TESTING
        try fault(.afterReadOnlyOpen)
        #endif
        let directoryInfo = try directory.validate(uid: receipt.binding.uid, directory: true)
        snapshot = GitConfigurationSnapshot(contributors: captured.contributors, repositoryConfig: captured.repositoryConfig,
            frozenDirectoryPath: parent.path + "/" + name, frozenDirectoryIdentity: FileIdentity(directoryInfo),
            frozenPath: parent.path + "/" + name + "/config", frozenIdentity: readonly.identity,
            frozenOwnerPID: getpid(), frozenSHA256: CustodyRecordBinding.digest(captured.bytes), frozenSize: captured.bytes.count)
        try revalidate(); try admission()
        try record(receipt.advancing(to: .sealed))
        #if SHADOW_SYNC_TESTING
        try fault(.afterSealReceipt)
        #endif
    }
    func revalidate() throws {
        try validateLease()
        guard !retirementStarted, !fileRemoved, !directoryRemoved, let parent, let directory, let file, let snapshot,
              fcntl(file.fd.value, F_GETFL) & O_ACCMODE == O_RDONLY else { throw CustodyResourceError.invalidResource }
        try parent.validate(); try validateName(directory, in: parent.fd, name: name, directory: true)
        try validateName(file, in: directory.fd.value, name: "config", directory: false)
        try RepositoryHandle.validateFrozenConfiguration(descriptor: file.fd.value,
            directoryDescriptor: directory.fd.value, snapshot: snapshot)
    }
    /// Call only after exact target/group retirement and EOF. No cancellation
    /// admission callback is needed to retire already-owned private resources.
    /// A partial unlink is remembered independently of the durable cursor, so a
    /// failed fsync/write can be retried without demanding the removed name.
    func retire() throws {
        try validateLease(); try flushPending()
        if isRetired {
            guard try readReceipt() == receipt else { throw CustodyRecordError.fenced }
            releaseDescriptors(); return
        }
        if !directoryCreated {
            retirementStarted = true
            if durable == nil { try record(receipt) }
            try record(receipt.advancing(to: .retired)); releaseDescriptors(); return
        }
        try acquireKnownNodes()
        guard let parent, let directory else { throw CustodyRecordError.fenced }
        try parent.validate()
        if !directoryRemoved {
            try validateName(directory, in: parent.fd, name: name, directory: true)
            if receipt.phase == .sealed && !retirementStarted { try revalidate() }
            // Once cleanup begins, immutable bits may legitimately be cleared.
            // Retained descriptor/name/ACL checks remain mandatory on retries;
            // no target may use this snapshot again.
            retirementStarted = true
            let info = try directory.validate(uid: receipt.binding.uid, directory: true)
            guard fchflags(directory.fd.value, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else { throw CustodyResourceError.systemCall(errno) }
            #if SHADOW_SYNC_TESTING
            try fault(.afterDirectoryUnseal)
            #endif
            if let file, !fileRemoved {
                try validateName(file, in: directory.fd.value, name: "config", directory: false)
                let info = try file.validate(uid: receipt.binding.uid, directory: false)
                guard fchflags(file.fd.value, info.st_flags & ~UInt32(UF_IMMUTABLE)) == 0 else { throw CustodyResourceError.systemCall(errno) }
                #if SHADOW_SYNC_TESTING
                try fault(.afterFileUnseal)
                #endif
                try validateName(file, in: directory.fd.value, name: "config", directory: false)
                guard unlinkat(directory.fd.value, "config", 0) == 0 else { throw CustodyResourceError.systemCall(errno) }
                fileRemoved = true
                #if SHADOW_SYNC_TESTING
                try fault(.afterFileUnlink)
                #endif
            }
            if fileRemoved {
                guard let file else { throw CustodyRecordError.fenced }
                _ = try file.validate(uid: receipt.binding.uid, directory: false, removed: true)
                var missing = stat()
                guard fstatat(directory.fd.value, "config", &missing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT,
                      fsync(directory.fd.value) == 0 else { throw CustodyResourceError.invalidResource }
                #if SHADOW_SYNC_TESTING
                try fault(.afterFileUnlinkSync)
                #endif
                if receipt.phase != .fileRemoved { try record(receipt.advancing(to: .fileRemoved)) }
                #if SHADOW_SYNC_TESTING
                try fault(.afterFileRemovalReceipt)
                #endif
            }
            try parent.validate(); try validateName(directory, in: parent.fd, name: name, directory: true)
            // rmdir refuses unexpected entries; there is deliberately no walk.
            guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw CustodyResourceError.systemCall(errno) }
            directoryRemoved = true
            #if SHADOW_SYNC_TESTING
            try fault(.afterDirectoryUnlink)
            #endif
        }
        var missing = stat()
        guard fstatat(parent.fd, name, &missing, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT,
              fsync(parent.fd) == 0 else { throw CustodyResourceError.invalidResource }
        #if SHADOW_SYNC_TESTING
        try fault(.afterParentSync)
        #endif
        if receipt.phase != .directoryRemoved { try record(receipt.advancing(to: .directoryRemoved)) }
        #if SHADOW_SYNC_TESTING
        try fault(.afterDirectoryRemovalReceipt)
        #endif
        try record(receipt.advancing(to: .retired))
        #if SHADOW_SYNC_TESTING
        try fault(.afterRetiredReceipt)
        #endif
        releaseDescriptors()
    }
    private func releaseDescriptors() {
        retirementStarted = true
        rawFile?.closeNow(); file?.fd.closeNow(); rawDirectory?.closeNow(); directory?.fd.closeNow()
        rawFile = nil; rawDirectory = nil; file = nil; directory = nil; parent = nil; snapshot = nil
    }
    #if SHADOW_SYNC_TESTING
    enum Fault: String, CaseIterable {
        case afterIntent, afterMkdir, afterDirectoryOpen, afterDirectoryReceipt, afterFileOpen, afterFileReceipt
        case afterWrite, afterFileSeal, afterDirectorySeal, afterReadOnlyOpen, afterSealReceipt
        case afterDirectoryUnseal, afterFileUnseal, afterFileUnlink, afterFileUnlinkSync, afterFileRemovalReceipt
        case afterDirectoryUnlink, afterParentSync, afterDirectoryRemovalReceipt, afterRetiredReceipt
    }
    var testingFault: Fault?
    private func fault(_ value: Fault) throws {
        if testingFault == value { testingFault = nil; throw CustodyRecordError.injectedFailure }
    }
    var testingDescriptors: (directory: Int32?, file: Int32?) { (directory?.fd.value, file?.fd.value) }
    var testingName: String { name }
    init(testing captured: CapturedGitConfiguration, journal: CustodyJournal, leases: CustodyAuthorityLeaseSet,
         root: String, persistenceFault: ((DiscoveryResourceReceipt.Phase) -> CustodyCatalogStore.Fault?)? = nil,
         admission: @escaping () throws -> Void) throws {
        _ = try TestIsolation.validateRoot(root)
        self.captured = captured; self.leases = leases; self.admission = admission; testRoot = root
        receipt = try CustodyCatalogStore(leases: leases).readDiscoveryResource(journal: journal)
        guard receipt.phase == .planned else { throw CustodyRecordError.fenced }
        durable = receipt
        name = try DiscoveryResourceReceipt.directoryName(requestID: receipt.binding.requestID)
        persist = { expected, next in
            let store = try CustodyCatalogStore(leases: leases)
            if let cut = persistenceFault?(next.phase) { store.testingFault(cut) }
            try store.persistDiscoveryResource(journal: journal, expected: expected, next: next)
        }
        readReceipt = { try CustodyCatalogStore(leases: leases).readDiscoveryResource(journal: journal) }
    }
    #endif
}
