import Darwin
import Foundation
import Security

/// These checks prove Developer ID code/resource integrity without spawning a
/// verifier or consulting the network. They do not assert notarization,
/// revocation freshness, Gatekeeper approval, or product qualification.
enum PublisherCodeVerifier {
    struct Identity: Equatable, Sendable {
        let team: String
        let identifier: String
        let codeDirectory: Data
    }
    private static let noNetwork: SecCSFlags = .noNetworkAccess
    private static let strict = SecCSFlags(rawValue: SecCSFlags.noNetworkAccess.rawValue
        | kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures
        | kSecCSRestrictSymlinks)

    static func requirement(identifier: String?, team: String?, codeDirectory: Data? = nil) throws -> SecRequirement {
        func token(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 255 && text.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46].contains($0)
            }
        }
        guard identifier.map(token) ?? true,
              team.map({ $0.utf8.count == 10 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } }) ?? true else {
            throw PublisherPolicyError.unavailable
        }
        var expression = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        if let identifier { expression += " and identifier \"\(identifier)\"" }
        if let team { expression += " and certificate leaf[subject.OU] = \"\(team)\"" }
        if let codeDirectory {
            guard codeDirectory.count == 20 else { throw PublisherPolicyError.unavailable }
            expression += " and cdhash H\"\(codeDirectory.map { String(format: "%02x", $0) }.joined())\""
        }
        var result: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &result) == errSecSuccess,
              let result else { throw PublisherPolicyError.unavailable }
        return result
    }

    static func verifiedStatic(path: String, identifier: String?, team: String?) throws -> (SecStaticCode, Identity) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, strict,
                try requirement(identifier: identifier, team: team)) == errSecSuccess else {
            throw PublisherPolicyError.unavailable
        }
        let identity = try information(code)
        guard identifier.map({ $0 == identity.identifier }) ?? true,
              team.map({ $0 == identity.team }) ?? true else { throw PublisherPolicyError.unavailable }
        return (code, identity)
    }

    private static func information(_ code: SecStaticCode) throws -> Identity {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0, flags.uint32Value & 0x0002 == 0,
              info[kSecCodeInfoTimestamp as String] is Date,
              let cdHash = info[kSecCodeInfoUnique as String] as? Data, !cdHash.isEmpty else {
            throw PublisherPolicyError.unavailable
        }
        // Empty entitlements are intentional. A future entitlement requires a
        // separately reviewed contract change rather than an implicit exception.
        if let entitlements = info[kSecCodeInfoEntitlementsDict as String] {
            guard let values = entitlements as? [String: Any], values.isEmpty else {
                throw PublisherPolicyError.unavailable
            }
        } else if info[kSecCodeInfoEntitlements as String] != nil {
            throw PublisherPolicyError.unavailable
        }
        _ = try requirement(identifier: identifier, team: team)
        return Identity(team: team, identifier: identifier, codeDirectory: cdHash)
    }

    static func runningApplication(path: String) throws -> (SecStaticCode, Identity) {
        try runningCode(path: path, identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
    }

    static func runningCode(path: String, identifier: String, team: String) throws -> (SecStaticCode, Identity) {
        var running: SecCode?
        let required = try requirement(identifier: identifier, team: team)
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, noNetwork, required) == errSecSuccess else {
            throw PublisherPolicyError.unavailable
        }
        var disk: SecStaticCode?, location: CFURL?
        guard SecCodeCopyStaticCode(running, [], &disk) == errSecSuccess, let disk,
              SecCodeCopyPath(disk, [], &location) == errSecSuccess, let location,
              (location as URL).path.utf8.elementsEqual(path.utf8) else { throw PublisherPolicyError.unavailable }
        let (validated, identity) = try verifiedStatic(path: path, identifier: identifier, team: team)
        // Static-code lookup is not an authentication boundary by itself. A
        // second dynamic validity check binds the live process to the valid
        // on-disk code after all static validation has completed.
        guard SecCodeCheckValidity(running, noNetwork,
                try requirement(identifier: identity.identifier, team: identity.team)) == errSecSuccess,
              try information(disk) == identity else { throw PublisherPolicyError.unavailable }
        return (validated, identity)
    }

    static func sealed(_ file: PolicyAuthorityFile, relativePath: String, code: SecStaticCode) throws {
        guard SecCodeValidateFileResource(code, relativePath as CFString, file.bytes as CFData, noNetwork) == errSecSuccess else {
            throw PublisherPolicyError.unavailable
        }
    }

    /// A point-in-time authenticated socket-peer observation. This value carries
    /// neither installation ownership nor command authority; every consequential
    /// session transition must authenticate the retained socket again and compare
    /// the observation with its original session binding.
    struct AuditPeerObservation: Equatable, Sendable {
        let uid: uid_t
        let gid: gid_t
        let pid: pid_t
        let pidVersion: Int32
        let auditToken: Data

        fileprivate init(uid: uid_t, gid: gid_t, pid: pid_t, pidVersion: Int32, auditToken: Data) {
            self.uid = uid; self.gid = gid; self.pid = pid
            self.pidVersion = pidVersion; self.auditToken = auditToken
        }
    }

    /// The caller must obtain `expected` from its authenticated exact candidate
    /// installation binding. A peer message, serialized observation or same-team
    /// identity cannot supply that authority. Socket peers never use the owned
    /// suspended-child PID lookup below.
    static func livePeer(socket: OwnedFileDescriptor, expected: Identity,
                         expectedUID: uid_t) throws -> AuditPeerObservation {
        do {
            // No temporary descriptor can outlive the real session's close.
            // The short native queries exclude close/reuse on the original;
            // Security verification runs outside that descriptor mutex.
            let before = try socket.withOriginalSocket { try peerObservation($0, expectedUID: expectedUID) }
            let required = try requirement(identifier: expected.identifier,
                team: expected.team, codeDirectory: expected.codeDirectory)
            let attributes = [kSecGuestAttributeAudit as String: before.auditToken as CFData] as CFDictionary
            var peer: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess,
                  let peer, SecCodeCheckValidity(peer, noNetwork, required) == errSecSuccess else {
                throw PublisherPolicyError.unavailable
            }
            guard try socket.withOriginalSocket({ try peerObservation($0, expectedUID: expectedUID) }) == before else {
                throw PublisherPolicyError.unavailable
            }
            return before
        } catch { throw PublisherPolicyError.unavailable }
    }

    private static func peerObservation(_ descriptor: Int32, expectedUID: uid_t) throws -> AuditPeerObservation {
        var kind: Int32 = 0
        var kindSize = socklen_t(MemoryLayout<Int32>.size)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
              getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &kind, &kindSize) == 0,
              Int(kindSize) == MemoryLayout<Int32>.size, kind == SOCK_STREAM else {
            throw PublisherPolicyError.unavailable
        }
        // getpeername refuses an unconnected/listening socket. Check both
        // endpoints' families; an Internet stream is never a readiness channel.
        func unixAddress(peer: Bool) throws {
            var address = sockaddr_un()
            var size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    peer ? getpeername(descriptor, $0, &size) : getsockname(descriptor, $0, &size)
                }
            }
            guard result == 0, Int(size) >= MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size, Int(size) <= MemoryLayout<sockaddr_un>.size,
                  address.sun_family == sa_family_t(AF_UNIX) else { throw PublisherPolicyError.unavailable }
        }
        try unixAddress(peer: false)
        try unixAddress(peer: true)
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0,
              Int(tokenSize) == MemoryLayout<audit_token_t>.size,
              getpeereid(descriptor, &uid, &gid) == 0,
              getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0,
              Int(pidSize) == MemoryLayout<pid_t>.size,
              uid == expectedUID, uid == audit_token_to_euid(token), gid == audit_token_to_egid(token),
              pid > 0, pid == audit_token_to_pid(token) else { throw PublisherPolicyError.unavailable }
        // Decode using SDK accessors, never guessed audit_token_t word offsets.
        // Preserve all token bytes, including the process-generation binding.
        return AuditPeerObservation(uid: uid, gid: gid, pid: pid,
            pidVersion: audit_token_to_pidversion(token), auditToken: withUnsafeBytes(of: token) { Data($0) })
    }

    static func suspendedChild(_ pid: pid_t, expected: Identity) throws {
        // Only the runner supplies its own live, unreaped, suspended child PID.
        // No PID from disk, a socket, or a user preference reaches this method.
        guard pid > 0 else { throw PublisherPolicyError.unavailable }
        var child: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &child) == errSecSuccess, let child,
              SecCodeCheckValidity(child, noNetwork, try requirement(identifier: expected.identifier,
                team: expected.team, codeDirectory: expected.codeDirectory)) == errSecSuccess else {
            throw PublisherPolicyError.unavailable
        }
    }
}

