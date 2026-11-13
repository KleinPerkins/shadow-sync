import Darwin
import Foundation

/// Installation accepts the publisher's closed MVP bundle layout. The policy
/// runtime keeps its existing sealed topology; this is not a second manifest or
/// an authority to accept arbitrary links, code, or application resources.
final class PublisherBundleLayout {
    // Apple stores the stapled ticket here (distinct from the signature seal).
    // It is bounded data only; it never grants publisher or installation authority.
    static let ticketRelative = "Contents/CodeResources"
    static let frameworkRelative = "Contents/Frameworks/Python.framework"
    private static let directories: Set<String> = [
        "", "Contents", "Contents/MacOS", "Contents/Helpers", "Contents/Resources",
        "Contents/_CodeSignature", "Contents/Frameworks", frameworkRelative,
    ]
    private static let executables: Set<String> = [
        "Contents/MacOS/ShadowSync", "Contents/Helpers/ShadowSyncLifecycleCoordinator",
    ]
    private static let resources: Set<String> = [
        "Contents/Info.plist", "Contents/_CodeSignature/CodeResources",
        "Contents/Resources/release-contract.json", "Contents/Resources/command-graphs.json",
        "Contents/Resources/com.kleinperkins.shadow-sync.plist.template",
        "Contents/Resources/ShadowSync.icns", "Contents/Resources/THIRD_PARTY_NOTICES.md",
        "Contents/Resources/PolicyAdapter.py", "Contents/Resources/awa-contract.json",
        "Contents/Resources/policy-runtime-source.json",
    ]
    let bundlePath: String
    private let layout: PolicyRuntimeLayout
    private let tree: PolicyRuntimeTree
    private let files: [PolicyAuthorityFile]
    private let publisher: PublisherCodeVerifier.Identity?
    private let owner: uid_t
    private let validationProfile: InstallationValidationProfile
    private var ticket: PolicyAuthorityFile?
    private var outerNodes: [String: PolicyRuntimeTree.Node] = [:]

    private init(bundlePath: String, layout: PolicyRuntimeLayout, files: [PolicyAuthorityFile],
                 publisher: PublisherCodeVerifier.Identity?, validationProfile: InstallationValidationProfile = .production) throws {
        self.bundlePath = bundlePath; self.layout = layout; self.files = files
        self.publisher = publisher; owner = geteuid(); self.validationProfile = validationProfile
        tree = try PolicyRuntimeTree.capture(root: bundlePath + "/" + Self.frameworkRelative,
                                            owner: owner, layout: layout)
        outerNodes = try captureOuterNodes()
        if outerNodes[Self.ticketRelative] != nil {
            ticket = try PolicyAuthorityFile.read(path: bundlePath + "/" + Self.ticketRelative,
                owner: owner, maximumBytes: 1_048_576)
        }
        guard try captureOuterNodes() == outerNodes else { throw PublisherPolicyError.unavailable }
    }

