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
    /// A resource handoff can originate only in this exact running distribution.
    /// Paths, accounts, decoded contracts and candidate observations cannot mint
    /// one. The retained installation identity also binds the whole bundle.
    struct PolicyResourcesSource {
        private let publisher: LifecyclePublisher
        let installation: InstallationIdentity
        let account: EffectiveAccount

        private init(publisher: LifecyclePublisher, installation: InstallationIdentity) {
            self.publisher = publisher; self.installation = installation; account = publisher.account
        }
        fileprivate static func capture(_ publisher: LifecyclePublisher) throws -> Self {
            #if SHADOW_SYNC_TESTING
            // Even a signed fixture cannot acquire production policy authority.
            throw PublisherPolicyError.unavailable
            #else
            try publisher.revalidate()
            let installation = try publisher.installationIdentity()
            let source = Self(publisher: publisher, installation: installation)
            try source.revalidate()
            return source
            #endif
        }
        fileprivate static func capture(_ publisher: LifecyclePublisher, installation: InstallationIdentity) throws -> Self {
            #if SHADOW_SYNC_TESTING
            throw PublisherPolicyError.unavailable
            #else
            guard try publisher.installationIdentity() == installation else { throw PublisherPolicyError.unavailable }
            let source = Self(publisher: publisher, installation: installation)
            try source.revalidate()
            return source
            #endif
        }
        func revalidate() throws {
            #if SHADOW_SYNC_TESTING
            throw PublisherPolicyError.unavailable
            #else
            guard publisher.validationProfile == .production,
                  account == publisher.account, account == (try EffectiveAccount.current()),
                  getuid() == account.uid else { throw PublisherPolicyError.unavailable }
            try publisher.revalidate()
            try installation.revalidate()
            try publisher.revalidate()
            #endif
        }
        func requireInstallation(_ expected: InstallationIdentity) throws {
            // Object identity in InstallationIdentity equality excludes a new
            // publisher capture, even for byte-identical candidate metadata.
            guard expected == installation else { throw PublisherPolicyError.unavailable }
            try revalidate()
        }
        func resourceLocation() throws -> (app: String, owner: uid_t, publisher: PublisherCodeVerifier.Identity) {
            try revalidate()
            return (publisher.app, publisher.owner, publisher.appIdentity)
        }
    }

    /// Authentication and external-policy verification only. This creates no
    /// state and supplies neither deployed-prerequisite proof nor activation.
    func policyPrerequisite() throws -> CoordinatorPolicyPrerequisite {
        try CoordinatorPolicyPrerequisite.capture(PolicyResourcesSource.capture(self))
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

/// Retains the exact signed distribution and external configuration through a
/// coordinator handoff. The transaction must call revalidate(for:) on both sides
/// of a handoff and immediately before later activation or repository admission.
/// It must separately obtain the independently deployed prerequisites in ADR 0003
/// and normal repository classification; this value grants neither authority.
final class CoordinatorPolicyPrerequisite {
    private let source: LifecyclePublisher.PolicyResourcesSource
    private let resources: PublisherPolicyResources
    private let policy: RetainedPolicy
    private let revalidation = RevalidationState()

    /// Availability state only: this helper cannot mint publisher authority.
    /// Production and isolated fixtures use the same claim/commit algorithm.
    /// A second in-flight call permanently refuses this handoff rather than
    /// waiting behind unbounded Security/filesystem work. The final commit is
    /// the success linearization point; any earlier refusal defeats it.
    final class RevalidationState {
        private let mutex = NSLock()
        private var inFlight = false
        private var refused = false

        func revalidate(_ validation: () throws -> Void) throws {
            try claim()
            do {
                // Never hold the state mutex across validation or callbacks.
                try validation()
                try commit()
            } catch {
                refuse()
                throw PublisherPolicyError.unavailable
            }
        }
        private func claim() throws {
            mutex.lock(); defer { mutex.unlock() }
            guard !refused && !inFlight else {
                refused = true
                throw PublisherPolicyError.unavailable
            }
            inFlight = true
        }
        private func commit() throws {
            mutex.lock(); defer { mutex.unlock() }
            guard !refused && inFlight else { throw PublisherPolicyError.unavailable }
            inFlight = false
        }
        private func refuse() {
            mutex.lock(); defer { mutex.unlock() }
            // Restoration never re-enables a previously refused handoff.
            refused = true
            inFlight = false
        }
    }

    /// Configuration evidence only, deliberately not a publisher capability.
    /// Constructing this helper cannot construct the enclosing prerequisite.
    /// Production and isolated configuration fixtures share these exact checks.
    struct RetainedPolicy {
        private let snapshot: HostPolicySnapshot
        private let identity: String
        let account: EffectiveAccount
        init(account: EffectiveAccount, contract: QualifiedAWAContract) throws {
            let snapshot = try HostPolicySnapshot.load(account: account, contract: contract)
            self.snapshot = snapshot; self.account = account
            identity = try snapshot.identityCommitment()
            try revalidate()
        }
        func revalidate() throws {
            guard snapshot.account == account,
                  try snapshot.identityCommitment() == identity else { throw HostPolicyBindingError.unavailable }
            try snapshot.revalidate()
        }
    }

    private init(source: LifecyclePublisher.PolicyResourcesSource,
                 resources: PublisherPolicyResources, policy: RetainedPolicy) {
        self.source = source; self.resources = resources; self.policy = policy
    }
    fileprivate static func capture(_ source: LifecyclePublisher.PolicyResourcesSource) throws -> Self {
        #if SHADOW_SYNC_TESTING
        throw PublisherPolicyError.unavailable
        #else
        try source.revalidate()
        let resources = try PublisherPolicyResources.coordinator(source: source)
        // No external binding is read until all publisher/runtime resources pass.
        let contract = try QualifiedAWAContract.decode(resources.contract)
        try resources.revalidate(); try source.revalidate()
        let policy = try RetainedPolicy(account: source.account, contract: contract)
        try resources.revalidate(); try source.revalidate()
        let result = Self(source: source, resources: resources, policy: policy)
        try result.revalidate(for: source.installation)
        return result
        #endif
    }

    func revalidate(for installation: LifecyclePublisher.InstallationIdentity) throws {
        try revalidation.revalidate {
            try source.requireInstallation(installation)
            try resources.revalidate()
            guard policy.account == source.account else { throw PublisherPolicyError.unavailable }
            try policy.revalidate()
            try resources.revalidate()
            try source.requireInstallation(installation)
        }
    }
}

/// One authenticated distribution, original identity and retained policy. There
/// is no path initializer and no testing constructor for production admission.
final class CoordinatorInstallationAdmission {
    let publisher: LifecyclePublisher
    let installation: LifecyclePublisher.InstallationIdentity
    private let policy: CoordinatorPolicyPrerequisite
    let cancellation = InstallationCancellationGate()
    private init(publisher: LifecyclePublisher, installation: LifecyclePublisher.InstallationIdentity,
                 policy: CoordinatorPolicyPrerequisite) {
        self.publisher = publisher; self.installation = installation; self.policy = policy
    }
    static func current() throws -> CoordinatorInstallationAdmission {
        #if SHADOW_SYNC_TESTING
        throw PublisherPolicyError.unavailable
        #else
        return try capture(LifecyclePublisher.current())
        #endif
    }
    private static func capture(_ publisher: LifecyclePublisher) throws -> CoordinatorInstallationAdmission {
        let installation = try publisher.installationIdentity()
        let source = try LifecyclePublisher.PolicyResourcesSource.capture(publisher, installation: installation)
        let policy = try CoordinatorPolicyPrerequisite.capture(source)
        let result = CoordinatorInstallationAdmission(publisher: publisher, installation: installation, policy: policy)
        try result.revalidateForward()
        return result
    }
    func revalidateForward() throws {
        try cancellation.check()
        try policy.revalidate(for: installation)
        // Cancellation can arrive during fallible Security/filesystem work.
        try cancellation.check()
    }
}
