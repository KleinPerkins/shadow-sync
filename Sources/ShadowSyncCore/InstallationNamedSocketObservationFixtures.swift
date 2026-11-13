#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Native primitive qualification source only. These cases use strict parent-relative getattrlistat,
/// actual socket binds and original descriptors in fresh private namespaces.
/// They do not start listeners, authenticate peers or qualify product ownership.
enum InstallationNamedSocketObservationFixtures {
    typealias H = InstallationStorageFixtures
    typealias O = InstallationNamedSocketObservation

    private enum SetupCut { case none, firstAncestor, socketDescriptor }
    private enum RetirementCut { case none, beforeDescriptors, beforeChildUnlink }
    private final class Fixture: InstallationNamedSocketFixtureCustodyOwner {
        let outerRoot: String, root: String
        var rootIdentity: stat?
        var rootCreationUnresolved = false
        var chain: [OwnedFileDescriptor] = []
        var listeners: [OwnedFileDescriptor] = []
        var children: [String: stat] = [:]
        var unresolvedChildren: Set<String> = []
        var rootName: String
        var setupComplete = false, namespaceRetired = false, finished = false
        var retiredListeners = 0, retiredAncestors = 0
        var retirementCut: RetirementCut = .none
        init(outerRoot: String, parent: String) {
            self.outerRoot = outerRoot; root = parent
            rootName = String(parent.split(separator: "/").last!)
        }
        var parent: Int32 { chain.last!.value }
        var enclosing: Int32 { chain[chain.count - 2].value }
        func address(_ endpoint: O.Endpoint = .installation) throws -> O.Address {
            try .init(canonicalParent: root, endpoint: endpoint)
        }
        func read(_ endpoint: O.Endpoint = .installation, expected: O? = nil,
                  deadline: MonotonicDeadline = .init(seconds: 0.75)) throws -> O {
            try O.read(address: address(endpoint), retainedAncestors: chain, uid: geteuid(),
                       deadline: deadline, expected: expected)
        }
        static func sameNode(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
                && a.st_gid == b.st_gid && a.st_mode & S_IFMT == b.st_mode & S_IFMT
        }
        func verifyRoot() throws {
            guard let original = rootIdentity, chain.count >= 2 else { throw CustodyRecordError.fenced }
            var held = stat(), named = stat()
            try H.check(fstat(parent, &held) == 0
                && fstatat(enclosing, rootName, &named, AT_SYMLINK_NOFOLLOW) == 0
                && Self.sameNode(original, held) && Self.sameNode(original, named)
                && held.st_mode == S_IFDIR | 0o700 && named.st_mode == held.st_mode
                && held.st_flags == 0 && named.st_flags == 0 && held.st_nlink > 0,
                "named socket fixture original private root")
            _ = try PolicyAuthorityFile.privateStateACL(parent)
        }
        func current(_ name: String) throws -> stat {
            try verifyRoot()
            guard let original = children[name] else { throw CustodyRecordError.fenced }
            var now = stat()
            try H.check(fstatat(parent, name, &now, AT_SYMLINK_NOFOLLOW) == 0
                && Self.sameNode(original, now) && now.st_nlink == 1 && now.st_flags == 0,
                "named socket fixture original child")
            return now
        }
        func captureCreated(_ name: String, type: mode_t) throws {
            var node = stat()
            try H.check(children[name] == nil && fstatat(parent, name, &node, AT_SYMLINK_NOFOLLOW) == 0
                && node.st_mode & S_IFMT == type && node.st_uid == geteuid()
                && node.st_nlink == 1 && node.st_flags == 0, "named socket fixture created identity")
            children[name] = node; unresolvedChildren.remove(name)
        }
        func bind(_ endpoint: O.Endpoint = .installation, cut: SetupCut = .none) throws {
            try verifyRoot()
            let address = try address(endpoint)
            var missing = stat()
            try H.check(fstatat(parent, endpoint.rawValue, &missing, AT_SYMLINK_NOFOLLOW) == -1
                && errno == ENOENT, "named socket fixture bind absence")
            let raw = socket(AF_UNIX, SOCK_STREAM, 0)
            try H.check(raw >= 0, "named socket fixture listener acquisition")
            let owner = OwnedFileDescriptor(raw); listeners.append(owner)
            if cut == .socketDescriptor { throw CustodyRecordError.busy }
            try H.check(fcntl(raw, F_SETFD, FD_CLOEXEC) == 0, "named socket fixture descriptor flags")
            var value = sockaddr_un()
            value.sun_family = sa_family_t(AF_UNIX)
            value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(address.bytes) + [0]
            withUnsafeMutableBytes(of: &value.sun_path) { destination in
                destination.copyBytes(from: bytes)
            }
            unresolvedChildren.insert(endpoint.rawValue)
            let result = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                // Failed creation is not assumed absent. Unknown identity keeps
                // this original owner pending and prevents outer-root deletion.
                var absent = stat()
                if fstatat(parent, endpoint.rawValue, &absent, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT {
                    unresolvedChildren.remove(endpoint.rawValue)
                }
                throw CustodyRecordError.unsafeMetadata
            }
            // Bind creates the named node; never derive it from listener stat.
            try captureCreated(endpoint.rawValue, type: S_IFSOCK)
            try setMode(endpoint.rawValue, 0o600)
        }
        /// Creator-only fixture setup on an unpublished bound node. This is NOT
        /// a product setter or atomic expected-inode chmod. Lexical single-thread
        /// ownership and before/after identity checks are fixture obligations.
        func setMode(_ name: String, _ mode: mode_t) throws {
            let before = try current(name)
            try H.check(before.st_mode & S_IFMT == S_IFSOCK,
                        "named socket fixture mode target")
            try H.check(fchmodat(parent, name, mode, AT_SYMLINK_NOFOLLOW) == 0,
                        "named socket fixture nofollow mode candidate")
            let after = try current(name)
            try H.check(Self.sameNode(before, after) && after.st_mode == S_IFSOCK | mode,
                        "named socket fixture mode postimage")
        }
        func setACL(_ endpoint: O.Endpoint, tag: acl_tag_t?) throws -> String {
            let before = try current(endpoint.rawValue)
            var acl = acl_init(tag == nil ? 0 : 1)
            guard acl != nil else { throw PolicyAuthorityFileError.unavailable }
            defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
            if let tag {
                var entry: acl_entry_t?
                try H.check(acl_create_entry(&acl, &entry) == 0 && entry != nil, "named socket fixture ACL entry")
                var uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!.uuid
                try H.check(acl_set_tag_type(entry!, tag) == 0 && acl_set_qualifier(entry!, &uuid) == 0,
                            "named socket fixture ACL qualifier")
                var permissions: acl_permset_t?
                try H.check(acl_get_permset(entry!, &permissions) == 0 && permissions != nil,
                            "named socket fixture ACL permissions")
                try H.check(acl_add_perm(permissions!, ACL_READ_DATA) == 0, "named socket fixture ACL right")
            }
            try H.check(acl_valid(acl) == 0, "named socket fixture valid ACL")
            let size = acl_size(acl)
            try H.check((1...65_536).contains(size), "named socket fixture portable ACL size")
            var bytes = Data(count: size)
            let copied = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
            try H.check(copied == size, "named socket fixture portable ACL bytes")
            try H.check(acl_set_link_np(try address(endpoint).path, ACL_TYPE_EXTENDED, acl) == 0,
                        "named socket fixture actual named ACL setter")
            let after = try current(endpoint.rawValue)
            try H.check(Self.sameNode(before, after) && before.st_mode == after.st_mode,
                        "named socket fixture ACL postidentity")
            return CustodyRecordBinding.digest(bytes)
        }
        func renameChild(_ from: String, _ to: String) throws {
            let original = try current(from)
            var missing = stat()
            try H.check(children[to] == nil && fstatat(parent, to, &missing, AT_SYMLINK_NOFOLLOW) == -1
                && errno == ENOENT, "named socket fixture rename destination absent")
            try H.check(renameat(parent, from, parent, to) == 0, "named socket fixture rename")
            children.removeValue(forKey: from); children[to] = original
            _ = try current(to)
        }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
            func budget() throws { if deadline.hasExpired { throw CustodyRecordError.busy } }
            try budget()
            if finished {
                // Idempotence belongs to this exact owner and observed one-shot
                // results, never a fresh number or a guessed already-closed FD.
                guard namespaceRetired, children.isEmpty, unresolvedChildren.isEmpty,
                      retiredListeners == listeners.count, retiredAncestors == chain.count,
                      (listeners + chain).allSatisfy({ $0.retirementObservation == .succeeded }) else {
                    throw CustodyRecordError.fenced
                }
                return
            }
            guard retirementCut != .beforeDescriptors, !rootCreationUnresolved,
                  unresolvedChildren.isEmpty else { throw CustodyRecordError.busy }
            if !namespaceRetired {
                if setupComplete { try verifyRoot() }
                else {
                    guard children.isEmpty else { throw CustodyRecordError.fenced }
                    if let identity = rootIdentity {
                        var named = stat()
                        try H.check(lstat(root, &named) == 0 && Self.sameNode(identity, named)
                            && named.st_mode == S_IFDIR | 0o700 && named.st_flags == 0,
                            "named socket partial setup parent remains original")
                    }
                }
                while retiredListeners < listeners.count {
                    try budget()
                    let original = listeners[retiredListeners]
                    guard original.retirementObservation == .notAttempted,
                          original.retireChecked() == .succeeded else { throw CustodyRecordError.busy }
                    retiredListeners += 1
                }
                // A deterministic failure after real close preserves that exact
                // progress. Re-entry never closes the consumed number again.
                guard retirementCut != .beforeChildUnlink else { throw CustodyRecordError.busy }
                for name in children.keys.sorted() {
                    try budget(); _ = try current(name)
                    try H.check(unlinkat(parent, name, 0) == 0, "named socket fixture exact child unlink")
                    var missing = stat()
                    try H.check(fstatat(parent, name, &missing, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT,
                                "named socket fixture child absent")
                    children.removeValue(forKey: name)
                }
                if setupComplete {
                    try budget()
                    try H.check(fsync(parent) == 0, "named socket fixture parent sync")
                    try verifyRoot()
                }
                namespaceRetired = true
            }
            // Leave endpoint parent and enclosing root alive. Only the existing
            // registered root custody removes its original tree after retirement.
            while retiredAncestors < chain.count {
                try budget()
                let original = chain[chain.count - 1 - retiredAncestors]
                guard original.retirementObservation == .notAttempted,
                      original.retireChecked() == .succeeded else { throw CustodyRecordError.busy }
                retiredAncestors += 1
            }
            try budget(); finished = true
        }
        func acquire(cut: SetupCut = .none) throws {
            // Owner already belongs to RuntimeFixtureSession's registered outer
            // root BEFORE directory, descriptor or socket acquisition.
            rootCreationUnresolved = true
            try H.check(mkdir(root, 0o700) == 0, "named socket fixture endpoint parent creation")
            var created = stat()
            try H.check(lstat(root, &created) == 0 && created.st_mode == S_IFDIR | 0o700
                && created.st_uid == geteuid() && created.st_flags == 0,
                "named socket fixture private creation")
            rootIdentity = created; rootCreationUnresolved = false
            let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            let first = open("/", flags)
            try H.check(first >= 0, "named socket fixture root descriptor")
            chain.append(OwnedFileDescriptor(first))
            if cut == .firstAncestor { throw CustodyRecordError.busy }
            for part in root.split(separator: "/") {
                let fd = openat(chain.last!.value, String(part), flags)
                try H.check(fd >= 0, "named socket fixture ancestry descriptor")
                chain.append(OwnedFileDescriptor(fd))
            }
            try verifyRoot(); setupComplete = true
            if cut == .socketDescriptor { try bind(cut: cut) }
        }
    }
    private static func enroll(root: String, location: StateLocation) throws -> Fixture {
        let custody = try RuntimeFixtureSession.installationRoot(root)
        let original = Fixture(outerRoot: root, parent: location.path)
        custody.retainNamedSocket(original)
        return original
    }
    private static func fixture(_ body: (Fixture) throws -> Void) throws {
        try H.fixture { root, location in
            let original = try enroll(root: root, location: location)
            try original.acquire()
            try body(original)
            // H.fixture invokes the registered typed owner on success OR throw.
            // Failed setup/finish stays in its original guardian-visible custody.
        }
    }
    static func noACL() throws {
        try fixture { f in
            for endpoint in O.Endpoint.allCases {
                try f.bind(endpoint)
                let observed = try f.read(endpoint)
                try H.check(observed.aclSHA256 == CustodyRecordBinding.digest(Data()),
                            "named socket supported absent ACL token")
                try H.check(observed.nodeIdentity.aclDigest == CustodyRecordBinding.digest(Data(observed.aclSHA256.utf8)),
                            "named socket preserved outer ACL digest")
                try H.check(try f.read(endpoint, expected: observed) == observed, "named socket unchanged actual identity")
            }
        }
    }
    static func emptyACL() throws {
        try fixture { f in
            try f.bind()
            let portable = try f.setACL(.installation, tag: nil)
            let observed = try f.read()
            // If this host collapses explicit empty to absent, refuse qualification
            // instead of changing the established digest representation silently.
            try H.check(observed.aclSHA256 == portable && portable != CustodyRecordBinding.digest(Data()),
                        "named socket explicit empty ACL differs from absence")
        }
    }
    static func denyACL() throws {
        try fixture { f in
            try f.bind()
            let portable = try f.setACL(.installation, tag: ACL_EXTENDED_DENY)
            try H.check(try f.read().aclSHA256 == portable, "named socket deny-only portable ACL")
        }
    }
    static func grantACL() throws {
        try fixture { f in
            try f.bind(); _ = try f.read()
            _ = try f.setACL(.installation, tag: ACL_EXTENDED_ALLOW)
            try H.refuses { _ = try f.read() }
        }
    }
    static func wrongTypes() throws {
        try fixture { f in
            try f.bind(); _ = try f.read()
            try f.renameChild("installation.sock", "target.sock")
            f.unresolvedChildren.insert("installation.sock")
            try H.check(symlinkat("target.sock", f.parent, "installation.sock") == 0, "named socket fixture symlink")
            try f.captureCreated("installation.sock", type: S_IFLNK)
            try H.refuses { _ = try f.read() }
        }
        try fixture { f in
            f.unresolvedChildren.insert("installation.sock")
            let fd = openat(f.parent, "installation.sock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try H.check(fd >= 0, "named socket fixture regular file")
            let owner = OwnedFileDescriptor(fd); f.listeners.append(owner)
            try f.captureCreated("installation.sock", type: S_IFREG)
            try H.refuses { _ = try f.read() }
        }
    }
    static func identityDrift() throws {
        try fixture { f in
            try f.bind(); let original = try f.read()
            try f.setMode("installation.sock", 0o640)
            let invocation = InstallationInvocationTesting.Context()
            var failure: InstallationInvocationTesting.Failure?
            try H.refuses {
                try InstallationInvocationTesting.withInvocation(invocation) {
                    do { _ = try f.read() }
                    catch { failure = invocation.failure(error); throw error }
                }
            }
            try H.check(failure?.phase == .socketMetadata && failure?.predicate == .socketMode
                && failure?.error == .unsafeMetadata && failure?.system == InstallationInvocationTesting.SystemResult.none,
                "named socket diagnostic missed the actual socket-mode refusal")
            try f.setMode("installation.sock", 0o600)
            let before = try f.read()
            try H.refuses {
                _ = try O.testingRead(address: f.address(), retainedAncestors: f.chain, uid: geteuid(),
                    deadline: .init(seconds: 0.75), expected: before) {
                    try f.renameChild("installation.sock", "original.sock")
                    try f.bind()
                }
            }
            try H.check(try f.read().metadata.inode != before.metadata.inode, "named socket replacement is distinct")
            try H.refuses { _ = try f.read(expected: original) }
        }
    }
    static func parentDrift() throws {
        try fixture { f in
            try f.bind(); let original = try f.read()
            // A wrong actual retained parent, even with a matching address, refuses.
            var wrong = f.chain; wrong[wrong.count - 1] = wrong[wrong.count - 2]
            try H.refuses {
                _ = try O.read(address: f.address(), retainedAncestors: wrong, uid: geteuid(),
                               deadline: .init(seconds: 0.75))
            }
            let name = f.rootName, moved = name + ".moved"
            var absent = stat()
            try H.check(fstatat(f.enclosing, moved, &absent, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT,
                        "named socket fixture parent move absence")
            try H.refuses {
                _ = try O.testingRead(address: f.address(), retainedAncestors: f.chain, uid: geteuid(),
                    deadline: .init(seconds: 0.75), expected: original) {
                    try f.verifyRoot()
                    try H.check(renameat(f.enclosing, name, f.enclosing, moved) == 0, "named socket fixture parent move")
                    f.rootName = moved; try f.verifyRoot()
                }
            }
            try f.verifyRoot()
            try H.check(fstatat(f.enclosing, name, &absent, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT,
                        "named socket fixture original parent name still absent")
            try H.check(renameat(f.enclosing, moved, f.enclosing, name) == 0, "named socket fixture restore original parent")
            f.rootName = name; try f.verifyRoot()
            // Restoration is fixture cleanup only; no restored product authority.
        }
    }
    static func addressAndDeadline() throws {
        for parent in ["relative", "/private/../tmp", "/private//tmp", "/private/tmp/", "/private/tmp/\0x",
                       "/private/tmp/" + String(repeating: "é", count: 60)] {
            try H.refuses { _ = try O.Address(canonicalParent: parent, endpoint: .installation) }
        }
        try fixture { f in
            try f.bind(); _ = try f.read()
            try H.refuses { _ = try f.read(deadline: .init(uptimeNanoseconds: 0)) }
            let deadline = MonotonicDeadline(seconds: 0.75)
            try H.refuses {
                _ = try O.testingRead(address: f.address(), retainedAncestors: f.chain, uid: geteuid(), deadline: deadline) {
                    // No fresh deadline after a real read. Expiration is deliberate
                    // fixture waiting, not a product timeout extension or retry.
                    while !deadline.hasExpired { Thread.sleep(forTimeInterval: 0.005) }
                }
            }
        }
    }
    static func custodyFailures() throws {
        for cut in [SetupCut.firstAncestor, .socketDescriptor, .none] {
            var original: Fixture?, custody: InstallationReadinessFixtureCustody?
            let deadline = MonotonicDeadline(seconds: 3)
            var failed = false
            do {
                try H.fixture { root, location in
                    custody = try RuntimeFixtureSession.installationRoot(root)
                    let f = try enroll(root: root, location: location); original = f
                    // Setup throws before return; outer finish ALSO refuses, so
                    // the original partial owner must remain registry-visible.
                    f.retirementCut = cut == .none ? .beforeChildUnlink : .beforeDescriptors
                    try f.acquire(cut: cut)
                    if cut == .none { try f.bind(); _ = try f.read() }
                }
            } catch CustodyRecordError.busy { failed = true }
            guard let f = original, let owner = custody else { throw CustodyRecordError.fenced }
            try H.check(failed && !f.finished && !f.namespaceRetired
                && (try RuntimeFixtureSession.installationRoot(f.outerRoot)) === owner,
                "named socket failed setup or finish remains in original registered custody")
            if cut == .none {
                try H.check(f.retiredListeners == 1 && f.listeners[0].retirementObservation == .succeeded
                    && !f.children.isEmpty && f.retiredAncestors == 0,
                    "named socket failed retirement retains original child and close result")
            } else {
                try H.check(!f.chain.isEmpty && f.retiredAncestors == 0
                    && (f.chain + f.listeners).allSatisfy({ $0.retirementObservation == .notAttempted }),
                    "named socket failed acquisition retains actual unclosed originals")
                if cut == .socketDescriptor {
                    try H.check(f.listeners.count == 1 && f.children.isEmpty,
                                "named socket socket-acquisition cut owns original descriptor")
                }
            }
            f.retirementCut = .none
            // Resume the SAME custody/owner under the SAME test cleanup deadline.
            // No uncertain close is injected or retried; no external adoption.
            try owner.finish(deadline: deadline)
            RuntimeFixtureSession.didFinishInstallationRoot(owner)
            try H.check(f.finished && f.children.isEmpty
                && (f.chain + f.listeners).allSatisfy({ $0.retirementObservation == .succeeded }),
                "named socket original failed owner actually retired")
            var absent = stat()
            try H.check(lstat(f.outerRoot, &absent) == -1 && errno == ENOENT,
                        "named socket registered failed root actually absent")
        }
    }

    static func strictReplyFailures() throws {
        try fixture { f in
            try f.bind(); let observation = try f.read()
            let deadline = MonotonicDeadline(seconds: 0.75)
            let reply = try O.testingStrictReply(parent: f.parent, endpoint: .installation, deadline: deadline)
            func decode(_ bytes: Data, result: Int32 = 0) throws -> String {
                try O.testingDecodeStrictReply(bytes, result: result, metadata: observation.metadata, deadline: deadline)
            }
            func replacing<T: FixedWidthInteger>(_ source: Data, _ offset: Int, _ value: T) -> Data {
                var copy = source, value = value
                withUnsafeBytes(of: &value) { copy.replaceSubrange(offset..<(offset + $0.count), with: $0) }
                return copy
            }
            try H.check(try decode(reply) == observation.aclSHA256, "named socket strict complete reply agrees")
            // Error-result injection checks the shared decoder's refusal, not
            // an actual filesystem's unsupported ACL behavior or errno.
            try H.refuses { _ = try decode(reply, result: -1) }
            try H.refuses { _ = try decode(Data(reply.prefix(79))) }
            for bad in [replacing(reply, 0, UInt32.max), replacing(reply, 60, Int32.min),
                        replacing(reply, 60, Int32.max), replacing(reply, 60, Int32(0)),
                        replacing(reply, 64, UInt32.max), replacing(reply, 68, observation.metadata.inode ^ 1),
                        replacing(reply, 76, UInt32(2))] {
                try H.refuses { _ = try decode(bad) }
            }
            // A complete real deny ACL supplies native layout for corruptions;
            // supported-null and explicit-empty are exercised by old cases.
            _ = try f.setACL(.installation, tag: ACL_EXTENDED_DENY)
            let deny = try f.read()
            let native = try O.testingStrictReply(parent: f.parent, endpoint: .installation, deadline: deadline)
            for bad in [replacing(native, 80, UInt32(0)), replacing(native, 116, UInt32.max),
                        replacing(native, 116, UInt32(129)), replacing(native, 120, UInt32.max),
                        replacing(native, 140, UInt32(1)), replacing(native, 140, UInt32(0x202)),
                        replacing(native, 144, UInt32.max), replacing(native, 64, UInt32(43))] {
                try H.refuses { _ = try O.testingDecodeStrictReply(bad, result: 0, metadata: deny.metadata, deadline: deadline) }
            }
        }
    }

    static func failureCleanup() throws {
        enum Expected: Error { case failure }
        var original: Fixture?
        do {
            try fixture { f in
                original = f
                try f.bind(); _ = try f.read()
                throw Expected.failure
            }
            throw H.Failure(message: "named socket fixture swallowed assertion failure")
        } catch Expected.failure { }
        guard let original else { throw CustodyRecordError.fenced }
        try H.check(original.finished && original.children.isEmpty
            && original.listeners.allSatisfy({ $0.retirementObservation == .succeeded })
            && original.chain.allSatisfy({ $0.retirementObservation == .succeeded }),
            "named socket actual original failure cleanup")
        var absent = stat()
        try H.check(lstat(original.outerRoot, &absent) == -1 && errno == ENOENT, "named socket cleaned root absent")
    }
}
#endif
