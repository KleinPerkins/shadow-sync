#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation
import ShadowSyncCatalog

public enum HostPolicySnapshotSelfTestRunner {
    private enum Failure: Error { case assertion(String) }

    /// Shared synthetic policy bytes for the real discovery transport fixture.
    /// This does not qualify the deployed AWA module or host policy.
    enum DiscoveryFixtureLayout: Equatable { case products, body3 }

    static func installDiscoveryFixture(home: String, layout: DiscoveryFixtureLayout = .products) throws -> Data {
        _ = try EffectiveAccount.isolated(homeDirectory: home)
        let fixture = try Fixture(layout: layout)
        do {
            for (name, data) in fixture.contents {
                let target = home + "/" + name
                try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: target).deletingLastPathComponent().path,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
                try require(chmod(target, 0o600) == 0, "discovery policy fixture permissions")
            }
            let contract = try json(["schema": "shadow-sync-awa-contract/v1", "status": "qualified",
                "release_revision": String(repeating: "a", count: 40),
                "module_sha256": digest(fixture.contents["runtime/policy.py"]!)])
            try fixture.remove()
            return contract
        } catch {
            try fixture.remove()
            throw error
        }
    }

    public static func runAll(onPass: (String) -> Void) throws {
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T01-coherent-source-bound-configuration") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let snapshot = try HostPolicySnapshot.load(account: account, contract: contract)
            try snapshot.revalidate()
            try require(snapshot.projection.rootComponents == ["workspace"]
                && snapshot.bindingSHA256 == digest(fixture.contents[Fixture.binding]!)
                && snapshot.admissionSHA256.count == 64, "snapshot binding changed")
            try require(try HostPolicySnapshot.load(account: account, contract: contract).admissionSHA256
                        == snapshot.admissionSHA256, "stable admission changed")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T01-coherent-source-bound-configuration")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T02-every-source-drift-revokes-snapshot") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            // All six control documents participate in both initial digest checks
            // and subsequent identity checks. Nothing is silently regenerated.
            for name in fixture.contents.keys.sorted() {
                let current = try HostPolicySnapshot.load(account: account, contract: contract)
                try fixture.write(name, fixture.contents[name]! + Data("\n".utf8))
                try refuse { try current.revalidate() }
                try fixture.restore()
            }
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T02-every-source-drift-revokes-snapshot")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T03-stale-generated-and-runtime-bytes-refuse") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            for name in fixture.contents.keys.sorted().filter({ $0 != Fixture.binding }) {
                try fixture.write(name, Data("different input\n".utf8))
                try refuse { _ = try HostPolicySnapshot.load(account: account, contract: contract) }
                try fixture.restore()
            }
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T03-stale-generated-and-runtime-bytes-refuse")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T04-incomplete-deployment-refuses") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            for name in fixture.contents.keys.sorted() {
                let path = fixture.path + "/" + name
                try require(unlink(path) == 0, "remove fixture input")
                try refuse { _ = try HostPolicySnapshot.load(account: account, contract: contract) }
                try fixture.restore()
            }
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T04-incomplete-deployment-refuses")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T05-malformed-binding-projection-and-pin") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            for bad: [String: Any] in [["schema": "shadow-sync-host-policy-binding/v2"],
                                      ["schema": "shadow-sync-host-policy-binding/v1", "unknown": true]] {
                try fixture.write(Fixture.binding, json(bad))
                try refuse { _ = try HostPolicySnapshot.load(account: account, contract: contract) }
            }
            try fixture.restore()
            let wrongContract = try fixture.contract(moduleDigest: String(repeating: "e", count: 64))
            try refuse { _ = try HostPolicySnapshot.load(account: account, contract: wrongContract) }
            var badProjection = fixture.projection
            badProjection["shelves"] = [["parent"], ["parent", "nested"]]
            let bytes = try json(badProjection)
            try fixture.write("owner/projection.json", bytes)
            var binding = fixture.binding
            binding["projection"] = ["path": "owner/projection.json", "sha256": digest(bytes)]
            try fixture.write(Fixture.binding, json(binding))
            try refuse { _ = try HostPolicySnapshot.load(account: account, contract: contract) }
            try fixture.restore()
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T05-malformed-binding-projection-and-pin")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T06-identical-byte-replacement-invalidates-old-snapshot") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let before = try HostPolicySnapshot.load(account: account, contract: contract)
            let input = fixture.path + "/owner/overlay.json"
            let replacement = fixture.path + "/owner/replacement"
            try fixture.write("owner/replacement", fixture.contents["owner/overlay.json"]!)
            try require(rename(replacement, input) == 0, "replace source input")
            try refuse { try before.revalidate() }
            _ = try HostPolicySnapshot.load(account: account, contract: contract)
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T06-identical-byte-replacement-invalidates-old-snapshot")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T07-unsafe-authority-inputs-refuse") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let input = fixture.path + "/owner/overlay.json"
            let alias = fixture.path + "/owner/overlay-alias"
            try require(rename(input, alias) == 0 && symlink(alias, input) == 0, "source symlink fixture")
            try refuse { _ = try HostPolicySnapshot.load(account: account, contract: contract) }
            try require(unlink(input) == 0 && rename(alias, input) == 0, "restore source symlink fixture")
            try require(chmod(input, 0o622) == 0, "unsafe source permissions")
            try refuse { _ = try HostPolicySnapshot.load(account: account, contract: contract) }
            try require(chmod(input, 0o600) == 0, "restore source permissions")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T07-unsafe-authority-inputs-refuse")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T08-no-candidate-authority-or-module-execution") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            // The module bytes intentionally are not valid Python. Snapshot loading
            // is configuration verification, never module execution/classification.
            _ = try HostPolicySnapshot.load(account: account, contract: contract)
            try require(!FileManager.default.fileExists(atPath: fixture.path + "/workspace"),
                        "snapshot touched or generated a candidate root")
            let otherAccount = EffectiveAccount(uid: geteuid() + 1, username: "fixture-account", homeDirectory: fixture.path)
            try refuse { _ = try HostPolicySnapshot.load(account: otherAccount, contract: contract) }
            try require(String(describing: HostPolicyBindingError.unavailable)
                == "Repository policy configuration is unavailable.", "configuration diagnostic leaked")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T08-no-candidate-authority-or-module-execution")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T09-bound-operation-policy-and-protected-identity") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let current = try HostPolicySnapshot.load(account: account, contract: contract)
            let policy = try RepositoryPolicy(snapshot: current)
            let protectedOrigin = GitHubIdentity.parse("https://github.com/fixture-owner/protected.git")
            let ordinaryOrigin = GitHubIdentity.parse("git@github.com:fixture-owner/ordinary.git")
            try require(policy.admissionSHA256 == current.admissionSHA256
                && policy.identityBlockReason(origin: protectedOrigin) == .permanentNoTouch
                && policy.identityBlockReason(origin: ordinaryOrigin) == nil
                && policy.excludes(relativePath: "products/ordinary", origin: protectedOrigin)
                && policy.managedPreCommitDispatcher == current.projection.hookDispatcher,
                "bound policy projection weakened identity or hook protection")
            let projection = current.projection
            let expected = try RepositorySelectionPolicy(shelfPaths: projection.shelves,
                excludedPaths: projection.paths.excluded, readOnlyPaths: projection.paths.readOnly,
                artifactPaths: projection.paths.artifacts, writablePaths: projection.paths.writable,
                permanentNoTouchRepositoryIDs: Set(projection.permanentNoTouchRepositoryIDs),
                digest: current.admissionSHA256)
            for path in [".", "products", "products/ordinary", "readonly/example", "blocked/example"] {
                let projected = expected.disposition(relativePath: path)
                let actual = policy.pathDisposition(relativePath: path)
                try require((projected == .writable && actual == .allowed)
                    || (projected == .excluded && actual == .excluded)
                    || (projected == .readOnlyReference && actual == .readOnlyReference)
                    || (projected == .artifact && actual == .artifact),
                    "catalog and operation policy disagree")
            }
            try fixture.write("owner/overlay.json", fixture.contents["owner/overlay.json"]! + Data("\n".utf8))
            try refuse { _ = try RepositoryPolicy(snapshot: current) }
            try fixture.restore()
            try require(!FileManager.default.fileExists(atPath: fixture.path + "/workspace"),
                        "operation policy projection touched a candidate root")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T09-bound-operation-policy-and-protected-identity")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T10-bound-governed-root-role-refuses-stale-or-missing-policy") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let roleSnapshot = try HostPolicySnapshot.load(account: account, contract: contract)
            let role = try GovernedRootRole(snapshot: roleSnapshot)
            try require(role.repositoryID == "fixture-owner/root"
                && role.policyDigest == roleSnapshot.admissionSHA256,
                "governed-root role did not come from the bound projection")
            let scope = ValidatedSelectedRepositoryScope(selectionGeneration: 1,
                policyDigest: role.policyDigest, catalogGeneration: 1, repositories: [],
                governedRootRole: role)
            try require(try scope.requireGovernedRootRole() == role, "scope lost bound role")
            for missing in [nil, GovernedRootRole.testing(policyDigest: String(repeating: "f", count: 64))] {
                let invalid = ValidatedSelectedRepositoryScope(selectionGeneration: 1,
                    policyDigest: role.policyDigest, catalogGeneration: 1, repositories: [],
                    governedRootRole: missing)
                do {
                    _ = try invalid.requireGovernedRootRole()
                    throw Failure.assertion("missing or stale governed-root role was accepted")
                } catch SelectedRepositoryScopeError.policyUnavailable {}
            }
            try fixture.write("owner/overlay.json", fixture.contents["owner/overlay.json"]! + Data("\n".utf8))
            try refuse { _ = try GovernedRootRole(snapshot: roleSnapshot) }
            try fixture.restore()
            try require(!FileManager.default.fileExists(atPath: fixture.path + "/workspace"),
                        "governed-root role accessed a candidate")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T10-bound-governed-root-role-refuses-stale-or-missing-policy")

        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T11-cross-process-identity-stable-under-sibling-change") {
            let fixture = try Fixture(); defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let before = try HostPolicySnapshot.load(account: account, contract: contract)
            let identity = try before.identityCommitment()
            try fixture.write("owner/unrelated-sibling", Data("unrelated fixture".utf8))
            let after = try HostPolicySnapshot.load(account: account, contract: contract)
            try require(try identity == before.identityCommitment() && identity == after.identityCommitment(),
                        "unrelated sibling changed policy identity commitment")
            try require(identity.count == 64 && identity != before.admissionSHA256,
                        "policy identity commitment collapsed to content digest")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T11-cross-process-identity-stable-under-sibling-change")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T12-identical-bytes-new-inode-changes-handoff") {
            let fixture = try Fixture(); defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            for name in fixture.contents.keys.sorted() {
                let before = try HostPolicySnapshot.load(account: account, contract: contract)
                let identity = try before.identityCommitment()
                try fixture.write("replacement", fixture.contents[name]!)
                try require(rename(fixture.path + "/replacement", fixture.path + "/" + name) == 0,
                            "replace identical fixture authority input")
                let after = try HostPolicySnapshot.load(account: account, contract: contract)
                try require(before.admissionSHA256 == after.admissionSHA256,
                            "identical content changed policy admission digest")
                try require(try identity != after.identityCommitment(),
                            "replacement inode preserved cross-process policy identity")
                try refuse { _ = try before.identityCommitment() }
            }
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T12-identical-bytes-new-inode-changes-handoff")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T13-retained-file-new-ancestor-changes-handoff") {
            let fixture = try Fixture(); defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let before = try HostPolicySnapshot.load(account: account, contract: contract)
            let identity = try before.identityCommitment()
            var old = stat(), new = stat()
            try require(lstat(fixture.path + "/owner/policy.yml", &old) == 0, "capture retained file identity")
            try require(rename(fixture.path + "/owner", fixture.path + "/old-owner") == 0, "move owned policy ancestor")
            try require(mkdir(fixture.path + "/owner", 0o700) == 0, "replace owned policy ancestor")
            for name in fixture.contents.keys.filter({ $0.hasPrefix("owner/") }) {
                let base = String(name.dropFirst("owner/".count))
                try require(rename(fixture.path + "/old-owner/" + base, fixture.path + "/owner/" + base) == 0,
                            "move retained fixture file into replacement ancestor")
            }
            try require(lstat(fixture.path + "/owner/policy.yml", &new) == 0
                        && old.st_dev == new.st_dev && old.st_ino == new.st_ino, "fixture lost retained file inode")
            let after = try HostPolicySnapshot.load(account: account, contract: contract)
            try require(before.admissionSHA256 == after.admissionSHA256, "ancestor change modified content binding")
            try require(try identity != after.identityCommitment(), "replacement ancestor preserved policy identity")
            try refuse { _ = try before.identityCommitment() }
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T13-retained-file-new-ancestor-changes-handoff")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T14-bounded-batch-shared-ancestors-and-exact-bytes") {
            let fixture = try Fixture(); defer { try? fixture.remove() }
            let files = try fixture.contents.keys.sorted().map {
                try PolicyAuthorityFile.read(path: fixture.path + "/" + $0, owner: geteuid(), maximumBytes: 65_536)
            }
            try PolicyAuthorityFile.revalidate(files)
            try PolicyAuthorityFile.revalidate(Array(files.reversed()))
            try PolicyAuthorityFile.revalidate(Array(repeating: files[0], count: 64))
            for invalid in [[PolicyAuthorityFile](), Array(repeating: files[0], count: 65)] {
                do { try PolicyAuthorityFile.revalidate(invalid); throw Failure.assertion("unbounded authority batch admitted") }
                catch PolicyAuthorityFileError.unavailable {}
            }
            try fixture.write("owner/unrelated", Data("sibling\n".utf8))
            try PolicyAuthorityFile.revalidate(files)
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T14-bounded-batch-shared-ancestors-and-exact-bytes")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T15-batch-postflight-rejects-earlier-file-and-parent-drift") {
            for cut in ["bytes", "replacement", "mode", "parent"] {
                let fixture = try Fixture(); defer { try? fixture.remove() }
                let names = ["owner/policy.yml", "owner/overlay.json"]
                let files = try names.map {
                    try PolicyAuthorityFile.read(path: fixture.path + "/" + $0, owner: geteuid(), maximumBytes: 65_536)
                }
                var observed = [Int]()
                do {
                    try PolicyAuthorityFile.testingRevalidate(files) { index in
                        observed.append(index)
                        guard index == 1 else { return }
                        let target = fixture.path + "/" + names[0]
                        switch cut {
                        case "bytes":
                            var changed = fixture.contents[names[0]]!; changed[0] ^= 1
                            try fixture.write(names[0], changed)
                        case "replacement":
                            try fixture.write("owner/replacement", fixture.contents[names[0]]!)
                            try require(rename(fixture.path + "/owner/replacement", target) == 0, "batch replacement cut")
                        case "mode":
                            try require(chmod(target, 0o640) == 0, "batch mode cut")
                        default:
                            try require(rename(fixture.path + "/owner", fixture.path + "/old-owner") == 0,
                                        "batch parent rename cut")
                            try require(mkdir(fixture.path + "/owner", 0o700) == 0, "batch replacement parent")
                            // The opened payloads remain named in the old parent,
                            // so only final ancestor name/identity proof can reject.
                            for name in names { try fixture.write(name, fixture.contents[name]!) }
                        }
                    }
                    throw Failure.assertion("batch postflight admitted earlier drift: " + cut)
                } catch PolicyAuthorityFileError.unavailable {}
                try require(observed == [0, 1], "batch fault cut did not follow both payload reads")
                try fixture.remove()
            }
        }
        onPass("POLICY-SNAPSHOT-T15-batch-postflight-rejects-earlier-file-and-parent-drift")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T16-coordinator-retained-handoff-refusal-before-effects") {
            // Exercise the production prerequisite's real retained-policy helper,
            // without manufacturing the enclosing publisher capability.
            for mutation in ["missing", "bytes", "inode", "ancestor"] {
                let fixture = try Fixture(); defer { try? fixture.remove() }
                let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
                let retained = try CoordinatorPolicyPrerequisite.RetainedPolicy(account: account, contract: fixture.contract())
                var effects = 0
                try retained.revalidate(); effects += 1
                let input = fixture.path + "/owner/overlay.json"
                switch mutation {
                case "missing": try require(unlink(input) == 0, "handoff missing input")
                case "bytes": try fixture.write("owner/overlay.json", Data("substituted".utf8))
                case "inode":
                    try fixture.write("owner/replacement", fixture.contents["owner/overlay.json"]!)
                    try require(rename(fixture.path + "/owner/replacement", input) == 0, "handoff replacement")
                default:
                    try require(rename(fixture.path + "/owner", fixture.path + "/retained-owner") == 0,
                                "handoff original ancestor retained")
                    try fixture.restore()
                }
                try refuse { try retained.revalidate(); effects += 1 }
                try require(effects == 1 && !FileManager.default.fileExists(atPath: fixture.path + "/workspace"),
                            "changed handoff reached effects or repository root")
                try fixture.remove()
            }
        }
        onPass("POLICY-SNAPSHOT-T16-coordinator-retained-handoff-refusal-before-effects")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T17-coordinator-retained-handoff-unavailable-inputs") {
            for mutation in ["missing", "malformed", "incompatible", "stale", "account"] {
                let fixture = try Fixture(); defer { try? fixture.remove() }
                var account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
                var contract = try fixture.contract()
                switch mutation {
                case "missing": try require(unlink(fixture.path + "/" + Fixture.binding) == 0, "missing binding")
                case "malformed": try fixture.write(Fixture.binding, Data("{}".utf8))
                case "incompatible": contract = try fixture.contract(moduleDigest: String(repeating: "e", count: 64))
                case "stale": try fixture.write("owner/overlay.json", Data("changed source".utf8))
                default: account = EffectiveAccount(uid: geteuid() + 1, username: "fixture-account", homeDirectory: fixture.path)
                }
                var effects = 0
                try refuse {
                    _ = try CoordinatorPolicyPrerequisite.RetainedPolicy(account: account, contract: contract)
                    effects += 1
                }
                try require(effects == 0 && !FileManager.default.fileExists(atPath: fixture.path + "/workspace"),
                            "unavailable prerequisite reached effects or repository root")
                try fixture.remove()
            }
        }
        onPass("POLICY-SNAPSHOT-T17-coordinator-retained-handoff-unavailable-inputs")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T18-coordinator-overlap-refuses-inflight-commit") {
            let state = CoordinatorPolicyPrerequisite.RevalidationState()
            var trace = [String](), effects = 0
            try state.revalidate { trace.append("initial-validation") }; effects += 1
            try publisherRefuse {
                try state.revalidate {
                    trace.append("outer-validation")
                    // Deterministic A-entry/B-refusal/A-commit interleaving on
                    // the actual production state, without a scheduling race.
                    // Reentry also requires that validation holds no state lock.
                    try publisherRefuse {
                        try state.revalidate { trace.append("overlap-validation") }
                        effects += 1
                    }
                    trace.append("overlap-refused")
                    // Even if A's underlying evidence remains valid and its
                    // checks finish normally, its final commit must refuse.
                    trace.append("outer-validation-finished")
                }
                effects += 1
            }
            try publisherRefuse {
                try state.revalidate { trace.append("reuse-validation") }
                effects += 1
            }
            try require(trace == ["initial-validation", "outer-validation", "overlap-refused", "outer-validation-finished"]
                        && effects == 1, "overlapping refusal published success or reused validation")
        }
        onPass("POLICY-SNAPSHOT-T18-coordinator-overlap-refuses-inflight-commit")
        try RuntimeFixtureSession.withCase("POLICY-SNAPSHOT-T19-coordinator-refusal-survives-restored-policy") {
            let fixture = try Fixture(); defer { try? fixture.remove() }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
            let contract = try fixture.contract()
            let state = CoordinatorPolicyPrerequisite.RevalidationState()
            let retained = try CoordinatorPolicyPrerequisite.RetainedPolicy(account: account, contract: contract)
            var validations = 0, effects = 0
            try state.revalidate { validations += 1; try retained.revalidate() }; effects += 1
            try fixture.write("owner/overlay.json", Data("substituted".utf8))
            try publisherRefuse {
                try state.revalidate { validations += 1; try retained.revalidate() }
                effects += 1
            }
            try fixture.restore()
            // Demonstrate real restored inputs validate independently. The old
            // state's refusal, not still-invalid evidence, must prevent reuse.
            let restored = try CoordinatorPolicyPrerequisite.RetainedPolicy(account: account, contract: contract)
            try restored.revalidate()
            try publisherRefuse {
                try state.revalidate { validations += 1; try restored.revalidate() }
                effects += 1
            }
            try require(validations == 2 && effects == 1
                        && !FileManager.default.fileExists(atPath: fixture.path + "/workspace"),
                        "restored policy reopened a refused handoff or reached effects")
            try fixture.remove()
        }
        onPass("POLICY-SNAPSHOT-T19-coordinator-refusal-survives-restored-policy")
    }

    public static func runCatalogSession(onPass: (String) -> Void) throws {
        func denied(_ body: () throws -> Void) throws {
            do { try body(); throw Failure.assertion("unsafe session accepted") }
            catch PolicyHelperError.unavailable {}
            catch HostPolicyBindingError.unavailable {}
            catch RepositorySelectionAdmissionError.unavailable {}
            catch SelectedRepositoryScopeError.policyUnavailable {}
        }
        func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 750_000_000 }
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T01-snapshot-helper-and-catalog-composition") {
            let projection = "/fixture/home/workspace", marker = projection + "/ready/.git"
            let roster = [marker] + ["config", "refs", "refs/remotes", "refs/remotes/origin", "refs/remotes/origin/HEAD"].map { marker + "/" + $0 }
            func prefetched(_ required: [String], _ cached: Set<Data> = []) -> [String] {
                PolicyCatalogSession.prefetchCatalogMetadata(required, cached: cached, projectionRoot: projection)
            }
            try require(prefetched([marker]) == roster, "fixed metadata prefetch roster")
            for outside in ["/fixture/home/.git", "/fixture/home/workspace-other/ready/.git", projection + "/ready/.GIT"] {
                try require(prefetched([outside]) == [outside], "prefetch escaped exact projection or marker spelling")
            }
            // Keep filler names outside shelf-child prefetch so this still tests
            // the explicit marker's fixed-metadata priority at the final slot.
            let partial = [marker] + (0..<62).map { projection + "/unconfigured/candidate-\($0)" }
            try require(prefetched(partial) == partial + [roster[1]], "prefetch did not respect final batch slot")
            let full = partial + [projection + "/unconfigured/candidate-final"]
            try require(prefetched(full) == full, "prefetch displaced full mandatory batch")
            let nearFull = Set((0..<4094).map { Data((projection + "/cached-\($0)").utf8) })
            try require(prefetched([marker], nearFull) == [marker, roster[1]], "prefetch overfilled remaining cache slot")
            try require(prefetched([marker], nearFull.union([Data((projection + "/cached-final").utf8)])) == [marker],
                        "speculative prefetch displaced valid near-full cache request")
            try require(prefetched([marker], [Data(roster[1].utf8)]) == [marker] + Array(roster.dropFirst(2)),
                        "prefetch repeated an existing cached decision")
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let audit = CommandAudit()
            let session = try context.make("metadata-prefetch-roster", audit: audit)
            let binder = try session.binder()
            let catalogStarted = DispatchTime.now().uptimeNanoseconds
            let catalog = try binder.processFreeCatalog(preferences: nil, generation: 1)
            print("METRIC policy-session catalog-ns=\(DispatchTime.now().uptimeNanoseconds - catalogStarted) helpers=\(audit.invocations.count)")
            try require(catalog.isComplete, "projected catalog incomplete: \(String(describing: catalog.degradedReason))")
            guard let ready = catalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }),
                  let blocked = catalog.catalog.candidates.first(where: { $0.displayLabel == "blocked" }) else {
                throw Failure.assertion("projected rows missing")
            }
            try require(ready.isEligible && blocked.section == .protected && blocked.catalogRepositoryIdentity == nil
                && catalog.catalog.policyDigest == (try context.snapshot()).admissionSHA256, "projection/admission digest or rows")
            try require(!audit.invocations.isEmpty && audit.invocations.count <= 2 && audit.invocations.allSatisfy {
                $0.arguments == ["isolated-policy-classification"]
                    && !$0.spawnArguments.joined().contains(fixture.path)
            }, "candidate exposed in child arguments")
            let protectedSession = try context.make("metadata-prefetch-protected")
            let protectedCatalog = try protectedSession.binder().processFreeCatalog(preferences: nil, generation: 2)
            guard let protectedReady = protectedCatalog.catalog.candidates.first(where: { $0.displayLabel == "ready" }) else {
                throw Failure.assertion("prefetched protected metadata row missing")
            }
            try require(protectedCatalog.isComplete && protectedReady.section == .protected
                && protectedReady.advisoryOrigin == nil && protectedReady.catalogRepositoryIdentity == nil
                && protectedCatalog.catalog.counters.filesOpened == 0,
                "prefetched descendant protection bypassed before file access")
            try context.remove()

            // Exercise the root shelf the catalog really enumerates, including
            // a visible directory with no marker and protected metadata. The
            // evaluator refuses a child-only batch; old prefetch cannot pass.
            let rootContext = try SessionFixture()
            defer { try? rootContext.remove() }
            try FileManager.default.createDirectory(atPath: rootContext.fixture.path + "/workspace/root-empty",
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try rootContext.fixture.write("workspace/root-guarded/.git/config",
                Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/root-guarded.git\n".utf8))
            let rootAudit = CommandAudit()
            let rootSession = try rootContext.make("root-shelf-prefetch", audit: rootAudit)
            let rootCatalog = try rootSession.binder().processFreeCatalog(preferences: nil, generation: 3)
            guard rootCatalog.isComplete,
                  let rootGuarded = rootCatalog.catalog.candidates.first(where: { $0.displayLabel == "root-guarded" }),
                  let rootReady = rootCatalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }) else {
                throw Failure.assertion("root-shelf prefetch catalog incomplete or rows missing")
            }
            try require(rootReady.isEligible && rootGuarded.section == .protected
                && rootGuarded.advisoryOrigin == nil && rootGuarded.catalogRepositoryIdentity == nil
                && !rootCatalog.catalog.candidates.contains(where: { $0.displayLabel == "root-empty" })
                && rootCatalog.catalog.counters.filesOpened == catalog.catalog.counters.filesOpened,
                "root-shelf prefetch changed absent-marker or protected descendant outcome")
            try require(rootAudit.invocations.count == 3 && rootAudit.invocations.allSatisfy {
                $0.arguments == ["isolated-policy-classification"]
                    && !$0.spawnArguments.joined().contains(rootContext.fixture.path)
            }, "root-shelf catalog request count or lexical argument containment")

            let rootChild = try RepositorySelectionAdmissionPath(root: "~", components: ["workspace", "root-empty"])
            let rootMarker = try RepositorySelectionAdmissionPath(root: "~", components: ["workspace", "root-empty", ".git"])
            let rootReuseAudit = CommandAudit()
            let rootReuse = try rootContext.make("root-shelf-prefetch", audit: rootReuseAudit)
            let rootDeadline = deadline()
            try rootReuse.admission.requireAllowed(rootChild, deadline: rootDeadline)
            try rootReuse.admission.requireAllowed(rootMarker, deadline: rootDeadline)
            try require(rootReuseAudit.invocations.count == 1, "root marker did not reuse exact same-scan prefetch")
            try rootContext.fixture.write("owner/overlay.json", rootContext.fixture.contents["owner/overlay.json"]! + Data("\n".utf8))
            try denied { try rootReuse.admission.requireAllowed(rootMarker, deadline: rootDeadline) }
            try require(rootReuseAudit.invocations.count == 1, "cached root marker bypassed current authority")
            try rootContext.fixture.restore()
            // Restoring bytes does not restore the captured file identities.
            // The old authority must remain refused before another helper.
            try denied { try rootReuse.admission.requireAllowed(rootMarker, deadline: rootDeadline) }
            try require(rootReuseAudit.invocations.count == 1, "restored bytes revived stale root authority")

            // A current snapshot gets its own unchanged scan budget. Keep the
            // prefetch eviction check independent of irreversible policy drift.
            let currentRootAudit = CommandAudit()
            let rootResourceMarker = rootContext.fixture.path + "/resource-marker"
            let currentRoot = try rootContext.make("root-shelf-prefetch", audit: currentRootAudit, resourceCheck: {
                if FileManager.default.fileExists(atPath: rootResourceMarker) { throw PolicyHelperError.unavailable }
            })
            let currentRootDeadline = deadline()
            try currentRoot.admission.requireAllowed(rootChild, deadline: currentRootDeadline)
            try currentRoot.admission.requireAllowed(rootMarker, deadline: currentRootDeadline)
            try require(currentRootAudit.invocations.count == 1, "current root snapshot did not reclassify and reuse prefetch")
            try rootContext.fixture.write("resource-marker", Data("changed".utf8))
            try denied { try currentRoot.admission.requireAllowed(rootMarker, deadline: currentRootDeadline) }
            try require(currentRootAudit.invocations.count == 1, "cached root marker bypassed revoked resources")
            try require(unlink(rootResourceMarker) == 0, "root resource marker cleanup")
            try currentRoot.admission.requireAllowed(rootMarker, deadline: currentRootDeadline)
            try require(currentRootAudit.invocations.count == 2, "root drift refusal retained prefetched decisions")

            let invalidRootAudit = CommandAudit()
            let invalidRoot = try rootContext.make("root-shelf-prefetch-invalid", audit: invalidRootAudit)
            let invalidRootDeadline = deadline()
            try denied { try invalidRoot.admission.requireAllowed(rootChild, deadline: invalidRootDeadline) }
            try denied { try invalidRoot.admission.requireAllowed(rootMarker, deadline: invalidRootDeadline) }
            try require(invalidRootAudit.invocations.count == 2,
                "invalid optional root metadata retained a partial batch decision")
            try rootContext.remove()
        }
        onPass("POLICY-SESSION-T01-snapshot-helper-and-catalog-composition")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T02-selected-intent-reclassified-and-bound") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let audit = CommandAudit()
            let session = try context.make(audit: audit)
            let binder = try session.binder()
            let catalogStarted = DispatchTime.now().uptimeNanoseconds
            let catalog = try binder.processFreeCatalog(preferences: nil, generation: 1)
            print("METRIC policy-session catalog-ns=\(DispatchTime.now().uptimeNanoseconds - catalogStarted) helpers=\(audit.invocations.count)")
            try require(catalog.isComplete, "projected catalog incomplete: \(String(describing: catalog.degradedReason))")
            guard let ready = catalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }),
                  let blocked = catalog.catalog.candidates.first(where: { $0.displayLabel == "blocked" }) else {
                throw Failure.assertion("projected rows missing")
            }
            try require(ready.isEligible && blocked.section == .protected && blocked.catalogRepositoryIdentity == nil
                && catalog.catalog.policyDigest == (try context.snapshot()).admissionSHA256, "projection/admission digest or rows")
            try require(!audit.invocations.isEmpty && audit.invocations.allSatisfy {
                $0.arguments == ["isolated-policy-classification"]
                    && !$0.spawnArguments.joined().contains(fixture.path)
            }, "candidate exposed in child arguments")
            let intent = try RepositorySelectionIntent(catalog: catalog.catalog, entries: [try ready.preferenceEntry])
            let bindStarted = DispatchTime.now().uptimeNanoseconds
            let callsBeforeBind = audit.invocations.count
            let scope: ValidatedSelectedRepositoryScope
            do { scope = try binder.bind(intent: intent) }
            catch {
                throw Failure.assertion("bind failed ns=\(DispatchTime.now().uptimeNanoseconds - bindStarted) helpers=\(audit.invocations.count - callsBeforeBind) error=\(error)")
            }
            print("METRIC policy-session bind-ns=\(DispatchTime.now().uptimeNanoseconds - bindStarted) helpers=\(audit.invocations.count - callsBeforeBind)")
            try require(scope.repositories.count == 1 && scope.repositories[0].repositoryID == "fixture-owner/ready"
                && scope.policyDigest == catalog.catalog.policyDigest, "snapshot-bound intent failed to bind")
            let boundRole = try scope.requireGovernedRootRole()
            let exact = try scope.exactRepositoryScope(repositoryID: "fixture-owner/ready")
            let hydration = SelectedRepositoryHydrator.sessionPlan(scope: scope,
                retainedScope: nil, retainedRepositoryIDs: []).hydrationScope
            try require(boundRole.repositoryID == "fixture-owner/root"
                && boundRole.policyDigest == scope.policyDigest
                && exact.governedRootRole == boundRole && hydration?.governedRootRole == boundRole,
                "scope projection lost verified governed-root role")
            try context.remove()
        }
        onPass("POLICY-SESSION-T02-selected-intent-reclassified-and-bound")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T03-outside-projection-rejected-before-child") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let audit = CommandAudit()
            let session = try context.make(audit: audit)
            let binder = try session.binder()
            let catalogStarted = DispatchTime.now().uptimeNanoseconds
            let catalog = try binder.processFreeCatalog(preferences: nil, generation: 1)
            print("METRIC policy-session catalog-ns=\(DispatchTime.now().uptimeNanoseconds - catalogStarted) helpers=\(audit.invocations.count)")
            try require(catalog.isComplete, "projected catalog incomplete: \(String(describing: catalog.degradedReason))")
            guard let ready = catalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }),
                  let blocked = catalog.catalog.candidates.first(where: { $0.displayLabel == "blocked" }) else {
                throw Failure.assertion("projected rows missing")
            }
            try require(ready.isEligible && blocked.section == .protected && blocked.catalogRepositoryIdentity == nil
                && catalog.catalog.policyDigest == (try context.snapshot()).admissionSHA256, "projection/admission digest or rows")
            try require(!audit.invocations.isEmpty && audit.invocations.allSatisfy {
                $0.arguments == ["isolated-policy-classification"]
                    && !$0.spawnArguments.joined().contains(fixture.path)
            }, "candidate exposed in child arguments")
            let intent = try RepositorySelectionIntent(catalog: catalog.catalog, entries: [try ready.preferenceEntry])
            let bindStarted = DispatchTime.now().uptimeNanoseconds
            let callsBeforeBind = audit.invocations.count
            let scope: ValidatedSelectedRepositoryScope
            do { scope = try binder.bind(intent: intent) }
            catch {
                throw Failure.assertion("bind failed ns=\(DispatchTime.now().uptimeNanoseconds - bindStarted) helpers=\(audit.invocations.count - callsBeforeBind) error=\(error)")
            }
            print("METRIC policy-session bind-ns=\(DispatchTime.now().uptimeNanoseconds - bindStarted) helpers=\(audit.invocations.count - callsBeforeBind)")
            try require(scope.repositories.count == 1 && scope.repositories[0].repositoryID == "fixture-owner/ready"
                && scope.policyDigest == catalog.catalog.policyDigest, "snapshot-bound intent failed to bind")
            let boundRole = try scope.requireGovernedRootRole()
            let exact = try scope.exactRepositoryScope(repositoryID: "fixture-owner/ready")
            let hydration = SelectedRepositoryHydrator.sessionPlan(scope: scope,
                retainedScope: nil, retainedRepositoryIDs: []).hydrationScope
            try require(boundRole.repositoryID == "fixture-owner/root"
                && boundRole.policyDigest == scope.policyDigest
                && exact.governedRootRole == boundRole && hydration?.governedRootRole == boundRole,
                "scope projection lost verified governed-root role")
            let before = audit.invocations.count
            for path in [try RepositorySelectionAdmissionPath(root: "other", components: ["workspace"]),
                         try RepositorySelectionAdmissionPath(root: "~", components: ["outside"])] {
                try denied { try session.admission.requireAllowed(path, deadline: deadline()) }
            }
            try require(audit.invocations.count == before, "outside projection reached helper")
            try context.remove()
        }
        onPass("POLICY-SESSION-T03-outside-projection-rejected-before-child")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T04-invalid-helper-cannot-admit-root") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            for mode in ["partial", "noise", "invalid"] {
                let invalid = try context.make(mode)
                try denied { _ = try invalid.binder().processFreeCatalog(preferences: nil, generation: 1) }
            }
            try context.remove()
        }
        onPass("POLICY-SESSION-T04-invalid-helper-cannot-admit-root")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T05-cancellation-and-shared-deadline") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let cancelled = CancellationToken(); cancelled.cancel()
            try denied { _ = try context.make(cancellation: cancelled) }
            let token = CancellationToken(), cancellationAudit = CommandAudit()
            let cancellable = try context.make(cancellation: token, audit: cancellationAudit)
            token.closeFutureChildAdmissions()
            try denied { _ = try cancellable.binder() }
            try require(cancellationAudit.invocations.isEmpty, "closed child admission spawned")
            let sleeping = try context.make("sleep")
            let started = DispatchTime.now().uptimeNanoseconds
            try denied { try sleeping.admission.requireAllowed(RepositorySelectionAdmissionPath(root: "~", components: []),
                deadline: started + 100_000_000) }
            try require(DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000, "helper deadline did not settle")
            try context.remove()
        }
        onPass("POLICY-SESSION-T05-cancellation-and-shared-deadline")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T06-policy-drift-revokes-before-child-or-root") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let driftAudit = CommandAudit(), drift = try context.make(audit: driftAudit)
            try fixture.write("owner/overlay.json", fixture.contents["owner/overlay.json"]! + Data("\n".utf8))
            try denied { _ = try drift.binder().processFreeCatalog(preferences: nil, generation: 1) }
            try require(driftAudit.invocations.isEmpty, "stale snapshot reached helper")
            try fixture.restore()
            try context.remove()
        }
        onPass("POLICY-SESSION-T06-policy-drift-revokes-before-child-or-root")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T07-unsafe-scratch-and-wrong-contract-refuse") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            try require(chmod(fixture.path, 0o750) == 0, "scratch mode fixture")
            try denied { _ = try context.make() }
            try require(chmod(fixture.path, 0o700) == 0, "restore scratch mode")
            let newSnapshot = try context.snapshot()
            let wrong = try json(["schema": "shadow-sync-awa-contract/v1", "status": "qualified",
                "release_revision": String(repeating: "b", count: 40), "module_sha256": digest(fixture.contents["runtime/policy.py"]!)])
            try denied { _ = try PolicyCatalogSession(snapshot: newSnapshot, interpreter: context.interpreter, adapter: Data("unused".utf8),
                contract: wrong, scratchDescriptor: context.directory, cancellation: CancellationToken(),
                revalidateResources: {}, validateInterpreter: { _ in }) }
            try context.remove()
        }
        onPass("POLICY-SESSION-T07-unsafe-scratch-and-wrong-contract-refuse")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T08-scan-scoped-reuse-revalidates-and-expires") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let reuseAudit = CommandAudit(), reuse = try context.make(audit: reuseAudit)
            let rootPath = try RepositorySelectionAdmissionPath(root: "~", components: [])
            let sharedDeadline = deadline()
            try reuse.admission.requireAllowed(rootPath, deadline: sharedDeadline)
            try reuse.admission.requireAllowed(rootPath, deadline: sharedDeadline)
            try require(reuseAudit.invocations.count == 1, "same-scan exact decision not reused")
            try reuse.admission.requireAllowed(rootPath, deadline: sharedDeadline + 1)
            try require(reuseAudit.invocations.count == 2, "new scan borrowed previous admission")
            try fixture.write("owner/overlay.json", fixture.contents["owner/overlay.json"]! + Data("\n".utf8))
            try denied { try reuse.admission.requireAllowed(rootPath, deadline: sharedDeadline + 1) }
            try require(reuseAudit.invocations.count == 2, "cached lookup bypassed changed authority")
            try fixture.restore()
            final class ValidationProbe: @unchecked Sendable {
                private let lock = NSLock()
                private var calls = 0
                private var failAt: Int?
                func arm(_ call: Int?) { lock.lock(); calls = 0; failAt = call; lock.unlock() }
                func check() throws {
                    lock.lock(); calls += 1; let fail = calls == failAt; lock.unlock()
                    if fail { throw PolicyHelperError.unavailable }
                }
                var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
            }
            let probe = ValidationProbe(), probeAudit = CommandAudit()
            let probed = try context.make(audit: probeAudit, resourceCheck: { try probe.check() })
            let probeDeadline = deadline()
            try probed.admission.requireAllowed(rootPath, deadline: probeDeadline)
            try require(probeAudit.invocations.count == 1, "cache-validation warmup did not classify")
            probe.arm(nil)
            try probed.admission.requireAllowed(rootPath, deadline: probeDeadline)
            try require(probe.count == 2 && probeAudit.invocations.count == 1,
                        "cached admission must retain both outer validation boundaries")
            probe.arm(2)
            try denied { try probed.admission.requireAllowed(rootPath, deadline: probeDeadline) }
            try require(probe.count == 2 && probeAudit.invocations.count == 1,
                        "post-evaluation validation failure did not refuse cached admission")
            probe.arm(nil)
            try probed.admission.requireAllowed(rootPath, deadline: probeDeadline)
            try require(probeAudit.invocations.count == 2, "failed outer validation retained prior cache decisions")
            probe.arm(1)
            try denied { try probed.admission.requireAllowed(rootPath, deadline: probeDeadline) }
            try require(probe.count == 1 && probeAudit.invocations.count == 2,
                        "pre-evaluation validation failure reached classification")
            probe.arm(nil)
            try probed.admission.requireAllowed(rootPath, deadline: probeDeadline)
            try require(probeAudit.invocations.count == 3, "failed outer validation retained prior cache decisions")
            print("METRIC policy-session cached-validation-checks=2 recovery-reclassifications=2")
            try context.remove()
        }
        onPass("POLICY-SESSION-T08-scan-scoped-reuse-revalidates-and-expires")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T09-full-projection-cardinality-composes") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            var maximalProjection = fixture.projection
            maximalProjection["shelves"] = (0..<32).map { ["shelf-\($0)"] }
            let maximalBytes = try json(maximalProjection)
            try fixture.write("owner/projection.json", maximalBytes)
            var maximalBinding = fixture.binding
            maximalBinding["projection"] = ["path": "owner/projection.json", "sha256": digest(maximalBytes)]
            try fixture.write(Fixture.binding, json(maximalBinding))
            let maximalAudit = CommandAudit()
            let maximal = try context.make("projection-prefetch-boundary", audit: maximalAudit).binder()
            let maximalCatalog = try maximal.processFreeCatalog(preferences: nil, generation: 1)
            try require(maximalCatalog.isComplete && !maximalAudit.invocations.isEmpty,
                        "32 projected shelves plus root rejected or classifier not exercised")
            try fixture.restore()
            try context.remove()
        }
        onPass("POLICY-SESSION-T09-full-projection-cardinality-composes")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T10-publisher-resource-drift-revokes-before-and-after-child") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let rootPath = try RepositorySelectionAdmissionPath(root: "~", components: [])
            let resourceRevoked = CancellationToken(), resourceAudit = CommandAudit()
            let resourceSession = try context.make(audit: resourceAudit, resourceCheck: {
                if resourceRevoked.isCancelled { throw PolicyHelperError.unavailable }
            })
            resourceRevoked.cancel()
            try denied { _ = try resourceSession.binder() }
            try require(resourceAudit.invocations.isEmpty, "revoked publisher resources reached a child")
            let marker = fixture.path + "/resource-marker", duringAudit = CommandAudit()
            let during = try context.make("resource-drift", audit: duringAudit, resourceCheck: {
                if FileManager.default.fileExists(atPath: marker) { throw PolicyHelperError.unavailable }
            })
            try denied { try during.admission.requireAllowed(rootPath, deadline: deadline()) }
            try require(duringAudit.invocations.count == 1 && FileManager.default.fileExists(atPath: marker),
                        "mid-child resource drift was not exercised")
            try denied { try during.admission.requireAllowed(rootPath, deadline: deadline()) }
            try require(duringAudit.invocations.count == 1, "failed publisher resources left a cached allow")
            try require(unlink(marker) == 0, "resource marker cleanup")
            try context.remove()
        }
        onPass("POLICY-SESSION-T10-publisher-resource-drift-revokes-before-and-after-child")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T11-real-runtime-layout-lease-within-catalog-and-bind-budget") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit framework lease fixture missing")
            }
            let runtimeLayout = try PolicyRuntimeLayout.decode(
                Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest)),
                source: Data(contentsOf: URL(fileURLWithPath: sourcePath)))
            let runtimeTree = try PolicyRuntimeTree.capture(root: framework, owner: geteuid(), layout: runtimeLayout)
            final class Measurement: @unchecked Sendable {
                private let lock = NSLock()
                private var values: [UInt64] = []
                func record(_ value: UInt64) { lock.lock(); values.append(value); lock.unlock() }
                var durations: [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
            }
            let resourceMeasurement = Measurement(), measuredAudit = CommandAudit()
            let measured = try context.make(audit: measuredAudit, resourceCheck: {
                let start = DispatchTime.now().uptimeNanoseconds
                defer { resourceMeasurement.record(DispatchTime.now().uptimeNanoseconds - start) }
                try runtimeTree.revalidate(root: framework, owner: geteuid(), layout: runtimeLayout)
            })
            let measuredBinder = try measured.binder(), initialResourceCalls = resourceMeasurement.durations.count
            let measuredStart = DispatchTime.now().uptimeNanoseconds
            let measuredCatalog = try measuredBinder.processFreeCatalog(preferences: nil, generation: 1)
            let measuredDuration = DispatchTime.now().uptimeNanoseconds - measuredStart
            print("METRIC policy-runtime real-layout-catalog-ns=\(measuredDuration)")
            let resourceDurations = resourceMeasurement.durations.dropFirst(initialResourceCalls)
            print("METRIC policy-runtime resource-checks=\(resourceDurations.count) resource-ns=\(resourceDurations.reduce(0, +)) helpers=\(measuredAudit.invocations.count) complete=\(measuredCatalog.isComplete)")
            try require(measuredCatalog.isComplete && measuredDuration <= 750_000_000,
                        "real runtime lease exceeded catalog admission bound")
            guard let measuredReady = measuredCatalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }) else {
                throw Failure.assertion("measured selected row missing")
            }
            let measuredIntent = try RepositorySelectionIntent(catalog: measuredCatalog.catalog,
                entries: [try measuredReady.preferenceEntry])
            let measuredBindStart = DispatchTime.now().uptimeNanoseconds
            _ = try measuredBinder.bind(intent: measuredIntent)
            print("METRIC policy-runtime real-layout-bind-ns=\(DispatchTime.now().uptimeNanoseconds - measuredBindStart)")
            try context.remove()
        }
        onPass("POLICY-SESSION-T11-real-runtime-layout-lease-within-catalog-and-bind-budget")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T12-publisher-and-policy-setup-share-catalog-deadline") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let fixture = context.fixture
            let setupAudit = CommandAudit(), setupSession = try context.make(audit: setupAudit)
            try denied { _ = try setupSession.binder(setupDeadline: DispatchTime.now().uptimeNanoseconds - 1) }
            let setupBound = try setupSession.binder(setupDeadline: DispatchTime.now().uptimeNanoseconds + 50_000_000)
            Thread.sleep(forTimeInterval: 0.06)
            try denied { _ = try setupBound.processFreeCatalog(preferences: nil, generation: 1) }
            try require(setupAudit.invocations.isEmpty, "expired factory setup reset the catalog budget")
            try context.remove()
        }
        onPass("POLICY-SESSION-T12-publisher-and-policy-setup-share-catalog-deadline")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T13-cleanup-pending-preserves-admission-state") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let marker = context.fixture.path + "/pending-policy-fixture"
            let audit = CommandAudit()
            let session = try context.make(audit: audit, resourceCheck: {
                if FileManager.default.fileExists(atPath: marker) { throw PolicyHelperError.cleanupPending }
            })
            let binder = try session.binder()
            let prior = try binder.processFreeCatalog(preferences: nil, generation: 1)
            try require(prior.isComplete, "pending fixture has no prior complete catalog")
            let calls = audit.invocations.count
            try context.fixture.write("pending-policy-fixture", Data("pending".utf8))
            do { _ = try binder.processFreeCatalog(preferences: nil, generation: 2); throw Failure.assertion("pending catalog accepted") }
            catch SelectedRepositoryScopeError.cleanupPending {}
            try require(audit.invocations.count == calls && prior.isComplete, "pending admission launched or changed prior catalog")
            try require(unlink(marker) == 0, "pending marker cleanup")
            do { _ = try session.binder(); throw Failure.assertion("pending session reopened without recovery") }
            catch RepositorySelectionAdmissionError.cleanupPending {}
            try context.remove()
        }
        onPass("POLICY-SESSION-T13-cleanup-pending-preserves-admission-state")
        func selectedScope(_ fixture: SessionFixture) throws -> ValidatedSelectedRepositoryScope {
            let binder = try fixture.make().binder()
            let catalog = try binder.processFreeCatalog(preferences: nil, generation: 1)
            guard catalog.isComplete,
                  let ready = catalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }) else {
                throw Failure.assertion("rebind fixture selection missing: complete=\(catalog.isComplete) reason=\(String(describing: catalog.degradedReason)) rows=\(catalog.catalog.candidates.count) elapsed_ns=\(catalog.catalog.elapsedNanoseconds)")
            }
            return try binder.bind(intent: RepositorySelectionIntent(catalog: catalog.catalog,
                entries: [try ready.preferenceEntry]))
        }
        func changedScope(_ scope: ValidatedSelectedRepositoryScope,
                          digest: String? = nil, generation: UInt64? = nil,
                          repositories: [ValidatedSelectedRepository]? = nil) -> ValidatedSelectedRepositoryScope {
            ValidatedSelectedRepositoryScope(selectionGeneration: generation ?? scope.selectionGeneration,
                policyDigest: digest ?? scope.policyDigest, catalogGeneration: scope.catalogGeneration,
                repositories: repositories ?? scope.repositories, governedRootRole: scope.governedRootRole)
        }
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T14-fresh-operation-rebind-preserves-exact-selection") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let scope = try selectedScope(context), audit = CommandAudit()
            let binder = try context.make(audit: audit).binder()
            var entered = false
            let value = try binder.withReboundScope(scope, cancellation: CancellationToken()) { rebound in
                try require(rebound == scope, "fresh operation changed saved selection")
                entered = true
                return rebound.repositoryIDs
            }
            try require(entered && value == scope.repositoryIDs && !audit.invocations.isEmpty,
                        "operation reused an earlier policy decision without fresh classification")
            try context.remove()
        }
        onPass("POLICY-SESSION-T14-fresh-operation-rebind-preserves-exact-selection")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T15-stale-and-duplicate-scope-refuses-before-classifier") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let scope = try selectedScope(context), audit = CommandAudit()
            let binder = try context.make(audit: audit).binder()
            for stale in [changedScope(scope, digest: String(repeating: "f", count: 64)),
                          changedScope(scope, generation: scope.selectionGeneration + 1),
                          changedScope(scope, repositories: scope.repositories + scope.repositories)] {
                do {
                    _ = try binder.withReboundScope(stale, cancellation: CancellationToken()) { _ in
                        throw Failure.assertion("stale selection reached downstream inspection")
                    }
                    throw Failure.assertion("stale selection rebound")
                } catch SelectedRepositoryScopeError.changed {}
            }
            try require(audit.invocations.isEmpty, "invalid scope reached classifier")
            try context.remove()
        }
        onPass("POLICY-SESSION-T15-stale-and-duplicate-scope-refuses-before-classifier")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T16-replaced-repository-refuses-downstream-inspection") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            // Create the retention directory before capturing the governed root.
            // It is outside the catalog shelves and the policy authority paths.
            let retained = context.fixture.path + "/rebind-retained"
            try require(mkdir(retained, 0o700) == 0, "create retained fixture directory")
            let scope = try selectedScope(context)
            let selected = scope.repositories[0]
            try require(selected.rootIdentity != selected.repositoryIdentity, "root-identity fixture is not distinct")
            let wrongRoot = ValidatedSelectedRepository(repositoryID: selected.repositoryID,
                locator: selected.locator, governedRootPath: selected.governedRootPath,
                policyRootPath: selected.policyRootPath, repositoryPath: selected.repositoryPath,
                rootIdentity: selected.repositoryIdentity, repositoryIdentity: selected.repositoryIdentity)
            do {
                _ = try context.make().binder().withReboundScope(
                    changedScope(scope, repositories: [wrongRoot]), cancellation: CancellationToken()) { _ in
                    throw Failure.assertion("changed root identity reached downstream inspection")
                }
                throw Failure.assertion("changed root identity rebound")
            } catch SelectedRepositoryScopeError.changed {}
            let original = context.fixture.path + "/workspace/products/ready"
            let saved = retained + "/ready"
            var before = stat()
            try require(lstat(original, &before) == 0 && FileIdentity(before) == selected.repositoryIdentity,
                        "original selected fixture identity changed")
            try require(rename(original, saved) == 0, "retain original selected fixture")
            var replacementIdentity: FileIdentity?
            var bodyFailure: Error?
            do {
                try context.fixture.write("workspace/products/ready/.git/config",
                    Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/ready.git\n".utf8))
                try context.fixture.write("workspace/products/ready/.git/refs/remotes/origin/HEAD",
                    Data("ref: refs/remotes/origin/main\n".utf8))
                var replacement = stat(), root = stat()
                try require(lstat(original, &replacement) == 0 && replacement.st_uid == geteuid()
                    && replacement.st_mode & S_IFMT == S_IFDIR, "replacement fixture identity")
                replacementIdentity = FileIdentity(replacement)
                try require(replacement.st_dev != before.st_dev || replacement.st_ino != before.st_ino,
                            "replacement did not change repository inode")
                try require(lstat(selected.governedRootPath, &root) == 0 && FileIdentity(root) == selected.rootIdentity,
                            "repository replacement changed governed-root identity")
                let binder = try context.make().binder()
                do {
                    _ = try binder.withReboundScope(scope, cancellation: CancellationToken()) { _ in
                        throw Failure.assertion("replacement inherited saved repository authority")
                    }
                    throw Failure.assertion("replaced repository rebound")
                } catch SelectedRepositoryScopeError.changed {}
            } catch { bodyFailure = error }
            do {
                var replacement = stat(), retainedInfo = stat()
                if lstat(original, &replacement) == 0 {
                    try require(replacementIdentity == FileIdentity(replacement), "replacement identity changed before cleanup")
                    try FileManager.default.removeItem(atPath: original)
                } else { try require(errno == ENOENT, "inspect replacement cleanup path") }
                try require(lstat(saved, &retainedInfo) == 0 && FileIdentity(retainedInfo) == FileIdentity(before),
                            "retained original identity changed before restoration")
                try require(rename(saved, original) == 0, "restore original selected fixture")
                var restored = stat()
                try require(lstat(original, &restored) == 0 && FileIdentity(restored) == FileIdentity(before),
                            "restored selected fixture identity differs")
                try context.remove()
            } catch {
                if let bodyFailure {
                    throw Failure.assertion("rebind fixture body failed: \(bodyFailure); cleanup also failed: \(error)")
                }
                throw error
            }
            if let bodyFailure { throw bodyFailure }
        }
        onPass("POLICY-SESSION-T16-replaced-repository-refuses-downstream-inspection")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T17-pending-rebind-and-postflight-never-complete") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let scope = try selectedScope(context), marker = context.fixture.path + "/operation-pending"
            for beforeBody in [true, false] {
                let audit = CommandAudit()
                let session = try context.make(audit: audit, resourceCheck: {
                    if FileManager.default.fileExists(atPath: marker) { throw PolicyHelperError.cleanupPending }
                })
                let binder = try session.binder()
                if beforeBody { try context.fixture.write("operation-pending", Data("pending".utf8)) }
                var entered = false, completed = false
                do {
                    _ = try binder.withReboundScope(scope, cancellation: CancellationToken()) { rebound in
                        entered = true
                        try context.fixture.write("operation-pending", Data("pending".utf8))
                        return rebound
                    }
                    completed = true
                } catch SelectedRepositoryScopeError.cleanupPending {}
                try require(!completed && entered != beforeBody && (!beforeBody || audit.invocations.isEmpty),
                            "pending operation admitted work or published completion")
                try require(unlink(marker) == 0, "remove owned pending marker")
                do { _ = try session.binder(); throw Failure.assertion("pending operation reopened") }
                catch RepositorySelectionAdmissionError.cleanupPending {}
            }
            try context.remove()
        }
        onPass("POLICY-SESSION-T17-pending-rebind-and-postflight-never-complete")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T18-cancelled-or-closed-phase-never-completes") {
            let context = try SessionFixture()
            defer { try? context.remove() }
            let scope = try selectedScope(context)
            for closePhase in [false, true] {
                for beforeBody in [true, false] {
                    let token = CancellationToken(), phaseClosed = CancellationToken(), audit = CommandAudit()
                    let binder = try context.make(audit: audit).binder(revalidatePhase: {
                        if phaseClosed.isCancelled { throw CustodyRecordError.fenced }
                    })
                    func revoke() { if closePhase { phaseClosed.cancel() } else { token.cancel() } }
                    if beforeBody { revoke() }
                    var entered = false, completed = false
                    do {
                        _ = try binder.withReboundScope(scope, cancellation: token) { rebound in
                            entered = true; revoke(); return rebound
                        }
                        completed = true
                    } catch GitSafetyError.cancelled { try require(!closePhase, "wrong phase refusal") }
                    catch SelectedRepositoryScopeError.policyUnavailable { try require(closePhase, "wrong cancellation refusal") }
                    try require(!completed && entered != beforeBody && (!beforeBody || audit.invocations.isEmpty),
                                "cancelled or closed phase admitted work or published completion")
                }
            }
            try context.remove()
        }
        onPass("POLICY-SESSION-T18-cancelled-or-closed-phase-never-completes")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T19-rebind-borrows-exclusive-authority-through-return-and-throw") {
            enum Stop: Error { case body }
            let fixture = try SessionFixture()
            defer { try? fixture.remove() }
            try require(mkdir(fixture.fixture.path + "/home", 0o700) == 0, "create isolated custody account")
            let location = try StateLocation.isolated(root: fixture.fixture.path)
            try TestIsolation.initializeState(at: location)
            let initializer = try RunAuthority.acquireRun(at: location)
            do { try CustodyCatalogStore.testingInitialize(leases: initializer.retainCommandLeases(), root: fixture.fixture.path) }
            catch { initializer.release(); throw error }
            initializer.release()
            let scope = try selectedScope(fixture)
            func requireExclusive() throws {
                do { _ = try CustodyAuthorityLeaseSet.retainReadLeases(at: location) }
                catch is SecureStateError { return }
                catch is CustodyRecordError { return }
                throw Failure.assertion("borrowed operation released exclusive authority")
            }
            for throwsFromBody in [false, true] {
                let owner = try RunAuthority.acquireRun(at: location)
                defer { owner.release() }
                weak var observed: CommandCustodyContext?
                var escaped: SelectedRepositoryScopeBinder?
                var entered = false, completed = false
                do {
                    let value = try CommandCustodyContext.withPhase(
                        CommandCustodyContext.testing(leases: owner.retainCommandLeases(), location: location,
                            root: fixture.fixture.path, authority: owner)) { phase in
                        observed = phase
                        try require(phase.mode == .mutation, "rebind did not borrow operation EX")
                        let binder = try fixture.make().binder(revalidatePhase: phase.phaseAdmissionCheck())
                        escaped = binder
                        return try binder.withReboundScope(scope, cancellation: CancellationToken()) { rebound in
                            entered = true
                            try requireExclusive()
                            try require(rebound == scope, "borrowed phase changed saved selection")
                            if throwsFromBody { throw Stop.body }
                            return 71
                        }
                    }
                    try require(value == 71, "rebind body value lost")
                    completed = true
                } catch Stop.body { try require(throwsFromBody, "unexpected body error") }
                try require(entered && completed != throwsFromBody && observed == nil && owner.commandAdmissionIsOpen,
                            "rebind phase retained its context or retired parent authority")
                try requireExclusive()
                guard let escaped else { throw Failure.assertion("escaped binder fixture missing") }
                do {
                    _ = try escaped.withReboundScope(scope, cancellation: CancellationToken()) { _ in
                        throw Failure.assertion("escaped borrowed phase admitted inspection")
                    }
                    throw Failure.assertion("escaped borrowed binder accepted")
                } catch SelectedRepositoryScopeError.policyUnavailable {}
                owner.release()
                let next = try RunAuthority.acquireRun(at: location); next.release()
            }
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T19-rebind-borrows-exclusive-authority-through-return-and-throw")

        func metadataFixture() throws -> SessionFixture {
            let fixture = try SessionFixture()
            do {
                try fixture.fixture.write("workspace/products/ready/.git/config", Data("[core]\nrepositoryformatversion = 0\nbare = false\n[remote \"origin\"]\nurl = https://github.com/fixture-owner/ready.git\nfetch = +refs/heads/*:refs/remotes/origin/*\n".utf8))
                try FileManager.default.createDirectory(atPath: fixture.fixture.path + "/workspace/products/ready/.git/objects",
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                return fixture
            } catch { try? fixture.remove(); throw error }
        }
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T20-discovery-uses-bound-policy-coordinates") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            let found = try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                try require(try service.policyRelativePath(scope.repositories[0].repositoryPath) == "products/ready",
                            "policy coordinates retained the home-relative root prefix")
                return try RepositoryDiscovery().discoverMetadata(scope: scope, policy: service)
            }
            try require(found.count == 1, "bound metadata discovery changed selection count")
            try require(found[0].id == "fixture-owner/ready", "bound metadata discovery changed repository identity")
            try require(found[0].presentationLocation == "~/workspace/products/ready",
                        "bound metadata discovery changed presentation coordinates")
            try require(found[0].isEligible,
                        "bound metadata discovery refused permitted fixture: \(String(describing: found[0].blockedReason))")
            try require(found[0].policyAdmissionSHA256 == scope.policyDigest,
                        "bound metadata discovery changed policy digest")
            try require(!FileManager.default.fileExists(atPath: fixture.fixture.path + "/workspace/_ops"),
                        "standalone discovery created or required legacy policy scripts")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T20-discovery-uses-bound-policy-coordinates")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T21-discovery-service-cannot-escape-callback") {
            for throwsFromBody in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), binder = try fixture.make().binder()
                var escaped: RepositoryDiscoveryPolicy?
                do {
                    try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        escaped = service
                        if throwsFromBody { throw GitSafetyError.cancelled }
                    }
                    try require(!throwsFromBody, "callback failure lost")
                } catch GitSafetyError.cancelled { try require(throwsFromBody, "unexpected callback cancellation") }
                guard let escaped else { throw Failure.assertion("service did not enter callback") }
                try denied { try escaped.validate() }
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T21-discovery-service-cannot-escape-callback")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T22-discovery-cancel-and-closed-phase-before-access") {
            for closesPhase in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), cancellation = CancellationToken(), phase = CancellationToken()
                let binder = try fixture.make().binder(revalidatePhase: {
                    if phase.isCancelled { throw PolicyHelperError.unavailable }
                })
                var accesses: [String] = []
                try denied {
                    try binder.withDiscoveryPolicy(scope, cancellation: cancellation) { service in
                        service.testingBeforeAccess = { accesses.append($0) }
                        if closesPhase { phase.cancel() } else { cancellation.cancel() }
                        _ = try RepositoryDiscovery().discoverMetadata(scope: scope, policy: service)
                    }
                }
                try require(accesses.isEmpty, "closed discovery accessed candidate metadata")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T22-discovery-cancel-and-closed-phase-before-access")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T23-discovery-pending-survives-return-and-throw") {
            enum FailureStage: String { case fixture, selection, binder, rebind, callback, pendingCheck, postflight, audit, cleanup }
            for throwsFromBody in [false, true] {
                var stage = FailureStage.fixture
                let started = DispatchTime.now().uptimeNanoseconds
                do {
                    let fixture = try metadataFixture(); defer { try? fixture.remove() }
                    stage = .selection
                    let scope = try selectedScope(fixture), pending = CancellationToken(), audit = CommandAudit()
                    stage = .binder
                    let binder = try fixture.make(audit: audit, resourceCheck: {
                        if pending.isCancelled { throw PolicyHelperError.cleanupPending }
                    }).binder()
                    var callsAtPending = 0
                    do {
                        stage = .rebind
                        try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                            stage = .callback
                            callsAtPending = audit.invocations.count; pending.cancel()
                            stage = .pendingCheck
                            do { try service.requireAllowed(scope.repositories[0].repositoryPath) }
                            catch SelectedRepositoryScopeError.cleanupPending {}
                            stage = .postflight
                            if throwsFromBody { throw GitSafetyError.cancelled }
                        }
                        throw Failure.assertion("pending discovery completed")
                    } catch SelectedRepositoryScopeError.cleanupPending {}
                    stage = .audit
                    try require(audit.invocations.count == callsAtPending, "pending discovery launched a later helper")
                    stage = .cleanup
                    try fixture.remove()
                } catch {
                    // A single closed failure record, independent of optional
                    // detailed traces. Preserve the original error unchanged.
                    fputs("POLICY T23 FAILURE stage=\(stage.rawValue) throws_body=\(throwsFromBody) elapsed_ns=\(DispatchTime.now().uptimeNanoseconds - started)\n", stderr)
                    fflush(stderr)
                    throw error
                }
            }
        }
        onPass("POLICY-SESSION-T23-discovery-pending-survives-return-and-throw")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T24-discovery-refuses-protected-linked-target-before-access") {
            for exactAncestorOnly in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let protectedAncestor = fixture.fixture.path + "/workspace/products/blocked"
                let target = protectedAncestor + (exactAncestorOnly ? "/leaf" : "")
                try fixture.fixture.write("workspace/products/ready/.git/worktrees/linked/gitdir", Data((target + "/.git\n").utf8))
                let audit = CommandAudit()
                let scope = try selectedScope(fixture)
                var allowedLeafVerified = false
                if exactAncestorOnly {
                    // A separate service proves the fixture's leaf rule without
                    // warming discovery's cache or spending its metadata budget.
                    let leafProof = try fixture.make("exact-only").binder()
                    try leafProof.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        try service.requireAllowed(target)
                        allowedLeafVerified = true
                    }
                }
                let binder = try fixture.make(exactAncestorOnly ? "exact-only" : "valid", audit: audit).binder()
                var accesses: [String] = []
                var protectedDecisions: [(path: String, beforeDeadline: Bool)] = []
                var metadataStarted: UInt64?
                try denied {
                    try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        metadataStarted = DispatchTime.now().uptimeNanoseconds
                        service.testingProtectedPath = { path, deadline in
                            protectedDecisions.append((path, DispatchTime.now().uptimeNanoseconds < deadline))
                        }
                        service.testingBeforeAccess = { accesses.append($0) }
                        _ = try RepositoryDiscovery().discoverMetadata(scope: scope, policy: service)
                    }
                }
                try require(!exactAncestorOnly || allowedLeafVerified, "exact ancestor fixture did not allow its leaf")
                let observed = accesses.map { path in
                    path.hasPrefix(fixture.fixture.path + "/")
                        ? String(path.dropFirst(fixture.fixture.path.count)) : "<fixture-root>"
                }.suffix(12).joined(separator: ",")
                let elapsed = metadataStarted.map { DispatchTime.now().uptimeNanoseconds - $0 } ?? 0
                print("METRIC policy-linked-discovery exact=\(exactAncestorOnly) elapsed_ns=\(elapsed) helpers=\(audit.invocations.count)")
                try require(protectedDecisions.contains {
                    $0.path.utf8.elementsEqual(protectedAncestor.utf8) && $0.beforeDeadline
                }, "protected ancestor decision was not observed before deadline: exact=\(exactAncestorOnly) elapsed_ns=\(elapsed)")
                try require(accesses.contains { $0.hasSuffix("/worktrees/linked/gitdir") },
                    "linked registration not reached: exact=\(exactAncestorOnly) entered=\(metadataStarted != nil) elapsed_ns=\(elapsed) helpers=\(audit.invocations.count) observed=\(observed)")
                try require(!accesses.contains { $0 == protectedAncestor || $0.hasPrefix(protectedAncestor + "/") },
                    "protected linked ancestor accessed: exact=\(exactAncestorOnly) observed=\(observed)")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T24-discovery-refuses-protected-linked-target-before-access")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T25-discovery-shares-one-metadata-deadline") {
            for batched in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), audit = CommandAudit()
                let binder = try fixture.make(audit: audit).binder()
                var accesses: [String] = [], callsBefore = -1
                try denied {
                    try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        service.testingBeforeAccess = { accesses.append($0) }
                        callsBefore = audit.invocations.count
                        usleep(800_000)
                        if batched {
                            let path = scope.repositories[0].repositoryPath
                            try service.willAccess([path, path + "/.git", path + "/.git/config"])
                        } else {
                            _ = try RepositoryDiscovery().discoverMetadata(scope: scope, policy: service)
                        }
                    }
                }
                try require(accesses.isEmpty && audit.invocations.count == callsBefore,
                            "discovery extended the expired metadata deadline or launched a helper")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T25-discovery-shares-one-metadata-deadline")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T26-discovery-never-falls-back-to-legacy-git") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            do {
                _ = try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                    try RepositoryDiscovery().discover(scope: scope, policy: service)
                }
                throw Failure.assertion("unintegrated production command path completed")
            } catch RepositoryDiscoveryExecutionError.commandAdapterUnavailable {}
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T26-discovery-never-falls-back-to-legacy-git")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T27-home-relative-presentation-roundtrip-and-refusal") {
            func candidate(_ location: String?) -> RepositoryCandidate {
                RepositoryCandidate(id: "fixture-owner/ready", displayName: "ready",
                    path: "/fixture/unchanged-repository", rawOrigin: "https://github.com/fixture-owner/ready.git",
                    presentationLocation: location)
            }
            for location in ["~", "~/dev", "~/workspace/products/ready"] {
                let value = candidate(location)
                let decoded = try JSONDecoder().decode(RepositoryCandidate.self, from: JSONEncoder().encode(value))
                try require(value.presentationLocation == location && decoded.presentationLocation == location,
                            "safe home-relative presentation did not survive roundtrip")
                try require(decoded.path == "/fixture/unchanged-repository" && decoded.id == "fixture-owner/ready",
                            "presentation changed repository identity or authority path")
            }
            try require(candidate(nil).presentationLocation == nil, "absent presentation became a path")
            let valid = try JSONEncoder().encode(candidate("~/workspace/products/ready"))
            for location in ["", "~/", "~someone/workspace", "/absolute/workspace", "~/workspace//ready",
                             "~/workspace/./ready", "~/workspace/../ready", "~/workspace/\tready",
                             "~/workspace/\nready", "~/workspace/\0ready", "~/" + String(repeating: "x", count: 1_025)] {
                guard var object = try JSONSerialization.jsonObject(with: valid) as? [String: Any] else {
                    throw Failure.assertion("presentation fixture did not encode an object")
                }
                object["presentationLocation"] = location
                let decoded = try JSONDecoder().decode(RepositoryCandidate.self,
                    from: JSONSerialization.data(withJSONObject: object))
                try require(candidate(location).presentationLocation == nil && decoded.presentationLocation == nil,
                            "malformed presentation accepted by initializer or decoder")
                try require(decoded.path == "/fixture/unchanged-repository" && decoded.id == "fixture-owner/ready",
                            "malformed presentation changed repository identity or authority path")
            }
        }
        onPass("POLICY-SESSION-T27-home-relative-presentation-roundtrip-and-refusal")

        func discoveryCommand(_ seconds: TimeInterval = 5) throws -> DiscoveryGitCommand {
            try DiscoveryGitCommand(arguments: ["--no-replace-objects", "--no-lazy-fetch", "symbolic-ref", "--quiet", "--short", "HEAD"],
                                    captureTransportConfiguration: false, timeoutSeconds: seconds)
        }
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T28-command-admission-exact-selection-and-distinct-budget") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            let candidates = try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) {
                try RepositoryDiscovery().discoverMetadata(scope: scope, policy: $0)
            }
            let command = try discoveryCommand(), budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: command.workSeconds)
            try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: command,
                budget: budget, cancellation: CancellationToken()) { service in
                usleep(800_000)
                try service.requireCandidate(candidates[0])
                try service.willAccess(candidates[0].path + "/.git/config")
                try require(service.budget == budget && service.command.arguments == command.arguments,
                            "command admission replaced original command or budget")
                try require(try service.identityCommitment == fixture.snapshot().identityCommitment(),
                            "command admission did not bind current policy file identities")
            }
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T28-command-admission-exact-selection-and-distinct-budget")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T29-command-service-escape-refuses") {
            for throwsFromBody in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), binder = try fixture.make().binder(), command = try discoveryCommand()
                var escaped: RepositoryDiscoveryCommandPolicy?
                do {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: command,
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                        escaped = $0
                        if throwsFromBody { throw GitSafetyError.cancelled }
                    }
                    try require(!throwsFromBody, "command callback failure lost")
                } catch GitSafetyError.cancelled { try require(throwsFromBody, "unexpected command cancellation") }
                guard let escaped else { throw Failure.assertion("command callback not entered") }
                try denied { try escaped.willAccess(scope.repositories[0].repositoryPath) }
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T29-command-service-escape-refuses")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T30-command-pending-survives-caught-error") {
            for throwsFromBody in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), pending = CancellationToken(), audit = CommandAudit()
                let binder = try fixture.make(audit: audit, resourceCheck: {
                    if pending.isCancelled { throw PolicyHelperError.cleanupPending }
                }).binder()
                var calls = 0
                do {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                        calls = audit.invocations.count; pending.cancel()
                        do { try $0.willAccess(scope.repositories[0].repositoryPath) }
                        catch SelectedRepositoryScopeError.cleanupPending {}
                        if throwsFromBody { throw GitSafetyError.cancelled }
                    }
                    throw Failure.assertion("pending discovery command completed")
                } catch SelectedRepositoryScopeError.cleanupPending {}
                try require(audit.invocations.count == calls, "pending command launched another classifier")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T30-command-pending-survives-caught-error")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T31-command-cancel-or-closed-phase-before-access") {
            for closesPhase in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), cancellation = CancellationToken(), phase = CancellationToken()
                let binder = try fixture.make().binder(revalidatePhase: {
                    if phase.isCancelled { throw PolicyHelperError.unavailable }
                })
                var accesses = 0
                try denied {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: cancellation) {
                        $0.testingBeforeAccess = { _ in accesses += 1 }
                        if closesPhase { phase.cancel() } else { cancellation.cancel() }
                        try $0.willAccess(scope.repositories[0].repositoryPath)
                    }
                }
                try require(accesses == 0, "revoked command accessed candidate")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T31-command-cancel-or-closed-phase-before-access")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T32-command-expiry-does-not-renew") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), audit = CommandAudit(), binder = try fixture.make(audit: audit).binder()
            let command = try discoveryCommand(0.1)
            let budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: 0.1,
                now: DispatchTime.now().uptimeNanoseconds
                    - UInt64(ChildProcessBudget.seconds(command.workSeconds) * 1_000_000_000) - 200_000_000)
            let calls = audit.invocations.count
            do {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: command,
                    budget: budget, cancellation: CancellationToken()) { _ in
                    throw Failure.assertion("expired command entered callback")
                }
                throw Failure.assertion("expired command renewed")
            } catch CustodyProtocolError.invalidBudget {}
            try require(audit.invocations.count == calls, "expired command classified candidate")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T32-command-expiry-does-not-renew")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T33-command-protected-ancestor-before-access") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make("exact-only").binder()
            var accesses = 0
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                    $0.testingBeforeAccess = { _ in accesses += 1 }
                    try $0.willAccess(scope.repositories[0].repositoryPath + "/blocked/allowed-leaf")
                }
            }
            try require(accesses == 0, "command crossed a protected ancestor")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T33-command-protected-ancestor-before-access")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T34-unadmitted-config-paths-refuse-and-stick") {
            for suffix in ["/.gitconfig", "/.config/git/config", "external"] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), binder = try fixture.make().binder()
                var accesses = 0
                try denied {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) { service in
                        service.testingBeforeAccess = { _ in accesses += 1 }
                        let path = suffix == "external" ? "/fixture-system/config" : fixture.fixture.path + suffix
                        try denied { try service.willAccess(path) }
                        // A caller cannot swallow configuration refusal and
                        // fall back to an apparently valid repository command.
                        try denied { try service.willAccess(scope.repositories[0].repositoryPath) }
                    }
                }
                try require(accesses == 0, "unadmitted configuration reached access callback")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T34-unadmitted-config-paths-refuse-and-stick")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T35-identical-policy-replacement-revokes-command") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            var accesses = 0
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                    $0.testingBeforeAccess = { _ in accesses += 1 }
                    try fixture.fixture.write("replacement", fixture.fixture.contents["owner/policy.yml"]!)
                    try require(rename(fixture.fixture.path + "/replacement", fixture.fixture.path + "/owner/policy.yml") == 0,
                                "replace identical current command policy")
                    try $0.willAccess(scope.repositories[0].repositoryPath)
                }
            }
            try require(accesses == 0, "stale command accessed candidate after policy replacement")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T35-identical-policy-replacement-revokes-command")

        try RuntimeFixtureSession.withCase("POLICY-SESSION-T36-command-refuses-unselected-sibling-before-classifier") {
            for validatesCandidateFirst in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), audit = CommandAudit(), binder = try fixture.make(audit: audit).binder()
                let candidates = try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) {
                    try RepositoryDiscovery().discoverMetadata(scope: scope, policy: $0)
                }
                var accesses = 0, calls = 0
                try denied {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                        if validatesCandidateFirst { try $0.requireCandidate(candidates[0]) }
                        $0.testingBeforeAccess = { _ in accesses += 1 }
                        calls = audit.invocations.count
                        try $0.willAccess(scope.repositories[0].repositoryPath + "-sibling/.git/config")
                    }
                }
                try require(accesses == 0 && calls > 0 && audit.invocations.count == calls,
                            "selected command admitted an unselected sibling")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T36-command-refuses-unselected-sibling-before-classifier")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T37-command-expiry-during-rebind-stops-access") {
            final class Observation: @unchecked Sendable {
                let lock = NSLock()
                private var values: [UInt64] = []
                func record(_ value: UInt64) { lock.lock(); values.append(value); lock.unlock() }
                var deadlines: [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
            }
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), observation = Observation()
            let admission = RepositorySelectionPathAdmission(evaluate: { paths, deadline in
                observation.record(deadline)
                usleep(150_000)
                return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
            }, revalidate: {})
            let binder = try SelectedRepositoryScopeBinder(snapshot: fixture.snapshot(), admission: admission)
            let command = try discoveryCommand(0.1)
            // Deliberately use an absolute 100ms fixture budget, within the
            // configured ceiling even when child-budget test scaling is active.
            let issued = DispatchTime.now().uptimeNanoseconds, work = issued + 100_000_000
            let budget = try CustodyBudget(wire: .object([
                "issued": .unsigned(issued), "work": .unsigned(work), "term": .unsigned(work),
                "kill": .unsigned(work), "receipt": .unsigned(work),
            ]))
            var entered = false
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: command,
                    budget: budget, cancellation: CancellationToken()) { _ in entered = true }
            }
            try require(!entered && observation.deadlines == [budget.work],
                        "command rebinding renewed its deadline or continued after expiry")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T37-command-expiry-during-rebind-stops-access")

        try RuntimeFixtureSession.withCase("POLICY-SESSION-T38-command-replaced-selected-directory-refuses") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            var accesses = 0
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                    $0.testingBeforeAccess = { _ in accesses += 1 }
                    let path = scope.repositories[0].repositoryPath
                    try require(rename(path, path + "-preserved") == 0 && mkdir(path, 0o700) == 0,
                                "replace selected fixture directory")
                    // Deliberately omit optional requireCandidate: every access
                    // must independently reject a same-path substitute checkout.
                    try $0.willAccess(path + "/.git/config")
                }
            }
            try require(accesses == 0, "command accessed a replaced selected directory")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T38-command-replaced-selected-directory-refuses")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T39-command-stage-does-not-reuse-expired-setup") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture)
            let session = try fixture.make()
            let binder = try session.binder(setupDeadline: DispatchTime.now().uptimeNanoseconds + 100_000_000)
            usleep(150_000)
            try denied { _ = try binder.processFreeCatalog(preferences: nil, generation: 1) }
            var accesses = 0
            let budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: 5)
            try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                budget: budget, cancellation: CancellationToken()) {
                $0.testingBeforeAccess = { _ in accesses += 1 }
                try $0.willAccess(scope.repositories[0].repositoryPath + "/.git/config")
                try require($0.budget == budget, "fresh command renewed its original budget")
            }
            try require(accesses == 1, "expired setup blocked independent command stage")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T39-command-stage-does-not-reuse-expired-setup")

        try RuntimeFixtureSession.withCase("POLICY-SESSION-T40-configuration-derived-sources-without-catalog-expansion") {
            for system in [nil, "/fixture-system/gitconfig"] as [String?] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), audit = CommandAudit(), session = try fixture.make(audit: audit)
                let binder = try session.binder(), preflight = try GitConfigurationPreflight.testing(systemPath: system, account: fixture.account)
                var calls = 0
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) { service in
                    try service.withConfiguration(preflight) { admitted in
                        calls += 1
                        try require(admitted.paths == preflight.paths && admitted.systemPath == system,
                                    "configuration admission changed derived sources")
                    }
                }
                try require(calls == 1, "derived configuration callback was not admitted")
                let before = audit.invocations.count
                try denied {
                    _ = try session.admission.classify([RepositorySelectionAdmissionPath(root: "~", components: [".gitconfig"])],
                                                       deadline: deadline())
                }
                try require(audit.invocations.count == before, "configuration classification widened catalog access")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T40-configuration-derived-sources-without-catalog-expansion")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T41-configuration-protected-ancestor-refuses-before-consumption") {
            for mode in ["exact-only", "config-ancestor"] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), binder = try fixture.make(mode).binder()
                let preflight = try GitConfigurationPreflight.testing(systemPath: mode == "exact-only" ? "/blocked/gitconfig" : nil,
                                                                     account: fixture.account)
                var calls = 0
                try denied {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) { service in
                        try denied { try service.withConfiguration(preflight) { _ in calls += 1 } }
                        try denied { try service.willAccess(scope.repositories[0].repositoryPath) }
                    }
                }
                try require(calls == 0, "protected configuration ancestor reached resource consumer")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T41-configuration-protected-ancestor-refuses-before-consumption")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T42-configuration-account-mismatch-refuses-before-classifier") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), audit = CommandAudit(), binder = try fixture.make(audit: audit).binder()
            let other = EffectiveAccount(uid: fixture.account.uid, username: "other-fixture-account", homeDirectory: fixture.account.homeDirectory)
            let preflight = try GitConfigurationPreflight.testing(systemPath: nil, account: other)
            var calls = 0, before = 0
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) { service in
                    before = audit.invocations.count
                    try service.withConfiguration(preflight) { _ in calls += 1 }
                }
            }
            try require(calls == 0 && audit.invocations.count == before, "foreign account reached configuration classifier")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T42-configuration-account-mismatch-refuses-before-classifier")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T43-missing-configuration-adapter-refuses") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), session = try fixture.make()
            let binder = try SelectedRepositoryScopeBinder(snapshot: fixture.snapshot(), admission: session.admission)
            let preflight = try GitConfigurationPreflight.testing(systemPath: nil, account: fixture.account)
            var calls = 0
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                    try $0.withConfiguration(preflight) { _ in calls += 1 }
                }
            }
            try require(calls == 0, "missing configuration adapter became permissive")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T43-missing-configuration-adapter-refuses")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T44-configuration-policy-drift-postflight-refuses") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            let preflight = try GitConfigurationPreflight.testing(systemPath: nil, account: fixture.account)
            var calls = 0
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) {
                    try $0.withConfiguration(preflight) { _ in
                        calls += 1
                        try fixture.fixture.write("owner/replacement", fixture.fixture.contents["owner/overlay.json"]!)
                        try require(rename(fixture.fixture.path + "/owner/replacement", fixture.fixture.path + "/owner/overlay.json") == 0,
                                    "replace configuration policy fixture")
                    }
                }
            }
            try require(calls == 1, "configuration drift fixture never reached admitted consumer")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T44-configuration-policy-drift-postflight-refuses")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T45-configuration-pending-and-escaped-service-refuse") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), pending = CancellationToken()
            let binder = try fixture.make(resourceCheck: {
                if pending.isCancelled { throw PolicyHelperError.cleanupPending }
            }).binder()
            let preflight = try GitConfigurationPreflight.testing(systemPath: nil, account: fixture.account)
            var escaped: RepositoryDiscoveryCommandPolicy?, calls = 0
            do {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                    budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) { service in
                    escaped = service; pending.cancel()
                    do { try service.withConfiguration(preflight) { _ in calls += 1 } }
                    catch SelectedRepositoryScopeError.cleanupPending {}
                }
                throw Failure.assertion("pending configuration became command success")
            } catch SelectedRepositoryScopeError.cleanupPending {}
            guard let escaped else { throw Failure.assertion("configuration escape fixture missing") }
            do {
                try escaped.withConfiguration(preflight) { _ in calls += 1 }
                throw Failure.assertion("escaped pending configuration reopened admission")
            } catch SelectedRepositoryScopeError.cleanupPending {}
            try require(calls == 0, "pending configuration invoked consumer")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T45-configuration-pending-and-escaped-service-refuse")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T46-configuration-expiry-does-not-renew-command-budget") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), expire = CancellationToken()
            let command = try discoveryCommand(0.1), budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: 0.1)
            let binder = try fixture.make(resourceCheck: {
                if expire.isCancelled {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < budget.work { usleep(UInt32((budget.work - now) / 1_000 + 1_000)) }
                }
            }).binder()
            let preflight = try GitConfigurationPreflight.testing(systemPath: nil, account: fixture.account)
            var calls = 0, entered = false
            try denied {
                try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: command,
                    budget: budget, cancellation: CancellationToken()) { service in
                    entered = true; expire.cancel()
                    try service.withConfiguration(preflight) { _ in calls += 1 }
                }
            }
            try require(entered && calls == 0, "configuration preparation renewed expired command budget")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T46-configuration-expiry-does-not-renew-command-budget")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T47-configuration-batches-preserve-original-deadline") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), audit = CommandAudit(), binder = try fixture.make(audit: audit).binder()
            let preflight = try GitConfigurationPreflight.testing(
                systemPath: "/fixture-system/" + Array(repeating: "part", count: 70).joined(separator: "/") + "/gitconfig", account: fixture.account)
            let budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: 5)
            var calls = 0
            try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                budget: budget, cancellation: CancellationToken()) { service in
                let before = audit.invocations.count
                try service.withConfiguration(preflight) { _ in calls += 1 }
                try require(audit.invocations.count >= before + 4 && service.budget == budget,
                            "configuration batching skipped paths or replaced original command deadline")
            }
            try require(calls == 1, "batched configuration did not reach consumer")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T47-configuration-batches-preserve-original-deadline")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T48-configuration-callback-pending-overrides-caught-errors") {
            for indirect in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), pending = CancellationToken(), audit = CommandAudit()
                let binder = try fixture.make(audit: audit, resourceCheck: {
                    if pending.isCancelled { throw PolicyHelperError.cleanupPending }
                }).binder()
                let preflight = try GitConfigurationPreflight.testing(systemPath: nil, account: fixture.account)
                var calls = 0, atFailure = 0
                do {
                    try binder.withDiscoveryCommandPolicy(scope, selected: scope.repositories[0], command: discoveryCommand(),
                        budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 5), cancellation: CancellationToken()) { service in
                        do {
                            try service.withConfiguration(preflight) { _ in
                                calls += 1; atFailure = audit.invocations.count
                                if indirect { pending.cancel(); throw GitSafetyError.cancelled }
                                throw SystemGitConfigurationError.cleanupPending
                            }
                            throw Failure.assertion("configuration callback pending was lost")
                        } catch SelectedRepositoryScopeError.cleanupPending {}
                        do {
                            try service.willAccess(scope.repositories[0].repositoryPath)
                            throw Failure.assertion("caught configuration pending reopened admission")
                        } catch SelectedRepositoryScopeError.cleanupPending {}
                    }
                    throw Failure.assertion("caught configuration pending became completion")
                } catch SelectedRepositoryScopeError.cleanupPending {}
                try require(calls == 1 && audit.invocations.count == atFailure,
                            "pending configuration callback spawned more classification")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T48-configuration-callback-pending-overrides-caught-errors")

        func metadataCandidate(_ fixture: SessionFixture, _ scope: ValidatedSelectedRepositoryScope) throws -> RepositoryCandidate {
            let binder = try fixture.make().binder()
            return try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) {
                let values = try RepositoryDiscovery().discoverMetadata(scope: scope, policy: $0)
                try require(values.count == 1 && values[0].isEligible, "metadata read fixture candidate")
                return values[0]
            }
        }
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T49-live-metadata-read-results") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let access = DiscoveryMetadataAccess(binder: try fixture.make().binder(), scope: scope, cancellation: CancellationToken())
            let handle = try access.withRead(candidate, .identity) { try RepositoryHandle.open(candidate) }
            try DiscoveryMetadataAccess.withHandle(access, handle, .busy) { try handle.rejectBusyState() }
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .topology) { try handle.verifyNoRegisteredLinkedWorktrees() }, "metadata topology changed")
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .index) { try handle.readOnlyHiddenIndexState() } == false, "metadata index changed")
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .mainReference) { try handle.readOnlyMainCommit() } == nil, "metadata main changed")
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .remoteReference) { try handle.readOnlyRemoteMainCommit() } == nil, "metadata remote changed")
            let oid = String(repeating: "a", count: 40)
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .looseCommit(oid)) { try handle.readOnlyLooseCommitObject(oid) } == nil, "metadata object changed")
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .primaryClaim(candidate.path)) { try handle.verifyWorktreeClaim(path: candidate.path).isPrimary }, "metadata claim changed")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T49-live-metadata-read-results")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T50-metadata-leaf-ancestor-denial-before-read") {
            for mode in ["metadata-index", "metadata-object-ancestor"] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
                let access = DiscoveryMetadataAccess(binder: try fixture.make(mode).binder(), scope: scope, cancellation: CancellationToken())
                var reads = 0
                try denied { try access.withRead(candidate, .index) { reads += 1 } }
                try require(reads == 0, "protected metadata reached read body")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T50-metadata-leaf-ancestor-denial-before-read")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T51-metadata-cancel-closed-phase-before-read") {
            for closePhase in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
                let cancellation = CancellationToken(), phase = CancellationToken(), audit = CommandAudit()
                let binder = try fixture.make(audit: audit).binder(revalidatePhase: {
                    if phase.isCancelled { throw PolicyHelperError.unavailable }
                })
                let access = DiscoveryMetadataAccess(binder: binder, scope: scope, cancellation: cancellation)
                if closePhase { phase.cancel() } else { cancellation.cancel() }
                var reads = 0
                do {
                    try access.withRead(candidate, .identity) { reads += 1 }
                    throw Failure.assertion("cancelled metadata stage completed")
                } catch GitSafetyError.cancelled { try require(!closePhase, "wrong metadata phase refusal") }
                catch SelectedRepositoryScopeError.policyUnavailable { try require(closePhase, "wrong metadata cancellation refusal") }
                try require(reads == 0 && audit.invocations.isEmpty, "closed metadata phase reached classification or read body")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T51-metadata-cancel-closed-phase-before-read")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T52-metadata-policy-drift-before-and-after-read") {
            for beforeRead in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
                let access = DiscoveryMetadataAccess(binder: try fixture.make().binder(), scope: scope, cancellation: CancellationToken())
                func replacePolicy() throws {
                    try fixture.fixture.write("replacement", fixture.fixture.contents["owner/policy.yml"]!)
                    try require(rename(fixture.fixture.path + "/replacement", fixture.fixture.path + "/owner/policy.yml") == 0, "replace metadata policy fixture")
                }
                if beforeRead { try replacePolicy() }
                var reads = 0
                try denied {
                    try access.withRead(candidate, .identity) {
                        reads += 1
                        if !beforeRead { try replacePolicy() }
                    }
                }
                try require(reads == (beforeRead ? 0 : 1), "metadata drift boundary changed")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T52-metadata-policy-drift-before-and-after-read")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T53-metadata-closed-path-roster") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let audit = CommandAudit(), access = DiscoveryMetadataAccess(binder: try fixture.make(audit: audit).binder(), scope: scope, cancellation: CancellationToken())
            for read in [DiscoveryMetadataAccess.Read.looseCommit("../foreign"), .primaryClaim(candidate.path + "/foreign")] {
                let before = audit.invocations.count
                do {
                    try access.withRead(candidate, read) { throw Failure.assertion("foreign metadata read body") }
                    throw Failure.assertion("foreign metadata accepted")
                } catch SelectedRepositoryScopeError.changed {}
                try require(audit.invocations.count == before, "foreign metadata reached classifier")
            }
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T53-metadata-closed-path-roster")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T54-inventory-missing-transport-no-fallback") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), binder = try fixture.make().binder()
            do {
                _ = try RepositoryDiscovery().discover(scope: scope, binder: binder, cancellation: CancellationToken())
                throw Failure.assertion("inventory without transport completed")
            } catch RepositoryDiscoveryExecutionError.commandAdapterUnavailable {}
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T54-inventory-missing-transport-no-fallback")

        // The marker is inside the fixture policy's denied subtree. Each old
        // multi-component syscall would either find/read it or return a different
        // error. Require the ancestor refusal itself, not merely any failure.
        func metadataAlias(_ alias: String, leaf: String, read: DiscoveryMetadataAccess.Read,
                           operation: (RepositoryHandle) throws -> Void) throws {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let access = DiscoveryMetadataAccess(binder: try fixture.make().binder(), scope: scope,
                                                 cancellation: CancellationToken())
            let handle = try access.withRead(candidate, .identity) { try RepositoryHandle.open(candidate) }
            let target = fixture.fixture.path + "/workspace/products/blocked"
            let marker = target + "/" + leaf
            let bytes = Data((String(repeating: "a", count: 40) + "\n").utf8)
            try fixture.fixture.write("workspace/products/blocked/" + leaf, bytes)
            let link = candidate.path + "/.git/" + alias
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: link).deletingLastPathComponent().path,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var enteredPrimitive = false
            do {
                try DiscoveryMetadataAccess.withHandle(access, handle, read) {
                    // Static aliases are covered by catalog admission tests.
                    // Install this alias after fresh binding, at the actual read
                    // boundary, so catalog refusal cannot mask the primitive.
                    var existing = stat()
                    if lstat(link, &existing) == 0 {
                        try require(rename(link, target + "/saved-alias-parent") == 0, "preserve fixture metadata parent")
                    } else { try require(errno == ENOENT, "fixture metadata parent inspection") }
                    try require(symlink(target, link) == 0, "fixture intermediate metadata symlink")
                    enteredPrimitive = true
                    try operation(handle)
                }
                throw Failure.assertion("metadata intermediate symlink accepted")
            } catch GitSafetyError.unsafeRepository(let reason) {
                try require(enteredPrimitive && reason == "cannot traverse Git resource without following links",
                            "metadata reached target or wrong refusal: " + reason)
            }
            try require(try Data(contentsOf: URL(fileURLWithPath: marker)) == bytes, "fixture target changed")
            try fixture.remove()
        }
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T55-busy-intermediate-symlink-refused") {
            for alias in ["refs/heads", "refs/remotes/origin"] {
                try metadataAlias(alias, leaf: "main.lock", read: .busy) { try $0.rejectBusyState() }
            }
        }
        onPass("POLICY-SESSION-T55-busy-intermediate-symlink-refused")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T56-reference-intermediate-symlink-refused") {
            // Exercise the shared reference primitive beyond the main busy-marker
            // paths. This is a disposable primitive fixture, not a new production
            // discovery command or grant for an additional selected branch.
            try metadataAlias("refs/heads/topic", leaf: "deep", read: .mainReference) {
                _ = try $0.readOnlyLocalBranchCommit("refs/heads/topic/deep")
            }
        }
        onPass("POLICY-SESSION-T56-reference-intermediate-symlink-refused")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T57-graph-metadata-intermediate-symlink-refused") {
            for (alias, leaf) in [("refs", "replace"), ("info", "grafts"), ("objects/info", "alternates")] {
                try metadataAlias(alias, leaf: leaf, read: .identity) { try $0.rejectReplacementAndGraftState() }
            }
        }
        onPass("POLICY-SESSION-T57-graph-metadata-intermediate-symlink-refused")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T58-loose-object-intermediate-symlink-refused") {
            let oid = String(repeating: "a", count: 40)
            try metadataAlias("objects/aa", leaf: String(oid.dropFirst(2)), read: .looseCommit(oid)) {
                _ = try $0.readOnlyLooseCommitObject(oid)
            }
        }
        onPass("POLICY-SESSION-T58-loose-object-intermediate-symlink-refused")

        try RuntimeFixtureSession.withCase("POLICY-SESSION-T59-index-fifo-refused-without-writer") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let access = DiscoveryMetadataAccess(binder: try fixture.make().binder(), scope: scope,
                                                 cancellation: CancellationToken())
            let handle = try access.withRead(candidate, .identity) { try RepositoryHandle.open(candidate) }
            let path = candidate.path + "/.git/index"
            try require(mkfifo(path, 0o600) == 0, "fixture index FIFO create")
            // There is deliberately no writer. A blocking open cannot reach the
            // regular-file refusal or release the live metadata callback.
            do {
                _ = try DiscoveryMetadataAccess.withHandle(access, handle, .index) { try handle.readOnlyHiddenIndexState() }
                throw Failure.assertion("index FIFO accepted")
            } catch GitSafetyError.unsafeRepository(let reason) {
                try require(reason == "index metadata identity is unsafe", "index FIFO did not reach bounded type refusal")
            }
            try require(unlink(path) == 0, "fixture index FIFO removal")
            try require(try DiscoveryMetadataAccess.withHandle(access, handle, .index) {
                try handle.readOnlyHiddenIndexState()
            } == false, "metadata authority failed to unwind after FIFO refusal")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T59-index-fifo-refused-without-writer")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T60-lexical-shelf-child-prefetch-preserves-admission-bounds") {
            let projection = "/fixture/home/workspace", child = projection + "/personal/ready"
            let marker = child + "/.git"
            let metadata = ["config", "refs", "refs/remotes", "refs/remotes/origin", "refs/remotes/origin/HEAD"]
                .map { marker + "/" + $0 }
            func expand(_ required: [String], cached: Set<Data> = []) -> [String] {
                PolicyCatalogSession.prefetchCatalogMetadata(required, cached: cached,
                    projectionRoot: projection, shelves: [["personal"], ["capabilities", "tools"]])
            }
            try require(expand([child]) == [child, marker] + metadata, "shelf child did not share fixed metadata request")
            for path in [projection + "/other/ready", projection + "/personal/ready/nested",
                         projection + "/personal/.hidden", projection + "/personal/.GIT",
                         projection + "-other/personal/ready", "/fixture/home/personal/ready"] {
                try require(expand([path]) == [path], "speculative marker escaped authenticated shelf child")
            }
            let cached = Set(([marker] + metadata).map { Data($0.utf8) })
            try require(expand([child], cached: cached) == [child], "prefetch repeated cached metadata")
            let reserved = [child] + (0..<63).map { projection + "/personal/required-\($0)" }
            try require(expand(reserved) == reserved, "prefetch displaced mandatory full-batch candidates")
            let partial = Array(reserved.dropLast())
            try require(expand(partial) == partial + [marker], "prefetch exceeded final transport slot")
            let nearFull = Set((0..<4094).map { Data((projection + "/cached-\($0)").utf8) })
            try require(expand([child], cached: nearFull) == [child, marker], "prefetch exceeded final cache slot")
            try require(expand([child], cached: nearFull.union([Data("last cached entry".utf8)])) == [child],
                        "prefetch consumed mandatory cache slot")
            let unicode = projection + "/personal/e\u{301}"
            let unicodeResult = expand([unicode])
            try require(unicodeResult[1].utf8.elementsEqual((unicode + "/.git").utf8), "prefetch normalized candidate bytes")
            let rootChild = projection + "/root-ready", rootMarker = rootChild + "/.git"
            let rootMetadata = ["config", "refs", "refs/remotes", "refs/remotes/origin", "refs/remotes/origin/HEAD"]
                .map { rootMarker + "/" + $0 }
            try require(expand([rootChild]) == [rootChild, rootMarker] + rootMetadata,
                        "visible root child did not share fixed metadata request")
            for path in [projection + "/.hidden", projection + "/.GIT", projection + "-other/root-ready",
                         projection + "/root-ready/nested", "/fixture/home/root-ready"] {
                try require(expand([path]) == [path], "root prefetch escaped exact visible child")
            }
            try require(expand([rootChild], cached: [Data(rootMarker.utf8)]) == [rootChild] + rootMetadata,
                        "cached root marker suppressed uncached fixed metadata")
            let rootCached = Set(([rootMarker] + rootMetadata).map { Data($0.utf8) })
            try require(expand([rootChild], cached: rootCached) == [rootChild], "root prefetch repeated cached metadata")
            let rootReserved = [rootChild] + (0..<63).map { projection + "/root-required-\($0)" }
            try require(expand(rootReserved) == rootReserved, "root prefetch displaced mandatory full-batch candidates")
            let rootPartial = Array(rootReserved.dropLast())
            try require(expand(rootPartial) == rootPartial + [rootMarker], "root prefetch exceeded final transport slot")
            try require(expand([rootChild], cached: nearFull) == [rootChild, rootMarker],
                        "root prefetch exceeded final cache slot")
            try require(expand([rootChild], cached: nearFull.union([Data("last cached entry".utf8)])) == [rootChild],
                        "root prefetch consumed mandatory cache slot")
            let rootUnicode = projection + "/e\u{301}"
            let rootUnicodeResult = expand([rootUnicode])
            try require(rootUnicodeResult.count == 7
                && rootUnicodeResult[1].utf8.elementsEqual((rootUnicode + "/.git").utf8),
                "root prefetch normalized candidate bytes")
            let decomposedRoot = "/fixture/home/e\u{301}"
            let decomposedChild = decomposedRoot + "/root-ready"
            let decomposedResult = PolicyCatalogSession.prefetchCatalogMetadata([decomposedChild], cached: [],
                projectionRoot: decomposedRoot)
            try require(decomposedResult.count == 7
                && decomposedResult[1].utf8.elementsEqual((decomposedChild + "/.git").utf8),
                "root prefetch normalized projection bytes")
            let composedChild = "/fixture/home/\u{e9}/root-ready"
            try require(PolicyCatalogSession.prefetchCatalogMetadata([composedChild], cached: [],
                projectionRoot: decomposedRoot) == [composedChild], "root parent accepted canonically equivalent wrong bytes")
        }
        onPass("POLICY-SESSION-T60-lexical-shelf-child-prefetch-preserves-admission-bounds")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T61-diagnostic-opt-in-and-concurrent-output-bounds") {
            final class TraceProbe: @unchecked Sendable {
                private let lock = NSLock()
                private var lines: [String] = []
                private var formats = 0
                func render(_ text: String) -> String {
                    lock.lock(); defer { lock.unlock() }
                    formats += 1; return text
                }
                func append(_ text: String) {
                    lock.lock(); defer { lock.unlock() }; lines.append(text)
                }
                func snapshot() -> ([String], Int) {
                    lock.lock(); defer { lock.unlock() }; return (lines, formats)
                }
            }
            // The observation must retain the actual throw, restore nesting,
            // preserve errno, and emit no diagnostic from successful work.
            typealias Busy = DiscoveryFixtureDiagnostic.RepositoryBusyObservation
            final class BusySentinel: Error {}
            let sentinel = BusySentinel()
            var observed: [Busy.Snapshot] = []
            do {
                try Busy.observe(enabled: true, failure: { observed.append($0) }) {
                    Busy.transition(.admit)
                    do {
                        try Busy.observe(enabled: true, failure: { observed.append($0) }) {
                            Busy.transition(.executing); Busy.busy(.catalogFileLock)
                            errno = EBUSY; throw sentinel
                        }
                    } catch { try require(error as AnyObject === sentinel && errno == EBUSY,
                        "busy observation changed nested error or errno") }
                    Busy.busy(.catalogMutex); errno = EAGAIN; throw sentinel
                }
            } catch { try require(error as AnyObject === sentinel && errno == EAGAIN,
                "busy observation changed original error or errno") }
            try require(observed == [.init(transition: .executing, site: .catalogFileLock),
                                     .init(transition: .admit, site: .catalogMutex)],
                        "busy observation lost scoped throwing boundary")
            Busy.transition(.executing); Busy.busy(.catalogFileLock) // No stale scope may survive.
            do {
                try Busy.observe(enabled: true, failure: { observed.append($0) }) { throw sentinel }
            } catch { try require(error as AnyObject === sentinel, "busy observation replaced error") }
            try require(observed.last == Busy.Snapshot(), "busy observation leaked a preceding attempt")
            Busy.observe(enabled: true, failure: { observed.append($0) }) { Busy.busy(.catalogMutex) }
            do {
                try Busy.observe(enabled: false, failure: { observed.append($0) }) { throw sentinel }
            } catch { try require(error as AnyObject === sentinel, "disabled observer changed error") }
            try require(observed.count == 3, "success or disabled observer published failure")
            let frame = "DISCOVERY REPOSITORY CUSTODIAN FIRST FAILURE event=spawnTargetFailure error=busy"
                + " transition=admit busy_site=catalogFileLock\n"
            let projected = DiscoveryFixtureDiagnostic.repositoryCustodianFailureProjection(Data(frame.utf8))
            try require(projected?.event == "spawnTargetFailure" && projected?.error == "busy"
                && projected?.detail == Busy.Snapshot(transition: .admit, site: .catalogFileLock),
                "closed custody busy frame lost exact fields")
            for malformed in [String(frame.dropLast()), "prefix" + frame, frame + "tail\n",
                frame.replacingOccurrences(of: "catalogFileLock", with: "/fixture/untrusted"),
                frame.replacingOccurrences(of: "transition=admit", with: "transition=admit extra=true"),
                frame.replacingOccurrences(of: "error=busy", with: "error=fenced")] {
                try require(DiscoveryFixtureDiagnostic.repositoryCustodianFailureProjection(Data(malformed.utf8)) == nil,
                            "custody busy projection accepted non-closed output")
            }
            try require(DiscoveryFixtureDiagnostic.repositoryCustodianFailureProjection(Data(("target output\n" + frame).utf8)) != nil,
                        "complete final custody frame was lost after bounded target output")
            // The expected wrong-origin control runs before the observed
            // parallel failure. It may consume only ordinary evidence.
            typealias FailureSelection = DiscoveryFixtureDiagnostic.RepositoryResultFailureSelection
            let selection = FailureSelection()
            try require(!selection.take(enabled: false, observeCustodianFailure: false)
                && !selection.take(enabled: false, observeCustodianFailure: true)
                && selection.take(enabled: true, observeCustodianFailure: false)
                && !selection.take(enabled: true, observeCustodianFailure: false)
                && selection.take(enabled: true, observeCustodianFailure: true)
                && !selection.take(enabled: true, observeCustodianFailure: true),
                "earlier refusal consumed observed evidence or disabled selection consumed a slot")
            let reversed = FailureSelection()
            try require(reversed.take(enabled: true, observeCustodianFailure: true)
                && reversed.take(enabled: true, observeCustodianFailure: false),
                "observed evidence consumed ordinary first-failure slot")
            let concurrentSelection = FailureSelection(), selectedFailures = TraceProbe()
            DispatchQueue.concurrentPerform(iterations: 1_000) { index in
                let observed = index % 2 == 0
                if concurrentSelection.take(enabled: true, observeCustodianFailure: observed) {
                    selectedFailures.append(observed ? "observed" : "ordinary")
                }
            }
            try require(selectedFailures.snapshot().0.sorted() == ["observed", "ordinary"],
                "concurrent repository failure selection exceeded its two closed slots")
            typealias Sink = DiscoveryFixtureDiagnostic.Sink
            typealias Samples = DiscoveryFixtureDiagnostic.SampleBudget
            let sampled = TraceProbe(), unsampled = TraceProbe()
            let sampleBudget = Samples(enabled: true), disabledBudget = Samples(enabled: false)
            DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
                if sampleBudget.take() { sampled.append("sample") }
                if disabledBudget.take() { unsampled.append("unexpected") }
            }
            try require(sampled.snapshot().0.count == Samples.maximumSamples
                && unsampled.snapshot().0.isEmpty && !sampleBudget.take(),
                "revalidation samples escaped opt-in or concurrent process bound")
            let quiet = TraceProbe(), active = TraceProbe()
            let disabled = Sink(enabled: false, writer: { quiet.append($0) })
            let enabled = Sink(enabled: true, writer: { active.append($0) })
            DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
                disabled.emit(quiet.render("disabled diagnostic\n"))
                enabled.emit(active.render("bounded diagnostic\n"))
            }
            let (quietLines, quietFormats) = quiet.snapshot()
            try require(quietLines.isEmpty && quietFormats == 0, "disabled tracing performed output or formatting")
            let (activeLines, activeFormats) = active.snapshot()
            try require(activeFormats == Sink.maximumRecords && activeLines.count == Sink.maximumRecords + 1,
                        "concurrent tracing escaped record budget or formatted after suppression")
            try require(activeLines.last == Sink.suppression
                && activeLines.filter { $0 == Sink.suppression }.count == 1,
                "diagnostic suppression was missing or repeated")
            try require(activeLines.joined().utf8.count <= Sink.maximumBytes, "diagnostic byte budget exceeded")
            // Exercise the actual routing seam after ordinary capacity is gone.
            // Registry progress is not failure and must not exhaust its reserve.
            let progress = TraceProbe(), failures = TraceProbe()
            let progressSink = Sink(enabled: true, writer: { progress.append($0) })
            let failuresSink = Sink(enabled: true, writer: { failures.append($0) })
            func route(_ component: DiscoveryFixtureDiagnostic.Component,
                       _ stage: DiscoveryFixtureDiagnostic.Stage, _ succeeded: Bool,
                       _ text: String) {
                DiscoveryFixtureDiagnostic.sinkForRecord(component, stage: stage, succeeded: succeeded,
                    ordinary: progressSink, failures: failuresSink).emit(text)
            }
            for _ in 0..<1_000 {
                route(.catalog, .entry, true, "successful catalog\n")
                route(.registry, .retired, false, "registry progress\n")
                route(.policyPreparation, .postflight, true, "successful preparation\n")
                route(.publication, .preparedWrite, true, "successful publication\n")
                route(.helperPreparation, .postflight, true, "successful helper preparation\n")
            }
            try require(progress.snapshot().0.last == Sink.suppression && failures.snapshot().0.isEmpty,
                        "progress tracing consumed the failure reserve")
            let terminal: [(DiscoveryFixtureDiagnostic.Component, DiscoveryFixtureDiagnostic.Stage)] = [
                (.admission, .deadlineBefore), (.admission, .revalidation), (.admission, .deadlineAfter),
                (.session, .snapshot), (.catalog, .decisions), (.transport, .execution),
                (.custody, .result), (.binder, .root), (.selection, .projection),
                (.rebind, .postflight), (.discovery, .metadata), (.publisher, .runtimeTree),
                (.registry, .failure), (.policyPreparation, .authorityConstruction),
                (.policyPreparation, .resources), (.publication, .lockValidation),
                (.publication, .catalogFence), (.publication, .reservationWrite),
                (.publication, .preparedWrite), (.helperPreparation, .suspendedSpawn),
                (.helperPreparation, .suspendedVerification), (.helperPreparation, .ownerTransfer),
                (.phase, .entry), (.phase, .resources), (.phase, .lockValidation),
                (.phase, .installationFence), (.phase, .authorityAfter), (.phase, .metadata), (.phase, .postflight)
            ]
            for (component, stage) in terminal {
                route(component, stage, false, "terminal \(component.rawValue) \(stage.rawValue)\n")
            }
            try require(failures.snapshot().0 == terminal.map { "terminal \($0.0.rawValue) \($0.1.rawValue)\n" },
                        "a terminal diagnostic was lost after progress saturation")
            route(.session, .postflight, true, "successful sampled session\n")
            try require(failures.snapshot().0.count == terminal.count,
                        "successful revalidation consumed failure capacity")
            DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
                DiscoveryFixtureDiagnostic.sinkForRecord(.admission, stage: .revalidation, succeeded: false,
                    ordinary: progressSink, failures: failuresSink).emit("bounded failure\n")
            }
            try require(failures.snapshot().0.count == Sink.maximumRecords + 1
                && failures.snapshot().0.last == Sink.suppression
                && failures.snapshot().0.joined().utf8.count <= Sink.maximumBytes,
                "independent failure routing escaped concurrent output bounds")
            let byteProbe = TraceProbe()
            let byteBounded = Sink(enabled: true, writer: { byteProbe.append($0) })
            for _ in 0..<1_000 { byteBounded.emit(String(repeating: "x", count: Sink.maximumLineBytes)) }
            let (byteLines, _) = byteProbe.snapshot()
            try require(byteLines.count > 1 && byteLines.count < Sink.maximumRecords
                && byteLines.last == Sink.suppression && byteLines.joined().utf8.count <= Sink.maximumBytes,
                "byte bound did not independently close diagnostic output")
            for oversized in [String(repeating: "x", count: Sink.maximumLineBytes + 1),
                              String(repeating: "é", count: Sink.maximumLineBytes / 2 + 1)] {
                let probe = TraceProbe()
                // A fresh sink must refuse an oversized first record, including
                // multi-byte text, and emit only the fixed suppression notice.
                let checked = Sink(enabled: true, writer: { probe.append($0) })
                checked.emit(oversized); checked.emit("later diagnostic\n")
                try require(probe.snapshot().0 == [Sink.suppression], "oversized diagnostic escaped UTF-8 bound")
            }
            // A saturated suite trace cannot hide costs from the one exact
            // selection attempt. Component timings overlap helper timings;
            // fixed stage rows retain that distinction instead of summing them.
            let costProbe = TraceProbe()
            let costs = DiscoveryFixtureDiagnostic.CatalogCostObservation(
                output: Sink(enabled: true, writer: { costProbe.append($0) }))
            costs.captureHelper(started: 0, ended: 999) // outside scope: ignored
            costs.measure(.setup) {
                costs.captureSetup(started: 0, ended: 100, milestones: [10, 30, 60])
                costs.captureSession(started: 0, ended: 100, milestones: [10, 30, 60])
            }
            enum CostFailure: Error { case expected }
            do {
                try costs.measure(.catalog) {
                    costs.captureHelper(started: 0, ended: 200)
                    costs.captureHelper(started: 200, ended: 500)
                    costs.captureSession(started: 0, ended: 10, milestones: [])
                    throw CostFailure.expected
                }
                throw Failure.assertion("cost observation swallowed original failure")
            } catch CostFailure.expected {}
            try require(costProbe.snapshot().0.isEmpty, "cost observation emitted during measured work")
            costs.finish(succeeded: false)
            costs.finish(succeeded: false)
            let costLines = costProbe.snapshot().0
            try require(costLines.count == 6
                && costLines[0].contains("failed_stage=1 prebudget_ns=10 publisher_ns=20 snapshot_ns=30 session_binder_ns=40")
                && costLines[1].contains("stage=0 calls=1")
                && costLines[1].contains("helpers=0 helper_ns=0 sessions=1 scratch_ns=10 snapshot_ns=20 resources_ns=30 postflight_ns=40")
                && costLines[2].contains("stage=1 calls=1")
                && costLines[2].contains("helpers=2 helper_ns=500 sessions=1 scratch_ns=10 snapshot_ns=0 resources_ns=0 postflight_ns=0")
                && costLines[3].contains("stage=2 calls=0 wall_ns=0 helpers=0 helper_ns=0 sessions=0"),
                "selection costs mixed stages, lost partial failures or emitted more than once")
            try require(costLines.allSatisfy { $0.utf8.count <= Sink.maximumLineBytes }
                && costLines.joined().utf8.count <= 6 * Sink.maximumLineBytes,
                "selection aggregate exceeded its six-line byte ceiling")
            let successProbe = TraceProbe()
            let successfulCosts = DiscoveryFixtureDiagnostic.CatalogCostObservation(
                output: Sink(enabled: true, writer: { successProbe.append($0) }))
            let returned = successfulCosts.measure(.bind) { 7 }
            successfulCosts.finish(succeeded: true); successfulCosts.finish(succeeded: false)
            try require(returned == 7 && successProbe.snapshot().0.isEmpty,
                "cost observation changed success or emitted after successful closure")
            let overflowProbe = TraceProbe()
            let overflowCosts = DiscoveryFixtureDiagnostic.CatalogCostObservation(
                output: Sink(enabled: true, writer: { overflowProbe.append($0) }))
            overflowCosts.measure(.catalog) {
                for _ in 0..<2 {
                    overflowCosts.captureHelper(started: 0, ended: UInt64.max)
                    overflowCosts.captureSession(started: 0, ended: UInt64.max, milestones: [])
                }
                overflowCosts.captureHelper(started: 2, ended: 1)
                overflowCosts.captureSession(started: 0, ended: 1, milestones: [2])
            }
            overflowCosts.finish(succeeded: false)
            try require(overflowProbe.snapshot().0.count == 6
                && overflowProbe.snapshot().0[2].contains("helpers=2 helper_ns=\(UInt64.max) sessions=2 scratch_ns=\(UInt64.max)")
                && overflowProbe.snapshot().0.allSatisfy { $0.utf8.count <= Sink.maximumLineBytes },
                "cost aggregation overflowed or accepted nonmonotonic component timing")
            // The retained failure happened after successful initial binding.
            // Preserve those totals through pre-body rebind, body, and postflight
            // failures; a nested failure must not be mislabeled on propagation.
            for fault in ["rebind", "metadata", "postflight"] {
                let probe = TraceProbe()
                let observed = DiscoveryFixtureDiagnostic.CatalogCostObservation(
                    output: Sink(enabled: true, writer: { probe.append($0) }))
                observed.measure(.setup) {
                    observed.captureSetup(started: 0, ended: 100,
                        milestones: [10, 30, 60], deadline: 1)
                }
                observed.measure(.catalog) { observed.captureHelper(started: 0, ended: 200) }
                observed.measure(.bind) { observed.captureHelper(started: 0, ended: 300) }
                do {
                    try observed.measure(.discoveryPolicy) {
                        observed.captureHelper(started: 0, ended: 400)
                        if fault == "rebind" { throw CostFailure.expected }
                        try observed.measure(.metadata) {
                            observed.captureHelper(started: 0, ended: 500)
                            if fault == "metadata" { throw CostFailure.expected }
                        }
                        observed.captureHelper(started: 0, ended: 600)
                        throw CostFailure.expected
                    }
                } catch CostFailure.expected {}
                try require(probe.snapshot().0.isEmpty, "extended costs emitted before failure unwound")
                observed.finish(succeeded: false); observed.finish(succeeded: false)
                let lines = probe.snapshot().0
                let expectedStage = fault == "metadata" ? 4 : 3
                let policyHelpers = fault == "postflight" ? 2 : 1
                let policyTime = fault == "postflight" ? 1_000 : 400
                try require(lines.count == 6
                    && lines[0].contains("failed_stage=\(expectedStage) ")
                    && lines[2].contains("helpers=1 helper_ns=200")
                    && lines[3].contains("helpers=1 helper_ns=300")
                    && lines[4].contains("stage=3 calls=1")
                    && lines[4].contains("helpers=\(policyHelpers) helper_ns=\(policyTime)")
                    && lines[4].contains("setup_entry_remaining_ns=0 setup_end_remaining_ns=0")
                    && lines[5].contains(fault == "rebind" ? "stage=4 calls=0" : "stage=4 calls=1")
                    && lines[5].contains(fault == "rebind" ? "helpers=0 helper_ns=0" : "helpers=1 helper_ns=500")
                    && lines.allSatisfy { $0.utf8.count <= Sink.maximumLineBytes },
                    "extended costs lost initial work, nested attribution or original deadline")
            }
            let absent = DiscoveryFixtureDiagnostic.pendingBits(reason: .ioFailure, owner: nil, state: 0)
            let running = DiscoveryFixtureDiagnostic.pendingBits(reason: .ioFailure, owner: .running, state: 0)
            let zero = DiscoveryFixtureDiagnostic.pendingBits(reason: .ioFailure, owner: .reaped(0), state: 0)
            let exited = DiscoveryFixtureDiagnostic.pendingBits(reason: .ioFailure, owner: .reaped(71 << 8), state: 0x1ff)
            let lost = DiscoveryFixtureDiagnostic.pendingBits(reason: .ioFailure, owner: .ownershipFailure(ECHILD), state: 0)
            try require(Set([absent, running, zero, exited, lost]).count == 5
                && [absent, running, zero, exited, lost].allSatisfy { $0 >> 63 == 1 && $0 & 0xff == 7 }
                && ((exited >> 8) & 0xffff_ffff) == UInt64(71 << 8)
                && ((exited >> 44) & 0x1ff) == 0x1ff
                && DiscoveryFixtureDiagnostic.pendingBits(reason: .ioFailure, owner: nil, state: UInt64.max)
                    == (absent | (UInt64(0x1ff) << 44)),
                "pending observations conflated absent/reaped status or escaped closed bits")
            let reasons: [CustodyReason] = [.none, .cancelled, .timeout, .protocolFault,
                .invalidResource, .identityFailure, .outputLimit, .ioFailure, .startFailure,
                .ownershipLost, .persistenceFailure, .bootChanged]
            try require(reasons.enumerated().allSatisfy {
                DiscoveryFixtureDiagnostic.pendingBits(reason: $0.element, owner: nil, state: 0) & 0xff == UInt64($0.offset)
            }, "pending diagnostic reason table changed")
        }
        onPass("POLICY-SESSION-T61-diagnostic-opt-in-and-concurrent-output-bounds")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T62-metadata-resource-revocation-before-during-and-after-classification") {
            enum Cut { case beforeClassification, duringClassification, firstAccess, finalAccess }
            for batched in [false, true] {
                for cut in [Cut.beforeClassification, .duringClassification, .firstAccess, .finalAccess] {
                    let fixture = try metadataFixture(); defer { try? fixture.remove() }
                    // Bind the directory only after the marker exists. Changing
                    // bytes in this existing file isolates resource revocation from
                    // an unrelated selected-directory identity change.
                    let marker = fixture.fixture.path + "/resource-marker"
                    try Data("baseline".utf8).write(to: URL(fileURLWithPath: marker), options: .withoutOverwriting)
                    try require(chmod(marker, 0o600) == 0, "metadata drift marker permissions")
                    let scope = try selectedScope(fixture), audit = CommandAudit()
                    let armed = CancellationToken(), revoked = CancellationToken(), faultObserved = CancellationToken()
                    let binder = try fixture.make(cut == .duringClassification ? "resource-drift" : "valid",
                        audit: audit, resourceCheck: {
                            if armed.isCancelled && (revoked.isCancelled
                                || (try? Data(contentsOf: URL(fileURLWithPath: marker))) == Data("changed".utf8)) {
                                faultObserved.cancel()
                                throw PolicyHelperError.unavailable
                            }
                        }).binder()
                    var entered = false, returnedFromAccess = false, accessHooks = 0, callsBefore = -1
                    try denied {
                        try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                            entered = true; callsBefore = audit.invocations.count
                            if cut == .duringClassification {
                                try require(try Data(contentsOf: URL(fileURLWithPath: marker)) == Data("changed".utf8),
                                            "metadata drift setup marker missing")
                                try Data("baseline".utf8).write(to: URL(fileURLWithPath: marker))
                            }
                            armed.cancel()
                            if cut == .beforeClassification { revoked.cancel() }
                            let path = scope.repositories[0].repositoryPath
                            let paths = [path, path + "/.git", path + "/.git/config"]
                            service.testingBeforeAccess = { _ in
                                accessHooks += 1
                                if cut == .firstAccess || (cut == .finalAccess && accessHooks == (batched ? paths.count : 1)) {
                                    revoked.cancel()
                                }
                            }
                            if batched { try service.willAccess(paths) }
                            else { try service.willAccess(path) }
                            returnedFromAccess = true
                        }
                    }
                    try require(faultObserved.isCancelled, "resource fault was not observed; refusal may be unrelated")
                    try require(entered && !returnedFromAccess,
                                "metadata resource refusal did not precede caller access")
                    let expectedHooks = cut == .firstAccess || cut == .finalAccess ? (batched ? 3 : 1) : 0
                    try require(accessHooks == expectedHooks,
                                "metadata resource failure crossed access boundary")
                    try require(audit.invocations.count - callsBefore == (cut == .beforeClassification ? 0 : 1),
                                "metadata resource failure reached an unexpected helper")
                    if cut == .duringClassification {
                        try require(try Data(contentsOf: URL(fileURLWithPath: marker)) == Data("changed".utf8),
                                    "mid-classification resource cut not exercised")
                    }
                    try require(unlink(marker) == 0, "metadata drift marker cleanup")
                    try fixture.remove()
                }
            }
            for batched in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), audit = CommandAudit()
                let binder = try fixture.make(audit: audit).binder()
                var hooks = 0, changed = false, candidateAccesses = 0
                try denied {
                    try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        let path = scope.repositories[0].repositoryPath
                        let paths = [path, path + "/.git", path + "/.git/config"]
                        service.testingBeforeAccess = { _ in
                            hooks += 1
                            if hooks == (batched ? paths.count : 1) {
                                changed = chmod(fixture.fixture.path + "/owner/policy.yml", 0o622) == 0
                            }
                        }
                        if batched { try service.willAccess(paths) }
                        else { try service.willAccess(path) }
                        candidateAccesses += 1
                    }
                }
                try require(changed && hooks == (batched ? 3 : 1) && candidateAccesses == 0,
                            "final access hook policy drift escaped fresh validation")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T62-metadata-resource-revocation-before-during-and-after-classification")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T63-metadata-malformed-input-preserves-pending-precedence") {
            for variant in 0..<7 {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), audit = CommandAudit()
                let pending = CancellationToken(), faultObserved = CancellationToken()
                let binder = try fixture.make(audit: audit, resourceCheck: {
                    if pending.isCancelled {
                        faultObserved.cancel()
                        throw PolicyHelperError.cleanupPending
                    }
                }).binder()
                var entered = false, callsBefore = -1
                do {
                    try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        entered = true; callsBefore = audit.invocations.count; pending.cancel()
                        if variant == 0 { try service.requireAllowed("") }
                        else if variant == 1 { try service.prepareAccess([]) }
                        else if variant == 2 { try service.prepareAccess([fixture.fixture.path + "/../outside"]) }
                        else if variant == 3 { try service.willAccess([]) }
                        else if variant == 4 { try service.willAccess([fixture.fixture.path + "/../outside"]) }
                        else if variant == 5 { try service.willAccess(Array(repeating: scope.repositories[0].repositoryPath, count: 65)) }
                        else { try service.willAccess([scope.repositories[0].repositoryPath, ""]) }
                    }
                    throw Failure.assertion("malformed metadata request lost pending refusal")
                } catch SelectedRepositoryScopeError.cleanupPending {}
                try require(entered && faultObserved.isCancelled && audit.invocations.count == callsBefore,
                            "malformed metadata request hid cleanup or launched a helper")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T63-metadata-malformed-input-preserves-pending-precedence")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T64-metadata-known-paths-share-first-classification") {
            final class AdmissionProbe: @unchecked Sendable {
                private let lock = NSLock()
                private var checks = 0
                private var requests: [[Data]] = []
                private var deadlines: [UInt64] = []
                func validate() { lock.lock(); defer { lock.unlock() }; checks += 1 }
                func evaluate(_ paths: [RepositorySelectionAdmissionPath], _ deadline: UInt64) {
                    lock.lock(); defer { lock.unlock() }
                    requests.append(paths.map { Data($0.components.joined(separator: "/").utf8) })
                    deadlines.append(deadline)
                }
                func state() -> (Int, [[Data]], [UInt64]) {
                    lock.lock(); defer { lock.unlock() }; return (checks, requests, deadlines)
                }
            }
            // Count the complete admission wrapper, including both classify
            // validations and the final fresh validation, rather than timing it.
            for batched in [false, true] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), snapshot = try fixture.snapshot(), probe = AdmissionProbe()
                let admission = RepositorySelectionPathAdmission(evaluate: { paths, deadline in
                    probe.evaluate(paths, deadline)
                    return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
                }, revalidate: { probe.validate(); try snapshot.revalidate() })
                let binder = try SelectedRepositoryScopeBinder(snapshot: snapshot, admission: admission)
                try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                    let path = scope.repositories[0].repositoryPath
                    // Canonically equivalent Unicode remains distinct policy bytes.
                    let paths = [path + "/caf\u{00e9}", path + "/cafe\u{0301}", path + "/.git/config"]
                    let before = probe.state()
                    var hooks: [Data] = []
                    service.testingBeforeAccess = { hooks.append(Data($0.utf8)) }
                    if batched { try service.willAccess(paths) }
                    else { for path in paths { try service.willAccess(path) } }
                    let after = probe.state(), requests = Array(after.1.dropFirst(before.1.count))
                    try require(after.0 - before.0 == (batched ? 3 : 9)
                        && requests.count == (batched ? 1 : 3), "access batching lost full validation or repeated its wrapper")
                    try require(hooks == paths.map { Data($0.utf8) }, "batch access hooks changed order or exact bytes")
                    var expected: [Data] = [], seen: Set<Data> = []
                    for path in paths {
                        let relative = String(path.dropFirst(fixture.fixture.path.count + 1)).split(separator: "/").map(String.init)
                        for count in 0...relative.count {
                            let prefix = Data(relative.prefix(count).joined(separator: "/").utf8)
                            if seen.insert(prefix).inserted { expected.append(prefix) }
                        }
                    }
                    var actual: [Data] = [], observed: Set<Data> = []
                    for prefix in requests.flatMap({ $0 }) {
                        if observed.insert(prefix).inserted { actual.append(prefix) }
                    }
                    try require(actual == expected, "batch omitted an exact leaf or ancestor")
                    let deadlines = Array(after.2.dropFirst(before.2.count))
                    try require(Set(deadlines).count == 1, "access paths renewed the metadata deadline")
                    // The admitted maximum keeps all hooks and still uses one wrapper.
                    if batched {
                        let start = probe.state(), count = hooks.count
                        try service.willAccess(Array(repeating: path, count: 64))
                        try require(hooks.count - count == 64 && probe.state().0 - start.0 == 3,
                                    "bounded maximum access group lost hooks or full validation")
                    }
                }
                try fixture.remove()
            }
            // An allowed leaf cannot confer access through one protected
            // ancestor, and swallowing that refusal cannot reopen the service.
            for variant in 0..<4 {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), audit = CommandAudit()
                let binder = try fixture.make("exact-only", audit: audit).binder()
                var hooks = 0, candidateAccesses = 0, protectedAncestorObserved = false
                try denied {
                    try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                        let path = scope.repositories[0].repositoryPath
                        service.testingBeforeAccess = { _ in hooks += 1 }
                        service.testingProtectedPath = { observed, deadline in
                            if observed.utf8.elementsEqual((path + "/blocked").utf8)
                                && DispatchTime.now().uptimeNanoseconds < deadline {
                                protectedAncestorObserved = true
                            }
                        }
                        let paths: [String]
                        switch variant {
                        case 0: paths = [path + "/.git/config", path + "/blocked/allowed-leaf"]
                        case 1: paths = Array(repeating: path, count: 65)
                        case 2: paths = []
                        default: paths = [path, path + "/../outside"]
                        }
                        let before = audit.invocations.count
                        try denied {
                            try service.willAccess(paths)
                            candidateAccesses += 1
                        }
                        try require(variant == 0 ? protectedAncestorObserved : audit.invocations.count == before,
                                    "batch refused before the intended protected or lexical boundary")
                        let calls = audit.invocations.count
                        try denied { try service.willAccess(path); candidateAccesses += 1 }
                        try denied { try service.willAccess([path, path + "/.git"]); candidateAccesses += 1 }
                        try require(audit.invocations.count == calls, "sticky batch refusal reached another classifier")
                    }
                }
                try require(hooks == 0 && candidateAccesses == 0, "batch refusal crossed candidate access boundary")
                try fixture.remove()
            }
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), audit = CommandAudit()
            let binder = try fixture.make(audit: audit).binder()
            let candidates = try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                let before = audit.invocations.count
                let rows = try RepositoryDiscovery().discoverMetadata(scope: scope, policy: service)
                try require(audit.invocations.count - before == 1,
                            "known metadata paths started more than one classifier")
                return rows
            }
            try require(candidates.count == 1 && candidates[0].id == "fixture-owner/ready"
                && candidates[0].isEligible && scope.admits(candidates[0]),
                "metadata prefetch changed selected repository or eligibility")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T64-metadata-known-paths-share-first-classification")

        try RuntimeFixtureSession.withCase("POLICY-SESSION-T65-rebind-one-deadline-through-catalog-and-binding") {
            final class Deadlines: @unchecked Sendable {
                let lock = NSLock()
                private var values: [UInt64] = []
                private var first: UInt64?
                func record(_ value: UInt64) {
                    lock.lock(); defer { lock.unlock() }
                    if first == nil { first = DispatchTime.now().uptimeNanoseconds }
                    values.append(value)
                }
                var all: [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
                var firstObserved: UInt64 { lock.lock(); defer { lock.unlock() }; return first ?? 0 }
            }
            let fixture = try SessionFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), snapshot = try fixture.snapshot(), observed = Deadlines()
            let admission = RepositorySelectionPathAdmission(evaluate: { paths, deadline in
                observed.record(deadline)
                return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
            }, revalidate: { try snapshot.revalidate() })
            let binder = try SelectedRepositoryScopeBinder(snapshot: snapshot, admission: admission)
            var catalogs = 0, entered = false
            binder.testingAfterRebindCatalog = { catalogs += 1 }
            let started = DispatchTime.now().uptimeNanoseconds
            try binder.withReboundScope(scope, cancellation: CancellationToken()) { rebound in
                entered = true
                try require(rebound == scope, "same-call catalog changed saved selection")
            }
            let deadlines = observed.all
            try require(entered && catalogs == 1 && !deadlines.isEmpty && Set(deadlines).count == 1
                && deadlines[0] > started && deadlines[0] <= observed.firstObserved + 750_000_000,
                "rebind renewed the original metadata deadline")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T65-rebind-one-deadline-through-catalog-and-binding")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T66-rebind-post-catalog-revocation-refuses-body") {
            for fault in ["policy", "resources", "phase", "pending", "deadline"] {
                let fixture = try SessionFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), revoked = CancellationToken(), phase = CancellationToken()
                let binder = try fixture.make(resourceCheck: {
                    if revoked.isCancelled {
                        if fault == "pending" { throw PolicyHelperError.cleanupPending }
                        throw PolicyHelperError.unavailable
                    }
                }).binder(revalidatePhase: {
                    if phase.isCancelled { throw PolicyHelperError.unavailable }
                })
                var catalogs = 0, entered = false
                binder.testingAfterRebindCatalog = {
                    catalogs += 1
                    if fault == "policy" { try fixture.fixture.write("owner/policy.yml", Data("changed".utf8)) }
                    else if fault == "phase" { phase.cancel() }
                    else if fault == "deadline" { usleep(800_000) }
                    else { revoked.cancel() }
                }
                do {
                    try binder.withReboundScope(scope, cancellation: CancellationToken()) { _ in entered = true }
                    throw Failure.assertion("post-catalog revocation completed a rebind")
                } catch SelectedRepositoryScopeError.policyUnavailable {
                    try require(fault != "pending", "pending precedence was lost")
                } catch SelectedRepositoryScopeError.cleanupPending {
                    try require(fault == "pending", "unrelated revocation became pending")
                } catch PolicyHelperError.unavailable {
                    try require(fault == "phase", "wrong raw phase refusal")
                }
                try require(catalogs == 1 && !entered, "post-catalog revocation reached operation body")
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T66-rebind-post-catalog-revocation-refuses-body")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T67-rebind-post-catalog-directory-replacement-refuses") {
            for replaceRoot in [false, true] {
                let fixture = try SessionFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), binder = try fixture.make().binder()
                let original = replaceRoot ? fixture.fixture.path : scope.repositories[0].repositoryPath
                let retained = original + "-retained"
                var before = stat()
                try require(lstat(original, &before) == 0, "capture original rebind fixture directory")
                let originalIdentity = FileIdentity(before)
                var replacementIdentity: FileIdentity?, displaced = false, entered = false, catalogs = 0
                binder.testingAfterRebindCatalog = {
                    catalogs += 1
                    try require(rename(original, retained) == 0, "retain exact original fixture directory")
                    displaced = true
                    try require(mkdir(original, 0o700) == 0, "create replacement fixture directory")
                    var created = stat()
                    try require(lstat(original, &created) == 0, "capture replacement fixture directory")
                    replacementIdentity = FileIdentity(created)
                    if replaceRoot { try fixture.fixture.restore() }
                    try fixture.fixture.write("workspace/products/ready/.git/config",
                        Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/ready.git\n".utf8))
                    try fixture.fixture.write("workspace/products/ready/.git/refs/remotes/origin/HEAD",
                        Data("ref: refs/remotes/origin/main\n".utf8))
                }
                var bodyFailure: Error?
                do {
                    do {
                        try binder.withReboundScope(scope, cancellation: CancellationToken()) { _ in entered = true }
                        throw Failure.assertion("post-catalog replacement inherited selected authority")
                    } catch SelectedRepositoryScopeError.changed {}
                    catch SelectedRepositoryScopeError.policyUnavailable { try require(replaceRoot, "wrong repository replacement refusal") }
                    try require(catalogs == 1 && !entered, "replacement reached operation body")
                } catch { bodyFailure = error }
                do {
                    if displaced {
                        var current = stat(), saved = stat()
                        if lstat(original, &current) == 0 {
                            guard let replacementIdentity else { throw Failure.assertion("unidentified replacement retained") }
                            try require(FileIdentity(current).matchesStableNode(replacementIdentity), "replacement changed before cleanup")
                            try FileManager.default.removeItem(atPath: original)
                        } else { try require(errno == ENOENT, "replacement inspection failed") }
                        try require(lstat(retained, &saved) == 0 && FileIdentity(saved).matchesStableNode(originalIdentity),
                                    "retained original changed before restoration")
                        try require(rename(retained, original) == 0, "restore original fixture directory")
                        var restored = stat()
                        try require(lstat(original, &restored) == 0 && FileIdentity(restored).matchesStableNode(originalIdentity),
                                    "restored original identity differs")
                    }
                    try fixture.remove()
                } catch {
                    throw Failure.assertion("rebind replacement body=\(String(describing: bodyFailure)); cleanup=\(error)")
                }
                if let bodyFailure { throw bodyFailure }
            }
        }
        onPass("POLICY-SESSION-T67-rebind-post-catalog-directory-replacement-refuses")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T68-public-bind-refreshes-advisory-eligibility") {
            for changedOrigin in [false, true] {
                let fixture = try SessionFixture(); defer { try? fixture.remove() }
                let binder = try fixture.make().binder()
                let catalog = try binder.processFreeCatalog(preferences: nil, generation: 1)
                guard catalog.isComplete, let ready = catalog.catalog.candidates.first(where: { $0.id == "fixture-owner/ready" }) else {
                    throw Failure.assertion("public binding fixture has no eligible candidate")
                }
                let intent = try RepositorySelectionIntent(catalog: catalog.catalog, entries: [try ready.preferenceEntry])
                if changedOrigin {
                    try fixture.fixture.write("workspace/products/ready/.git/config",
                        Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/other.git\n".utf8))
                } else {
                    try require(unlink(fixture.fixture.path + "/workspace/products/ready/.git/refs/remotes/origin/HEAD") == 0,
                                "remove owned advisory remote-default fixture")
                }
                do { _ = try binder.bind(intent: intent); throw Failure.assertion("public bind reused prior catalog eligibility") }
                catch SelectedRepositoryScopeError.ambiguous { try require(changedOrigin, "wrong unavailable-default refusal") }
                catch SelectedRepositoryScopeError.forbidden { try require(!changedOrigin, "wrong changed-origin refusal") }
                try fixture.remove()
            }
        }
        onPass("POLICY-SESSION-T68-public-bind-refreshes-advisory-eligibility")

        try RuntimeFixtureSession.withCase("POLICY-SESSION-T69-rebind-hints-exact-bytes-bounded-input") {
            func locator(_ components: [String], root: String = "~") throws -> RepositorySelectionLocator {
                try RepositorySelectionLocator(governedRoot: root, components: components)
            }
            func paths(_ hints: [RepositorySelectionLocator]) throws -> [RepositorySelectionAdmissionPath] {
                try SelectedRepositoryScopeBinder.firstRootAdmissionPaths(root: "~",
                    projectionRoot: ["workspace"], lexicalHints: hints)
            }
            let selected = try locator(["workspace", "products", "ready"])
            let composed = try locator(["workspace", "products", "caf\u{00e9}"])
            let decomposed = try locator(["workspace", "products", "cafe\u{0301}"])
            let unrelated = try locator(selected.components, root: "other")
            let outside = try locator(["workspace-other", "products", "ready"])
            let admitted = try paths([unrelated, outside, selected, selected, composed, decomposed])
            try require(admitted.count == 4 && admitted[0].components.isEmpty
                && admitted[1].components == selected.components
                && admitted[2].components.last!.utf8.elementsEqual(composed.components.last!.utf8)
                && admitted[3].components.last!.utf8.elementsEqual(decomposed.components.last!.utf8),
                "hint filtering normalized bytes, repeated input, or displaced root")
            let full = try (0..<64).map { try locator(["workspace", "products", "repo-\($0)"]) }
            let bounded = try paths(full)
            try require(bounded.count == 64 && bounded[0].components.isEmpty
                && bounded.last!.components == full[62].components,
                "hint batch exceeded root plus 63 candidates")
            let repeated = try paths(Array(repeating: selected, count: 63) + [composed])
            let rejected = try paths(Array(repeating: unrelated, count: 63) + [selected])
            try require(repeated.count == 2 && rejected.count == 1,
                "hint input cap scanned beyond duplicate or wrong-root entries")
            for components in [["workspace", ".."], ["workspace", "bad/name"],
                               ["workspace", "bad\\name"], ["workspace", ".hidden"],
                               ["workspace", ""], ["workspace", String(repeating: "x", count: 256)]] {
                do { _ = try locator(components); throw Failure.assertion("malformed locator became a hint") }
                catch RepositorySelectionValueError.invalidLocator {}
            }
        }
        onPass("POLICY-SESSION-T69-rebind-hints-exact-bytes-bounded-input")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T70-rebind-first-batch-current-policy-metadata") {
            let fixture = try SessionFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), audit = CommandAudit()
            let advisory = try fixture.make().binder().processFreeCatalog(preferences: nil,
                generation: scope.selectionGeneration)
            let intent = try RepositorySelectionIntent(catalog: advisory.catalog,
                entries: scope.repositories.map {
                    try RepositorySelectionPreferenceEntry(repositoryID: $0.repositoryID, locator: $0.locator)
                })
            let initialAudit = CommandAudit()
            let initial = try fixture.make("rebind-first-batch", audit: initialAudit).binder()
            for _ in 0..<2 {
                let before = initialAudit.invocations.count
                let bound = try initial.bind(intent: intent)
                try require(bound == scope && initialAudit.invocations.count > before,
                    "initial bind omitted first-batch metadata or reused prior deadline authority")
            }
            let initialProtectedAudit = CommandAudit()
            let initialProtected = try fixture.make("rebind-first-protected", audit: initialProtectedAudit).binder()
            do {
                _ = try initialProtected.bind(intent: intent)
                throw Failure.assertion("initial bind trusted protected lexical selection")
            } catch SelectedRepositoryScopeError.ambiguous {}
            try require(!initialProtectedAudit.invocations.isEmpty,
                "initial bind failed before current protected classification")
            // The adapter rejects a root batch lacking this selection's fixed
            // metadata, so a separate later warming request cannot satisfy it.
            let binder = try fixture.make("rebind-first-batch", audit: audit).binder()
            for _ in 0..<2 {
                let before = audit.invocations.count
                let rebound = try binder.rebind(scope)
                try require(rebound == scope && audit.invocations.count > before,
                    "new rebind stage reused old-deadline authority or changed selection")
            }
            // Same saved input, different current classifier: prefetched allow
            // from the prior session must not admit a now-protected repository.
            let protectedAudit = CommandAudit()
            let protected = try fixture.make("rebind-first-protected", audit: protectedAudit).binder()
            var entered = false
            do {
                try protected.withReboundScope(scope, cancellation: CancellationToken()) { _ in entered = true }
                throw Failure.assertion("protected hint admitted saved selection")
            } catch SelectedRepositoryScopeError.changed {}
            try require(!entered && !protectedAudit.invocations.isEmpty,
                "protected current-policy hint reached repository inspection")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T70-rebind-first-batch-current-policy-metadata")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T71-rebind-required-root-denial-and-fresh-deadline") {
            final class Requests: @unchecked Sendable {
                let lock = NSLock()
                private var values: [([RepositorySelectionAdmissionPath], UInt64)] = []
                func record(_ paths: [RepositorySelectionAdmissionPath], _ deadline: UInt64) {
                    lock.lock(); defer { lock.unlock() }; values.append((paths, deadline))
                }
                var all: [([RepositorySelectionAdmissionPath], UInt64)] {
                    lock.lock(); defer { lock.unlock() }; return values
                }
            }
            let fixture = try SessionFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), snapshot = try fixture.snapshot(), requests = Requests()
            let advisory = try fixture.make().binder().processFreeCatalog(preferences: nil,
                generation: scope.selectionGeneration)
            let intent = try RepositorySelectionIntent(catalog: advisory.catalog,
                entries: scope.repositories.map {
                    try RepositorySelectionPreferenceEntry(repositoryID: $0.repositoryID, locator: $0.locator)
                })
            let admission = RepositorySelectionPathAdmission(evaluate: { paths, deadline in
                requests.record(paths, deadline)
                return paths.map { RepositorySelectionAdmissionDecision(path: $0,
                    disposition: $0.components.isEmpty ? .protected : .allowed) }
            }, revalidate: { try snapshot.revalidate() })
            let binder = try SelectedRepositoryScopeBinder(snapshot: snapshot, admission: admission)
            var entered = false, catalogs = 0
            binder.testingAfterRebindCatalog = { catalogs += 1 }
            let started = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<2 {
                do {
                    try binder.withReboundScope(scope, cancellation: CancellationToken()) { _ in entered = true }
                    throw Failure.assertion("allowed hint overrode denied required root")
                } catch SelectedRepositoryScopeError.policyUnavailable {}
            }
            for _ in 0..<2 {
                do {
                    _ = try binder.bind(intent: intent)
                    throw Failure.assertion("initial bind hint overrode denied required root")
                } catch SelectedRepositoryScopeError.policyUnavailable {}
            }
            let observed = requests.all
            try require(!entered && catalogs == 0 && observed.count == 4
                && observed.allSatisfy { $0.0.count == 2 && $0.0[0].components.isEmpty
                    && $0.0[1].components == scope.repositories[0].locator.components
                    && $0.1 > started }
                && zip(observed, observed.dropFirst()).allSatisfy { $0.1 < $1.1 },
                "root denial was bypassed or rebind reused first invocation deadline")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T71-rebind-required-root-denial-and-fresh-deadline")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T72-rebind-stale-unrelated-and-missing-hints-refuse") {
            let fixture = try SessionFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), selected = scope.repositories[0]
            for locator in [try RepositorySelectionLocator(governedRoot: "other", components: selected.locator.components),
                            try RepositorySelectionLocator(governedRoot: "~", components: ["outside", "missing"]),
                            try RepositorySelectionLocator(governedRoot: "~", components: ["workspace", "products", "missing"])] {
                let stale = ValidatedSelectedRepository(repositoryID: selected.repositoryID, locator: locator,
                    governedRootPath: selected.governedRootPath, policyRootPath: selected.policyRootPath,
                    repositoryPath: selected.repositoryPath, rootIdentity: selected.rootIdentity,
                    repositoryIdentity: selected.repositoryIdentity)
                var entered = false
                do {
                    try fixture.make().binder().withReboundScope(changedScope(scope, repositories: [stale]),
                        cancellation: CancellationToken()) { _ in entered = true }
                    throw Failure.assertion("stale lexical hint admitted saved selection")
                } catch SelectedRepositoryScopeError.changed {}
                try require(!entered, "lexical stale hint replaced the exact selected identity")
            }
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T72-rebind-stale-unrelated-and-missing-hints-refuse")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T73-fixed-read-first-batch-and-fresh-stage") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let oid = String(repeating: "a", count: 40)
            let reads: [DiscoveryMetadataAccess.Read] = [.identity, .busy, .topology, .index,
                .mainReference, .remoteReference, .looseCommit(oid), .primaryClaim(candidate.path)]
            for (index, read) in reads.enumerated() {
                let audit = CommandAudit()
                // The fixture adapter rejects the first metadata-stage batch
                // unless it contains this fixed read's leaves and ancestors.
                // A second warming batch cannot satisfy that condition.
                let binder = try fixture.make("metadata-read-first-\(index)", audit: audit).binder()
                var afterCatalog = -1, callbacks = 0
                binder.testingAfterRebindCatalog = { afterCatalog = audit.invocations.count }
                let access = DiscoveryMetadataAccess(binder: binder, scope: scope, cancellation: CancellationToken())
                for _ in 0..<2 {
                    let before = audit.invocations.count
                    try access.withRead(candidate, read) { callbacks += 1 }
                    try require(afterCatalog > before && audit.invocations.count - afterCatalog == 1,
                        "fixed read repeated a metadata helper or borrowed the prior deadline cache")
                }
                try require(callbacks == 2, "fixed read did not reach both independently admitted bodies")
            }
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T73-fixed-read-first-batch-and-fresh-stage")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T74-fixed-read-protected-stale-and-identity-refuse") {
            for mode in ["metadata-index", "metadata-object-ancestor", "metadata-read-replace"] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
                let audit = CommandAudit(), binder = try fixture.make(mode, audit: audit).binder()
                var afterCatalog = -1, callbacks = 0
                binder.testingAfterRebindCatalog = { afterCatalog = audit.invocations.count }
                let access = DiscoveryMetadataAccess(binder: binder, scope: scope, cancellation: CancellationToken())
                do {
                    try access.withRead(candidate, .index) { callbacks += 1 }
                    throw Failure.assertion("fixed read crossed protected metadata or replaced identity")
                } catch SelectedRepositoryScopeError.policyUnavailable {
                    try require(mode != "metadata-read-replace", "replacement did not reach physical identity check")
                } catch GitSafetyError.unsafeRepository(let reason) {
                    try require(mode == "metadata-read-replace" && reason == "worktree-list directory identity changed",
                        "replaced metadata directory failed at unrelated boundary")
                }
                try require(callbacks == 0 && afterCatalog >= 0 && audit.invocations.count - afterCatalog == 1,
                    "refusal did not exercise first metadata batch before the read body")
                if mode == "metadata-read-replace" {
                    try require(FileManager.default.fileExists(atPath: candidate.path + "-saved-read-root/.git/config"),
                        "replacement fixture did not preserve the original selected directory")
                }
                try fixture.remove()
            }
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let audit = CommandAudit(), binder = try fixture.make(audit: audit).binder()
            var afterCatalog = -1, callbacks = 0
            binder.testingAfterRebindCatalog = { afterCatalog = audit.invocations.count }
            let access = DiscoveryMetadataAccess(binder: binder, scope: scope, cancellation: CancellationToken())
            for variant in 0..<2 {
                let stale = RepositoryCandidate(id: candidate.id, displayName: candidate.displayName,
                    path: candidate.path + (variant == 0 ? "/" : ""), rawOrigin: candidate.rawOrigin,
                    rootIdentity: candidate.rootIdentity,
                    policyAdmissionSHA256: variant == 0 ? candidate.policyAdmissionSHA256 : String(repeating: "f", count: 64))
                do {
                    try access.withRead(stale, .index) { callbacks += 1 }
                    throw Failure.assertion("stale fixed read passed initial exact scope guard")
                } catch SelectedRepositoryScopeError.changed {}
                try require(afterCatalog >= 0 && audit.invocations.count == afterCatalog,
                    "stale candidate reached metadata classification")
            }
            // An admitted body cannot turn policy drift into successful return.
            do {
                try access.withRead(candidate, .index) {
                    callbacks += 1
                    try fixture.fixture.write("owner/overlay.json", fixture.fixture.contents["owner/overlay.json"]! + Data("\n".utf8))
                }
                throw Failure.assertion("fixed read policy drift escaped postflight")
            } catch SelectedRepositoryScopeError.policyUnavailable {}
            try require(callbacks == 1, "stale or postflight refusal crossed the wrong read boundary")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T74-fixed-read-protected-stale-and-identity-refuse")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T75-fixed-read-one-deadline-and-expiry") {
            final class ReadDeadlines: @unchecked Sendable {
                let lock = NSLock()
                private var values: [([RepositorySelectionAdmissionPath], UInt64, UInt64)] = []
                func record(_ paths: [RepositorySelectionAdmissionPath], _ deadline: UInt64) {
                    lock.lock(); defer { lock.unlock() }
                    values.append((paths, deadline, DispatchTime.now().uptimeNanoseconds))
                }
                var all: [([RepositorySelectionAdmissionPath], UInt64, UInt64)] {
                    lock.lock(); defer { lock.unlock() }; return values
                }
            }
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let snapshot = try fixture.snapshot(), probe = ReadDeadlines()
            // Observe lexical admission deadlines without a timed helper. The
            // real session/transport and cache are covered by T73 and T74.
            let admission = RepositorySelectionPathAdmission(evaluate: { paths, deadline in
                probe.record(paths, deadline)
                return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
            }, revalidate: { try snapshot.revalidate() })
            let binder = try SelectedRepositoryScopeBinder(snapshot: snapshot, admission: admission)
            let access = DiscoveryMetadataAccess(binder: binder, scope: scope, cancellation: CancellationToken())
            var callbacks = 0
            do {
                try access.withRead(candidate, .mainReference) {
                    callbacks += 1
                    let observed = probe.all
                    guard let last = observed.last else { throw Failure.assertion("metadata deadline not observed") }
                    let stage = observed.filter { $0.1 == last.1 }
                    try require(!stage.isEmpty && stage.allSatisfy { $0.1 > $0.2 && $0.1 - $0.2 <= 750_000_000 }
                        && stage.first!.0.contains { $0.components.last == "main.lock" }
                        && stage.first!.0.contains { $0.components.last == "config.worktree" },
                        "metadata fixed paths did not share the first original bounded stage")
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < last.1 { usleep(UInt32((last.1 - now) / 1_000 + 2_000)) }
                }
                throw Failure.assertion("fixed read renewed expired postflight deadline")
            } catch SelectedRepositoryScopeError.policyUnavailable {}
            try require(callbacks == 1, "expiry fixture failed before admitted read body")
            let expired = probe.all.last!.1
            try access.withRead(candidate, .mainReference) { callbacks += 1 }
            let fresh = probe.all.last!.1
            try require(callbacks == 2 && fresh > expired,
                "new fixed read reused an expired metadata deadline")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T75-fixed-read-one-deadline-and-expiry")
        try RuntimeFixtureSession.withCase("POLICY-SESSION-T76-fixed-read-batch-bound-refusal") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let scope = try selectedScope(fixture), candidate = try metadataCandidate(fixture, scope)
            let audit = CommandAudit(), binder = try fixture.make(audit: audit).binder()
            var entered = false, before = -1
            var preparationRejected = false, selectedRejected = false, stageRejected = false
            do {
                try binder.withDiscoveryPolicy(scope, cancellation: CancellationToken()) { service in
                    entered = true; before = audit.invocations.count
                    do {
                        try service.prepareAccess(Array(repeating: candidate.path, count: 65))
                    } catch SelectedRepositoryScopeError.policyUnavailable { preparationRejected = true }
                    do {
                        try service.requireSelected(scope.repositories[0])
                    } catch SelectedRepositoryScopeError.policyUnavailable { selectedRejected = true }
                }
            } catch SelectedRepositoryScopeError.policyUnavailable { stageRejected = true }
            // Assert outside the wrapper: its sticky validation must not replace
            // an assertion sentinel with the policy error expected by this case.
            try require(entered && preparationRejected && selectedRejected && stageRejected
                && before >= 0 && audit.invocations.count == before,
                "oversized metadata preparation or sticky refusal failed")
            let session = try fixture.make(audit: audit)
            let paths = try (0..<65).map {
                try RepositorySelectionAdmissionPath(root: "~", components: ["workspace", "products", "leaf-\($0)"])
            }
            let calls = audit.invocations.count
            do {
                _ = try session.admission.classify(paths, deadline: deadline())
                throw Failure.assertion("oversized policy request accepted")
            } catch RepositorySelectionAdmissionError.unavailable {}
            try require(audit.invocations.count == calls, "65-path request reached bounded transport")
            let marker = candidate.path + "/.git"
            let cached = Set((0..<4095).map { Data((candidate.path + "/cached-\($0)").utf8) })
            try require(PolicyCatalogSession.prefetchCatalogMetadata([marker], cached: cached,
                projectionRoot: fixture.fixture.path + "/workspace") == [marker],
                "optional metadata exceeded 4096-entry cache bound")
            try fixture.remove()
        }
        onPass("POLICY-SESSION-T76-fixed-read-batch-bound-refusal")
    }

    private final class SessionFixture {
        let fixture: Fixture
        let directory: Int32
        let account: EffectiveAccount
        let interpreter: String
        let contractBytes: Data
        let contract: QualifiedAWAContract
        private var removed = false

        init() throws {
            guard let interpreter = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_PYTHON"],
                  interpreter.hasPrefix("/") else { throw Failure.assertion("explicit test interpreter missing") }
            let fixture = try Fixture()
            let directory = open(fixture.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else {
                try? fixture.remove()
                throw Failure.assertion("session scratch open")
            }
            do {
                let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: fixture.path)
                let contractBytes = try json(["schema": "shadow-sync-awa-contract/v1", "status": "qualified",
                    "release_revision": String(repeating: "a", count: 40),
                    "module_sha256": digest(fixture.contents["runtime/policy.py"]!)])
                let contract = try QualifiedAWAContract.decode(contractBytes)
                try fixture.write("workspace/products/ready/.git/config",
                    Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/ready.git\n".utf8))
                try fixture.write("workspace/products/ready/.git/refs/remotes/origin/HEAD", Data("ref: refs/remotes/origin/main\n".utf8))
                try FileManager.default.createDirectory(atPath: fixture.path + "/workspace/products/blocked",
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                self.fixture = fixture; self.directory = directory
                self.account = account; self.interpreter = interpreter
                self.contractBytes = contractBytes; self.contract = contract
            } catch {
                close(directory)
                try? fixture.remove()
                throw error
            }
        }

        func snapshot() throws -> HostPolicySnapshot { try HostPolicySnapshot.load(account: account, contract: contract) }
        func make(_ mode: String = "valid", cancellation: CancellationToken = CancellationToken(),
                  audit: CommandAudit = CommandAudit(),
                  resourceCheck: @escaping @Sendable () throws -> Void = {}) throws -> PolicyCatalogSession {
            let snapshot = try snapshot()
            let code = """
            import json,sys,time
            def run_sealed(contract):
                request=json.load(sys.stdin)
                mode='\(mode)'
                if mode=='sleep': time.sleep(10)
                if mode=='noise': sys.stderr.write('fixture diagnostic')
                if mode=='resource-drift':
                    with open('\(fixture.path)/resource-marker','w') as marker: marker.write('changed')
                rows=[]
                for i,path in enumerate(request['candidates']):
                    matched=path.endswith('/blocked') or '/blocked/' in path
                    if mode=='exact-only': matched=path.endswith('/blocked')
                    if mode=='config-ancestor': matched=matched or path.endswith('/.config')
                    if mode=='metadata-index': matched=matched or path.endswith('/.git/index')
                    if mode=='metadata-prefetch-protected': matched=matched or path.endswith('/ready/.git/config')
                    if mode.startswith('root-shelf-prefetch'): matched=matched or path.endswith('/root-guarded/.git/config')
                    if mode=='rebind-first-protected': matched=matched or path.endswith('/ready') or '/ready/' in path
                    if mode=='metadata-object-ancestor': matched=matched or path.endswith('/.git/objects')
                    kind='exact_root' if matched else 'none'
                    if mode=='invalid': matched=True; kind='invalid_candidate'
                    if mode=='root-shelf-prefetch-invalid' and path.endswith('/root-empty/.git/config'): matched=True; kind='invalid_candidate'
                    rows.append({'index':i,'matched':matched,'kind':kind,'policy_valid':True})
                if mode in ('metadata-prefetch-roster','metadata-prefetch-protected'):
                    for marker in [p for p in request['candidates'] if p.endswith('/ready/.git')]:
                        expected=[marker+'/'+suffix for suffix in ('config','refs','refs/remotes','refs/remotes/origin','refs/remotes/origin/HEAD')]
                        if not set(expected).issubset(request['candidates']): rows=[]
                if mode.startswith('root-shelf-prefetch'):
                    for child in ('root-empty','root-guarded'):
                        candidate='\(fixture.path)/workspace/'+child
                        if candidate in request['candidates']:
                            marker=candidate+'/.git'
                            expected=[marker]+[marker+'/'+suffix for suffix in ('config','refs','refs/remotes','refs/remotes/origin','refs/remotes/origin/HEAD')]
                            if not set(expected).issubset(request['candidates']): rows=[]
                if mode in ('rebind-first-batch','rebind-first-protected') and '\(fixture.path)' in request['candidates']:
                    child='\(fixture.path)/workspace/products/ready'
                    marker=child+'/.git'
                    expected=[child,marker]+[marker+'/'+suffix for suffix in ('config','refs','refs/remotes','refs/remotes/origin','refs/remotes/origin/HEAD')]
                    if request['candidates'][0]!='\(fixture.path)' or not set(expected).issubset(request['candidates']): rows=[]
                # Rebind begins with [home, selected]; metadata preparation
                # begins with [home, projection]. Gate only the latter stage.
                metadata=request['candidates'][:2]==['\(fixture.path)','\(fixture.path)/workspace']
                if mode.startswith('metadata-read-first-') and metadata:
                    index=int(mode.rsplit('-',1)[1]); git='\(fixture.path)/workspace/products/ready/.git'
                    expected=[git+'/config.worktree',git+'/objects',git+'/commondir',git+'/refs/replace',git+'/info/grafts',git+'/objects/info/alternates',git+'/packed-refs']
                    busy=['index.lock','HEAD.lock','MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','BISECT_LOG','rebase-apply','rebase-merge','sequencer','packed-refs.lock','config.lock','shallow.lock','refs/heads/main.lock','refs/remotes/origin/main.lock']
                    if index in (1,4,5): expected += [git+'/'+p for p in busy]
                    if index==2: expected.append(git+'/worktrees')
                    if index==3: expected.append(git+'/index')
                    if index==4: expected.append(git+'/refs/heads/main')
                    if index==5: expected.append(git+'/refs/remotes/origin/main')
                    if index==6: expected.append(git+'/objects/aa/'+'a'*38)
                    prefixes={p[:i] for p in expected for i,c in enumerate(p) if c=='/' and i>len('\(fixture.path)')}
                    if not set(expected).union(prefixes).issubset(request['candidates']): rows=[]
                if mode=='metadata-read-replace' and metadata:
                    import os
                    path='\(fixture.path)/workspace/products/ready'
                    os.rename(path,path+'-saved-read-root'); os.mkdir(path,0o700)
                if mode=='partial': rows=[]
                if mode=='projection-prefetch-boundary' and '\(fixture.path)' in request['candidates']:
                    if len(request['candidates'])!=64 or '\(fixture.path)/.git' in request['candidates']: rows=[]
                print(json.dumps({'schema':'shadow-sync-policy-batch-response/v1',
                    'nonce':request['nonce'],'binding_sha256':request['binding_sha256'],
                    'policy_sha256':'\(snapshot.binding.policy.sha256)',
                    'module_sha256':'\(snapshot.binding.module.sha256)','results':rows}))
                return 0
            """
            return try PolicyCatalogSession(snapshot: snapshot, interpreter: interpreter,
                adapter: Data(code.utf8), contract: contractBytes, scratchDescriptor: directory,
                cancellation: cancellation, revalidateResources: resourceCheck, validateInterpreter: { _ in }, audit: audit)
        }
        func remove() throws {
            if removed { return }
            try fixture.remove()
            let result = close(directory)
            removed = true
            try require(result == 0, "session scratch close")
        }
        deinit { try? remove() }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.assertion(message) } }
    private static func publisherRefuse(_ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("refused coordinator handoff accepted") }
        catch PublisherPolicyError.unavailable {}
    }

    private static func refuse(_ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("invalid configuration snapshot accepted") }
        catch HostPolicyBindingError.unavailable {}
    }

    private final class Fixture {
        static let binding = "Library/Application Support/ShadowSync/host-policy-binding.json"
        let path: String
        let device: Int32
        let inode: UInt64
        let contents: [String: Data]
        let binding: [String: Any]
        let projection: [String: Any]
        private var removed = false

        init(layout: DiscoveryFixtureLayout = .products) throws {
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-authority-") + "XXXXXX").utf8CString)
            guard let result = mkdtemp(&template) else { throw Failure.assertion("snapshot fixture create") }
            path = String(cString: result)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw Failure.assertion("snapshot fixture identity")
            }
            device = info.st_dev; inode = info.st_ino
            let policy = Data("hard_no_touch_paths:\n  roots: []\n".utf8)
            let overlay = Data("{\"fixture\":true}\n".utf8)
            let dispatcher = Data("#!/bin/sh\nexit 0\n".utf8)
            let module = Data("not executable python: fixture bytes only\n".utf8)
            let governedRoot: [String: Any] = [
                "components": layout == .products ? ["workspace"] : ["dev"],
                "display_label": layout == .products ? "~/workspace" : "~/dev",
                "repository_id": "fixture-owner/root",
            ]
            let shelves: [[String]] = layout == .products ? [["products"]] : [["personal"]]
            let managedLocations: [[String: Any]] = layout == .products ? [] : [
                ["kind": "awa", "components": [".local", "share", "awa", "worktrees"], "minimum_depth": 1],
            ]
            projection = [
                "schema": "shadow-sync-host-policy-projection/v1",
                "source_inputs": ["worktree_policy": ["path": "owner/policy.yml", "sha256": digest(policy)],
                    "host_overlay": ["path": "owner/overlay.json", "sha256": digest(overlay)],
                    "hook_dispatcher": ["path": "owner/dispatcher", "sha256": digest(dispatcher)]],
                "governed_root": governedRoot,
                "shelves": shelves,
                "path_policy": ["excluded": ["."], "read_only": [String](), "artifacts": [String](), "writable": ["."]],
                "permanent_no_touch_repository_ids": ["fixture-owner/protected"],
                "managed_locations": managedLocations,
                "hooks": ["foreign_markers": ["fixture-hook"], "dispatcher_base64": dispatcher.base64EncodedString(), "dispatcher_sha256": digest(dispatcher)],
                "awa_evidence": NSNull(),
            ]
            let projectionBytes = try json(projection)
            binding = ["schema": "shadow-sync-host-policy-binding/v1",
                "policy": ["path": "owner/policy.yml", "sha256": digest(policy)],
                "projection": ["path": "owner/projection.json", "sha256": digest(projectionBytes)],
                "awa": ["module_path": "runtime/policy.py", "module_sha256": digest(module), "release_revision": String(repeating: "a", count: 40)]]
            contents = [Self.binding: try json(binding), "owner/policy.yml": policy, "owner/projection.json": projectionBytes,
                        "runtime/policy.py": module, "owner/overlay.json": overlay, "owner/dispatcher": dispatcher]
            do { try restore() } catch { try? remove(); throw error }
        }
        func contract(moduleDigest: String? = nil) throws -> QualifiedAWAContract {
            try QualifiedAWAContract.decode(json(["schema": "shadow-sync-awa-contract/v1", "status": "qualified",
                "release_revision": String(repeating: "a", count: 40), "module_sha256": moduleDigest ?? digest(contents["runtime/policy.py"]!)]))
        }
        func write(_ name: String, _ data: Data) throws {
            let target = path + "/" + name
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: target).deletingLastPathComponent().path,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: URL(fileURLWithPath: target))
            try require(chmod(target, 0o600) == 0, "snapshot input permissions")
        }
        func restore() throws { for (name, data) in contents { try write(name, data) } }
        func remove() throws {
            if removed { return }
            var info = stat()
            try require(lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
                        && info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFDIR, "snapshot cleanup identity")
            try FileManager.default.removeItem(atPath: path); removed = true
        }
    }
}
#endif