/// The executable's initial bytes are checked by Security. Retain its stable
/// no-follow identity as well, so later pathname replacement cannot keep an
/// otherwise unchanged resource lease alive. Ancestor content changes do not
/// matter; ancestor replacement or access-policy changes do.
struct PublisherExecutableSnapshot: Equatable {
    struct Parent: Equatable {
        let device: Int32, inode: UInt64, owner: UInt32, group: UInt32, mode: UInt16
        let acl: String
        init(_ s: stat, _ acl: String) {
            device = s.st_dev; inode = s.st_ino; owner = s.st_uid; group = s.st_gid; mode = s.st_mode
            self.acl = acl
        }
    }
    let parents: [Parent]
    let file: PolicyRuntimeTree.Node
    static func capture(path: String, owner: uid_t) throws -> Self {
        try capture(path: path, owner: owner, systemGitLauncher: false)
    }
    /// Apple's fixed system Git multiplexer has multiple hard links. Only its
    /// root-owned, no-follow path may retain that topology; the graph caller
    /// separately requires the release-qualified Apple CDHash. This snapshot is
    /// not executable authority. App/helper and all other tool paths retain the
    /// single-link rule. The actual link count remains in the stable node proof.
    static func captureSystemGitLauncher() throws -> Self {
        try capture(path: "/usr/bin/git", owner: 0, systemGitLauncher: true)
    }
    private static func capture(path: String, owner: uid_t, systemGitLauncher: Bool) throws -> Self {
        let names = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard path.utf8.count <= 4096, names.first == "", (2...65).contains(names.count),
              names.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(92), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw PublisherPolicyError.unavailable
        }
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptors: [Int32] = [], parents: [Parent] = []
        var file: Int32 = -1
        defer { if file >= 0 { close(file) }; for fd in descriptors.reversed() { close(fd) } }
        func append(_ fd: Int32) throws {
            guard fd >= 0 else { throw PublisherPolicyError.unavailable }
            descriptors.append(fd)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == owner,
                  info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else {
                throw PublisherPolicyError.unavailable
            }
            parents.append(Parent(info, try PolicyAuthorityFile.safeACL(fd)))
        }
        try append(Darwin.open("/", flags | O_DIRECTORY))
        for name in names.dropFirst().dropLast() { try append(openat(descriptors.last!, name, flags | O_DIRECTORY)) }
        file = openat(descriptors.last!, names.last!, flags)
        var before = stat(), after = stat(), named = stat()
        guard file >= 0, fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == owner, before.st_mode & 0o7777 == 0o755,
              before.st_nlink == 1 || (systemGitLauncher && path == "/usr/bin/git" && owner == 0 && before.st_nlink > 0),
              (1...536_870_912).contains(before.st_size) else { throw PublisherPolicyError.unavailable }
        let node = PolicyRuntimeTree.Node(before, acl: try PolicyAuthorityFile.safeACL(file))
        guard fstat(file, &after) == 0, fstatat(descriptors.last!, names.last!, &named, AT_SYMLINK_NOFOLLOW) == 0,
              node == PolicyRuntimeTree.Node(after, acl: try PolicyAuthorityFile.safeACL(file)),
              node == PolicyRuntimeTree.Node(named, acl: node.acl) else { throw PublisherPolicyError.unavailable }
        for index in descriptors.indices {
            var info = stat()
            guard fstat(descriptors[index], &info) == 0,
                  Parent(info, try PolicyAuthorityFile.safeACL(descriptors[index])) == parents[index] else {
                throw PublisherPolicyError.unavailable
            }
            if index > 0 {
                guard fstatat(descriptors[index - 1], names[index], &info, AT_SYMLINK_NOFOLLOW) == 0,
                      Parent(info, parents[index].acl) == parents[index] else { throw PublisherPolicyError.unavailable }
            }
        }
        return Self(parents: parents, file: node)
    }
}

