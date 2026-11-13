import Darwin
import Foundation

enum PublisherPolicyError: Error, CustomStringConvertible {
    case unavailable
    var description: String { "Signed repository policy resources are unavailable." }
}

/// Pure decoding. Only a separately verified framework resource seal makes
/// this inventory authoritative. No pathname from it is used before validation.
struct PolicyRuntimeLayout: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        enum Kind: String, Sendable { case directory, file, symlink }
        let kind: Kind
        let mode: UInt16
        let target: String?
    }
    let entries: [String: Entry]
    static let interpreter = "Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
    static let manifest = "Versions/3.14/Resources/ShadowSyncRuntimeLayout.json"
    static let links: [String: String] = [
        "Python": "Versions/Current/Python",
        "Resources": "Versions/Current/Resources",
        "Versions/Current": "3.14",
        "Versions/3.14/lib/libcrypto.dylib": "libcrypto.3.dylib",
        "Versions/3.14/lib/libcurses.dylib": "libncurses.6.dylib",
        "Versions/3.14/lib/libform.dylib": "libform.6.dylib",
        "Versions/3.14/lib/libmenu.dylib": "libmenu.6.dylib",
        "Versions/3.14/lib/libncurses.dylib": "libncurses.6.dylib",
        "Versions/3.14/lib/libpanel.dylib": "libpanel.6.dylib",
        "Versions/3.14/lib/libpython3.14.dylib": "../Python",
        "Versions/3.14/lib/libssl.dylib": "libssl.3.dylib",
        "Versions/3.14/lib/libzstd.1.dylib": "libzstd.1.5.7.dylib",
        "Versions/3.14/lib/libzstd.dylib": "libzstd.1.5.7.dylib",
    ]

    static func decode(_ bytes: Data, source: Data) throws -> Self {
        do {
            var sourceParser = try PolicyWireParser(source, profile: .configuration)
            let sourceValue = try sourceParser.parse()
            let pin = try sourceValue.object(keys: ["schema", "architecture", "framework_version", "version",
                "package_url", "package_bytes", "package_sha256", "package_license_sha256",
                "notices_manifest_sha256", "selection_recipe", "upstream_team"])
            guard pin["schema"] == .string("shadow-sync-policy-runtime-source/v1"),
                  pin["architecture"] == .string("arm64"), pin["framework_version"] == .string("3.14"),
                  pin["version"] == .string("3.14.10"),
                  pin["selection_recipe"] == .string("stdlib-source-checked-bytecode-zip/v1"),
                  pin["package_url"] == .string("https://www.python.org/ftp/python/3.14.10/python-3.14.10-macos11.pkg"),
                  pin["package_bytes"] == .unsigned(76018440),
                  pin["upstream_team"] == .string("BMM5U3QVKW") else { throw PublisherPolicyError.unavailable }
            for key in ["package_sha256", "package_license_sha256", "notices_manifest_sha256"] {
                guard case let .string(value) = pin[key], value.utf8.count == 64,
                      value != String(repeating: "0", count: 64),
                      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw PublisherPolicyError.unavailable
                }
            }
            var parser = try PolicyWireParser(bytes, profile: .bundleLayout)
            let root = try parser.parse().object(keys: ["schema", "source", "entries"])
            guard root["schema"] == .string("shadow-sync-policy-runtime-layout/v1"),
                  root["source"] == sourceValue,
                  case let .object(rows) = root["entries"], (1...4096).contains(rows.count) else {
                throw PublisherPolicyError.unavailable
            }
            var entries: [String: Entry] = [:]
            for (path, raw) in rows {
                guard validPath(path), case let .object(row) = raw,
                      case let .string(kindText) = row["kind"], let kind = Entry.Kind(rawValue: kindText),
                      case let .unsigned(mode) = row["mode"],
                      Set(row.keys) == (kind == .symlink ? ["kind", "mode", "target"] : ["kind", "mode"]),
                      kind == .file ? [420, 493].contains(mode) : mode == 493 else {
                    throw PublisherPolicyError.unavailable
                }
                if path.hasPrefix("Versions/3.14/lib/python3.14/"),
                   path.hasSuffix(".py") || path.hasSuffix(".pyc") {
                    throw PublisherPolicyError.unavailable
                }
                var target: String?
                if kind == .symlink {
                    guard case let .string(value) = row["target"], links[path] == value else {
                        throw PublisherPolicyError.unavailable
                    }
                    target = value
                }
                entries[path] = Entry(kind: kind, mode: UInt16(mode), target: target)
            }
            for path in entries.keys {
                let parts = path.split(separator: "/")
                for count in 1..<parts.count {
                    guard entries[parts.prefix(count).joined(separator: "/")]?.kind == .directory else {
                        throw PublisherPolicyError.unavailable
                    }
                }
            }
            guard entries.filter({ $0.value.kind == .symlink }).mapValues(\.target) == links.mapValues(Optional.some),
                  entries[interpreter] == Entry(kind: .file, mode: 493, target: nil),
                  entries[manifest] == Entry(kind: .file, mode: 420, target: nil),
                  entries["Versions/3.14/lib/python314.zip"] == Entry(kind: .file, mode: 420, target: nil),
                  entries["Versions/3.14/Resources/ShadowSyncStdlibArchive.json"] == Entry(kind: .file, mode: 420, target: nil),
                  entries["Versions/3.14/Python"]?.kind == .file else { throw PublisherPolicyError.unavailable }
            return Self(entries: entries)
        } catch { throw PublisherPolicyError.unavailable }
    }

    static func validPath(_ path: String) -> Bool {
        let bytes = path.utf8
        guard !bytes.isEmpty, bytes.count <= 1024 else { return false }
        var depth = 1, length = 0, dotsOnly = true
        for byte in bytes {
            guard byte >= 32, byte <= 126, byte != 92 else { return false }
            if byte == 47 {
                guard length > 0, !(dotsOnly && length <= 2), depth < 32 else { return false }
                depth += 1; length = 0; dotsOnly = true
            } else {
                length += 1
                if byte != 46 { dotsOnly = false }
            }
        }
        return length > 0 && !(dotsOnly && length <= 2)
    }
}

