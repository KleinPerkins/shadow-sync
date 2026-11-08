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
        try runRepositoryGit(onPass: onPass)
        try runRepositoryGitCorrections(onPass: onPass)
    }

    private static func runRepositoryGit(onPass: (String) -> Void) throws {
        for test in ["positive", "wrong-origin", "read-mutation", "cancelled", "unknown-field"] {
            let id = "REPOSITORY-GIT-" + test
            try RuntimeFixtureSession.withCase(id) {
                let fixture = try Fixture(systemConfiguration: false)
                var failure: Error?
                do {
                    let prepared = try repositoryFixtureResources(root: fixture.root, context: fixture.context)
                    let handle = prepared.0, frozen = prepared.1, snapshot = prepared.2
                    let args = ["--no-replace-objects", "--no-lazy-fetch", "rev-parse", "--verify", "HEAD^{commit}"]
                    let token = CancellationToken()
                    if test == "cancelled" { token.cancel() }
                    if test == "read-mutation" {
                        do {
                            _ = try fixture.context.prepareRepositoryGit(arguments: ["--no-replace-objects", "--no-lazy-fetch",
                                "merge", "--ff-only", "--no-overwrite-ignore", "--no-autostash", String(repeating: "a", count: 40)],
                                handle: handle, frozen: frozen, snapshot: snapshot,
                                budget: CustodyBudget.make(kind: .repositoryGit, workSeconds: 10), outputLimit: 65_536, cancellation: token)
                            throw Failure.assertion("read scope admitted mutation")
                        } catch is CustodyResourceError {}
                        try require(RetainedCleanupRegistry.shared.testingCount == 0, "refused mutation reserved custody")
                    } else if test == "unknown-field" {
                        let input = try RepositoryGitCustodyInput(policy: fixture.snapshot, snapshot: snapshot, transport: .https, sshAgent: nil)
                        var object = try JSONSerialization.jsonObject(with: input.encode()) as! [String: Any]
                        object["executable"] = "/bin/false"
                        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                        do { _ = try RepositoryGitCustodyInput.decode(bytes); throw Failure.assertion("unknown input accepted") }
                        catch is CustodyResourceError {}
                    } else {
                        let selected: RepositoryExecutionSnapshot
                        if test == "wrong-origin" {
                            selected = try handle.executionSnapshot(account: fixture.account, frozenConfiguration: frozen,
                                admission: GitAdmissionSnapshot(effectiveURL: "https://github.com/fixture-owner/wrong.git",
                                    transport: .https, frozenConfigSHA256: frozen.snapshot.frozenSHA256))
                        } else { selected = snapshot }
                        var value: ProcessResult?, rejection: Error?
                        do {
                            value = try DescriptorProcessRunner(outputLimit: 65_536).runRepository(arguments: args,
                                context: fixture.context, handle: handle, frozen: frozen, snapshot: selected,
                                timeout: 15, cancellation: token)
                        } catch { rejection = error }
                        if test == "positive" {
                            if let rejection { throw rejection }
                            guard let value else { throw Failure.assertion("repository real Git result missing") }
                            let trimmed = String(decoding: value.stdout, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !(value.succeeded && value.stderr.isEmpty && trimmed.count == 40) {
                                // Fixed scalar diagnostics only: preserve the exact predicate,
                                // command result and budgets without logging repository bytes.
                                let diagnostic = "repository real Git result status=\(value.status)"
                                    + " succeeded=\(value.succeeded) timeout=\(value.timedOut) cancelled=\(value.cancelled)"
                                    + " stdout_truncated=\(value.stdoutTruncated) stderr_truncated=\(value.stderrTruncated)"
                                    + " stdout_bytes=\(value.stdout.count) stderr_bytes=\(value.stderr.count) trimmed_chars=\(trimmed.count)"
                                    + " stderr_fixture_marker=\(value.stderr.range(of: Data("shadow-sync-fixture-".utf8)) != nil)"
                                throw Failure.assertion(diagnostic)
                            }
                        } else { try require(rejection != nil && value == nil, "repository negative case unexpectedly succeeded") }
                    }
                } catch { failure = error }
                try fixture.remove(expectDiscovery: false, allowUnsubmitted: true)
                if let failure { throw failure }
            }
            onPass(id)
        }
        for phase in ["system", "policy", "root", "origin", "transport", "command", "postflight"] {
            let id = "REPOSITORY-GIT-worker-loss-" + phase
            try RuntimeFixtureSession.withCase(id) { try repositoryWorkerLoss(phase: phase) }
            onPass(id)
        }
    }


    public static func runRetentionCustody(onPass: (String) -> Void) throws {
        let cases = ["RETENTION-CUSTODY-T01-real-bundle-and-restore", "RETENTION-CUSTODY-T02-nonempty-repeated-config",
            "RETENTION-CUSTODY-T03-closed-context-before-access", "RETENTION-CUSTODY-T04-source-identity-race",
            "RETENTION-CUSTODY-T05-destination-identity-race", "RETENTION-CUSTODY-T06-publisher-race",
            "RETENTION-CUSTODY-T07-cancel-and-control-eof", "RETENTION-CUSTODY-T08-pending-keeps-resources"]
        for (index, id) in cases.enumerated() {
            try RuntimeFixtureSession.withCase(id) {
                let fixture = try Fixture(systemConfiguration: true, retention: true)
                var failure: Error?
                do { try fixture.retentionCase(index) } catch { failure = error }
                do { try fixture.remove(expectDiscovery: false, allowUnsubmitted: index == 2) }
                catch { throw Failure.assertion("retention=\(String(describing: failure)); cleanup=\(error)") }
                if let failure { throw failure }
            }
            onPass(id)
        }
        try runFrozenAdmissionCorrections(onPass: onPass)
        try runFrozenRecoveryCorrections(onPass: onPass)
        try runFrozenBudgetCorrections(onPass: onPass)
        try runRetentionCallerCorrections(onPass: onPass)
        for phase in ["bundle", "restore", "bundle-resumed", "restore-resumed", "store-bundle", "body3-bundle"] {
            let id = "RETENTION-CUSTODY-worker-loss-" + phase
            try RuntimeFixtureSession.withCase(id) { try retentionWorkerLoss(phase: phase) }
            onPass(id)
        }
    }

    private final class FrozenAccessObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func access() { lock.lock(); count += 1; lock.unlock() }
        var accesses: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private static func runFrozenAdmissionCorrections(onPass: (String) -> Void) throws {
        for resource in ["root", "directory", "config"] {
            for refusal in ["denied", "malformed", "stale"] {
                let id = "FROZEN-ADMISSION-" + resource + "-" + refusal
                try RuntimeFixtureSession.withCase(id) {
                    let fixture = try Fixture(systemConfiguration: true)
                    var failure: Error?
                    let adapter = fixture.home + "/.shadow-sync-fixture/PolicyAdapter.py"
                    let policy = fixture.home + "/" + fixture.snapshot.binding.policy.relativePath
                    let originalAdapter = try Data(contentsOf: URL(fileURLWithPath: adapter))
                    let originalPolicy = try Data(contentsOf: URL(fileURLWithPath: policy))
                    let classified = fixture.root + "/frozen-classified.jsonl"
                    do {
                        let original = try RepositoryHandle.testingBoundCandidate(path: fixture.repository,
                            id: "fixture-owner/ready", displayName: "Fixture", rawOrigin: "https://github.com/fixture-owner/ready.git")
                        let candidate = RepositoryCandidate(id: original.id, displayName: original.displayName, path: original.path,
                            rawOrigin: original.rawOrigin, rootIdentity: original.rootIdentity, gitDirectoryIdentity: original.gitDirectoryIdentity,
                            commonDirectoryIdentity: original.commonDirectoryIdentity, configIdentity: original.configIdentity,
                            policyAdmissionSHA256: fixture.snapshot.admissionSHA256)
                        let handle = try RepositoryHandle.open(candidate)
                        // Prove the exact fixture can complete before introducing a
                        // refusal; an unrelated setup failure must never pass a negative.
                        do {
                            let baselineProbe = SystemGitConfigurationProbe(testingContext: fixture.context,
                                cancellation: fixture.cancellation) {
                                try DiscoveryFixtureResources.systemConfiguration(home: fixture.home)
                            }
                            let baseline = try handle.freezeConfiguration(account: fixture.account,
                                retainedConfigurationProbe: baselineProbe)
                            try require(baseline.snapshot.frozenSize > 0 && !RetainedCleanupRegistry.shared.hasRetainedWork,
                                "frozen negative fixture lacks successful baseline")
                        }
                        let observation = FrozenAccessObservation()
                        let probe = SystemGitConfigurationProbe(testingContext: fixture.context, cancellation: fixture.cancellation) {
                            try DiscoveryFixtureResources.systemConfiguration(home: fixture.home)
                        }
                        probe.testingFrozenAccess = { observation.access() }
                        if refusal == "stale" {
                            try Data("stale fixture policy".utf8).write(to: URL(fileURLWithPath: policy))
                            do { try fixture.snapshot.revalidate(); throw Failure.assertion("stale policy fixture unchanged") }
                            catch HostPolicyBindingError.unavailable { }
                        } else {
                            let match: String
                            switch resource {
                            case "root": match = "path == '/private/tmp'"
                            case "directory": match = "'shadow-sync-fixture-config.' in path and not path.endswith('/config')"
                            default: match = "'shadow-sync-fixture-config.' in path and path.endswith('/config')"
                            }
                            var text = String(decoding: originalAdapter, as: UTF8.self)
                            let quotedPath = String(decoding: try JSONSerialization.data(withJSONObject: classified,
                                options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
                            text = text.replacingOccurrences(of: "request=json.load(sys.stdin)",
                                with: "request=json.load(sys.stdin)\n    with open(\(quotedPath), 'a') as observed: observed.write(json.dumps(request['candidates'])+'\\n')")
                            if refusal == "denied" {
                                text = text.replacingOccurrences(of: "'matched':False,'kind':'none'",
                                    with: "'matched':bool(\(match)),'kind':('invalid_candidate' if \(match) else 'none')")
                            } else {
                                text = text.replacingOccurrences(of: "'nonce':request['nonce']",
                                    with: "'nonce':('malformed-fixture' if any(\(match) for path in request['candidates']) else request['nonce'])")
                            }
                            try Data(text.utf8).write(to: URL(fileURLWithPath: adapter))
                        }
                        do {
                            _ = try handle.freezeConfiguration(account: fixture.account, retainedConfigurationProbe: probe)
                            throw Failure.assertion("frozen scratch policy refusal admitted access")
                        } catch SystemGitConfigurationError.unavailable { }
                        if refusal != "stale" {
                            let requests = try String(contentsOfFile: classified, encoding: .utf8).split(separator: "\n")
                            let paths = try requests.flatMap { line -> [String] in
                                guard let values = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String] else {
                                    throw Failure.assertion("classifier boundary observation malformed")
                                }
                                return values
                            }
                            let observed = paths.contains { path in
                                if resource == "root" { return path == "/private/tmp" }
                                if resource == "directory" { return path.contains("shadow-sync-fixture-config.") && !path.hasSuffix("/config") }
                                return path.contains("shadow-sync-fixture-config.") && path.hasSuffix("/config")
                            }
                            try require(observed, "denied/malformed classifier never saw exact target path")
                        }
                        try require(observation.accesses == 0 && !RetainedCleanupRegistry.shared.hasRetainedWork,
                            "frozen scratch accessed before policy admission or leaked cleanup")
                    } catch { failure = error }
                    try originalAdapter.write(to: URL(fileURLWithPath: adapter))
                    try originalPolicy.write(to: URL(fileURLWithPath: policy))
                    try fixture.remove(expectDiscovery: false, allowUnsubmitted: true)
                    if let failure { throw failure }
                }
                onPass(id)
            }
        }
    }

    private static func frozenCorrectionHandle(_ fixture: Fixture) throws -> RepositoryHandle {
        let original = try RepositoryHandle.testingBoundCandidate(path: fixture.repository,
            id: "fixture-owner/ready", displayName: "Fixture", rawOrigin: "https://github.com/fixture-owner/ready.git")
        return try RepositoryHandle.open(RepositoryCandidate(id: original.id, displayName: original.displayName,
            path: original.path, rawOrigin: original.rawOrigin, rootIdentity: original.rootIdentity,
            gitDirectoryIdentity: original.gitDirectoryIdentity, commonDirectoryIdentity: original.commonDirectoryIdentity,
            configIdentity: original.configIdentity, policyAdmissionSHA256: fixture.snapshot.admissionSHA256))
    }

    /// One exact fixture-owned immutable candidate. Keeping descriptors open does
    /// not impersonate a live owner: only the live-owner case takes a shared lock.
    private final class FrozenRecoveryCandidate {
        let path: String
        private let ownedDirectory: OwnedFileDescriptor, ownedFile: OwnedFileDescriptor
        var directory: Int32 { ownedDirectory.value }
        var file: Int32 { ownedFile.value }
        let directoryIdentity: FileIdentity, fileIdentity: FileIdentity
        let bytes = Data("[fixture]\nvalue = stale\n".utf8)
        init(live: Bool = false, malformed: Bool = false) throws {
            path = try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.")
                + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
            try DiscoveryCallerSelfTestRunner.require(mkdir(path, 0o700) == 0, "create recovery fixture")
            let directoryFD = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try DiscoveryCallerSelfTestRunner.require(directoryFD >= 0, "open recovery fixture")
            ownedDirectory = OwnedFileDescriptor(directoryFD)
            let fileFD = openat(directoryFD, "config", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try DiscoveryCallerSelfTestRunner.require(fileFD >= 0, "create recovery config")
            ownedFile = OwnedFileDescriptor(fileFD)
            directoryIdentity = try RetentionArchiveCommandAuthority.identity(directoryFD)
            fileIdentity = try RetentionArchiveCommandAuthority.identity(fileFD)
            let written = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
            try DiscoveryCallerSelfTestRunner.require(written == bytes.count && fchmod(file, 0o600) == 0
                && fchmod(directory, 0o700) == 0, "write recovery fixture")
            if live { try DiscoveryCallerSelfTestRunner.require(flock(file, LOCK_SH | LOCK_NB) == 0, "hold live snapshot") }
            try DiscoveryCallerSelfTestRunner.require(fchflags(file, UInt32(UF_IMMUTABLE)) == 0
                && (malformed || fchflags(directory, UInt32(UF_IMMUTABLE)) == 0), "seal recovery fixture")
        }
        func requirePreserved() throws {
            var named = stat(), leaf = stat()
            try DiscoveryCallerSelfTestRunner.require(lstat(path, &named) == 0
                && FileIdentity(named).matchesStableNode(directoryIdentity)
                && fstatat(directory, "config", &leaf, AT_SYMLINK_NOFOLLOW) == 0
                && FileIdentity(leaf).matchesStableNode(fileIdentity), "refused recovery changed candidate identities")
            try DiscoveryCallerSelfTestRunner.require(try Data(contentsOf: URL(fileURLWithPath: path + "/config")) == bytes,
                "refused recovery changed candidate contents")
        }
        func dispose(recovered: Bool) throws {
            if recovered {
                var named = stat()
                try DiscoveryCallerSelfTestRunner.require(lstat(path, &named) != 0 && errno == ENOENT,
                    "successful recovery retained fixture candidate")
            } else {
                try requirePreserved()
                try DiscoveryCallerSelfTestRunner.require(fchflags(directory, 0) == 0 && fchflags(file, 0) == 0
                    && unlinkat(directory, "config", 0) == 0 && rmdir(path) == 0,
                    "fixture-owned candidate cleanup")
            }
            ownedFile.closeNow(); ownedDirectory.closeNow()
        }
    }

    private static func runFrozenRecoveryCorrections(onPass: (String) -> Void) throws {
        let boundaries = ["root-admitted", "root-read", "candidates-admitted", "candidate-open",
            "candidate-read", "config-open", "candidate-delete"]
        let cases = ["success", "live-owner", "malformed"]
            + boundaries.flatMap { boundary in [boundary + "-stale", boundary + "-missing"] }
            + ["root-read-publisher"]
        for test in cases {
            let id = "FROZEN-RECOVERY-" + test
            try RuntimeFixtureSession.withCase(id) {
                let fixture = try Fixture(systemConfiguration: true)
                let candidate = try FrozenRecoveryCandidate(live: test == "live-owner", malformed: test == "malformed")
                let policyPath = fixture.home + "/" + fixture.snapshot.binding.policy.relativePath
                let publisherPath = fixture.home + "/.shadow-sync-fixture/PolicyAdapter.py"
                let targetPath = test.hasSuffix("-publisher") ? publisherPath : policyPath
                let original = try Data(contentsOf: URL(fileURLWithPath: targetPath))
                var failure: Error?, mutated = false, recovered = false
                var accesses: [String] = [], boundariesSeen: [String] = [], accessCountAtRefusal = -1
                do {
                    let handle = try frozenCorrectionHandle(fixture)
                    let probe = SystemGitConfigurationProbe(testingContext: fixture.context, cancellation: fixture.cancellation) {
                        try DiscoveryFixtureResources.systemConfiguration(home: fixture.home)
                    }
                    probe.testingFrozenRecoveryAccess = { accesses.append($0) }
                    probe.testingFrozenRecoveryBoundary = { boundary in
                        boundariesSeen.append(boundary)
                        if !mutated && ["-stale", "-missing", "-publisher"].contains(where: { test == boundary + $0 }) {
                            mutated = true; accessCountAtRefusal = accesses.count
                            if test.hasSuffix("-missing") { try FileManager.default.removeItem(atPath: targetPath) }
                            else { try Data("changed fixture authority".utf8).write(to: URL(fileURLWithPath: targetPath)) }
                        }
                    }
                    if test == "success" || test == "live-owner" {
                        let frozen = try handle.freezeConfiguration(account: fixture.account, retainedConfigurationProbe: probe)
                        try require(frozen.snapshot.frozenSize > 0 && boundariesSeen.contains("candidates-admitted")
                            && accesses.contains("candidate-open") && accesses.contains("config-open"),
                            "positive recovery did not reach actual candidate access")
                        if test == "success" {
                            try require(accesses.filter { $0 == "candidate-delete" }.count == 1, "stale candidate not recovered once")
                            recovered = true
                        } else {
                            try require(!accesses.contains("candidate-delete"), "live owner was deleted")
                            try candidate.requirePreserved()
                        }
                    } else if test == "malformed" {
                        do {
                            _ = try handle.freezeConfiguration(account: fixture.account, retainedConfigurationProbe: probe)
                            throw Failure.assertion("malformed candidate accepted")
                        } catch GitSafetyError.unsafeRepository { }
                        try require(accesses.contains("candidate-open") && !accesses.contains("config-open")
                            && !accesses.contains("candidate-delete"), "malformed recovery failed at wrong boundary")
                        try candidate.requirePreserved()
                    } else {
                        do {
                            _ = try handle.freezeConfiguration(account: fixture.account, retainedConfigurationProbe: probe)
                            throw Failure.assertion("changed recovery authority admitted access")
                        } catch SystemGitConfigurationError.unavailable { }
                        try require(mutated && accessCountAtRefusal >= 0 && accesses.count == accessCountAtRefusal,
                            "negative boundary was not reached or recovery accessed after authority refusal")
                        try require(!accesses.contains("candidate-delete"), "authority refusal deleted a candidate")
                        try candidate.requirePreserved()
                    }
                    try require(!RetainedCleanupRegistry.shared.hasRetainedWork, "recovery left unresolved custody")
                } catch { failure = error }
                if mutated { try original.write(to: URL(fileURLWithPath: targetPath)) }
                // Failure evidence is not reclassified as a successful recovery.
                // Only the exact still-present fixture candidate may be removed.
                try candidate.dispose(recovered: recovered)
                try fixture.remove(expectDiscovery: false, allowUnsubmitted: true)
                if let failure { throw failure }
            }
            onPass(id)
        }
    }

    private static func runFrozenBudgetCorrections(onPass: (String) -> Void) throws {
        let pureID = "FROZEN-BUDGET-parent-endpoints-and-default"
        try RuntimeFixtureSession.withCase(pureID) {
            let now: UInt64 = 10_000_000_000
            let parent = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 1,
                termSeconds: 0, killSeconds: 0, receiptSeconds: 0, now: now)
            let child = try PolicyCommandWire.budget(timeout: 2, absoluteDeadline: parent.work,
                enclosingBudget: parent, now: now)
            try require(child.work == parent.work && child.term == parent.term
                && child.kill == parent.kill && child.receipt == parent.receipt, "nested policy extended original endpoints")
            do {
                _ = try PolicyCommandWire.budget(timeout: 2, absoluteDeadline: parent.work,
                    enclosingBudget: parent, now: parent.work)
                throw Failure.assertion("expired original policy budget accepted")
            } catch CustodyProtocolError.invalidBudget { }
            let zeroGrace = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 10,
                termSeconds: 0, killSeconds: 0, receiptSeconds: 0, now: now)
            let earlyChild = try PolicyCommandWire.budget(timeout: 1, absoluteDeadline: zeroGrace.work,
                enclosingBudget: zeroGrace, now: now)
            try require(earlyChild.work == earlyChild.term && earlyChild.term == earlyChild.kill
                && earlyChild.kill == earlyChild.receipt, "short child regained enclosing cleanup grace")
            // Exercise both short child and short parent ceilings, delayed
            // preparation, and zero/partial/full cleanup without raw construction.
            for outerWork: Double in [0.5, 3, 120] {
                for grace: Double in [0, 0.25, 1] {
                    let outer = try CustodyBudget.make(kind: .repositoryGit, workSeconds: outerWork,
                        termSeconds: grace, killSeconds: grace, receiptSeconds: grace, now: now)
                    for offset: UInt64 in [0, 100_000_000] {
                        for timeout: Double in [0.1, 1, 2] {
                            let start = now + offset
                            let raw = try CustodyBudget.make(kind: .policyClassify, workSeconds: timeout, now: start)
                            let parentBound = try outer.repositoryPreflight(.policyClassification, now: start)
                                .draining(at: raw.work)
                            let actual = try PolicyCommandWire.budget(timeout: timeout, absoluteDeadline: nil,
                                enclosingBudget: outer, now: start)
                            try require(actual.issued == raw.issued && actual.work == min(raw.work, parentBound.work)
                                && actual.term == min(raw.term, parentBound.term)
                                && actual.kill == min(raw.kill, parentBound.kill)
                                && actual.receipt == min(raw.receipt, parentBound.receipt),
                                "nested policy clipping changed an original endpoint")
                        }
                    }
                }
            }
            let original = try CustodyBudget.make(kind: .policyClassify, workSeconds: 2, now: now)
            for limit: UInt64? in [nil, parent.work, original.receipt] {
                let actual = try PolicyCommandWire.budget(timeout: 2, absoluteDeadline: limit, now: now)
                let expected = try limit.map { try original.draining(at: $0) } ?? original
                try require(actual == expected, "default policy budget behavior changed")
            }
        }
        onPass(pureID)
        let boundaryID = "FROZEN-BUDGET-expired-retention-callback"
        try RuntimeFixtureSession.withCase(boundaryID) {
            let fixture = try Fixture(systemConfiguration: true, retention: true)
            var failure: Error?
            do {
                let admission = try fixture.context.retentionAdmission(cancellation: fixture.cancellation)
                let handle = try frozenCorrectionHandle(fixture)
                let probe = SystemGitConfigurationProbe(testingContext: fixture.context, cancellation: fixture.cancellation) {
                    try DiscoveryFixtureResources.systemConfiguration(home: fixture.home)
                }
                let original = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 15,
                    termSeconds: 0, killSeconds: 0, receiptSeconds: 0)
                probe.testingFreezeBudget = original
                let receipts = try StateLocation.isolated(root: fixture.root).path + "/custody/receipts"
                var before: [String] = [], reached = false, callbackReached = false
                probe.testingBeforeConfigurationAdmission = { budget in
                    try require(budget == original, "freeze changed enclosing budget")
                    before = try FileManager.default.contentsOfDirectory(atPath: receipts).sorted()
                    try require(!before.isEmpty, "deadline fixture never ran initial policy admission")
                    reached = true
                    while DispatchTime.now().uptimeNanoseconds < budget.work { usleep(1_000) }
                }
                do {
                    _ = try handle.freezeConfiguration(account: fixture.account, retainedConfigurationProbe: probe,
                        admitConfiguration: { preflight, budget in
                            callbackReached = true
                            try require(reached && budget == original
                                && DispatchTime.now().uptimeNanoseconds >= budget.work, "wrong callback deadline boundary")
                            try admission.classify(paths: preflight.admissionPaths(account: fixture.account),
                                scratch: fixture.directory, cancellation: fixture.cancellation, budget: budget)
                        })
                    throw Failure.assertion("expired retention configuration callback succeeded")
                } catch CustodyProtocolError.invalidBudget { }
                try require(reached && callbackReached && !RetainedCleanupRegistry.shared.hasRetainedWork
                    && before == (try FileManager.default.contentsOfDirectory(atPath: receipts).sorted()),
                    "expired original callback admitted a policy child or did not reach boundary")
            } catch { failure = error }
            try fixture.remove(expectDiscovery: false, allowUnsubmitted: true)
            if let failure { throw failure }
        }
        onPass(boundaryID)
    }

    private final class RetentionCallerObservations: @unchecked Sendable {
        let lock = NSLock()
        var handles: [RetainedCleanupRegistry.Handle] = []
        var commands: [PreparedCustodyCommand] = []
        var events: [Body3LogRecord] = []
        var scopes = Set<String>()
        weak var context: CommandCustodyContext?
        var first = true
        func takeFirst() -> Bool { lock.lock(); defer { lock.unlock() }; let v = first; first = false; return v }
        func append(_ command: PreparedCustodyCommand, _ handle: RetainedCleanupRegistry.Handle) {
            lock.lock(); commands.append(command); handles.append(handle); lock.unlock()
        }
        func event(_ record: Body3LogRecord) { lock.lock(); events.append(record); lock.unlock() }
        func observe(_ value: CommandCustodyContext) { lock.lock(); context = value; scopes.insert(value.id); lock.unlock() }
        func drain() throws {
            for handle in handles {
                RetainedCleanupRegistry.shared.testingReleaseDeferredRead(handle)
                handle.cancel()
            }
            let deadline = MonotonicDeadline(seconds: 12)
            while RetainedCleanupRegistry.shared.hasRetainedWork && !deadline.hasExpired { usleep(2_000) }
            try DiscoveryCallerSelfTestRunner.require(!RetainedCleanupRegistry.shared.hasRetainedWork,
                "actual caller cleanup unresolved; fixture retained")
            try DiscoveryCallerSelfTestRunner.require(commands.allSatisfy { $0.resources.testingResourcesRetired },
                "actual caller retained command aliases")
            handles.removeAll(); commands.removeAll()
        }
    }

    private static func retentionSelection(root: String, policyDigest: String) throws -> (RemovalSelection, RepositoryInventory) {
        let repository = root + "/home/workspace/products/ready"
        let tip = try String(contentsOfFile: repository + "/.git/refs/heads/main", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Disposable fixture setup, never a product Git mutation path.
        try write(repository + "/.git/refs/heads/recovery-fixture", Data((tip + "\n").utf8))
        // The recovery branch is a fixture-owned, unclaimed copy of the actual main tip.
        let actualHead = try String(contentsOfFile: repository + "/.git/HEAD", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveryTip = try String(contentsOfFile: repository + "/.git/refs/heads/recovery-fixture", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentMainTip = try String(contentsOfFile: repository + "/.git/refs/heads/main", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(actualHead == "ref: refs/heads/main" && recoveryTip == tip && currentMainTip == tip,
            "retention fixture branch identity or equality changed")
        let original = try RepositoryHandle.testingBoundCandidate(path: repository, id: "fixture-owner/ready",
            displayName: "Fixture", rawOrigin: "https://github.com/fixture-owner/ready.git")
        let candidate = RepositoryCandidate(id: original.id, displayName: original.displayName, path: original.path,
            rawOrigin: original.rawOrigin, rootIdentity: original.rootIdentity, gitDirectoryIdentity: original.gitDirectoryIdentity,
            commonDirectoryIdentity: original.commonDirectoryIdentity, configIdentity: original.configIdentity,
            policyAdmissionSHA256: policyDigest)
        guard let common = candidate.commonDirectoryIdentity else { throw Failure.assertion("fixture common identity") }
        let branch = try Branch(cloneID: LocalClone.id(for: common), fullRef: "refs/heads/recovery-fixture", tipOID: tip,
            claimingWorktreeIDs: [],
            relationToDefault: DefaultBranchRelation(kind: .equal, aheadCount: 0, behindCount: 0),
            // Closed fixture PR evidence; no network lookup or production evidence inference.
            pullRequests: [], pullRequestAvailability: .available,
            removalPreview: RemovalPreview(recommendation: .recovery, permission: .previewOnly,
                explanation: "Fixture history requires recovery.", recoveryConsequence: "Preserve the fixture tip."))
        let clone = try LocalClone(repositoryID: candidate.id, sourceSnapshot: candidate, effectiveOrigin: candidate.rawOrigin,
            originParityVerified: true, policyCategory: .writable, kind: .primaryCheckout,
            worktrees: [], branches: [branch], warnings: [])
        let remote = try RemoteRepository(id: candidate.id, origins: [candidate.rawOrigin], policyCategory: .writable,
            resolvedDefault: RemoteDefaultBranch(name: "main", advertisedOID: tip), defaultUnavailableReason: nil)
        let removal = try RemovalCandidate(repository: remote, clone: clone, branch: branch)
        try require(removal.hardExclusion == nil && removal.canSelect,
            "retention fixture complete branch evidence is not selectable")
        let selection = try RemovalSelection(candidate: removal, intent: .removeWithRecovery, includePossibleSecrets: true)
        let card = try RepositoryCard(repository: remote,
            authority: CanonicalAuthorityState(status: .usable, record: RepositoryAuthorityRecord(clone: clone), explanation: "Fixture authority."),
            clones: [clone], relation: DefaultBranchRelation(kind: .equal, aheadCount: 0, behindCount: 0),
            fastForward: nil, fastForwardRefusal: nil)
        return (selection, RepositoryInventory(cards: [card], onboardingProposals: [], authorityFileIdentity: nil))
    }

    private static func runRetentionCallerCorrections(onPass: (String) -> Void) throws {
        for test in ["store-success", "store-pending", "store-retirement", "body3-success", "body3-pending",
                     "body3-pending-generic-error", "body3-pending-cancel"] {
            let id = "RETENTION-CALLER-" + test
            try RuntimeFixtureSession.withCase(id) {
                let body3 = test.hasPrefix("body3"), pending = test.contains("pending")
                let fixture = try Fixture(systemConfiguration: true, retention: !body3)
                let observed = RetentionCallerObservations()
                var failure: Error?
                do {
                    let selected = try retentionSelection(root: fixture.root, policyDigest: fixture.snapshot.admissionSHA256)
                    var hooks = RetentionArtifactStore.TestingCustodyHooks()
                    let barrier = CustodyLeaseTestingBarrier()
                    defer { barrier.release() }
                    hooks.beforePrepare = { _ in
                        if observed.takeFirst() {
                            if pending { RetainedCleanupRegistry.shared.testingDeferNextRead(.outputUntilReleased) }
                            if test == "store-retirement" { RetainedCleanupRegistry.shared.testingPauseNextRetirement(barrier) }
                        }
                    }
                    hooks.afterStart = { command, handle, token in
                        observed.append(command, handle)
                        if pending {
                            // Cancel shortens cleanup inside the original budget; deferred
                            // actual output EOF keeps the registry and owners pending.
                            handle.cancel()
                            let result = handle.wait()
                            try require(result.phase == .cleanupPending && RetainedCleanupRegistry.shared.hasRetainedWork,
                                "actual Store command did not enter retained cleanup")
                            if test.hasSuffix("generic-error") {
                                observed.context?.recordCleanupPending()
                                throw Failure.assertion("fixture error after actual pending")
                            }
                            if test.hasSuffix("cancel") { token.cancel() }
                        }
                        if test == "store-retirement", observed.commands.count == 1 {
                            try require(barrier.waitUntilEntered(), "retention retirement barrier missing")
                            try require(handle.snapshot().phase != .finished && !RetainedCleanupRegistry.shared.hasRetainedWork
                                && command.resources.testingResourcesRetired,
                                "testingResourcesRetired: retention finished before descriptor/accounting retirement")
                            barrier.release()
                        }
                    }
                    let location = try StateLocation.isolated(root: fixture.root)
                    if body3 {
                        fixture.releaseReadPhase()
                        var configuration = CoordinatorConfiguration(stateLocation: location, trampolineExecutable: CommandLine.arguments[0])
                        configuration.testingRepositoryCustodyRoot = fixture.root
                        configuration.testingRepositoryContextObserved = { observed.observe($0) }
                        configuration.testingRetentionCustodyHooks = hooks
                        let plan = try Body3BatchPlanner.make(run: RunIdentity.make(), operations: [], removals: [selected.0])
                        let coordinator = RunCoordinator(configuration: configuration, account: fixture.account)
                        let report = try coordinator.runBody3(plan: plan, selectedScope: .testing(plan: plan),
                            cancellation: CancellationToken(), inventoryProvider: { _ in selected.1 }) { event in
                                if let record = event.record { observed.event(record) }
                                event.confirmation?.cancel()
                            }
                        try require(!observed.commands.isEmpty, "Body 3 never entered actual retention Store")
                        if pending {
                            let roundTrip = try JSONDecoder().decode(Body3BatchReport.self, from: JSONEncoder().encode(report))
                            try require(roundTrip.cleanupPending && roundTrip == report, "pending report transport lost state")
                            var logBytes = Data()
                            for record in observed.events { logBytes.append(try JSONEncoder().encode(record)); logBytes.append(10) }
                            let decodedLog = Body3RunLogReader.decode(logBytes)
                            try require(decodedLog.last?.report?.cleanupPending == true, "pending structured log could not be read")
                            try require(report.cleanupPending && report.requiresReview
                                && report.results.contains { $0.status == .cleanupPending && !$0.status.isTerminal },
                                "Body 3 erased pending in report")
                            try require(observed.events.contains { $0.type == "run_cleanup_pending" }
                                && !observed.events.contains { $0.type == "run_finished" || $0.phase == "Complete" }
                                && !observed.events.contains { $0.type == "node_terminal" && $0.kind == "retention" },
                                "Body 3 emitted terminal cleanup evidence")
                        } else {
                            try require(!report.cleanupPending && observed.events.contains { $0.type == "run_finished" },
                                "successful retention did not return ordinary report")
                        }
                    } else {
                        let store = RetentionArtifactStore(state: try SecureStateDirectory.open(location), account: fixture.account,
                            configurationContext: fixture.context)
                        store.testingCustodyHooks = hooks
                        let result = store.prepare(selection: selected.0, cancellation: CancellationToken())
                        try require(!observed.commands.isEmpty, "runRetentionCallerCorrections: Store bypassed retained archive commands")
                        if pending {
                            try require(result == .cleanupPending && fixture.context.hasCleanupPending,
                                "Store erased actual cleanup pending")
                            let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/retention")
                            try require(names.contains { $0.hasPrefix(".incomplete-") }, "pending Store lost incomplete slot")
                        } else {
                            guard case .completed(let summary) = result else { throw Failure.assertion("actual Store did not complete: \(result)") }
                            try require(summary.restoreProven && (try store.verify(summary)), "Store restore proof missing")
                        }
                    }
                } catch { failure = error }
                try observed.drain()
                try fixture.remove(expectDiscovery: false, allowUnsubmitted: true, additionalScopeIDs: observed.scopes)
                if let failure { throw failure }
            }
            onPass(id)
        }
    }

    private struct RetentionWorkerObservation: Codable, Equatable {
        let pid: UInt32, group: UInt32, uid: UInt32
        let startSeconds: UInt64, startMicroseconds: UInt64
        let generation: String
        init(_ value: CustodyProcessObservation) {
            pid = value.pid; group = value.group; uid = value.uid
            startSeconds = value.startSeconds; startMicroseconds = value.startMicroseconds; generation = value.generation
        }
    }
    private static func retentionCustodyBytes(_ location: StateLocation, _ name: String) throws -> Data {
        try PolicyAuthorityFile.read(path: location.path + "/custody/" + name, owner: geteuid(), maximumBytes: 262_144).bytes
    }
    private struct RetentionWorkerReady: Codable {
        let request: String
        let budget: [UInt64]
        let frozen: GitConfigurationSnapshot
        let helper: RetentionWorkerObservation
        let target: RetentionWorkerObservation
        var slotPath: String? = nil
        var requestSHA256: String? = nil
        var inputSHA256: String? = nil
        var manifestSHA256: String? = nil
        var slotIdentity: FileIdentity? = nil
        var controlIdentity: FileIdentity? = nil
    }
    /// Only the enclosing disposable fixture creates this worker root.

    public static func dispatchRetentionWorker(_ arguments: [String]) -> Int32? {
        guard arguments.count == 4, arguments[1] == "--shadow-sync-retention-worker-fixture" else { return nil }
        return retentionWorker(root: arguments[2], phase: arguments[3])
    }
    private static func retentionCallerWorker(root: String, body3: Bool) -> Int32 {
        do {
            _ = try TestIsolation.validateRoot(root)
            let location = try StateLocation.isolated(root: root)
            let account = try EffectiveAccount.isolated(homeDirectory: root + "/home")
            let publisher = try PublisherPolicyResources.testingDiscovery(account: account)
            let policy = try HostPolicySnapshot.load(account: account, contract: QualifiedAWAContract.decode(publisher.contract))
            let selected = try retentionSelection(root: root, policyDigest: policy.admissionSHA256)
            var hooks = RetentionArtifactStore.TestingCustodyHooks()
            hooks.beforePrepare = { authority in
                if authority.arguments.contains("bundle") && authority.arguments.contains("create") {
                    authority.testingPauseAtAdmission()
                }
            }
            hooks.afterStart = { command, handle, _ in
                guard command.resources.request.arguments.contains("bundle"),
                      command.resources.request.arguments.contains("create") else { return }
                let deadline = MonotonicDeadline(seconds: 25)
                while !String(decoding: handle.snapshot().stderr, as: UTF8.self).contains("shadow-sync-fixture-final-preparation") {
                    guard !deadline.hasExpired, handle.snapshot().phase != .finished,
                          handle.snapshot().phase != .cleanupPending else { throw Failure.assertion("testingPauseAtAdmission: actual caller worker missed target boundary") }
                    usleep(2_000)
                }
                let journal = try CustodyJournal.decode(retentionCustodyBytes(location, command.resources.request.binding.requestID + ".json"))
                guard let helper = journal.custodian, let target = journal.target,
                      let slot = command.resources.request.arguments.first(where: { $0.hasSuffix("/branch.bundle") }) else {
                    throw Failure.assertion("retentionCallerWorker: actual caller worker lacked target evidence")
                }
                // The actual command's frozen owner is retained in the registry.
                let snapshot = try command.resources.testingFrozenSnapshot()
                try require(snapshot.frozenOwnerPID == getpid(),
                    "testingFrozenSnapshot: frozen owner differs from the actual caller worker")
                let budget = command.resources.request.budget
                let ready = RetentionWorkerReady(request: journal.binding.requestID,
                    budget: [budget.issued, budget.work, budget.term, budget.kill, budget.receipt], frozen: snapshot,
                    helper: RetentionWorkerObservation(helper), target: RetentionWorkerObservation(target),
                    slotPath: URL(fileURLWithPath: slot).deletingLastPathComponent().path)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try write(root + "/retention-worker-ready.new", encoder.encode(ready))
                let parent = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw Failure.assertion("worker marker root") }; defer { close(parent) }
                let file = openat(parent, "retention-worker-ready.new", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw Failure.assertion("worker marker file") }; defer { close(file) }
                try require(fsync(file) == 0 && renameatx_np(parent, "retention-worker-ready.new", parent,
                    "retention-worker-ready.json", UInt32(RENAME_EXCL)) == 0 && fsync(parent) == 0, "worker marker publication")
            }
            if body3 {
                var configuration = CoordinatorConfiguration(stateLocation: location, trampolineExecutable: CommandLine.arguments[0])
                configuration.testingRepositoryCustodyRoot = root
                configuration.testingRetentionCustodyHooks = hooks
                let plan = try Body3BatchPlanner.make(run: RunIdentity.make(), operations: [], removals: [selected.0])
                _ = try RunCoordinator(configuration: configuration, account: account).runBody3(plan: plan,
                    selectedScope: .testing(plan: plan), cancellation: CancellationToken(), inventoryProvider: { _ in selected.1 }) { $0.confirmation?.cancel() }
            } else {
                let authority = try RunAuthority.acquireRun(at: location)
                defer { authority.release() }
                let context = try CommandCustodyContext.testing(leases: authority.retainCommandLeases(),
                    location: location, root: root, authority: authority, discoveryFixture: true)
                defer { context.close() }
                let store = RetentionArtifactStore(state: try SecureStateDirectory.open(location), account: account, configurationContext: context)
                store.testingCustodyHooks = hooks
                _ = store.prepare(selection: selected.0, cancellation: CancellationToken())
            }
            return 94
        } catch { return 91 }
    }

    private static func retentionWorker(root: String, phase: String) -> Int32 {
        if phase == "store-bundle" || phase == "body3-bundle" { return retentionCallerWorker(root: root, body3: phase == "body3-bundle") }
        do {
            _ = try TestIsolation.validateRoot(root)
            guard ["bundle", "restore", "bundle-resumed", "restore-resumed"].contains(phase) else { return 90 }
            let location = try StateLocation.isolated(root: root)
            let authority = try RunAuthority.acquireRun(at: location)
            defer { authority.release() }
            let context = try CommandCustodyContext.testing(leases: authority.retainCommandLeases(),
                location: location, root: root, authority: authority, discoveryFixture: true)
            defer { context.close() }
            let account = try EffectiveAccount.isolated(homeDirectory: root + "/home")
            let cancellation = CancellationToken()
            let admission = try context.retentionAdmission(cancellation: cancellation)
            let repository = account.homeDirectory + "/workspace/products/ready"
            let original = try RepositoryHandle.testingBoundCandidate(path: repository, id: "fixture-owner/ready",
                displayName: "Fixture", rawOrigin: "https://github.com/fixture-owner/ready.git")
            let candidate = RepositoryCandidate(id: original.id, displayName: original.displayName, path: original.path,
                rawOrigin: original.rawOrigin, rootIdentity: original.rootIdentity, gitDirectoryIdentity: original.gitDirectoryIdentity,
                commonDirectoryIdentity: original.commonDirectoryIdentity, configIdentity: original.configIdentity,
                policyAdmissionSHA256: admission.policy.snapshot.admissionSHA256)
            let handle = try RepositoryHandle.open(candidate)
            let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: cancellation) {
                try DiscoveryFixtureResources.systemConfiguration(home: account.homeDirectory)
            }
            let frozen = try handle.freezeConfiguration(account: account, retainedConfigurationProbe: probe)
            let slot = location.path + "/retention/.incomplete-ret-worker"
            try FileManager.default.createDirectory(atPath: slot + "/.restore-proof", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let slotFD = open(slot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let proofFD = open(slot + "/.restore-proof", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard slotFD >= 0 && proofFD >= 0 else { return 90 }; defer { close(slotFD); close(proofFD) }
            func setup(_ args: [String]) throws -> ProcessResult {
                let result = try ClosedProcessRunner().run(command: ClosedProcessCommand(executable: "/usr/bin/git", arguments: args),
                    environment: ClosedProcessRunner.environment(account: account), workingDirectoryDescriptor: handle.worktreeDescriptor,
                    account: account, timeout: 10, cancellation: cancellation)
                try require(result.succeeded, "retention worker fixture setup"); return result
            }
            var payloadManifest: [TestingRetentionPayload.Entry] = []
            if phase.hasSuffix("-resumed") {
                // One fixed 32 MiB attempt; no automatic escalation or workload
                // execution is hidden behind retries. All setup commands retain 10s.
                try require(TestingRetentionPayload.count <= 256 && TestingRetentionPayload.initialBytes == 33_554_432,
                    "TestingRetentionPayload: retention workload bound")
                for index in 0..<TestingRetentionPayload.count {
                    let bytes = TestingRetentionPayload.bytes(index), name = TestingRetentionPayload.name(index)
                    try write(repository + "/" + name, bytes)
                    payloadManifest.append(.init(name: name, size: bytes.count, sha256: CustodyRecordBinding.digest(bytes)))
                }
                try TestingRetentionPayload.validate(payloadManifest)
                try write(repository + "/" + TestingRetentionPayload.manifestName, TestingRetentionPayload.encode(payloadManifest))
                _ = try setup(["-C", repository, "add", "--", TestingRetentionPayload.manifestName] + payloadManifest.map(\.name))
                _ = try setup(["-C", repository, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--quiet", "-m", "bounded retention fixture"])
                try testingRetentionScratchBound(root)
            }
            try require(try InheritedRetentionArchiveResources.testingAbsent(slotFD, TestingRetentionEOFWitness.filename)
                && InheritedRetentionArchiveResources.testingAbsent(slotFD, TestingRetentionEOFWitness.temporary), "retention witness preexisting")
            let tip = String(decoding: try setup(["-C", repository, "rev-parse", "HEAD"]).stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let args: [String]
            if phase.hasPrefix("restore") {
                _ = try setup(["--git-dir", handle.identity.commonDirectoryPath, "bundle", "create", slot + "/branch.bundle", "refs/heads/main"])
                args = ["clone", "--no-hardlinks", slot + "/branch.bundle", slot + "/.restore-proof/repository"]
            } else {
                args = ["--git-dir", handle.identity.commonDirectoryPath, "bundle", "create", slot + "/branch.bundle", "refs/heads/main"]
            }
            let budget = try CustodyBudget.make(kind: .retentionArchive, workSeconds: 120)
            let commandAuthority = try RetentionArchiveCommandAuthority(admission: admission, primary: handle, worktree: handle,
                frozen: frozen, destination: slotFD, slotPath: slot, cwd: phase.hasPrefix("restore") ? proofFD : handle.worktreeDescriptor,
                arguments: args, revision: "refs/heads/main", tip: tip, statePath: location.path)
            commandAuthority.testingPauseAtAdmission(afterResume: phase.hasSuffix("-resumed"))
            try require(commandAuthority.input.testingPauseAfterResume == phase.hasSuffix("-resumed")
                && commandAuthority.input.testingPauseBeforeResume != phase.hasSuffix("-resumed"),
                "testingPauseAtAdmission: requested retention boundary was not installed")
            let command = try context.prepareRetention(commandAuthority, budget: budget, cancellation: cancellation)
            let retained = try RetainedCleanupRegistry.shared.start(command)
            defer { retained.cancel() }
            // The closed spawn manifest passes only the pipe's reader to the
            // helper; CLOEXEC keeps this sole writer out of every target.
            let writer = command.resources.testingControlWriterDescriptor
            let writerIdentity = try RetentionArchiveCommandAuthority.identity(writer)
            guard fcntl(writer, F_GETFL) & O_ACCMODE == O_WRONLY
                && fcntl(writer, F_GETFD) & FD_CLOEXEC != 0
                && mode_t(writerIdentity.mode) & S_IFMT == S_IFIFO && writerIdentity.linkCount == 0 else {
                // Keep this fixed failure observable even though the worker's
                // outer catch intentionally discards arbitrary error payloads.
                fputs("retention original exclusive control writer\n", stderr)
                return 91
            }
            let deadline = MonotonicDeadline(seconds: 25)
            while !String(decoding: retained.snapshot().stderr, as: UTF8.self).contains("shadow-sync-fixture-final-preparation") {
                guard !deadline.hasExpired, retained.snapshot().phase != .finished,
                      retained.snapshot().phase != .cleanupPending else { return 92 }; usleep(2_000)
            }
            if phase.hasSuffix("-resumed") {
                // Readiness is phase-specific, but decisive liveness/ancestry
                // proof is the helper's later sample after this worker's true EOF.
                while true {
                    if (try? InheritedRetentionArchiveResources.testingOutput(slot: slotFD,
                        restore: phase.hasPrefix("restore"), manifest: payloadManifest)) != nil { break }
                    guard !deadline.hasExpired else { return 97 }; usleep(2_000)
                }
            }
            let journal = try CustodyJournal.decode(retentionCustodyBytes(location, command.resources.request.binding.requestID + ".json"))
            guard let helper = journal.custodian, let target = journal.target else { return 93 }
            let ready = RetentionWorkerReady(request: journal.binding.requestID,
                budget: [budget.issued, budget.work, budget.term, budget.kill, budget.receipt], frozen: frozen.snapshot,
                helper: RetentionWorkerObservation(helper), target: RetentionWorkerObservation(target),
                requestSHA256: CustodyRecordBinding.digest(try command.resources.request.encode()),
                inputSHA256: CustodyRecordBinding.digest(try commandAuthority.input.encode()),
                manifestSHA256: phase.hasSuffix("-resumed") ? CustodyRecordBinding.digest(try TestingRetentionPayload.encode(payloadManifest)) : nil,
                slotIdentity: try RetentionArchiveCommandAuthority.identity(slotFD), controlIdentity: writerIdentity)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try write(root + "/retention-worker-ready.new", encoder.encode(ready))
            let markerDirectory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard markerDirectory >= 0 else { return 96 }; defer { close(markerDirectory) }
            let markerFile = openat(markerDirectory, "retention-worker-ready.new", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard markerFile >= 0 else { return 96 }; defer { close(markerFile) }
            guard fsync(markerFile) == 0,
                  renameatx_np(markerDirectory, "retention-worker-ready.new", markerDirectory, "retention-worker-ready.json", UInt32(RENAME_EXCL)) == 0,
                  fsync(markerDirectory) == 0 else { return 96 }
            let result = retained.wait(); return result.phase == .finished ? 94 : 95
        } catch { return 91 }
    }

    /// Bounded disposable fixture accounting, never a host or repository inventory.
    /// Do not follow links; refuse unknown accounting and growth. Pending retains.
    private static func testingRetentionScratchBound(_ root: String) throws {
        _ = try TestIsolation.validateRoot(root)
        var count = 0, total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { throw Failure.assertion("retention scratch accounting") }
        while let name = enumerator.nextObject() as? String {
            count += 1
            try require(count <= 16_384 && !name.hasPrefix("/") && !name.split(separator: "/").contains(".."), "retention scratch entry bound")
            var st = stat()
            try require(lstat(root + "/" + name, &st) == 0, "retention scratch unknown node")
            // Existing fixture publisher frameworks contain reviewed symlinks;
            // do not follow them or charge the referenced external bytes.
            if st.st_mode & S_IFMT == S_IFREG {
                try require(st.st_size >= 0, "retention scratch negative size")
                total += st.st_size
                try require(total <= TestingRetentionPayload.scratchLimit, "retention scratch exceeds 1 GiB")
            }
        }
    }

    private static func spawnRetentionWorker(root: String, phase: String) throws -> (OwnedSpawnAnchor, OwnedDirectChild) {
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        try require(posix_spawn_file_actions_init(&actions) == 0, "retention worker spawn actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try require(posix_spawnattr_init(&attr) == 0, "retention worker spawn attributes")
        defer { posix_spawnattr_destroy(&attr) }
        for fd: Int32 in [0, 1, 2] {
            try require(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0,
                "retention worker null streams")
        }
        var defaults = sigset_t(), empty = sigset_t(); sigemptyset(&defaults); sigemptyset(&empty)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try require(posix_spawnattr_setflags(&attr, flags) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0
            && posix_spawnattr_setsigdefault(&attr, &defaults) == 0 && posix_spawnattr_setsigmask(&attr, &empty) == 0,
            "retention worker closed flags")
        let path = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()).executablePath
        let args = ([path, "--shadow-sync-retention-worker-fixture", root, phase] as [String]).map { value in
            value.withCString { strdup($0) }
        }
        var environmentValues = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=/private/tmp"]
        if let namespace = ProcessInfo.processInfo.environment["SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE"] {
            _ = try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.", namespace: namespace)
            environmentValues.append("SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE=" + namespace)
        }
        let environment = environmentValues.map { strdup($0) }
        defer { (args + environment).forEach { free($0) } }
        try require((args + environment).allSatisfy { $0 != nil }, "retention worker argv")
        var argv = args + [nil], env = environment + [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in try env.withUnsafeMutableBufferPointer { ev in
            try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: path,
                actions: &actions, attributes: &attr, arguments: av.baseAddress, environment: ev.baseAddress,
                streamsDrained: { true }, cooperativeStop: {})
        } }
        do {
            let owner = try anchor.transfer(expectedExecutable: path, generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
            return (anchor, owner)
        } catch { RuntimeFixtureSession.drain(anchor); throw error }
    }

    private static func retentionWorkerLoss(phase: String) throws {
        let fixture = try Fixture(systemConfiguration: true)
        try fixture.releaseForRetentionWorker()
        // On failure retain this fixture and its receipts, never erase unknown
        // helper custody. The runtime fixture owner still joins its own worker.
        let (anchor, owner) = try spawnRetentionWorker(root: fixture.root, phase: phase)
        defer { RuntimeFixtureSession.drain(anchor) }
        try require(owner.send(SIGCONT), "retention worker resume")
        let marker = fixture.root + "/retention-worker-ready.json"
        let deadline = MonotonicDeadline(seconds: 25)
        while !FileManager.default.fileExists(atPath: marker) {
            guard !deadline.hasExpired, owner.poll() == .running else { throw Failure.assertion("retention worker did not reach " + phase) }
            usleep(5_000)
        }
        let ready = try JSONDecoder().decode(RetentionWorkerReady.self,
            from: PolicyAuthorityFile.read(path: marker, owner: geteuid(), maximumBytes: 262_144).bytes)
        try require(RunIdentity.isValid(ready.request), "retention worker request id")
        try require(owner.send(SIGKILL), "repository original worker kill")
        let drain = MonotonicDeadline(seconds: 10)
        while true {
            if case .reaped(let status) = owner.reapAfterGroupDrain(streamsDrained: true) {
                try require(status & 0x7f == SIGKILL, "retention worker was not actually killed by SIGKILL"); break
            }
            guard !drain.hasExpired else { throw Failure.assertion("retention worker reap pending") }
            usleep(5_000)
        }
        let location = try StateLocation.isolated(root: fixture.root)
        var final: CustodyJournal?
        var eofWitness: TestingRetentionEOFWitness?
        let witnessSlot = ready.slotPath ?? location.path + "/retention/.incomplete-ret-worker"
        func absent(_ observation: RetentionWorkerObservation) -> Bool {
            var info = proc_bsdinfo(); errno = 0
            let count = proc_pidinfo(Int32(observation.pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            return (count == 0 && errno == ESRCH) || (count == MemoryLayout<proc_bsdinfo>.size
                && (info.pbi_start_tvsec != observation.startSeconds || info.pbi_start_tvusec != observation.startMicroseconds))
        }
        while true {
            if phase.hasSuffix("-resumed"), eofWitness == nil,
               let bytes = try? PolicyAuthorityFile.read(path: witnessSlot + "/" + TestingRetentionEOFWitness.filename,
                   owner: geteuid(), maximumBytes: TestingRetentionEOFWitness.maximumBytes).bytes {
                let witness = try JSONDecoder().decode(TestingRetentionEOFWitness.self, from: bytes)
                try witness.validate()
                try require(try witness.encode() == bytes, "TestingRetentionEOFWitness: noncanonical retention EOF witness")
                try require(witness.request == ready.request && witness.budget == ready.budget
                    && witness.requestSHA256 == ready.requestSHA256 && witness.inputSHA256 == ready.inputSHA256
                    && witness.manifestSHA256 == ready.manifestSHA256 && witness.slot == ready.slotIdentity
                    && witness.control == ready.controlIdentity
                    && witness.worker.processID == owner.identity.processID && witness.worker.userID == owner.identity.userID
                    && witness.worker.startSeconds == owner.identity.startSeconds
                    && witness.worker.startMicroseconds == owner.identity.startMicroseconds
                    && RetentionWorkerObservation(try CustodyProcessObservation(witness.helper)) == ready.helper
                    && RetentionWorkerObservation(try CustodyProcessObservation(witness.graph.original)) == ready.target
                    && witness.output.phase == (phase.hasPrefix("restore") ? "clone-incomplete-checkout" : "bundle-unpublished-intermediate"),
                    "TestingRetentionLiveGraph: retention EOF witness changed original bindings")
                // Executed negatives use the same acceptance decoder: unknown
                // phase, missing ancestry, completed output and wrong schema fail.
                for mutation in ["schema", "ancestry", "phase", "complete"] {
                    var value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    if mutation == "schema" { value["schema"] = "unknown" }
                    else if mutation == "ancestry" {
                        var graph = value["graph"] as! [String: Any]; graph["ancestry"] = []; value["graph"] = graph
                    } else {
                        var output = value["output"] as! [String: Any]
                        if mutation == "phase" { output["phase"] = "unknown" }
                        else if phase.hasPrefix("restore") { output["observedPayloadSize"] = TestingRetentionPayload.bytesPerFile }
                        else { output["finalAbsent"] = false }
                        value["output"] = output
                    }
                    let changed = try JSONDecoder().decode(TestingRetentionEOFWitness.self, from: JSONSerialization.data(withJSONObject: value))
                    var refused = false; do { try changed.validate() } catch { refused = true }
                    try require(refused, "retention EOF witness accepted false evidence")
                }
                eofWitness = witness
            }
            let descendantsGone = eofWitness?.graph.ancestry.allSatisfy { member in
                let i = member.identity
                var info = proc_bsdinfo(); errno = 0
                let n = proc_pidinfo(i.processID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                return (n == 0 && errno == ESRCH) || (n == MemoryLayout<proc_bsdinfo>.size
                    && (UInt64(info.pbi_start_tvsec) != i.startSeconds || UInt64(info.pbi_start_tvusec) != i.startMicroseconds))
            } ?? !phase.hasSuffix("-resumed")
            if let bytes = try? retentionCustodyBytes(location, ready.request + ".json"),
               let journal = try? CustodyJournal.decode(bytes), journal.phase == .terminal,
               absent(ready.helper), absent(ready.target), descendantsGone { final = journal; break }
            guard !drain.hasExpired else { throw Failure.assertion("retention orphan custody pending; evidence retained") }
            usleep(5_000)
        }
        guard let final else { throw Failure.assertion("repository terminal missing") }
        try require(final.kind == .retentionArchive && final.outcome == .cancelledDrained && final.reason == .cancelled
            && final.custodian.map(RetentionWorkerObservation.init) == ready.helper
            && final.target.map(RetentionWorkerObservation.init) == ready.target
            && [final.budget.issued, final.budget.work, final.budget.term, final.budget.kill, final.budget.receipt] == ready.budget,
            "retention worker loss changed transaction or deadlines")
        try require(!FileManager.default.fileExists(atPath: location.path + "/custody/receipts/" + ready.request + ".caller.json"),
            "repository successor fabricated reaping")
        // These are resources created by this exact fixture worker. After both
        // owned worker reap and helper/target convergence, verify every saved
        // identity and exclusive frozen lease before disposing its scratch.
        let directory = open(ready.frozen.frozenDirectoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(directory >= 0, "retention orphan frozen directory")
        defer { close(directory) }
        // Immutable config rejects write-open. Reopen read-only, then retain
        // all existing identity/content/owner/exclusive-lease checks before cleanup.
        let file = openat(directory, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(file >= 0, "retention orphan frozen file")
        defer { close(file) }
        try require(ready.frozen.frozenOwnerPID == owner.identity.processID
            && ready.frozen.frozenDirectoryPath.hasPrefix("/private/tmp/shadow-sync-fixture-config."), "retention fixture resource ownership")
        try RepositoryHandle.validateFrozenConfiguration(descriptor: file, directoryDescriptor: directory, snapshot: ready.frozen)
        try require(flock(file, LOCK_EX | LOCK_NB) == 0, "retention orphan frozen lease still retained")
        try RepositoryHandle.cleanupFrozenConfiguration(descriptor: file, directoryDescriptor: directory, snapshot: ready.frozen)
        let slot = ready.slotPath ?? location.path + "/retention/.incomplete-ret-worker"
        try require(FileManager.default.fileExists(atPath: slot), "interrupted retention slot disappeared")
        if phase.hasPrefix("restore") { try require(FileManager.default.fileExists(atPath: slot + "/branch.bundle"), "recoverable bundle disappeared") }
        if phase.hasSuffix("-resumed") {
            guard let witness = eofWitness else { throw Failure.assertion("post-EOF retention witness absent") }
            try require(witness.releaseSHA256 == final.binding.releaseSHA256 && witness.inputSHA256 == final.inputSHA256,
                "retention witness terminal binding")
            let slotFD = open(slot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(slotFD >= 0, "retention witness slot missing"); defer { close(slotFD) }
            try RetentionArchiveCommandAuthority.validateDirectory(path: slot, identity: witness.slot, retained: slotFD)
            if phase.hasPrefix("restore") {
                let proof = try InheritedRetentionArchiveResources.testingNode(slotFD, ".restore-proof", directory: true)
                let repository = try InheritedRetentionArchiveResources.testingNode(proof.value, "repository", directory: true)
                let git = try InheritedRetentionArchiveResources.testingNode(repository.value, ".git", directory: true)
                let config = try InheritedRetentionArchiveResources.testingNode(git.value, "config")
                try require(try RetentionArchiveCommandAuthority.identity(config.value) == witness.output.node,
                    "retention clone output substituted")
            } else {
                // Git may delete its lock during TERM cleanup or publish it just
                // after the sample. A surviving name must still be that inode.
                for name in ["branch.bundle.lock", "branch.bundle"] {
                    if try !InheritedRetentionArchiveResources.testingAbsent(slotFD, name) {
                        let file = try InheritedRetentionArchiveResources.testingNode(slotFD, name)
                        try require(try RetentionArchiveCommandAuthority.identity(file.value) == witness.output.node,
                            "retention bundle output substituted")
                    }
                }
            }
            let sourceFD = open(fixture.repository, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(sourceFD >= 0, "retention manifest source missing"); defer { close(sourceFD) }
            let retainedManifest = try InheritedRetentionArchiveResources.testingRead(sourceFD, TestingRetentionPayload.manifestName, maximum: 65_536)
            try require(CustodyRecordBinding.digest(retainedManifest) == witness.manifestSHA256, "TestingRetentionPayload: retention manifest changed")
            try testingRetentionScratchBound(fixture.root)
        }
        try fixture.removeAfterRetentionWorker(request: ready.request)
    }


    private static func repositoryFixtureResources(root: String, context: CommandCustodyContext,
        systemPath: String? = nil, effectiveURL: String = "https://github.com/fixture-owner/ready.git")
        throws -> (RepositoryHandle, FrozenGitConfiguration, RepositoryExecutionSnapshot) {
        let account = try EffectiveAccount.isolated(homeDirectory: root + "/home")
        let publisher = try PublisherPolicyResources.testingDiscovery(account: account)
        let policy = try HostPolicySnapshot.load(account: account, contract: QualifiedAWAContract.decode(publisher.contract))
        let original = try RepositoryHandle.testingBoundCandidate(path: account.homeDirectory + "/workspace/products/ready",
            id: "fixture-owner/ready", displayName: "Fixture", rawOrigin: "https://github.com/fixture-owner/ready.git")
        let candidate = RepositoryCandidate(id: original.id, displayName: original.displayName, path: original.path,
            rawOrigin: original.rawOrigin, rootIdentity: original.rootIdentity, gitDirectoryIdentity: original.gitDirectoryIdentity,
            commonDirectoryIdentity: original.commonDirectoryIdentity, configIdentity: original.configIdentity,
            policyAdmissionSHA256: policy.admissionSHA256)
        let handle = try RepositoryHandle.open(candidate)
        let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: CancellationToken(), resolve: { systemPath })
        let frozen = try handle.freezeConfiguration(account: account, retainedConfigurationProbe: probe)
        let snapshot = try handle.executionSnapshot(account: account, frozenConfiguration: frozen,
            admission: GitAdmissionSnapshot(effectiveURL: effectiveURL, transport: .https,
                frozenConfigSHA256: frozen.snapshot.frozenSHA256))
        return (handle, frozen, snapshot)
    }

    private final class CorrectionObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RepositoryCommandObservation] = []
        private var scopes: Set<String> = []
        private weak var context: CommandCustodyContext?
        private var results: [Result<ProcessResult, Error>] = []
        func record(_ event: RepositoryCommandObservation) {
            lock.lock(); events.append(event); lock.unlock()
        }
        func observed(_ context: CommandCustodyContext) {
            lock.lock(); scopes.insert(context.id); self.context = context; lock.unlock()
        }
        var borrowedContext: CommandCustodyContext? { lock.lock(); defer { lock.unlock() }; return context }
        var scopeIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return scopes }
        var admitted: [String] { lock.lock(); defer { lock.unlock() }; return events.filter { $0.phase == .admission }.map(\.requestID) }
        var retired: [String] { lock.lock(); defer { lock.unlock() }; return events.filter { $0.phase == .retired }.map(\.requestID) }
        func append(_ result: Result<ProcessResult, Error>) { lock.lock(); results.append(result); lock.unlock() }
        var outcomes: [Result<ProcessResult, Error>] { lock.lock(); defer { lock.unlock() }; return results }
        func requireOnceOnly() throws {
            let a = admitted, r = retired
            try DiscoveryCallerSelfTestRunner.require(!a.isEmpty && a.count == Set(a).count
                && r.count == Set(r).count && Set(a) == Set(r), "typed lifecycle missing/duplicate retirement")
        }
    }

    private static func runRepositoryGitCorrections(onPass: (String) -> Void) throws {
        let cases = ["nonempty-repeated-read", "nonempty-parallel-config", "observer-refusal", "observer-channel-failure",
            "observer-cancel", "inventory-lifecycle", "pending-inventory", "coordinator-ff", "coordinator-maintenance",
            "coordinator-candidate", "pending-coordinator-ff", "pending-coordinator-maintenance", "pending-coordinator-candidate",
            "finished-resource-retirement", "immutable-name-refusal"]
        for test in cases {
            let id = "REPOSITORY-GIT-" + test
            try RuntimeFixtureSession.withCase(id) {
                if test.contains("coordinator") { try repositoryCoordinatorCorrection(test) }
                else { try repositoryReadCorrection(test) }
            }
            onPass(id)
        }
    }

    private static func drainCorrection(_ observations: CorrectionObservations) throws {
        let registry = RetainedCleanupRegistry.shared
        for id in observations.admitted {
            if let handle = registry.testingRepositoryHandle(id) { registry.testingReleaseDeferredRead(handle) }
        }
        let deadline = MonotonicDeadline(seconds: 12)
        while registry.hasRetainedWork && !deadline.hasExpired { usleep(10_000) }
        try require(!registry.hasRetainedWork && registry.testingCount == 0,
            "correction fixture retains unresolved cleanup; preserve its exact root")
    }

    private static func repositoryReadCorrection(_ test: String) throws {
        let nonempty = test.hasPrefix("nonempty") || test == "immutable-name-refusal"
        let effective = "https://github.com/fixture-owner/ready"
        let user = "[user]\nname = Fixture User\n[url \"\(effective)\"]\ninsteadOf = https://github.com/fixture-owner/ready.git\n[core]\nsshCommand = /usr/bin/false\n"
        let fixture = try Fixture(systemConfiguration: nonempty, userConfiguration: nonempty ? user : nil)
        let observations = CorrectionObservations(), token = CancellationToken()
        var failure: Error?
        do {
            let prepared = try repositoryFixtureResources(root: fixture.root, context: fixture.context,
                systemPath: nonempty ? fixture.home + "/.shadow-sync-fixture/fixture-system-config" : nil,
                effectiveURL: nonempty ? effective : "https://github.com/fixture-owner/ready.git")
            let handle = prepared.0, frozen = prepared.1, snapshot = prepared.2
            if test == "immutable-name-refusal" {
                let directory = frozen.snapshot.frozenDirectoryPath, file = frozen.snapshot.frozenPath
                // None may create a replacement or move the original under its
                // still-held immutable flags, including while another opener lives.
                try require(rename(file, directory + "/replaced") == -1 && errno == EPERM,
                    "immutable config permitted late rename; preserve fixture")
                try require(rename(directory, directory + ".moved") == -1 && errno == EPERM,
                    "immutable directory permitted late rename; preserve fixture")
                try require(unlink(file) == -1 && errno == EPERM,
                    "immutable config permitted late unlink; preserve fixture")
                try require(symlink("/dev/null", directory + "/replacement") == -1 && errno == EPERM,
                    "immutable directory permitted late symlink; preserve fixture")
                try RepositoryHandle.validateFrozenConfiguration(descriptor: frozen.descriptor,
                    directoryDescriptor: frozen.directoryDescriptor, snapshot: frozen.snapshot)
            }
            let progress = RepositoryInventoryProgress(observer: nil)
            let runner = DescriptorProcessRunner(outputLimit: 65_536, repositoryObserver: { event in
                observations.record(event)
                _ = progress.observeRepository(event)
                if event.phase == .admission {
                    if test == "observer-refusal" { return false }
                    if test == "observer-channel-failure" {
                        // The real bounded channel failure contract, without a live user channel.
                        do { try JSONLineChannel.write(["request": event.requestID], descriptor: -1); return true }
                        catch { return false }
                    }
                    if test == "observer-cancel" { token.cancel() }
                }
                return true
            })
            if nonempty {
                try require(frozen.snapshot.frozenSize > 0, "nonempty fixture froze no bytes")
                let args = ["--no-replace-objects", "--no-lazy-fetch", "remote", "get-url", "--all", "origin"]
                if test == "nonempty-parallel-config" {
                    let group = DispatchGroup()
                    for _ in 0..<2 {
                        group.enter()
                        DispatchQueue.global().async {
                            observations.append(Result { try runner.runRepository(arguments: args,
                                context: fixture.context, handle: handle, frozen: frozen, snapshot: snapshot,
                                timeout: 15, cancellation: token) })
                            group.leave()
                        }
                    }
                    group.wait() // Join every caller; each registry wait has its original absolute budget.
                    try require(observations.outcomes.count == 2, "parallel command missing")
                    for outcome in observations.outcomes {
                        let value = try outcome.get()
                        try require(value.succeeded && String(decoding: value.stdout, as: UTF8.self) == effective + "\n",
                            "parallel frozen origin changed")
                    }
                } else {
                    for _ in 0..<2 {
                        let value = try runner.runRepository(arguments: args, context: fixture.context, handle: handle,
                            frozen: frozen, snapshot: snapshot, timeout: 15, cancellation: token)
                        try require(value.succeeded && String(decoding: value.stdout, as: UTF8.self) == effective + "\n",
                            "serial stages consumed frozen config cursor")
                        let transport = try runner.runRepository(arguments: ["--no-replace-objects", "--no-lazy-fetch"]
                            + EffectiveTransportConfiguration.queryArguments, context: fixture.context, handle: handle,
                            frozen: frozen, snapshot: snapshot, timeout: 15, cancellation: token)
                        try require(transport.succeeded && transport.stdout == Data("core.sshcommand\0".utf8),
                            "transport/final config reads lost nonempty frozen input")
                    }
                    // Reopening the same selected named input twice in one consumer
                    // has independent offsets. The real Git cases above cover its parser.
                    let first = open(frozen.snapshot.frozenPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    let second = open(frozen.snapshot.frozenPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    defer { if first >= 0 { close(first) }; if second >= 0 { close(second) } }
                    var left = [UInt8](repeating: 0, count: Int(frozen.snapshot.frozenSize))
                    var right = left
                    try require(first >= 0 && second >= 0 && read(first, &left, left.count) == left.count
                        && read(second, &right, right.count) == right.count && left == right,
                        "named frozen input repeated-open cursor sharing")
                }
            } else if test == "finished-resource-retirement" {
                let command = try fixture.context.prepareRepositoryGit(arguments: ["--no-replace-objects", "--no-lazy-fetch",
                    "rev-parse", "--verify", "HEAD^{commit}"], handle: handle, frozen: frozen, snapshot: snapshot,
                    budget: CustodyBudget.make(kind: .repositoryGit, workSeconds: 15), outputLimit: 65_536, cancellation: token)
                let observer = RepositoryCommandObserver(requestID: command.resources.request.binding.requestID) { event in
                    observations.record(event)
                    return event.phase != .retired || command.resources.testingResourcesRetired
                }
                let requestFD = command.resources.testingRequestDescriptor
                let cwdFD = command.resources.testingWorkingDescriptor
                let controlFD = command.resources.testingControlWriterDescriptor
                let barrier = CustodyLeaseTestingBarrier()
                RetainedCleanupRegistry.shared.testingPauseNextRetirement(barrier)
                defer { barrier.release() }
                let retained = try RetainedCleanupRegistry.shared.start(command, repositoryObserver: observer)
                try require(barrier.waitUntilEntered(), "retirement publication barrier missing")
                try require(retained.snapshot().phase != .finished && !RetainedCleanupRegistry.shared.hasRetainedWork
                    && command.resources.testingResourcesRetired && observations.retired.isEmpty,
                    "retirement publication crossed retained frame/callback barrier")
                for fd in [requestFD, cwdFD, controlFD] {
                    try require(fcntl(fd, F_GETFD) == -1 && errno == EBADF,
                        "registry descriptor still open before retirement notification")
                }
                barrier.release()
                let result = retained.wait()
                try require(result.phase == .finished && result.reason == nil
                    && !RetainedCleanupRegistry.shared.hasRetainedWork && command.resources.testingResourcesRetired,
                    "finished preceded actual registry/resource retirement")
            } else if test == "pending-inventory" || test == "inventory-lifecycle" {
                let probe = SystemGitConfigurationProbe(testingContext: fixture.context, cancellation: token, resolve: { nil })
                let session = RepositoryReadSession(executablePath: CommandLine.arguments[0], leaseDescriptor: -1,
                    account: fixture.account, runner: runner, cancellation: token, progress: progress,
                    transportMapping: nil, configurationProbe: probe)
                if test == "pending-inventory" { RetainedCleanupRegistry.shared.testingDeferNextRepositoryRead() }
                if test == "inventory-lifecycle" {
                    let clone = try session.inspectClone(handle.candidate, category: .writable)
                    try require(clone.originParityVerified && progress.count > 0, "actual inventory omitted typed starts")
                } else {
                    do {
                        _ = try session.inspectClone(handle.candidate, category: .writable)
                        throw Failure.assertion("inventory hid pending")
                    } catch SelectedRepositoryScopeError.cleanupPending {}
                    try require(fixture.context.hasCleanupPending && token.areFutureChildAdmissionsClosed,
                        "inventory did not retain pending cause")
                    do { try session.validatePhaseCompletion(); throw Failure.assertion("completion lost pending") }
                    catch SystemGitConfigurationError.cleanupPending {}
                    do { try probe.withValidatedCompletion { throw Failure.assertion("ordinary error") }; throw Failure.assertion("probe hid pending") }
                    catch SystemGitConfigurationError.cleanupPending {}
                    try require(RetainedCleanupRegistry.shared.hasRetainedWork && observations.retired.isEmpty,
                        "pending inventory fabricated retirement")
                }
            } else {
                do {
                    _ = try runner.runRepository(arguments: ["--no-replace-objects", "--no-lazy-fetch", "rev-parse", "--verify", "HEAD^{commit}"],
                        context: fixture.context, handle: handle, frozen: frozen, snapshot: snapshot, timeout: 15, cancellation: token)
                    throw Failure.assertion("observer refusal admitted a repository command")
                } catch let error as Failure { throw error }
                catch {}
                try require(!RetainedCleanupRegistry.shared.hasRetainedWork && observations.admitted.count == 1,
                    "observer refusal lost retirement")
            }
            try drainCorrection(observations)
            try observations.requireOnceOnly()
            if test != "finished-resource-retirement" {
                try require(progress.count == observations.admitted.count, "inventory counted retirement or missed admission")
            }
        } catch { failure = error }
        try drainCorrection(observations)
        try fixture.remove(expectDiscovery: false, allowUnsubmitted: true)
        if let failure { throw failure }
    }

    private static func correctionTarget(_ candidate: RepositoryCandidate, oid: String, maintenance: Bool) throws -> DefaultBranchUpdateTarget {
        guard let common = candidate.commonDirectoryIdentity, let root = candidate.rootIdentity else {
            throw Failure.assertion("coordinator fixture identities missing")
        }
        let cloneID = LocalClone.id(for: common), worktreeID = "worktree:\(LocalClone.id(for: common)):\(root.device):\(root.inode)"
        let checkedOutRef = maintenance ? "refs/heads/feature" : "refs/heads/main"
        let worktree = try Worktree(id: worktreeID, cloneID: cloneID, path: candidate.path, rootIdentity: root,
            registrationIdentity: nil, attachedBranchRef: checkedOutRef, detachedOID: nil, isPrimary: true,
            locationKind: .canonicalPrimary, verification: .verified, cleanliness: .clean)
        let branch = try Branch(cloneID: cloneID, fullRef: checkedOutRef, tipOID: oid, claimingWorktreeIDs: [worktreeID])
        let clone = try LocalClone(repositoryID: candidate.id, sourceSnapshot: candidate, effectiveOrigin: candidate.rawOrigin,
            originParityVerified: true, policyCategory: .writable, kind: .primaryCheckout,
            worktrees: [worktree], branches: [branch], warnings: [])
        let resolved = try RemoteDefaultBranch(name: "main", advertisedOID: oid)
        let remote = try RemoteRepository(id: candidate.id, origins: [candidate.rawOrigin], policyCategory: .writable,
            resolvedDefault: resolved, defaultUnavailableReason: nil)
        return try DefaultBranchUpdateTarget(repository: remote, canonicalClone: clone, resolvedDefault: resolved,
            expectedLocalOID: maintenance ? nil : oid, expectedFetchedOID: oid,
            mode: maintenance ? .initializeAbsent : .checkedOut, worktreeID: maintenance ? nil : worktreeID,
            relation: DefaultBranchRelation(kind: .equal, aheadCount: 0, behindCount: 0))
    }

    private static func repositoryCoordinatorCorrection(_ test: String) throws {
        let pending = test.hasPrefix("pending"), maintenance = test.hasSuffix("maintenance")
        let fixture = try Fixture(systemConfiguration: false, initialFeatureBranch: maintenance)
        let observations = CorrectionObservations(), audit = CommandAudit(), token = CancellationToken()
        var failure: Error?
        do {
            // Capture disposable identities before ending this read phase. The
            // ordinary coordinator must itself acquire and borrow mutation authority.
            let prepared = try repositoryFixtureResources(root: fixture.root, context: fixture.context)
            let candidate = prepared.0.candidate
            let localRef = maintenance ? "feature" : "main"
            let oid = try String(contentsOfFile: fixture.repository + "/.git/refs/heads/" + localRef, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if maintenance {
                let head = try String(contentsOfFile: fixture.repository + "/.git/HEAD", encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let remote = try String(contentsOfFile: fixture.repository + "/.git/refs/remotes/origin/main", encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try require(head == "ref: refs/heads/feature" && remote == oid
                    && !FileManager.default.fileExists(atPath: fixture.repository + "/.git/refs/heads/main"),
                    "maintenance fixture must have an actual feature primary and absent local main")
            }
            let target = try correctionTarget(candidate, oid: oid, maintenance: maintenance)
            let operation = maintenance ? try PlannedOperation(kind: .initializeDefaultBranch, target: target, maintenanceEvidence: .initializeDefault)
                : PlannedOperation(target: target)
            try require(operation.isSelectable, "coordinator fixture operation not selectable")
            // Frozen resources are lexical/read-only and do not retain this phase's lock.
            fixture.releaseReadPhase()
            var configuration = CoordinatorConfiguration(stateLocation: try StateLocation.isolated(root: fixture.root),
                trampolineExecutable: CommandLine.arguments[0],
                governedRootRole: .testing(policyDigest: fixture.snapshot.admissionSHA256))
            configuration.testingRepositoryCustodyRoot = fixture.root
            configuration.testingRepositoryContextObserved = { observations.observed($0) }
            if pending { RetainedCleanupRegistry.shared.testingDeferNextRepositoryRead() }
            let coordinator = RunCoordinator(configuration: configuration, audit: audit, repositoryObserver: { event in
                observations.record(event)
                // Exercise real local commands; external transport is refused at
                // actual admission, not replaced with synthetic command output.
                guard event.phase == .admission else { return true }
                return audit.invocations.last.map { !$0.arguments.contains("ls-remote") && !$0.arguments.contains("fetch") } ?? false
            }, account: fixture.account)
            let report: RunReport
            if test.hasSuffix("candidate") {
                report = try coordinator.run(runID: RunIdentity.make(), candidates: [candidate], cancellation: token) { _ in }
            } else {
                report = try coordinator.run(runID: RunIdentity.make(), operations: [operation], cancellation: token) { _ in }
            }
            try require(observations.scopeIDs.count == 1 && !observations.admitted.isEmpty,
                "ordinary coordinator omitted its borrowed context/typed caller")
            try require(report.results.count == 1 && !report.results[0].mainUpdated,
                "bounded coordinator fixture unexpectedly mutated")
            if pending {
                try require(report.hasCleanupPending && report.results[0].code == .cleanupPending
                    && report.summary.contains("still pending") && observations.borrowedContext?.hasCleanupPending == true,
                    "coordinator remapped pending to ordinary failure/completion")
                guard let id = observations.admitted.first,
                      let retained = RetainedCleanupRegistry.shared.testingRepositoryHandle(id),
                      let resources = RetainedCleanupRegistry.shared.testingResources(retained) else {
                    throw Failure.assertion("pending coordinator dropped retained command resources")
                }
                try require(retained.snapshot().phase == .cleanupPending && !resources.testingResourcesRetired
                    && observations.retired.isEmpty, "pending coordinator claimed resource retirement")
            } else {
                try require(!report.hasCleanupPending && report.results[0].resultClass != .success
                    && observations.admitted.count >= 2, "coordinator failed before actual repository commands")
            }
            try drainCorrection(observations)
            try observations.requireOnceOnly()
        } catch { failure = error }
        try drainCorrection(observations)
        try fixture.remove(expectDiscovery: false, allowUnsubmitted: true, additionalScopeIDs: observations.scopeIDs)
        if let failure { throw failure }
    }

    private struct RepositoryWorkerObservation: Codable, Equatable {
        let pid: UInt32, group: UInt32, uid: UInt32
        let startSeconds: UInt64, startMicroseconds: UInt64
        let generation: String
        init(_ value: CustodyProcessObservation) {
            pid = value.pid; group = value.group; uid = value.uid
            startSeconds = value.startSeconds; startMicroseconds = value.startMicroseconds; generation = value.generation
        }
    }
    private static func repositoryCustodyBytes(_ location: StateLocation, _ name: String) throws -> Data {
        try PolicyAuthorityFile.read(path: location.path + "/custody/" + name, owner: geteuid(), maximumBytes: 262_144).bytes
    }
    private struct RepositoryWorkerReady: Codable {
        let request: String
        let budget: [UInt64]
        let frozen: GitConfigurationSnapshot
        let helper: RepositoryWorkerObservation
        let target: RepositoryWorkerObservation
    }
    /// A fixed test worker. Only the enclosing test creates this root and its
    /// catalog. The child never initializes unknown state or enrolls tools.
    static func repositoryWorker(root: String, phase: String) -> Int32 {
        do {
            _ = try TestIsolation.validateRoot(root)
            let location = try StateLocation.isolated(root: root)
            let context = try CommandCustodyContext.testing(leases: CustodyAuthorityLeaseSet.retainReadLeases(at: location),
                location: location, root: root, discoveryFixture: true)
            defer { context.close() }
            context.testingRepositoryPausePhase = phase
            let (repository, frozen, snapshot) = try repositoryFixtureResources(root: root, context: context)
            let budget = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 30)
            let command = try context.prepareRepositoryGit(arguments: ["--no-replace-objects", "--no-lazy-fetch",
                "rev-parse", "--verify", "HEAD^{commit}"], handle: repository, frozen: frozen, snapshot: snapshot,
                budget: budget, outputLimit: 65_536, cancellation: CancellationToken())
            let retained = try RetainedCleanupRegistry.shared.start(command)
            defer { retained.cancel() }
            // The closed spawn manifest passes only the pipe's reader to the
            // helper; CLOEXEC keeps this sole writer out of every target.
            let writer = command.resources.testingControlWriterDescriptor
            let writerIdentity = try RetentionArchiveCommandAuthority.identity(writer)
            guard fcntl(writer, F_GETFL) & O_ACCMODE == O_WRONLY
                && fcntl(writer, F_GETFD) & FD_CLOEXEC != 0
                && mode_t(writerIdentity.mode) & S_IFMT == S_IFIFO && writerIdentity.linkCount == 0 else {
                // Keep this fixed failure observable even though the worker's
                // outer catch intentionally discards arbitrary error payloads.
                fputs("retention original exclusive control writer\n", stderr)
                return 91
            }
            let deadline = MonotonicDeadline(seconds: 25)
            let marker = "shadow-sync-fixture-repository-phase:" + phase + "\n"
            while !String(decoding: retained.snapshot().stderr, as: UTF8.self).contains(marker) {
                guard !deadline.hasExpired, retained.snapshot().phase != .finished,
                      retained.snapshot().phase != .cleanupPending else { return 92 }
                usleep(2_000)
            }
            let journal = try CustodyJournal.decode(repositoryCustodyBytes(location, command.resources.request.binding.requestID + ".json"))
            guard let helper = journal.custodian, let target = journal.target else { return 93 }
            let ready = RepositoryWorkerReady(request: journal.binding.requestID,
                budget: [budget.issued, budget.work, budget.term, budget.kill, budget.receipt],
                frozen: frozen.snapshot, helper: RepositoryWorkerObservation(helper), target: RepositoryWorkerObservation(target))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try write(root + "/repository-worker-ready.new", encoder.encode(ready))
            let markerDirectory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard markerDirectory >= 0 else { return 96 }
            defer { close(markerDirectory) }
            let markerFile = openat(markerDirectory, "repository-worker-ready.new", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard markerFile >= 0 else { return 96 }
            defer { close(markerFile) }
            guard fsync(markerFile) == 0,
                  renameatx_np(markerDirectory, "repository-worker-ready.new", markerDirectory, "repository-worker-ready.json", UInt32(RENAME_EXCL)) == 0,
                  fsync(markerDirectory) == 0 else { return 96 }
            let result = retained.wait()
            return result.phase == .finished ? 94 : 95
        } catch { return 91 }
    }
    private static func spawnRepositoryWorker(root: String, phase: String) throws -> (OwnedSpawnAnchor, OwnedDirectChild) {
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        try require(posix_spawn_file_actions_init(&actions) == 0, "repository worker spawn actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try require(posix_spawnattr_init(&attr) == 0, "repository worker spawn attributes")
        defer { posix_spawnattr_destroy(&attr) }
        for fd: Int32 in [0, 1, 2] {
            try require(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0,
                "repository worker null streams")
        }
        var defaults = sigset_t(), empty = sigset_t(); sigemptyset(&defaults); sigemptyset(&empty)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try require(posix_spawnattr_setflags(&attr, flags) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0
            && posix_spawnattr_setsigdefault(&attr, &defaults) == 0 && posix_spawnattr_setsigmask(&attr, &empty) == 0,
            "repository worker closed flags")
        let path = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()).executablePath
        let args = ([path, "--shadow-sync-repository-git-worker-fixture", root, phase] as [String]).map { value in
            value.withCString { strdup($0) }
        }
        var environmentValues = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=/private/tmp"]
        if let namespace = ProcessInfo.processInfo.environment["SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE"] {
            _ = try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.", namespace: namespace)
            environmentValues.append("SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE=" + namespace)
        }
        let environment = environmentValues.map { strdup($0) }
        defer { (args + environment).forEach { free($0) } }
        try require((args + environment).allSatisfy { $0 != nil }, "repository worker argv")
        var argv = args + [nil], env = environment + [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in try env.withUnsafeMutableBufferPointer { ev in
            try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: path,
                actions: &actions, attributes: &attr, arguments: av.baseAddress, environment: ev.baseAddress,
                streamsDrained: { true }, cooperativeStop: {})
        } }
        do {
            let owner = try anchor.transfer(expectedExecutable: path, generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
            return (anchor, owner)
        } catch { RuntimeFixtureSession.drain(anchor); throw error }
    }
    private static func repositoryWorkerLoss(phase: String) throws {
        let fixture = try Fixture(systemConfiguration: false)
        // On failure retain this fixture and its receipts, never erase unknown
        // helper custody. The runtime fixture owner still joins its own worker.
        let (anchor, owner) = try spawnRepositoryWorker(root: fixture.root, phase: phase)
        defer { RuntimeFixtureSession.drain(anchor) }
        try require(owner.send(SIGCONT), "repository worker resume")
        let marker = fixture.root + "/repository-worker-ready.json"
        let deadline = MonotonicDeadline(seconds: 25)
        while !FileManager.default.fileExists(atPath: marker) {
            guard !deadline.hasExpired, owner.poll() == .running else { throw Failure.assertion("repository worker did not reach " + phase) }
            usleep(5_000)
        }
        let ready = try JSONDecoder().decode(RepositoryWorkerReady.self,
            from: PolicyAuthorityFile.read(path: marker, owner: geteuid(), maximumBytes: 262_144).bytes)
        try require(RunIdentity.isValid(ready.request), "repository worker request id")
        try require(owner.send(SIGKILL), "repository original worker kill")
        let drain = MonotonicDeadline(seconds: 10)
        while true {
            if case .reaped(let status) = owner.reapAfterGroupDrain(streamsDrained: true) {
                try require(status & 0x7f == SIGKILL, "repository worker was not actually killed by SIGKILL"); break
            }
            guard !drain.hasExpired else { throw Failure.assertion("repository worker reap pending") }
            usleep(5_000)
        }
        let location = try StateLocation.isolated(root: fixture.root)
        var final: CustodyJournal?
        func absent(_ observation: RepositoryWorkerObservation) -> Bool {
            var info = proc_bsdinfo(); errno = 0
            let count = proc_pidinfo(Int32(observation.pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            return (count == 0 && errno == ESRCH) || (count == MemoryLayout<proc_bsdinfo>.size
                && (info.pbi_start_tvsec != observation.startSeconds || info.pbi_start_tvusec != observation.startMicroseconds))
        }
        while true {
            if let bytes = try? repositoryCustodyBytes(location, ready.request + ".json"),
               let journal = try? CustodyJournal.decode(bytes), journal.phase == .terminal,
               absent(ready.helper), absent(ready.target) { final = journal; break }
            guard !drain.hasExpired else { throw Failure.assertion("repository orphan custody pending; evidence retained") }
            usleep(5_000)
        }
        guard let final else { throw Failure.assertion("repository terminal missing") }
        let observedBudgets = [final.budget.issued, final.budget.work, final.budget.term,
            final.budget.kill, final.budget.receipt]
        let budgetMatchMask = observedBudgets.enumerated().reduce(UInt8(0)) { mask, entry in
            guard entry.offset < ready.budget.count, entry.element == ready.budget[entry.offset] else { return mask }
            return mask | (UInt8(1) << entry.offset)
        }
        DiscoveryFixtureDiagnostic.recordRepositoryWorkerComparison(final,
            helperMatches: final.custodian.map(RepositoryWorkerObservation.init) == ready.helper,
            targetMatches: final.target.map(RepositoryWorkerObservation.init) == ready.target,
            budgetMatchMask: budgetMatchMask, budgetCountMatches: ready.budget.count == observedBudgets.count)
        try require(final.kind == .repositoryGit && final.outcome == .cancelledDrained && final.reason == .cancelled
            && final.custodian.map(RepositoryWorkerObservation.init) == ready.helper
            && final.target.map(RepositoryWorkerObservation.init) == ready.target
            && [final.budget.issued, final.budget.work, final.budget.term, final.budget.kill, final.budget.receipt] == ready.budget,
            "repository worker loss changed transaction or deadlines")
        try require(!FileManager.default.fileExists(atPath: location.path + "/custody/receipts/" + ready.request + ".caller.json"),
            "repository successor fabricated reaping")
        // These are resources created by this exact fixture worker. After both
        // owned worker reap and helper/target convergence, verify every saved
        // identity and exclusive frozen lease before disposing its scratch.
        let directory = open(ready.frozen.frozenDirectoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(directory >= 0, "repository orphan frozen directory")
        defer { close(directory) }
        // Immutable config rejects write-open. Reopen read-only, then retain
        // all existing identity/content/owner/exclusive-lease checks before cleanup.
        let file = openat(directory, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(file >= 0, "repository orphan frozen file")
        defer { close(file) }
        try require(ready.frozen.frozenOwnerPID == owner.identity.processID
            && ready.frozen.frozenDirectoryPath.hasPrefix("/private/tmp/shadow-sync-fixture-config."), "repository fixture resource ownership")
        try RepositoryHandle.validateFrozenConfiguration(descriptor: file, directoryDescriptor: directory, snapshot: ready.frozen)
        try require(flock(file, LOCK_EX | LOCK_NB) == 0, "repository orphan frozen lease still retained")
        try RepositoryHandle.cleanupFrozenConfiguration(descriptor: file, directoryDescriptor: directory, snapshot: ready.frozen)
        try fixture.removeAfterRepositoryWorker(request: ready.request)
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
        let graphs: [[String: Any]] = try [CommandGraphCatalog.Adapter.policyClassify, .systemGitConfig, .discoveryGit, .repositoryGit, .retentionArchive].map { kind in
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

    private final class Fixture: @unchecked Sendable {
        let root: String, home: String, repository: String
        let account: EffectiveAccount
        private var retainedContext: CommandCustodyContext?
        var context: CommandCustodyContext { retainedContext! }
        private let initialScopeID: String
        func releaseReadPhase() { retainedContext?.close(); retainedContext = nil }
        let publisher: PublisherPolicyResources
        let snapshot: HostPolicySnapshot
        let cancellation = CancellationToken()
        fileprivate let directory: Int32
        private let identity: FileIdentity
        private let installationControlBytes: Data
        private let installationReceiptBytes: [String: Data]
        private var removed = false

        private var mutationAuthority: RunAuthority?
        init(systemConfiguration: Bool, userConfiguration: String? = nil, retention: Bool = false,
             initialFeatureBranch: Bool = false) throws {
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
                    try write(home + "/.gitconfig", Data((userConfiguration ?? "[user]\nname = Fixture User\n").utf8))
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
                // Maintenance starts on a real feature primary; no branch deletion
                // or invented missing worktree is needed to model absent main.
                try git(["init", "--quiet", initialFeatureBranch ? "--initial-branch=feature" : "--initial-branch=main", repository])
                // The null graft file remains enforced; silence only its known
                // deprecation advice in this owned fixture before identity capture.
                try git(["-C", repository, "config", "--local", "advice.graftFileDeprecated", "false"])
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
                let installationControlBytes: Data
                let installationReceiptBytes: [String: Data]
                do {
                    let leases = try initialOwner.retainCommandLeases()
                    try CustodyCatalogStore.testingInitialize(leases: leases, root: root)
                    // Rebuild the exact synthetic seed from the held fixture
                    // descriptors. Cleanup must not learn its allowlist from
                    // whatever files happen to be present at disposal time.
                    let state = try leases.duplicateStateDirectory()
                    let binding = try InstallationStateBinding.capture(stateDescriptor: state.0.value, uid: state.1)
                    var harness = try InstallationControlFixtures.Harness(state: binding)
                    try harness.throughReady(); try harness.commitReady()
                    for action in [InstallationAction.cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish] {
                        try harness.pair(action)
                    }
                    try harness.record.validateReceiptChain(harness.receipts)
                    installationControlBytes = try harness.record.encode()
                    installationReceiptBytes = try Dictionary(uniqueKeysWithValues: harness.receipts.map { receipt in
                        (try receipt.filename(uid: state.1), try receipt.encode(uid: state.1))
                    })
                } catch {
                    initialOwner.release()
                    throw error
                }
                initialOwner.release()
                let publisher = try PublisherPolicyResources.testingDiscovery(account: account)
                let mutation = retention ? try RunAuthority.acquireRun(at: location) : nil
                let leases = try mutation?.retainCommandLeases() ?? CustodyAuthorityLeaseSet.retainReadLeases(at: location)
                let context = try CommandCustodyContext.testing(leases: leases,
                    location: location, root: root, authority: mutation, discoveryFixture: true)
                mutationAuthority = mutation
                self.root = root; self.home = home; self.repository = repository; self.identity = identity
                self.directory = directory; self.account = account; self.retainedContext = context; self.initialScopeID = context.id
                self.publisher = publisher; self.snapshot = snapshot
                self.installationControlBytes = installationControlBytes
                self.installationReceiptBytes = installationReceiptBytes
            } catch {
                if directory >= 0 { close(directory) }
                var current = stat()
                try require(lstat(root, &current) == 0 && FileIdentity(current).matchesStableNode(identity),
                    "failed fixture identity changed; retained")
                try FileManager.default.removeItem(atPath: root)
                throw error
            }
        }

        func retentionCase(_ index: Int) throws {
            if index == 2 {
                context.close()
                do { _ = try context.retentionAdmission(cancellation: cancellation); throw Failure.assertion("closed context admitted retention") }
                catch is Failure { throw Failure.assertion("closed context admitted retention") } catch {}
                try require(!FileManager.default.fileExists(atPath: try StateLocation.isolated(root: root).path + "/retention"),
                    "refusal created destination")
                return
            }
            let admission = try context.retentionAdmission(cancellation: cancellation)
            let location = try StateLocation.isolated(root: root)
            let slotPath = location.path + "/retention/.incomplete-ret-fixture"
            try admission.classify(paths: DiscoveryCustodyIntent.repositoryMetadataPaths(repositoryPath: repository) + [slotPath],
                scratch: directory, cancellation: cancellation, budget: CustodyBudget.make(kind: .retentionArchive, workSeconds: 120))
            let original = try RepositoryHandle.testingBoundCandidate(path: repository, id: "fixture-owner/ready",
                displayName: "Fixture", rawOrigin: "https://github.com/fixture-owner/ready.git")
            let candidate = RepositoryCandidate(id: original.id, displayName: original.displayName, path: original.path,
                rawOrigin: original.rawOrigin, rootIdentity: original.rootIdentity, gitDirectoryIdentity: original.gitDirectoryIdentity,
                commonDirectoryIdentity: original.commonDirectoryIdentity, configIdentity: original.configIdentity,
                policyAdmissionSHA256: snapshot.admissionSHA256)
            let handle = try RepositoryHandle.open(candidate)
            let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: cancellation) {
                try DiscoveryFixtureResources.systemConfiguration(home: self.home)
            }
            let frozen = try handle.freezeConfiguration(account: account, retainedConfigurationProbe: probe,
                admitConfiguration: { preflight, budget in
                    try admission.classify(paths: preflight.admissionPaths(account: self.account), scratch: self.directory,
                        cancellation: self.cancellation, budget: budget)
                })
            try require(frozen.snapshot.frozenSize > 0, "nonempty frozen fixture required")
            try FileManager.default.createDirectory(atPath: slotPath + "/.restore-proof", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let slot = open(slotPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let proof = open(slotPath + "/.restore-proof", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(slot >= 0 && proof >= 0, "retention fixture descriptors")
            defer { close(slot); close(proof) }
            // Fixture setup only: actual commands below always use retained custody.
            let tipResult = try ClosedProcessRunner().run(command: ClosedProcessCommand(executable: "/usr/bin/git",
                arguments: ["-C", repository, "rev-parse", "HEAD"]), environment: ClosedProcessRunner.environment(account: account),
                workingDirectoryDescriptor: directory, account: account, timeout: 5, cancellation: cancellation)
            try require(tipResult.succeeded, "fixture tip setup")
            let tip = String(decoding: tipResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            func prepare(_ args: [String], cwd: Int32) throws -> PreparedCustodyCommand {
                // T08 deliberately withholds output until cleanup is pending. Its
                // small status command needs a fixture budget, not the maximum
                // retention work allowance; keep every pending-owner assertion.
                let budget = try CustodyBudget.make(kind: .retentionArchive, workSeconds: index == 7 ? 5 : 120)
                let authority = try RetentionArchiveCommandAuthority(admission: admission, primary: handle, worktree: handle,
                    frozen: frozen, destination: slot, slotPath: slotPath, cwd: cwd, arguments: args,
                    revision: "refs/heads/main", tip: tip, statePath: location.path)
                return try context.prepareRetention(authority, budget: budget, cancellation: cancellation)
            }
            let status = ["-C", repository, "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching"]
            func execute(_ tag: DiscoveryFixtureDiagnostic.RetentionCommand, _ args: [String], cwd: Int32) throws -> CustodyRegistryResult {
                let command = try prepare(args, cwd: cwd)
                let result = try RetainedCleanupRegistry.shared.start(command).wait()
                DiscoveryFixtureDiagnostic.recordRetentionResult(result, command: tag)
                try require(result.phase == .finished && result.journal?.waitStatus == 0 && result.journal?.reason == CustodyReason.none,
                    "retention command failed: \(String(describing: result.journal?.reason))")
                return result
            }
            if index == 0 || index == 1 {
                let first = try execute(.statusFirst, status, cwd: handle.worktreeDescriptor)
                let second = try execute(.statusReplay, status, cwd: handle.worktreeDescriptor)
                try require(first.stdout == second.stdout, "configuration replay changed status")
                let bundle = slotPath + "/branch.bundle", restore = slotPath + "/.restore-proof/repository"
                _ = try execute(.bundleCreate, ["--git-dir", handle.identity.commonDirectoryPath, "bundle", "create", bundle, "refs/heads/main"], cwd: handle.worktreeDescriptor)
                _ = try execute(.bundleVerify, ["--git-dir", handle.identity.commonDirectoryPath, "bundle", "verify", bundle], cwd: handle.worktreeDescriptor)
                _ = try execute(.clone, ["clone", "--no-hardlinks", bundle, restore], cwd: proof)
                let restored = open(restore, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(restored >= 0, "restored fixture root"); defer { close(restored) }
                _ = try execute(.checkout, ["-C", restore, "checkout", "--detach", tip], cwd: restored)
                let observed = try execute(.revision, ["-C", restore, "rev-parse", "--verify", tip + "^{commit}"], cwd: restored)
                try require(String(decoding: observed.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == tip,
                    "retention tip mismatch")
                _ = try execute(.connectivity, ["-C", restore, "fsck", "--connectivity-only", "--no-dangling"], cwd: restored)
                _ = try execute(.restoredStatus, ["-C", restore] + Array(status.dropFirst(2)), cwd: restored)
                return
            }
            if (3...5).contains(index) {
                let command = try prepare(status, cwd: handle.worktreeDescriptor)
                let changed = index == 3 ? repository : index == 4 ? slotPath : home + "/.shadow-sync-fixture/PolicyAdapter.py"
                let saved = changed + ".retention-fixture-saved"
                try FileManager.default.moveItem(atPath: changed, toPath: saved)
                defer { try? FileManager.default.removeItem(atPath: changed); try? FileManager.default.moveItem(atPath: saved, toPath: changed) }
                if index == 5 { try write(changed, Data("raise RuntimeError('fixture replacement')".utf8)) }
                else { try FileManager.default.createDirectory(atPath: changed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                // start reserves an asynchronous owner; its returned handle is
                // not evidence that the replaced resource passed validation.
                let registry = RetainedCleanupRegistry.shared
                let catalogBefore = try repositoryCustodyBytes(location, "catalog.json")
                try require(!registry.hasRetainedWork && registry.testingCount == 0,
                    "replacement fixture requires an empty registry")
                let result = try registry.start(command).wait()
                try require(result.phase == .finished && result.reason == .invalidResource
                    && result.journal == nil && result.stdout.isEmpty && result.stderr.isEmpty && result.trace.isEmpty,
                    "retention resource replacement admitted")
                try require(!registry.hasRetainedWork && registry.testingCount == 0,
                    "refusal submitted a child")
                try require(try context.testingScope.testingRead().entries.isEmpty
                    && repositoryCustodyBytes(location, "catalog.json") == catalogBefore,
                    "replacement refusal changed custody metadata")
                try require(!FileManager.default.fileExists(atPath: location.path + "/custody/"
                    + command.resources.request.binding.requestID + ".json"),
                    "replacement refusal published a journal")
                return
            }
            let registry = RetainedCleanupRegistry.shared
            if index == 7 { registry.testingDeferNextRead(.outputUntilReleased) }
            let command = try prepare(status, cwd: handle.worktreeDescriptor)
            let retained = try registry.start(command)
            if index == 6 { retained.cancel(); registry.testingCloseControl(retained) }
            let output = retained.wait()
            if index == 7 {
                try require(output.phase == .cleanupPending && registry.testingCount > 0,
                    "pending fixture did not retain command")
                context.recordCleanupPending()
                try require(context.hasCleanupPending && FileManager.default.fileExists(atPath: frozen.snapshot.frozenPath)
                    && FileManager.default.fileExists(atPath: slotPath), "pending resources lost")
                registry.testingReleaseDeferredRead(retained)
            } else {
                try require(output.phase == .finished || output.phase == .cleanupPending, "control EOF did not stop command")
            }
            let deadline = MonotonicDeadline(seconds: 10)
            while registry.testingCount != 0 && !deadline.hasExpired { usleep(2_000) }
            try require(registry.testingCount == 0, "retention fixture cleanup unresolved; preserve resources")
        }


        func releaseForRetentionWorker() throws {
            try require(RetainedCleanupRegistry.shared.testingCount == 0 && context.testingScope.testingRead().entries.isEmpty,
                "worker seed already has command work")
            context.close(); retainedContext = nil
            mutationAuthority?.release(); mutationAuthority = nil
        }
        func removeAfterRetentionWorker(request: String) throws {
            guard !removed, retainedContext == nil else { throw Failure.assertion("worker fixture ownership") }
            let location = try StateLocation.isolated(root: root)
            let catalog = try CustodyCatalog.decode(retentionCustodyBytes(location, "catalog.json"))
            try require(catalog.entries.count == 1 && catalog.entries[0].requestID == request,
                "unexpected orphan fixture transaction; retained")
            let journal = try CustodyJournal.decode(retentionCustodyBytes(location, request + ".json"))
            try require(journal.phase == .terminal && journal.kind == .retentionArchive && journal.authority == .mutation,
                "retention orphan not terminal under mutation authority")
            var info = stat()
            try require(lstat(root, &info) == 0 && FileIdentity(info).matchesStableNode(identity), "retention orphan root identity")
            try require(close(directory) == 0, "retention orphan fixture directory close")
            try FileManager.default.removeItem(atPath: root); removed = true
        }

        func session() throws -> PolicyCatalogSession {
            try PolicyCatalogSession(snapshot: snapshot, publisher: publisher, context: context,
                scratchDescriptor: directory, cancellation: cancellation)
        }

        func removeAfterRepositoryWorker(request: String) throws {
            guard !removed else { return }
            let location = try StateLocation.isolated(root: root)
            let catalog = try CustodyCatalog.decode(repositoryCustodyBytes(location, "catalog.json"))
            try require(catalog.entries.count == 1 && catalog.entries[0].requestID == request,
                "unexpected orphan fixture transaction; retained")
            let journal = try CustodyJournal.decode(repositoryCustodyBytes(location, request + ".json"))
            try require(journal.phase == .terminal && journal.kind == .repositoryGit, "orphan not terminal")
            var info = stat()
            try require(lstat(root, &info) == 0 && FileIdentity(info).matchesStableNode(identity), "orphan root identity")
            try require(close(directory) == 0, "orphan fixture directory close")
            try FileManager.default.removeItem(atPath: root)
            removed = true
        }

        func remove(expectDiscovery: Bool, allowUnsubmitted: Bool = false, additionalScopeIDs: Set<String> = []) throws {
            if removed { return }
            retainedContext?.close()
            mutationAuthority?.release(); mutationAuthority = nil
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
            if DiscoveryFixtureDiagnostic.isEnabled {
                // Independent observations only; the original short-circuiting
                // assertion below remains authoritative and unchanged.
                let catalogEmpty = try? CustodyCatalog.decode(repositoryCustodyBytes(
                    StateLocation.isolated(root: root), "catalog.json")).entries.isEmpty
                DiscoveryFixtureDiagnostic.recordFixtureCleanup(
                    registryEmpty: RetainedCleanupRegistry.shared.testingCount == 0,
                    scopeTerminal: retainedContext == nil || retainedContext!.testingScope.observation == .terminal,
                    unsubmittedClosed: allowUnsubmitted && retainedContext?.isClosed == true,
                    catalogEmpty: catalogEmpty)
            }
            try require(RetainedCleanupRegistry.shared.testingCount == 0
                && (retainedContext == nil || retainedContext!.testingScope.observation == .terminal
                    || (allowUnsubmitted && retainedContext!.isClosed))
                && (try CustodyCatalog.decode(repositoryCustodyBytes(StateLocation.isolated(root: root), "catalog.json"))).entries.isEmpty,
                "discovery cleanup unresolved; fixture and transaction evidence retained at \(root)")
            let custody = try StateLocation.isolated(root: root).path + "/custody"
            let control = try PolicyAuthorityFile.read(path: custody + "/" + InstallationControlRecord.filename,
                owner: account.uid, maximumBytes: InstallationControlRecord.maximumBytes)
            try require(control.bytes == installationControlBytes,
                "fixture installation control changed; evidence retained")
            let receipts = custody + "/receipts"
            var discoveryCount = 0
            let names = try FileManager.default.contentsOfDirectory(atPath: receipts)
            var expectedNames = Set<String>()
            for (name, bytes) in installationReceiptBytes {
                let file = try PolicyAuthorityFile.read(path: receipts + "/" + name,
                    owner: account.uid, maximumBytes: InstallationStepReceipt.maximumBytes)
                try require(file.bytes == bytes, "fixture installation receipt binding; evidence retained")
                expectedNames.insert(name)
            }
            let journalNames = names.filter {
                installationReceiptBytes[$0] == nil
                    && !$0.hasSuffix(".caller.json") && !$0.hasPrefix("discovery-resource-")
            }
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
                try require(journal.phase == .terminal && (journal.binding.scopeID == initialScopeID || additionalScopeIDs.contains(journal.binding.scopeID))
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
