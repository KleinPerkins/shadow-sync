#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation
import Security
import ShadowSyncCatalog

/// Real caller/helper transport with isolated, explicitly synthetic policy and
/// ad-hoc fixture resources. Passing never enrolls a production command graph.
public enum DiscoveryCallerSelfTestRunner {
    private enum Failure: Error { case assertion(String) }

    public static func runAll(onPass: (String) -> Void) throws {
        for present in [false, true] {
            let id = present ? "DISCOVERY-CALLER-T02-present-system-and-user-config"
                : "DISCOVERY-CALLER-T01-absent-system-and-user-config"
            try RuntimeFixtureSession.withCase(id) {
                let fixture = try Fixture(systemConfiguration: present)
                var failure: Error?
                enum Stage: String { case session, catalog, selection, discovery, cleanupCheck }
                var stage = Stage.session
                do {
                    let session = try fixture.session()
                    let binder = try session.binder(revalidatePhase: fixture.context.phaseAdmissionCheck())
                    stage = .catalog
                    let catalog = try binder.processFreeCatalog(preferences: nil, generation: 1)
                    try require(catalog.isComplete, "real-helper catalog incomplete: \(String(describing: catalog.degradedReason)) elapsed_ns=\(catalog.catalog.elapsedNanoseconds)")
                    guard let ready = catalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }) else {
                        throw Failure.assertion("real-helper catalog lost fixture repository")
                    }
                    stage = .selection
                    let scope = try binder.bind(intent: RepositorySelectionIntent(catalog: catalog.catalog,
                        entries: [try ready.preferenceEntry]))
                    stage = .discovery
                    let rows = try RepositoryDiscovery().discover(scope: scope, binder: binder,
                        cancellation: fixture.cancellation)
                    try require(rows.count == 1 && rows[0].id == "fixture-owner/ready"
                        && rows[0].path == fixture.repository && rows[0].isEligible
                        && rows[0].cachedMainRelation == .equal,
                        "real-helper discovery did not preserve inspection: \(rows)")
                    stage = .cleanupCheck
                    try require(RetainedCleanupRegistry.shared.testingCount == 0,
                        "real-helper discovery left retained commands")
                } catch { failure = error }
                if let failure {
                    fputs("DISCOVERY CALLER BODY FAILURE stage=\(stage.rawValue): \(failure)\n", stderr); fflush(stderr)
                }
                do { try fixture.remove(expectDiscovery: failure == nil) }
                catch {
                    throw Failure.assertion("body=\(String(describing: failure)); cleanup=\(error)")
                }
                if let failure { throw failure }
            }
            onPass(id)
        }
    }

    /// Separate diagnostic suite: never warms or extends a discovery deadline.
    /// It exercises fresh authenticated factories; timings are observations, not
    /// performance acceptance thresholds or production publisher qualification.
    public static func runBootstrapProfile(onPass: (String) -> Void) throws {
        let id = "DISCOVERY-BOOTSTRAP-T01-repeatable-authenticated-construction"
        try RuntimeFixtureSession.withCase(id) {
            let fixture = try BootstrapFixture()
            var failure: Error?
            do {
                for trial in 0..<3 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let helper = try CustodyHelperExecutable.testingDiscovery(home: fixture.home)
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    let publisher = try PublisherPolicyResources.testingDiscovery(account: fixture.account)
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    let snapshot = try HostPolicySnapshot.load(account: fixture.account,
                        contract: QualifiedAWAContract.decode(publisher.contract))
                    let t3 = DispatchTime.now().uptimeNanoseconds
                    let authority = try PolicyCommandAuthority(snapshot: snapshot, publisher: publisher, helper: helper)
                    let t4 = DispatchTime.now().uptimeNanoseconds
                    try authority.revalidate()
                    let t5 = DispatchTime.now().uptimeNanoseconds
                    _ = try helper.authenticateParent(getpid(), generation: RunIdentity.make())
                    let t6 = DispatchTime.now().uptimeNanoseconds
                    try require(publisher.adapter == fixture.publisher.adapter
                        && publisher.contract == fixture.publisher.contract
                        && snapshot.identityCommitment() == fixture.snapshot.identityCommitment(),
                        "fresh authenticated bootstrap changed bound resources")
                    print("METRIC discovery-bootstrap trial=\(trial) helper_ns=\(t1-t0) publisher_ns=\(t2-t1) snapshot_ns=\(t3-t2) authority_ns=\(t4-t3) revalidate_ns=\(t5-t4) parent_ns=\(t6-t5)")
                }
            } catch { failure = error }
            do { try fixture.remove() }
            catch { throw Failure.assertion("bootstrap=\(String(describing: failure)); cleanup=\(error)") }
            if let failure { throw failure }
        }
        onPass(id)
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    private static func codeHash(_ path: String) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { throw Failure.assertion("fixture tool code unavailable") }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data,
              hash.count == 20 else { throw Failure.assertion("fixture tool code hash unavailable") }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ path: String, _ bytes: Data) throws {
        try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        try require(chmod(path, 0o600) == 0, "fixture input permissions")
    }

    /// Shared resource bytes only; creates no command context or subprocess.
    private static func installPolicyResources(home: String, framework: String, sourcePath: String)
        throws -> (account: EffectiveAccount, snapshot: HostPolicySnapshot) {
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let contract = try HostPolicySnapshotSelfTestRunner.installDiscoveryFixture(home: home)
        let resources = home + "/.shadow-sync-fixture"
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try write(resources + "/framework-location.json", json([
            "schema": "shadow-sync-discovery-fixture/v1", "path": framework]))
        try write(resources + "/awa-contract.json", contract)
        try write(resources + "/policy-runtime-source.json", Data(contentsOf: URL(fileURLWithPath: sourcePath)))
        let pin = try QualifiedAWAContract.decode(contract)
        let snapshot = try HostPolicySnapshot.load(account: account, contract: pin)
        let adapter = """
        import json,sys
        def run_sealed(contract):
            request=json.load(sys.stdin)
            rows=[{'index':i,'matched':False,'kind':'none','policy_valid':True}
                  for i,path in enumerate(request['candidates'])]
            print(json.dumps({'schema':'shadow-sync-policy-batch-response/v1',
                'nonce':request['nonce'],'binding_sha256':request['binding_sha256'],
                'policy_sha256':'\(snapshot.binding.policy.sha256)',
                'module_sha256':'\(snapshot.binding.module.sha256)','results':rows}))
            return 0
        """
        try write(resources + "/PolicyAdapter.py", Data(adapter.utf8))
        var buildBytes = [CChar](repeating: 0, count: 64), buildSize = 64
        try require(sysctlbyname("kern.osversion", &buildBytes, &buildSize, nil, 0) == 0
            && (2...64).contains(buildSize) && buildBytes[buildSize - 1] == 0, "fixture system build")
        let build = String(decoding: buildBytes.prefix(buildSize - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let graphs: [[String: Any]] = try [CommandGraphCatalog.Adapter.policyClassify, .systemGitConfig, .discoveryGit].map { kind in
            let tools = try kind.paths.map { path in
                ["path": path, "cdhash": try codeHash(kind == .policyClassify
                    ? framework + "/" + PolicyRuntimeLayout.interpreter : path)]
            }
            return ["adapter": kind.rawValue, "architecture": "arm64", "system_build": build,
                "qualification_sha256": digest(Data("synthetic fixture only; no production qualification".utf8)),
                "tools": tools]
        }
        try write(resources + "/command-graphs.json", json(["schema": "shadow-sync-command-graphs/v1", "graphs": graphs]))
        return (account, snapshot)
    }

    /// Diagnostic ownership is limited to its newly created private resource tree.
    private final class BootstrapFixture {
        let root: String, home: String
        let account: EffectiveAccount
        let publisher: PublisherPolicyResources
        let snapshot: HostPolicySnapshot
        private let identity: FileIdentity
        private var removed = false

        init() throws {
            try require(RetainedCleanupRegistry.shared.testingCount == 0, "fixture requires exclusive empty registry")
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/shadow-sync-"), sourcePath.hasPrefix("/private/tmp/shadow-sync-") else {
                throw Failure.assertion("explicit fixture runtime resources missing")
            }
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-authority-") + "XXXXXX").utf8CString)
            guard let created = mkdtemp(&template) else { throw Failure.assertion("discovery fixture create") }
            let root = String(cString: created), home = root + "/home"
            var info = stat()
            try require(lstat(root, &info) == 0 && info.st_uid == geteuid()
                && info.st_mode & 0o777 == 0o700, "discovery fixture root identity")
            let identity = FileIdentity(info)
            do {
                try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                let installed = try installPolicyResources(home: home, framework: framework, sourcePath: sourcePath)
                let publisher = try PublisherPolicyResources.testingDiscovery(account: installed.account)
                self.root = root; self.home = home; self.identity = identity
                self.account = installed.account; self.snapshot = installed.snapshot; self.publisher = publisher
            } catch {
                var current = stat()
                try require(lstat(root, &current) == 0 && FileIdentity(current).matchesStableNode(identity),
                    "failed fixture identity changed; retained")
                try FileManager.default.removeItem(atPath: root)
                throw error
            }
        }

        func remove() throws {
            if removed { return }
            try require(RetainedCleanupRegistry.shared.testingCount == 0,
                "bootstrap unexpectedly retained a command; fixture retained")
            var info = stat()
            try require(lstat(root, &info) == 0 && FileIdentity(info).matchesStableNode(identity),
                "discovery fixture cleanup identity changed; retained")
            try FileManager.default.removeItem(atPath: root)
            removed = true
        }
    }

    private final class Fixture {
        let root: String, home: String, repository: String
        let account: EffectiveAccount
        let context: CommandCustodyContext
        let publisher: PublisherPolicyResources
        let snapshot: HostPolicySnapshot
        let cancellation = CancellationToken()
        private let directory: Int32
        private let identity: FileIdentity
        private var removed = false

        init(systemConfiguration: Bool) throws {
            try require(RetainedCleanupRegistry.shared.testingCount == 0, "fixture requires exclusive empty registry")
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/shadow-sync-"), sourcePath.hasPrefix("/private/tmp/shadow-sync-") else {
                throw Failure.assertion("explicit fixture runtime resources missing")
            }
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-authority-") + "XXXXXX").utf8CString)
            guard let created = mkdtemp(&template) else { throw Failure.assertion("discovery fixture create") }
            let root = String(cString: created), home = root + "/home"
            var info = stat()
            try require(lstat(root, &info) == 0 && info.st_uid == geteuid()
                && info.st_mode & 0o777 == 0o700, "discovery fixture root identity")
            let identity = FileIdentity(info)
            var directory: Int32 = -1
            do {
                try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.createDirectory(atPath: root + "/owner-resources", withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                let installed = try installPolicyResources(home: home, framework: framework, sourcePath: sourcePath)
                let account = installed.account, snapshot = installed.snapshot
                let resources = home + "/.shadow-sync-fixture"
                if systemConfiguration {
                    try write(resources + "/fixture-system-config", Data("[core]\nignorecase = false\n".utf8))
                    try write(home + "/.gitconfig", Data("[user]\nname = Fixture User\n".utf8))
                }
                let repository = home + "/workspace/products/ready"
                try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(directory >= 0, "fixture scratch descriptor")
                let runner = ClosedProcessRunner()
                func git(_ args: [String]) throws {
                    let result = try runner.run(command: ClosedProcessCommand(
                        executable: "/Library/Developer/CommandLineTools/usr/bin/git", arguments: args),
                        environment: ClosedProcessRunner.environment(account: account),
                        workingDirectoryDescriptor: directory, account: account, timeout: 10,
                        cancellation: CancellationToken())
                    try require(result.succeeded, "fixture setup Git failed: \(result.diagnostic)")
                }
                try git(["init", "--quiet", "--initial-branch=main", repository])
                try write(repository + "/value.txt", Data("fixture\n".utf8))
                try git(["-C", repository, "add", "value.txt"])
                try git(["-C", repository, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--quiet", "-m", "fixture"])
                try git(["-C", repository, "remote", "add", "origin", "https://github.com/fixture-owner/ready.git"])
                try git(["-C", repository, "update-ref", "refs/remotes/origin/main", "HEAD"])
                try git(["-C", repository, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
                let location = try StateLocation.isolated(root: root)
                try TestIsolation.initializeState(at: location)
                let initialOwner = try RunAuthority.acquireRun(at: location)
                do {
                    try CustodyCatalogStore.testingInitialize(leases: initialOwner.retainCommandLeases(), root: root)
                } catch {
                    initialOwner.release()
                    throw error
                }
                initialOwner.release()
                let publisher = try PublisherPolicyResources.testingDiscovery(account: account)
                let context = try CommandCustodyContext.testing(leases: CustodyAuthorityLeaseSet.retainReadLeases(at: location),
                    location: location, root: root, discoveryFixture: true)
                self.root = root; self.home = home; self.repository = repository; self.identity = identity
                self.directory = directory; self.account = account; self.context = context
                self.publisher = publisher; self.snapshot = snapshot
            } catch {
                if directory >= 0 { close(directory) }
                var current = stat()
                try require(lstat(root, &current) == 0 && FileIdentity(current).matchesStableNode(identity),
                    "failed fixture identity changed; retained")
                try FileManager.default.removeItem(atPath: root)
                throw error
            }
        }

        func session() throws -> PolicyCatalogSession {
            try PolicyCatalogSession(snapshot: snapshot, publisher: publisher, context: context,
                scratchDescriptor: directory, cancellation: cancellation)
        }

        func remove(expectDiscovery: Bool) throws {
            if removed { return }
            context.close()
            var reported = false
            let diagnostic = MonotonicDeadline(seconds: 6)
            while !RetainedCleanupRegistry.shared.testingOriginalHelpersReaped {
                if diagnostic.hasExpired && !reported {
                    fputs("DISCOVERY FIXTURE ORIGINAL HELPER DRAIN PENDING\n", stderr)
                    fflush(stderr); reported = true
                }
                usleep(10_000)
            }
            // A reaped helper is not proof of resource retirement. Never dispose
            // pending transactions or erase their evidence to make cleanup pass.
            try require(RetainedCleanupRegistry.shared.testingCount == 0
                && context.testingScope.observation == .terminal
                && context.testingScope.testingRead().entries.isEmpty,
                "discovery cleanup unresolved; fixture and transaction evidence retained at \(root)")
            let receipts = try StateLocation.isolated(root: root).path + "/custody/receipts"
            var discoveryCount = 0
            let names = try FileManager.default.contentsOfDirectory(atPath: receipts)
            let journalNames = names.filter {
                !$0.hasSuffix(".caller.json") && !$0.hasPrefix("discovery-resource-")
            }
            var expectedNames = Set<String>()
            for name in journalNames {
                try require(name.hasSuffix(".json") && RunIdentity.isValid(String(name.dropLast(5))), "unexpected fixture receipt")
                expectedNames.insert(name)
                expectedNames.insert(String(name.dropLast(5)) + ".caller.json")
                let file = try PolicyAuthorityFile.read(path: receipts + "/" + name, owner: account.uid, maximumBytes: 65_536)
                let wire = try CustodyWire.decode(file.bytes, maximum: 65_536)
                guard case .object(let fields) = wire, let journalWire = fields["journal"] else {
                    throw Failure.assertion("malformed fixture receipt; evidence retained")
                }
                let journal = try CustodyJournal.decode(CustodyWire.encode(journalWire, maximum: CustodyJournal.maximumBytes))
                let journalDigest = CustodyRecordBinding.digest(try journal.encode())
                try require(journal.phase == .terminal && journal.binding.scopeID == context.id
                    && name == journal.binding.requestID + ".json"
                    && CustodyWire.text(fields["journal_sha256"]) == journalDigest, "fixture terminal receipt binding")
                let callerFile = try PolicyAuthorityFile.read(path: receipts + "/" + journal.binding.requestID + ".caller.json",
                    owner: account.uid, maximumBytes: 65_536)
                let caller = try CustodyWire.decode(callerFile.bytes, maximum: 65_536).object(keys:
                    ["schema", "binding", "journal_sha256", "event", "custodian", "wait_status", "observer"])
                guard let callerBinding = caller["binding"] else { throw Failure.assertion("missing caller binding") }
                try require(CustodyWire.text(caller["schema"]) == "shadow-sync-custody-caller/v1"
                    && CustodyRecordBinding(wire: callerBinding) == journal.binding
                    && CustodyWire.text(caller["journal_sha256"]) == journalDigest
                    && ["custodian-reaped", "never-resumed-reaped", "no-successful-spawn"].contains(CustodyWire.text(caller["event"])),
                    "caller observation binding; evidence retained")
                if journal.kind == .discoveryGit {
                    guard let resourceWire = fields["discovery_resource"] else { throw Failure.assertion("missing resource receipt") }
                    let resource = try DiscoveryResourceReceipt.decode(CustodyWire.encode(resourceWire, maximum: DiscoveryResourceReceipt.maximumBytes))
                    try require(resource.binding == journal.binding && resource.phase == .retired, "unretired resource; evidence retained")
                    // The catalog intentionally retains a resource sidecar as
                    // well as embedding it in the terminal journal receipt.
                    // Require the exact three-way binding, not just its name.
                    let resourceName = "discovery-resource-" + journal.binding.requestID + ".json"
                    let resourceFile = try PolicyAuthorityFile.read(path: receipts + "/" + resourceName,
                        owner: account.uid, maximumBytes: DiscoveryResourceReceipt.maximumBytes)
                    try require(DiscoveryResourceReceipt.decode(resourceFile.bytes) == resource
                        && CustodyWire.text(fields["discovery_resource_sha256"])
                            == CustodyRecordBinding.digest(try resource.encode()),
                        "resource sidecar binding; evidence retained")
                    expectedNames.insert(resourceName)
                    let path = try DiscoveryFixtureResources.resourcePaths(home: home, requestID: journal.binding.requestID)[0]
                    var info = stat()
                    try require(lstat(path, &info) != 0 && errno == ENOENT, "retired resource still present; evidence retained")
                    discoveryCount += 1
                }
            }
            try require(Set(names) == expectedNames && names.count == expectedNames.count,
                "unpaired or orphan fixture receipt; evidence retained")
            try require(!expectDiscovery || discoveryCount > 0, "actual discovery receipts missing")
            try require(FileManager.default.contentsOfDirectory(atPath: root + "/owner-resources").isEmpty,
                "unresolved fixture resource retained")
            var info = stat()
            try require(lstat(root, &info) == 0 && FileIdentity(info).matchesStableNode(identity),
                "discovery fixture cleanup identity changed; retained")
            try require(close(directory) == 0, "discovery fixture scratch close")
            try FileManager.default.removeItem(atPath: root)
            removed = true
        }
    }
}
#endif
