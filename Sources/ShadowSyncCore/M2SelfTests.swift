#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum M2SelfTestRunner {
    public static func runPractical(
        onPass: (String) -> Void
    ) throws -> Int {
        let tests: [(String, () throws -> Void)] = [
            (
                "m2-practical-primary-authority-scan-orders",
                testPracticalPrimaryAuthorityScanOrders
            ),
            (
                "m2-practical-canonical-primary-and-duplicates",
                testPracticalCanonicalPrimaryAndDuplicates
            ),
            (
                "m2-practical-blocked-worktree-matrix",
                testPracticalBlockedWorktreeMatrix
            ),
            (
                "m2-practical-managed-hook-matrix",
                testPracticalManagedHookMatrix
            ),
            (
                "m2-practical-selection-admission",
                testPracticalSelectionAdmission
            ),
            (
                "m2-practical-admission-cache-and-path-identity",
                testAdmissionCacheAndPathIdentity
            ),
            (
                "m2-practical-hidden-and-policy-pruning",
                testHiddenImplementationDirectoryPruning
            ),
            (
                "m2-practical-complete-visibility-and-artifacts",
                testCompleteVisibilityAndArtifacts
            ),
            (
                "m2-practical-local-state-preselection",
                testLocalStatePreselection
            ),
            (
                "m2-practical-artifact-policy-compatibility",
                testArtifactPolicyCompatibility
            ),
        ]
        for (name, test) in tests {
            try RuntimeFixtureSession.withCase(name) { try test() }
            onPass(name)
        }
        return tests.count
    }

    public static func runPerformance(
        onPass: (String) -> Void
    ) throws -> Int {
        let tests: [(String, () throws -> Void)] = [
            (
                "m2-coalesced-validation-parity",
                testCoalescedValidationParity
            ),
            (
                "m2-hundred-candidate-discovery-budget",
                testHundredCandidateBudget
            ),
        ]
        for (name, test) in tests {
            try RuntimeFixtureSession.withCase(name) { try test() }
            onPass(name)
        }
        return tests.count
    }

    public static func runCoalescedValidation(
        onPass: (String) -> Void
    ) throws -> Int {
        try RuntimeFixtureSession.withCase("m2-coalesced-validation-parity") {
            try testCoalescedValidationParity()
        }
        onPass("m2-coalesced-validation-parity")
        return 1
    }

    public static func runAll(
        onPass: (String) -> Void
    ) throws -> Int {
        let tests: [(String, () throws -> Void)] = [
            (
                "m2-hidden-implementation-directory-pruning",
                testHiddenImplementationDirectoryPruning
            ),
            (
                "m2-complete-visibility-and-artifacts",
                testCompleteVisibilityAndArtifacts
            ),
            ("m2-local-state-preselection", testLocalStatePreselection),
            (
                "m2-artifact-policy-compatibility",
                testArtifactPolicyCompatibility
            ),
            (
                "m2-coalesced-validation-parity",
                testCoalescedValidationParity
            ),
            ("m2-hundred-candidate-discovery-budget", testHundredCandidateBudget),
            ("m2-dynamic-umbrella-sorting-safe-paths", testDynamicUmbrellaSortingAndSafePaths),
            ("m2-policy-parity-and-fail-closed", testPolicyParityAndFailure),
            ("m2-policy-zero-descent-and-origin-exclusion", testPolicyExclusions),
            ("m2-scan-budget-classification", testScanBudgetClassification),
            ("m2-common-directory-dedup-and-linked-topology", testLinkedWorktreeDeduplication),
            ("m2-malformed-metadata-matrix", testMalformedMetadataMatrix),
            ("m2-origin-eligibility-matrix", testOriginEligibilityMatrix),
            ("m2-effective-transport-discovery-matrix", testEffectiveTransportDiscoveryMatrix),
            ("m2-discovery-wait-error-drains-child", testDiscoveryWaitErrorDrainsChild),
            ("m2-selection-state-and-admission", testSelectionStateAndAdmission),
            (
                "m2-admission-cache-and-path-identity",
                testAdmissionCacheAndPathIdentity
            ),
            ("m2-multi-row-coordinator-admission", testMultiRowCoordinatorAdmission),
            ("m2-descendant-root-identity", testDescendantRootIdentity),
        ]
        for (name, test) in tests {
            try RuntimeFixtureSession.withCase(name) { try test() }
            onPass(name)
        }
        return tests.count
    }

    private static func testHiddenImplementationDirectoryPruning() throws {
        try withFixture { fixture in
            let visible = fixture.root + "/visible/nested/repository"
            let hidden = fixture.root + "/.hidden-fixture-repository"
            let archived = fixture.root + "/_ops/.trash/archive/repository"
            let generated = fixture.root + "/node_modules/repository"
            let policyExcluded = fixture.root + "/blocked/tree/repository"
            try fixture.createRepository(
                at: visible,
                origin: "https://github.com/owner/visible.git"
            )
            try fixture.createRepository(
                at: hidden,
                origin: "https://github.com/owner/hidden.git"
            )
            try fixture.createRepository(
                at: archived,
                origin: "https://github.com/owner/archived.git"
            )
            try fixture.createRepository(
                at: generated,
                origin: "https://github.com/owner/generated.git"
            )
            try fixture.createRepository(
                at: policyExcluded,
                origin: "https://github.com/owner/policy-excluded.git"
            )
            let hiddenLink = fixture.root + "/.hidden-fixture-link"
            let hiddenDanglingLink = fixture.root + "/.hidden-fixture-dangling-link"
            try FileManager.default.createSymbolicLink(
                atPath: hiddenLink,
                withDestinationPath: visible
            )
            try FileManager.default.createSymbolicLink(
                atPath: hiddenDanglingLink,
                withDestinationPath: fixture.root + "/missing-target"
            )

            let observed = M2PathCollector()
            let gitInvocations = M2GitInvocationCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                scanObserver: { observed.append($0) },
                gitCandidateObserver: {
                    gitInvocations.append(path: $0, arguments: $1)
                }
            ).discover()

            try check(
                Set(rows.map(\.path)) == Set([visible, policyExcluded]),
                "hidden, generated, or policy-visible discovery changed: \(rows.map(\.path))"
            )
            try assertBlocked(
                rows,
                path: policyExcluded,
                reason: .excludedByPolicy
            )
            for prunedRoot in [
                hidden,
                fixture.root + "/_ops/.trash",
                generated,
                hiddenLink,
                hiddenDanglingLink,
            ] {
                try check(
                    !observed.values.contains {
                        $0 == prunedRoot || $0.hasPrefix(prunedRoot + "/")
                    },
                    "pruned discovery root reached repository inspection: \(prunedRoot)"
                )
            }
            try check(
                gitInvocations.values.contains(where: {
                    $0.path == visible
                })
                    && !gitInvocations.values.contains(where: {
                        $0.path == policyExcluded
                    }),
                "policy-visible or pruned discovery Git boundary changed"
            )
        }
    }

    private static func testCompleteVisibilityAndArtifacts() throws {
        try withFixture(
            artifactPaths: [
                "artifacts/exact",
                "artifacts/glob/*",
            ]
        ) { fixture in
            let allowed = fixture.root + "/allowed/operator"
            let excluded = fixture.root + "/blocked/tree/repository"
            let readOnly = fixture.root + "/readonly/reference"
            let originExcluded = fixture.root + "/origin-excluded"
            let invalidOrigin = fixture.root + "/invalid-origin"
            let hooked = fixture.root + "/hooked"
            let linkedPrimary = fixture.root + "/linked-primary"
            let linkedRepresentation = fixture.root + "/linked-copy"
            let exactArtifact = fixture.root + "/artifacts/exact"
            let globArtifact = fixture.root + "/artifacts/glob/fixture"
            let hidden = fixture.root + "/.hidden/repository"
            let generated = fixture.root + "/build/repository"
            let bare = fixture.root + "/bare.git"
            for (path, origin) in [
                (allowed, "https://github.com/owner/operator.git"),
                (excluded, "https://github.com/owner/excluded.git"),
                (readOnly, "https://github.com/owner/reference.git"),
                (
                    originExcluded,
                    "https://github.com/blocked-owner/blocked-repo.git"
                ),
                (invalidOrigin, "https://example.invalid/owner/repository.git"),
                (hooked, "https://github.com/owner/hooked.git"),
                (
                    linkedPrimary,
                    "https://github.com/owner/linked-primary.git"
                ),
                (
                    exactArtifact,
                    "https://github.com/owner/exact-artifact.git"
                ),
                (
                    globArtifact,
                    "https://github.com/owner/glob-artifact.git"
                ),
                (hidden, "https://github.com/owner/hidden.git"),
                (generated, "https://github.com/owner/generated.git"),
            ] {
                try fixture.createRepository(at: path, origin: origin)
            }
            try fixture.addWorktree(
                primary: linkedPrimary,
                linked: linkedRepresentation,
                branch: "feature"
            )
            try Data().write(
                to: URL(
                    fileURLWithPath:
                        hooked + "/.fixture-hook-config.yaml"
                )
            )
            try fixture.git(["init", "-q", "--bare", bare])

            let observed = M2PathCollector()
            let gitInvocations = M2GitInvocationCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                scanObserver: { observed.append($0) },
                gitCandidateObserver: {
                    gitInvocations.append(path: $0, arguments: $1)
                }
            ).discover()
            let expectedRows = Set([
                allowed,
                excluded,
                readOnly,
                originExcluded,
                invalidOrigin,
                hooked,
                linkedPrimary,
            ])
            try check(
                Set(rows.map(\.path)) == expectedRows,
                "complete visibility inventory changed: "
                    + rows.map(\.path).joined(separator: ",")
            )
            try check(
                rows.first(where: { $0.path == allowed })?.isEligible == true,
                "allowed repository was not selectable"
            )
            try check(
                rows.first(where: { $0.path == linkedPrimary })?
                    .linkedWorktreePaths == [linkedRepresentation]
                    && !rows.contains(where: {
                        $0.path == linkedRepresentation
                    }),
                "linked representation was not grouped under its primary"
            )
            try assertBlocked(
                rows,
                path: excluded,
                reason: .excludedByPolicy
            )
            try assertBlocked(
                rows,
                path: readOnly,
                reason: .readOnlyReference
            )
            try assertBlocked(
                rows,
                path: originExcluded,
                reason: .excludedByPolicy
            )
            try assertBlocked(
                rows,
                path: invalidOrigin,
                reason: .unsupportedOrigin
            )
            try assertBlocked(
                rows,
                path: hooked,
                reason: .unsupportedHook
            )
            guard let invalid = rows.first(where: {
                $0.path == invalidOrigin
            }) else {
                throw M2SelfTestError.failed(
                    "invalid-origin row disappeared"
                )
            }
            try check(
                invalid.canonicalOriginName == nil
                    && invalid.displayName == "invalid-origin"
                    && invalid.presentationLocation
                        == "~/dev/invalid-origin",
                "invalid-origin row invented identity or lost location"
            )
            for omittedRoot in [
                exactArtifact,
                globArtifact,
                hidden,
                generated,
            ] {
                try check(
                    !observed.values.contains(where: {
                        $0 == omittedRoot
                            || $0.hasPrefix(omittedRoot + "/")
                    }),
                    "omitted tree was traversed: \(omittedRoot)"
                )
            }
            try check(
                !rows.contains(where: { $0.path == bare }),
                "bare repository was presented as a working copy"
            )
            let probedPaths = Set(gitInvocations.values.map(\.path))
            try check(
                probedPaths == Set([allowed, linkedPrimary]),
                "blocked or artifact repository received Git commands: "
                    + probedPaths.sorted().joined(separator: ",")
            )
            try check(
                gitInvocations.values.allSatisfy {
                    $0.arguments.prefix(2)
                        == ["--no-replace-objects", "--no-lazy-fetch"]
                        && !$0.arguments.contains("fetch")
                },
                "discovery Git commands left the closed local command set"
            )
        }
    }

    private static func testLocalStatePreselection() throws {
        try withFixture { fixture in
            let eligible = fixture.root + "/state-eligible"
            let dirty = fixture.root + "/state-dirty"
            let detached = fixture.root + "/state-detached"
            let nonMain = fixture.root + "/state-non-main"
            let missingMain = fixture.root + "/state-missing-main"
            let busy = fixture.root + "/state-busy"
            let hiddenIndex = fixture.root + "/state-hidden-index"
            let linkedMain = fixture.root + "/state-linked-main"
            let linkedMainWorktree = fixture.root + "/state-linked-copy"
            let unverifiable = fixture.root + "/state-unverifiable"
            for path in [
                eligible,
                dirty,
                detached,
                nonMain,
                missingMain,
                busy,
                hiddenIndex,
                linkedMain,
                unverifiable,
            ] {
                try fixture.createRepository(
                    at: path,
                    origin: "https://github.com/owner/"
                        + URL(fileURLWithPath: path).lastPathComponent
                        + ".git"
                )
            }
            try fixture.git([
                "-C", eligible, "update-ref",
                "refs/remotes/origin/main", "refs/heads/main",
            ])
            try Data("dirty\n".utf8).write(
                to: URL(fileURLWithPath: dirty + "/untracked.txt")
            )
            try fixture.git([
                "-C", dirty, "update-ref",
                "refs/remotes/origin/main", "refs/heads/main",
            ])
            try fixture.git([
                "-C", detached, "checkout", "-q", "--detach",
            ])
            try fixture.git([
                "-C", nonMain, "checkout", "-q", "-b", "feature",
            ])
            try fixture.git([
                "-C", missingMain, "branch", "-m", "trunk",
            ])
            try Data().write(
                to: URL(fileURLWithPath: busy + "/.git/index.lock")
            )
            try Data("tracked\n".utf8).write(
                to: URL(fileURLWithPath: hiddenIndex + "/tracked.txt")
            )
            try fixture.git(["-C", hiddenIndex, "add", "tracked.txt"])
            try fixture.git([
                "-C", hiddenIndex,
                "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.invalid",
                "commit", "-q", "-m", "tracked",
            ])
            try fixture.git([
                "-C", hiddenIndex, "update-index",
                "--skip-worktree", "tracked.txt",
            ])
            try fixture.git([
                "-C", linkedMain, "checkout", "-q", "-b", "feature",
            ])
            try fixture.addWorktree(
                primary: linkedMain,
                linked: linkedMainWorktree,
                branch: "main",
                createBranch: false
            )
            guard chmod(unverifiable + "/.git/index", 0) == 0 else {
                throw M2SelfTestError.failed(
                    "unverifiable-state fixture could not be protected"
                )
            }
            defer { _ = chmod(unverifiable + "/.git/index", 0o600) }

            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home
            ).discover()
            try check(
                rows.count == 9,
                "local-state discovery omitted or duplicated rows: "
                    + rows.map(\.path).joined(separator: ",")
            )
            guard let eligibleRow = rows.first(where: {
                $0.path == eligible
            }), let dirtyRow = rows.first(where: {
                $0.path == dirty
            }) else {
                throw M2SelfTestError.failed(
                    "eligible or dirty state row was omitted"
                )
            }
            try check(
                eligibleRow.isEligible
                    && eligibleRow.cachedMainRelation == .equal
                    && eligibleRow.configIdentity != nil
                    && eligibleRow.policyAdmissionSHA256 != nil
                    && eligibleRow.hookAdmissionSHA256 != nil,
                "eligible repository omitted an admission snapshot"
            )
            try check(
                dirtyRow.cachedMainRelation == .equal,
                "cached relation was not retained on a blocked row"
            )
            for (path, reason) in [
                (dirty, RepositoryBlockReason.dirty),
                (detached, .detachedHead),
                (nonMain, .primaryNotOnMain),
                (missingMain, .localMainMissing),
                (busy, .busy),
                (hiddenIndex, .hiddenIndex),
                (linkedMain, .mainInLinkedWorktree),
                (unverifiable, .localStateUnverifiable),
            ] {
                try assertBlocked(rows, path: path, reason: reason)
            }
        }
    }

    private static func testArtifactPolicyCompatibility() throws {
        try withFixture { fixture in
            let policy = try RepositoryPolicyLoader.load(
                rootPath: fixture.root
            )
            try check(
                policy.artifactPaths.isEmpty,
                "legacy policy without artifact_paths changed meaning"
            )
        }

        try withFixture(
            artifactPaths: [
                "fixtures/exact",
                "fixtures/generated/*",
            ]
        ) { fixture in
            let policy = try RepositoryPolicyLoader.load(
                rootPath: fixture.root
            )
            try check(
                policy.artifactPaths
                    == ["fixtures/exact", "fixtures/generated/*"],
                "artifact exact/glob policy was not parsed"
            )
            try check(
                policy.pathDisposition(
                    relativePath: "fixtures/exact"
                ) == .artifact
                    && policy.pathDisposition(
                        relativePath: "fixtures/generated/one"
                    ) == .artifact
                    && policy.pathDisposition(
                        relativePath: "fixtures/other"
                    ) == .allowed,
                "artifact exact/glob matching changed"
            )
        }

        for invalidPath in [
            "../escape",
            "/absolute",
            "blocked/example",
            "duplicate",
        ] {
            try withFixture { fixture in
                let policyPath =
                    fixture.root
                    + "/_ops/policy/worktree-policy.yml"
                var policy = try String(
                    contentsOfFile: policyPath,
                    encoding: .utf8
                )
                let entries =
                    invalidPath == "duplicate"
                    ? "    - duplicate\n    - duplicate"
                    : "    - \(invalidPath)"
                policy = policy.replacingOccurrences(
                    of: "  foreign_hook_frameworks:",
                    with: """
                      artifact_paths:
                    \(entries)
                      foreign_hook_frameworks:
                    """
                )
                try Data(policy.utf8).write(
                    to: URL(fileURLWithPath: policyPath)
                )
                do {
                    _ = try RepositoryPolicyLoader.load(
                        rootPath: fixture.root
                    )
                    throw M2SelfTestError.failed(
                        "invalid artifact policy was accepted: "
                            + invalidPath
                    )
                } catch M1RepositoryDiscoveryError.policyUnavailable {
                    // Expected fail-closed classification.
                }
            }
        }
    }

    private static func testPracticalPrimaryAuthorityScanOrders() throws {
        var outcomes: [String] = []
        for primaryFirst in [true, false] {
            try withFixture { fixture in
                let primary = fixture.root
                    + (primaryFirst ? "/a-primary" : "/z-primary")
                let stale = fixture.root
                    + (primaryFirst ? "/z-stale-linked" : "/a-stale-linked")
                let registered = fixture.home
                    + "/.cursor/worktrees/authority-order/feature"
                try fixture.createRepository(
                    at: primary,
                    origin: "git@github.com:owner/authority-order.git",
                    commit: true
                )
                try fixture.addWorktree(
                    primary: primary,
                    linked: registered,
                    branch: "feature"
                )
                try FileManager.default.createDirectory(
                    atPath: stale,
                    withIntermediateDirectories: false
                )
                try Data(
                    contentsOf: URL(fileURLWithPath: registered + "/.git")
                ).write(to: URL(fileURLWithPath: stale + "/.git"))
                let account = try EffectiveAccount.isolated(
                    homeDirectory: fixture.home
                )
                let registrations =
                    try RepositoryDiscovery.testingRegisteredLinkedWorktrees(
                        commonDirectory: primary + "/.git",
                        rootPath: fixture.root,
                        account: account
                    )
                var registeredInfo = stat()
                var staleInfo = stat()
                try check(
                    lstat(registered, &registeredInfo) == 0
                        && lstat(stale, &staleInfo) == 0,
                    "representation identity fixture could not be read"
                )
                try check(
                    RepositoryDiscovery.testingMatchesRegisteredRepresentation(
                        rootIdentity: RepositoryDirectoryIdentity(
                            FileIdentity(registeredInfo)
                        ),
                        linkedWorktrees: registrations
                    ),
                    "registered representation did not match by physical identity"
                )
                try check(
                    !RepositoryDiscovery.testingMatchesRegisteredRepresentation(
                        rootIdentity: RepositoryDirectoryIdentity(
                            FileIdentity(staleInfo)
                        ),
                        linkedWorktrees: registrations
                    ),
                    "backlink-copy inode mismatch was treated as registered"
                )

                let rows = try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover()
                let passed = rows.count == 1
                        && rows[0].path == primary
                        && rows[0].isEligible
                        && rows[0].linkedWorktreePaths == [registered]
                outcomes.append(
                    (primaryFirst ? "primary-first" : "stale-first")
                        + "="
                        + (passed ? "eligible" : rows.map {
                            $0.blockedReason?.rawValue ?? "unexpected"
                        }.joined(separator: ","))
                )
            }
        }
        try check(
            outcomes == [
                "primary-first=eligible",
                "stale-first=eligible",
            ],
            "stale linked representation overrode primary in scan orders: "
                + outcomes.joined(separator: ";")
        )
    }

    private static func testPracticalCanonicalPrimaryAndDuplicates() throws {
        try withFixture { fixture in
            let primary = fixture.root + "/cursor-primary"
            let linked = fixture.home + "/.cursor/worktrees/cursor-primary/feature"
            let detached =
                fixture.home + "/.cursor/worktrees/cursor-primary/detached"
            let duplicate = fixture.root + "/cursor-primary-duplicate"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/cursor-primary.git",
                commit: true
            )
            try fixture.createRepository(
                at: duplicate,
                origin: "git@github.com:owner/cursor-primary.git"
            )
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: linked).deletingLastPathComponent().path,
                withIntermediateDirectories: true
            )
            try Data("tracked\n".utf8).write(
                to: URL(fileURLWithPath: primary + "/tracked.txt")
            )
            try fixture.git(["-C", primary, "add", "tracked.txt"])
            try fixture.git([
                "-C", primary,
                "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.invalid",
                "commit", "-q", "-m", "tracked fixture",
            ])
            try fixture.git([
                "-C", primary, "worktree", "add", "-b", "feature", linked,
            ])
            try fixture.git([
                "-C", primary, "worktree", "add", "--detach", detached,
            ])
            try Data("dirty feature\n".utf8).write(
                to: URL(fileURLWithPath: linked + "/tracked.txt")
            )
            try Data("untracked feature\n".utf8).write(
                to: URL(fileURLWithPath: linked + "/untracked.txt")
            )
            _ = try RepositoryDiscovery.testingRegisteredLinkedWorktrees(
                commonDirectory: primary + "/.git",
                rootPath: fixture.root,
                account: try EffectiveAccount.isolated(
                    homeDirectory: fixture.home
                )
            )
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home
            ).discover()
            try check(
                Set(rows.map(\.path)) == Set([primary, duplicate])
                    && rows.allSatisfy(\.isEligible),
                "canonical primary or distinct duplicate was not admitted: "
                    + rows.map {
                        "\($0.path)=\($0.blockedReason?.rawValue ?? "eligible")"
                    }.joined(separator: ",")
            )
            guard let canonical = rows.first(where: { $0.path == primary }),
                  let duplicateRow = rows.first(where: {
                      $0.path == duplicate
                  }) else {
                throw M2SelfTestError.failed(
                    "canonical or duplicate row was absent"
                )
            }
            let expectedWorktrees = [linked, detached].sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            try check(
                canonical.linkedWorktreePaths == expectedWorktrees
                    && canonical.linkedWorktrees.map(\.path)
                        == expectedWorktrees,
                "valid feature and detached Cursor topology was not retained"
            )
            try check(
                canonical.commonDirectoryIdentity
                    != duplicateRow.commonDirectoryIdentity,
                "distinct physical clones were deduplicated"
            )
            let collisions =
                RepositoryOperatorPresentation.collidingPaths(in: rows)
            for row in rows {
                let label = RepositoryOperatorPresentation.selectionLabel(
                    row,
                    collidingPaths: collisions
                )
                try check(
                    label.contains(row.presentationLocation!),
                    "compact location was absent from a repository row"
                )
            }
        }

        try withFixture { fixture in
            let primary = fixture.root
                + "/depth-1/depth-2/depth-3/depth-4/depth-5/depth-6/primary"
            let stale = fixture.root + "/linked-only"
            let registered = fixture.home
                + "/.cursor/worktrees/linked-only/feature"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/linked-only.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: registered,
                branch: "feature"
            )
            try FileManager.default.createDirectory(
                atPath: stale,
                withIntermediateDirectories: false
            )
            try Data(
                contentsOf: URL(fileURLWithPath: registered + "/.git")
            ).write(to: URL(fileURLWithPath: stale + "/.git"))

            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home
            ).discover()
            try check(
                rows.count == 1
                    && rows[0].path == primary
                    && rows[0].isEligible
                    && rows[0].linkedWorktreePaths == [registered],
                "repository below the former depth-six cutoff was not discovered"
            )
        }
    }

    private static func testPracticalBlockedWorktreeMatrix() throws {
        try withFixture { fixture in
            let primary = fixture.root + "/unexpected-external"
            let linked =
                fixture.home + "/.local/share/awa/worktrees/repository/feature"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/unexpected-external.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: linked,
                branch: "feature"
            )
            try assertSingleBlocked(
                try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover(),
                path: primary,
                reason: .unsupportedExternalWorktree
            )
        }

        try withFixture { fixture in
            let primary = fixture.root + "/missing-external"
            let linked =
                fixture.home + "/.cursor/worktrees/missing-external/feature"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/missing-external.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: linked,
                branch: "feature"
            )
            try FileManager.default.removeItem(atPath: linked)
            try assertSingleBlocked(
                try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover(),
                path: primary,
                reason: .unsafeWorktreeTopology
            )
        }

        try withFixture { fixture in
            let primary = fixture.root + "/symlinked-external"
            let linked =
                fixture.home + "/.cursor/worktrees/symlinked-external/feature"
            let moved = fixture.home + "/physical-feature"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/symlinked-external.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: linked,
                branch: "feature"
            )
            try FileManager.default.moveItem(atPath: linked, toPath: moved)
            try FileManager.default.createSymbolicLink(
                atPath: linked,
                withDestinationPath: moved
            )
            try assertSingleBlocked(
                try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover(),
                path: primary,
                reason: .unsafeWorktreeTopology
            )
        }

        try withFixture { fixture in
            let primary = fixture.root + "/malformed-backlink"
            let linked =
                fixture.home + "/.cursor/worktrees/malformed-backlink/feature"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/malformed-backlink.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: linked,
                branch: "feature"
            )
            try Data("not-a-gitdir\n".utf8).write(
                to: URL(fileURLWithPath: linked + "/.git")
            )
            try assertSingleBlocked(
                try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover(),
                path: primary,
                reason: .unsafeWorktreeTopology
            )
        }

        try withFixture { fixture in
            let primary = fixture.root + "/mismatched-backlink"
            let first =
                fixture.home + "/.cursor/worktrees/mismatched-backlink/first"
            let second =
                fixture.home + "/.cursor/worktrees/mismatched-backlink/second"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/mismatched-backlink.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: first,
                branch: "first"
            )
            try fixture.addWorktree(
                primary: primary,
                linked: second,
                branch: "second"
            )
            let secondGitDirectory = try fixture.linkedGitDirectory(at: second)
            try Data("gitdir: \(secondGitDirectory)\n".utf8).write(
                to: URL(fileURLWithPath: first + "/.git")
            )
            try assertSingleBlocked(
                try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover(),
                path: primary,
                reason: .unsafeWorktreeTopology
            )
        }

        try withFixture { fixture in
            let primary = fixture.root + "/worktree-config"
            let linked =
                fixture.home + "/.cursor/worktrees/worktree-config/feature"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/worktree-config.git",
                commit: true
            )
            try fixture.addWorktree(
                primary: primary,
                linked: linked,
                branch: "feature"
            )
            let linkedGitDirectory = try fixture.linkedGitDirectory(at: linked)
            try Data("[user]\n\tname = unsafe\n".utf8).write(
                to: URL(
                    fileURLWithPath: linkedGitDirectory + "/config.worktree"
                )
            )
            try assertSingleBlocked(
                try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home
                ).discover(),
                path: primary,
                reason: .unsafeWorktreeTopology
            )
        }

        try withFixture { fixture in
            let primary = fixture.root + "/linked-main"
            let linked =
                fixture.home + "/.cursor/worktrees/linked-main/main"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/linked-main.git",
                commit: true
            )
            try fixture.git(["-C", primary, "checkout", "-q", "-b", "feature"])
            try fixture.addWorktree(
                primary: primary,
                linked: linked,
                branch: "main",
                createBranch: false
            )
            let commands = M2GitInvocationCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                gitCandidateObserver: {
                    commands.append(path: $0, arguments: $1)
                }
            ).discover()
            try assertSingleBlocked(
                rows,
                path: primary,
                reason: .mainInLinkedWorktree
            )
            try check(
                commands.values.isEmpty,
                "linked-main primary reached a Git probe"
            )
        }
    }

    private static func testPracticalManagedHookMatrix() throws {
        try withFixture { fixture in
            let exact = fixture.root + "/00-exact-managed"
            let spoofed = fixture.root + "/01-spoofed-marker"
            let drifted = fixture.root + "/02-byte-drift"
            let foreign = fixture.root + "/03-foreign-pre-commit"
            let husky = fixture.root + "/04-husky"
            let lefthook = fixture.root + "/05-lefthook"
            let framework = fixture.root + "/06-pre-commit-framework"
            let chained = fixture.root + "/07-chained-foreign"
            let writable = fixture.root + "/08-writable-managed"
            let symlinkedHooks = fixture.root + "/09-symlinked-hooks"
            let repositories = [
                exact, spoofed, drifted, foreign, husky, lefthook, framework,
                chained, writable, symlinkedHooks,
            ]
            for repository in repositories {
                try fixture.createRepository(
                    at: repository,
                    origin:
                        "git@github.com:owner/\(URL(fileURLWithPath: repository).lastPathComponent).git"
                )
            }
            try fixture.installManagedPreCommit(at: exact)
            try fixture.writeExecutablePreCommit(
                at: spoofed,
                text: """
                #!/bin/sh
                # managed-by: fixture-owner/dev identity-guard (spoof)
                exit 0
                """
            )
            try fixture.installManagedPreCommit(at: drifted)
            try fixture.append(
                "# drift\n",
                to: drifted + "/.git/hooks/pre-commit"
            )
            let sentinel = foreign + "/hook-executed"
            try fixture.writeExecutablePreCommit(
                at: foreign,
                text: "#!/bin/sh\nprintf ran > '\(sentinel)'\n"
            )
            try FileManager.default.createDirectory(
                atPath: husky + "/.husky",
                withIntermediateDirectories: false
            )
            try Data("pre-commit:\n".utf8).write(
                to: URL(fileURLWithPath: lefthook + "/.lefthook.yml")
            )
            try Data("repos: []\n".utf8).write(
                to: URL(
                    fileURLWithPath:
                        framework + "/.pre-commit-config.yaml"
                )
            )
            try fixture.installManagedPreCommit(at: chained)
            try fixture.writeExecutableFile(
                chained + "/.git/hooks/pre-commit.local",
                text: "#!/bin/sh\nexit 0\n"
            )
            try fixture.installManagedPreCommit(at: writable)
            guard chmod(
                writable + "/.git/hooks/pre-commit",
                0o722
            ) == 0 else {
                throw M2SelfTestError.failed(
                    "writable managed hook fixture mode could not change"
                )
            }
            let hooks = symlinkedHooks + "/.git/hooks"
            let physicalHooks = symlinkedHooks + "/.git/physical-hooks"
            try FileManager.default.moveItem(
                atPath: hooks,
                toPath: physicalHooks
            )
            try FileManager.default.createSymbolicLink(
                atPath: hooks,
                withDestinationPath: physicalHooks
            )
            try fixture.installManagedPreCommit(at: symlinkedHooks)

            let commands = M2GitInvocationCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                gitCandidateObserver: {
                    commands.append(path: $0, arguments: $1)
                }
            ).discover()
            try check(
                rows.count == repositories.count,
                "hook matrix lost safely identified rows"
            )
            guard let exactRow = rows.first(where: { $0.path == exact }) else {
                throw M2SelfTestError.failed(
                    "exact managed hook row was absent"
                )
            }
            try check(
                exactRow.isEligible,
                "exact owner-managed dispatcher was blocked"
            )
            for path in repositories where path != exact {
                guard let row = rows.first(where: { $0.path == path }) else {
                    throw M2SelfTestError.failed(
                        "blocked hook row was absent: \(path)"
                    )
                }
                try check(
                    row.blockedReason == .unsupportedHook,
                    "unsafe hook was not blocked: \(path) = "
                        + (row.blockedReason?.rawValue ?? "eligible")
                )
            }
            try check(
                Set(commands.values.map(\.path)) == Set([exact]),
                "blocked hook candidate received a Git probe"
            )
            try check(
                !FileManager.default.fileExists(atPath: sentinel),
                "discovery executed a repository hook"
            )
        }
    }

    private static func testPracticalSelectionAdmission() throws {
        let eligible = RepositoryCandidate(
            id: "owner/eligible",
            displayName: "owner/eligible",
            path: "/tmp/eligible",
            rawOrigin: "git@github.com:owner/eligible.git",
            presentationLocation: "~/dev/personal/eligible"
        )
        let blocked = RepositoryCandidate(
            id: "owner/blocked",
            displayName: "owner/blocked",
            path: "/tmp/blocked",
            rawOrigin: "git@github.com:owner/blocked.git",
            presentationLocation: "~/dev/personal/blocked",
            blockedReason: .unsafeWorktreeTopology
        )
        let invalidOrigin = RepositoryCandidate(
            id: "local:1:2",
            displayName: "invalid-origin",
            path: "/tmp/invalid-origin",
            rawOrigin: "",
            presentationLocation: "~/dev/personal/invalid-origin",
            blockedReason: .unsupportedOrigin
        )
        var state = RepositorySelectionState(
            candidates: [eligible, blocked, invalidOrigin]
        )
        state.selectAll()
        try check(
            state.selected == [eligible]
                && state.confirmationTitle
                    == "Ready to update 1 repositories",
            "select-all included a blocked repository"
        )
        state.setSelected(true, path: blocked.path)
        try check(state.selected == [eligible], "blocked row became selectable")
        state.clearAll()
        try check(!state.canReview, "clear-all left a selected row")
        try check(
            RepositorySelectionAdmission.admits(
                requests: [eligible],
                discovered: [eligible, blocked, invalidOrigin]
            ),
            "invalid-origin blocked row invalidated an eligible request"
        )
        try check(
            !RepositorySelectionAdmission.admits(
                requests: [blocked],
                discovered: [eligible, blocked, invalidOrigin]
            ),
            "blocked row entered worker admission"
        )
        let rediscoveredBlocked = RepositoryCandidate(
            id: eligible.id,
            displayName: eligible.displayName,
            path: eligible.path,
            rawOrigin: eligible.rawOrigin,
            presentationLocation: eligible.presentationLocation,
            blockedReason: .unsafeWorktreeTopology
        )
        try check(
            !RepositorySelectionAdmission.admits(
                requests: [eligible],
                discovered: [rediscoveredBlocked]
            ),
            "runtime rediscovery admitted an exact path after it became blocked"
        )
        try check(
            RepositoryOperatorPresentation.selectionLabel(
                eligible,
                collidingPaths: []
            ).contains("~/dev/personal/eligible"),
            "eligible row omitted its compact location"
        )
    }

    private static func testAdmissionCacheAndPathIdentity() throws {
        let base = RepositoryCandidate(
            id: "owner/cache-stable",
            displayName: "owner/cache-stable",
            path: "/private/tmp/cache-stable",
            rawOrigin: "git@github.com:owner/cache-stable.git",
            presentationLocation: "~/dev/personal/cache-stable",
            cachedMainRelation: .behind
        )
        let refusedRelations = [
            RepositoryCachedMainRelation.equal,
            .behind,
            .ahead,
            .diverged,
            .unavailable,
        ].filter { relation in
            let refreshed = RepositoryCandidate(
                id: base.id,
                displayName: base.displayName,
                path: base.path,
                rawOrigin: base.rawOrigin,
                presentationLocation: base.presentationLocation,
                rootIdentity: base.rootIdentity,
                gitDirectoryIdentity: base.gitDirectoryIdentity,
                commonDirectoryIdentity: base.commonDirectoryIdentity,
                configIdentity: base.configIdentity,
                linkedWorktreePaths: base.linkedWorktreePaths,
                linkedWorktrees: base.linkedWorktrees,
                cachedMainRelation: relation,
                blockedReason: base.blockedReason
            )
            let admitted = RepositorySelectionAdmission.admittedCandidates(
                requests: [base],
                discovered: [refreshed]
            )
            return admitted != [refreshed]
        }
        let blocked = RepositoryCandidate(
            id: base.id,
            displayName: base.displayName,
            path: base.path,
            rawOrigin: base.rawOrigin,
            presentationLocation: base.presentationLocation,
            rootIdentity: base.rootIdentity,
            gitDirectoryIdentity: base.gitDirectoryIdentity,
            commonDirectoryIdentity: base.commonDirectoryIdentity,
            configIdentity: base.configIdentity,
            cachedMainRelation: .equal,
            blockedReason: .unsupportedHook
        )
        try check(
            !RepositorySelectionAdmission.admits(
                requests: [base],
                discovered: [blocked]
            ),
            "blocked-reason drift was admitted"
        )
        let representedDrifts = [
            RepositoryCandidate(
                id: "owner/other",
                displayName: base.displayName,
                path: base.path,
                rawOrigin: "git@github.com:owner/other.git",
                presentationLocation: base.presentationLocation
            ),
            RepositoryCandidate(
                id: base.id,
                displayName: "changed-label",
                path: base.path,
                rawOrigin: base.rawOrigin,
                presentationLocation: base.presentationLocation
            ),
            RepositoryCandidate(
                id: base.id,
                displayName: base.displayName,
                path: "/private/tmp/other-path",
                rawOrigin: base.rawOrigin,
                presentationLocation: base.presentationLocation
            ),
            RepositoryCandidate(
                id: base.id,
                displayName: base.displayName,
                path: base.path,
                rawOrigin: base.rawOrigin,
                presentationLocation: "~/dev/personal/other-location"
            ),
            RepositoryCandidate(
                id: base.id,
                displayName: base.displayName,
                path: base.path,
                rawOrigin: base.rawOrigin,
                presentationLocation: base.presentationLocation,
                linkedWorktreePaths: ["/private/tmp/stale-linked-worktree"]
            ),
        ]
        for drift in representedDrifts {
            try check(
                !RepositorySelectionAdmission.admits(
                    requests: [base],
                    discovered: [drift]
                ),
                "represented admission-identity drift was admitted"
            )
        }
        let policySHA = String(repeating: "a", count: 64)
        let hookSHA = String(repeating: "b", count: 64)
        let snapshotted = RepositoryCandidate(
            id: base.id,
            displayName: base.displayName,
            path: base.path,
            rawOrigin: base.rawOrigin,
            presentationLocation: base.presentationLocation,
            policyAdmissionSHA256: policySHA,
            hookAdmissionSHA256: hookSHA
        )
        for drift in [
            RepositoryCandidate(
                id: base.id,
                displayName: base.displayName,
                path: base.path,
                rawOrigin: base.rawOrigin,
                presentationLocation: base.presentationLocation,
                policyAdmissionSHA256: String(repeating: "c", count: 64),
                hookAdmissionSHA256: hookSHA
            ),
            RepositoryCandidate(
                id: base.id,
                displayName: base.displayName,
                path: base.path,
                rawOrigin: base.rawOrigin,
                presentationLocation: base.presentationLocation,
                policyAdmissionSHA256: policySHA,
                hookAdmissionSHA256: String(repeating: "d", count: 64)
            ),
        ] {
            try check(
                !RepositorySelectionAdmission.admits(
                    requests: [snapshotted],
                    discovered: [drift]
                ),
                "policy or hook admission snapshot drift was admitted"
            )
        }

        try withFixture { fixture in
            let repository = fixture.root + "/physical-alias"
            try fixture.createRepository(
                at: repository,
                origin: "git@github.com:owner/physical-alias.git",
                commit: true
            )
            let linked = fixture.root + "/physical-alias-linked"
            try fixture.addWorktree(
                primary: repository,
                linked: linked,
                branch: "feature"
            )
            let candidate = try RepositoryHandle.testingBoundCandidate(
                path: repository,
                id: "owner/physical-alias",
                displayName: "owner/physical-alias",
                rawOrigin: "git@github.com:owner/physical-alias.git",
                presentationLocation: "~/dev/personal/physical-alias"
            )
            let otherRepository = fixture.root + "/other-identity"
            try fixture.createRepository(
                at: otherRepository,
                origin: "git@github.com:owner/other-identity.git",
                commit: true
            )
            let otherCandidate = try RepositoryHandle.testingBoundCandidate(
                path: otherRepository,
                id: "owner/other-identity",
                displayName: "owner/other-identity",
                rawOrigin: "git@github.com:owner/other-identity.git",
                presentationLocation: "~/dev/personal/other-identity"
            )
            let physicalIdentityDrifts = [
                RepositoryCandidate(
                    id: candidate.id,
                    displayName: candidate.displayName,
                    path: candidate.path,
                    rawOrigin: candidate.rawOrigin,
                    presentationLocation: candidate.presentationLocation,
                    rootIdentity: otherCandidate.rootIdentity,
                    gitDirectoryIdentity: candidate.gitDirectoryIdentity,
                    commonDirectoryIdentity: candidate.commonDirectoryIdentity,
                    configIdentity: candidate.configIdentity
                ),
                RepositoryCandidate(
                    id: candidate.id,
                    displayName: candidate.displayName,
                    path: candidate.path,
                    rawOrigin: candidate.rawOrigin,
                    presentationLocation: candidate.presentationLocation,
                    rootIdentity: candidate.rootIdentity,
                    gitDirectoryIdentity: otherCandidate.gitDirectoryIdentity,
                    commonDirectoryIdentity: candidate.commonDirectoryIdentity,
                    configIdentity: candidate.configIdentity
                ),
                RepositoryCandidate(
                    id: candidate.id,
                    displayName: candidate.displayName,
                    path: candidate.path,
                    rawOrigin: candidate.rawOrigin,
                    presentationLocation: candidate.presentationLocation,
                    rootIdentity: candidate.rootIdentity,
                    gitDirectoryIdentity: candidate.gitDirectoryIdentity,
                    commonDirectoryIdentity:
                        otherCandidate.commonDirectoryIdentity,
                    configIdentity: candidate.configIdentity
                ),
                RepositoryCandidate(
                    id: candidate.id,
                    displayName: candidate.displayName,
                    path: candidate.path,
                    rawOrigin: candidate.rawOrigin,
                    presentationLocation: candidate.presentationLocation,
                    rootIdentity: candidate.rootIdentity,
                    gitDirectoryIdentity: candidate.gitDirectoryIdentity,
                    commonDirectoryIdentity: candidate.commonDirectoryIdentity,
                    configIdentity: otherCandidate.configIdentity
                ),
            ]
            for drift in physicalIdentityDrifts {
                try check(
                    !RepositorySelectionAdmission.admits(
                        requests: [candidate],
                        discovered: [drift]
                    ),
                    "physical repository identity drift was admitted"
                )
            }
            let handle = try RepositoryHandle.open(candidate)
            let alias = candidate.path.replacingOccurrences(
                of: "/private/tmp/",
                with: "/tmp/"
            )
            let linkedAlias = linked.replacingOccurrences(
                of: "/private/tmp/",
                with: "/tmp/"
            )
            try check(alias != candidate.path, "macOS temporary-path alias was unavailable")
            _ = try LocalRepositoryInspection.inspect(handle: handle) {
                localInspectionResult(
                    arguments: $0,
                    worktrees: [
                        (alias, "main"),
                        (linkedAlias, "feature"),
                    ]
                )
            }

            let userSymlink = fixture.root + "/user-symlink"
            try FileManager.default.createSymbolicLink(
                atPath: userSymlink,
                withDestinationPath: candidate.path
            )
            for unsafePath in [
                userSymlink,
                fixture.root,
                fixture.root + "/missing",
            ] {
                do {
                    _ = try LocalRepositoryInspection.inspect(handle: handle) {
                        localInspectionResult(
                            arguments: $0,
                            worktrees: [(unsafePath, "main")]
                        )
                    }
                    throw M2SelfTestError.failed(
                        "unsafe worktree-list path was admitted: \(unsafePath)"
                    )
                } catch M2SelfTestError.failed {
                    throw M2SelfTestError.failed(
                        "unsafe worktree-list path was admitted: \(unsafePath)"
                    )
                } catch {
                    continue
                }
            }

            try fixture.append(
                "# backlink drift\n",
                to: linked + "/.git"
            )
            do {
                _ = try LocalRepositoryInspection.inspect(handle: handle) {
                    localInspectionResult(
                        arguments: $0,
                        worktrees: [
                            (alias, "main"),
                            (linkedAlias, "feature"),
                        ]
                    )
                }
                throw M2SelfTestError.failed(
                    "linked-worktree backlink drift was admitted"
                )
            } catch M2SelfTestError.failed {
                throw M2SelfTestError.failed(
                    "linked-worktree backlink drift was admitted"
                )
            } catch {
                // Expected: the marker no longer matches its verified backlink.
            }
        }

        let varFixture = try M2Fixture(
            writePolicy: true,
            temporaryBase: "/private/var/tmp"
        )
        defer {
            try? FileManager.default.removeItem(
                atPath: varFixture.temporaryRoot
            )
        }
        let varRepository = varFixture.root + "/var-alias"
        try varFixture.createRepository(
            at: varRepository,
            origin: "git@github.com:owner/var-alias.git",
            commit: true
        )
        let varCandidate = try RepositoryHandle.testingBoundCandidate(
            path: varRepository,
            id: "owner/var-alias",
            displayName: "owner/var-alias",
            rawOrigin: "git@github.com:owner/var-alias.git",
            presentationLocation: "~/dev/personal/var-alias"
        )
        let varAlias = varCandidate.path.replacingOccurrences(
            of: "/private/var/",
            with: "/var/"
        )
        try check(
            varAlias != varCandidate.path,
            "macOS /var alias fixture was unavailable"
        )
        let varHandle = try RepositoryHandle.open(varCandidate)
        _ = try LocalRepositoryInspection.inspect(handle: varHandle) {
            localInspectionResult(
                arguments: $0,
                worktrees: [(varAlias, "main")]
            )
        }

        try check(
            refusedRelations.isEmpty,
            "informational cached relation transitions were refused: "
                + refusedRelations.map(\.rawValue).joined(separator: ",")
        )
    }

    private static func localInspectionResult(
        arguments: [String],
        worktrees: [(String, String)]
    ) -> LocalRepositoryCommandResult {
        let command = arguments.dropFirst(2)
        let objectID = String(repeating: "a", count: 40)
        let status: Int32
        let stdout: Data
        if command.starts(with: ["worktree", "list"]) {
            status = 0
            stdout = Data(worktrees.map { path, branch in
                "worktree \(path)\0HEAD \(objectID)\0branch refs/heads/\(branch)\0"
            }.joined().utf8)
        } else if command.starts(with: ["for-each-ref"]) {
            status = 0
            stdout = Data(
                "refs/heads/main\0\(objectID)\0commit\0\0\0\n".utf8
            )
        } else if command.starts(with: ["status"]) {
            status = 0
            stdout = Data(
                "# branch.oid \(objectID)\0# branch.head main\0".utf8
            )
        } else if command.starts(with: ["ls-files"]) {
            status = 0
            stdout = Data()
        } else {
            status = 0
            stdout = Data("\(objectID)\n".utf8)
        }
        return LocalRepositoryCommandResult(
            status: status,
            stdout: stdout,
            stdoutTruncated: false,
            diagnostic: ""
        )
    }

    private static func assertSingleBlocked(
        _ rows: [RepositoryCandidate],
        path: String,
        reason: RepositoryBlockReason
    ) throws {
        guard rows.count == 1, let row = rows.first else {
            throw M2SelfTestError.failed(
                "blocked repository did not produce exactly one durable row"
            )
        }
        try check(
            row.path == path
                && row.blockedReason == reason
                && row.hasValidatedOriginIdentity
                && row.presentationLocation?.hasPrefix("~/dev/") == true,
            "blocked row identity, location, or reason changed"
        )
    }

    private static func testDynamicUmbrellaSortingAndSafePaths() throws {
        try withFixture { fixture in
            try fixture.createRepository(at: fixture.root, origin: "git@github.com:owner/root.git")
            let names = ["z-last", "space repo", "éclair", "semi;colon"]
            for (index, name) in names.enumerated() {
                try fixture.createRepository(
                    at: fixture.root + "/\(name)",
                    origin: "https://github.com/owner/path-\(index).git"
                )
            }
            let observed = M2PathCollector()
            let discovery = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                scanObserver: { observed.append($0) }
            )
            let first = try discovery.discover()
            try check(
                first.count == names.count + 1,
                "umbrella and safe paths were not discovered: \(first.map(\.path))"
            )
            let expectedOrder = names.enumerated().map {
                fixture.root + "/\($0.element)"
            } + [fixture.root]
            try check(
                first.map(\.path) == expectedOrder,
                "operator-name repository sorting changed"
            )
            try check(!observed.values.contains(where: { $0 == "/dev" || $0.hasPrefix("/dev/") }),
                      "discovery accessed system /dev")
            let removed = fixture.root + "/z-last"
            try FileManager.default.removeItem(atPath: removed)
            try fixture.createRepository(
                at: fixture.root + "/added",
                origin: "git@github.com:owner/added.git"
            )
            let second = try discovery.discover()
            try check(!second.contains(where: { $0.path == removed }),
                      "removed repository remained in fresh discovery")
            try check(second.contains(where: { $0.path == fixture.root + "/added" }),
                      "new repository was absent from fresh discovery")
            try check(first != second, "fresh discovery reused a persisted repository list")
        }
    }

    private static func testPolicyParityAndFailure() throws {
        try withFixture(artifactPaths: ["owned-artifact"]) { fixture in
            for (relative, origin) in [
                ("allowed/safe", "git@github.com:fixture-owner/safe.git"),
                ("blocked/repository", "git@github.com:fixture-owner/blocked.git"),
                ("readonly/reference", "git@github.com:fixture-owner/reference.git"),
                ("allowed/origin-blocked", "git@github.com:blocked-owner/blocked-repo.git"),
            ] {
                try fixture.createRepository(
                    at: fixture.root + "/" + relative,
                    origin: origin
                )
            }
            let policy = try RepositoryPolicyLoader.load(rootPath: fixture.root)
            try check(!policy.excludedPaths.isEmpty, "fixture path exclusions were not derived")
            try check(!policy.readOnlyPaths.isEmpty, "fixture read-only paths were not derived")
            try check(
                policy.artifactPaths == ["owned-artifact"],
                "fixture artifact policy was not normalized"
            )
            try check(!policy.excludedOrigins.isEmpty, "fixture origin exclusions were not derived")
            try check(!policy.foreignHookMarkers.isEmpty, "fixture hook markers were not derived")
            let observed = M2PathCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                scanObserver: { observed.append($0) }
            ).discover()
            try check(
                rows.contains { $0.path == fixture.root + "/allowed/safe" && $0.isEligible },
                "policy parity fixture did not admit its safe repository"
            )
            try check(
                observed.values.allSatisfy {
                    $0 == fixture.root || $0.hasPrefix(fixture.root + "/")
                },
                "fixture discovery escaped its owned root"
            )
            for row in rows {
                let relative = row.path == fixture.root
                    ? "."
                    : String(row.path.dropFirst(fixture.root.count + 1))
                if policy.excludes(
                    relativePath: relative,
                    origin: GitHubIdentity.parse(row.rawOrigin)
                ) {
                    try check(
                        !row.isEligible && row.blockedReason != nil,
                        "fixture policy-excluded repository became eligible"
                    )
                }
                try check(
                    row.linkedWorktreePaths.allSatisfy {
                        $0 == fixture.root || $0.hasPrefix(fixture.root + "/")
                    },
                    "fixture linked-worktree topology escaped its owned root"
                )
            }
        }

        let presentation = RepositoryDiscoveryFailurePresentation.forError(
            M1RepositoryDiscoveryError.policyUnavailable
        )
        try check(
            presentation.messageText == "Repository Safety Policy Unavailable"
                && presentation.informativeText
                    == "ShadowSync could not verify which repositories are safe to inspect. No repositories were checked.",
            "policy failure copy changed"
        )
        try withFixture(writePolicy: false) { fixture in
            let discovery = try RepositoryDiscovery(testingHomeDirectory: fixture.home)
            do {
                _ = try discovery.discover()
                throw M2SelfTestError.failed("missing policy did not fail closed")
            } catch M1RepositoryDiscoveryError.policyUnavailable {
                // Expected.
            }
        }
    }

    private static func testPolicyExclusions() throws {
        try withFixture { fixture in
            try fixture.createRepository(
                at: fixture.root + "/allowed/third party",
                origin: "https://github.com/external/third-party.git"
            )
            try fixture.createRepository(
                at: fixture.root + "/blocked/tree/repository",
                origin: "https://github.com/owner/path-blocked.git"
            )
            try fixture.createRepository(
                at: fixture.root + "/origin-blocked",
                origin: "git@github.com:blocked-owner/blocked-repo.git"
            )
            let hooked = fixture.root + "/hooked"
            try fixture.createRepository(
                at: hooked,
                origin: "git@github.com:owner/hooked.git"
            )
            try Data().write(to: URL(fileURLWithPath: hooked + "/.fixture-hook-config.yaml"))
            let observed = M2PathCollector()
            let gitInvocations = M2GitInvocationCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                scanObserver: { observed.append($0) },
                gitCandidateObserver: {
                    gitInvocations.append(path: $0, arguments: $1)
                }
            ).discover()
            let allowed = fixture.root + "/allowed/third party"
            let pathBlocked = fixture.root + "/blocked/tree/repository"
            let originBlocked = fixture.root + "/origin-blocked"
            try check(
                Set(rows.map(\.path)) == Set([
                    allowed, pathBlocked, originBlocked, hooked,
                ]),
                "policy-visible or permitted third-party behavior changed"
            )
            try assertBlocked(
                rows,
                path: pathBlocked,
                reason: .excludedByPolicy
            )
            try assertBlocked(
                rows,
                path: originBlocked,
                reason: .excludedByPolicy
            )
            try assertBlocked(
                rows,
                path: hooked,
                reason: .unsupportedHook
            )
            try check(
                Set(gitInvocations.values.map(\.path)) == Set([allowed]),
                "blocked policy or hook candidate received a Git probe"
            )
        }
    }

    private static func testScanBudgetClassification() throws {
        let presentation = RepositoryDiscoveryFailurePresentation.forError(
            M1RepositoryDiscoveryError.scanBudgetExceeded
        )
        try check(
            presentation.messageText == "Repository Search Limit Reached"
                && presentation.informativeText
                    == "ShadowSync stopped before offering repositories because ~/dev contains more folders than can be safely inspected in one run. Move unnecessary folders outside ~/dev, then try again. No update was started.",
            "scan-budget failure copy changed"
        )

        try withFixture { fixture in
            let repository = fixture.root + "/allowed-repository"
            try fixture.createRepository(
                at: repository,
                origin: "https://github.com/owner/allowed-repository.git"
            )
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                testingDirectoryLimit: 5
            ).discover()
            try check(
                rows.map(\.path) == [repository],
                "exactly-at-cap discovery did not return the complete eligible list"
            )
        }

        try withFixture { fixture in
            let repository = fixture.root + "/allowed-repository"
            try fixture.createRepository(
                at: repository,
                origin: "https://github.com/owner/allowed-repository.git"
            )
            try FileManager.default.createDirectory(
                atPath: fixture.root + "/z-over-cap",
                withIntermediateDirectories: false
            )
            let gitCommands = M2CommandCollector()
            do {
                _ = try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home,
                    testingDirectoryLimit: 5,
                    gitObserver: { gitCommands.append($0) }
                ).discover()
                throw M2SelfTestError.failed("over-cap discovery returned a partial list")
            } catch M1RepositoryDiscoveryError.scanBudgetExceeded {
                // Expected.
            }
            try check(
                gitCommands.values.isEmpty,
                "over-cap discovery probed a partial candidate set"
            )
        }
    }

    private static func testLinkedWorktreeDeduplication() throws {
        try withFixture { fixture in
            let primary = fixture.root + "/primary"
            let linked = fixture.root + "/linked worktree"
            try fixture.createRepository(
                at: primary,
                origin: "git@github.com:owner/topology.git",
                commit: true
            )
            try fixture.git(
                ["-C", primary, "worktree", "add", "-b", "linked-fixture", linked]
            )
            let account = try EffectiveAccount.isolated(homeDirectory: fixture.home)
            let common = try RepositoryDiscovery.testingLinkedCommonDirectory(
                markerPath: linked + "/.git",
                account: account
            )
            try check(common == primary + "/.git", "linked common directory resolved incorrectly")
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home
            ).discover()
            try check(rows.count == 1, "common Git directory was not deduplicated")
            try check(rows[0].path == primary, "linked worktree did not resolve to primary checkout")
            try check(
                rows[0].linkedWorktreePaths == [linked],
                "complete linked-worktree topology was not retained: \(rows[0].linkedWorktreePaths)"
            )

            let stale = rows
            try fixture.git(["-C", primary, "worktree", "remove", "--force", linked])
            let refreshed = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home
            ).discover()
            try check(refreshed.count == 1 && refreshed[0].linkedWorktreePaths.isEmpty,
                      "removed linked worktree remained in fresh topology")
            try check(!RepositorySelectionAdmission.admits(
                requests: stale,
                discovered: refreshed
            ), "changed topology was admitted")
        }
    }

    private static func testMalformedMetadataMatrix() throws {
        try withFixture { fixture in
            let cases = [
                ("include", "[include]\n\tpath = /tmp/other\n"),
                ("multiple-origin", "[remote \"origin\"]\n\turl = git@github.com:owner/second.git\n"),
                ("worktree", "[core]\n\tworktree = ../outside\n"),
                ("worktree-config", "[extensions]\n\tworktreeConfig = true\n"),
                ("upload-pack", "[remote \"origin\"]\n\tuploadpack = custom\n"),
                ("ssh-command", "[core]\n\tsshCommand = custom\n"),
            ]
            for (name, suffix) in cases {
                let path = fixture.root + "/\(name)"
                try fixture.createRepository(
                    at: path,
                    origin: "git@github.com:owner/\(name).git"
                )
                try fixture.append(suffix, to: path + "/.git/config")
            }
            let alternate = fixture.root + "/alternate"
            try fixture.createRepository(
                at: alternate,
                origin: "git@github.com:owner/alternate.git"
            )
            try FileManager.default.createDirectory(
                atPath: alternate + "/.git/objects/info",
                withIntermediateDirectories: true
            )
            try Data("../other\n".utf8).write(
                to: URL(fileURLWithPath: alternate + "/.git/objects/info/alternates")
            )
            let symlink = fixture.root + "/symlink-git"
            try FileManager.default.createDirectory(
                atPath: symlink,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: symlink + "/.git",
                withDestinationPath: alternate + "/.git"
            )
            let escaping = fixture.root + "/escaping-worktree"
            try fixture.createRepository(
                at: escaping,
                origin: "git@github.com:owner/escaping.git",
                commit: true
            )
            try fixture.git([
                "-C", escaping, "worktree", "add", "-b", "outside-fixture",
                fixture.temporaryRoot + "/outside-worktree",
            ])
            let worktreeConfigPrimary = fixture.root + "/worktree-local-config"
            let worktreeConfigLinked = fixture.root + "/worktree-local-linked"
            try fixture.createRepository(
                at: worktreeConfigPrimary,
                origin: "git@github.com:owner/worktree-local.git",
                commit: true
            )
            try fixture.git([
                "-C", worktreeConfigPrimary, "worktree", "add", "-b", "local-config-fixture",
                worktreeConfigLinked,
            ])
            let marker = try String(
                contentsOfFile: worktreeConfigLinked + "/.git",
                encoding: .utf8
            )
            let linkedGitDirectory = marker
                .dropFirst("gitdir: ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Data("[core]\n\tbare = false\n".utf8).write(
                to: URL(fileURLWithPath: linkedGitDirectory + "/config.worktree")
            )
            let gitCommands = M2CommandCollector()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                gitObserver: { gitCommands.append($0) }
            ).discover()
            let expectedPaths = Set(
                cases.map { fixture.root + "/\($0.0)" }
                    + [alternate, escaping, worktreeConfigPrimary]
            )
            try check(
                Set(rows.map(\.path)) == expectedPaths
                    && rows.allSatisfy { !$0.isEligible },
                "unsafe metadata was omitted or became eligible: "
                    + rows.map {
                        "\($0.path)=\($0.blockedReason?.rawValue ?? "eligible")"
                    }.joined(separator: ",")
            )
            try check(
                !rows.contains(where: { $0.path == symlink }),
                "unsafe symlink marker was treated as a physical working copy"
            )
            try check(gitCommands.values.isEmpty, "unsafe raw metadata received a Git probe")
        }
    }

    private static func testOriginEligibilityMatrix() throws {
        let raw = try requiredIdentity("git@github.com:owner/rewrite.git")
        let rewritten = try GitTransaction.validatedEffectiveIdentity(
            "https://github.com/owner/rewrite.git",
            rawIdentity: raw
        )
        try check(
            rewritten.canonicalName == raw.canonicalName,
            "same-identity GitHub transport rewrite was refused"
        )
        do {
            _ = try GitTransaction.validatedEffectiveIdentity(
                "https://github.com/other/rewrite.git",
                rawIdentity: raw
            )
            throw M2SelfTestError.failed("retargeting rewrite was admitted")
        } catch M2SelfTestError.failed {
            throw M2SelfTestError.failed("retargeting rewrite was admitted")
        } catch {
            // Expected.
        }
        try withFixture { fixture in
            let origins: [(String, String, Bool)] = [
                ("ssh", "git@github.com:owner/ssh.git", true),
                ("https", "https://github.com/owner/https.git", true),
                ("local", fixture.root + "/remote.git", false),
                ("malformed", "not a URL", false),
                ("credential", "https://token@github.com/owner/credential.git", false),
                ("missing", "", false),
            ]
            for (name, origin, _) in origins {
                try fixture.createRepository(
                    at: fixture.root + "/\(name)",
                    origin: origin
                )
            }
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home
            ).discover()
            let expected = Set(origins.map { fixture.root + "/\($0.0)" })
            try check(
                Set(rows.map(\.path)) == expected,
                "origin visibility matrix changed"
            )
            for (name, _, eligible) in origins {
                guard let row = rows.first(where: {
                    $0.path == fixture.root + "/\(name)"
                }) else {
                    throw M2SelfTestError.failed(
                        "origin row was absent: \(name)"
                    )
                }
                try check(
                    row.isEligible == eligible
                        && (
                            eligible
                                ? row.blockedReason == nil
                                : row.blockedReason == .unsupportedOrigin
                        ),
                    "origin eligibility changed for \(name)"
                )
                if !eligible {
                    try check(
                        row.canonicalOriginName == nil
                            && row.displayName == name,
                        "invalid origin invented canonical identity"
                    )
                }
            }
        }
    }

    private static func testEffectiveTransportDiscoveryMatrix() throws {
        let cases: [(String, String, String?, String?, Bool)] = [
            ("clean-ssh", "git@github.com:owner/clean-ssh.git", nil, nil, true),
            ("clean-https", "https://github.com/owner/clean-https.git", nil, nil, true),
            (
                "ssh-command-ssh",
                "git@github.com:owner/ssh-command-ssh.git",
                "[core]\n\tsshCommand = secret-command\n",
                nil,
                false
            ),
            (
                "ssh-command-https",
                "https://github.com/owner/ssh-command-https.git",
                "[core]\n\tsshCommand = ignored-for-https\n",
                nil,
                true
            ),
            (
                "uploadpack-ssh",
                "git@github.com:owner/uploadpack-ssh.git",
                "[remote \"origin\"]\n\tuploadpack = secret-command\n",
                nil,
                false
            ),
            (
                "uploadpack-https",
                "https://github.com/owner/uploadpack-https.git",
                "[remote \"origin\"]\n\tuploadpack = secret-command\n",
                nil,
                false
            ),
            (
                "included-ssh-command",
                "git@github.com:owner/included-ssh-command.git",
                "[include]\n\tpath = INCLUDE_PATH\n",
                "[core]\n\tsshCommand = included-secret-command\n",
                false
            ),
            (
                "duplicate-ssh-command",
                "git@github.com:owner/duplicate-ssh-command.git",
                "[core]\n\tsshCommand = first\n\tsshCommand = second\n",
                nil,
                false
            ),
            (
                "duplicate-uploadpack",
                "https://github.com/owner/duplicate-uploadpack.git",
                "[remote \"origin\"]\n\tuploadpack = first\n\tuploadpack = second\n",
                nil,
                false
            ),
            (
                "malformed-global-config",
                "git@github.com:owner/malformed-global-config.git",
                "[core\n\tsshCommand = malformed\n",
                nil,
                false
            ),
        ]
        for (name, origin, globalConfig, includedConfig, expected) in cases {
            try withFixture { fixture in
                let repository = fixture.root + "/\(name)"
                try fixture.createRepository(at: repository, origin: origin)
                if let includedConfig {
                    let includedPath = fixture.home + "/included-\(name).config"
                    try Data(includedConfig.utf8).write(to: URL(fileURLWithPath: includedPath))
                    try Data(
                        globalConfig!.replacingOccurrences(
                            of: "INCLUDE_PATH",
                            with: includedPath
                        ).utf8
                    ).write(to: URL(fileURLWithPath: fixture.home + "/.gitconfig"))
                } else if let globalConfig {
                    try Data(globalConfig.utf8).write(
                        to: URL(fileURLWithPath: fixture.home + "/.gitconfig")
                    )
                }
                let commands = M2CommandCollector()
                let rows = try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home,
                    gitObserver: { commands.append($0) }
                ).discover()
                let row = rows.first { $0.path == repository }
                try check(
                    row != nil && row?.isEligible == expected,
                    "effective transport discovery decision changed for \(name)"
                )
                try check(
                    !commands.values.contains(where: { $0.contains("fetch") }),
                    "discovery invoked network-capable fetch for \(name)"
                )
            }
        }

        for (name, origin, localConfig) in [
            (
                "local-ssh-command-no-shared-config",
                "git@github.com:owner/local-ssh-command.git",
                "\n[core]\n\tsshCommand = local-secret-command\n"
            ),
            (
                "local-uploadpack-no-shared-config",
                "https://github.com/owner/local-uploadpack.git",
                "\n[remote \"origin\"]\n\tuploadpack = local-secret-command\n"
            ),
        ] {
            try withFixture { fixture in
                let repository = fixture.root + "/\(name)"
                try fixture.createRepository(at: repository, origin: origin)
                try fixture.append(localConfig, to: repository + "/.git/config")
                try check(
                    !FileManager.default.fileExists(atPath: fixture.home + "/.gitconfig")
                        && !FileManager.default.fileExists(
                            atPath: fixture.home + "/.config/git/config"
                        ),
                    "local custom-transport fixture unexpectedly had shared config"
                )
                let commands = M2CommandCollector()
                let rows = try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home,
                    gitObserver: { commands.append($0) }
                ).discover()
                try check(
                    rows.first(where: { $0.path == repository })?.isEligible
                        == false,
                    "repository-local custom transport was not blocked for \(name)"
                )
                try check(
                    commands.values.isEmpty,
                    "repository-local custom transport reached a Git probe for \(name)"
                )
            }
        }

        for (name, rewriteBase, expected) in [
            ("local-same-identity-rewrite", "https://github.com/owner/", true),
            ("local-retargeting-rewrite", "https://github.com/other/", false),
        ] {
            try withFixture { fixture in
                let repository = fixture.root + "/\(name)"
                let origin = "git@github.com:owner/\(name).git"
                try fixture.createRepository(at: repository, origin: origin)
                try fixture.append(
                    """

                    [url "\(rewriteBase)"]
                        insteadOf = git@github.com:owner/
                    """,
                    to: repository + "/.git/config"
                )
                let commands = M2CommandCollector()
                let rows = try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home,
                    gitObserver: { commands.append($0) }
                ).discover()
                let row = rows.first { $0.path == repository }
                try check(
                    row != nil && row?.isEligible == expected,
                    "repository-local URL rewrite decision changed for \(name)"
                )
                try check(
                    commands.values.contains(where: { $0.contains("get-url") }),
                    "repository-local URL rewrite skipped effective origin validation"
                )
            }
        }

        for (name, section) in [
            ("local-include-rewrite", "include"),
            (
                "local-includeif-rewrite",
                #"includeIf "gitdir:**/local-includeif-rewrite/""#
            ),
        ] {
            try withFixture { fixture in
                let repository = fixture.root + "/\(name)"
                let included = fixture.root + "/\(name)-included.config"
                try fixture.createRepository(
                    at: repository,
                    origin: "git@github.com:owner/\(name).git"
                )
                try fixture.append(
                    """

                    [\(section)]
                        path = \(included)
                    """,
                    to: repository + "/.git/config"
                )
                try Data(
                    """
                    [url "https://github.com/retargeted/"]
                        insteadOf = git@github.com:owner/
                    """.utf8
                ).write(to: URL(fileURLWithPath: included))
                let commands = M2CommandCollector()
                let rows = try RepositoryDiscovery(
                    testingHomeDirectory: fixture.home,
                    gitObserver: { commands.append($0) }
                ).discover()
                try check(
                    rows.first(where: { $0.path == repository })?.isEligible
                        == false,
                    "repository-local \(section) retarget was not blocked"
                )
                try check(
                    commands.values.isEmpty,
                    "deferred repository-local \(section) reached a Git probe"
                )
            }
        }

        try withFixture { fixture in
            let repository = fixture.root + "/reason"
            try fixture.createRepository(
                at: repository,
                origin: "git@github.com:owner/reason.git"
            )
            let candidate = try RepositoryHandle.fixedCandidate(path: repository)
            try Data("[core]\n\tsshCommand = secret-command\n".utf8).write(
                to: URL(fileURLWithPath: fixture.home + "/.gitconfig")
            )
            do {
                _ = try DiscoveryGitProbe(
                    account: try EffectiveAccount.isolated(homeDirectory: fixture.home)
                ).validate(candidate)
                throw M2SelfTestError.failed("custom SSH command lacked an exclusion reason")
            } catch let GitSafetyError.customTransport(name) {
                try check(
                    name == "core.sshCommand",
                    "custom transport exclusion leaked or misstated command content"
                )
            }
        }
        do {
            try EffectiveTransportConfiguration.validate(
                status: 2,
                output: Data(),
                transport: .ssh,
                operation: "fixture transport probe"
            )
            throw M2SelfTestError.failed("failed config command was admitted")
        } catch let GitSafetyError.commandFailed(operation, status, diagnostic) {
            try check(
                operation == "fixture transport probe" && status == 2 && diagnostic.isEmpty,
                "failed config command reason changed"
            )
        }
    }

    private static func testDiscoveryWaitErrorDrainsChild() throws {
        try withFixture { fixture in
            let repository = fixture.root + "/wait-error"
            try fixture.createRepository(
                at: repository,
                origin: "https://github.com/owner/wait-error.git"
            )
            let candidate = try RepositoryHandle.testingBoundCandidate(
                path: repository,
                id: "owner/wait-error",
                displayName: "Wait Error",
                rawOrigin: "https://github.com/owner/wait-error.git"
            )
            try withUnrelatedSleep { unrelated in
            let observed = M2ProcessIdentityBox()
            let probe = DiscoveryGitProbe(
                account: try EffectiveAccount.isolated(homeDirectory: fixture.home),
                observer: nil,
                processObserver: { observed.set($0) },
                injectWaitError: true
            )
            do {
                _ = try probe.validate(candidate)
                throw M2SelfTestError.failed("injected wait error was ignored")
            } catch let SecureStateError.systemCall(operation, code) {
                try check(
                    operation == "waitpid discovery Git" && code == EIO,
                    "injected wait error classification changed"
                )
            }
            guard let identity = observed.value else {
                throw M2SelfTestError.failed(
                    "discovery child identity was not published"
                )
            }
            try check(
                !identity.isCurrent(expectedGeneration: identity.generation),
                "discovery child survived unexpected waitpid failure"
            )
            try check(unrelated.identity.isCurrent(expectedGeneration: unrelated.identity.generation)
                && unrelated.terminalStatusHeld == nil,
                "waitpid cleanup signalled an unrelated process")
            }
        }
    }

    // This sentinel is distinct from the discovery child under test, but remains
    // owned by this assertion case. Cancellation never abandons its original anchor.
    private static func withUnrelatedSleep(_ body: (OwnedDirectChild) throws -> Void) throws {
        let registry = try RuntimeFixtureSession.current()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions) == 0, "sentinel file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes) == 0, "sentinel attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0, "sentinel null stream")
        }
        var defaults = sigset_t(); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var mask = sigset_t(); sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
            && posix_spawnattr_setsigmask(&attributes, &mask) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setflags(&attributes, flags) == 0, "sentinel closed attributes")
        let strings = (["/bin/sleep", "30"] as [String]).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try check(strings.allSatisfy { $0 != nil }, "sentinel arguments")
        var argv = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in
            try environment.withUnsafeMutableBufferPointer { ev in
                try RuntimeFixtureSpawn.spawn(registry: registry, executable: "/bin/sleep",
                    actions: &actions, attributes: &attributes, arguments: av.baseAddress,
                    environment: ev.baseAddress, streamsDrained: { true })
            }
        }
        defer { RuntimeFixtureSession.drain(anchor) }
        let owner = try anchor.transfer(expectedExecutable: "/bin/sleep", generation: RunIdentity.make(),
                                        reapPolicy: .afterGroupDrain)
        try check(owner.send(SIGCONT), "sentinel admission refused")
        try body(owner)
    }

    private static func testSelectionStateAndAdmission() throws {
        let candidates = [
            RepositoryCandidate(id: "owner/a", displayName: "a", path: "/tmp/a", rawOrigin: "git@github.com:owner/a.git"),
            RepositoryCandidate(id: "owner/b", displayName: "b", path: "/tmp/b", rawOrigin: "git@github.com:owner/b.git"),
        ]
        var state = RepositorySelectionState(candidates: candidates)
        try check(!state.canReview && state.selected.isEmpty, "selection did not start empty")
        state.selectAll()
        try check(state.selected == candidates && state.confirmationTitle == "Ready to update 2 repositories",
                  "select-all or confirmation count changed")
        state.setSelected(false, path: candidates[0].path)
        try check(state.selected == [candidates[1]], "subset selection changed")
        state.clearAll()
        try check(!state.canReview, "clear-all left a selection")
        try check(RepositorySelectionAdmission.admits(
            requests: [candidates[1]],
            discovered: candidates
        ), "valid subset was refused")
        try check(!RepositorySelectionAdmission.admits(
            requests: [candidates[1], candidates[1]],
            discovered: candidates
        ), "duplicate request was admitted")
        try check(!RepositorySelectionAdmission.admits(
            requests: [RepositoryCandidate(
                id: candidates[1].id,
                displayName: candidates[1].displayName,
                path: "/tmp/swapped",
                rawOrigin: candidates[1].rawOrigin
            )],
            discovered: candidates
        ), "retargeted request was admitted")
    }

    private static func testCoalescedValidationParity() throws {
        try withFixture { fixture in
            let repository = fixture.root + "/coalesced"
            try fixture.createRepository(
                at: repository,
                origin: "git@github.com:owner/coalesced.git"
            )
            let fastPathCommands = M2CommandCollector()
            let fastPathRows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                gitObserver: { fastPathCommands.append($0) }
            ).discover()
            try check(
                fastPathRows.count == 1
                    && fastPathRows[0].isEligible,
                "coalesced two-child fast path changed eligibility"
            )
            try check(
                fastPathCommands.values.count == 2
                    && fastPathCommands.values.contains(where: {
                        $0.contains("remote")
                            && $0.contains("get-url")
                    })
                    && fastPathCommands.values.contains(where: {
                        $0.contains("status")
                            && $0.contains("--porcelain=v2")
                    }),
                "coalesced fast path no longer uses exactly origin and status"
            )
            let candidate = try RepositoryHandle.testingBoundCandidate(
                path: repository,
                id: "owner/coalesced",
                displayName: "owner/coalesced",
                rawOrigin: "git@github.com:owner/coalesced.git",
                presentationLocation: "~/dev/personal/coalesced"
            )
            let handle = try RepositoryHandle.open(candidate)
            let localOID = String(repeating: "a", count: 40)
            let remoteOID = String(repeating: "b", count: 40)

            struct Scenario {
                let name: String
                let remote: String?
                let expectedRelation: RepositoryCachedMainRelation
                let branch: String?
                let dirty: Bool
                let hidden: Bool
                let expectedBlock: LocalRepositoryInspectionBlock?
            }
            let scenarios = [
                Scenario(
                    name: "unavailable", remote: nil,
                    expectedRelation: .unavailable,
                    branch: "main", dirty: false, hidden: false,
                    expectedBlock: nil
                ),
                Scenario(
                    name: "equal", remote: localOID,
                    expectedRelation: .equal,
                    branch: "main", dirty: false, hidden: false,
                    expectedBlock: nil
                ),
                Scenario(
                    name: "behind", remote: remoteOID,
                    expectedRelation: .behind,
                    branch: "main", dirty: false, hidden: false,
                    expectedBlock: nil
                ),
                Scenario(
                    name: "ahead", remote: remoteOID,
                    expectedRelation: .ahead,
                    branch: "main", dirty: false, hidden: false,
                    expectedBlock: nil
                ),
                Scenario(
                    name: "diverged", remote: remoteOID,
                    expectedRelation: .diverged,
                    branch: "main", dirty: false, hidden: false,
                    expectedBlock: nil
                ),
                Scenario(
                    name: "detached", remote: nil,
                    expectedRelation: .unavailable,
                    branch: nil, dirty: false, hidden: false,
                    expectedBlock: .detachedHead
                ),
                Scenario(
                    name: "other-branch", remote: nil,
                    expectedRelation: .unavailable,
                    branch: "feature", dirty: false, hidden: false,
                    expectedBlock: .primaryNotOnMain
                ),
                Scenario(
                    name: "dirty", remote: nil,
                    expectedRelation: .unavailable,
                    branch: "main", dirty: true, hidden: false,
                    expectedBlock: .dirty
                ),
                Scenario(
                    name: "hidden-index", remote: nil,
                    expectedRelation: .unavailable,
                    branch: "main", dirty: false, hidden: true,
                    expectedBlock: .hiddenIndex
                ),
            ]

            for scenario in scenarios {
                let commands = M2CommandCollector()
                let inspection = try LocalRepositoryInspection.inspect(
                    handle: handle
                ) { arguments in
                    commands.append(arguments)
                    let command = Array(arguments.dropFirst(2))
                    let output: Data
                    if command.starts(with: ["worktree", "list"]) {
                        output = Data(
                            "worktree \(repository)\0HEAD \(localOID)\0branch refs/heads/main\0".utf8
                        )
                    } else if command.starts(with: ["for-each-ref"]) {
                        var text =
                            "refs/heads/main\0\(localOID)\0commit\0\0\0\n"
                        if let remote = scenario.remote {
                            text +=
                                "refs/remotes/origin/main\0\(remote)\0commit\0\0\0\n"
                        }
                        output = Data(text.utf8)
                    } else if command.starts(with: ["status"]) {
                        let head = scenario.branch ?? "(detached)"
                        var text =
                            "# branch.oid \(localOID)\0# branch.head \(head)\0"
                        if scenario.dirty {
                            text += "? changed.txt\0"
                        }
                        output = Data(text.utf8)
                    } else if command.starts(with: ["ls-files"]) {
                        output = scenario.hidden
                            ? Data("S value.txt\0".utf8)
                            : Data("H value.txt\0".utf8)
                    } else if command.starts(with: ["merge-base"]) {
                        let localFirst = command[2] == localOID
                        let succeeds =
                            scenario.expectedRelation == .behind
                                ? localFirst
                                : scenario.expectedRelation == .ahead
                                    ? !localFirst
                                    : false
                        return LocalRepositoryCommandResult(
                            status: succeeds ? 0 : 1,
                            stdout: Data(),
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    } else {
                        throw M2SelfTestError.failed(
                            "unexpected coalesced command for \(scenario.name): "
                                + command.joined(separator: " ")
                        )
                    }
                    return LocalRepositoryCommandResult(
                        status: 0,
                        stdout: output,
                        stdoutTruncated: false,
                        diagnostic: ""
                    )
                }
                try check(
                    inspection.localMainCommit == localOID
                        && inspection.cachedMainRelation
                            == scenario.expectedRelation
                        && inspection.block == scenario.expectedBlock,
                    "coalesced validation changed \(scenario.name) semantics"
                )
                let expectedCount: Int
                switch scenario.expectedRelation {
                case .unavailable, .equal:
                    expectedCount = 4
                case .behind:
                    expectedCount = 5
                case .ahead, .diverged:
                    expectedCount = 6
                }
                try check(
                    commands.values.count == expectedCount,
                    "coalesced local inspection count changed for "
                        + "\(scenario.name): \(commands.values.count)"
                )
            }

            let tagOID = String(repeating: "c", count: 40)
            let peeled = try LocalRepositoryInspection.inspect(
                handle: handle
            ) {
                let command = Array($0.dropFirst(2))
                let output: Data
                if command.starts(with: ["worktree", "list"]) {
                    output = Data(
                        "worktree \(repository)\0HEAD \(localOID)\0branch refs/heads/main\0".utf8
                    )
                } else if command.starts(with: ["for-each-ref"]) {
                    output = Data(
                        "refs/heads/main\0\(tagOID)\0tag\0\(localOID)\0commit\0\n".utf8
                    )
                } else if command.starts(with: ["status"]) {
                    output = Data(
                        "# branch.oid \(localOID)\0# branch.head main\0".utf8
                    )
                } else {
                    output = Data()
                }
                return LocalRepositoryCommandResult(
                    status: 0,
                    stdout: output,
                    stdoutTruncated: false,
                    diagnostic: ""
                )
            }
            try check(
                peeled.localMainCommit == localOID && peeled.block == nil,
                "coalesced refs no longer preserve rev-parse tag peeling"
            )

            let exactCommands = [
                [
                    "--no-replace-objects", "--no-lazy-fetch",
                    "for-each-ref",
                    "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00",
                    "refs/heads/main", "refs/remotes/origin/main",
                ],
                [
                    "--no-replace-objects", "--no-lazy-fetch",
                    "status", "--porcelain=v2", "-z", "--branch",
                    "--untracked-files=all",
                ],
            ]
            for arguments in exactCommands {
                _ = try GitCommandPolicy.validate(arguments)
                var widened = arguments
                widened.append("--no-walk")
                do {
                    _ = try GitCommandPolicy.validate(widened)
                    throw M2SelfTestError.failed(
                        "coalesced Git grammar admitted an extra argument"
                    )
                } catch M2SelfTestError.failed {
                    throw M2SelfTestError.failed(
                        "coalesced Git grammar admitted an extra argument"
                    )
                } catch {
                    // Expected.
                }
            }

            for malformed in [
                Data("refs/heads/main\0\(localOID)\0commit\0\0\0".utf8),
                Data("refs/heads/main\0\(localOID)\0blob\0\0\0\n".utf8),
                Data("refs/heads/main\0\(localOID)\0commit\0\0\0\nrefs/heads/main\0\(localOID)\0commit\0\0\0\n".utf8),
            ] {
                do {
                    _ = try LocalRepositoryInspection.inspect(handle: handle) {
                        let command = Array($0.dropFirst(2))
                        if command.starts(with: ["worktree", "list"]) {
                            return LocalRepositoryCommandResult(
                                status: 0,
                                stdout: Data(
                                    "worktree \(repository)\0HEAD \(localOID)\0branch refs/heads/main\0".utf8
                                ),
                                stdoutTruncated: false,
                                diagnostic: ""
                            )
                        }
                        if command.starts(with: ["status"]) {
                            return LocalRepositoryCommandResult(
                                status: 0,
                                stdout: Data(
                                    "# branch.oid \(localOID)\0# branch.head feature\0".utf8
                                ),
                                stdoutTruncated: false,
                                diagnostic: ""
                            )
                        }
                        return LocalRepositoryCommandResult(
                            status: 0,
                            stdout: malformed,
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    }
                    throw M2SelfTestError.failed(
                        "malformed coalesced ref output was admitted"
                    )
                } catch M2SelfTestError.failed {
                    throw M2SelfTestError.failed(
                        "malformed coalesced ref output was admitted"
                    )
                } catch let GitSafetyError.commandFailed(operation, _, _) {
                    try check(
                        operation == "git rev-parse",
                        "coalesced ref failure classification changed"
                    )
                }
            }

            for (malformedStatus, expectedOperation) in [
                (
                    Data("# branch.oid \(localOID)\0".utf8),
                    "git symbolic-ref"
                ),
                (
                    Data(
                        "# branch.oid invalid\0# branch.head main\0".utf8
                    ),
                    "git rev-parse"
                ),
                (
                    Data(
                        "# branch.oid \(localOID)\0# branch.head main\0# branch.head other\0".utf8
                    ),
                    "git symbolic-ref"
                ),
                (
                    Data(
                        "# branch.oid \(localOID)\0# branch.head (unknown)\0".utf8
                    ),
                    "git symbolic-ref"
                ),
                (
                    Data(
                        "# branch.oid \(localOID)\0# branch.head main\0# unexpected value\0".utf8
                    ),
                    "git status"
                ),
                (
                    Data(
                        "# branch.oid \(localOID)\0# branch.head main\0? missing-terminator".utf8
                    ),
                    "git status"
                ),
                (
                    Data(
                        "# branch.oid \(localOID)\0# branch.head main\02 R. N... 100644 100644 100644 \(localOID) \(localOID) R100 new\0".utf8
                    ),
                    "git status"
                ),
            ] {
                do {
                    _ = try LocalRepositoryInspection.inspect(handle: handle) {
                        let command = Array($0.dropFirst(2))
                        let output: Data
                        if command.starts(with: ["worktree", "list"]) {
                            output = Data(
                                "worktree \(repository)\0HEAD \(localOID)\0branch refs/heads/main\0".utf8
                            )
                        } else if command.starts(with: ["for-each-ref"]) {
                            output = Data(
                                "refs/heads/main\0\(localOID)\0commit\0\0\0\n".utf8
                            )
                        } else {
                            output = malformedStatus
                        }
                        return LocalRepositoryCommandResult(
                            status: 0,
                            stdout: output,
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    }
                    throw M2SelfTestError.failed(
                        "malformed coalesced status output was admitted"
                    )
                } catch M2SelfTestError.failed {
                    throw M2SelfTestError.failed(
                        "malformed coalesced status output was admitted"
                    )
                } catch let GitSafetyError.commandFailed(operation, _, _) {
                    try check(
                        operation == expectedOperation,
                        "coalesced status failure classification changed"
                    )
                }
            }

            do {
                _ = try LocalRepositoryInspection.inspect(handle: handle) {
                    let command = Array($0.dropFirst(2))
                    if command.starts(with: ["worktree", "list"]) {
                        return LocalRepositoryCommandResult(
                            status: 0,
                            stdout: Data(
                                "worktree \(repository)\0HEAD \(localOID)\0branch refs/heads/main\0".utf8
                            ),
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    }
                    if command.starts(with: ["for-each-ref"]) {
                        return LocalRepositoryCommandResult(
                            status: 0,
                            stdout: Data(
                                "refs/heads/main\0\(localOID)\0commit\0\0\0\nrefs/remotes/origin/main\0\(remoteOID)\0commit\0\0\0\n".utf8
                            ),
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    }
                    if command.starts(with: ["status"]) {
                        return LocalRepositoryCommandResult(
                            status: 0,
                            stdout: Data(
                                "# branch.oid \(localOID)\0# branch.head main\0".utf8
                            ),
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    }
                    if command.starts(with: ["ls-files"]) {
                        return LocalRepositoryCommandResult(
                            status: 0,
                            stdout: Data(),
                            stdoutTruncated: false,
                            diagnostic: ""
                        )
                    }
                    return LocalRepositoryCommandResult(
                        status: 2,
                        stdout: Data(),
                        stdoutTruncated: false,
                        diagnostic: ""
                    )
                }
                throw M2SelfTestError.failed(
                    "malformed coalesced relation output was admitted"
                )
            } catch M2SelfTestError.failed {
                throw M2SelfTestError.failed(
                    "malformed coalesced relation output was admitted"
                )
            } catch let GitSafetyError.commandFailed(operation, _, _) {
                try check(
                    operation == "git merge-base",
                    "coalesced relation failure classification changed"
                )
            }

            let taggedRepository = fixture.root + "/tagged-main"
            try fixture.createRepository(
                at: taggedRepository,
                origin: "git@github.com:owner/tagged-main.git"
            )
            let commitOID = try String(
                contentsOfFile:
                    taggedRepository + "/.git/refs/heads/main",
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try fixture.git([
                "-C", taggedRepository,
                "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.invalid",
                "tag", "-a", "annotated-main", "-m", "annotated",
            ])
            let annotatedOID = try String(
                contentsOfFile:
                    taggedRepository
                        + "/.git/refs/tags/annotated-main",
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try Data("\(annotatedOID)\n".utf8).write(
                to: URL(
                    fileURLWithPath:
                        taggedRepository + "/.git/refs/heads/main"
                )
            )
            let taggedCandidate =
                try RepositoryHandle.testingBoundCandidate(
                    path: taggedRepository,
                    id: "owner/tagged-main",
                    displayName: "owner/tagged-main",
                    rawOrigin:
                        "git@github.com:owner/tagged-main.git",
                    presentationLocation:
                        "~/dev/personal/tagged-main"
                )
            let taggedHandle = try RepositoryHandle.open(
                taggedCandidate
            )
            let taggedObjectIsCommit =
                try taggedHandle.readOnlyLooseCommitObject(
                    annotatedOID
                )
            try check(
                taggedObjectIsCommit == false,
                "annotated tag object was mistaken for a commit"
            )
            let taggedCommands = M2CommandCollector()
            let taggedInspection =
                try LocalRepositoryInspection.inspect(
                    handle: taggedHandle,
                    knownNoLinkedWorktrees: true
                ) { arguments in
                    taggedCommands.append(arguments)
                    let command = Array(arguments.dropFirst(2))
                    let output: Data
                    if command.starts(with: ["status"]) {
                        output = Data(
                            "# branch.oid \(annotatedOID)\0# branch.head main\0".utf8
                        )
                    } else if command.starts(
                        with: ["for-each-ref"]
                    ) {
                        output = Data(
                            "refs/heads/main\0\(annotatedOID)\0tag\0\(commitOID)\0commit\0\n".utf8
                        )
                    } else {
                        throw M2SelfTestError.failed(
                            "tag fallback admitted unexpected command"
                        )
                    }
                    return LocalRepositoryCommandResult(
                        status: 0,
                        stdout: output,
                        stdoutTruncated: false,
                        diagnostic: ""
                    )
                }
            try check(
                taggedInspection.localMainCommit == commitOID
                    && taggedInspection.block == nil
                    && taggedCommands.values.count == 2,
                "annotated branch tag no longer preserves commit peeling"
            )

            let malformedIndex = fixture.root + "/malformed-index"
            try fixture.createRepository(
                at: malformedIndex,
                origin: "git@github.com:owner/malformed-index.git"
            )
            try Data("corrupt".utf8).write(
                to: URL(
                    fileURLWithPath:
                        malformedIndex + "/.git/index"
                )
            )
            let malformedHandle = try RepositoryHandle.open(
                try RepositoryHandle.testingBoundCandidate(
                    path: malformedIndex,
                    id: "owner/malformed-index",
                    displayName: "owner/malformed-index",
                    rawOrigin:
                        "git@github.com:owner/malformed-index.git",
                    presentationLocation:
                        "~/dev/personal/malformed-index"
                )
            )
            do {
                _ = try malformedHandle.readOnlyHiddenIndexState()
                throw M2SelfTestError.failed(
                    "malformed direct index triggered a fallback"
                )
            } catch M2SelfTestError.failed {
                throw M2SelfTestError.failed(
                    "malformed direct index triggered a fallback"
                )
            } catch GitSafetyError.unsafeRepository {
                // Expected: malformed direct metadata fails closed.
            }
        }
    }

    private static func testHundredCandidateBudget() throws {
        try withFixture { fixture in
            for index in 0..<100 {
                try fixture.createRepository(
                    at: fixture.root + String(format: "/candidate-%03d", index),
                    origin: "git@github.com:owner/candidate-\(index).git"
                )
            }
            let commands = M2CommandCollector()
            let started = MonotonicInstant.now()
            let rows = try RepositoryDiscovery(
                testingHomeDirectory: fixture.home,
                gitObserver: { commands.append($0) }
            ).discover()
            let elapsed = MonotonicInstant.now().milliseconds(since: started)
            try check(
                rows.count == 100,
                "100-candidate fixture was incomplete: \(rows.count) admitted"
            )
            try check(
                rows.allSatisfy(\.isEligible),
                "100-candidate validation unexpectedly blocked rows: "
                    + rows.compactMap(\.blockedReason?.rawValue)
                        .joined(separator: ",")
            )
            try check(
                commands.values.count == 200,
                "100-candidate validation process count changed from 200: "
                    + "\(commands.values.count)"
            )
            try check(
                !commands.values.contains(where: {
                    $0.contains("show-ref")
                        || $0.contains("symbolic-ref")
                        || $0.contains("rev-parse")
                        || $0.contains("worktree")
                        || $0.contains("for-each-ref")
                        || $0.contains("ls-files")
                }),
                "coalesced validation regressed to duplicated Git queries"
            )
            print(
                "METRIC m2-hundred-candidate-processes "
                    + "\(commands.values.count)"
            )
            try check(elapsed < 5_000, "100-candidate discovery exceeded five seconds: \(elapsed) ms")
            print("METRIC m2-hundred-candidate-discovery \(elapsed) ms")
        }
    }

    private static func testDescendantRootIdentity() throws {
        try withFixture { fixture in
            let repository = fixture.root + "/nested/repository"
            try FileManager.default.createDirectory(
                atPath: repository,
                withIntermediateDirectories: true
            )
            let rootFD = Darwin.open(
                fixture.root,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            let repositoryFD = Darwin.open(
                repository,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            let outsideFD = Darwin.open(
                fixture.temporaryRoot,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            defer {
                close(rootFD)
                close(repositoryFD)
                close(outsideFD)
            }
            var repositoryInfo = stat()
            var outsideInfo = stat()
            try check(
                rootFD >= 0 && repositoryFD >= 0 && outsideFD >= 0
                    && fstat(repositoryFD, &repositoryInfo) == 0
                    && fstat(outsideFD, &outsideInfo) == 0,
                "root identity fixture could not be opened"
            )
            try GitChildRootIdentity.validate(
                expectedDescriptor: rootFD,
                currentDescriptor: repositoryFD,
                snapshotRoot: FileIdentity(repositoryInfo),
                allowDescendant: true
            )
            do {
                try GitChildRootIdentity.validate(
                    expectedDescriptor: rootFD,
                    currentDescriptor: outsideFD,
                    snapshotRoot: FileIdentity(outsideInfo),
                    allowDescendant: true
                )
                throw M2SelfTestError.failed("different root inode was admitted")
            } catch M2SelfTestError.failed {
                throw M2SelfTestError.failed("different root inode was admitted")
            } catch {
                // Expected.
            }
        }
    }

    private static func testMultiRowCoordinatorAdmission() throws {
        try withFixture { fixture in
            let state = try StateLocation.isolated(root: fixture.temporaryRoot)
            try TestIsolation.initializeState(at: state)
            let candidates = [
                RepositoryCandidate(
                    id: "owner/shared",
                    displayName: "first",
                    path: fixture.root + "/first",
                    rawOrigin: "git@github.com:owner/shared.git"
                ),
                RepositoryCandidate(
                    id: "owner/shared",
                    displayName: "second",
                    path: fixture.root + "/second",
                    rawOrigin: "git@github.com:owner/shared.git"
                ),
            ]
            let token = CancellationToken()
            token.cancel()
            let events = M2EventCollector()
            let coordinator = RunCoordinator(
                configuration: CoordinatorConfiguration(
                    stateLocation: state,
                    trampolineExecutable: nil
                ),
                account: try EffectiveAccount.isolated(homeDirectory: fixture.home)
            )
            let report = try coordinator.run(
                runID: RunIdentity.make(),
                candidates: candidates,
                cancellation: token
            ) { events.append($0) }
            try check(
                report.results.map(\.repository.path) == candidates.map(\.path)
                    && report.results.allSatisfy { $0.code == .cancelledPending },
                "multi-row coordinator did not preserve confirmed order"
            )
            try check(
                events.values.filter { $0.type == .repositoryResult }.count == 2,
                "multi-row coordinator did not emit every terminal row"
            )
        }
    }

    private static func withFixture(
        writePolicy: Bool = true,
        artifactPaths: [String] = [],
        _ body: (M2Fixture) throws -> Void
    ) throws {
        let fixture = try M2Fixture(
            writePolicy: writePolicy,
            artifactPaths: artifactPaths
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.temporaryRoot) }
        try body(fixture)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw M2SelfTestError.failed(message)
        }
    }

    private static func assertBlocked(
        _ rows: [RepositoryCandidate],
        path: String,
        reason: RepositoryBlockReason
    ) throws {
        guard let row = rows.first(where: { $0.path == path }) else {
            throw M2SelfTestError.failed(
                "blocked repository was omitted: \(path)"
            )
        }
        try check(
            !row.isEligible && row.blockedReason == reason,
            "repository block changed for \(path): "
                + (row.blockedReason?.rawValue ?? "eligible")
        )
    }

    private static func requiredIdentity(_ value: String) throws -> GitHubIdentity {
        guard let identity = GitHubIdentity.parse(value) else {
            throw M2SelfTestError.failed("identity fixture is invalid")
        }
        return identity
    }
}

private struct M2Fixture {
    let temporaryRoot: String
    let home: String
    let root: String

    init(
        writePolicy: Bool,
        artifactPaths: [String] = [],
        temporaryBase: String = "/private/tmp"
    ) throws {
        guard ["/private/tmp", "/private/var/tmp"].contains(temporaryBase) else {
            throw M2SelfTestError.failed("fixture temporary base is not admitted")
        }
        let prefix = try RuntimeFixtureSession.fixturePrefix("shadow-sync-m2.")
        temporaryRoot = temporaryBase + "/" + URL(fileURLWithPath: prefix).lastPathComponent
            + UUID().uuidString
        home = temporaryRoot + "/home"
        root = home + "/dev"
        try FileManager.default.createDirectory(
            atPath: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if writePolicy {
            try FileManager.default.createDirectory(
                atPath: root + "/_ops/policy",
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: root + "/_ops/bin",
                withIntermediateDirectories: true
            )
            let artifactSection = artifactPaths.isEmpty
                ? ""
                : """
                  artifact_paths:
                \(artifactPaths.map { "    - \($0)" }.joined(separator: "\n"))
                """
            let policy = """
            version: 1
            governed_roots:
              - ~/dev
            managed_location: ~/.cursor/worktrees
            modes_file: worktree-modes.yml
            default: include
            include:
              - allowed/*
            exclude:
              - blocked/*
              - .
            detectors:
              governed_markers:
                - _ops/POLICY.md
              foreign_hook_frameworks:
                - fixture-hook
                - husky
                - lefthook
                - pre-commit
              read_only_paths:
                - readonly/*
            \(artifactSection)
            overrides:
              include: []
              exclude: []
            """
            let baseline = """
            bl_classify_repo() {
              if [ "$ownerrepo_lc" = "blocked-owner/blocked-repo" ]; then
                printf 'EXCLUDED'
                return
              fi
            }
            """
            let installer = """
            MARKER='managed-by: fixture-owner/dev identity-guard'
            disp_tmp="$(mktemp)"
            cat > "$disp_tmp" <<EOF
            #!/usr/bin/env bash
            # $MARKER (chained pre-commit dispatcher)
            # Installed by fixture-owner/dev _ops/bin/install-identity-guard.sh — idempotent; do not hand-edit.
            # Runs the session-lock (concurrency, fail-closed), then identity-guard (fail-closed), then
            # data-guard (secrets/PII/oversized, fail-closed), then the registration-guard (ADVISORY, always
            # exits 0 — regenerates a capability repo's .eco-registry.lock; self-disables elsewhere), then chains
            # any preserved prior hook.
            set -uo pipefail
            HOOK_DIR="\\$(cd "\\$(dirname "\\$0")" && pwd)"
            if [ -x "\\$HOOK_DIR/session-lock" ]; then
              "\\$HOOK_DIR/session-lock" check || exit \\$?
            fi
            if [ -x "\\$HOOK_DIR/identity-guard" ]; then
              "\\$HOOK_DIR/identity-guard" || exit \\$?
            fi
            if [ -x "\\$HOOK_DIR/data-guard" ]; then
              "\\$HOOK_DIR/data-guard" || exit \\$?
            fi
            if [ -x "\\$HOOK_DIR/registration-guard" ]; then
              "\\$HOOK_DIR/registration-guard" || true
            fi
            if [ -x "\\$HOOK_DIR/pre-commit.local" ]; then
              exec "\\$HOOK_DIR/pre-commit.local"
            fi
            exit 0
            EOF
            """
            try Data(policy.utf8).write(
                to: URL(fileURLWithPath: root + "/_ops/policy/worktree-policy.yml")
            )
            try Data(baseline.utf8).write(
                to: URL(fileURLWithPath: root + "/_ops/bin/baseline-lib.sh")
            )
            try Data(installer.utf8).write(
                to: URL(fileURLWithPath: root + "/_ops/bin/install-identity-guard.sh")
            )
        }
    }

    func installManagedPreCommit(at repository: String) throws {
        let hook = repository + "/.git/hooks/pre-commit"
        try Data((Self.managedDispatcher + "\n").utf8).write(
            to: URL(fileURLWithPath: hook)
        )
        guard chmod(hook, 0o700) == 0 else {
            throw M2SelfTestError.failed("managed hook fixture could not be made executable")
        }
    }

    private static let managedDispatcher = """
    #!/usr/bin/env bash
    # managed-by: fixture-owner/dev identity-guard (chained pre-commit dispatcher)
    # Installed by fixture-owner/dev _ops/bin/install-identity-guard.sh — idempotent; do not hand-edit.
    # Runs the session-lock (concurrency, fail-closed), then identity-guard (fail-closed), then
    # data-guard (secrets/PII/oversized, fail-closed), then the registration-guard (ADVISORY, always
    # exits 0 — regenerates a capability repo's .eco-registry.lock; self-disables elsewhere), then chains
    # any preserved prior hook.
    set -uo pipefail
    HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$HOOK_DIR/session-lock" ]; then
      "$HOOK_DIR/session-lock" check || exit $?
    fi
    if [ -x "$HOOK_DIR/identity-guard" ]; then
      "$HOOK_DIR/identity-guard" || exit $?
    fi
    if [ -x "$HOOK_DIR/data-guard" ]; then
      "$HOOK_DIR/data-guard" || exit $?
    fi
    if [ -x "$HOOK_DIR/registration-guard" ]; then
      "$HOOK_DIR/registration-guard" || true
    fi
    if [ -x "$HOOK_DIR/pre-commit.local" ]; then
      exec "$HOOK_DIR/pre-commit.local"
    fi
    exit 0
    """

    func addWorktree(
        primary: String,
        linked: String,
        branch: String,
        createBranch: Bool = true
    ) throws {
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: linked)
                .deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        var arguments = ["-C", primary, "worktree", "add", "-q"]
        if createBranch {
            arguments += ["-b", branch, linked]
        } else {
            arguments += [linked, branch]
        }
        try git(arguments)
    }

    func linkedGitDirectory(at worktree: String) throws -> String {
        let marker = try String(
            contentsOfFile: worktree + "/.git",
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir: "
        guard marker.hasPrefix(prefix) else {
            throw M2SelfTestError.failed(
                "linked worktree fixture marker is malformed"
            )
        }
        return String(marker.dropFirst(prefix.count))
    }

    func writeExecutablePreCommit(
        at repository: String,
        text: String
    ) throws {
        try writeExecutableFile(
            repository + "/.git/hooks/pre-commit",
            text: text
        )
    }

    func writeExecutableFile(_ path: String, text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        guard chmod(path, 0o700) == 0 else {
            throw M2SelfTestError.failed(
                "hook fixture could not be made executable"
            )
        }
    }

    func createRepository(
        at path: String,
        origin: String,
        commit: Bool = true
    ) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        try git(["init", "-q", "-b", "main", path])
        if !origin.isEmpty {
            try git(["-C", path, "remote", "add", "origin", origin])
        }
        if commit {
            try git([
                "-C", path,
                "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.invalid",
                "commit", "-q", "--allow-empty", "-m", "fixture",
            ])
        }
    }

    func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func git(_ arguments: [String]) throws {
        // The /var alias assertion keeps its repositories in /private/var/tmp.
        // Its setup process gets a separately owned /private/tmp home so the
        // normal test-account validator remains unchanged. Config and cwd still
        // refer to the original fixture; no real user configuration is read.
        let executionRoot: M1TemporaryDirectory?
        let executionHome: String
        if temporaryRoot.hasPrefix("/private/var/tmp/shadow-sync-m2.") {
            let temporary = try M1TemporaryDirectory()
            executionRoot = temporary
            executionHome = temporary.path + "/home"
            try FileManager.default.createDirectory(atPath: executionHome,
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } else {
            executionRoot = nil
            executionHome = home
        }
        defer { executionRoot?.remove() }
        let account = try EffectiveAccount.isolated(homeDirectory: executionHome)
        let directory = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw M2SelfTestError.failed("fixture home is unavailable") }
        defer { close(directory) }
        let result = try ClosedProcessRunner().run(
            command: ClosedProcessCommand(executable: discoveryFixtureGitExecutable, arguments: arguments),
            environment: ClosedProcessRunner.environment(account: account,
                frozenConfigPath: home + "/.gitconfig"),
            workingDirectoryDescriptor: directory, account: account,
            timeout: 10, cancellation: CancellationToken())
        guard result.status == 0 && !result.timedOut && !result.cancelled
            && !result.stdoutTruncated && !result.stderrTruncated else {
            throw M2SelfTestError.failed("git fixture failed: "
                + String(decoding: result.stderr, as: UTF8.self))
        }
    }

}

private enum M2SelfTestError: Error {
    case failed(String)
}

private final class M2PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private final class M2EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RunEvent] = []

    func append(_ event: RunEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var values: [RunEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class M2CommandCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func append(_ command: [String]) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    var values: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

private final class M2GitInvocationCollector: @unchecked Sendable {
    struct Invocation {
        let path: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    func append(path: String, arguments: [String]) {
        lock.lock()
        invocations.append(Invocation(path: path, arguments: arguments))
        lock.unlock()
    }

    var values: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

private final class M2ProcessIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ProcessIdentity?

    func set(_ value: ProcessIdentity) {
        lock.lock()
        identity = value
        lock.unlock()
    }

    var value: ProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identity
    }
}
#endif