    static func captureIfPresent(_ bundlePath: String,
                                 validationProfile: InstallationValidationProfile = .production) throws -> PublisherBundleLayout? {
        try validationProfile.validateBundlePath(bundlePath)
        // Check each parent physically before examining the runtime. A malformed
        // or aliased component is never interpreted as a development bundle.
        var current = bundlePath
        for component in ["Contents", "Frameworks", "Python.framework"] {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) != 0 {
                guard errno == ENOENT else { throw PublisherPolicyError.unavailable }
                return nil
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
                throw PublisherPolicyError.unavailable
            }
        }
        let owner = geteuid(), framework = bundlePath + "/" + Self.frameworkRelative
        func read(_ relative: String, limit: Int = 65_536) throws -> PolicyAuthorityFile {
            try PolicyAuthorityFile.read(path: bundlePath + "/" + relative, owner: owner, maximumBytes: limit)
        }
        let info = try read("Contents/Info.plist")
        let source = try read("Contents/Resources/policy-runtime-source.json")
        let contract = try read("Contents/Resources/release-contract.json")
        let manifest = try read(Self.frameworkRelative + "/" + PolicyRuntimeLayout.manifest, limit: 1_048_576)
        let layout = try PolicyRuntimeLayout.decode(manifest.bytes, source: source.bytes)
        let (code, publisher) = try PublisherCodeVerifier.verifiedStatic(path: bundlePath,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
        let (frameworkCode, _) = try PublisherCodeVerifier.verifiedStatic(path: framework,
            identifier: "com.kleinperkins.shadow-sync.python-runtime", team: publisher.team)
        _ = try PublisherCodeVerifier.verifiedStatic(path: bundlePath + "/Contents/Helpers/ShadowSyncLifecycleCoordinator",
            identifier: LifecyclePublisher.identifier, team: publisher.team)
        try PublisherCodeVerifier.sealed(source, relativePath: "Resources/policy-runtime-source.json", code: code)
        try PublisherCodeVerifier.sealed(contract, relativePath: "Resources/release-contract.json", code: code)
        try PublisherCodeVerifier.sealed(manifest, relativePath: "Resources/ShadowSyncRuntimeLayout.json", code: frameworkCode)
        guard let values = try PropertyListSerialization.propertyList(from: info.bytes, format: nil) as? [String: Any] else {
            throw PublisherPolicyError.unavailable
        }
        let release = try ReleaseIdentity(infoDictionary: values)
        try validationProfile.validate(release)
        guard release.releaseContractSHA256 == contract.sha256 else { throw PublisherPolicyError.unavailable }
        let result = try Self(bundlePath: bundlePath, layout: layout, files: [info, source, contract, manifest], publisher: publisher, validationProfile: validationProfile)
        for relative in result.tree.machOFiles {
            _ = try PublisherCodeVerifier.verifiedStatic(path: framework + "/" + relative,
                identifier: relative == PolicyRuntimeLayout.interpreter ? "com.kleinperkins.shadow-sync.policy-helper" : nil,
                team: publisher.team)
        }
        try result.revalidate()
        return result
    }

    private func entry(_ relative: String) throws -> PolicyRuntimeLayout.Entry {
        if Self.directories.contains(relative) { return .init(kind: .directory, mode: 0o755, target: nil) }
        if Self.executables.contains(relative) { return .init(kind: .file, mode: 0o755, target: nil) }
        if Self.resources.union(validationProfile.additionalBundleResources).contains(relative) || relative == Self.ticketRelative { return .init(kind: .file, mode: 0o644, target: nil) }
        let prefix = Self.frameworkRelative + "/"
        guard relative.hasPrefix(prefix), let entry = layout.entries[String(relative.dropFirst(prefix.count))] else {
            throw PublisherPolicyError.unavailable
        }
        return entry
    }

    /// Returns an exact allowed link target, never a resolved external pathname.
    func validateNode(_ relative: String) throws -> String? {
        let expected = try entry(relative)
        let path = relative.isEmpty ? bundlePath : bundlePath + "/" + relative
        var info = stat()
        let type: mode_t = switch expected.kind { case .directory: S_IFDIR; case .file: S_IFREG; case .symlink: S_IFLNK }
        guard lstat(path, &info) == 0, info.st_uid == owner, info.st_flags == 0,
              info.st_mode & S_IFMT == type, info.st_mode & 0o7777 == mode_t(expected.mode),
              expected.kind != .file || info.st_nlink == 1,
              BundleArtifactIdentity.hasOnlyPermittedXattrs(path) else { throw PublisherPolicyError.unavailable }
        if relative == Self.ticketRelative {
            guard info.st_size > 0, info.st_size <= 1_048_576 else { throw PublisherPolicyError.unavailable }
        }
        if let target = expected.target {
            var bytes = [UInt8](repeating: 0, count: 1025)
            let count = readlink(path, &bytes, bytes.count)
            guard count > 0, count <= 1024, Data(bytes.prefix(count)) == Data(target.utf8) else {
                throw PublisherPolicyError.unavailable
            }
        }
        return expected.target
    }

    func requireComplete(_ observed: Set<String>) throws {
        let expected = Set(outerNodes.keys)
            .union(layout.entries.keys.map { Self.frameworkRelative + "/" + $0 })
        guard observed == expected else { throw PublisherPolicyError.unavailable }
    }

