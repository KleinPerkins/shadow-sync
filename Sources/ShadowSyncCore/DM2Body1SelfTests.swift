#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum V2Body1SelfTestRunner {
    public static func runAll(
        testExecutable: String,
        onPass: (String) -> Void = { _ in }
    ) throws -> Int {
        let tests: [(String, () throws -> Void)] = [
            (
                "DM2-T01 identity-authority",
                testIdentityAuthority
            ),
            (
                "DM2-T02 remote-default",
                {
                    try testRemoteDefaults(
                        testExecutable: testExecutable
                    )
                }
            ),
            (
                "DM2-T03 checked-out-target",
                {
                    try testCheckedOutTargets(
                        testExecutable: testExecutable
                    )
                }
            ),
            (
                "DM2-T05 Body 1 hooks",
                {
                    try testHooks(
                        testExecutable: testExecutable
                    )
                }
            ),
            (
                "DM2-T12 Body 1 cards",
                {
                    try testRepositoryCards(
                        testExecutable: testExecutable
                    )
                }
            ),
            (
                "DM2-T13 Body 1 lifecycle",
                testAuthorityLifecycle
            ),
        ]
        let requestedTest = ProcessInfo.processInfo.environment[
            "SHADOW_SYNC_BODY1_TEST"
        ]
        if let requestedTest, !tests.contains(where: { $0.0 == requestedTest }) {
            throw DM2Body1SelfTestError.testFailed(
                "selection", "unknown Body 1 test selector"
            )
        }
        var completed = 0
        for (name, test) in tests
        where requestedTest == nil || requestedTest == name {
            let started = MonotonicInstant.now()
            do {
                try test()
                let duration = MonotonicInstant.now().milliseconds(
                    since: started
                )
                onPass("\(name) [\(duration) ms]")
                completed += 1
            } catch {
                throw DM2Body1SelfTestError.testFailed(
                    name,
                    String(describing: error)
                )
            }
        }
        return completed
    }

    public static func runBetaV08(
        testExecutable: String,
        onPass: (String) -> Void = { _ in }
    ) throws {
        for (state, expected) in [
            (FixtureState.equal, ResultCode.alreadyCurrent),
            (FixtureState.behind, ResultCode.updated),
        ] {
            let prepared = try preparedFixture(
                defaultBranch: "main",
                state: state,
                additionalTrackedFiles: 512
            )
            defer { prepared.fixture.remove() }
            let inventory = try prepared.fixture.gitOutput([
                "ls-files", "-v", "-z",
            ])
            try check(
                inventory.count > 16_384
                    && inventory.count
                        < DescriptorProcessRunner
                            .completeRepositoryOutputLimit,
                "large Fast-forward fixture did not cross the legacy output cap"
            )
            let execution = try execute(
                prepared,
                operation: try makeOperation(prepared),
                executable: testExecutable
            )
            try check(
                execution.result.code == expected,
                "large-index \(state) execution failed: "
                    + execution.result.code.rawValue
                    + " "
                    + (
                        execution.result.technicalDetail
                            ?? execution.result.explanation
                    )
            )
        }

        let hidden = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            additionalTrackedFiles: 512
        )
        defer { hidden.fixture.remove() }
        try hidden.fixture.git([
            "update-index", "--skip-worktree",
            "inventory-0000-\(String(repeating: "x", count: 48)).txt",
        ])
        let hiddenResult = try execute(
            hidden,
            operation: try makeOperation(hidden),
            executable: testExecutable
        ).result
        try check(
            hiddenResult.code == .skippedHiddenIndexState,
            "large hidden-index fixture was admitted"
        )

        let leakedName = "private-file-name.txt"
        let truncated = ProcessResult(
            status: 0,
            stdout: Data(leakedName.utf8),
            stderr: Data(),
            stdoutTruncated: true,
            stderrTruncated: false,
            outputByteLimit:
                DescriptorProcessRunner
                    .completeRepositoryOutputLimit,
            timedOut: false,
            cancelled: false,
            terminationRequested: false,
            processID: 1
        )
        try check(
            truncated.outputDisposition
                == .stdoutExceededBound
                && truncated.exitedSuccessfully
                && !truncated.succeeded
                && truncated.diagnostic.contains(
                    "33554432-byte bound (exit 0)"
                )
                && !truncated.diagnostic.contains(leakedName),
            "status-zero output overflow was not typed and sanitized"
        )
        let failedIndex = ProcessResult(
            status: 1,
            stdout: Data(leakedName.utf8),
            stderr: Data("index command refused".utf8),
            stdoutTruncated: false,
            stderrTruncated: false,
            outputByteLimit:
                DescriptorProcessRunner
                    .completeRepositoryOutputLimit,
            timedOut: false,
            cancelled: false,
            terminationRequested: false,
            processID: 1
        )
        try check(
            failedIndex.diagnosticOmittingStdout
                == "index command refused"
                && !failedIndex.diagnosticOmittingStdout
                    .contains(leakedName),
            "complete index failure leaked ordinary stdout"
        )

        let advertised = String(repeating: "a", count: 40)
        let exact = DefaultBranchRelation(
            kind: .equal,
            aheadCount: 0,
            behindCount: 0
        )
        let missing =
            RepositoryReadSession
                .classifyCachedRelation(
                    trackingOID: nil,
                    advertisedOID: advertised
                ) {
                    exact
                }
        let stale =
            RepositoryReadSession
                .classifyCachedRelation(
                    trackingOID:
                        String(repeating: "b", count: 40),
                    advertisedOID: advertised
                ) {
                    exact
                }
        let current =
            RepositoryReadSession
                .classifyCachedRelation(
                    trackingOID: advertised,
                    advertisedOID: advertised
                ) {
                    exact
                }
        try check(
            missing == .unavailable
                && stale
                    == .remoteChangedSinceLastFetch
                && stale.operatorLabel
                    == "Remote changed since last fetch · exact comparison pending"
                && current == exact,
            "cached relation presentation states were not conservative and distinct"
        )
        onPass("BETA-V08-BOUNDED-INVENTORY")
    }

    public static func runDeviceDriftOnly(
        onPass: (String) -> Void = { _ in }
    ) throws {
        let prepared = try preparedFixture(
            defaultBranch: "main",
            state: .equal
        )
        defer { prepared.fixture.remove() }
        let clone = try makeOperation(prepared)
            .target.canonicalClone
        let current = RepositoryAuthorityRecord(clone: clone)
        func record(
            rootDevice: UInt64? = nil,
            rootInode: UInt64? = nil,
            commonDevice: UInt64? = nil,
            commonInode: UInt64? = nil,
            path: String? = nil,
            repositoryID: String? = nil
        ) throws -> RepositoryAuthorityRecord {
            let object: [String: Any] = [
                "repositoryID": repositoryID
                    ?? current.repositoryID,
                "canonicalRoot": path
                    ?? current.canonicalRoot,
                "rootIdentity": [
                    "device": rootDevice
                        ?? current.rootIdentity.device,
                    "inode": rootInode
                        ?? current.rootIdentity.inode,
                ],
                "commonDirectoryIdentity": [
                    "device": commonDevice
                        ?? current.commonDirectoryIdentity.device,
                    "inode": commonInode
                        ?? current.commonDirectoryIdentity.inode,
                ],
                "updatedAt": current.updatedAt,
            ]
            return try JSONDecoder().decode(
                RepositoryAuthorityRecord.self,
                from: JSONSerialization.data(
                    withJSONObject: object
                )
            )
        }
        let deviceOnly = try record(
            rootDevice: current.rootIdentity.device + 1,
            commonDevice:
                current.commonDirectoryIdentity.device + 1
        )
        try check(
            deviceOnly.matchesExceptDevice(clone),
            "device-only drift was not classified"
        )
        for unsafe in [
            try record(
                rootDevice: current.rootIdentity.device + 1,
                rootInode: current.rootIdentity.inode + 1
            ),
            try record(
                commonDevice:
                    current.commonDirectoryIdentity.device + 1,
                commonInode:
                    current.commonDirectoryIdentity.inode + 1
            ),
            try record(
                rootDevice: current.rootIdentity.device + 1,
                path: current.canonicalRoot + "-other"
            ),
            try record(
                rootDevice: current.rootIdentity.device + 1,
                repositoryID: "other/repository"
            ),
        ] {
            try check(
                !unsafe.matchesExceptDevice(clone),
                "non-device authority drift was accepted"
            )
        }
        let policyDrift = try LocalClone(
            repositoryID: clone.repositoryID,
            sourceSnapshot: clone.sourceSnapshot,
            effectiveOrigin: clone.effectiveOrigin,
            originParityVerified: clone.originParityVerified,
            policyCategory: .reference,
            kind: clone.kind,
            worktrees: clone.worktrees,
            branches: clone.branches,
            warnings: []
        )
        let topologyDrift = try LocalClone(
            repositoryID: clone.repositoryID,
            sourceSnapshot: clone.sourceSnapshot,
            effectiveOrigin: clone.effectiveOrigin,
            originParityVerified: clone.originParityVerified,
            policyCategory: clone.policyCategory,
            kind: clone.kind,
            worktrees: clone.worktrees,
            branches: clone.branches,
            warnings: ["topology changed"]
        )
        try check(
            !deviceOnly.matchesExceptDevice(policyDrift)
                && !deviceOnly.matchesExceptDevice(topologyDrift),
            "policy or topology drift was accepted"
        )

        let store = RepositoryAuthorityStore(
            state: try SecureStateDirectory.open(
                prepared.fixture.stateLocation
            )
        )
        _ = try store.confirmCanonicalRoot(
            clone: clone,
            freshClones: [clone],
            expectedFileIdentity: nil
        )
        func install(_ authorityRecord: RepositoryAuthorityRecord)
            throws {
            let document = try RepositoryAuthorityDocument(
                revision: (store.snapshot().document?.revision ?? 0) + 1,
                records: [authorityRecord]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted, .sortedKeys,
                .withoutEscapingSlashes,
            ]
            var bytes = try encoder.encode(document)
            bytes.append(0x0A)
            let path = prepared.fixture.stateLocation.path
                + "/" + RepositoryAuthorityStore.filename
            try bytes.write(
                to: URL(fileURLWithPath: path),
                options: .atomic
            )
            _ = chmod(path, 0o600)
        }
        try install(deviceOnly)
        let driftSnapshot = store.snapshot()
        let refreshed = try store.refreshSelectedDeviceDrift(
            selectedRepositoryIDs: [clone.repositoryID],
            freshClones: [clone],
            expectedFileIdentity: driftSnapshot.fileIdentity
        )
        try check(
            refreshed.usableRecords.count == 1
                && refreshed.usableRecords[0].matches(clone),
            "device-only authority was not refreshed"
        )

        try install(deviceOnly)
        let stale = store.snapshot()
        try install(deviceOnly)
        do {
            _ = try store.refreshSelectedDeviceDrift(
                selectedRepositoryIDs: [clone.repositoryID],
                freshClones: [clone],
                expectedFileIdentity: stale.fileIdentity
            )
            throw DM2Body1SelfTestError.testFailed(
                "device drift CAS",
                "stale authority identity was accepted"
            )
        } catch RepositoryAuthorityStoreError.changed {
            // Expected.
        }
        onPass("BETA-V02-DEVICE-DRIFT")
    }

    public static func runBetaV06(
        testExecutable: String,
        onPass: (String) -> Void = { _ in }
    ) throws {
        try testCheckedOutTargets(
            testExecutable: testExecutable
        )
        onPass(
            "BETA-V06-CHECKED-OUT-ADMISSION"
        )
    }

    private static func testIdentityAuthority() throws {
        let ssh = try require(
            GitHubIdentity.parse(
                "git@github.com:Fixture-Owner/Fixture-Repo.git"
            ),
            "SSH origin did not normalize"
        )
        let https = try require(
            GitHubIdentity.parse(
                "https://github.com/fixture-owner/fixture-repo"
            ),
            "HTTPS origin did not normalize"
        )
        try check(
            ssh.canonicalName == "fixture-owner/fixture-repo"
                && ssh.canonicalName == https.canonicalName,
            "origin identity was not repository-centric"
        )
        try check(
            GitHubIdentity.parse(
                "https://token@github.com/fixture-owner/fixture-repo"
            ) == nil,
            "credential-bearing origin was accepted"
        )

        let first = try preparedFixture(
            defaultBranch: "main",
            state: .equal
        )
        defer { first.fixture.remove() }
        let second = try preparedFixture(
            defaultBranch: "main",
            state: .equal
        )
        defer { second.fixture.remove() }
        let firstOperation = try makeOperation(first)
        let secondOperation = try makeOperation(second)
        let firstClone = firstOperation.target.canonicalClone
        let secondClone = secondOperation.target.canonicalClone
        try check(
            firstClone.id != secondClone.id
                && firstClone.repositoryID == secondClone.repositoryID,
            "independent common-directory clones collapsed identity"
        )

        let unclaimed = try Branch(
            cloneID: firstClone.id,
            fullRef: "refs/heads/unclaimed",
            tipOID: first.localOID,
            claimingWorktreeIDs: []
        )
        let multiplyClaimed = try Branch(
            cloneID: firstClone.id,
            fullRef: "refs/heads/multiply-claimed",
            tipOID: first.localOID,
            claimingWorktreeIDs: [
                "worktree:fixture:a",
                "worktree:fixture:b",
            ]
        )
        try check(
            unclaimed.claimingWorktreeIDs.isEmpty
                && multiplyClaimed.claimingWorktreeIDs.count == 2,
            "zero-to-many branch claims were not preserved"
        )

        let dev = RepositoryCandidate(
            id: "fixture-owner/dev",
            displayName: "dev",
            path: first.fixture.account.homeDirectory + "/dev",
            rawOrigin: "git@github.com:fixture-owner/dev.git",
            presentationLocation: "~/dev",
            blockedReason: .excludedByPolicy
        )
        let protected = RepositoryCandidate(
            id: "fixture-owner/protected-product",
            displayName: "protected-product",
            path: first.fixture.account.homeDirectory
                + "/dev/products/protected-product",
            rawOrigin:
                "git@github.com:fixture-owner/protected-product.git",
            blockedReason: .permanentNoTouch
        )
        let reference = RepositoryCandidate(
            id: "fixture/reference",
            displayName: "reference",
            path: first.fixture.account.homeDirectory
                + "/dev/reference/vendor/reference",
            rawOrigin: "git@github.com:fixture/reference.git",
            blockedReason: .readOnlyReference
        )
        try check(
            RepositoryInventoryDiscovery.testingPolicyCategory(dev)
                == .writable,
            "~/dev inherited an update ban"
        )
        try check(
            RepositoryInventoryDiscovery.testingPolicyCategory(protected)
                == .permanentNoTouch,
            "policy-protected repository lost permanent no-touch"
        )
        // A stale writable presentation cannot override the source's protected
        // role. Use a disposable fixture and change only its policy evidence.
        let sourceBytes = try JSONEncoder().encode(firstClone.sourceSnapshot)
        var sourceObject = try JSONSerialization.jsonObject(with: sourceBytes) as! [String: Any]
        sourceObject["blockedReason"] = RepositoryBlockReason.permanentNoTouch.rawValue
        let protectedSource = try JSONDecoder().decode(RepositoryCandidate.self,
            from: JSONSerialization.data(withJSONObject: sourceObject))
        try check(!protectedSource.isEligible
            && RepositoryInventoryDiscovery.testingPolicyCategory(protectedSource) == .permanentNoTouch,
            "protected source accepted as eligible after serialization")
        let staleWritableClone = try LocalClone(
            repositoryID: firstClone.repositoryID,
            sourceSnapshot: protectedSource,
            effectiveOrigin: firstClone.effectiveOrigin,
            originParityVerified: firstClone.originParityVerified,
            policyCategory: .writable,
            kind: firstClone.kind,
            worktrees: firstClone.worktrees,
            branches: firstClone.branches + [unclaimed],
            warnings: []
        )
        let protectedRemoval = try RemovalCandidate(repository: firstOperation.target.repository,
            clone: staleWritableClone, branch: unclaimed)
        try check(protectedRemoval.hardExclusion != nil && !protectedRemoval.canSelect,
            "writable presentation bypassed protected removal exclusion")
        try check(
            RepositoryInventoryDiscovery.testingPolicyCategory(reference)
                == .reference,
            "reference/vendor policy lost read-only classification"
        )

        let state = try SecureStateDirectory.open(
            first.fixture.stateLocation
        )
        let store = RepositoryAuthorityStore(state: state)
        let absent = store.snapshot()
        try check(
            absent.status == .absent
                && absent.fileIdentity == nil,
            "new authority store was not absent"
        )
        let proposals = [
            CanonicalAuthorityProposal(clone: firstClone),
            CanonicalAuthorityProposal(clone: secondClone),
        ]
        let noChange = try store.confirmOnboarding(
            proposals: proposals,
            selectedRepositoryIDs: [],
            freshClones: [firstClone, secondClone],
            expectedFileIdentity: nil
        )
        try check(
            noChange == .noChange
                && !noChange.didPersistChange
                && store.snapshot().status == .absent,
            "cancel/deselect was classified as persisted canonical authority"
        )
        try check(
            throwsError {
                _ = try store.confirmOnboarding(
                    proposals: [proposals[0]],
                    selectedRepositoryIDs: [firstClone.repositoryID],
                    freshClones: [firstClone, secondClone],
                    expectedFileIdentity: nil
                )
            },
            "ambiguous writable clones gained authority"
        )
        try FileManager.default.moveItem(
            atPath: first.fixture.repositoryPath,
            toPath: first.fixture.repositoryPath + "-moved"
        )
        try check(
            throwsError {
                _ = try store.confirmOnboarding(
                    proposals: [proposals[0]],
                    selectedRepositoryIDs: [firstClone.repositoryID],
                    freshClones: [firstClone],
                    expectedFileIdentity: nil
                )
            } && store.snapshot().status == .absent,
            "stale canonical-root race wrote authority"
        )
        try check(
            LegacyRunPresentation.label
                == "Legacy run — clone-based model",
            "v1 run label changed"
        )
        let legacy = RunReport(
            run: RunIdentity.make(),
            startedAt: WallClock.timestamp(),
            endedAt: WallClock.timestamp(),
            cancelled: false,
            results: []
        )
        try check(
            LegacyRunPresentation.isLegacy(legacy),
            "clone-based run was promoted to a v2 operation record"
        )

        // Phase-invariant — commitOnboarding path (DM2-T01).
        // Proves that the authority write commits to disk before any
        // post-write rediscovery runs, so a refresh failure cannot be
        // reported as "not changed" and recovery never issues a second write.
        let phaseOnboard = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/phase-onboard"
        )
        defer { phaseOnboard.fixture.remove() }
        let phaseOnboardClone =
            try makeOperation(phaseOnboard).target.canonicalClone
        let phaseOnboardStore = try RepositoryAuthorityStore.open(
            at: phaseOnboard.fixture.stateLocation
        )
        let phaseOnboardProposal = CanonicalAuthorityProposal(
            clone: phaseOnboardClone
        )
        let phaseOnboardCommit =
            try phaseOnboardStore.confirmOnboarding(
                proposals: [phaseOnboardProposal],
                selectedRepositoryIDs: [phaseOnboardClone.repositoryID],
                freshClones: [phaseOnboardClone],
                expectedFileIdentity: nil
            )
        let afterOnboardWrite = phaseOnboardStore.snapshot()
        let afterOnboardIdentity = try require(
            afterOnboardWrite.fileIdentity,
            "phase-onboard: authority file identity absent after write"
        )
        // Committed selection is durable regardless of post-write discovery outcome.
        try check(
            phaseOnboardCommit.didPersistChange
                && afterOnboardWrite.status == .available
                && afterOnboardWrite.usableRecords.count == 1
                && afterOnboardWrite.usableRecords[0].repositoryID
                    == phaseOnboardClone.repositoryID,
            "phase-onboard: committed selection absent from authority file"
        )
        // Simulated post-write refresh failure: file identity unchanged (no second write).
        try check(
            phaseOnboardStore.snapshot().fileIdentity == afterOnboardIdentity,
            "phase-onboard: simulated refresh failure altered authority file"
        )
        // Recovery path: a second confirmOnboarding with wrong expectedFileIdentity
        // (nil when file exists) throws — proving the recovery path cannot
        // inadvertently re-write.
        try check(
            throwsError {
                _ = try phaseOnboardStore.confirmOnboarding(
                    proposals: [phaseOnboardProposal],
                    selectedRepositoryIDs: [phaseOnboardClone.repositoryID],
                    freshClones: [phaseOnboardClone],
                    expectedFileIdentity: nil
                )
            },
            "phase-onboard: recovery accepted inadvertent second write"
        )
        try check(
            phaseOnboardStore.snapshot().fileIdentity == afterOnboardIdentity,
            "phase-onboard: rejected second write altered authority file"
        )
        // Later read converges to the persisted authority.
        try check(
            phaseOnboardStore.snapshot().usableRecords.first?.repositoryID
                == phaseOnboardClone.repositoryID,
            "phase-onboard: later read did not converge to persisted authority"
        )

        // Phase-invariant — commitCanonicalRoot path (DM2-T01).
        let phaseRoot = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/phase-root"
        )
        defer { phaseRoot.fixture.remove() }
        let phaseRootClone =
            try makeOperation(phaseRoot).target.canonicalClone
        let phaseRootStore = try RepositoryAuthorityStore.open(
            at: phaseRoot.fixture.stateLocation
        )
        _ = try phaseRootStore.confirmCanonicalRoot(
            clone: phaseRootClone,
            freshClones: [phaseRootClone],
            expectedFileIdentity: nil
        )
        let afterRootWrite = phaseRootStore.snapshot()
        let afterRootIdentity = try require(
            afterRootWrite.fileIdentity,
            "phase-root: authority file identity absent after write"
        )
        try check(
            afterRootWrite.status == .available
                && afterRootWrite.usableRecords.count == 1
                && afterRootWrite.usableRecords[0].repositoryID
                    == phaseRootClone.repositoryID,
            "phase-root: committed selection absent from authority file"
        )
        try check(
            phaseRootStore.snapshot().fileIdentity == afterRootIdentity,
            "phase-root: simulated refresh failure altered authority file"
        )
        try check(
            throwsError {
                _ = try phaseRootStore.confirmCanonicalRoot(
                    clone: phaseRootClone,
                    freshClones: [phaseRootClone],
                    expectedFileIdentity: nil
                )
            },
            "phase-root: recovery accepted inadvertent second write"
        )
        try check(
            phaseRootStore.snapshot().fileIdentity == afterRootIdentity,
            "phase-root: rejected second write altered authority file"
        )
        try check(
            phaseRootStore.snapshot().usableRecords.first?.repositoryID
                == phaseRootClone.repositoryID,
            "phase-root: later read did not converge to persisted authority"
        )
    }

    private static func testRemoteDefaults(
        testExecutable: String
    ) throws {
        for name in ["main", "master", "develop", "next"] {
            let fixture = try preparedFixture(
                defaultBranch: name,
                state: .behind
            )
            defer { fixture.fixture.remove() }
            let operation = try makeOperation(fixture)
            let execution = try execute(
                fixture,
                operation: operation,
                executable: testExecutable
            )
            try check(
                execution.result.code == .updated
                    && execution.result.defaultBranch == name
                    && execution.result.afterCommit
                        == fixture.remoteOID,
                "\(name) default did not Fast-forward: "
                    + execution.result.code.rawValue + " "
                    + (execution.result.technicalDetail ?? "")
            )
            let fetches = execution.audit.invocations.filter {
                $0.arguments.contains("fetch")
            }
            try check(
                fetches.count == 1,
                "\(name) issued an unexpected fetch count"
            )
            let fetch = fetches[0].arguments
            for required in [
                "--porcelain",
                "--verbose",
                "--no-write-fetch-head",
                "--no-tags",
                "--no-prune",
                "--no-recurse-submodules",
                "--no-auto-maintenance",
                "refs/heads/\(name):refs/remotes/origin/\(name)",
            ] {
                try check(
                    fetch.contains(required),
                    "\(name) fetch omitted \(required)"
                )
            }
            try check(
                !fetch.contains(
                    "+refs/heads/\(name):refs/remotes/origin/\(name)"
                ),
                "\(name) fetch forced the tracking ref"
            )
        }

        let oid = String(repeating: "a", count: 40)
        for name in ["main", "master", "develop", "next"] {
            let parsed = try RemoteDefaultResolver.parse(
                Data(
                    """
                    ref: refs/heads/\(name)\tHEAD
                    \(oid)\tHEAD
                    """.utf8
                )
            )
            try check(
                parsed.name == name && parsed.advertisedOID == oid,
                "\(name) symbolic HEAD was not parsed"
            )
        }
        for malformed in [
            "\(oid)\tHEAD\n",
            "ref: refs/tags/main\tHEAD\n\(oid)\tHEAD\n",
            "ref: refs/heads/main\tHEAD\nnot-an-oid\tHEAD\n",
            "ref: refs/heads/main\tHEAD\n"
                + "ref: refs/heads/next\tHEAD\n\(oid)\tHEAD\n",
        ] {
            try check(
                throwsError {
                    _ = try RemoteDefaultResolver.parse(
                        Data(malformed.utf8)
                    )
                },
                "missing, detached, or malformed remote HEAD was accepted"
            )
        }
        for forbidden in [
            ["--no-replace-objects", "checkout", "main"],
            ["--no-replace-objects", "reset", "--hard"],
            ["--no-replace-objects", "stash"],
            ["--no-replace-objects", "pull"],
            ["--no-replace-objects", "push", "origin", "main"],
            [
                "--no-replace-objects", "update-ref",
                "refs/heads/main", oid,
            ],
            ["--no-replace-objects", "fetch", "origin"],
        ] {
            try check(
                throwsError {
                    _ = try GitCommandPolicy.validate(forbidden)
                },
                "forbidden Git grammar entered Body 1"
            )
        }

        let changed = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { changed.fixture.remove() }
        let changedOperation = try makeOperation(changed)
        _ = try M1GitFixture.runGit([
            "--git-dir", changed.fixture.remotePath,
            "update-ref", "refs/heads/next", changed.remoteOID,
        ])
        _ = try M1GitFixture.runGit([
            "--git-dir", changed.fixture.remotePath,
            "symbolic-ref", "HEAD", "refs/heads/next",
        ])
        let changedExecution = try execute(
            changed,
            operation: changedOperation,
            executable: testExecutable
        )
        try check(
            changedExecution.result.code == .failedInspection
                && !changedExecution.result.mainUpdated
                && !changedExecution.audit.invocations.contains {
                    $0.arguments.contains("fetch")
                },
            "changed remote default was not refused before fetch"
        )
    }

    private static func testCheckedOutTargets(
        testExecutable: String
    ) throws {
        let equal = try preparedFixture(
            defaultBranch: "main",
            state: .equal
        )
        defer { equal.fixture.remove() }
        let equalExecution = try execute(
            equal,
            operation: try makeOperation(equal),
            executable: testExecutable
        )
        try check(
            equalExecution.result.code == .alreadyCurrent
                && equalExecution.result.fetched
                && !equalExecution.result.mainUpdated
                && !equalExecution.audit.invocations.contains {
                    $0.arguments.contains("merge")
                },
            "Equal did not remain a verified no-op"
        )

        for (
            state,
            expectedCode,
            expectedUpdate
        ): (FixtureState, ResultCode, Bool) in [
            (.equal, .alreadyCurrent, false),
            (.behind, .updated, true),
            (.ahead, .skippedAhead, false),
            (.diverged, .skippedDiverged, false),
        ] {
            let unknownPreview = try preparedFixture(
                defaultBranch: "main",
                state: state
            )
            defer { unknownPreview.fixture.remove() }
            let operation = try makeOperation(
                unknownPreview,
                previewRelation: .unavailable
            )
            let before = try oid(unknownPreview)
            let execution = try execute(
                unknownPreview,
                operation: operation,
                executable: testExecutable
            )
            let after = try oid(unknownPreview)
            try check(
                operation.isSelectable
                    && execution.result.code == expectedCode
                    && execution.result.fetched
                    && execution.result.mainUpdated
                        == expectedUpdate
                    && (
                        expectedUpdate
                            ? after == unknownPreview.remoteOID
                            : after == before
                    ),
                "unavailable checked-out preview did not defer \(state) classification to execution: "
                    + execution.result.code.rawValue + " "
                    + (
                        execution.result.technicalDetail
                            ?? execution.result.explanation
                    )
            )
        }

        let dirtyTarget = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { dirtyTarget.fixture.remove() }
        try Data("preserve target change\n".utf8).write(
            to: URL(fileURLWithPath:
                dirtyTarget.fixture.repositoryPath
                    + "/untracked-target.txt"
            )
        )
        let dirtyExecution = try execute(
            dirtyTarget,
            operation: try makeOperation(dirtyTarget),
            executable: testExecutable
        )
        try check(
            dirtyExecution.result.code == .skippedDirty
                && !dirtyExecution.result.mainUpdated
                && !dirtyExecution.audit.invocations.contains {
                    $0.arguments.contains("fetch")
                        || $0.arguments.contains("merge")
                }
                && FileManager.default.fileExists(
                    atPath: dirtyTarget.fixture.repositoryPath
                        + "/untracked-target.txt"
                ),
            "dirty default-branch target mutated or reached fetch"
        )

        let hiddenTarget = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { hiddenTarget.fixture.remove() }
        try hiddenTarget.fixture.git([
            "update-index", "--skip-worktree", "value.txt",
        ])
        let hiddenExecution = try execute(
            hiddenTarget,
            operation: try makeOperation(hiddenTarget),
            executable: testExecutable
        )
        try check(
            hiddenExecution.result.code == .skippedHiddenIndexState
                && !hiddenExecution.result.mainUpdated
                && !hiddenExecution.audit.invocations.contains {
                    $0.arguments.contains("fetch")
                        || $0.arguments.contains("merge")
                },
            "hidden target index state reached mutation"
        )

        let ahead = try preparedFixture(
            defaultBranch: "main",
            state: .ahead
        )
        defer { ahead.fixture.remove() }
        let aheadExecution = try execute(
            ahead,
            operation: try makeOperation(ahead),
            executable: testExecutable
        )
        let observedAhead = try oid(ahead)
        try check(
            aheadExecution.result.code == .skippedAhead
                && !aheadExecution.result.mainUpdated
                && observedAhead == ahead.localOID,
            "Ahead mutated or lost exact refusal"
        )

        let diverged = try preparedFixture(
            defaultBranch: "main",
            state: .diverged
        )
        defer { diverged.fixture.remove() }
        let divergedExecution = try execute(
            diverged,
            operation: try makeOperation(diverged),
            executable: testExecutable
        )
        let observedDiverged = try oid(diverged)
        try check(
            divergedExecution.result.code == .skippedDiverged
                && !divergedExecution.result.mainUpdated
                && observedDiverged == diverged.localOID,
            "Diverged mutated or lost exact refusal"
        )

        let staleUnrelated = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { staleUnrelated.fixture.remove() }
        let staleUnrelatedPath =
            staleUnrelated.fixture.rootPath
                + "/stale-unrelated-feature"
        try staleUnrelated.fixture.git([
            "branch", "stale-unrelated-feature",
        ])
        try staleUnrelated.fixture.git([
            "worktree", "add", "--quiet",
            staleUnrelatedPath,
            "stale-unrelated-feature",
        ])
        try FileManager.default.removeItem(
            atPath: staleUnrelatedPath
        )
        let staleUnrelatedExecution = try execute(
            staleUnrelated,
            operation: try makeOperation(
                staleUnrelated,
                previewRelation: .unavailable
            ),
            executable: testExecutable
        )
        let staleUnrelatedOID = try oid(
            staleUnrelated
        )
        try check(
            staleUnrelatedExecution.result.code == .updated
                && staleUnrelatedExecution.result.mainUpdated
                && staleUnrelatedOID
                    == staleUnrelated.remoteOID,
            "unrelated stale non-default registration vetoed the exact default target: "
                + staleUnrelatedExecution.result.code.rawValue
                + " "
                + (
                    staleUnrelatedExecution.result
                        .technicalDetail
                        ?? staleUnrelatedExecution.result
                            .explanation
                )
        )

        let linked = try preparedLinkedTarget()
        defer { linked.fixture.remove() }
        try Data("dirty unrelated feature\n".utf8).write(
            to: URL(fileURLWithPath: linked.fixture.repositoryPath)
                .appendingPathComponent("untracked-feature.txt")
        )
        let linkedOperation = try operationWithStaleSource(
            makeOperation(
                linked,
                worktreePath: linked.targetWorktreePath,
                candidate: linked.candidate
            )
        )
        try check(
            linkedOperation.target.canonicalClone
                .sourceSnapshot.linkedWorktrees.isEmpty
                && linkedOperation.target.canonicalClone
                    .worktrees.contains {
                        $0.path
                            == linked.targetWorktreePath
                    },
            "linked Fast-forward fixture did not reproduce stale source metadata"
        )
        let linkedExecution = try execute(
            linked,
            operation: linkedOperation,
            executable: testExecutable
        )
        try check(
            linkedExecution.result.code == .updated
                && linkedExecution.result.afterCommit
                    == linked.remoteOID,
            "linked/external target was blocked by unrelated dirty feature context: "
                + linkedExecution.result.code.rawValue + " "
                + (linkedExecution.result.technicalDetail ?? "")
        )
        try check(
            try oid(linked, at: linked.targetWorktreePath)
                == linked.remoteOID,
            "linked default-branch worktree did not update"
        )

        let linkedDrift = try preparedLinkedTarget()
        defer { linkedDrift.fixture.remove() }
        let linkedDriftOperation =
            try operationWithStaleSource(
                makeOperation(
                    linkedDrift,
                    worktreePath:
                        linkedDrift.targetWorktreePath,
                    candidate: linkedDrift.candidate
                )
            )
        let linkedDriftBefore = String(
            decoding: try linkedDrift.fixture.gitOutput([
                "rev-parse", "refs/heads/main",
            ]),
            as: UTF8.self
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try Data(
            (
                "gitdir: "
                + linkedDrift.fixture.repositoryPath
                + "/.git\n"
            ).utf8
        ).write(
            to: URL(
                fileURLWithPath:
                    linkedDrift.targetWorktreePath
                    + "/.git"
            )
        )
        let linkedDriftExecution = try execute(
            linkedDrift,
            operation: linkedDriftOperation,
            executable: testExecutable
        )
        try check(
            linkedDriftExecution.result.code
                == .failedInspection
                && linkedDriftExecution.result.mainUpdated
                    == false
                && String(
                    decoding:
                        try linkedDrift.fixture.gitOutput([
                            "rev-parse", "refs/heads/main",
                        ]),
                    as: UTF8.self
                ).trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) == linkedDriftBefore,
            "fresh linked-worktree marker drift was not refused before mutation"
        )

        let duplicate = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { duplicate.fixture.remove() }
        let ordinary = try makeOperation(duplicate)
        let clone = ordinary.target.canonicalClone
        let duplicateBranch = try Branch(
            cloneID: clone.id,
            fullRef: ordinary.target.resolvedDefault.localRef,
            tipOID: duplicate.localOID,
            claimingWorktreeIDs: [
                clone.worktrees[0].id,
                "worktree:duplicate:claim",
            ]
        )
        let duplicateClone = try LocalClone(
            repositoryID: clone.repositoryID,
            sourceSnapshot: clone.sourceSnapshot,
            effectiveOrigin: clone.effectiveOrigin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: clone.worktrees,
            branches: [duplicateBranch],
            warnings: []
        )
        try check(
            throwsError {
                _ = try DefaultBranchUpdateTarget(
                    repository: ordinary.target.repository,
                    canonicalClone: duplicateClone,
                    resolvedDefault:
                        ordinary.target.resolvedDefault,
                    expectedLocalOID: duplicate.localOID,
                    expectedFetchedOID: duplicate.remoteOID,
                    mode: .checkedOut,
                    worktreeID: clone.worktrees[0].id,
                    relation: relation(for: .behind)
                )
            },
            "duplicate default claims produced an operation"
        )

        let forced = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { forced.fixture.remove() }
        let duplicateRoot = forced.fixture.rootPath
            + "/forced-duplicate-claim"
        try forced.fixture.git([
            "worktree", "add", "--quiet", "--detach",
            duplicateRoot, forced.localOID,
        ])
        let worktreeAdmin = try require(
            try FileManager.default.contentsOfDirectory(
                atPath: forced.fixture.repositoryPath
                    + "/.git/worktrees"
            ).first,
            "forced duplicate registration is missing"
        )
        try Data("ref: refs/heads/main\n".utf8).write(
            to: URL(fileURLWithPath:
                forced.fixture.repositoryPath
                    + "/.git/worktrees/\(worktreeAdmin)/HEAD"
            )
        )
        let forcedCandidate = try candidateWithLinkedWorktrees(
            forced
        )
        let authority = try RunAuthority.acquireRun(
            at: forced.fixture.stateLocation
        )
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let forcedClone = try RepositoryReadSession(
            executablePath: testExecutable,
            leaseDescriptor: lease,
            account: forced.fixture.account,
            runner: DescriptorProcessRunner(),
            transportMapping: forced.fixture.mapping
        ).inspectClone(
            forcedCandidate,
            category: .writable
        )
        try check(
            forcedClone.branches.first {
                $0.fullRef == "refs/heads/main"
            }?.claimingWorktreeIDs.count == 2,
            "forced duplicate claims were collapsed or hidden"
        )
        let unavailableWorktree = try Worktree(
            id: "worktree:unavailable:claim",
            cloneID: clone.id,
            path: duplicate.fixture.rootPath + "/missing",
            rootIdentity: nil,
            registrationIdentity: nil,
            attachedBranchRef:
                ordinary.target.resolvedDefault.localRef,
            detachedOID: nil,
            isPrimary: false,
            locationKind: .external,
            verification: .unavailable,
            cleanliness: .unknown
        )
        try check(
            !unavailableWorktree.isVerifiedClean,
            "unknown claim became a mutable target"
        )
        let unknownClaimBranch = try Branch(
            cloneID: clone.id,
            fullRef: ordinary.target.resolvedDefault.localRef,
            tipOID: duplicate.localOID,
            claimingWorktreeIDs: [
                clone.worktrees[0].id,
                unavailableWorktree.id,
            ]
        )
        let unknownClaimClone = try LocalClone(
            repositoryID: clone.repositoryID,
            sourceSnapshot: clone.sourceSnapshot,
            effectiveOrigin: clone.effectiveOrigin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: clone.worktrees + [unavailableWorktree],
            branches: [unknownClaimBranch],
            warnings: []
        )
        try check(
            unknownClaimClone.isAuthorityEligible
                && throwsError {
                    _ = try DefaultBranchUpdateTarget(
                        repository: ordinary.target.repository,
                        canonicalClone: unknownClaimClone,
                        resolvedDefault:
                            ordinary.target.resolvedDefault,
                        expectedLocalOID: duplicate.localOID,
                        expectedFetchedOID: duplicate.remoteOID,
                        mode: .checkedOut,
                        worktreeID: clone.worktrees[0].id,
                        relation: relation(for: .behind)
                    )
                },
            "unknown claim escaped its Fast-forward-only refusal boundary"
        )

        let claimRace = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { claimRace.fixture.remove() }
        let claimRaceRoot = claimRace.fixture.rootPath
            + "/claim-race-worktree"
        try claimRace.fixture.git([
            "worktree", "add", "--quiet", "--detach",
            claimRaceRoot, claimRace.localOID,
        ])
        let claimRaceCandidate = try candidateWithLinkedWorktrees(
            claimRace
        )
        let claimRaceAdmin = try require(
            try FileManager.default.contentsOfDirectory(
                atPath: claimRace.fixture.repositoryPath
                    + "/.git/worktrees"
            ).first,
            "claim-race registration is missing"
        )
        let claimRaceHEAD = claimRace.fixture.repositoryPath
            + "/.git/worktrees/\(claimRaceAdmin)/HEAD"
        let claimRaced = try execute(
            claimRace,
            operation: try makeOperation(
                claimRace,
                candidate: claimRaceCandidate
            ),
            executable: testExecutable,
            afterFetchCapture: { _, _ in
                try? Data("ref: refs/heads/main\n".utf8).write(
                    to: URL(fileURLWithPath: claimRaceHEAD)
                )
            }
        )
        try check(
            claimRaced.result.code == .failedInspection
                && !claimRaced.audit.invocations.contains {
                    $0.arguments.contains("merge")
                },
            "default-branch claim race reached merge"
        )

        let configRace = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { configRace.fixture.remove() }
        let config = configRace.fixture.repositoryPath
            + "/.git/config"
        let raced = try execute(
            configRace,
            operation: try makeOperation(configRace),
            executable: testExecutable,
            afterPreflight: { _ in
                guard let handle = try? FileHandle(
                    forWritingTo: URL(fileURLWithPath: config)
                ) else { return }
                _ = try? handle.seekToEnd()
                try? handle.write(
                    contentsOf: Data("\n# DM2 config race\n".utf8)
                )
                try? handle.close()
            }
        )
        try check(
            raced.result.code == .failedInspection
                && !raced.audit.invocations.contains {
                    $0.arguments.contains("fetch")
                },
            "config race reached fetch"
        )

        let refRace = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { refRace.fixture.remove() }
        let refRacePath = refRace.fixture.repositoryPath
        let refRaceTarget = refRace.remoteOID
        let refRaced = try execute(
            refRace,
            operation: try makeOperation(refRace),
            executable: testExecutable,
            afterFetchCapture: { _, _ in
                _ = try? M1GitFixture.runGit([
                    "-C", refRacePath,
                    "update-ref", "refs/heads/main",
                    refRaceTarget,
                ])
            }
        )
        try check(
            refRaced.result.code == .failedInspection
                && !refRaced.audit.invocations.contains {
                    $0.arguments.contains("merge")
                },
            "ref race reached merge"
        )

        let policyRace = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { policyRace.fixture.remove() }
        let calls = DM2CallCounter()
        let policyRaced = try execute(
            policyRace,
            operation: try makeOperation(policyRace),
            executable: testExecutable,
            runtimeEligibilityCheck: { _ in
                if calls.increment() >= 5 {
                    throw GitSafetyError.unsafeRepository(
                        "policy changed"
                    )
                }
            }
        )
        try check(
            policyRaced.result.code == .failedInspection
                && !policyRaced.result.mainUpdated,
            "policy race was not refused"
        )

        let journey = try preparedFixture(
            defaultBranch: "develop",
            state: .behind,
            fixturePolicyDigest: String(repeating: "a", count: 64)
        )
        defer { journey.fixture.remove() }
        let journeyCard = try card(for: journey)
        let journeyClone = try require(
            journeyCard.clones.first,
            "journey clone is missing"
        )
        let journeyState = try SecureStateDirectory.open(
            journey.fixture.stateLocation
        )
        let journeyAuthority = RepositoryAuthorityStore(
            state: journeyState
        )
        _ = try journeyAuthority.confirmOnboarding(
            proposals: [
                CanonicalAuthorityProposal(clone: journeyClone),
            ],
            selectedRepositoryIDs: [journeyClone.repositoryID],
            freshClones: [journeyClone],
            expectedFileIdentity: nil
        )
        try check(
            journeyAuthority.snapshot().usableRecords.first?
                .matches(journeyClone) == true,
            "journey onboarding did not persist canonical authority"
        )
        let selected = RepositoryInventorySelection.selectAll(
            RepositoryInventory(
                cards: [journeyCard],
                onboardingProposals: [],
                authorityFileIdentity: nil
            )
        )
        let coordinator = RunCoordinator(
            configuration: CoordinatorConfiguration(
                stateLocation: journey.fixture.stateLocation,
                trampolineExecutable: testExecutable,
                transportMapping: journey.fixture.mapping,
                governedRootRole: .testing(policyDigest:
                    selected[0].target.canonicalClone.sourceSnapshot.policyAdmissionSHA256 ?? "missing")
            ),
            account: journey.fixture.account
        )
        let report = try coordinator.run(
            runID: RunIdentity.make(),
            operations: selected,
            cancellation: CancellationToken(),
            eventSink: { _ in }
        )
        try check(
            selected.count == 1
                && report.repositoryModel == "v2"
                && report.results.first?.code == .updated
                && report.results.first?.defaultBranch == "develop",
            "selection-to-report journey did not preserve the v2 operation"
        )

        let deferredDev = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/governed-root",
            fixturePolicyDigest: String(repeating: "a", count: 64)
        )
        defer { deferredDev.fixture.remove() }
        let peer = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "zeta-owner/report-order"
        )
        defer { peer.fixture.remove() }
        let devOperation = try makeOperation(deferredDev)
        let peerOperation = try makeOperation(peer)
        let plannedOperations = [devOperation, peerOperation]
        let executionOperations =
            V2OperationOrdering.executionOrder(plannedOperations, governedRoot: .testing())
        let otherRoleOrder = V2OperationOrdering.executionOrder(plannedOperations,
            governedRoot: .testing(repositoryID: "fixture-owner/unselected-root"))
        try check(otherRoleOrder.map(\.id) == plannedOperations.map(\.id),
                  "ordinary repository retained a hard-coded terminal role")
        do {
            _ = try RunCoordinator(configuration: CoordinatorConfiguration(
                stateLocation: deferredDev.fixture.stateLocation,
                trampolineExecutable: testExecutable), account: deferredDev.fixture.account)
                .run(runID: RunIdentity.make(), operations: [devOperation],
                     cancellation: CancellationToken(), eventSink: { _ in })
            throw DM2Body1SelfTestError.message("missing role started an operation")
        } catch SelectedRepositoryScopeError.policyUnavailable {}
        let staleRoleAudit = CommandAudit()
        let staleLogURL = URL(fileURLWithPath: deferredDev.fixture.stateLocation.path + "/latest.log")
        let staleLogBefore = try? Data(contentsOf: staleLogURL)
        do {
            _ = try RunCoordinator(configuration: CoordinatorConfiguration(
                stateLocation: deferredDev.fixture.stateLocation,
                trampolineExecutable: testExecutable,
                transportMapping: deferredDev.fixture.mapping,
                governedRootRole: .testing(policyDigest: String(repeating: "f", count: 64))),
                audit: staleRoleAudit, account: deferredDev.fixture.account)
                .run(runID: RunIdentity.make(), operations: [devOperation],
                     cancellation: CancellationToken(), eventSink: { _ in })
            throw DM2Body1SelfTestError.message("stale role started an operation")
        } catch SelectedRepositoryScopeError.policyUnavailable {}
        try check(staleRoleAudit.invocations.isEmpty
            && (try? Data(contentsOf: staleLogURL)) == staleLogBefore,
                  "stale role produced child work or a run log")
        let timestamp = WallClock.timestamp()
        let executionResults = executionOperations.map { operation in
            RepositoryResult(
                repository:
                    operation.target.canonicalClone.sourceSnapshot,
                operationID: operation.id,
                defaultBranch:
                    operation.target.resolvedDefault.name,
                code: .alreadyCurrent,
                fetched: true,
                mainUpdated: false,
                beforeCommit: operation.target.expectedLocalOID,
                targetCommit: operation.target.expectedFetchedOID,
                afterCommit: operation.target.expectedLocalOID,
                startedAt: timestamp,
                endedAt: timestamp,
                durationMilliseconds: 0,
                explanation:
                    "The checked-out default branch is already current."
            )
        }
        let reportResults = try V2OperationOrdering.reportOrder(
            executionResults: executionResults,
            plannedOperations: plannedOperations
        )
        try check(
            executionOperations.map(\.id)
                == [peerOperation.id, devOperation.id]
                && reportResults.compactMap(\.operationID)
                    == plannedOperations.map(\.id)
                && reportResults.map(\.repository)
                    == plannedOperations.map {
                        $0.target.canonicalClone.sourceSnapshot
                    },
            "deferred ~/dev execution lost planned report row order"
        )
    }

    private static func testHooks(
        testExecutable: String
    ) throws {
        let marker = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { marker.fixture.remove() }
        try FileManager.default.createDirectory(
            atPath: marker.fixture.repositoryPath + "/.husky",
            withIntermediateDirectories: false
        )
        let preCommit = marker.fixture.repositoryPath
            + "/.git/hooks/pre-commit"
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: preCommit
        )
        let postMerge = marker.fixture.repositoryPath
            + "/.git/hooks/post-merge"
        try writeExecutable(
            "#!/bin/sh\nprintf 'post-merge\\n' > hook-residue.txt\n",
            to: postMerge
        )
        let markerExecution = try execute(
            marker,
            operation: try makeOperation(marker),
            executable: testExecutable
        )
        try check(
            markerExecution.result.code == .updatedWithWarning
                && markerExecution.result.mainUpdated
                && FileManager.default.fileExists(
                    atPath: marker.fixture.repositoryPath
                        + "/hook-residue.txt"
                ),
            "marker-only hooks blocked execution or hook residue vanished"
        )

        let veto = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { veto.fixture.remove() }
        let hook = veto.fixture.repositoryPath
            + "/.git/hooks/reference-transaction"
        try writeExecutable(
            """
            #!/bin/sh
            input="$(cat)"
            case "$1" in
              prepared|preparing)
                if printf '%s\n' "$input" | /usr/bin/grep -q 'refs/heads/main$'; then
                  exit 1
                fi
                ;;
            esac
            exit 0
            """,
            to: hook
        )
        let vetoExecution = try execute(
            veto,
            operation: try makeOperation(veto),
            executable: testExecutable
        )
        let observedVeto = try oid(veto)
        try check(
            vetoExecution.result.code == .failedUpdate
                && vetoExecution.result.fetched
                && !vetoExecution.result.mainUpdated
                && observedVeto == veto.localOID,
            "reference-transaction veto was bypassed or mutated the target"
        )
    }

    private static func testRepositoryCards(
        testExecutable: String
    ) throws {
        let first = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        defer { first.fixture.remove() }
        let second = try preparedFixture(
            defaultBranch: "main",
            state: .equal
        )
        defer { second.fixture.remove() }
        let referenceFixture = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/reference-repo"
        )
        defer { referenceFixture.fixture.remove() }
        let operation = try makeOperation(first)
        let canonical = operation.target.canonicalClone
        let contextual = try makeOperation(second)
            .target.canonicalClone
        let warningClone = try LocalClone(
            repositoryID: contextual.repositoryID,
            sourceSnapshot: contextual.sourceSnapshot,
            effectiveOrigin: contextual.effectiveOrigin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: contextual.worktrees,
            branches: contextual.branches,
            warnings: [
                "A separate clone has operation-specific context."
            ]
        )
        let card = try RepositoryCard(
            repository: operation.target.repository,
            authority: CanonicalAuthorityState(
                status: .usable,
                record: RepositoryAuthorityRecord(
                    clone: canonical
                ),
                explanation: "Explicit canonical root."
            ),
            clones: [canonical, warningClone],
            relation: operation.target.relation,
            fastForward: operation,
            fastForwardRefusal: nil
        )
        let referenceBase = try makeOperation(referenceFixture)
            .target.canonicalClone
        let referenceClone = try LocalClone(
            repositoryID: referenceBase.repositoryID,
            sourceSnapshot: referenceBase.sourceSnapshot,
            effectiveOrigin: referenceBase.effectiveOrigin,
            originParityVerified: true,
            policyCategory: .reference,
            kind: .readOnlyReference,
            worktrees: referenceBase.worktrees,
            branches: referenceBase.branches,
            warnings: []
        )
        let referenceRemote = try RemoteRepository(
            id: referenceBase.repositoryID,
            origins: [referenceBase.rawOrigin],
            policyCategory: .reference,
            resolvedDefault:
                try RemoteDefaultBranch(
                    name: "main",
                    advertisedOID: referenceFixture.remoteOID
                ),
            defaultUnavailableReason: nil
        )
        let referenceCard = try RepositoryCard(
            repository: referenceRemote,
            authority: CanonicalAuthorityState(
                status: .notApplicable,
                record: nil,
                explanation: "Reference only."
            ),
            clones: [referenceClone],
            relation: relation(for: .equal),
            fastForward: nil,
            fastForwardRefusal: "Reference repositories are read-only."
        )
        let inventory = RepositoryInventory(
            cards: [card, referenceCard],
            onboardingProposals: [],
            authorityFileIdentity: nil
        )
        let selected = RepositoryInventorySelection.selectAll(
            inventory
        )
        try check(
            card.clones.count == 2
                && inventory.cards.count == 2
                && inventory.writableCards.count == 1
                && inventory.referenceCards.count == 1
                && selected == [operation],
            "card grouping, reference counts, or Select All changed"
        )
        try check(
            card.clones.filter(\.warnings.isEmpty).count == 1
                && card.clones.filter {
                    !$0.warnings.isEmpty
                }.count == 1,
            "operation warning escaped its owning clone/card"
        )
        try check(
            inventory.onboardingProposals.isEmpty,
            "Fast-forward Select All granted authority"
        )

        let discoveryJourney = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/discovery-card"
        )
        defer { discoveryJourney.fixture.remove() }
        try installDiscoveryPolicy(
            homeDirectory: discoveryJourney.fixture.account.homeDirectory
        )
        let largeIndexRoot =
            discoveryJourney.fixture.repositoryPath
                + "/large-index"
        try FileManager.default.createDirectory(
            atPath: largeIndexRoot,
            withIntermediateDirectories: true
        )
        for index in 0..<512 {
            let name = String(
                format:
                    "tracked-entry-%04d-with-realistic-repository-name.txt",
                index
            )
            try Data("tracked\n".utf8).write(
                to: URL(fileURLWithPath: largeIndexRoot)
                    .appendingPathComponent(name)
            )
        }
        try discoveryJourney.fixture.git([
            "add", "large-index",
        ])
        try discoveryJourney.fixture.git([
            "commit", "--quiet", "-m",
            "large index fixture",
        ])
        try discoveryJourney.fixture.git([
            "push", discoveryJourney.fixture.remotePath,
            "main:main",
        ])
        let largeIndexOID = try oid(
            discoveryJourney.fixture,
            at:
                discoveryJourney.fixture
                    .repositoryPath
        )
        let largeIndexBytes =
            try discoveryJourney.fixture.gitOutput([
                "ls-files", "--stage", "-v", "-z",
            ])
        try check(
            largeIndexBytes.count > 16_384
                && largeIndexBytes.count
                    < RepositoryInventoryDiscovery
                        .inventoryOutputLimit,
            "large-index fixture does not exercise the production inspection budget"
        )
        let destination = discoveryJourney.fixture.account.homeDirectory
            + "/dev/personal/discovery-card"
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: destination)
                .deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            atPath: discoveryJourney.fixture.repositoryPath,
            toPath: destination
        )
        // Establish the remote tracking ref so cachedExactRelation can
        // compute the relation without a live fetch.  Without it the
        // tracking ref does not exist, the relation falls back to
        // .unavailable, and the card's fastForward is nil.
        _ = try M1GitFixture.runGit([
            "-C", destination,
            "update-ref", "refs/remotes/origin/main",
            largeIndexOID,
        ])
        let discovery = try RepositoryInventoryDiscovery(
            executablePath: testExecutable,
            isolatedRoot: discoveryJourney.fixture.rootPath,
            transportMapping: try TransportMapping(
                logicalURL:
                    "git@github.com:fixture-owner/discovery-card.git",
                localRepositoryPath:
                    discoveryJourney.fixture.remotePath,
                containmentRoot:
                    discoveryJourney.fixture.rootPath
            )
        )
        let initial = try discovery.discoverInventory()
        let proposal = try require(
            initial.onboardingProposals.first,
            "repository-centric discovery omitted onboarding"
        )
        let discoveredClone = try require(
            initial.cards.first?.clones.first,
            "repository-centric discovery omitted its clone"
        )
        let discoveryState = try SecureStateDirectory.open(
            discoveryJourney.fixture.stateLocation
        )
        _ = try RepositoryAuthorityStore(
            state: discoveryState
        ).confirmOnboarding(
            proposals: [proposal],
            selectedRepositoryIDs: [proposal.repositoryID],
            freshClones: [discoveredClone],
            expectedFileIdentity: initial.authorityFileIdentity
        )
        // Phase-invariant (DM2-T12): the onboarding write committed to disk
        // before the post-write rediscovery runs.  If the post-write discovery
        // were to fail, the authority file already contains the selection and
        // the operator must not be told "nothing was saved".
        let phaseCardCheck = RepositoryAuthorityStore(
            state: discoveryState
        ).snapshot()
        try check(
            phaseCardCheck.status == .available
                && phaseCardCheck.usableRecords.first?.repositoryID
                    == "fixture-owner/discovery-card",
            "repository card phase: authority write did not commit before post-write discovery"
        )
        let admitted = try discovery.discoverInventory()
        try check(
            admitted.cards.count == 1
                && admitted.cards[0].id
                    == "fixture-owner/discovery-card"
                && admitted.cards[0].authority.status == .usable
                && admitted.cards[0].repository.resolvedDefault?.name
                    == "main"
                && admitted.selectableOperations.count == 1,
            "repository-centric discovery did not produce one admitted card"
        )

        let stalePath =
            discoveryJourney.fixture.account
                .homeDirectory
                + "/dev/personal/discovery-card-stale"
        try FileManager.default.createDirectory(
            atPath:
                URL(fileURLWithPath: stalePath)
                    .deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        _ = try M1GitFixture.runGit([
            "-C", destination,
            "branch", "stale-registration",
            largeIndexOID,
        ])
        _ = try M1GitFixture.runGit([
            "-C", destination,
            "worktree", "add", "--quiet",
            stalePath, "stale-registration",
        ])
        try FileManager.default.removeItem(
            atPath: stalePath
        )
        let staleInventory =
            try discovery.discoverInventory()
        let staleScope =
            try ValidatedSelectedRepositoryScope
                .testing(
                    candidates:
                        staleInventory.cards
                            .flatMap(\.clones)
                            .map(\.sourceSnapshot)
                )
        let staleCapability =
            try VerifiedRepositoryAuthorityCapability(
                scope: staleScope,
                inventory: staleInventory
            )
        let inspectedStaleInventory =
            try discovery.inspectCleanup(
                inventory: staleInventory,
                repositoryIDs: staleScope.repositoryIDs,
                capability: staleCapability
            )
        try check(
            !inspectedStaleInventory.cards
                .flatMap(\.clones)
                .flatMap(\.warnings)
                .contains {
                    $0.contains(
                        "Cleanup inspection failed"
                    )
                },
            "large-index cleanup inspection exceeded the production output budget"
        )
        let staleOperations =
            inspectedStaleInventory.selectableOperations
        let staleFastForward = try require(
            staleOperations.first {
                $0.kind == .fastForward
            },
            "stale-registration inventory omitted Fast-forward"
        )
        let staleRepair = try require(
            staleOperations.first {
                $0.kind
                    == .repairPruneRegistrations
            },
            "stale-registration inventory omitted exact Repair"
        )
        let governedRoot =
            discoveryJourney.fixture.account
                .homeDirectory + "/dev"
        let currentPolicySHA256: String
        do {
            currentPolicySHA256 =
                try RepositoryPolicyLoader.load(
                    rootPath: governedRoot
                ).admissionSHA256
        } catch {
            throw DM2Body1SelfTestError.message(
                "could not reload stale-registration fixture policy at \(governedRoot): \(error)"
            )
        }
        try check(
            staleFastForward.target.canonicalClone
                .sourceSnapshot
                .policyAdmissionSHA256
                == currentPolicySHA256,
            "stale-registration fixture policy snapshot changed: candidate=\(staleFastForward.target.canonicalClone.sourceSnapshot.policyAdmissionSHA256 ?? "missing") current=\(currentPolicySHA256)"
        )
        try RepositoryDiscovery
            .validateRuntimeEligibility(
                staleFastForward,
                account:
                    discoveryJourney.fixture.account,
                stateLocation:
                    discoveryJourney.fixture
                        .stateLocation,
                governedRootPath: governedRoot
            )
        try RepositoryDiscovery
            .validateRuntimeEligibility(
                staleRepair,
                account:
                    discoveryJourney.fixture.account,
                stateLocation:
                    discoveryJourney.fixture
                        .stateLocation,
                governedRootPath: governedRoot
            )

        let policyURL = URL(
            fileURLWithPath:
                governedRoot
                    + "/_ops/policy/worktree-policy.yml"
        )
        let originalPolicy = try String(
            contentsOf: policyURL,
            encoding: .utf8
        )
        let exclusion = """
        exclude:
          - blocked/*
        """
        try check(
            originalPolicy.contains(exclusion),
            "stale-registration fixture exclusion is missing"
        )
        let changedPolicy = originalPolicy.replacingOccurrences(
            of: exclusion,
            with: exclusion
                + "\n  - changed-after-preview/*"
        )
        try Data(changedPolicy.utf8).write(to: policyURL)
        try check(
            throwsError {
                try RepositoryDiscovery
                    .validateRuntimeEligibility(
                        staleFastForward,
                        account:
                            discoveryJourney.fixture
                                .account,
                        stateLocation:
                            discoveryJourney.fixture
                                .stateLocation,
                        governedRootPath:
                            governedRoot
                    )
            },
            "changed policy passed stale-registration runtime admission"
        )
    }

    private static func testAuthorityLifecycle() throws {
        let first = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/authority-one"
        )
        defer { first.fixture.remove() }
        let second = try preparedFixture(
            defaultBranch: "main",
            state: .equal,
            logicalRepository: "fixture-owner/authority-two"
        )
        defer { second.fixture.remove() }
        let firstClone = try makeOperation(first)
            .target.canonicalClone
        let secondClone = try makeOperation(second)
            .target.canonicalClone
        let state = try SecureStateDirectory.open(
            first.fixture.stateLocation
        )
        let store = RepositoryAuthorityStore(state: state)
        _ = try store.confirmOnboarding(
            proposals: [CanonicalAuthorityProposal(clone: firstClone)],
            selectedRepositoryIDs: [firstClone.repositoryID],
            freshClones: [firstClone],
            expectedFileIdentity: nil
        )
        let firstSnapshot = store.snapshot()
        try check(
            firstSnapshot.status == .available
                && firstSnapshot.usableRecords.count == 1,
            "initial authority write failed"
        )
        _ = try store.confirmOnboarding(
            proposals: [
                CanonicalAuthorityProposal(clone: secondClone)
            ],
            selectedRepositoryIDs: [secondClone.repositoryID],
            freshClones: [secondClone],
            expectedFileIdentity: firstSnapshot.fileIdentity
        )
        let secondSnapshot = store.snapshot()
        try check(
            secondSnapshot.usableRecords.map(\.repositoryID)
                == [
                    firstClone.repositoryID,
                    secondClone.repositoryID,
                ].sorted(),
            "onboarding update discarded preserved authority"
        )
        let path = state.path + "/"
            + RepositoryAuthorityStore.filename
        let beforeRace = try Data(contentsOf: URL(fileURLWithPath: path))
        try InstallationLifecycle
            .testingPreserveAuthorityDuringRemoval(
                at: first.fixture.stateLocation
            )
        let afterRemovalAdmission = store.snapshot()
        let afterRemovalBytes = try Data(
            contentsOf: URL(fileURLWithPath: path)
        )
        try check(
            afterRemovalAdmission.status == .available
                && afterRemovalAdmission.fileIdentity
                    == secondSnapshot.fileIdentity
                && afterRemovalBytes == beforeRace,
            "verified uninstall/rollback cleanup did not preserve authority"
        )
        try check(
            throwsError {
                _ = try store.confirmCanonicalRoot(
                    clone: firstClone,
                    freshClones: [firstClone],
                    expectedFileIdentity:
                        firstSnapshot.fileIdentity
                )
            },
            "stale authority identity was accepted"
        )
        let afterRace = try Data(contentsOf: URL(fileURLWithPath: path))
        try check(
            beforeRace == afterRace,
            "stale authority race changed the file"
        )
        var info = stat()
        try check(
            lstat(path, &info) == 0
                && (info.st_mode & S_IFMT) == S_IFREG
                && info.st_uid == geteuid()
                && mode_t(info.st_mode) & 0o777 == 0o600
                && info.st_nlink == 1,
            "authority file lost private physical identity"
        )
        try check(
            RepositoryAuthorityStore.filename
                == "repository-authorities.json",
            "authority lifecycle filename changed"
        )
    }

    private enum FixtureState {
        case equal
        case behind
        case ahead
        case diverged
    }

    private struct PreparedFixture {
        let fixture: M1GitFixture
        let candidate: RepositoryCandidate
        let defaultBranch: String
        let localOID: String
        let remoteOID: String
        let state: FixtureState
        let targetWorktreePath: String
    }

    private static func preparedFixture(
        defaultBranch: String,
        state: FixtureState,
        logicalRepository: String =
            "fixture-owner/fixture-repo",
        additionalTrackedFiles: Int = 0,
        fixturePolicyDigest: String? = nil
    ) throws -> PreparedFixture {
        let fixture = try M1GitFixture()
        if logicalRepository
            != fixture.candidate.originIdentity?.canonicalName {
            try fixture.git([
                "remote", "set-url", "origin",
                "git@github.com:\(logicalRepository).git",
            ])
        }
        if defaultBranch != "main" {
            try fixture.git([
                "branch", "-m", "main", defaultBranch,
            ])
        }
        if additionalTrackedFiles > 0 {
            for index in 0..<additionalTrackedFiles {
                let name = String(
                    format:
                        "inventory-%04d-%@.txt",
                    index,
                    String(repeating: "x", count: 48)
                )
                try Data("tracked\n".utf8).write(
                    to: URL(
                        fileURLWithPath:
                            fixture.repositoryPath
                    ).appendingPathComponent(name)
                )
            }
            try fixture.git(["add", "--", "."])
            try fixture.git([
                "commit", "--quiet", "-m",
                "large bounded inventory",
            ])
        }
        _ = try M1GitFixture.runGit([
            "--git-dir", fixture.remotePath,
            "symbolic-ref", "HEAD",
            "refs/heads/\(defaultBranch)",
        ])
        try fixture.git([
            "push", fixture.remotePath,
            "\(defaultBranch):\(defaultBranch)",
        ])
        let base = try oid(
            fixture,
            at: fixture.repositoryPath
        )
        let localOID: String
        let remoteOID: String
        switch state {
        case .equal:
            localOID = base
            remoteOID = base
        case .behind:
            remoteOID = try commit(
                fixture,
                name: "remote-behind-\(defaultBranch)"
            )
            try fixture.git([
                "push", fixture.remotePath,
                "\(defaultBranch):\(defaultBranch)",
            ])
            try fixture.git(["reset", "--hard", base])
            localOID = base
        case .ahead:
            localOID = try commit(
                fixture,
                name: "local-ahead-\(defaultBranch)"
            )
            remoteOID = base
        case .diverged:
            remoteOID = try commit(
                fixture,
                name: "remote-diverged-\(defaultBranch)"
            )
            try fixture.git([
                "push", fixture.remotePath,
                "\(defaultBranch):\(defaultBranch)",
            ])
            try fixture.git(["reset", "--hard", base])
            localOID = try commit(
                fixture,
                name: "local-diverged-\(defaultBranch)"
            )
        }
        let fixed = try RepositoryHandle.fixedCandidate(path: fixture.repositoryPath)
        let candidate = RepositoryCandidate(id: fixed.id, displayName: fixed.displayName,
            path: fixed.path, rawOrigin: fixed.rawOrigin, presentationLocation: fixed.presentationLocation,
            rootIdentity: fixed.rootIdentity, gitDirectoryIdentity: fixed.gitDirectoryIdentity,
            commonDirectoryIdentity: fixed.commonDirectoryIdentity, configIdentity: fixed.configIdentity,
            policyAdmissionSHA256: fixturePolicyDigest ?? fixed.policyAdmissionSHA256,
            hookAdmissionSHA256: fixed.hookAdmissionSHA256, linkedWorktreePaths: fixed.linkedWorktreePaths,
            linkedWorktrees: fixed.linkedWorktrees, cachedMainRelation: fixed.cachedMainRelation,
            blockedReason: fixed.blockedReason)
        return PreparedFixture(
            fixture: fixture,
            candidate: candidate,
            defaultBranch: defaultBranch,
            localOID: localOID,
            remoteOID: remoteOID,
            state: state,
            targetWorktreePath: fixture.repositoryPath
        )
    }

    private static func preparedLinkedTarget()
        throws -> PreparedFixture {
        let prepared = try preparedFixture(
            defaultBranch: "main",
            state: .behind
        )
        try prepared.fixture.git([
            "checkout", "--quiet", "-b", "feature",
        ])
        let linked = prepared.fixture.rootPath
            + "/external-default-worktree"
        try prepared.fixture.git([
            "worktree", "add", "--quiet", linked, "main",
        ])
        let candidate = try candidateWithLinkedWorktrees(prepared)
        return PreparedFixture(
            fixture: prepared.fixture,
            candidate: candidate,
            defaultBranch: prepared.defaultBranch,
            localOID: prepared.localOID,
            remoteOID: prepared.remoteOID,
            state: prepared.state,
            targetWorktreePath: linked
        )
    }

    private static func candidateWithLinkedWorktrees(
        _ prepared: PreparedFixture
    ) throws -> RepositoryCandidate {
        let linkedRecords =
            try RepositoryDiscovery.testingRegisteredLinkedWorktrees(
                commonDirectory:
                    prepared.fixture.repositoryPath + "/.git",
                rootPath: prepared.fixture.rootPath,
                account: prepared.fixture.account
            )
        let fixed = try RepositoryHandle.fixedCandidate(
            path: prepared.fixture.repositoryPath
        )
        return RepositoryCandidate(
            id: fixed.id,
            displayName: fixed.displayName,
            path: fixed.path,
            rawOrigin: fixed.rawOrigin,
            presentationLocation: fixed.presentationLocation,
            rootIdentity: fixed.rootIdentity,
            gitDirectoryIdentity: fixed.gitDirectoryIdentity,
            commonDirectoryIdentity:
                fixed.commonDirectoryIdentity,
            configIdentity: fixed.configIdentity,
            policyAdmissionSHA256:
                fixed.policyAdmissionSHA256,
            hookAdmissionSHA256:
                fixed.hookAdmissionSHA256,
            linkedWorktreePaths: linkedRecords.map(\.path),
            linkedWorktrees: linkedRecords,
            cachedMainRelation: .behind,
            blockedReason: nil
        )
    }

    private static func candidateWithoutLinkedWorktrees(
        _ candidate: RepositoryCandidate
    ) -> RepositoryCandidate {
        RepositoryCandidate(
            id: candidate.id,
            displayName: candidate.displayName,
            path: candidate.path,
            rawOrigin: candidate.rawOrigin,
            presentationLocation:
                candidate.presentationLocation,
            rootIdentity: candidate.rootIdentity,
            gitDirectoryIdentity:
                candidate.gitDirectoryIdentity,
            commonDirectoryIdentity:
                candidate.commonDirectoryIdentity,
            configIdentity: candidate.configIdentity,
            policyAdmissionSHA256:
                candidate.policyAdmissionSHA256,
            hookAdmissionSHA256:
                candidate.hookAdmissionSHA256,
            linkedWorktreePaths: [],
            linkedWorktrees: [],
            cachedMainRelation:
                candidate.cachedMainRelation,
            blockedReason: candidate.blockedReason
        )
    }

    private static func operationWithStaleSource(
        _ discovered: PlannedOperation
    ) throws -> PlannedOperation {
        let discoveredClone =
            discovered.target.canonicalClone
        let operationClone = try LocalClone(
            repositoryID: discoveredClone.repositoryID,
            sourceSnapshot:
                candidateWithoutLinkedWorktrees(
                    discoveredClone.sourceSnapshot
                ),
            effectiveOrigin:
                discoveredClone.effectiveOrigin,
            originParityVerified:
                discoveredClone.originParityVerified,
            policyCategory:
                discoveredClone.policyCategory,
            kind: discoveredClone.kind,
            worktrees: discoveredClone.worktrees,
            branches: discoveredClone.branches,
            warnings: discoveredClone.warnings
        )
        let target = discovered.target
        return PlannedOperation(
            target: try DefaultBranchUpdateTarget(
                repository: target.repository,
                canonicalClone: operationClone,
                resolvedDefault: target.resolvedDefault,
                expectedLocalOID: target.expectedLocalOID,
                expectedFetchedOID:
                    target.expectedFetchedOID,
                operationHookSHA256:
                    target.operationHookSHA256,
                registrationSetSHA256:
                    target.registrationSetSHA256,
                preservationSHA256:
                    target.preservationSHA256,
                mode: target.mode,
                worktreeID: target.worktreeID,
                relation: target.relation
            )
        )
    }

    private static func makeOperation(
        _ prepared: PreparedFixture,
        worktreePath: String? = nil,
        candidate overrideCandidate: RepositoryCandidate? = nil,
        previewRelation: DefaultBranchRelation? = nil
    ) throws -> PlannedOperation {
        let candidate = overrideCandidate ?? prepared.candidate
        let repositoryID = try require(
            candidate.originIdentity?.canonicalName,
            "fixture origin identity is missing"
        )
        let common = try require(
            candidate.commonDirectoryIdentity,
            "fixture common-directory identity is missing"
        )
        let cloneID = LocalClone.id(for: common)
        let path = worktreePath ?? prepared.targetWorktreePath
        let isPrimary = path == candidate.path
        let root: RepositoryDirectoryIdentity
        let registration: RepositoryDirectoryIdentity?
        if isPrimary {
            root = try require(
                candidate.rootIdentity,
                "fixture root identity is missing"
            )
            registration = nil
        } else {
            let record = try require(
                candidate.linkedWorktrees.first {
                    $0.path == path
                },
                "linked fixture registration is missing"
            )
            root = record.rootIdentity
            registration = record.registrationDirectoryIdentity
        }
        let targetID =
            "worktree:\(cloneID):\(root.device):\(root.inode)"
        var worktrees: [Worktree] = [
            try Worktree(
                id: targetID,
                cloneID: cloneID,
                path: path,
                rootIdentity: root,
                registrationIdentity: registration,
                attachedBranchRef:
                    "refs/heads/\(prepared.defaultBranch)",
                detachedOID: nil,
                isPrimary: isPrimary,
                locationKind:
                    isPrimary ? .canonicalPrimary : .external,
                verification: .verified,
                cleanliness: .clean,
                warning:
                    isPrimary ? nil : "External linked worktree context."
            ),
        ]
        var branches: [Branch] = [
            try Branch(
                cloneID: cloneID,
                fullRef:
                    "refs/heads/\(prepared.defaultBranch)",
                tipOID: prepared.localOID,
                claimingWorktreeIDs: [targetID]
            ),
        ]
        if !isPrimary {
            let primaryRoot = try require(
                candidate.rootIdentity,
                "fixture primary identity is missing"
            )
            let primaryID =
                "worktree:\(cloneID):\(primaryRoot.device):\(primaryRoot.inode)"
            worktrees.append(try Worktree(
                id: primaryID,
                cloneID: cloneID,
                path: candidate.path,
                rootIdentity: primaryRoot,
                registrationIdentity: nil,
                attachedBranchRef: "refs/heads/feature",
                detachedOID: nil,
                isPrimary: true,
                locationKind: .canonicalPrimary,
                verification: .verified,
                cleanliness: .dirty
            ))
            branches.append(try Branch(
                cloneID: cloneID,
                fullRef: "refs/heads/feature",
                tipOID: prepared.localOID,
                claimingWorktreeIDs: [primaryID]
            ))
        }
        let clone = try LocalClone(
            repositoryID: repositoryID,
            sourceSnapshot: candidate,
            effectiveOrigin: candidate.rawOrigin,
            originParityVerified: true,
            policyCategory: .writable,
            kind: .primaryCheckout,
            worktrees: worktrees,
            branches: branches,
            warnings: []
        )
        let resolved = try RemoteDefaultBranch(
            name: prepared.defaultBranch,
            advertisedOID: prepared.remoteOID
        )
        let repository = try RemoteRepository(
            id: repositoryID,
            origins: [candidate.rawOrigin],
            policyCategory: .writable,
            resolvedDefault: resolved,
            defaultUnavailableReason: nil
        )
        let target = try DefaultBranchUpdateTarget(
            repository: repository,
            canonicalClone: clone,
            resolvedDefault: resolved,
            expectedLocalOID: prepared.localOID,
            expectedFetchedOID: prepared.remoteOID,
            mode: .checkedOut,
            worktreeID: targetID,
            relation: previewRelation
                ?? relation(for: prepared.state)
        )
        return PlannedOperation(target: target)
    }

    private static func execute(
        _ prepared: PreparedFixture,
        operation: PlannedOperation,
        executable: String,
        afterPreflight:
            (@Sendable (RepositoryCandidate) -> Void)? = nil,
        afterFetchCapture:
            (@Sendable (String, RepositoryCandidate) -> Void)? = nil,
        runtimeEligibilityCheck:
            (@Sendable (RepositoryCandidate) throws -> Void)? = nil
    ) throws -> (result: RepositoryResult, audit: CommandAudit) {
        let authority = try RunAuthority.acquireRun(
            at: prepared.fixture.stateLocation
        )
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let audit = CommandAudit()
        let transaction = FastForwardTransactionV2(
            runner: DescriptorProcessRunner(
                audit: audit,
                outputLimit:
                    DescriptorProcessRunner
                        .completeRepositoryOutputLimit
            ),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: executable,
                operationLeaseDescriptor: lease,
                transportMapping: prepared.fixture.mapping,
                afterPreflight: afterPreflight,
                afterFetchCapture: afterFetchCapture,
                runtimeEligibilityCheck:
                    runtimeEligibilityCheck ?? { _ in }
            ),
            account: prepared.fixture.account
        )
        return (
            transaction.execute(
                operation: operation,
                cancellation: CancellationToken(),
                phase: { _ in }
            ),
            audit
        )
    }

    private static func relation(
        for state: FixtureState
    ) -> DefaultBranchRelation {
        switch state {
        case .equal:
            return DefaultBranchRelation(
                kind: .equal,
                aheadCount: 0,
                behindCount: 0
            )
        case .behind:
            return DefaultBranchRelation(
                kind: .behind,
                aheadCount: 0,
                behindCount: 1
            )
        case .ahead:
            return DefaultBranchRelation(
                kind: .ahead,
                aheadCount: 1,
                behindCount: 0
            )
        case .diverged:
            return DefaultBranchRelation(
                kind: .diverged,
                aheadCount: 1,
                behindCount: 1
            )
        }
    }

    private static func card(
        for prepared: PreparedFixture
    ) throws -> RepositoryCard {
        let operation = try makeOperation(prepared)
        let clone = operation.target.canonicalClone
        return try RepositoryCard(
            repository: operation.target.repository,
            authority: CanonicalAuthorityState(
                status: .usable,
                record: RepositoryAuthorityRecord(clone: clone),
                explanation: "Canonical root verified."
            ),
            clones: [clone],
            relation: operation.target.relation,
            fastForward: operation,
            fastForwardRefusal: nil
        )
    }

    private static func commit(
        _ fixture: M1GitFixture,
        name: String
    ) throws -> String {
        try Data("\(name)\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("\(name).txt")
        )
        try fixture.git(["add", "\(name).txt"])
        try fixture.git(["commit", "--quiet", "-m", name])
        return try oid(fixture, at: fixture.repositoryPath)
    }

    private static func oid(
        _ prepared: PreparedFixture,
        at path: String? = nil
    ) throws -> String {
        try oid(
            prepared.fixture,
            at: path ?? prepared.fixture.repositoryPath
        )
    }

    private static func oid(
        _ fixture: M1GitFixture,
        at path: String
    ) throws -> String {
        String(
            decoding: try M1GitFixture.runGit([
                "-C", path, "rev-parse", "HEAD",
            ]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeExecutable(
        _ value: String,
        to path: String
    ) throws {
        try Data(value.utf8).write(
            to: URL(fileURLWithPath: path)
        )
        guard chmod(path, 0o700) == 0 else {
            throw DM2Body1SelfTestError.message(
                "could not make fixture hook executable"
            )
        }
    }

    private static func installDiscoveryPolicy(
        homeDirectory: String
    ) throws {
        let policyRoot = homeDirectory + "/dev/_ops"
        try FileManager.default.createDirectory(
            atPath: policyRoot + "/policy",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: policyRoot + "/bin",
            withIntermediateDirectories: true
        )
        let policy = """
        version: 1
        governed_roots:
          - ~/dev
        managed_location: ~/.cursor/worktrees
        modes_file: worktree-modes.yml
        default: include
        include:
          - personal/*
        exclude:
          - blocked/*
        detectors:
          governed_markers:
            - _ops/POLICY.md
          foreign_hook_frameworks:
            - fixture-hook
          read_only_paths:
            - reference/*
        overrides:
          include: []
          exclude: []
        """
        let baseline = """
        bl_classify_repo() {
          if [ "$ownerrepo_lc" = "blocked-owner/blocked-repo" ]; then
            printf 'EXCLUDED'
          fi
        }
        """
        let hookInstaller = """
        MARKER='managed-by: ShadowSync fixture'
        disp_tmp="$(mktemp)"
        cat > "$disp_tmp" <<EOF
        #!/usr/bin/env bash
        # $MARKER
        exit 0
        EOF
        """
        try Data(policy.utf8).write(
            to: URL(fileURLWithPath:
                policyRoot + "/policy/worktree-policy.yml")
        )
        try Data(baseline.utf8).write(
            to: URL(fileURLWithPath:
                policyRoot + "/bin/baseline-lib.sh")
        )
        try Data(hookInstaller.utf8).write(
            to: URL(fileURLWithPath:
                policyRoot + "/bin/install-identity-guard.sh")
        )
    }

    private static func require<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw DM2Body1SelfTestError.message(message)
        }
        return value
    }

    private static func throwsError(
        _ body: () throws -> Void
    ) -> Bool {
        do {
            try body()
            return false
        } catch {
            return true
        }
    }

    private static func check(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw DM2Body1SelfTestError.message(message)
        }
    }
}

private final class DM2CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private enum DM2Body1SelfTestError:
    Error, CustomStringConvertible {
    case message(String)
    case testFailed(String, String)

    var description: String {
        switch self {
        case let .message(value):
            return value
        case let .testFailed(name, detail):
            return "\(name): \(detail)"
        }
    }
}
#endif
