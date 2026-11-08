#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Fixture-only parents. No source bundle, host installation, account home,
/// process launch, repository or command graph is used by these cases.
enum InstallationParentPreparationFixtures {
    typealias P = InstallationParentPreparation
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch is Failure { throw Failure(message: "fixture setup failed") }
        catch { return }
        throw Failure(message: "fixed parent operation unexpectedly accepted")
    }
    static let paths: [P.Parent: String] = [.local: ".local", .state: ".local/state",
        .applications: "Applications", .library: "Library", .launchAgents: "Library/LaunchAgents"]
    struct Snapshot: Equatable {
        let identity: FileIdentity
        let bytes: Data?
        let link: String?
        let flags: UInt32
        let acl: Data?
    }
    static func rawACL(_ path: String) throws -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try check(fd >= 0, "fixture ACL snapshot descriptor"); defer { close(fd) }
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            try check(errno == ENOENT, "fixture ACL snapshot unavailable"); return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let size = acl_size(acl); try check(size >= 0 && size <= 65_536, "fixture ACL snapshot size")
        var data = Data(count: size)
        let copied = data.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, size) }
        try check(copied == size, "fixture ACL snapshot copy"); return data
    }
    static func snapshot(_ root: String) throws -> [String: Snapshot] {
        var result: [String: Snapshot] = [:]
        func visit(_ path: String) throws {
            var s = stat(); try check(lstat(path, &s) == 0, "fixture snapshot")
            let kind = s.st_mode & S_IFMT
            let bytes = kind == S_IFREG ? try Data(contentsOf: URL(fileURLWithPath: path)) : nil
            let link = kind == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
            result[path] = Snapshot(identity: FileIdentity(s), bytes: bytes, link: link,
                                    flags: s.st_flags, acl: kind == S_IFLNK ? nil : try rawACL(path))
            if kind == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() { try visit(path + "/" + name) }
            }
        }
        try visit(root); return result
    }
    static func fixture(_ body: (String, String) throws -> Void) throws {
        var pattern = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-fresh-state.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&pattern) else { throw Failure(message: "fixture root") }
        let root = String(cString: raw)
        var initial = stat(); try check(lstat(root, &initial) == 0, "fixture root identity")
        let home = root + "/home"; try check(mkdir(home, 0o700) == 0, "fixture home")
        // No failure-path deletion. An unexpected test failure retains its root
        // and all evidence for the owning runtime guardian to report.
        try body(root, home)
        let tree = try snapshot(root)
        var now = stat()
        try check(lstat(root, &now) == 0 && FileIdentity(now).matchesStableNode(FileIdentity(initial)), "cleanup root replaced")
        for path in tree.keys.sorted(by: { $0.count > $1.count }) {
            guard let node = tree[path] else { throw Failure(message: "cleanup evidence") }
            try check(lstat(path, &now) == 0 && FileIdentity(now).matchesStableNode(node.identity), "cleanup node replaced")
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(fd >= 0, "cleanup parent")
            defer { close(fd) }
            var parentNode = stat()
            try check(fstat(fd, &parentNode) == 0, "cleanup parent identity")
            if let expected = tree[parent] {
                try check(FileIdentity(parentNode).matchesStableNode(expected.identity), "cleanup parent replaced")
            } else { try check(path == root, "cleanup escaped fixture") }
            try check(unlinkat(fd, URL(fileURLWithPath: path).lastPathComponent,
                               node.identity.isDirectory ? AT_REMOVEDIR : 0) == 0, "cleanup removal")
        }
    }
    static func make(_ home: String, _ parent: P.Parent, mode: mode_t = 0o700) throws {
        guard let relative = paths[parent] else { throw Failure(message: "fixture fixed path") }
        if parent == .state && !FileManager.default.fileExists(atPath: home + "/.local") { try make(home, .local) }
        if parent == .launchAgents && !FileManager.default.fileExists(atPath: home + "/Library") { try make(home, .library) }
        try check(mkdir(home + "/" + relative, mode) == 0, "fixture fixed parent")
    }
    static func absent() throws {
        try fixture { root, home in
            let before = try snapshot(root), preparation = try P.testing(root: root)
            try check(try snapshot(root) == before, "factory mutated parents")
            try refuses { try preparation.revalidate() }
            try preparation.prepare(); try preparation.revalidate()
            let evidence = preparation.evidence()
            try check(evidence.count == 5 && evidence.allSatisfy { $0.progress == .observedParentSynced && $0.identity != nil }, "retained observations did not finish sync")
            let after = try snapshot(root)
            try check(after.count == 7, "preparation created payload or controls")
            try check(!FileManager.default.fileExists(atPath: home + "/.local/state/shadow-sync"), "preparation created state")
            try preparation.prepare(); try check(try snapshot(root) == after, "idempotent retry changed nodes")
        }
    }
    static func present() throws {
        try fixture { root, home in
            for parent in P.Parent.allCases { try make(home, parent) }
            // Existing general-purpose parents may contain unrelated user data;
            // preparation does not interpret, repair, claim or remove it.
            try Data("fixture unrelated data".utf8).write(to: URL(fileURLWithPath: home + "/Applications/fixture.txt"))
            let before = try snapshot(root), p = try P.testing(root: root)
            try p.prepare(); try p.revalidate()
            try check(try snapshot(root) == before && p.evidence().allSatisfy { $0.progress == .observedExisting }, "existing parent changed or attributed")
        }
    }
    static func partial() throws {
        for selected in 0..<32 {
            try fixture { root, home in
                for (index, parent) in P.Parent.allCases.enumerated() where selected & (1 << index) != 0 {
                    if !FileManager.default.fileExists(atPath: home + "/" + paths[parent]!) { try make(home, parent) }
                }
                let before = try snapshot(root), p = try P.testing(root: root)
                let existing = Set(p.evidence().filter { $0.progress == .observedExisting }.map(\.parent))
                try p.prepare(); try p.revalidate()
                let after = try snapshot(root)
                for (path, node) in before { try check(after[path]?.identity.matchesStableNode(node.identity) == true, "partial parent replaced") }
                for e in p.evidence() { try check(e.progress == (existing.contains(e.parent) ? .observedExisting : .observedParentSynced), "partial observation progress") }
            }
        }
    }
    static func unsafe() throws {
        for mode: mode_t in [0o777, 0o775, 0o1700, 0o4700] {
            try fixture { root, home in
                try make(home, .applications); try check(chmod(home + "/Applications", mode) == 0, "fixture unsafe mode")
                let before = try snapshot(root)
                try refuses { _ = try P.testing(root: root) }
                try check(try snapshot(root) == before, "unsafe mode repaired")
            }
        }
        try fixture { root, home in
            try make(home, .local); try make(home, .state, mode: 0o755)
            let before = try snapshot(root); try refuses { _ = try P.testing(root: root) }
            try check(try snapshot(root) == before, "state parent privacy repaired")
        }
        try fixture { root, home in
            try Data("fixture file".utf8).write(to: URL(fileURLWithPath: home + "/Library"))
            let before = try snapshot(root); try refuses { _ = try P.testing(root: root) }
            try check(try snapshot(root) == before, "wrong type changed")
        }
    }
    static func links() throws {
        for parent in P.Parent.allCases {
            try fixture { root, home in
                if parent == .state { try make(home, .local) }
                if parent == .launchAgents { try make(home, .library) }
                let target = root + "/target"; try check(mkdir(target, 0o700) == 0, "fixture target")
                try check(symlink(target, home + "/" + paths[parent]!) == 0, "fixture link")
                let before = try snapshot(root); try refuses { _ = try P.testing(root: root) }
                try check(try snapshot(root) == before, "link target changed")
            }
        }
    }
    static func ancestors() throws {
        try fixture { root, home in
            let p = try P.testing(root: root)
            try check(chmod(home, 0o777) == 0, "fixture home mode")
            let before = try snapshot(root); try refuses { try p.prepare() }
            try check(try snapshot(root) == before, "unsafe ancestor changed")
        }
        try fixture { root, home in
            let p = try P.testing(root: root)
            try check(rename(home, root + "/old-home") == 0 && symlink(root + "/old-home", home) == 0, "fixture home link")
            let before = try snapshot(root); try refuses { try p.prepare() }
            try check(try snapshot(root) == before, "intermediate link changed")
        }
    }
    static func acl() throws {
        try fixture { root, home in
            try make(home, .state)
            try InstallationOwnershipFixtures.withACLGrant(home + "/.local/state") {
                let before = try snapshot(root); try refuses { _ = try P.testing(root: root) }
                try check(try snapshot(root) == before, "unsafe ACL changed")
            }
        }
    }
    static func wrongOwner() throws {
        try fixture { root, _ in
            let before = try snapshot(root); try refuses { try P.testingWrongOwner(root: root) }
            try check(try snapshot(root) == before, "wrong-owner check changed data")
        }
    }
    static func substitution() throws {
        try fixture { root, home in
            try make(home, .applications)
            let p = try P.testing(root: root)
            try check(rename(home + "/Applications", home + "/old-applications") == 0, "fixture rename")
            try make(home, .applications)
            let before = try snapshot(root); try refuses { try p.prepare() }
            try check(try snapshot(root) == before, "substitution accepted")
        }
    }
    static func concurrent() throws {
        try fixture { root, _ in
            let first = try P.testing(root: root), second = try P.testing(root: root)
            try first.prepare(); let before = try snapshot(root)
            try refuses { try second.prepare() }; try check(try snapshot(root) == before, "concurrent absent snapshot adopted")
            try check(second.evidence().allSatisfy { $0.progress == .absent }, "concurrent creation attributed")
            let later = try P.testing(root: root); try later.prepare()
            try check(later.evidence().allSatisfy { $0.progress == .observedExisting }, "fresh invocation claimed ownership")
        }
    }
    static func creationRace() throws {
        // mkdirat cannot prove which inode is first observed afterward. A safe
        // replacement is independently pinned, with explicitly noncausal
        // progress; no created/owned/durable-origin result exists in this API.
        for unsafe in [false, true] {
            try fixture { root, home in
                let p = try P.testing(root: root)
                defer { p.testingMutation(nil) }
                var original: FileIdentity?, observed: FileIdentity?
                p.testingMutation { stage in
                    if stage == .beforeFirstObservation(.local) {
                        var node = stat()
                        try check(lstat(home + "/.local", &node) == 0, "first observation original stat")
                        original = FileIdentity(node)
                        try check(rename(home + "/.local", root + "/displaced-local") == 0, "first observation move")
                        try make(home, .local)
                        if unsafe { try check(chmod(home + "/.local", 0o777) == 0, "first observation unsafe mode") }
                        try check(lstat(home + "/.local", &node) == 0, "first observation replacement stat")
                        observed = FileIdentity(node)
                    }
                }
                if unsafe {
                    try refuses { try p.prepare() }
                    try check(p.evidence().first?.progress == .indeterminate && p.evidence().first?.identity == nil,
                        "unsafe first observation retained")
                    try check(!FileManager.default.fileExists(atPath: home + "/.local/state"),
                        "unsafe first observation received nested effects")
                } else {
                    try p.prepare(); try p.revalidate()
                    guard let old = original, let now = observed, let evidence = p.evidence().first,
                          let identity = evidence.identity else { throw Failure(message: "missing first observation evidence") }
                    try check(old.inode != now.inode && identity.inode == UInt64(now.inode)
                        && evidence.progress == .observedParentSynced, "first observation claimed mkdir-origin inode")
                    var displaced = stat()
                    try check(lstat(root + "/displaced-local", &displaced) == 0
                        && FileIdentity(displaced).matchesStableNode(old), "displaced original changed")
                    try check(try FileManager.default.contentsOfDirectory(atPath: root + "/displaced-local").isEmpty,
                        "displaced original received nested effects")
                }
            }
        }
        try fixture { root, home in
            let p = try P.testing(root: root)
            defer { p.testingMutation(nil) }
            p.testingMutation { stage in if stage == .beforeMkdir(.local) { try make(home, .local) } }
            try refuses { try p.prepare() }; p.testingMutation(nil)
            let before = try snapshot(root)
            try refuses { try p.prepare() }
            try check(try snapshot(root) == before && p.evidence().allSatisfy { $0.identity == nil }, "EEXIST adopted concurrent creation")
        }
        try fixture { root, home in
            let p = try P.testing(root: root)
            defer { p.testingMutation(nil) }
            p.testingMutation { stage in
                if stage == .afterMkdir(.local) {
                    try check(rename(home + "/.local", home + "/original-local") == 0, "fixture postmkdir rename")
                    try make(home, .local)
                }
            }
            try refuses { try p.prepare() }; p.testingMutation(nil)
            let before = try snapshot(root); try refuses { try p.prepare() }
            try check(try snapshot(root) == before && p.evidence().first?.progress == .indeterminate,
                      "mkdir-to-open substitution attributed or changed")
        }
    }
    static func indeterminate() throws {
        for parent in P.Parent.allCases {
            try fixture { root, _ in
                let p = try P.testing(root: root); p.testingCut(.afterMkdir(parent))
                try refuses { try p.prepare() }
                let entry = p.evidence().first { $0.parent == parent }!
                try check(entry.progress == .indeterminate && entry.identity == nil, "lost postimage claimed ownership")
                let before = try snapshot(root); try refuses { try p.prepare() }
                try check(try snapshot(root) == before, "indeterminate retry adopted or deleted node")
                let next = try P.testing(root: root); try next.prepare(); try next.revalidate()
                try check(next.evidence().first { $0.parent == parent }?.progress == .observedExisting, "fresh invocation claimed ambiguous creation")
            }
        }
    }
    static func cuts() throws {
        for parent in P.Parent.allCases {
            for cut in [P.Cut.beforeCreate(parent), .afterCreate(parent), .afterChildSync(parent), .afterParentSync(parent)] {
                try fixture { root, _ in
                    let p = try P.testing(root: root); p.testingCut(cut)
                    try refuses { try p.prepare() }
                    let before = try snapshot(root), evidence = p.evidence()
                    try p.prepare(); try p.revalidate(); let after = try snapshot(root)
                    for (path, node) in before { try check(after[path]?.identity.matchesStableNode(node.identity) == true, "cut replaced original") }
                    for e in evidence where e.identity != nil {
                        try check(p.evidence().first { $0.parent == e.parent }?.identity == e.identity, "cut lost retained postimage")
                    }
                    try check(p.evidence().allSatisfy { $0.progress == .observedParentSynced }, "cut retry incomplete")
                }
            }
        }
    }
    static func syncFailure() throws {
        for parent in P.Parent.allCases {
            for stage in [P.Cut.afterChildSync(parent), .afterParentSync(parent)] {
                try fixture { root, _ in
                    let p = try P.testing(root: root); p.testingSyncFailure(stage)
                    try refuses { try p.prepare() }
                    let e = p.evidence().first { $0.parent == parent }!
                    try check(e.identity != nil && e.progress == (stage == .afterChildSync(parent) ? .observedAfterMkdir : .observedNodeSynced), "failed fsync reported a completed observation")
                    let before = try snapshot(root); p.testingSyncFailure(nil); try p.prepare(); try p.revalidate()
                    let after = try snapshot(root)
                    for (path, node) in before { try check(after[path]?.identity.matchesStableNode(node.identity) == true, "sync retry replaced node") }
                }
            }
        }
    }
    static func cutSubstitution() throws {
        try fixture { root, home in
            let p = try P.testing(root: root); p.testingCut(.afterCreate(.local))
            try refuses { try p.prepare() }
            try check(rename(home + "/.local", home + "/old-local") == 0, "fixture cut rename")
            try make(home, .local); let before = try snapshot(root)
            try refuses { try p.prepare() }; try check(try snapshot(root) == before, "cut retry adopted replacement")
        }
    }
    static func unknownData() throws {
        try fixture { root, home in
            let p = try P.testing(root: root); p.testingCut(.afterCreate(.local))
            try refuses { try p.prepare() }
            try Data("unrecognized fixture evidence".utf8).write(to: URL(fileURLWithPath: home + "/.local/unknown"))
            let before = try snapshot(root); try refuses { try p.prepare() }
            try check(try snapshot(root) == before, "unknown data removed or accepted during continuation")
        }
    }
    static func publisherBoundary() throws {
        try fixture { root, _ in
            let p = try P.testing(root: root); p.testingRejectPublisher()
            let before = try snapshot(root); try refuses { try p.prepare() }
            try check(try snapshot(root) == before, "publisher refusal mutated parents")
        }
        try fixture { root, _ in
            let p = try P.testing(root: root)
            defer { p.testingMutation(nil) }
            p.testingMutation { stage in if stage == .afterCreate(.local) { p.testingRejectPublisher() } }
            try refuses { try p.prepare() }; let before = try snapshot(root)
            try refuses { try p.prepare() }; try check(try snapshot(root) == before, "publisher cut changed parents")
            p.testingMutation(nil)
        }
    }
    static func productionRefusal() throws {
        // Production's testing branch throws before EffectiveAccount.current,
        // publisher lookup or home access. No host snapshot is needed or allowed.
        try refuses { _ = try P.production() }
    }
    static func successor() throws {
        try fixture { root, _ in
            var p: P? = try P.testing(root: root); p!.testingCut(.afterCreate(.local))
            try refuses { try p!.prepare() }
            let first = p!.evidence().first { $0.parent == .local }!
            p = nil
            let next = try P.testing(root: root)
            try check(next.evidence().first { $0.parent == .local }?.progress == .observedExisting, "successor attributed previous creation")
            try next.prepare(); try next.revalidate()
            try check(next.evidence().first { $0.parent == .local }?.identity == first.identity, "successor changed pre-existing inode")
        }
    }
}
#endif