/// A no-follow identity inventory used around initial signature validation and
/// around every helper invocation. Mode/ACL/ctime/inode changes revoke the lease.
/// Regular-file bytes are authenticated by Security's resource/code seals, not
/// by treating mutable filesystem metadata as a substitute for a signature.
struct PolicyRuntimeTree: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        let device: Int32, inode: UInt64, owner: UInt32, group: UInt32
        let mode: UInt16, links: UInt16, flags: UInt32, size: Int64
        let mtime: Int, mtimeNS: Int, ctime: Int, ctimeNS: Int
        let acl: String, target: String?
        init(_ s: stat, acl: String, target: String? = nil) {
            device = s.st_dev; inode = s.st_ino; owner = s.st_uid; group = s.st_gid
            mode = s.st_mode; links = s.st_nlink; flags = s.st_flags; size = s.st_size
            mtime = s.st_mtimespec.tv_sec; mtimeNS = s.st_mtimespec.tv_nsec
            ctime = s.st_ctimespec.tv_sec; ctimeNS = s.st_ctimespec.tv_nsec
            self.acl = acl; self.target = target
        }
        // An ancestor may gain or lose unrelated children. Its identity,
        // access policy and flags must stay fixed; child-count/timestamps/size
        // belong to the sealed framework inventory, not its parent directories.
        func matchesAncestorIdentityAndAccess(_ other: Self) -> Bool {
            device == other.device && inode == other.inode && owner == other.owner
                && group == other.group && mode == other.mode && flags == other.flags && acl == other.acl
        }
    }
    private struct InspectionObserver {
        #if SHADOW_SYNC_TESTING
        var afterAncestorRead: ((String) throws -> Void)? = nil
        var beforeDirectoryRead: ((String) throws -> Void)? = nil
        var afterEntryRead: ((String, String, Bool) throws -> Void)? = nil
        var substituteEntry: ((String, String, stat?, Bool) throws -> (String, stat?))? = nil
        #endif
    }
    let nodes: [String: Node]
    let machOFiles: [String]
    // Immutable lookup data only. It never contains a fresh observation or a
    // permission to access a candidate. Initial capture has already checked
    // every full path and layout entry; repeated scans need only match each
    // freshly enumerated name to that exact authenticated entry.
    private struct InspectionEntry: Equatable, Sendable {
        let path: String
        let ordinal: Int
        let layout: PolicyRuntimeLayout.Entry
        let node: Node
    }
    private let capturedLayout: PolicyRuntimeLayout
    private let children: [String: [String: InspectionEntry]]

    private init(nodes: [String: Node], machOFiles: [String], layout: PolicyRuntimeLayout) throws {
        var children: [String: [String: InspectionEntry]] = [:]
        // Stable ordering makes each directory-local ordinal independent of
        // Dictionary insertion order, including independent full captures.
        for (path, entry) in layout.entries.sorted(by: { $0.key < $1.key }) {
            guard PolicyRuntimeLayout.validPath(path), let node = nodes[path] else {
                throw PublisherPolicyError.unavailable
            }
            let slash = path.lastIndex(of: "/")
            let parent = slash.map { String(path[..<$0]) } ?? ""
            let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
            let ordinal = children[parent]?.count ?? 0
            children[parent, default: [:]][name] = InspectionEntry(path: path, ordinal: ordinal, layout: entry, node: node)
        }
        self.nodes = nodes; self.machOFiles = machOFiles
        self.capturedLayout = layout; self.children = children
    }

    static func capture(root: String, owner: uid_t, layout: PolicyRuntimeLayout) throws -> Self {
        try inspect(root: root, owner: owner, layout: layout, expected: nil)
    }

    func revalidate(root: String, owner: uid_t, layout: PolicyRuntimeLayout) throws {
        guard try Self.inspect(root: root, owner: owner, layout: layout, expected: self) == self else {
            throw PublisherPolicyError.unavailable
        }
    }

    #if SHADOW_SYNC_TESTING
    func testingRevalidate(root: String, owner: uid_t, layout: PolicyRuntimeLayout,
                           afterAncestorRead: @escaping (String) throws -> Void) throws {
        guard try Self.inspect(root: root, owner: owner, layout: layout, expected: self,
            observer: InspectionObserver(afterAncestorRead: afterAncestorRead)) == self else {
            throw PublisherPolicyError.unavailable
        }
    }
    /// Observe the actual production enumeration route. Hooks run only after
    /// the directory's initial identity check. The optional substitution is
    /// testing-only fault injection for malformed enumeration records.
    // Keep this testing-only entry visible to compiled symbol verification.
    @inline(never)
    func testingRevalidateScan(root: String, owner: uid_t, layout: PolicyRuntimeLayout,
                               beforeDirectoryRead: ((String) throws -> Void)? = nil,
                               afterEntryRead: ((String, String, Bool) throws -> Void)? = nil,
                               substituteEntry: ((String, String, stat?, Bool) throws -> (String, stat?))? = nil) throws {
        guard try Self.inspect(root: root, owner: owner, layout: layout, expected: self,
            observer: InspectionObserver(beforeDirectoryRead: beforeDirectoryRead,
                                         afterEntryRead: afterEntryRead, substituteEntry: substituteEntry)) == self else {
            throw PublisherPolicyError.unavailable
        }
    }
    #endif

    private static func inspect(root: String, owner: uid_t, layout: PolicyRuntimeLayout, expected: Self?,
                                observer: InspectionObserver = InspectionObserver()) throws -> Self {
        // A caller cannot pair retained nodes with a different layout. Normal
        // calls share the immutable Dictionary storage; no filesystem result is
        // cached, and every directory/name/node below is still freshly observed.
        if let expected, expected.capturedLayout != layout { throw PublisherPolicyError.unavailable }
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let components = root.utf8.split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard root.utf8.count <= 4096, components.first == "", (2...65).contains(components.count),
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !root.utf8.contains(92), !root.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw PublisherPolicyError.unavailable
        }
        var descriptors: [Int32] = [], parents: [Node] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        func addParent(_ fd: Int32) throws {
            guard fd >= 0 else { throw PublisherPolicyError.unavailable }
            descriptors.append(fd)
            let observed = try PolicyAuthorityFile.safeACLObservation(fd)
            let s = observed.info
            guard s.st_mode & S_IFMT == S_IFDIR,
                  s.st_uid == 0 || s.st_uid == owner,
                  s.st_mode & 0o022 == 0 || (s.st_uid == 0 && s.st_mode & S_ISVTX != 0) else {
                throw PublisherPolicyError.unavailable
            }
            parents.append(Node(s, acl: observed.acl))
        }
        try addParent(Darwin.open("/", flags | O_DIRECTORY))
        for name in components.dropFirst() { try addParent(openat(descriptors.last!, name, flags | O_DIRECTORY)) }
        guard parents.last!.owner == owner, parents.last!.mode & 0o7777 == 0o755 else {
            throw PublisherPolicyError.unavailable
        }
        if let expected {
            guard expected.nodes[""] == parents.last! else { throw PublisherPolicyError.unavailable }
        }
        // Initial capture builds the authenticated inventory. Revalidation
        // compares every fresh node directly against that immutable inventory;
        // rebuilding its dictionary would duplicate the same proof and values.
        var nodes: [String: Node] = expected == nil ? ["": parents.last!] : [:]
        var observedCount = 1
        var machO: [String] = []
        // Invocation-local scratch. Active parent batches remain checked out
        // while children run; only completed/unwinding siblings share storage.
        var bulkReaders = PolicyRuntimeBulkDirectory.Pool()
        func scan(_ fd: Int32, prefix: String) throws {
            let expectedChildren = expected?.children[prefix] ?? [:]
            // Bulk attributes amortize many regular-file observations. Tiny
            // directories instead enumerate names and query each named node;
            // they need no bulk record buffer/decoder. This changes only the
            // observation mechanism: even an expected empty directory is read
            // to EOF and every fresh name must match the captured inventory.
            let useBulk = expected != nil && expectedChildren.count > 8
            #if SHADOW_SYNC_TESTING
            try observer.beforeDirectoryRead?(prefix)
            #endif
            let stream: UnsafeMutablePointer<DIR>?
            if useBulk { stream = nil }
            else {
                let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 10)
                guard duplicate >= 0 else { throw PublisherPolicyError.unavailable }
                guard let opened = fdopendir(duplicate) else {
                    close(duplicate); throw PublisherPolicyError.unavailable
                }
                stream = opened
            }
            defer { if let stream { closedir(stream) } }
            var bulk: PolicyRuntimeBulkDirectory? = useBulk ? bulkReaders.take() : nil
            defer { if useBulk { bulkReaders.put(&bulk) } }
            var seen: Set<String> = []
            // Fresh visitation state belongs to this recursive directory frame;
            // immutable ordinals replace a second hash of each observed name.
            var visited = [Bool](repeating: false, count: expectedChildren.count)
            while true {
                var name: String
                var batched: stat?
                if let stream {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        guard errno == 0 else { throw PublisherPolicyError.unavailable }; break
                    }
                    let length = Int(entry.pointee.d_namlen)
                    guard (1...255).contains(length) else { throw PublisherPolicyError.unavailable }
                    name = withUnsafePointer(to: entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    // Bulk decode enforces this same exact ASCII leaf grammar.
                    // Do not let Unicode equivalence or replacement decoding
                    // turn an unexpected readdir name into an indexed name.
                    guard name.utf8.count == length, PolicyRuntimeLayout.validPath(name),
                          !name.utf8.contains(47) else { throw PublisherPolicyError.unavailable }
                } else {
                    // The caller opened this descriptor for this traversal;
                    // getattrlistbulk advances it but does not take ownership.
                    // A duplicate would share the same open-file offset anyway.
                    guard let entry = try bulk!.next(fd: fd) else { break }
                    name = entry.name; batched = entry.regularFile
                }
                #if SHADOW_SYNC_TESTING
                if let substitute = observer.substituteEntry {
                    (name, batched) = try substitute(prefix, name, batched, useBulk)
                }
                try observer.afterEntryRead?(prefix, name, useBulk)
                #endif
                let path: String, entryLayout: PolicyRuntimeLayout.Entry, retained: Node?
                if expected != nil {
                    guard observedCount <= 4096, let entry = expectedChildren[name], !visited[entry.ordinal] else {
                        throw PublisherPolicyError.unavailable
                    }
                    visited[entry.ordinal] = true
                    path = entry.path; entryLayout = entry.layout; retained = entry.node
                } else {
                    guard seen.insert(name).inserted, observedCount <= 4096 else { throw PublisherPolicyError.unavailable }
                    path = prefix.isEmpty ? name : prefix + "/" + name
                    guard PolicyRuntimeLayout.validPath(path), let entry = layout.entries[path] else {
                        throw PublisherPolicyError.unavailable
                    }
                    entryLayout = entry; retained = nil
                }
                observedCount += 1
                var before = stat()
                if let batched { before = batched }
                else { guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw PublisherPolicyError.unavailable } }
                guard before.st_uid == owner, before.st_mode & 0o7777 == entryLayout.mode else {
                    throw PublisherPolicyError.unavailable
                }
                let expectedType = entryLayout.kind == .directory ? S_IFDIR : entryLayout.kind == .file ? S_IFREG : S_IFLNK
                guard before.st_mode & S_IFMT == expectedType else { throw PublisherPolicyError.unavailable }
                if expected != nil {
                    guard let retained, Node(before, acl: retained.acl, target: retained.target) == retained else {
                        throw PublisherPolicyError.unavailable
                    }
                }
                // A changed ACL or file content updates ctime. After initial
                // no-follow seal/ACL verification, unchanged inode+ctime+mode
                // permits metadata-only revalidation without reopening each
                // stdlib file. Directory traversal still uses O_NOFOLLOW.
                if entryLayout.kind == .file, retained != nil {
                    continue
                }
                if entryLayout.kind == .symlink {
                    var bytes = [UInt8](repeating: 0, count: 1025)
                    let count = readlinkat(fd, name, &bytes, bytes.count)
                    guard count > 0, count < bytes.count,
                          let target = String(bytes: bytes.prefix(count), encoding: .utf8), target == entryLayout.target else {
                        throw PublisherPolicyError.unavailable
                    }
                    var after = stat()
                    guard fstatat(fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                          Node(before, acl: "", target: target) == Node(after, acl: "", target: target) else {
                        throw PublisherPolicyError.unavailable
                    }
                    let node = Node(after, acl: "", target: target)
                    if let retained {
                        guard node == retained else { throw PublisherPolicyError.unavailable }
                    } else { nodes[path] = node }
                } else {
                    let child = openat(fd, name, flags | (entryLayout.kind == .directory ? O_DIRECTORY : 0))
                    guard child >= 0 else { throw PublisherPolicyError.unavailable }
                    defer { close(child) }
                    let acl = try retained?.acl ?? PolicyAuthorityFile.safeACL(child)
                    var opened = stat()
                    guard fstat(child, &opened) == 0, Node(before, acl: acl) == Node(opened, acl: acl) else {
                        throw PublisherPolicyError.unavailable
                    }
                    if entryLayout.kind == .directory { try scan(child, prefix: path) }
                    else {
                        guard before.st_nlink == 1, (0...536_870_912).contains(before.st_size) else {
                            throw PublisherPolicyError.unavailable
                        }
                        var magic = [UInt8](repeating: 0, count: 8)
                        let count = pread(child, &magic, magic.count, 0)
                        guard count >= 0 else { throw PublisherPolicyError.unavailable }
                        if count >= 4 && [[0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf],
                                         [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xce],
                                         [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca],
                                         [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(Array(magic.prefix(4))) {
                            guard count == 8, magic == [0xcf,0xfa,0xed,0xfe,0x0c,0x00,0x00,0x01] else {
                                throw PublisherPolicyError.unavailable
                            }
                            machO.append(path)
                        }
                    }
                    var after = stat(), named = stat()
                    guard fstat(child, &after) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          Node(before, acl: acl) == Node(after, acl: try retained?.acl ?? PolicyAuthorityFile.safeACL(child)),
                          Node(after, acl: acl) == Node(named, acl: acl) else { throw PublisherPolicyError.unavailable }
                    let node = Node(after, acl: acl)
                    if let retained {
                        guard node == retained else { throw PublisherPolicyError.unavailable }
                    } else { nodes[path] = node }
                }
            }
        }
        try scan(descriptors.last!, prefix: "")
        if let expected {
            // Each component name is unique within its parent and every full
            // path matched both the manifest and the retained node above.
            // Equal bounded counts therefore prove neither inventory omitted
            // an entry, without allocating a second node dictionary/key set.
            guard observedCount == expected.nodes.count,
                  observedCount == layout.entries.count + 1 else { throw PublisherPolicyError.unavailable }
            machO = expected.machOFiles
        } else {
            guard Set(nodes.keys).subtracting([""]) == Set(layout.entries.keys) else {
                throw PublisherPolicyError.unavailable
            }
        }
        guard machO.contains(PolicyRuntimeLayout.interpreter), machO.contains("Versions/3.14/Python") else {
            throw PublisherPolicyError.unavailable
        }
        // Ancestors can change unrelated contents. Compare their identity and
        // access policy, not mtime; the framework root itself is fully stable.
        for index in descriptors.indices {
            var named = stat()
            let opened = try PolicyAuthorityFile.safeACLObservation(descriptors[index])
            let now = Node(opened.info, acl: opened.acl), old = parents[index]
            guard now.matchesAncestorIdentityAndAccess(old) else { throw PublisherPolicyError.unavailable }
            if index > 0 {
                #if SHADOW_SYNC_TESTING
                try observer.afterAncestorRead?(components.prefix(index + 1).joined(separator: "/"))
                #endif
                guard fstatat(descriptors[index - 1], components[index], &named, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw PublisherPolicyError.unavailable
                }
                // Read access policy again instead of relying on ctime to
                // detect ACL changes between the held and named observations.
                let namedNode = Node(named, acl: try PolicyAuthorityFile.safeACL(descriptors[index]))
                guard namedNode.matchesAncestorIdentityAndAccess(now) else { throw PublisherPolicyError.unavailable }
                if index == descriptors.count - 1 {
                    guard namedNode == now else { throw PublisherPolicyError.unavailable }
                }
            }
            if index == descriptors.count - 1 { guard now == old else { throw PublisherPolicyError.unavailable } }
        }
        if let expected { return expected }
        return try Self(nodes: nodes, machOFiles: machO.sorted(), layout: layout)
    }
}
