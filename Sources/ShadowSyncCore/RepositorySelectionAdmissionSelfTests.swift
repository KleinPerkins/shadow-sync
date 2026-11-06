#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import ShadowSyncCatalog

public enum RepositorySelectionAdmissionSelfTestRunner {
    private enum Failure: Error { case assertion(String) }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[RepositorySelectionAdmissionPath]] = []
        private var validations = 0
        func add(_ paths: [RepositorySelectionAdmissionPath]) { lock.lock(); defer { lock.unlock() }; batches.append(paths) }
        func all() -> [[RepositorySelectionAdmissionPath]] { lock.lock(); defer { lock.unlock() }; return batches }
        func nextValidation() -> Int { lock.lock(); defer { lock.unlock() }; validations += 1; return validations }
    }
    public static func runAll(onPass: (String) -> Void) throws {
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T01-absent-authority-and-invalid-batch-refuse") {
            let a = try RepositorySelectionAdmissionPath(root: "fixture", components: ["a"])
            let b = try RepositorySelectionAdmissionPath(root: "fixture", components: ["b"])
            func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 750_000_000 }
            try refuses { _ = try RepositorySelectionPathAdmission.unavailable.classify([a], deadline: deadline()) }
            for invalid in ["", ".", "..", "slash/name", "back\\name", "null\0name", "line\nname"] {
                try refuses { _ = try RepositorySelectionAdmissionPath(root: "fixture", components: [invalid]) }
            }
            try refuses { _ = try RepositorySelectionPathAdmission.testingAllowAll.classify([], deadline: deadline()) }
            try refuses { _ = try RepositorySelectionPathAdmission.testingAllowAll.classify(Array(repeating: a, count: 65), deadline: deadline()) }
        }
        onPass("POLICY-CATALOG-T01-absent-authority-and-invalid-batch-refuse")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T02-exact-ordered-byte-response-binding") {
            let a = try RepositorySelectionAdmissionPath(root: "fixture", components: ["a"])
            let b = try RepositorySelectionAdmissionPath(root: "fixture", components: ["b"])
            func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 750_000_000 }
            for response in [[], [a], [a,b,a], [b,a]] as [[RepositorySelectionAdmissionPath]] {
                let gate = RepositorySelectionPathAdmission(evaluate: { _, _ in response.map {
                    RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed)
                } }, revalidate: {})
                try refuses { _ = try gate.classify([a,b], deadline: deadline()) }
            }
            let composed = try RepositorySelectionAdmissionPath(root: "fixture", components: ["caf\u{e9}"])
            let decomposed = try RepositorySelectionAdmissionPath(root: "fixture", components: ["cafe\u{301}"])
            let unicode = RepositorySelectionPathAdmission(evaluate: { _, _ in [
                RepositorySelectionAdmissionDecision(path: decomposed, disposition: .allowed)
            ] }, revalidate: {})
            try refuses { _ = try unicode.classify([composed], deadline: deadline()) }
        }
        onPass("POLICY-CATALOG-T02-exact-ordered-byte-response-binding")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T03-stale-authority-and-expired-deadlines-refuse") {
            let a = try RepositorySelectionAdmissionPath(root: "fixture", components: ["a"])
            let b = try RepositorySelectionAdmissionPath(root: "fixture", components: ["b"])
            func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 750_000_000 }
            let staleCalls = Calls()
            let stale = RepositorySelectionPathAdmission(evaluate: { paths, _ in paths.map {
                RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed)
            } }, revalidate: {
                if staleCalls.nextValidation() > 1 { throw RepositorySelectionAdmissionError.unavailable }
            })
            try refuses { _ = try stale.classify([a], deadline: deadline()) }
            let slowCalls = Calls()
            let slow = RepositorySelectionPathAdmission(evaluate: { paths, _ in
                slowCalls.add(paths); usleep(20_000)
                return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
            }, revalidate: {})
            try refuses { _ = try slow.classify([a], deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000) }
            try require(slowCalls.all().count == 1, "slow classifier did not run")
            try refuses { _ = try slow.classify([a], deadline: 0) }
            try require(slowCalls.all().count == 1, "expired deadline admitted helper")
        }
        onPass("POLICY-CATALOG-T03-stale-authority-and-expired-deadlines-refuse")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T04-root-and-binder-refuse-before-open") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let absent = try fixture.catalog(admission: .unavailable)
            try require(absent.degradedReason == .policyUnavailable && absent.catalog.counters.directoriesOpened == 0,
                        "absent authority accessed root")
            let binder = SelectedRepositoryScopeBinder(governedRootPath: fixture.path + "/does-not-exist", logicalRoot: "fixture")
            do { _ = try binder.processFreeCatalog(preferences: nil, generation: 1); throw Failure.assertion("binder accepted absent authority") }
            catch SelectedRepositoryScopeError.policyUnavailable {}
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T04-root-and-binder-refuse-before-open")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T05-protected-child-visible-without-metadata") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let calls = Calls()
            let denied = gate(calls: calls) { $0.components.last == "blocked" }
            let result = try fixture.catalog(admission: denied)
            let protected = result.catalog.candidates.filter { $0.section == .protected }
            try require(result.isComplete && protected.count == 1 && protected[0].displayLabel == "blocked"
                        && protected[0].catalogRepositoryIdentity == nil && protected[0].advisoryOrigin == nil
                        && !protected[0].isEligible && !protected[0].isDefaultSelected,
                        "protected row acquired metadata or selection")
            try require(result.catalog.counters.directoriesOpened == 2 && result.catalog.counters.filesOpened == 0,
                        "denied candidate opened")
            try require(calls.all().map { $0.map(\.components) } == [[[]], [[".git"]], [["shelf"]], [["shelf", ".git"]], [["shelf", "blocked"]]],
                        "root/shelf/child classification order changed")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T05-protected-child-visible-without-metadata")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T06-protected-intermediate-stops-traversal") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let shelfCalls = Calls()
            let shelfDenied = try fixture.catalog(admission: gate(calls: shelfCalls) { $0.components == ["shelf"] })
            try require(shelfDenied.isComplete && shelfDenied.catalog.counters.directoriesOpened == 1
                        && shelfDenied.catalog.counters.directoryEntries == 0
                        && shelfDenied.catalog.candidates.map(\.displayLabel) == ["shelf"],
                        "protected shelf enumerated")
            try require(shelfCalls.all().flatMap { $0 }.allSatisfy { $0.components.count <= 1 },
                        "descendants admitted below denied shelf")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T06-protected-intermediate-stops-traversal")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T07-invalid-batch-produces-incomplete-catalog") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let failedCalls = Calls()
            let failed = RepositorySelectionPathAdmission(evaluate: { paths, _ in
                failedCalls.add(paths)
                if paths.contains(where: { $0.components.count == 2 && $0.components.last != ".git" }) { return [] }
                return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
            }, revalidate: {})
            let incomplete = try fixture.catalog(admission: failed)
            try require(incomplete.degradedReason == .policyUnavailable && incomplete.catalog.counters.directoriesOpened == 2
                        && incomplete.catalog.candidates.isEmpty, "malformed batch accessed candidates")
            try require(failedCalls.all().contains(where: { $0.contains(where: {
                $0.components.count == 2 && $0.components.last != ".git"
            }) }), "malformed candidate batch never evaluated")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T07-invalid-batch-produces-incomplete-catalog")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T08-complete-bounded-batches-with-no-candidate-opens") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            for index in 0..<130 { try fixture.directory("shelf/repository-\(index)") }
            let batchCalls = Calls()
            let many = try fixture.catalog(admission: gate(calls: batchCalls) { $0.components.count == 2 && $0.components.last != ".git" })
            let batches = batchCalls.all().filter { $0.first?.components.count == 2 && $0.first?.components.last != ".git" }
            try require(many.isComplete && many.catalog.candidates.count == 131
                        && batches.map(\.count) == [64,64,3]
                        && many.catalog.counters.directoriesOpened == 2,
                        "catalog classification batching or protection changed")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T08-complete-bounded-batches-with-no-candidate-opens")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T09-revocation-prevents-batch-consumption") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            for index in 0..<130 { try fixture.directory("shelf/repository-\(index)") }
            // A revocation observed immediately after a batch prevents consumption.
            let revocations = Calls()
            let revoked = RepositorySelectionPathAdmission(evaluate: { paths, _ in
                revocations.add(paths)
                return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: .allowed) }
            }, revalidate: {
                if revocations.all().contains(where: { $0.first?.components.count == 2 && $0.first?.components.last != ".git" }) {
                    throw RepositorySelectionAdmissionError.unavailable
                }
            })
            let revokedResult = try fixture.catalog(admission: revoked)
            try require(revokedResult.degradedReason == .policyUnavailable
                        && revokedResult.catalog.counters.directoriesOpened == 2, "revoked batch accessed candidate")
            try require(revocations.all().contains(where: {
                $0.count == 64 && $0.first?.components.count == 2 && $0.first?.components.last != ".git"
            }), "revoked candidate batch never evaluated")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T09-revocation-prevents-batch-consumption")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T10-admitted-byte-identity-survives-selection-and-persistence") {
            let a = try RepositorySelectionAdmissionPath(root: "fixture", components: ["a"])
            let b = try RepositorySelectionAdmissionPath(root: "fixture", components: ["b"])
            func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 750_000_000 }
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            for index in 0..<130 { try fixture.directory("shelf/repository-\(index)") }
            let rawName = "cafe\u{301}"
            let normalizedName = "caf\u{e9}"
            try fixture.directory("shelf/" + rawName + "/.git/refs/remotes/origin")
            let git = fixture.path + "/shelf/" + rawName + "/.git/"
            try Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/unicode.git\n".utf8)
                .write(to: URL(fileURLWithPath: git + "config"))
            try Data("ref: refs/remotes/origin/main\n".utf8)
                .write(to: URL(fileURLWithPath: git + "refs/remotes/origin/HEAD"))
            let unicodeCalls = Calls()
            let unicodeGate = gate(calls: unicodeCalls) {
                $0.components.last?.utf8.elementsEqual(normalizedName.utf8) == true
            }
            let unicodeResult = try fixture.catalog(admission: unicodeGate)
            guard let row = unicodeResult.catalog.candidates.first(where: { $0.id == "fixture-owner/unicode" }) else {
                throw Failure.assertion("unicode fixture missing")
            }
            try require(unicodeResult.isComplete && row.isEligible
                        && row.locator.components.last!.utf8.elementsEqual(rawName.utf8), "catalog rewrote admitted locator")
            let roundtrip = try JSONDecoder().decode(RepositorySelectionLocator.self,
                from: JSONEncoder().encode(row.locator))
            let normalizedLocator = try RepositorySelectionLocator(governedRoot: "fixture", components: ["shelf", normalizedName])
            try require(roundtrip.components.last!.utf8.elementsEqual(rawName.utf8)
                        && roundtrip != normalizedLocator && Set([roundtrip, normalizedLocator]).count == 2,
                        "locator persistence or hashing collapsed byte identities")
            try require((roundtrip < normalizedLocator) != (normalizedLocator < roundtrip), "byte order not total")
            try unicodeGate.requireAllowed(RepositorySelectionAdmissionPath(
                root: roundtrip.governedRoot, components: roundtrip.components), deadline: deadline())
            try refuses { try unicodeGate.requireAllowed(RepositorySelectionAdmissionPath(
                root: normalizedLocator.governedRoot, components: normalizedLocator.components), deadline: deadline()) }
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T10-admitted-byte-identity-survives-selection-and-persistence")

        func metadataFixture() throws -> Fixture {
            let fixture = try Fixture()
            do {
                try fixture.directory("shelf/ready/.git/refs/remotes/origin")
                let git = fixture.path + "/shelf/ready/.git/"
                try Data("[remote \"origin\"]\nurl = https://github.com/fixture-owner/ready.git\n".utf8)
                    .write(to: URL(fileURLWithPath: git + "config"))
                try Data("ref: refs/remotes/origin/main\n".utf8)
                    .write(to: URL(fileURLWithPath: git + "refs/remotes/origin/HEAD"))
                return fixture
            } catch { try? fixture.remove(); throw error }
        }
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T11-metadata-leaves-and-ancestors-denied-before-files") {
            for suffix in [[".git"], [".git", "config"], [".git", "refs"], [".git", "refs", "remotes"],
                           [".git", "refs", "remotes", "origin"], [".git", "refs", "remotes", "origin", "HEAD"]] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let calls = Calls(), denied = ["shelf", "ready"] + suffix
                let result = try fixture.catalog(admission: gate(calls: calls) { $0.components == denied })
                let rows = result.catalog.candidates.filter { $0.locator.components == ["shelf", "ready"] }
                try require(result.isComplete && rows.count == 1 && rows[0].section == .protected
                            && !rows[0].isEligible && rows[0].advisoryOrigin == nil
                            && rows[0].catalogRepositoryIdentity == nil && result.catalog.counters.filesOpened == 0,
                            "denied metadata consumed or misplaced protected row")
                try require(calls.all().flatMap { $0 }.contains(where: { $0.components == denied }), "metadata denial not evaluated")
                try fixture.remove()
            }
        }
        onPass("POLICY-CATALOG-T11-metadata-leaves-and-ancestors-denied-before-files")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T12-remote-head-intermediate-aliases-refuse") {
            for alias in ["refs", "refs/remotes", "refs/remotes/origin"] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let baseline = try fixture.catalog(admission: .testingAllowAll)
                try require(baseline.isComplete && baseline.catalog.candidates.contains(where: { $0.id == "fixture-owner/ready" && $0.isEligible }), "metadata alias positive control")
                let tail = String("refs/remotes/origin/HEAD".dropFirst(alias.count + 1))
                let target = fixture.path + "/target", link = fixture.path + "/shelf/ready/.git/" + alias
                let marker = target + "/" + tail, bytes = Data("ref: refs/remotes/origin/main\n".utf8)
                try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: marker).deletingLastPathComponent().path,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try bytes.write(to: URL(fileURLWithPath: marker))
                try require(rename(link, fixture.path + "/saved") == 0 && symlink(target, link) == 0, "catalog alias fixture")
                let result = try fixture.catalog(admission: .testingAllowAll)
                let rows = result.catalog.candidates.filter { $0.id == "fixture-owner/ready" }
                try require(result.isComplete && rows.count == 1 && !rows[0].isEligible
                            && rows[0].disabledReason == "Remote-default metadata is unavailable."
                            && result.catalog.counters.filesOpened == 1, "catalog traversed intermediate alias")
                try require(try Data(contentsOf: URL(fileURLWithPath: marker)) == bytes, "alias target changed")
                try fixture.remove()
            }
        }
        onPass("POLICY-CATALOG-T12-remote-head-intermediate-aliases-refuse")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T13-metadata-fifos-refuse-without-writers") {
            for leaf in ["config", "refs/remotes/origin/HEAD"] {
                let fixture = try metadataFixture(); defer { try? fixture.remove() }
                let path = fixture.path + "/shelf/ready/.git/" + leaf
                try require(unlink(path) == 0 && mkfifo(path, 0o600) == 0, "catalog FIFO fixture")
                // No writer exists: a blocking open cannot reach these assertions.
                let result = try fixture.catalog(admission: .testingAllowAll)
                try require(!result.catalog.candidates.contains(where: { $0.isEligible }), "catalog FIFO became eligible")
                if leaf == "config" { try require(result.degradedReason == .unsafeEntry, "config FIFO wrong refusal") }
                else { try require(result.isComplete && result.catalog.candidates.contains(where: {
                    $0.id == "fixture-owner/ready" && $0.disabledReason == "Remote-default metadata is unavailable."
                }), "remote HEAD FIFO wrong refusal") }
                var info = stat()
                try require(lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO, "FIFO fixture changed")
                try fixture.remove()
            }
        }
        onPass("POLICY-CATALOG-T13-metadata-fifos-refuse-without-writers")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T14-metadata-positive-roster-and-budget") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            let calls = Calls(), result = try fixture.catalog(admission: gate(calls: calls) { _ in false })
            let git = fixture.path + "/shelf/ready/.git/"
            let configBytes = try Data(contentsOf: URL(fileURLWithPath: git + "config")).count
            let headBytes = try Data(contentsOf: URL(fileURLWithPath: git + "refs/remotes/origin/HEAD")).count
            try require(result.isComplete && result.catalog.candidates.contains(where: { $0.id == "fixture-owner/ready" && $0.isEligible })
                        && result.catalog.counters.filesOpened == 2 && result.catalog.counters.aggregateBytes == configBytes + headBytes,
                        "positive catalog or metadata budget omitted")
            let observed = calls.all().flatMap { $0 }.map(\.components)
            for suffix in [[".git"], [".git", "config"], [".git", "refs"], [".git", "refs", "remotes"],
                           [".git", "refs", "remotes", "origin"], [".git", "refs", "remotes", "origin", "HEAD"]] {
                try require(observed.contains(["shelf", "ready"] + suffix), "metadata admission roster incomplete")
            }
            let oneFile = try fixture.catalog(admission: .testingAllowAll,
                limits: RepositorySelectionCatalogLimits(filesOpened: 1))
            try require(oneFile.degradedReason == .fileOpenLimit && oneFile.catalog.counters.filesOpened == 2
                        && !oneFile.catalog.candidates.contains(where: { $0.isEligible }), "remote HEAD escaped file limit")
            let configOnly = try fixture.catalog(admission: .testingAllowAll,
                limits: RepositorySelectionCatalogLimits(aggregateBytes: configBytes))
            try require(configOnly.degradedReason == .aggregateByteLimit
                        && configOnly.catalog.counters.aggregateBytes == configBytes
                        && !configOnly.catalog.candidates.contains(where: { $0.isEligible }), "remote HEAD escaped byte limit")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T14-metadata-positive-roster-and-budget")
        try RuntimeFixtureSession.withCase("POLICY-CATALOG-T15-traversal-anchor-is-not-repository") {
            let fixture = try metadataFixture(); defer { try? fixture.remove() }
            try fixture.directory(".git")
            let fifo = fixture.path + "/.git/config"
            try require(mkfifo(fifo, 0o600) == 0, "anchor FIFO fixture")
            let calls = Calls()
            let result = try fixture.catalog(admission: gate(calls: calls) { $0.components.first == ".git" },
                                             inspectRootRepository: false)
            try require(result.isComplete && result.catalog.candidates.contains(where: {
                $0.id == "fixture-owner/ready" && $0.isEligible
            }) && !result.catalog.candidates.contains(where: { $0.locator.components.isEmpty }),
                        "traversal anchor inspected as repository")
            try require(!calls.all().flatMap { $0 }.contains(where: { $0.components.first == ".git" }),
                        "anchor metadata admission requested outside projection")
            var info = stat()
            try require(lstat(fifo, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO, "anchor fixture changed")
            try fixture.remove()
        }
        onPass("POLICY-CATALOG-T15-traversal-anchor-is-not-repository")
    }

    private static func gate(calls: Calls, denied: @escaping @Sendable (RepositorySelectionAdmissionPath) -> Bool)
        -> RepositorySelectionPathAdmission {
        RepositorySelectionPathAdmission(evaluate: { paths, _ in
            calls.add(paths)
            return paths.map { RepositorySelectionAdmissionDecision(path: $0, disposition: denied($0) ? .protected : .allowed) }
        }, revalidate: {})
    }
    private static func require(_ condition: Bool, _ text: String) throws { if !condition { throw Failure.assertion(text) } }
    private static func refuses(_ body: () throws -> Void) throws {
        do { try body(); throw Failure.assertion("unsafe admission accepted") }
        catch RepositorySelectionAdmissionError.unavailable {}
    }
    private final class Fixture {
        let path: String
        let descriptor: Int32
        let identity: RepositorySelectionCatalogIdentity
        private var removed = false
        init() throws {
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-catalog-admission-") + "XXXXXX").utf8CString)
            guard let result = mkdtemp(&template) else { throw Failure.assertion("fixture creation") }
            path = String(cString: result)
            descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var info = stat()
            guard descriptor >= 0, fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw Failure.assertion("fixture identity")
            }
            identity = RepositorySelectionCatalogIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), owner: UInt32(info.st_uid))
            try directory("shelf/blocked")
        }
        func directory(_ relative: String) throws {
            try FileManager.default.createDirectory(atPath: path + "/" + relative,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        func catalog(admission: RepositorySelectionPathAdmission,
                     limits: RepositorySelectionCatalogLimits = RepositorySelectionCatalogLimits(),
                     inspectRootRepository: Bool = true) throws -> RepositorySelectionCatalogResult {
            let root = try RepositorySelectionCatalogRoot(logicalKey: "fixture", descriptor: descriptor, identity: identity)
            let policy = try RepositorySelectionPolicy(shelfPaths: [["shelf"]], excludedPaths: [], readOnlyPaths: [],
                artifactPaths: [], permanentNoTouchRepositoryIDs: [], digest: String(repeating: "0", count: 64))
            return RepositorySelectionCatalogDiscovery.discoverCatalog(configuration: RepositorySelectionCatalogConfiguration(
                roots: [root], policy: policy, preferences: nil, generation: 1, limits: limits, admission: admission, inspectRootRepository: inspectRootRepository))
        }
        func remove() throws {
            if removed { return }
            var info = stat()
            guard lstat(path, &info) == 0, UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode,
                  info.st_uid == geteuid() else { throw Failure.assertion("cleanup identity changed") }
            close(descriptor)
            try FileManager.default.removeItem(atPath: path)
            removed = true
        }
    }
}
#endif