/// Constructible in production only from the currently running canonical,
/// Developer ID application. All inputs are fixed application resources;
/// source checkouts, PATH, environment overrides and policy candidate paths
/// cannot select the interpreter or establish publisher authority.
final class PublisherPolicyResources: @unchecked Sendable {
    let interpreter: String
    let adapter: Data
    let contract: Data
    private let framework: String
    private let owner: uid_t
    private let layout: PolicyRuntimeLayout
    private let tree: PolicyRuntimeTree
    private let resources: [PolicyAuthorityFile]
    private let appExecutable: String
    private let appExecutableIdentity: PublisherExecutableSnapshot
    private let interpreterIdentity: PublisherCodeVerifier.Identity?
    #if SHADOW_SYNC_TESTING
    private var fixtureInterpreter: DiscoveryFixtureCode?
    #endif

    private init(interpreter: String, adapter: Data, contract: Data, framework: String,
                 owner: uid_t, layout: PolicyRuntimeLayout, tree: PolicyRuntimeTree,
                 resources: [PolicyAuthorityFile], appExecutable: String,
                 appExecutableIdentity: PublisherExecutableSnapshot,
                 interpreterIdentity: PublisherCodeVerifier.Identity?) {
        self.interpreter = interpreter; self.adapter = adapter; self.contract = contract
        self.framework = framework; self.owner = owner; self.layout = layout
        self.tree = tree; self.resources = resources
        self.appExecutable = appExecutable; self.appExecutableIdentity = appExecutableIdentity
        self.interpreterIdentity = interpreterIdentity
    }

