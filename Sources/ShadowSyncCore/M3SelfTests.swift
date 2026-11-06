#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

private final class M3EligibilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public enum M3SelfTestRunner {
    public static func runPractical(
        testExecutable: String,
        onPass: (String) -> Void = { _ in }
    ) throws -> [String] {
        let tests: [(String, () throws -> Void)] = [
            ("m3-practical-primary-main-with-dirty-feature-worktree", {
                try testPrimaryMainWithDirtyFeatureWorktree(
                    executable: testExecutable
                )
            }),
            ("m3-practical-lock-config-ref-and-topology-drift", {
                try testPracticalDriftRefusals(executable: testExecutable)
            }),
            ("m3-practical-detached-head-precision", {
                try testPracticalDetachedPrecision(
                    executable: testExecutable
                )
            }),
        ]
        var completed: [String] = []
        for (name, test) in tests {
            let descriptorBaseline = openDescriptorCount()
            do {
                try RuntimeFixtureSession.withCase(name) {
                    try test()
                    let descriptorCount = openDescriptorCount()
                    try check(
                        descriptorCount == descriptorBaseline,
                        "\(name) leaked \(descriptorCount - descriptorBaseline) descriptors"
                    )
                }
                completed.append(name)
                onPass(name)
            } catch {
                throw M3SelfTestError.testFailed(name, String(describing: error))
            }
        }
        return completed
    }

    public static func runAll(
        testExecutable: String,
        onPass: (String) -> Void = { _ in }
    ) throws -> [String] {
        let tests: [(String, () throws -> Void)] = [
            ("m3-relationship-state-matrix", {
                try testRelationshipStateMatrix(executable: testExecutable)
            }),
            ("m3-prefetch-refusal-matrix", {
                try testPrefetchRefusalMatrix(executable: testExecutable)
            }),
            ("m3-non-main-linked-prefetch-refusal", {
                try testNonMainAndLinkedPrefetchRefusal(
                    executable: testExecutable
                )
            }),
            ("m3-practical-primary-main-with-dirty-feature-worktree", {
                try testPrimaryMainWithDirtyFeatureWorktree(
                    executable: testExecutable
                )
            }),
            ("m3-practical-lock-config-ref-and-topology-drift", {
                try testPracticalDriftRefusals(executable: testExecutable)
            }),
            ("m3-practical-detached-head-precision", {
                try testPracticalDetachedPrecision(
                    executable: testExecutable
                )
            }),
            ("m3-residue-hook-and-runtime-policy", {
                try testResidueHookAndRuntimePolicy(executable: testExecutable)
            }),
            ("m3-update-failure-poststates", {
                try testUpdateFailurePoststates(executable: testExecutable)
            }),
            ("m3-fetch-failure-continuation-authentication", {
                try testFetchFailureContinuation(executable: testExecutable,
                    marker: GitCommandPolicy.syntheticFetchAuthenticationMarker,
                    code: .failedFetchAuthentication, reason: .authentication)
            }),
            ("m3-fetch-failure-continuation-dns", {
                try testFetchFailureContinuation(executable: testExecutable,
                    marker: GitCommandPolicy.syntheticFetchDNSMarker,
                    code: .failedFetchNetwork, reason: .dns)
            }),
            ("m3-fetch-failure-continuation-transport", {
                try testFetchFailureContinuation(executable: testExecutable,
                    marker: GitCommandPolicy.syntheticFetchTransportMarker,
                    code: .failedFetchNetwork, reason: .transport)
            }),
            ("m3-fetch-failure-continuation-timeout", {
                try testFetchFailureContinuation(executable: testExecutable,
                    marker: GitCommandPolicy.syntheticFetchTimeoutMarker,
                    code: .failedFetchNetwork, reason: .timeout)
            }),
            ("m3-fetch-failure-continuation-other", {
                try testFetchFailureContinuation(executable: testExecutable,
                    marker: GitCommandPolicy.syntheticFetchOtherMarker,
                    code: .failedFetch, reason: .other)
            }),
            ("m3-fetch-failure-classifier-precedence", {
                try testFetchFailureClassifierPrecedence()
            }),
            ("m3-command-and-time-contract", {
                try testCommandAndTimeContract(executable: testExecutable)
            }),
        ]
        var completed: [String] = []
        for (name, test) in tests {
            let descriptorBaseline = openDescriptorCount()
            do {
                try RuntimeFixtureSession.withCase(name) {
                    try test()
                    let descriptorCount = openDescriptorCount()
                    try check(
                        descriptorCount == descriptorBaseline,
                        "\(name) leaked \(descriptorCount - descriptorBaseline) descriptors"
                    )
                }
                completed.append(name)
                onPass(name)
            } catch {
                throw M3SelfTestError.testFailed(name, String(describing: error))
            }
        }
        return completed
    }

