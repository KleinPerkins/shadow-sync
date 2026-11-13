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
    private let release: ReleaseIdentity
    private let app: String
    private let executable: String
    private let owner: uid_t
    private let appIdentity: PublisherCodeVerifier.Identity
    private let helperIdentity: PublisherCodeVerifier.Identity
    private let appSnapshot: PublisherExecutableSnapshot
    private let helperSnapshot: PublisherExecutableSnapshot
    private let resources: [PolicyAuthorityFile]
    private let graphResource: PolicyAuthorityFile
    let validationProfile: InstallationValidationProfile

    private init(app: String, executable: String, owner: uid_t, account: EffectiveAccount,
                 appIdentity: PublisherCodeVerifier.Identity, helperIdentity: PublisherCodeVerifier.Identity,
                 resources: [PolicyAuthorityFile], graphs: PolicyAuthorityFile, release: ReleaseIdentity,
                 validationProfile: InstallationValidationProfile) throws {
        self.validationProfile = validationProfile
        self.app = app; self.executable = executable; self.owner = owner; self.account = account
        self.appIdentity = appIdentity; self.helperIdentity = helperIdentity
        self.resources = resources; graphResource = graphs; self.release = release; releaseSHA256 = release.releaseContractSHA256
        appSnapshot = try PublisherExecutableSnapshot.capture(path: app + "/Contents/MacOS/ShadowSync", owner: owner)
        helperSnapshot = try PublisherExecutableSnapshot.capture(path: executable, owner: owner)
    }
    static func current() throws -> LifecyclePublisher { try captureCurrent(validationProfile: .production) }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    static func current(validationProfile: InstallationValidationProfile) throws -> LifecyclePublisher {
        guard case .signedFixture = validationProfile else { throw PublisherPolicyError.unavailable }
        return try captureCurrent(validationProfile: validationProfile)
    }
    #endif
    private static func captureCurrent(validationProfile: InstallationValidationProfile) throws -> LifecyclePublisher {
        let account = try EffectiveAccount.current()
        guard account.uid != 0, getuid() == account.uid else { throw PublisherPolicyError.unavailable }
        let own = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make())
        let executable = own.executablePath
        guard executable.hasSuffix(relativeExecutable) else { throw PublisherPolicyError.unavailable }
        let app = String(executable.dropLast(relativeExecutable.count))
        guard app.hasSuffix("/ShadowSync.app") else { throw PublisherPolicyError.unavailable }
        try validationProfile.validateBundlePath(app)
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
        let release = try ReleaseIdentity(infoDictionary: dictionary); try validationProfile.validate(release)
        guard release.releaseContractSHA256 == contract.sha256 else { throw PublisherPolicyError.unavailable }
        var parser = try PolicyWireParser(contract.bytes, profile: .configuration)
        guard case let .object(fields) = try parser.parse(),
              fields["command_graphs_sha256"] == .string(graphs.sha256) else { throw PublisherPolicyError.unavailable }
        _ = try CommandGraphCatalog.decode(graphs.bytes)
        try PublisherCodeVerifier.sealed(contract, relativePath: "Resources/release-contract.json", code: code)
        try PublisherCodeVerifier.sealed(graphs, relativePath: "Resources/command-graphs.json", code: code)
        let result = try Self(app: app, executable: executable, owner: owner, account: account,
            appIdentity: publisher, helperIdentity: helper, resources: [info, contract, seal, graphs], graphs: graphs, release: release, validationProfile: validationProfile)
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
    /// Immutable evidence from this exact running source. The capsule cannot be
    /// decoded or constructed from candidate metadata and grants no install right.
    struct InstallationIdentity: Equatable {
        let candidate: InstallationCandidate
        let sourceReleaseDigest: String
        let coordinatorCode: PublisherCodeVerifier.Identity
        private let publisher: LifecyclePublisher?
        private let sourceRoot: String

        private init(publisher: LifecyclePublisher?, sourceRoot: String,
                     candidate: InstallationCandidate, sourceReleaseDigest: String,
                     coordinatorCode: PublisherCodeVerifier.Identity) {
            self.publisher = publisher; self.sourceRoot = sourceRoot; self.candidate = candidate
            self.sourceReleaseDigest = sourceReleaseDigest; self.coordinatorCode = coordinatorCode
        }
        fileprivate static func capture(_ publisher: LifecyclePublisher) throws -> Self {
            try publisher.revalidate()
            // inspect deliberately retains its effective-user ownership rule.
            // A root-owned source accepted by current() is NOT broadened here.
            let artifact = try BundleArtifactIdentity.inspect(bundlePath: publisher.app, installationProfile: publisher.validationProfile)
            let (_, app) = try PublisherCodeVerifier.verifiedStatic(path: publisher.app,
                identifier: ReleaseIdentity.bundleIdentifier, team: publisher.appIdentity.team)
            let (_, helper) = try PublisherCodeVerifier.verifiedStatic(path: publisher.executable,
                identifier: LifecyclePublisher.identifier, team: publisher.appIdentity.team)
            guard artifact.release == publisher.release, app == publisher.appIdentity,
                  helper == publisher.helperIdentity else { throw PublisherPolicyError.unavailable }
            let candidate = InstallationCandidate(release: artifact.release, bundleDigest: artifact.canonicalSHA256,
                appCDHash: app.codeDirectory.map { String(format: "%02x", $0) }.joined(),
                coordinatorCDHash: helper.codeDirectory.map { String(format: "%02x", $0) }.joined())
            try candidate.validate(profile: publisher.validationProfile)
            try publisher.revalidate()
            return Self(publisher: publisher, sourceRoot: publisher.app, candidate: candidate,
                sourceReleaseDigest: publisher.releaseSHA256, coordinatorCode: helper)
        }
        func captureCoordinator(generation: String) throws -> ProcessIdentity {
            guard let publisher else { throw CustodyRecordError.fenced }
            try publisher.revalidate()
            let process = try ProcessIdentity.capture(processID: getpid(), generation: generation,
                expectedExecutablePath: publisher.executable)
            guard process.userID == publisher.account.uid else { throw CustodyRecordError.fenced }
            return process
        }
        func revalidate() throws {
            guard let publisher, try Self.capture(publisher) == self else { throw CustodyRecordError.fenced }
        }
        static func == (a: Self, b: Self) -> Bool {
            a.publisher === b.publisher && a.sourceRoot == b.sourceRoot && a.candidate == b.candidate
                && a.sourceReleaseDigest == b.sourceReleaseDigest && a.coordinatorCode == b.coordinatorCode
        }
        #if SHADOW_SYNC_TESTING
        static func testing(root: String, candidate: InstallationCandidate) throws -> Self {
            let root = try TestIsolation.validateRoot(root)
            try candidate.validate()
            let bytes = stride(from: 0, to: candidate.coordinatorCDHash.count, by: 2).map { offset -> UInt8 in
                let start = candidate.coordinatorCDHash.index(candidate.coordinatorCDHash.startIndex, offsetBy: offset)
                return UInt8(candidate.coordinatorCDHash[start..<candidate.coordinatorCDHash.index(start, offsetBy: 2)], radix: 16)!
            }
            return Self(publisher: nil, sourceRoot: root, candidate: candidate,
                sourceReleaseDigest: candidate.release.releaseContractSHA256,
                coordinatorCode: .init(team: ReleaseIdentity.publisherTeamIdentifier,
                    identifier: LifecyclePublisher.identifier, codeDirectory: Data(bytes)))
        }
        #endif
    }
    func installationIdentity() throws -> InstallationIdentity { try InstallationIdentity.capture(self) }
    func installationSourceBundle() throws -> String { try revalidate(); return app }

    func revalidate() throws {
        try validationProfile.revalidate()
        guard account == (try EffectiveAccount.current()), getuid() == account.uid,
              appSnapshot == (try PublisherExecutableSnapshot.capture(path: app + "/Contents/MacOS/ShadowSync", owner: owner)),
              helperSnapshot == (try PublisherExecutableSnapshot.capture(path: executable, owner: owner)) else { throw PublisherPolicyError.unavailable }
        for resource in resources { try resource.revalidate() }
        let (_, appNow) = try PublisherCodeVerifier.verifiedStatic(path: app, identifier: ReleaseIdentity.bundleIdentifier, team: appIdentity.team)
        let (_, helperNow) = try PublisherCodeVerifier.runningCode(path: executable, identifier: Self.identifier, team: appIdentity.team)
        guard appNow == appIdentity, helperNow == helperIdentity else { throw PublisherPolicyError.unavailable }
    }
}