    // Retain the outer nodes too: code signatures do not authenticate Unix modes,
    // and the runtime snapshot covers only the framework. Walk opened directories
    // without following links, compare the closed roster, and retain each identity.
    private func captureOuterNodes() throws -> [String: PolicyRuntimeTree.Node] {
        var nodes: [String: PolicyRuntimeTree.Node] = [:]
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let root = open(bundlePath, flags)
        guard root >= 0 else { throw PublisherPolicyError.unavailable }
        defer { close(root) }
        func visit(_ relative: String, _ descriptor: Int32) throws {
            _ = try validateNode(relative)
            var before = stat(), after = stat(), named = stat()
            guard fstat(descriptor, &before) == 0 else { throw PublisherPolicyError.unavailable }
            let acl = try PolicyAuthorityFile.safeACL(descriptor)
            let initial = PolicyRuntimeTree.Node(before, acl: acl)
            if before.st_mode & S_IFMT == S_IFDIR, relative != Self.frameworkRelative {
                let duplicate = dup(descriptor)
                guard duplicate >= 0 else { throw PublisherPolicyError.unavailable }
                guard let stream = fdopendir(duplicate) else { close(duplicate); throw PublisherPolicyError.unavailable }
                defer { closedir(stream) }
                while true {
                    errno = 0
                    guard let item = readdir(stream) else {
                        guard errno == 0 else { throw PublisherPolicyError.unavailable }
                        break
                    }
                    let name = withUnsafePointer(to: &item.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    let child = relative.isEmpty ? name : relative + "/" + name
                    guard Self.directories.contains(child) || Self.executables.contains(child)
                        || Self.resources.union(validationProfile.additionalBundleResources).contains(child) || child == Self.ticketRelative else { throw PublisherPolicyError.unavailable }
                    let fd = openat(descriptor, name, flags)
                    guard fd >= 0 else { throw PublisherPolicyError.unavailable }
                    defer { close(fd) }
                    try visit(child, fd)
                }
            }
            let path = relative.isEmpty ? bundlePath : bundlePath + "/" + relative
            guard fstat(descriptor, &after) == 0, lstat(path, &named) == 0,
                  initial == PolicyRuntimeTree.Node(after, acl: try PolicyAuthorityFile.safeACL(descriptor)),
                  initial == PolicyRuntimeTree.Node(named, acl: acl) else { throw PublisherPolicyError.unavailable }
            nodes[relative] = initial
        }
        try visit("", root)
        let required = Self.directories.union(Self.executables).union(Self.resources).union(validationProfile.additionalBundleResources)
        guard Set(nodes.keys) == required || Set(nodes.keys) == required.union([Self.ticketRelative]) else {
            throw PublisherPolicyError.unavailable
        }
        return nodes
    }

    func revalidate() throws {
        try validationProfile.revalidate()
        guard try captureOuterNodes() == outerNodes else { throw PublisherPolicyError.unavailable }
        for file in files { try file.revalidate() }
        try ticket?.revalidate()
        try tree.revalidate(root: bundlePath + "/" + Self.frameworkRelative, owner: owner, layout: layout)
        if let publisher {
            let (_, current) = try PublisherCodeVerifier.verifiedStatic(path: bundlePath,
                identifier: ReleaseIdentity.bundleIdentifier, team: publisher.team)
            guard current == publisher else { throw PublisherPolicyError.unavailable }
        } else {
            #if !SHADOW_SYNC_TESTING
            throw PublisherPolicyError.unavailable
            #endif
        }
        guard try captureOuterNodes() == outerNodes else { throw PublisherPolicyError.unavailable }
    }

    #if SHADOW_SYNC_TESTING
    static func testing(bundlePath: String, layout: PolicyRuntimeLayout) throws -> PublisherBundleLayout {
        guard bundlePath.hasPrefix("/private/tmp/shadow-sync-publisher-policy-") else {
            throw PublisherPolicyError.unavailable
        }
        return try Self(bundlePath: bundlePath, layout: layout, files: [], publisher: nil)
    }
    static var testingDirectories: Set<String> { directories }
    static var testingExecutables: Set<String> { executables }
    static var testingResources: Set<String> { resources }
    #endif
}