    private static func openDescriptorCount() -> Int {
        (0..<Int32(getdtablesize())).reduce(into: 0) { count, descriptor in
            if fcntl(descriptor, F_GETFD) >= 0 {
                count += 1
            }
        }
    }

    private static func testRelationshipStateMatrix(executable: String) throws {
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let result = try execute(fixture, executable: executable).result
            try check(
                result.code == .alreadyCurrent,
                "equal state was \(result.code): \(result.technicalDetail ?? "")"
            )
            try check(result.fetched && !result.mainUpdated, "equal fetch/update flags are wrong")
            try check(result.beforeCommit == result.targetCommit, "equal target was not captured")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let before = try oid(fixture, "HEAD")
            let target = try commit(fixture, name: "behind-target")
            try fixture.git(["push", fixture.remotePath, "main:main"])
            try fixture.git(["reset", "--hard", before])
            let execution = try execute(fixture, executable: executable)
            try check(execution.result.code == .updated, "behind state did not update")
            try check(execution.result.targetCommit == target, "behind target was not frozen")
            try check(execution.result.afterCommit == target, "behind state reached wrong commit")
            try check(
                execution.result.remoteTrackingAfterCommit == target,
                "behind remote-tracking result was not recorded"
            )
            let observed = try oid(fixture, "HEAD")
            try check(observed == target, "behind fixture HEAD is wrong")
            try assertClosedCommandSet(execution.audit)
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            _ = try commit(fixture, name: "local-ahead")
            let result = try execute(fixture, executable: executable).result
            try check(result.code == .skippedAhead, "ahead state was \(result.code)")
            try check(!result.mainUpdated, "ahead state mutated main")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let base = try oid(fixture, "HEAD")
            let local = try commit(fixture, name: "local-side")
            try fixture.git(["reset", "--hard", base])
            _ = try commit(fixture, name: "remote-side")
            try fixture.git(["push", fixture.remotePath, "main:main"])
            try fixture.git(["reset", "--hard", local])
            let result = try execute(fixture, executable: executable).result
            try check(result.code == .skippedDiverged, "diverged state was \(result.code)")
            let observed = try oid(fixture, "HEAD")
            try check(observed == local, "diverged state changed local main")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let result = try execute(fixture, executable: executable).result
            try check(
                result.code == .skippedRemoteMainMissing,
                "missing remote main was \(result.code): \(result.technicalDetail ?? "")"
            )
            try check(!result.fetched && !result.mainUpdated, "missing remote flags are wrong")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["checkout", "--quiet", "-b", "feature"])
            try fixture.git(["branch", "-D", "main"])
            let refreshed = try RepositoryHandle.fixedCandidate(
                path: fixture.repositoryPath
            )
            let execution = try execute(
                fixture,
                executable: executable,
                candidate: refreshed
            )
            try check(
                execution.result.code == .skippedLocalMainMissing,
                "missing local main was \(execution.result.code)"
            )
            try check(!containsCommand(execution.audit, "fetch"), "missing local main fetched")
        }
    }

    private static func testPrefetchRefusalMatrix(executable: String) throws {
        enum UnsafeState {
            case dirty
            case busy
            case detached
            case hidden
            case replacement
            case graft
        }
        let cases: [(UnsafeState, ResultCode)] = [
            (.dirty, .skippedDirty),
            (.busy, .skippedBusy),
            (.detached, .skippedDetachedHead),
            (.hidden, .skippedHiddenIndexState),
            (.replacement, .failedInspection),
            (.graft, .failedInspection),
        ]
        for (state, expected) in cases {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            switch state {
            case .dirty:
                try Data("dirty\n".utf8).write(
                    to: URL(fileURLWithPath: fixture.repositoryPath)
                        .appendingPathComponent("dirty.txt")
                )
            case .busy:
                try Data().write(
                    to: URL(fileURLWithPath: fixture.repositoryPath)
                        .appendingPathComponent(".git/refs/heads/main.lock")
                )
            case .detached:
                try fixture.git(["checkout", "--quiet", "--detach"])
            case .hidden:
                try fixture.git(["update-index", "--skip-worktree", "value.txt"])
            case .replacement:
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: fixture.repositoryPath)
                        .appendingPathComponent(".git/refs/replace"),
                    withIntermediateDirectories: true
                )
            case .graft:
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: fixture.repositoryPath)
                        .appendingPathComponent(".git/info"),
                    withIntermediateDirectories: true
                )
                try Data("invalid\n".utf8).write(
                    to: URL(fileURLWithPath: fixture.repositoryPath)
                        .appendingPathComponent(".git/info/grafts")
                )
            }
            let before = try? oid(fixture, "refs/heads/main")
            let execution = try execute(fixture, executable: executable)
            try check(
                execution.result.code == expected,
                "\(state) was \(execution.result.code), expected \(expected)"
            )
            try check(!containsCommand(execution.audit, "fetch"), "\(state) reached fetch")
            try check(
                (try? oid(fixture, "refs/heads/main")) == before,
                "\(state) changed local main"
            )
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(atPath: fixture.repositoryPath)
            let execution = try execute(fixture, executable: executable)
            try check(
                execution.result.code == .skippedRepositoryRemoved,
                "removed repository was \(execution.result.code)"
            )
            try check(execution.audit.invocations.isEmpty, "removed repository invoked Git")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git([
                "remote", "set-url", "origin",
                "git@github.com:fixture-owner/different-repository.git",
            ])
            let execution = try execute(fixture, executable: executable)
            try check(
                execution.result.code == .failedInspection
                    && execution.result.technicalDetail?
                        .contains("config owner, type, or links") == true,
                "changed origin bypassed selected config identity"
            )
            try check(execution.audit.invocations.isEmpty, "changed raw origin invoked Git")
        }
    }

    private static func testNonMainAndLinkedPrefetchRefusal(
        executable: String
    ) throws {
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let main = try oid(fixture, "main")
            try fixture.git(["checkout", "--quiet", "-b", "feature"])
            let execution = try execute(fixture, executable: executable)
            try check(
                execution.result.code == .skippedPrimaryNotOnMain,
                "clean non-main was \(execution.result.code)"
            )
            try check(
                !execution.result.fetched
                    && !containsCommand(execution.audit, "fetch"),
                "clean non-main reached fetch"
            )
            try check(!containsCommand(execution.audit, "merge"), "clean non-main merged")
            let observedMain = try oid(fixture, "main")
            let observedBranch = try currentBranch(fixture)
            try check(observedMain == main, "clean non-main changed main")
            try check(observedBranch == "feature", "clean non-main switched branch")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let main = try oid(fixture, "main")
            try fixture.git(["checkout", "--quiet", "-b", "feature"])
            let linked = URL(fileURLWithPath: fixture.rootPath)
                .appendingPathComponent("linked-main").path
            try fixture.git(["worktree", "add", "--quiet", linked, "main"])
            let execution = try execute(fixture, executable: executable)
            try check(
                execution.result.code == .skippedMainInLinkedWorktree,
                "linked main was \(execution.result.code): \(execution.result.technicalDetail ?? "")"
            )
            try check(
                !execution.result.fetched
                    && !containsCommand(execution.audit, "fetch"),
                "linked-main fixture reached fetch"
            )
            try check(!containsCommand(execution.audit, "merge"), "linked-main fixture merged")
            let observedMain = try oid(fixture, "main")
            try check(observedMain == main, "linked-main fixture changed main")
        }
    }

    private static func testPrimaryMainWithDirtyFeatureWorktree(
        executable: String
    ) throws {
        let behind = try behindFixture()
        defer { behind.fixture.remove() }
        let fixture = behind.fixture
        let linked = fixture.rootPath + "/feature-worktree"
        try fixture.git([
            "worktree", "add", "--quiet", "-b", "feature", linked,
        ])
        try Data("dirty linked feature\n".utf8).write(
            to: URL(fileURLWithPath: linked + "/value.txt")
        )
        try Data("untracked linked feature\n".utf8).write(
            to: URL(fileURLWithPath: linked + "/untracked.txt")
        )
        let linkedGit = try linkedGitDirectory(linked)
        let snapshot = (
            marker: try Data(contentsOf: URL(fileURLWithPath: linked + "/.git")),
            head: try Data(contentsOf: URL(fileURLWithPath: linkedGit + "/HEAD")),
            index: try Data(contentsOf: URL(fileURLWithPath: linkedGit + "/index")),
            tracked: try Data(contentsOf: URL(fileURLWithPath: linked + "/value.txt")),
            untracked: try Data(
                contentsOf: URL(fileURLWithPath: linked + "/untracked.txt")
            ),
            commit: try runGit(["-C", linked, "rev-parse", "HEAD"])
        )

        let eligibilityProbe = M3EligibilityProbe()
        let execution = try execute(
            fixture,
            executable: executable,
            runtimeEligibilityCheck: { _ in
                eligibilityProbe.record()
            }
        )
        try check(
            execution.result.code == .updated
                && execution.result.afterCommit == behind.target,
            "primary main did not fast-forward with a dirty feature worktree: "
                + execution.result.code.rawValue + " "
                + (execution.result.technicalDetail ?? "")
        )
        let observedPrimaryBranch = try currentBranch(fixture)
        let observedPrimaryMain = try oid(fixture, "main")
        try check(
            observedPrimaryBranch == "main"
                && observedPrimaryMain == behind.target,
            "primary branch switched or reached the wrong ref"
        )
        let observedMarker = try Data(
            contentsOf: URL(fileURLWithPath: linked + "/.git")
        )
        try check(
            observedMarker == snapshot.marker,
            "linked worktree marker changed"
        )
        let observedHead = try Data(
            contentsOf: URL(fileURLWithPath: linkedGit + "/HEAD")
        )
        try check(
            observedHead == snapshot.head,
            "linked worktree HEAD changed"
        )
        let observedIndex = try Data(
            contentsOf: URL(fileURLWithPath: linkedGit + "/index")
        )
        try check(
            observedIndex == snapshot.index,
            "linked worktree index changed"
        )
        let observedTracked = try Data(
            contentsOf: URL(fileURLWithPath: linked + "/value.txt")
        )
        try check(
            observedTracked == snapshot.tracked,
            "linked dirty tracked bytes changed"
        )
        let observedUntracked = try Data(
            contentsOf: URL(fileURLWithPath: linked + "/untracked.txt")
        )
        try check(
            observedUntracked == snapshot.untracked,
            "linked untracked bytes changed"
        )
        let observedLinkedCommit = try runGit([
            "-C", linked, "rev-parse", "HEAD",
        ])
        try check(
            observedLinkedCommit == snapshot.commit,
            "linked feature commit changed"
        )
        try check(
            eligibilityProbe.count >= 4,
            "topology eligibility was not checked across all Git boundaries"
        )
        try assertClosedCommandSet(execution.audit)
    }

    private static func testPracticalDriftRefusals(
        executable: String
    ) throws {
        do {
            let behind = try behindFixture()
            defer { behind.fixture.remove() }
            try Data().write(
                to: URL(fileURLWithPath: behind.fixture.repositoryPath)
                    .appendingPathComponent(".git/refs/heads/main.lock")
            )
            let execution = try execute(
                behind.fixture,
                executable: executable
            )
            try check(
                execution.result.code == .skippedBusy
                    && !containsCommand(execution.audit, "fetch"),
                "actual main lock did not block before fetch"
            )
        }

        do {
            let behind = try behindFixture()
            defer { behind.fixture.remove() }
            let config = behind.fixture.repositoryPath + "/.git/config"
            let execution = try execute(
                behind.fixture,
                executable: executable,
                afterPreflight: { _ in
                    guard let handle = try? FileHandle(
                        forWritingTo: URL(fileURLWithPath: config)
                    ) else {
                        return
                    }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("\n# drift\n".utf8))
                    try? handle.close()
                }
            )
            try check(
                execution.result.code == .failedInspection
                    && !containsCommand(execution.audit, "fetch"),
                "config identity drift reached fetch"
            )
        }

        do {
            let behind = try behindFixture()
            defer { behind.fixture.remove() }
            let repositoryPath = behind.fixture.repositoryPath
            let target = behind.target
            let execution = try execute(
                behind.fixture,
                executable: executable,
                afterFetchCapture: { _, _ in
                    _ = try? runGit([
                        "-C", repositoryPath,
                        "update-ref", "refs/heads/main", target,
                    ])
                }
            )
            try check(
                execution.result.code == .failedInspection
                    && !containsCommand(execution.audit, "merge"),
                "local main ref drift reached merge"
            )
        }

        do {
            let behind = try behindFixture()
            defer { behind.fixture.remove() }
            let linked = behind.fixture.rootPath + "/drifting-feature"
            try behind.fixture.git([
                "worktree", "add", "--quiet", "-b", "drifting-feature",
                linked,
            ])
            let linkedGit = try linkedGitDirectory(linked)
            let linkedHead = linkedGit + "/HEAD"
            let expectedLinkedHead = try Data(
                contentsOf: URL(fileURLWithPath: linkedHead)
            )
            let execution = try execute(
                behind.fixture,
                executable: executable,
                afterFetchCapture: { _, _ in
                    try? Data("ref: refs/heads/main\n".utf8).write(
                        to: URL(fileURLWithPath: linkedHead)
                    )
                },
                runtimeEligibilityCheck: { _ in
                    guard try Data(
                        contentsOf: URL(fileURLWithPath: linkedHead)
                    ) == expectedLinkedHead else {
                        throw GitSafetyError.unsafeRepository(
                            "linked-worktree topology changed"
                        )
                    }
                }
            )
            try check(
                execution.result.code == .failedInspection
                    && !containsCommand(execution.audit, "merge"),
                "linked-worktree topology drift reached merge"
            )
            let observedMain = try oid(behind.fixture, "main")
            try check(
                observedMain == behind.before,
                "topology drift changed local main"
            )
        }
    }

    private static func testPracticalDetachedPrecision(
        executable: String
    ) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        try fixture.git(["push", fixture.remotePath, "main:main"])
        try fixture.git(["checkout", "--quiet", "--detach"])
        let execution = try execute(
            fixture,
            executable: executable
        )
        try check(
            execution.result.code == .skippedDetachedHead
                && !execution.result.fetched
                && !execution.result.mainUpdated
                && !containsCommand(execution.audit, "fetch"),
            "detached runtime state was not refused precisely before fetch"
        )
        try assertClosedCommandSet(execution.audit)

        let source = fixture.candidate
        let blocked = RepositoryCandidate(
            id: source.id,
            displayName: source.displayName,
            path: source.path,
            rawOrigin: source.rawOrigin,
            presentationLocation: "~/dev/testing/blocked",
            rootIdentity: source.rootIdentity,
            gitDirectoryIdentity: source.gitDirectoryIdentity,
            commonDirectoryIdentity: source.commonDirectoryIdentity,
            configIdentity: source.configIdentity,
            blockedReason: .dirty
        )
        let blockedExecution = try execute(
            fixture,
            executable: executable,
            candidate: blocked
        )
        try check(
            blockedExecution.result.code == .failedInspection
                && blockedExecution.audit.invocations.isEmpty,
            "blocked payload entered a Git command boundary"
        )
    }

    private static func linkedGitDirectory(_ worktree: String) throws -> String {
        let marker = try String(
            contentsOfFile: worktree + "/.git",
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard marker.hasPrefix(prefix) else {
            throw M3SelfTestError.message(
                "linked worktree marker was malformed"
            )
        }
        return String(marker.dropFirst(prefix.count))
    }

    private static func testResidueHookAndRuntimePolicy(executable: String) throws {
        do {
            let fixture = try behindFixture()
            defer { fixture.fixture.remove() }
            let residue = URL(fileURLWithPath: fixture.fixture.repositoryPath)
                .appendingPathComponent("fetch-residue.txt")
            let result = try execute(
                fixture.fixture,
                executable: executable,
                afterFetchCapture: { _, _ in
                    try? Data("residue\n".utf8).write(to: residue)
                }
            ).result
            try check(
                result.code == .skippedDirty,
                "fetch residue was \(result.code): \(result.technicalDetail ?? "")"
            )
            try check(result.fetched && !result.mainUpdated, "fetch residue flags are wrong")
            let observedMain = try oid(fixture.fixture, "main")
            try check(observedMain == fixture.before, "fetch residue changed main")
            try check(FileManager.default.fileExists(atPath: residue.path), "fetch residue was cleaned")
        }
        do {
            let fixture = try behindFixture()
            defer { fixture.fixture.remove() }
            let repositoryPath = fixture.fixture.repositoryPath
            let target = fixture.target
            let result = try execute(
                fixture.fixture,
                executable: executable,
                afterFetchCapture: { _, _ in
                    _ = try? runGit([
                        "-C", repositoryPath, "update-ref", "refs/heads/main", target,
                    ])
                }
            ).result
            try check(result.code == .failedInspection, "post-fetch local drift was \(result.code)")
            try check(!result.mainUpdated, "utility claimed a drifted local update")
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try Data("collision.txt\n".utf8).write(
                to: URL(fileURLWithPath: fixture.repositoryPath)
                    .appendingPathComponent(".gitignore")
            )
            try fixture.git(["add", ".gitignore"])
            try fixture.git(["commit", "--quiet", "-m", "ignore collision"])
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let before = try oid(fixture, "main")
            let collision = URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("collision.txt")
            try Data("remote\n".utf8).write(to: collision)
            try fixture.git(["add", "-f", "collision.txt"])
            try fixture.git(["commit", "--quiet", "-m", "track collision"])
            try fixture.git(["push", fixture.remotePath, "main:main"])
            try fixture.git(["reset", "--hard", before])
            try Data("local ignored sentinel\n".utf8).write(to: collision)
            let result = try execute(fixture, executable: executable).result
            try check(
                result.code == .skippedIgnoredFileCollision,
                "ignored collision was \(result.code): \(result.technicalDetail ?? "")"
            )
            try check(!result.mainUpdated, "ignored collision changed main")
            let preserved = try String(contentsOf: collision, encoding: .utf8)
            try check(
                preserved == "local ignored sentinel\n",
                "ignored collision sentinel was not preserved"
            )
        }
        do {
            let fixture = try behindFixture()
            defer { fixture.fixture.remove() }
            let hook = URL(fileURLWithPath: fixture.fixture.repositoryPath)
                .appendingPathComponent(".git/hooks/post-merge")
            let residue = URL(fileURLWithPath: fixture.fixture.repositoryPath)
                .appendingPathComponent("hook-residue.txt")
            let escapedResidue = residue.path.replacingOccurrences(
                of: "'",
                with: "'\\''"
            )
            try Data(
                "#!/bin/sh\nprintf 'hook residue\\n' > '\(escapedResidue)'\n".utf8
            ).write(to: hook)
            guard chmod(hook.path, 0o700) == 0 else {
                throw M3SelfTestError.message("could not make hook executable")
            }
            let result = try execute(fixture.fixture, executable: executable).result
            try check(result.code == .updatedWithWarning, "hook residue was \(result.code)")
            try check(result.mainUpdated, "hook update was not retained")
            let observedMain = try oid(fixture.fixture, "main")
            try check(observedMain == fixture.target, "hook reached wrong target")
            try check(FileManager.default.fileExists(atPath: residue.path), "hook residue was removed")
        }
        do {
            let fixture = try behindFixture()
            defer { fixture.fixture.remove() }
            let marker = URL(fileURLWithPath: fixture.fixture.repositoryPath)
                .appendingPathComponent(".controlled-hooks")
            let execution = try execute(
                fixture.fixture,
                executable: executable,
                afterPreflight: { _ in
                    try? Data("appeared\n".utf8).write(to: marker)
                },
                runtimeEligibilityCheck: { _ in
                    if FileManager.default.fileExists(atPath: marker.path) {
                        throw GitSafetyError.unsupportedHookFramework
                    }
                }
            )
            try check(
                execution.result.code == .skippedUnsupportedHookFramework,
                "late hook framework was \(execution.result.code)"
            )
            try check(!containsCommand(execution.audit, "fetch"), "late hook framework fetched")
            let observedMain = try oid(fixture.fixture, "main")
            try check(observedMain == fixture.before, "late hook framework changed main")
        }
    }

    private static func testFetchFailureContinuation(
        executable: String, marker: String, code: ResultCode, reason: FetchFailureReason
    ) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        try fixture.git(["push", fixture.remotePath, "main:main"])
        let secondPath = URL(fileURLWithPath: fixture.rootPath)
            .appendingPathComponent("second-repository").path
        try runGit(["clone", "--quiet", fixture.remotePath, secondPath])
        try runGit(["-C", secondPath, "remote", "set-url", "origin", fixture.candidate.rawOrigin])
        let second = try RepositoryHandle.fixedCandidate(path: secondPath)
        let audit = CommandAudit()
        let coordinator = RunCoordinator(
            configuration: CoordinatorConfiguration(
                stateLocation: fixture.stateLocation,
                trampolineExecutable: executable,
                transportMapping: fixture.mapping,
                fetchMutationsByRepositoryPath: [fixture.candidate.path: marker],
                fetchTimeoutSeconds: marker == GitCommandPolicy.syntheticFetchTimeoutMarker
                    ? 3 : 5
            ),
            audit: audit,
            account: fixture.account
        )
        let report = try coordinator.run(
            runID: RunIdentity.make(),
            candidates: [fixture.candidate, second],
            cancellation: CancellationToken(),
            eventSink: { _ in }
        )
        try check(report.results.count == 2, "failure continuation lost a row")
        try check(report.results[0].code == code, "\(reason) mapped to \(report.results[0].code)")
        try check(report.results[0].failureReason == reason, "\(reason) detail was lost")
        try check(
            report.results[1].code == .alreadyCurrent,
            "\(reason) stopped the later row: \(report.results[1].code)"
        )
        try check(
            report.results.allSatisfy { $0.durationMilliseconds >= 0 },
            "\(reason) produced invalid monotonic timing"
        )
        try assertClosedCommandSet(audit)
    }

    private static func testUpdateFailurePoststates(executable: String) throws {
        let cases: [(String, ResultCode, Bool)] = [
            (GitCommandPolicy.syntheticUpdateFailureMarker, .failedUpdate, false),
            (GitCommandPolicy.syntheticUpdateAdvanceFailureMarker, .updatedWithWarning, true),
            (GitCommandPolicy.syntheticUpdateAmbiguousMarker, .needsAttention, false),
        ]
        for (marker, expectedCode, expectedUpdated) in cases {
            let fixture = try behindFixture()
            defer { fixture.fixture.remove() }
            let execution = try execute(
                fixture.fixture,
                executable: executable,
                finalMutationOnUpdate: marker
            )
            try check(
                execution.result.code == expectedCode,
                "\(marker) was \(execution.result.code)"
            )
            try check(
                execution.result.mainUpdated == expectedUpdated,
                "\(marker) reported the wrong update truth"
            )
            if marker == GitCommandPolicy.syntheticUpdateFailureMarker {
                let observed = try oid(fixture.fixture, "main")
                try check(observed == fixture.before, "failed update changed main")
            } else if marker == GitCommandPolicy.syntheticUpdateAdvanceFailureMarker {
                let observed = try oid(fixture.fixture, "main")
                try check(observed == fixture.target, "warning update lost completed main")
            }
            try assertClosedCommandSet(execution.audit)
        }
    }

    private static func testFetchFailureClassifierPrecedence() throws {
        func result(
            _ diagnostic: String,
            timedOut: Bool = false
        ) -> ProcessResult {
            ProcessResult(
                status: 128,
                stdout: Data(),
                stderr: Data(diagnostic.utf8),
                stdoutTruncated: false,
                stderrTruncated: false,
                outputByteLimit: 16_384,
                timedOut: timedOut,
                cancelled: false,
                terminationRequested: timedOut,
                processID: 1
            )
        }
        let cases: [(String, ProcessResult, FetchFailureReason)] = [
            (
                "authoritative deadline",
                result("authentication failed", timedOut: true),
                .timeout
            ),
            (
                "authentication precedence",
                result("authentication operation timed out"),
                .authentication
            ),
            (
                "DNS precedence",
                result("could not resolve host; connection timed out"),
                .dns
            ),
            ("operation timeout", result("fatal: operation timed out"), .timeout),
            ("connection timeout", result("fatal: CONNECTION TIMED OUT"), .timeout),
            (
                "timeout before transport",
                result("request timed out after connection refused"),
                .timeout
            ),
            ("transport", result("fatal: connection reset by peer"), .transport),
            ("other", result("fatal: remote end hung up unexpectedly"), .other),
        ]
        for (name, processResult, expected) in cases {
            try check(
                FetchFailureClassifier.classify(processResult) == expected,
                "\(name) classification changed"
            )
        }
    }

    private static func testCommandAndTimeContract(executable: String) throws {
        let defaults = GitTransactionConfiguration(
            trampolineExecutable: nil,
            operationLeaseDescriptor: nil
        )
        try check(defaults.localTimeoutSeconds == 5, "local timeout is not five seconds")
        try check(defaults.fetchTimeoutSeconds == 120, "fetch timeout is not 120 seconds")
        let candidate = RepositoryCandidate(
            id: "fixture-owner/fixture-repo",
            displayName: "fixture",
            path: "/private/tmp/fixture",
            rawOrigin: "git@github.com:fixture-owner/fixture-repo.git"
        )
        for code in ResultCode.allCases {
            let result = RepositoryResult(
                repository: candidate,
                code: code,
                fetched: code != .cancelledPending,
                mainUpdated: [
                    ResultCode.updated, .updatedBeforeCancellation, .updatedWithWarning,
                ].contains(code),
                beforeCommit: String(repeating: "a", count: 40),
                targetCommit: String(repeating: "b", count: 40),
                afterCommit: String(repeating: "b", count: 40),
                remoteTrackingBeforeCommit: String(repeating: "a", count: 40),
                remoteTrackingAfterCommit: String(repeating: "b", count: 40),
                startedAt: WallClock.timestamp(),
                endedAt: WallClock.timestamp(),
                durationMilliseconds: 1,
                explanation: "fixture",
                technicalDetail: "bounded",
                failureReason: code == .failedFetchNetwork ? .timeout : nil
            )
            let encoded = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(RepositoryResult.self, from: encoded)
            try check(decoded == result, "result fields did not serialize for \(code)")
        }

        let fixture = try behindFixture()
        defer { fixture.fixture.remove() }
        let execution = try execute(fixture.fixture, executable: executable)
        try assertClosedCommandSet(execution.audit)
        let fetches = execution.audit.invocations.filter { $0.arguments.contains("fetch") }
        try check(fetches.count == 1, "behind state did not issue exactly one fetch")
        let fetch = fetches[0].arguments
        for required in [
            "--no-replace-objects", "--no-tags", "--no-prune",
            "--no-recurse-submodules", "refs/heads/main:refs/remotes/origin/main",
        ] {
            try check(fetch.contains(required), "fetch omitted \(required)")
        }
        try check(!fetch.contains("+refs/heads/main:refs/remotes/origin/main"), "fetch forced its refspec")
        let merges = execution.audit.invocations.filter { $0.arguments.contains("merge") }
        try check(merges.count == 1, "behind state did not issue exactly one update")
        for required in ["--ff-only", "--no-overwrite-ignore", "--no-autostash", fixture.target] {
            try check(merges[0].arguments.contains(required), "update omitted \(required)")
        }
    }

    private static func execute(
        _ fixture: M1GitFixture,
        executable: String,
        afterPreflight: (@Sendable (RepositoryCandidate) -> Void)? = nil,
        afterFetchCapture: (@Sendable (String, RepositoryCandidate) -> Void)? = nil,
        runtimeEligibilityCheck: (@Sendable (RepositoryCandidate) throws -> Void)? = nil,
        finalMutationOnUpdate: String? = nil,
        candidate: RepositoryCandidate? = nil
    ) throws -> (result: RepositoryResult, audit: CommandAudit) {
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let audit = CommandAudit()
        let transaction = GitTransaction(
            runner: DescriptorProcessRunner(audit: audit),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: executable,
                operationLeaseDescriptor: lease,
                transportMapping: fixture.mapping,
                afterPreflight: afterPreflight,
                afterFetchCapture: afterFetchCapture,
                finalMutationOnUpdate: finalMutationOnUpdate,
                runtimeEligibilityCheck: runtimeEligibilityCheck
            ),
            account: fixture.account
        )
        return (
            transaction.execute(
                candidate: candidate ?? fixture.candidate,
                cancellation: CancellationToken(),
                phase: { _ in }
            ),
            audit
        )
    }

    private static func behindFixture() throws -> (
        fixture: M1GitFixture,
        before: String,
        target: String
    ) {
        let fixture = try M1GitFixture()
        try fixture.git(["push", fixture.remotePath, "main:main"])
        let before = try oid(fixture, "HEAD")
        let target = try commit(fixture, name: "target")
        try fixture.git(["push", fixture.remotePath, "main:main"])
        try fixture.git(["reset", "--hard", before])
        return (fixture, before, target)
    }

    private static func commit(_ fixture: M1GitFixture, name: String) throws -> String {
        try Data("\(name)\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("\(name).txt")
        )
        try fixture.git(["add", "\(name).txt"])
        try fixture.git(["commit", "--quiet", "-m", name])
        return try oid(fixture, "HEAD")
    }

    private static func oid(_ fixture: M1GitFixture, _ ref: String) throws -> String {
        String(decoding: try fixture.gitOutput(["rev-parse", "--verify", ref]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func currentBranch(_ fixture: M1GitFixture) throws -> String {
        String(decoding: try fixture.gitOutput(["branch", "--show-current"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsCommand(_ audit: CommandAudit, _ command: String) -> Bool {
        audit.invocations.contains { $0.arguments.contains(command) }
    }

    private static func assertClosedCommandSet(_ audit: CommandAudit) throws {
        let banned = Set([
            "reset", "update-ref", "rebase", "pull", "stash", "clean", "checkout",
            "switch", "branch", "push", "commit", "tag",
        ])
        for invocation in audit.invocations {
            try check(invocation.executable == DescriptorProcessRunner.gitPath, "non-system Git ran")
            try check(
                Set(invocation.arguments).isDisjoint(with: banned),
                "banned Git family ran: \(invocation.arguments)"
            )
        }
    }

    @discardableResult
    private static func runGit(_ arguments: [String]) throws -> Data {
        try M1GitFixture.runGit(arguments)
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw M3SelfTestError.message(message)
        }
    }
}

private enum M3SelfTestError: Error, CustomStringConvertible {
    case message(String)
    case testFailed(String, String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        case let .testFailed(name, detail):
            return "\(name): \(detail)"
        }
    }
}
#endif