    static func production(account: EffectiveAccount) throws -> PublisherPolicyResources {
        do {
            guard account.uid == geteuid(), account == (try EffectiveAccount.current()) else {
                throw PublisherPolicyError.unavailable
            }
            let app = account.homeDirectory + "/Applications/ShadowSync.app"
            // Refuse a source executable, translocated DMG, or alternate copy
            // before reading any host policy or application resource.
            guard Bundle.main.bundleURL.path.utf8.elementsEqual(app.utf8) else { throw PublisherPolicyError.unavailable }
            func resource(_ relative: String, limit: Int = 1_048_576) throws -> PolicyAuthorityFile {
                try PolicyAuthorityFile.read(path: app + "/Contents/" + relative, owner: account.uid, maximumBytes: limit)
            }
            let info = try resource("Info.plist", limit: 65_536)
            let adapter = try resource("Resources/PolicyAdapter.py")
            let contract = try resource("Resources/awa-contract.json", limit: 16_384)
            let source = try resource("Resources/policy-runtime-source.json", limit: 16_384)
            let releaseContract = try resource("Resources/release-contract.json", limit: 65_536)
            let codeResources = try resource("_CodeSignature/CodeResources")
            let appExecutable = app + "/Contents/MacOS/ShadowSync"
            let appExecutableIdentity = try PublisherExecutableSnapshot.capture(path: appExecutable, owner: account.uid)
            let framework = app + "/Contents/Frameworks/Python.framework"
            let manifest = try PolicyAuthorityFile.read(path: framework + "/" + PolicyRuntimeLayout.manifest,
                owner: account.uid, maximumBytes: 1_048_576)
            let layout = try PolicyRuntimeLayout.decode(manifest.bytes, source: source.bytes)
            let before = try PolicyRuntimeTree.capture(root: framework, owner: account.uid, layout: layout)
            let (appCode, publisher) = try PublisherCodeVerifier.runningApplication(path: app)
            for (file, path) in [(adapter, "Resources/PolicyAdapter.py"), (contract, "Resources/awa-contract.json"),
                                  (source, "Resources/policy-runtime-source.json"), (releaseContract, "Resources/release-contract.json")] {
                try PublisherCodeVerifier.sealed(file, relativePath: path, code: appCode)
            }
            let (frameworkCode, _) = try PublisherCodeVerifier.verifiedStatic(path: framework,
                identifier: "com.kleinperkins.shadow-sync.python-runtime", team: publisher.team)
            try PublisherCodeVerifier.sealed(manifest, relativePath: "Resources/ShadowSyncRuntimeLayout.json", code: frameworkCode)
            var interpreterIdentity: PublisherCodeVerifier.Identity?
            for file in before.machOFiles {
                let (_, identity) = try PublisherCodeVerifier.verifiedStatic(path: framework + "/" + file,
                    identifier: file == PolicyRuntimeLayout.interpreter ? "com.kleinperkins.shadow-sync.policy-helper" : nil,
                    team: publisher.team)
                if file == PolicyRuntimeLayout.interpreter { interpreterIdentity = identity }
            }
            guard let dictionary = try PropertyListSerialization.propertyList(from: info.bytes, format: nil) as? [String: Any] else {
                throw PublisherPolicyError.unavailable
            }
            let release = try ReleaseIdentity(infoDictionary: dictionary)
            try release.validate(requireProduction: true)
            guard release.releaseContractSHA256 == releaseContract.sha256 else { throw PublisherPolicyError.unavailable }
            _ = try QualifiedAWAContract.decode(contract.bytes)
            guard let interpreterIdentity else { throw PublisherPolicyError.unavailable }
            let result = Self(interpreter: framework + "/" + PolicyRuntimeLayout.interpreter,
                adapter: adapter.bytes, contract: contract.bytes, framework: framework, owner: account.uid,
                layout: layout, tree: before, resources: [info, adapter, contract, source, releaseContract, manifest, codeResources],
                appExecutable: appExecutable, appExecutableIdentity: appExecutableIdentity, interpreterIdentity: interpreterIdentity)
            try result.revalidate()
            return result
        } catch { throw PublisherPolicyError.unavailable }
    }

