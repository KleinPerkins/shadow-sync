import Darwin
import Foundation
import Security

/// A parsed catalog is data, not signal/spawn authority. Entries are admitted
/// only from a publisher-sealed resource whose digest is in the release contract.
/// No installed tool is automatically enrolled by observing its current signature.
struct CommandGraphCatalog {
    enum Adapter: String {
        case launchctlRead = "launchctl-read/v1"
        case launchctlMutation = "launchctl-mutation/v1"
        case signatureCheck = "signature-check/v1"
        case discoveryGit = "discovery-git/v1"
        case systemGitConfig = "system-git-config/v1"
        case policyClassify = "policy-classify/v1"
        var kind: CustodyCommandKind {
            switch self {
            case .launchctlRead: .launchctlRead
            case .launchctlMutation: .launchctlMutation
            case .signatureCheck: .signatureCheck
            case .discoveryGit: .discoveryGit
            case .systemGitConfig: .systemGitConfig
            case .policyClassify: .policyClassify
            }
        }
        // These closed graphs have no admitted detached descendants. A new
        // tool selection, path, command form or graph needs its own review.
        var paths: [String] {
            switch self {
            case .launchctlRead, .launchctlMutation: ["/bin/launchctl"]
            case .signatureCheck: ["/usr/bin/codesign"]
            case .discoveryGit, .systemGitConfig: ["/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
            // This one fixed relative path is resolved only through verified
            // publisher resources, never through a caller-selected bundle.
            case .policyClassify: ["Contents/Frameworks/Python.framework/" + PolicyRuntimeLayout.interpreter]
            }
        }
    }
    struct Tool {
        let path: String
        let codeDirectory: String
    }
    struct Entry {
        let adapter: Adapter
        let systemBuild: String
        let receiptSHA256: String
        let tools: [Tool]
    }
    let entries: [Entry]
    static func decode(_ data: Data) throws -> Self {
        let v = try CustodyWire.decode(data, maximum: 65_536).object(keys: ["schema", "graphs"])
        guard try CustodyWire.text(v["schema"]) == "shadow-sync-command-graphs/v1" else { throw CustodyProtocolError.invalidMessage }
        let graphs = try CustodyWire.array(v["graphs"])
        guard graphs.count <= 32 else { throw CustodyProtocolError.invalidMessage }
        var entries: [Entry] = [], keys = Set<String>()
        for graph in graphs {
            let g = try graph.object(keys: ["adapter", "architecture", "system_build", "qualification_sha256", "tools"])
            guard let adapter = Adapter(rawValue: try CustodyWire.text(g["adapter"])),
                  try CustodyWire.text(g["architecture"]) == "arm64" else { throw CustodyProtocolError.invalidMessage }
            let build = try CustodyWire.text(g["system_build"]), receipt = try CustodyWire.text(g["qualification_sha256"])
            guard (4...32).contains(build.utf8.count), build.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  CustodyWire.hex(receipt, bytes: 32), receipt != String(repeating: "0", count: 64),
                  keys.insert(adapter.rawValue + ":" + build).inserted else { throw CustodyProtocolError.invalidMessage }
            let tools = try CustodyWire.array(g["tools"]).map { value -> Tool in
                let t = try value.object(keys: ["path", "cdhash"])
                let path = try CustodyWire.text(t["path"]), hash = try CustodyWire.text(t["cdhash"])
                guard CustodyWire.hex(hash, bytes: 20), hash != String(repeating: "0", count: 40) else { throw CustodyProtocolError.invalidMessage }
                return Tool(path: path, codeDirectory: hash)
            }
            guard tools.map(\.path) == adapter.paths else { throw CustodyProtocolError.invalidMessage }
            entries.append(Entry(adapter: adapter, systemBuild: build, receiptSHA256: receipt, tools: tools))
        }
        return Self(entries: entries)
    }
    func entry(kind: CustodyCommandKind, systemBuild: String) throws -> Entry {
        guard let entry = entries.first(where: { $0.adapter.kind == kind && $0.systemBuild == systemBuild }) else {
            throw PublisherPolicyError.unavailable
        }
        return entry
    }
}

/// Immutable, privately constructed authority for a release-qualified graph.
/// It never grants ownership of a PID; only the original spawn anchor can attach
/// it to an owner. Security/filesystem work happens outside the owner mutex.
final class QualifiedCommandGraph: @unchecked Sendable {
    private struct Node {
        let path: String
        let snapshot: PublisherExecutableSnapshot
        let requirement: SecRequirement
        let owner: uid_t
    }
    let entryPath: String
    private let nodes: [Node]
    private let resource: PolicyAuthorityFile?
    private let publisher: PublisherPolicyResources?
    private static func snapshot(_ path: String, owner: uid_t) throws -> PublisherExecutableSnapshot {
        if path == "/usr/bin/git" { return try PublisherExecutableSnapshot.captureSystemGitLauncher() }
        return try PublisherExecutableSnapshot.capture(path: path, owner: owner)
    }
    private init(entry: CommandGraphCatalog.Entry, resource: PolicyAuthorityFile?,
                 publisher: PublisherPolicyResources? = nil) throws {
        guard (entry.adapter == .policyClassify) == (publisher != nil) else { throw PublisherPolicyError.unavailable }
        self.resource = resource; self.publisher = publisher
        entryPath = publisher?.interpreter ?? entry.tools[0].path
        nodes = try entry.tools.map { tool in
            let path: String, owner: uid_t, requirement: SecRequirement
            if let publisher {
                try publisher.revalidate()
                let identity = try publisher.commandGraphIdentity
                guard tool.path == CommandGraphCatalog.Adapter.policyClassify.paths[0],
                      identity.identifier == "com.kleinperkins.shadow-sync.policy-helper",
                      identity.team == ReleaseIdentity.publisherTeamIdentifier,
                      identity.codeDirectory.map({ String(format: "%02x", $0) }).joined() == tool.codeDirectory else {
                    throw PublisherPolicyError.unavailable
                }
                path = publisher.interpreter; owner = geteuid()
                requirement = try PublisherCodeVerifier.requirement(identifier: identity.identifier,
                    team: identity.team, codeDirectory: identity.codeDirectory)
            } else {
                path = tool.path; owner = 0
                var required: SecRequirement?
                let expression = "anchor apple and cdhash H\"" + tool.codeDirectory + "\""
                guard SecRequirementCreateWithString(expression as CFString, [], &required) == errSecSuccess,
                      let required else { throw PublisherPolicyError.unavailable }
                requirement = required
            }
            let snapshot = try Self.snapshot(path, owner: owner)
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | SecCSFlags.noNetworkAccess.rawValue), requirement) == errSecSuccess,
                  snapshot == (try Self.snapshot(path, owner: owner)) else { throw PublisherPolicyError.unavailable }
            return Node(path: path, snapshot: snapshot, requirement: requirement, owner: owner)
        }
    }
    static func production(kind: CustodyCommandKind, helper: CustodyHelperExecutable,
                           publisher: PublisherPolicyResources? = nil) throws -> Self {
        #if !arch(arm64)
        throw PublisherPolicyError.unavailable
        #else
        let resource = try helper.productionGraphResource()
        let catalog = try CommandGraphCatalog.decode(resource.bytes)
        return try Self(entry: catalog.entry(kind: kind, systemBuild: systemBuild()),
            resource: resource, publisher: publisher)
        #endif
    }
    /// Production callers keep the sealed-release factory. The distinct native
    /// fixture helper may use a retained test catalog only in a testing build.
    static func forHelper(kind: CustodyCommandKind, helper: CustodyHelperExecutable,
                          publisher: PublisherPolicyResources? = nil) throws -> Self {
        #if SHADOW_SYNC_TESTING
        if let resource = try helper.testingDiscoveryGraphResource() {
            let entry = try CommandGraphCatalog.decode(resource.bytes).entry(kind: kind, systemBuild: systemBuild())
            if kind == .policyClassify {
                guard let publisher else { throw PublisherPolicyError.unavailable }
                return try Self(testingEntry: entry, resource: resource, publisher: publisher)
            }
            guard publisher == nil, kind == .systemGitConfig || kind == .discoveryGit else {
                throw PublisherPolicyError.unavailable
            }
            return try Self(entry: entry, resource: resource)
        }
        #endif
        return try production(kind: kind, helper: helper, publisher: publisher)
    }
    private static func systemBuild() throws -> String {
        var bytes = [CChar](repeating: 0, count: 64), size = 64
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0,
              (2...64).contains(size), bytes[size - 1] == 0 else { throw PublisherPolicyError.unavailable }
        return String(decoding: bytes.prefix(size - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func revalidate() throws {
        try resource?.revalidate()
        try publisher?.revalidate()
        for node in nodes {
            guard node.snapshot == (try Self.snapshot(node.path, owner: node.owner)) else { throw PublisherPolicyError.unavailable }
        }
    }
    func validateSuspended(_ anchor: OwnedSpawnAnchor) throws {
        try revalidate()
        let identity = try ProcessIdentity.capture(processID: anchor.processID, generation: RunIdentity.make(), expectedExecutablePath: entryPath)
        guard identity.executablePath == entryPath else { throw PublisherPolicyError.unavailable }
        try validateCode(processID: anchor.processID, node: nodes[0])
        try publisher?.validateSuspendedInterpreter(anchor.processID)
    }
    private func validateCode(processID: pid_t, node: Node) throws {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, .noNetworkAccess, node.requirement) == errSecSuccess else { throw PublisherPolicyError.unavailable }
    }
    /// An observation of a retained child, not adoption. Exec may occur between
    /// observations; safety rests on the original unreaped child and the closed,
    /// qualified graph. The owner rechecks this observation under its mutex.
    enum Observation { case validated(ProcessIdentity), noLiveImage, transition, rejected }
    func permitsImagePath(_ path: String) -> Bool { nodes.contains { $0.path == path } }
    func observe(original: ProcessIdentity) -> Observation {
        do { try revalidate() } catch { return .rejected }
        guard let observed = try? ProcessIdentity.capture(processID: original.processID, generation: original.generation) else { return .noLiveImage }
        guard observed.sameOriginalChild(as: original), let node = nodes.first(where: { $0.path == observed.executablePath }) else { return .rejected }
        do { try validateCode(processID: original.processID, node: node) }
        catch {
            // Distinguish a real image change/exit race from a known mismatch.
            // Neither observation authorizes a signal by itself.
            guard let after = try? ProcessIdentity.capture(processID: original.processID, generation: original.generation) else { return .noLiveImage }
            guard after.sameOriginalChild(as: original), nodes.contains(where: { $0.path == after.executablePath }) else { return .rejected }
            return after.executablePath != observed.executablePath ? .transition : .rejected
        }
        guard observed.isCurrent(expectedGeneration: original.generation) else {
            guard let after = try? ProcessIdentity.capture(processID: original.processID, generation: original.generation) else { return .noLiveImage }
            return after.sameOriginalChild(as: original) && permitsImagePath(after.executablePath) ? .transition : .rejected
        }
        return .validated(observed)
    }
    #if SHADOW_SYNC_TESTING
    private init(testingEntry entry: CommandGraphCatalog.Entry, resource: PolicyAuthorityFile,
                 publisher: PublisherPolicyResources) throws {
        let code = try publisher.testingInterpreterAuthority()
        guard entry.adapter == .policyClassify, entry.tools.count == 1,
              entry.tools[0].path == CommandGraphCatalog.Adapter.policyClassify.paths[0],
              entry.tools[0].codeDirectory == code.codeDirectory.map({ String(format: "%02x", $0) }).joined() else {
            throw PublisherPolicyError.unavailable
        }
        self.resource = resource; self.publisher = publisher; entryPath = code.path
        nodes = [Node(path: code.path, snapshot: try Self.snapshot(code.path, owner: geteuid()),
                      requirement: code.requirement, owner: geteuid())]
        try revalidate()
    }
    // Only the compiled test suite may supply a synthetic catalog. It exercises
    // production matching against fixed Apple tools without qualifying a release.
    static func testing(_ data: Data, kind: CustodyCommandKind, build: String) throws -> QualifiedCommandGraph {
        try Self(entry: CommandGraphCatalog.decode(data).entry(kind: kind, systemBuild: build), resource: nil)
    }
    #endif
}
