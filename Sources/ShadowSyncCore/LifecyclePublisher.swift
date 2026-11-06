import Darwin
import Foundation

/// Bootstrap identity for the bundled coordinator, independent of an installed
/// app or source checkout. It does not authorize installation/activation merely
/// because a signature validates; the lifecycle transaction owns those gates.
final class LifecyclePublisher {
    static let identifier = "com.kleinperkins.shadow-sync.lifecycle-coordinator"
    static let relativeExecutable = "/Contents/Helpers/ShadowSyncLifecycleCoordinator"
    let releaseSHA256: String
    let account: EffectiveAccount
    private let app: String
    private let executable: String
    private let owner: uid_t
    private let appIdentity: PublisherCodeVerifier.Identity
    private let helperIdentity: PublisherCodeVerifier.Identity
    private let appSnapshot: PublisherExecutableSnapshot
    private let helperSnapshot: PublisherExecutableSnapshot
    private let resources: [PolicyAuthorityFile]
    private let graphResource: PolicyAuthorityFile

    private init(app: String, executable: String, owner: uid_t, account: EffectiveAccount,
                 appIdentity: PublisherCodeVerifier.Identity, helperIdentity: PublisherCodeVerifier.Identity,
                 resources: [PolicyAuthorityFile], graphs: PolicyAuthorityFile, release: String) throws {
        self.app = app; self.executable = executable; self.owner = owner; self.account = account
        self.appIdentity = appIdentity; self.helperIdentity = helperIdentity
        self.resources = resources; graphResource = graphs; releaseSHA256 = release
        appSnapshot = try PublisherExecutableSnapshot.capture(path: app + "/Contents/MacOS/ShadowSync", owner: owner)
        helperSnapshot = try PublisherExecutableSnapshot.capture(path: executable, owner: owner)
    }
    static func current() throws -> LifecyclePublisher {
        let account = try EffectiveAccount.current()
        guard account.uid != 0, getuid() == account.uid else { throw PublisherPolicyError.unavailable }
        let own = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make())
        let executable = own.executablePath
        guard executable.hasSuffix(relativeExecutable) else { throw PublisherPolicyError.unavailable }
        let app = String(executable.dropLast(relativeExecutable.count))
        guard app.hasSuffix("/ShadowSync.app") else { throw PublisherPolicyError.unavailable }
        var node = stat()
        guard lstat(app, &node) == 0, node.st_mode & S_IFMT == S_IFDIR,
              node.st_uid == 0 || node.st_uid == account.uid else { throw PublisherPolicyError.unavailable }
        let owner = node.st_uid
        let (code, publisher) = try PublisherCodeVerifier.verifiedStatic(path: app,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
        let (_, helper) = try PublisherCodeVerifier.runningCode(path: executable,
            identifier: identifier, team: publisher.team)
        let info = try PolicyAuthorityFile.read(path: app + "/Contents/Info.plist", owner: owner, maximumBytes: 65_536)
        let contract = try PolicyAuthorityFile.read(path: app + "/Contents/Resources/release-contract.json", owner: owner, maximumBytes: 65_536)
        let graphs = try PolicyAuthorityFile.read(path: app + "/Contents/Resources/command-graphs.json", owner: owner, maximumBytes: 65_536)
        let seal = try PolicyAuthorityFile.read(path: app + "/Contents/_CodeSignature/CodeResources", owner: owner, maximumBytes: 1_048_576)
        guard let dictionary = try PropertyListSerialization.propertyList(from: info.bytes, format: nil) as? [String: Any] else {
            throw PublisherPolicyError.unavailable
        }
        let release = try ReleaseIdentity(infoDictionary: dictionary); try release.validate(requireProduction: true)
        guard release.releaseContractSHA256 == contract.sha256 else { throw PublisherPolicyError.unavailable }
        var parser = try PolicyWireParser(contract.bytes, profile: .configuration)
        guard case let .object(fields) = try parser.parse(),
              fields["command_graphs_sha256"] == .string(graphs.sha256) else { throw PublisherPolicyError.unavailable }
        _ = try CommandGraphCatalog.decode(graphs.bytes)
        try PublisherCodeVerifier.sealed(contract, relativePath: "Resources/release-contract.json", code: code)
        try PublisherCodeVerifier.sealed(graphs, relativePath: "Resources/command-graphs.json", code: code)
        let result = try Self(app: app, executable: executable, owner: owner, account: account,
            appIdentity: publisher, helperIdentity: helper, resources: [info, contract, seal, graphs], graphs: graphs, release: contract.sha256)
        try result.revalidate(); return result
    }
    /// Values come only from this verified running coordinator. Keeping the
    /// publisher in the helper retains its complete distribution binding.
    func custodianBootstrap() throws -> (path: String, owner: uid_t,
        identity: PublisherCodeVerifier.Identity, snapshot: PublisherExecutableSnapshot,
        graphs: PolicyAuthorityFile) {
        try revalidate()
        return (executable, owner, helperIdentity, helperSnapshot, graphResource)
    }
    func revalidate() throws {
        guard account == (try EffectiveAccount.current()), getuid() == account.uid,
              appSnapshot == (try PublisherExecutableSnapshot.capture(path: app + "/Contents/MacOS/ShadowSync", owner: owner)),
              helperSnapshot == (try PublisherExecutableSnapshot.capture(path: executable, owner: owner)) else { throw PublisherPolicyError.unavailable }
        for resource in resources { try resource.revalidate() }
        let (_, appNow) = try PublisherCodeVerifier.verifiedStatic(path: app, identifier: ReleaseIdentity.bundleIdentifier, team: appIdentity.team)
        let (_, helperNow) = try PublisherCodeVerifier.runningCode(path: executable, identifier: Self.identifier, team: appIdentity.team)
        guard appNow == appIdentity, helperNow == helperIdentity else { throw PublisherPolicyError.unavailable }
    }
}
