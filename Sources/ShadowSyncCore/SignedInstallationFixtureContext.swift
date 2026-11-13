#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import CryptoKit
import Darwin
import Foundation

/// A retained context for one signed disposable source/case. Nothing in this
/// type creates state, installs an app, launches a child, or mints readiness.
/// Source preflight is separately callable and cannot satisfy installation
/// coverage. Production and ordinary testing builds exclude this file.
final class SignedInstallationFixtureContext {
    static let suite = "signed-installation-source"
    static let sourceCase = "signed-installation/source-preflight"
    static let installationSuite = "signed-installation-adapter"
    static let startupCase = "signed-installation/startup-stop"
    static let cases = [sourceCase] + SignedInstallationFixtureCase.allCases.map(\.rawValue)
    static let contractFD: Int32 = 209
    static let sealRelative = "Contents/Resources/signed-installation-fixture.json"
    static let graphRelative = "Contents/Resources/signed-installation-graph.json"

    /// Inherited bytes bind observations; they do not authenticate executable
    /// code. The actual source is independently checked by Security below.
    struct Request {
        let root: String, nonce: String, source: String, executable: String, app: String
        let bundle: String, release: ReleaseIdentity, appCDHash: String, helperCDHash: String
        let deadline: UInt64
        let caseID: String
        let bytes: Data
        static func consume() throws -> Request {
            let fd = contractFD
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode == S_IFREG | 0o400,
                  before.st_nlink == 0, before.st_uid == geteuid(), before.st_flags == 0,
                  before.st_size > 0, before.st_size <= 16_384,
                  fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY,
                  lseek(fd, 0, SEEK_CUR) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.fenced }
            let acl = try PolicyAuthorityFile.safeACL(fd)
            var data = Data(), block = [UInt8](repeating: 0, count: 4096)
            while data.count <= 16_384 {
                let n = Darwin.read(fd, &block, min(block.count, 16_385 - data.count))
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw CustodyRecordError.fenced }
                if n == 0 { break }; data.append(contentsOf: block.prefix(n))
            }
            guard fstat(fd, &after) == 0, FileIdentity(before) == FileIdentity(after),
                  before.st_size == after.st_size, data.count == before.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  try PolicyAuthorityFile.safeACL(fd) == acl else { throw CustodyRecordError.fenced }
            // Consume the inherited description before parsing. No retry on
            // uncertain close, and no request bytes can create a live profile.
            guard Darwin.close(fd) == 0 else { throw CustodyRecordError.fenced }
            return try decode(data)
        }
        static func decode(_ data: Data) throws -> Request {
            let wire = try CustodyWire.decode(data, maximum: 16_384)
            let fields = try wire.object(keys: ["schema", "case", "root", "nonce", "deadline", "source",
                "executable", "app", "bundle", "release", "appCDHash", "helperCDHash", "rootDisposition"])
            guard try CustodyWire.text(fields["schema"]) == "shadow-sync-signed-installation-request/v1",
                  cases.contains(try CustodyWire.text(fields["case"])),
                  fields["rootDisposition"] == .string("creator-after-coordinator-reap"),
                  try CustodyWire.encode(wire, maximum: 16_384) == data else { throw CustodyRecordError.fenced }
            let value = try Request(root: CustodyWire.text(fields["root"]), nonce: CustodyWire.text(fields["nonce"]),
                source: CustodyWire.text(fields["source"]), executable: CustodyWire.text(fields["executable"]),
                app: CustodyWire.text(fields["app"]), bundle: CustodyWire.text(fields["bundle"]),
                release: ReleaseIdentity.decode(CustodyWire.encode(CustodyWire.required(fields["release"]), maximum: 16_384)),
                appCDHash: CustodyWire.text(fields["appCDHash"]), helperCDHash: CustodyWire.text(fields["helperCDHash"]),
                deadline: CustodyWire.uint(fields["deadline"]), caseID: CustodyWire.text(fields["case"]), bytes: data)
            guard RuntimeSuiteGuardian.hex(value.nonce, count: 32),
                  [value.source, value.executable, value.app, value.bundle].allSatisfy({ RuntimeSuiteGuardian.hex($0, count: 64) }),
                  [value.appCDHash, value.helperCDHash].allSatisfy({ RuntimeSuiteGuardian.hex($0, count: 40) }),
                  value.release.buildMode == "testing",
                  value.release.sourceInputSHA256 == value.source else { throw CustodyRecordError.fenced }
            return value
        }
    }

    /// Pins the actual direct child of /private/tmp and fixed parent nodes.
    /// Revalidation compares named and retained descriptors, including ACLs.
    final class RootPin {
        private struct Node {
            let descriptor: OwnedFileDescriptor
            let identity: FileIdentity
            let acl: String
            let parent: Int32
            let name: String
        }
        let path: String
        var rootIdentity: FileIdentity { nodes[0].identity }
        private let temporary: OwnedFileDescriptor
        private let temporaryIdentity: FileIdentity
        private let nodes: [Node]
        init(root: String, nonce: String) throws {
            let prefix = "/private/tmp/shadow-sync-ic." + nonce + "."
            guard root.hasPrefix(prefix), root.utf8.count == prefix.utf8.count + 6,
                  root.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  try TestIsolation.validateRoot(root) == root else { throw CustodyRecordError.fenced }
            path = root
            let raw = Darwin.open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard raw >= 0 else { throw CustodyRecordError.fenced }
            temporary = OwnedFileDescriptor(raw)
            var parent = stat()
            guard fstat(raw, &parent) == 0, parent.st_uid == 0,
                  parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & S_ISVTX != 0 else { throw CustodyRecordError.fenced }
            temporaryIdentity = FileIdentity(parent)
            func openNode(_ name: String, at parent: Int32) throws -> Node {
                var named = stat(), observed = stat()
                guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_mode == S_IFDIR | 0o700, named.st_uid == geteuid(),
                      named.st_flags == 0, named.st_nlink > 0 else { throw CustodyRecordError.fenced }
                let raw = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard raw >= 0 else { throw CustodyRecordError.fenced }
                let descriptor = OwnedFileDescriptor(raw)
                guard fstat(raw, &observed) == 0, FileIdentity(named) == FileIdentity(observed) else { throw CustodyRecordError.fenced }
                return Node(descriptor: descriptor, identity: FileIdentity(observed),
                    acl: try PolicyAuthorityFile.privateStateACL(raw), parent: parent, name: name)
            }
            let rootNode = try openNode(String(root.dropFirst("/private/tmp/".count)), at: raw)
            nodes = try [rootNode] + ["candidate", "home", "state"].map { try openNode($0, at: rootNode.descriptor.value) }
            try revalidate()
        }
        func revalidate() throws {
            var parent = stat(), namedParent = stat()
            guard fstat(temporary.value, &parent) == 0, lstat("/private/tmp", &namedParent) == 0,
                  FileIdentity(parent).matchesStableNode(temporaryIdentity),
                  FileIdentity(namedParent).matchesStableNode(temporaryIdentity) else { throw CustodyRecordError.fenced }
            for node in nodes {
                var observed = stat(), named = stat()
                guard fstat(node.descriptor.value, &observed) == 0,
                      fstatat(node.parent, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      FileIdentity(observed).matchesStableNode(node.identity),
                      FileIdentity(named).matchesStableNode(node.identity), observed.st_flags == 0,
                      named.st_flags == 0, observed.st_nlink > 0, named.st_nlink > 0,
                      try PolicyAuthorityFile.privateStateACL(node.descriptor.value) == node.acl else { throw CustodyRecordError.fenced }
            }
        }
        func retainHostHome() throws -> OwnedFileDescriptor {
            try revalidate()
            guard let home = nodes.first(where: { $0.name == "home" }) else { throw CustodyRecordError.fenced }
            return OwnedFileDescriptor(try home.descriptor.duplicate(minimum: 214))
        }
        func validateStateDescriptor(_ fd: Int32) throws {
            try revalidate()
            guard let state = nodes.last else { throw CustodyRecordError.fenced }
            var named = stat(), actual = stat()
            guard fstatat(state.descriptor.value, "shadow-sync", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(fd, &actual) == 0, named.st_mode == S_IFDIR | 0o700,
                  named.st_uid == geteuid(), named.st_flags == 0,
                  FileIdentity(named).matchesStableNode(FileIdentity(actual)) else { throw CustodyRecordError.fenced }
            _ = try PolicyAuthorityFile.privateStateACL(fd)
        }
    }

    /// Not Codable and no public/memberwise initializer. Only capture below can
    /// form this exact-release profile, after real Security signature/seal checks.
    final class ReleaseProfile {
        fileprivate let pin: RootPin
        fileprivate enum Lifetime {
            case guardian(RuntimeSuiteGuardian, RuntimeFixtureCustody)
            case inherited(SignedInstallationFixtureParentChannel.Inherited)
            case host(SignedInstallationFixtureHostChannel.Inherited)
        }
        private let lifetime: Lifetime
        private let request: Request
        private let sealed: PolicyAuthorityFile
        private let graph: PolicyAuthorityFile
        private let policyContractFile: PolicyAuthorityFile
        private let policyContract: QualifiedAWAContract
        private let helperCode: PublisherCodeVerifier.Identity
        private let account: EffectiveAccount
        private let slotsMutex = NSLock()
        private var transactionID: String?
        private weak var service: SignedInstallationFixtureService?
        fileprivate init(pin: RootPin, lifetime: Lifetime,
                         request: Request, sealed: PolicyAuthorityFile, graph: PolicyAuthorityFile,
                         policyContractFile: PolicyAuthorityFile, policyContract: QualifiedAWAContract, helperCode: PublisherCodeVerifier.Identity, account: EffectiveAccount) {
            self.pin = pin; self.lifetime = lifetime
            self.request = request; self.sealed = sealed; self.graph = graph; self.helperCode = helperCode; self.account = account
            self.policyContractFile = policyContractFile; self.policyContract = policyContract
        }
        func revalidate() throws {
            switch lifetime {
            case let .guardian(guardian, registry): try guardian.requireActiveCase(request.caseID, registry: registry)
            case let .inherited(parent): try parent.revalidate()
            case let .host(parent): try parent.revalidate()
            }
            guard RuntimeSuiteGuardian.now < request.deadline else { throw CustodyRecordError.busy }
            try pin.revalidate(); try sealed.revalidate(); try graph.revalidate(); try policyContractFile.revalidate()
        }
        /// Call only after the genuine host consumed its durable commit. This
        /// validates configuration bytes; it grants no repository admission.
        func loadCommittedHostPolicy() throws -> HostPolicySnapshot {
            guard case .host = lifetime else { throw CustodyRecordError.fenced }
            try revalidate()
            let isolated = try EffectiveAccount.isolated(homeDirectory: pin.path + "/home")
            try validateDestinationAccount(isolated, publisher: account)
            let snapshot = try HostPolicySnapshot.load(account: isolated, contract: policyContract)
            try snapshot.revalidate(); try revalidate()
            return snapshot
        }
        func adapterCode() throws -> (path: String, identity: PublisherCodeVerifier.Identity, resource: PolicyAuthorityFile) {
            try revalidate()
            return (pin.path + "/candidate/ShadowSync.app" + LifecyclePublisher.relativeExecutable, helperCode, graph)
        }
        var hostParent: SignedInstallationFixtureHostChannel.Inherited? {
            if case let .host(parent) = lifetime { return parent }; return nil
        }
        var inheritedParent: SignedInstallationFixtureParentChannel.Inherited? {
            if case let .inherited(parent) = lifetime { return parent }; return nil
        }
        func makeParentChannel(requestDigest: String) throws -> SignedInstallationFixtureParentChannel {
            // Only the original guardian-backed coordinator exports context.
            // A helper cannot re-export inherited authority to another helper.
            guard case .guardian = lifetime else { throw CustodyRecordError.fenced }
            try revalidate()
            return try SignedInstallationFixtureParentChannel(request: request, requestDigest: requestDigest)
        }
        func bindService(_ value: SignedInstallationFixtureService) throws {
            guard case .guardian = lifetime else { throw CustodyRecordError.fenced }
            slotsMutex.lock(); defer { slotsMutex.unlock() }
            guard service == nil else { throw CustodyRecordError.fenced }; service = value
        }
        func makeAdapterChannel(requestDigest: String, request: UnvalidatedCustodyRequest,
                                binding: InstallationCommandBinding) throws -> SignedInstallationFixtureAdapterChannel {
            guard case .guardian = lifetime else { throw CustodyRecordError.fenced }
            try revalidate()
            slotsMutex.lock(); let service = self.service; slotsMutex.unlock()
            guard let service, binding.validationProfile == .signedFixture(self) else { throw CustodyRecordError.fenced }
            let channel = try SignedInstallationFixtureAdapterChannel(context: self.request, digest: requestDigest,
                kind: request.kind, arguments: request.arguments, binding: binding, service: service,
                deadline: min(self.request.deadline, request.budget.work))
            try channel.start(); return channel
        }
        func makeHostChannel(binding: InstallationCommandBinding) throws -> SignedInstallationFixtureHostChannel {
            guard case .guardian = lifetime else { throw CustodyRecordError.fenced }
            try revalidate(); try binding.validate()
            guard binding.validationProfile == .signedFixture(self) else { throw CustodyRecordError.fenced }
            return try SignedInstallationFixtureHostChannel(request: request, binding: binding)
        }
        var destinationAccount: EffectiveAccount { get throws {
            try revalidate(); return try EffectiveAccount.isolated(homeDirectory: pin.path + "/home")
        } }
        var location: StateLocation { get throws { try StateLocation.isolated(root: pin.path) } }

        func validate(_ release: ReleaseIdentity) throws {
            // Record validation is pure: a decoded record grants no live right.
            // Source/guardian checks belong to the retained owner outside its
            // catalog guard, never to a parser reached while that guard is held.
            try release.validate()
            guard release == request.release, release.buildMode == "testing",
                  release.sourceRevision != String(repeating: "0", count: 40),
                  release.sourceInputSHA256 != String(repeating: "0", count: 64),
                  release.releaseContractSHA256 != String(repeating: "0", count: 64) else { throw CustodyRecordError.fenced }
        }
        func validateCandidate(_ candidate: InstallationCandidate) throws {
            try validate(candidate.release)
            guard candidate.bundleDigest == request.bundle, candidate.appCDHash == request.appCDHash,
                  candidate.coordinatorCDHash == request.helperCDHash else { throw CustodyRecordError.fenced }
        }
        func validateBundlePath(_ path: String) throws {
            try revalidate()
            if path == pin.path + "/candidate/ShadowSync.app" { return }
            slotsMutex.lock(); let transaction = transactionID; slotsMutex.unlock()
            guard let transaction else { throw CustodyRecordError.fenced }
            let parent = pin.path + "/home/Applications/"
            guard ["ShadowSync.app", ".ShadowSync.app.incoming", ".ShadowSync.app.previous",
                   ".ShadowSync.app.incomplete." + transaction].contains(where: { path == parent + $0 }) else {
                throw CustodyRecordError.fenced
            }
        }
        /// Metadata-only narrowing to the one original transaction. This is no
        /// mutation grant; callers still need the owner/journal/inherited leases.
        func bindInstallationSlots(transactionID: String) throws {
            guard RunIdentity.isValid(transactionID) else { throw CustodyRecordError.fenced }
            slotsMutex.lock(); defer { slotsMutex.unlock() }
            guard self.transactionID == nil || self.transactionID == transactionID else { throw CustodyRecordError.fenced }
            self.transactionID = transactionID
        }
        func validateDestinationAccount(_ account: EffectiveAccount, publisher: EffectiveAccount) throws {
            guard publisher == self.account, publisher.uid != 0,
                  account.homeDirectory == pin.path + "/home", account.username == self.account.username,
                  account.uid == publisher.uid else { throw CustodyRecordError.fenced }
        }
        func validateLocation(_ location: StateLocation) throws {
            guard location.anchorPath == pin.path, location.components == ["state", "shadow-sync"],
                  location.uid == account.uid else { throw CustodyRecordError.fenced }
        }
        func validateStateDescriptor(_ fd: Int32) throws {
            // Descriptor metadata only; no publisher/source read or guardian
            // callback enters a catalog-guarded validation through this method.
            try pin.validateStateDescriptor(fd)
        }
    }
    let publisher: LifecyclePublisher
    let source: LifecyclePublisher.InstallationIdentity
    let profile: InstallationValidationProfile
    let paths: InstallationPaths
    var destinationAccount: EffectiveAccount { get throws {
        try revalidate(); return try EffectiveAccount.isolated(homeDirectory: paths.home)
    } }
    let deadline: MonotonicDeadline
    private let pin: RootPin
    private init(publisher: LifecyclePublisher, source: LifecyclePublisher.InstallationIdentity,
                 profile: InstallationValidationProfile, paths: InstallationPaths,
                 deadline: MonotonicDeadline, pin: RootPin) {
        self.publisher = publisher; self.source = source; self.profile = profile
        self.paths = paths; self.deadline = deadline; self.pin = pin
    }
    static func capture(request: Request, guardian: RuntimeSuiteGuardian) throws -> SignedInstallationFixtureContext {
        let registry = try RuntimeFixtureSession.current()
        try guardian.requireActiveCase(request.caseID, registry: registry)
        guard guardian.deadline == request.deadline else { throw CustodyRecordError.fenced }
        try guardian.claimSignedSourceContext(registry: registry, caseID: request.caseID)
        return try captureBound(request: request, lifetime: .guardian(guardian, registry))
    }
    static func captureInherited(_ parent: SignedInstallationFixtureParentChannel.Inherited) throws -> SignedInstallationFixtureContext {
        try parent.revalidate()
        return try captureBound(request: parent.request, lifetime: .inherited(parent))
    }
    private static func captureBound(request: Request, lifetime: ReleaseProfile.Lifetime) throws -> SignedInstallationFixtureContext {
        let retained = try captureProfile(request: request, lifetime: lifetime, runningHost: false)
        let profile = InstallationValidationProfile.signedFixture(retained)
        let publisher = try LifecyclePublisher.current(validationProfile: profile)
        let source = try publisher.installationIdentity()
        try source.candidate.validate(profile: profile)
        let value = try Self(publisher: publisher, source: source, profile: profile,
            paths: InstallationPaths.isolated(root: request.root), deadline: .init(uptimeNanoseconds: request.deadline), pin: retained.pin)
        try value.revalidate(); return value
    }
    static func captureHostProfile(_ inherited: SignedInstallationFixtureHostChannel.Inherited) throws -> InstallationValidationProfile {
        try inherited.revalidate()
        let retained = try captureProfile(request: inherited.request, lifetime: .host(inherited), runningHost: true)
        try retained.bindInstallationSlots(transactionID: inherited.transactionID)
        let profile = InstallationValidationProfile.signedFixture(retained)
        let source = try profile.inspectBundle(inherited.request.root + "/candidate/ShadowSync.app")
        guard source.release == inherited.request.release, source.canonicalSHA256 == inherited.request.bundle else {
            throw CustodyRecordError.fenced
        }
        try inherited.revalidate(); return profile
    }
    private static func captureProfile(request: Request, lifetime: ReleaseProfile.Lifetime,
                                       runningHost: Bool) throws -> ReleaseProfile {
        let pin = try RootPin(root: request.root, nonce: request.nonce)
        let app = request.root + "/candidate/ShadowSync.app"
        let helper = app + LifecyclePublisher.relativeExecutable
        let infoFile = try PolicyAuthorityFile.read(path: app + "/Contents/Info.plist", owner: geteuid(), maximumBytes: 65_536)
        guard let info = try PropertyListSerialization.propertyList(from: infoFile.bytes, format: nil) as? [String: Any],
              info["ShadowSyncSignedFixtureProfile"] as? String == "signed-installation/v1" else { throw CustodyRecordError.fenced }
        let process = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make(), expectedExecutablePath: runningHost ? request.root + "/home/Applications/ShadowSync.app/Contents/MacOS/ShadowSync" : helper)
        guard process.userID == geteuid(), getuid() == geteuid(), geteuid() != 0 else { throw CustodyRecordError.fenced }
        try RuntimeSuiteGuardian.verifyExecutable(helper, digest: request.executable)
        try RuntimeSuiteGuardian.verifyExecutable(app + "/Contents/MacOS/ShadowSync", digest: request.app)
        let (code, appCode) = try PublisherCodeVerifier.verifiedStatic(path: app,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
        try infoFile.revalidate()
        let helperCode: PublisherCodeVerifier.Identity
        if runningHost {
            let (_, running) = try PublisherCodeVerifier.runningApplication(path: request.root + "/home/Applications/ShadowSync.app")
            guard running == appCode else { throw CustodyRecordError.fenced }
            helperCode = try PublisherCodeVerifier.verifiedStatic(path: helper,
                identifier: LifecyclePublisher.identifier, team: appCode.team).1
        } else {
            helperCode = try PublisherCodeVerifier.runningCode(path: helper,
                identifier: LifecyclePublisher.identifier, team: appCode.team).1
        }
        guard appCode.codeDirectory.map({ String(format: "%02x", $0) }).joined() == request.appCDHash,
              helperCode.codeDirectory.map({ String(format: "%02x", $0) }).joined() == request.helperCDHash else { throw CustodyRecordError.fenced }
        let sealed = try PolicyAuthorityFile.read(path: app + "/" + sealRelative, owner: geteuid(), maximumBytes: 16_384)
        try PublisherCodeVerifier.sealed(sealed, relativePath: "Resources/signed-installation-fixture.json", code: code)
        let fields = try CustodyWire.decode(sealed.bytes, maximum: 16_384).object(keys: ["schema", "source", "cases"])
        guard try CustodyWire.text(fields["schema"]) == "shadow-sync-signed-installation-package/v1",
              try CustodyWire.text(fields["source"]) == request.source,
              try CustodyWire.array(fields["cases"]) == cases.map(PolicyWireValue.string) else { throw CustodyRecordError.fenced }
        let graph = try PolicyAuthorityFile.read(path: app + "/" + graphRelative, owner: geteuid(), maximumBytes: 16_384)
        try PublisherCodeVerifier.sealed(graph, relativePath: "Resources/signed-installation-graph.json", code: code)
        let graphWire = try CustodyWire.decode(graph.bytes, maximum: 16_384)
        let graphFields = try graphWire.object(keys: ["schema", "source", "identifier", "cdhash", "behavior", "roles"])
        guard graphFields["schema"] == .string("shadow-sync-signed-installation-graph/v1"),
              graphFields["source"] == .string(request.source),
              graphFields["identifier"] == .string(LifecyclePublisher.identifier),
              graphFields["cdhash"] == .string(request.helperCDHash),
              graphFields["behavior"] == .string("single-image-no-descendants"),
              graphFields["roles"] == .array([.string("service-read"), .string("service-mutation"), .string("signature-check")]),
              try CustodyWire.encode(graphWire, maximum: 16_384) == graph.bytes else { throw CustodyRecordError.fenced }
        let policyContractFile = try PolicyAuthorityFile.read(path: app + "/Contents/Resources/awa-contract.json",
            owner: geteuid(), maximumBytes: 16_384)
        try PublisherCodeVerifier.sealed(policyContractFile, relativePath: "Resources/awa-contract.json", code: code)
        let policyContract = try QualifiedAWAContract.decode(policyContractFile.bytes)
        return ReleaseProfile(pin: pin, lifetime: lifetime, request: request, sealed: sealed,
            graph: graph, policyContractFile: policyContractFile, policyContract: policyContract,
            helperCode: helperCode, account: try EffectiveAccount.current())
    }

    func retainHostHome() throws -> OwnedFileDescriptor {
        try revalidate(); return try pin.retainHostHome()
    }
    func retainRootCustody() throws -> InstallationReadinessFixtureCustody {
        try revalidate()
        let custody = try InstallationReadinessFixtureCustody(retainingExternalRoot: pin)
        try RuntimeFixtureSession.registerInstallationRoot(custody)
        return custody
    }
    func revalidate() throws {
        try pin.revalidate(); try profile.revalidate(); try publisher.revalidate(); try source.revalidate()
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
    }
}

/// Closed, source-only preflight. This is not an installation suite and has no
/// authority to claim startup, stop, retirement, launchd or installed acceptance.
enum SignedInstallationFixtureSourceEntrypoint {
    static func dispatch(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--verify-signed-installation-fixture-source") else { return nil }
        guard arguments.count == 2, arguments[1] == "--verify-signed-installation-fixture-source" else { return 64 }
        do {
            try requireInheritedManifest()
            let request = try SignedInstallationFixtureContext.Request.consume()
            guard request.caseID == SignedInstallationFixtureContext.sourceCase else { throw CustodyRecordError.fenced }
            let guardian = try RuntimeSuiteGuardian(suite: SignedInstallationFixtureContext.suite,
                cases: [SignedInstallationFixtureContext.sourceCase], nonce: request.nonce, deadline: request.deadline,
                source: request.source, executable: request.executable, app: request.app, probeTarget: nil)
            try RuntimeFixtureSession.installGuardian(guardian)
            defer { RuntimeFixtureSession.removeGuardian(guardian) }
            return guardian.execute {
                try RuntimeFixtureSession.withCase(SignedInstallationFixtureContext.sourceCase) {
                    let context = try SignedInstallationFixtureContext.capture(request: request, guardian: guardian)
                    try context.revalidate()
                    // Test the actual signed candidate through the explicit
                    // profile and independently prove ordinary decode refuses it.
                    let decoded = try InstallationCandidate(wire: context.source.candidate.wire, profile: context.profile)
                    guard decoded == context.source.candidate else { throw CustodyRecordError.fenced }
                    do {
                        _ = try InstallationCandidate(wire: context.source.candidate.wire)
                        throw RuntimeSuiteGuardian.Failure.invalidContract
                    } catch is ReleaseIdentityError {
                        // Production release validation refused testing metadata.
                    }
                }
                return true
            }
        } catch { return 78 }
    }
    static func requireInheritedManifest() throws {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0, size < 65_536 else { throw CustodyRecordError.fenced }
        var rows = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 32)
        let capacity = rows.count * MemoryLayout<proc_fdinfo>.stride
        let count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &rows, Int32(capacity))
        guard count > 0, count < capacity, Int(count) % MemoryLayout<proc_fdinfo>.stride == 0 else { throw CustodyRecordError.fenced }
        let descriptors = Set(rows.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd))
        guard descriptors == [0, 1, 2, RuntimeSuiteGuardian.controlFD, RuntimeSuiteGuardian.statusFD,
                              SignedInstallationFixtureContext.contractFD] else { throw CustodyRecordError.fenced }
        for fd in descriptors { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyRecordError.fenced } }
    }
}
#endif