    func revalidate() throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        let diagnosticSample = DiscoveryFixtureDiagnostic.samplePublisherRevalidation()
        let diagnosticAdmission = DiscoveryFixtureDiagnostic.currentAdmission
        let diagnosticCollect = diagnosticSample || diagnosticAdmission != nil
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.resourceFiles
        var diagnosticMilestones: [UInt64] = []
        var diagnosticPassed = false
        defer {
            diagnosticAdmission?.capture(.publisher, stage: diagnosticStage,
                started: diagnosticStart, passed: diagnosticPassed, milestones: diagnosticMilestones)
            if !diagnosticPassed || diagnosticSample {
                DiscoveryFixtureDiagnostic.record(.publisher, stage: diagnosticStage,
                    started: diagnosticStart, deadline: nil, succeeded: diagnosticPassed,
                    milestones: diagnosticMilestones)
            }
        }
        #endif
        do {
            try PolicyAuthorityFile.revalidate(resources)
            #if SHADOW_SYNC_TESTING
            if diagnosticCollect { diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds) }
            diagnosticStage = .appExecutable
            #endif
            guard try PublisherExecutableSnapshot.capture(path: appExecutable, owner: owner) == appExecutableIdentity else {
                throw PublisherPolicyError.unavailable
            }
            #if SHADOW_SYNC_TESTING
            if diagnosticCollect { diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds) }
            diagnosticStage = .runtimeTree
            #endif
            try tree.revalidate(root: framework, owner: owner, layout: layout)
            #if SHADOW_SYNC_TESTING
            // Three intervals: resource files, app identity, then runtime-tree
            // validation and defer overhead. All observed inputs stay private.
            diagnosticPassed = true
            diagnosticStage = .postflight
            #endif
        } catch { throw PublisherPolicyError.unavailable }
    }

    var commandGraphIdentity: PublisherCodeVerifier.Identity {
        get throws {
            guard let interpreterIdentity else { throw PublisherPolicyError.unavailable }
            return interpreterIdentity
        }
    }

    func validateSuspendedInterpreter(_ pid: pid_t) throws {
        #if SHADOW_SYNC_TESTING
        if let fixtureInterpreter { try fixtureInterpreter.validateSuspended(pid); return }
        #endif
        guard let interpreterIdentity else { throw PublisherPolicyError.unavailable }
        try PublisherCodeVerifier.suspendedChild(pid, expected: interpreterIdentity)
    }

    #if SHADOW_SYNC_TESTING
    /// Uses the same retained resource tree and transport, with explicitly
    /// fixture-only code trust. Production construction still requires the
    /// canonical running Developer ID app and cannot consume this identity.
    static func testingDiscovery(account: EffectiveAccount) throws -> PublisherPolicyResources {
        guard account == (try EffectiveAccount.isolated(homeDirectory: account.homeDirectory)) else {
            throw PublisherPolicyError.unavailable
        }
        let (framework, location) = try DiscoveryFixtureResources.framework(home: account.homeDirectory)
        let adapter = try DiscoveryFixtureResources.read(home: account.homeDirectory, name: "PolicyAdapter.py", maximum: 65_536)
        let contract = try DiscoveryFixtureResources.read(home: account.homeDirectory, name: "awa-contract.json", maximum: 16_384)
        let source = try DiscoveryFixtureResources.read(home: account.homeDirectory, name: "policy-runtime-source.json", maximum: 16_384)
        let manifest = try PolicyAuthorityFile.read(path: framework + "/" + PolicyRuntimeLayout.manifest,
            owner: account.uid, maximumBytes: 1_048_576)
        let layout = try PolicyRuntimeLayout.decode(manifest.bytes, source: source.bytes)
        let tree = try PolicyRuntimeTree.capture(root: framework, owner: account.uid, layout: layout)
        let executable = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()).executablePath
        guard executable.hasPrefix("/private/tmp/shadow-sync-") else { throw PublisherPolicyError.unavailable }
        let code = try DiscoveryFixtureCode(path: framework + "/" + PolicyRuntimeLayout.interpreter)
        _ = try QualifiedAWAContract.decode(contract.bytes)
        let result = try Self(interpreter: code.path, adapter: adapter.bytes, contract: contract.bytes,
            framework: framework, owner: account.uid, layout: layout, tree: tree,
            resources: [location, adapter, contract, source, manifest], appExecutable: executable,
            appExecutableIdentity: PublisherExecutableSnapshot.capture(path: executable, owner: account.uid),
            interpreterIdentity: nil)
        result.fixtureInterpreter = code
        try result.revalidate(); try code.revalidate()
        return result
    }

    func testingInterpreterAuthority() throws -> DiscoveryFixtureCode {
        guard interpreterIdentity == nil, let fixtureInterpreter else { throw PublisherPolicyError.unavailable }
        try revalidate(); try fixtureInterpreter.revalidate()
        return fixtureInterpreter
    }
    #endif
}
