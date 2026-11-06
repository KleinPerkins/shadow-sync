#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation

public enum V2Body4SelfTestRunner {
    public typealias Observer = (String) -> Void

    public static func runAll(
        testExecutable: String,
        observer: Observer = { _ in }
    ) throws {
        try runFocused(
            "t04",
            testExecutable: testExecutable,
            observer: observer
        )
        try runFocused(
            "t05",
            testExecutable: testExecutable,
            observer: observer
        )
        try runFocused(
            "t13",
            testExecutable: testExecutable,
            observer: observer
        )
    }

    public static func runFocused(
        _ requested: String,
        testExecutable: String,
        observer: Observer = { _ in }
    ) throws {
        switch requested.lowercased()
            .replacingOccurrences(of: "dm2-", with: "")
        {
        case "t04":
            try refOnlyCAS(executable: testExecutable)
            observer("DM2-T04 ref-only-cas")
        case "t04-success":
            try refOnlyCAS(
                executable: testExecutable,
                sections: ["success"]
            )
            observer("DM2-T04 ref-only-cas · success")
        case "t04-relations":
            try refOnlyCAS(
                executable: testExecutable,
                sections: ["relations"]
            )
            observer("DM2-T04 ref-only-cas · relations")
        case "t04-races-a":
            try refOnlyCAS(
                executable: testExecutable,
                sections: ["races-a"]
            )
            observer("DM2-T04 ref-only-cas · claim races")
        case "t04-races-b":
            try refOnlyCAS(
                executable: testExecutable,
                sections: ["races-b"]
            )
            observer("DM2-T04 ref-only-cas · identity races")
        case "t05":
            try operationHooks(executable: testExecutable)
            observer("DM2-T05 operation-hooks")
        case "t05-basic":
            try operationHooks(
                executable: testExecutable,
                sections: ["basic"]
            )
            observer("DM2-T05 operation-hooks · trace")
        case "t05-veto":
            try operationHooks(
                executable: testExecutable,
                sections: ["veto"]
            )
            observer("DM2-T05 operation-hooks · veto")
        case "t05-custom":
            try operationHooks(
                executable: testExecutable,
                sections: ["custom"]
            )
            observer("DM2-T05 operation-hooks · hooksPath")
        case "t05-policy":
            try commandPolicyCut()
            observer("DM2-T05 shared command policy")
        case "t13":
            try compatibilityRelease(executable: testExecutable)
            observer("DM2-T13 compatibility-release")
        default:
            throw Body4SelfTestError(
                "unknown focused Body 4 test \(requested)"
            )
        }
    }

    public static func installLifecycleEvidence(
        state: SecureStateDirectory,
        legacyLog: Data
    ) throws {
        try replaceLatest(legacyLog, state: state)
        try installAuthorityAndRetention(state: state)
    }

    private static func refOnlyCAS(
        executable: String,
        sections: Set<String> = [
            "success", "relations", "races-a", "races-b",
        ]
    ) throws {
        if sections.contains("success") {
            try commandPolicyCut()
            let success = try makeBehindFixture(
                "body4-success",
                executable: executable
            )
            defer { success.fixture.remove() }
            let successOperation = try refOnlyOperation(
                success.fixture,
                executable: executable
            )
            let preservedBefore =
                try RefOnlyPreservationSnapshot.capture(
                    clone: successOperation.target.canonicalClone,
                    account: success.fixture.account,
                    cancellation: CancellationToken()
                )
            let refsBefore = try refs(
                success.fixture,
                excluding: "refs/heads/main"
            )
            let audit = CommandAudit()
            let successResult = try execute(
                fixture: success.fixture,
                operation: successOperation,
                executable: executable,
                audit: audit
            )
            let preservedAfter =
                try RefOnlyPreservationSnapshot.capture(
                    clone: successOperation.target.canonicalClone,
                    account: success.fixture.account,
                    cancellation: CancellationToken()
                )
            let actions = updateRefActions(audit)
            try expect(
                successResult.code == .updated
                    && successResult.mainUpdated,
                "ref-only Behind result was not Updated: "
                    + "\(successResult.code.rawValue) "
                    + (successResult.technicalDetail
                        ?? successResult.explanation)
            )
            try expect(
                success.fixture.gitText([
                    "rev-parse", "refs/heads/main",
                ]) == success.target,
                "ref-only Behind target ref did not reach the target"
            )
            try expect(
                preservedBefore == preservedAfter,
                "ref-only Behind changed worktree or index evidence"
            )
            try expect(
                refsBefore
                    == refs(
                        success.fixture,
                        excluding: "refs/heads/main"
                    ),
                "ref-only Behind changed a ref other than the target"
            )
            try expect(
                actions.count == 1,
                "ref-only Behind did not issue exactly one update-ref"
            )
            let expectedArguments = [
                "--git-dir=\(success.fixture.repositoryPath)/.git",
                "update-ref",
                "refs/heads/main",
                success.target,
                success.local,
            ]
            try expect(
                Array(actions[0].arguments.suffix(5))
                    == expectedArguments,
                "ref-only Behind argv was not the closed expected-old CAS: "
                    + actions[0].arguments.joined(separator: " ")
            )
            try expect(
                !audit.invocations.contains(where: {
                    $0.arguments.contains("checkout")
                        || $0.arguments.contains("switch")
                        || $0.arguments.contains("reset")
                        || $0.arguments.contains("stash")
                        || $0.arguments.contains("clean")
                }),
                "ref-only worker entered a checkout or cleanup grammar"
            )
        }

        if sections.contains("relations") {
            try verifyDiscoveryRelations(executable: executable)
        }

        if sections.contains("races-a") {
            try refusalRace(
                "body4-claim-appeared",
                executable: executable,
                mutateAfterFetch: { fixture, _ in
                    let path = fixture.workRoot + "/appeared-main"
                    try fixture.git([
                        "worktree", "add", "--quiet",
                        path, "main",
                    ])
                }
            )
            try refusalRace(
                "body4-forced-duplicate",
                executable: executable,
                mutateBeforeAction: { fixture, _ in
                    let first = fixture.workRoot + "/first-main"
                    let second = fixture.workRoot + "/second-main"
                    try fixture.git([
                        "worktree", "add", "--quiet",
                        first, "main",
                    ])
                    try fixture.git([
                        "worktree", "add", "--quiet", "--force",
                        second, "main",
                    ])
                }
            )
            try refusalRace(
                "body4-claim-list-drift",
                executable: executable,
                mutateBeforeAction: { fixture, _ in
                    try fixture.git(["branch", "claim-drift"])
                    try fixture.git([
                        "worktree", "add", "--quiet",
                        fixture.workRoot + "/claim-drift",
                        "claim-drift",
                    ])
                }
            )
            try refusalRace(
                "body4-incomplete-claim-evidence",
                executable: executable,
                mutateAfterFetch: { fixture, _ in
                    try FileManager.default.createDirectory(
                        atPath:
                            fixture.repositoryPath
                            + "/.git/worktrees/incomplete-body4",
                        withIntermediateDirectories: true,
                        attributes: [
                            FileAttributeKey.posixPermissions: 0o700
                        ]
                    )
                }
            )
        }
        if sections.contains("races-b") {
            try refusalRace(
                "body4-ref-race",
                executable: executable,
                mutateAfterFetch: { fixture, target in
                    try fixture.git([
                        "update-ref", "refs/heads/main",
                        target,
                    ])
                }
            )
            try refusalRace(
                "body4-remote-oid-race",
                executable: executable,
                mutateAfterFetch: { fixture, target in
                    let local = try fixture.gitText([
                        "rev-parse", "refs/heads/main",
                    ])
                    try fixture.git([
                        "--git-dir=\(fixture.remotePath)",
                        "update-ref", "refs/heads/main",
                        local, target,
                    ])
                }
            )
            try refusalRace(
                "body4-config-race",
                executable: executable,
                mutateAfterFetch: { fixture, _ in
                    let config =
                        fixture.repositoryPath + "/.git/config"
                    let descriptor = Darwin.open(
                        config,
                        O_WRONLY | O_APPEND | O_CLOEXEC
                    )
                    guard descriptor >= 0 else {
                        throw Body4SelfTestError(
                            "could not open config race fixture"
                        )
                    }
                    defer { Darwin.close(descriptor) }
                    let bytes = Data(
                        "\n[body4-race]\n\tvalue = changed\n".utf8
                    )
                    try writeAll(bytes, descriptor: descriptor)
                }
            )
            try refusalRace(
                "body4-hook-race",
                executable: executable,
                mutateAfterFetch: { fixture, _ in
                    try installReferenceHook(
                        fixture,
                        body: "#!/bin/sh\nexit 0\n"
                    )
                }
            )
            try refusalRace(
                "body4-lock-race",
                executable: executable,
                mutateAfterFetch: { fixture, _ in
                    try Data().write(
                        to: URL(
                            fileURLWithPath:
                                fixture.repositoryPath
                                + "/.git/index.lock"
                        )
                    )
                },
                expectedCodes: [.skippedBusy]
            )
            try refusalRace(
                "body4-operation-lock-drift",
                executable: executable,
                mutateBeforeAction: { fixture, _ in
                    try replaceCommonOperationLock(fixture)
                }
            )
            try refusalRace(
                "body4-operation-lock-directory-drift",
                executable: executable,
                mutateBeforeAction: { fixture, _ in
                    try replaceCommonOperationLockDirectory(
                        fixture
                    )
                }
            )
            try policyRace(executable: executable)
            try expectedOldMismatch(executable: executable)
        }
    }

    private static func commandPolicyCut() throws {
        let common = "/private/tmp/body4-command-policy.git"
        let oid = String(repeating: "a", count: 40)
        let prefix = [
            "--no-replace-objects",
            "--no-lazy-fetch",
            "--git-dir=\(common)",
            "update-ref",
            "refs/heads/main",
            oid,
        ]
        try expect(
            try GitCommandPolicy.validate(
                prefix + [oid],
                expectedCommonDirectory: common
            ) == false,
            "expected-old update-ref was not admitted as ordinary Git"
        )
        try expectThrows(
            "update-ref without expected-old was admitted"
        ) {
            _ = try GitCommandPolicy.validate(
                prefix,
                expectedCommonDirectory: common
            )
        }
        try expectThrows(
            "forced ref-only update was admitted"
        ) {
            _ = try GitCommandPolicy.validate(
                prefix + [oid, "--force"],
                expectedCommonDirectory: common
            )
        }
        try expectThrows(
            "remote ref-only update was admitted"
        ) {
            _ = try GitCommandPolicy.validate(
                [
                    "--no-replace-objects",
                    "--no-lazy-fetch",
                    "--git-dir=\(common)",
                    "update-ref",
                    "refs/remotes/origin/main",
                    oid,
                    oid,
                ],
                expectedCommonDirectory: common
            )
        }
    }

    private static func verifyDiscoveryRelations(
        executable: String
    ) throws {
        let equal = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "body4-equal"
        )
        defer { equal.remove() }
        _ = try equal.authorizedInventory(
            executable: executable
        )
        try equal.git(["checkout", "--quiet", "--detach"])
        let equalOperation = try refOnlyOperation(
            equal,
            executable: executable
        )
        let equalResult = try execute(
            fixture: equal,
            operation: equalOperation,
            executable: executable
        )
        try expect(
            equalOperation.target.relation.kind == .equal
                && equalResult.code == .alreadyCurrent
                && !equalResult.mainUpdated,
            "Equal ref-only state was not a no-op: "
                + "\(equalOperation.target.relation.kind.rawValue) "
                + "\(equalResult.code.rawValue) "
                + (equalResult.technicalDetail
                    ?? equalResult.explanation)
        )

        let ahead = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "body4-ahead"
        )
        defer { ahead.remove() }
        _ = try ahead.authorizedInventory(
            executable: executable
        )
        try commit(ahead, value: "ahead")
        try ahead.git(["checkout", "--quiet", "--detach"])
        let aheadCard = try onlyCard(
            ahead,
            executable: executable
        )
        try expect(
            aheadCard.relation.kind == .ahead
                && aheadCard.fastForward == nil,
            "Ahead ref-only state became selectable"
        )

        let diverged = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "body4-diverged"
        )
        defer { diverged.remove() }
        _ = try diverged.authorizedInventory(
            executable: executable
        )
        let base = try diverged.gitText([
            "rev-parse", "refs/heads/main",
        ])
        try commit(diverged, value: "local-ahead")
        try diverged.git([
            "checkout", "--quiet", "--detach", base,
        ])
        try commit(diverged, value: "remote-ahead")
        try diverged.git([
            "push", "--quiet", diverged.remotePath,
            "HEAD:refs/heads/main",
        ])
        try refreshTracking(diverged)
        let divergedCard = try onlyCard(
            diverged,
            executable: executable
        )
        try expect(
            divergedCard.relation.kind == .diverged
                && divergedCard.fastForward == nil,
            "Diverged ref-only state became selectable"
        )

        let missing = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "body4-missing"
        )
        defer { missing.remove() }
        _ = try missing.authorizedInventory(
            executable: executable
        )
        try missing.git(["checkout", "--quiet", "--detach"])
        try missing.git(["branch", "-D", "main"])
        let missingInventory = try missing.inventory(
            executable: executable
        )
        try expect(
            !missingInventory.selectableOperations.contains {
                $0.kind == .fastForward
            }
                && missingInventory.selectableOperations.contains {
                    $0.kind == .initializeDefaultBranch
                },
            "missing local default escaped R-04 Initialize"
        )

        let unknown = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "body4-unknown"
        )
        defer { unknown.remove() }
        _ = try unknown.authorizedInventory(
            executable: executable
        )
        try unknown.git(["checkout", "--quiet", "--detach"])
        try commit(unknown, value: "remote-not-cached")
        try unknown.git([
            "push", "--quiet", unknown.remotePath,
            "HEAD:refs/heads/main",
        ])
        let unknownCard = try onlyCard(
            unknown,
            executable: executable
        )
        try expect(
            unknownCard.relation.kind == .unavailable
                && unknownCard.fastForward == nil,
            "unknown ref-only relation became selectable"
        )
    }

    private static func refusalRace(
        _ name: String,
        executable: String,
        mutateAfterFetch:
            (@Sendable (Body2Fixture, String) throws -> Void)? = nil,
        mutateBeforeAction:
            (@Sendable (Body2Fixture, String) throws -> Void)? = nil,
        expectedCodes: [ResultCode] = [.failedInspection]
    ) throws {
        let prepared = try makeBehindFixture(
            name,
            executable: executable
        )
        defer { prepared.fixture.remove() }
        let operation = try refOnlyOperation(
            prepared.fixture,
            executable: executable
        )
        let audit = CommandAudit()
        let mutation = LockedBody4Mutation()
        let afterFetch:
            (
                @Sendable (String, RepositoryCandidate) -> Void
            )?
        if let mutateAfterFetch {
            afterFetch = { _, _ in
                mutation.capture {
                    try mutateAfterFetch(
                        prepared.fixture,
                        prepared.target
                    )
                }
            }
        } else {
            afterFetch = nil
        }
        let beforeAction:
            (
                @Sendable (
                    PlannedOperationKind,
                    RepositoryCandidate
                ) -> Void
            )?
        if let mutateBeforeAction {
            beforeAction = { kind, _ in
                guard kind == .fastForward else { return }
                mutation.capture {
                    try mutateBeforeAction(
                        prepared.fixture,
                        prepared.target
                    )
                }
            }
        } else {
            beforeAction = nil
        }
        let result = try execute(
            fixture: prepared.fixture,
            operation: operation,
            executable: executable,
            audit: audit,
            afterFetch: afterFetch,
            beforeAction: beforeAction
        )
        try mutation.rethrowIfNeeded()
        try expect(
            expectedCodes.contains(result.code)
                && !result.mainUpdated
                && updateRefActions(audit).isEmpty,
            "\(name) was not refused before update-ref"
        )
    }

    private static func policyRace(
        executable: String
    ) throws {
        let prepared = try makeBehindFixture(
            "body4-policy-race",
            executable: executable
        )
        defer { prepared.fixture.remove() }
        let operation = try refOnlyOperation(
            prepared.fixture,
            executable: executable
        )
        let policyPath =
            prepared.fixture.home
            + "/dev/_ops/policy/worktree-policy.yml"
        let expected = try Data(
            contentsOf: URL(fileURLWithPath: policyPath)
        )
        let mutation = LockedBody4Mutation()
        let audit = CommandAudit()
        let result = try execute(
            fixture: prepared.fixture,
            operation: operation,
            executable: executable,
            audit: audit,
            afterFetch: { _, _ in
                mutation.capture {
                    let descriptor = Darwin.open(
                        policyPath,
                        O_WRONLY | O_APPEND | O_CLOEXEC
                    )
                    guard descriptor >= 0 else {
                        throw Body4SelfTestError(
                            "could not open policy race fixture"
                        )
                    }
                    defer { Darwin.close(descriptor) }
                    try writeAll(
                        Data("\n# Body 4 race\n".utf8),
                        descriptor: descriptor
                    )
                }
            },
            runtimeEligibility: { _ in
                guard
                    (try? Data(
                        contentsOf: URL(
                            fileURLWithPath: policyPath
                        )
                    )) == expected
                else {
                    throw GitSafetyError.unsafeRepository(
                        "test policy identity changed"
                    )
                }
            }
        )
        try mutation.rethrowIfNeeded()
        try expect(
            result.code == .failedInspection
                && updateRefActions(audit).isEmpty,
            "policy drift reached update-ref"
        )
    }

    private static func expectedOldMismatch(
        executable: String
    ) throws {
        let prepared = try makeBehindFixture(
            "body4-cas-mismatch",
            executable: executable
        )
        defer { prepared.fixture.remove() }
        let operation = try refOnlyOperation(
            prepared.fixture,
            executable: executable
        )
        let audit = CommandAudit()
        let result = try execute(
            fixture: prepared.fixture,
            operation: operation,
            executable: executable,
            audit: audit,
            finalMutationOnUpdate:
                GitCommandPolicy.finalRefMutationMarker
        )
        try expect(
            updateRefActions(audit).count == 1
                && result.code == .needsAttention
                && result.mainUpdated
                && prepared.fixture.gitText([
                    "rev-parse", "refs/heads/main",
                ]) == prepared.target,
            "expected-old mismatch retried, hid the moved ref, "
                + "or used a second update"
        )
    }

    private static func operationHooks(
        executable: String,
        sections: Set<String> = ["basic", "veto"]
    ) throws {
        if sections.contains("basic") {
            let marker = try makeBehindFixture(
                "body4-marker-hook",
                executable: executable
            )
            defer { marker.fixture.remove() }
            try Data("marker only\n".utf8).write(
                to: URL(
                    fileURLWithPath:
                        marker.fixture.repositoryPath
                        + "/.fixture-hook"
                )
            )
            let markerResult = try execute(
                fixture: marker.fixture,
                operation: try refOnlyOperation(
                    marker.fixture,
                    executable: executable
                ),
                executable: executable
            )
            try expect(
                markerResult.code == .updated,
                "marker-only repository was pre-blocked"
            )

            let irrelevant = try makeBehindFixture(
                "body4-irrelevant-hook",
                executable: executable
            )
            defer { irrelevant.fixture.remove() }
            let preCommitLog =
                irrelevant.fixture.temporary.path
                + "/pre-commit.log"
            let preCommit =
                irrelevant.fixture.repositoryPath
                + "/.git/hooks/pre-commit"
            try Data(
                """
                #!/bin/sh
                printf 'invoked\n' >> '\(preCommitLog)'
                exit 1
                """.utf8
            ).write(to: URL(fileURLWithPath: preCommit))
            guard chmod(preCommit, 0o700) == 0 else {
                throw Body4SelfTestError(
                    "could not install irrelevant hook"
                )
            }
            let irrelevantResult = try execute(
                fixture: irrelevant.fixture,
                operation: try refOnlyOperation(
                    irrelevant.fixture,
                    executable: executable
                ),
                executable: executable
            )
            try expect(
                irrelevantResult.code == .updated
                    && !FileManager.default.fileExists(
                        atPath: preCommitLog
                    ),
                "irrelevant pre-commit hook affected update-ref"
            )

            let traced = try makeBehindFixture(
                "body4-traced-hook",
                executable: executable
            )
            defer { traced.fixture.remove() }
            let trace = traced.fixture.temporary.path + "/trace.log"
            try installReferenceHook(
                traced.fixture,
                body:
                    "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(trace)'\nexit 0\n"
            )
            let tracedResult = try execute(
                fixture: traced.fixture,
                operation: try refOnlyOperation(
                    traced.fixture,
                    executable: executable
                ),
                executable: executable
            )
            let tracedPhases = try String(
                contentsOfFile: trace,
                encoding: .utf8
            )
            try expect(
                tracedResult.code == .updated
                    && (
                        tracedPhases.contains("prepared")
                        || tracedPhases.contains("preparing")
                    )
                    && tracedPhases.contains("committed"),
                "Apple Git update-ref hook phases were not traced"
            )
        }

        if sections.contains("basic")
            || sections.contains("custom")
        {
            let custom = try makeBehindFixture(
                "body4-custom-hookspath",
                executable: executable
            )
            defer { custom.fixture.remove() }
            try custom.fixture.git([
                "config", "core.hooksPath", ".githooks",
            ])
            let customDirectory =
                custom.fixture.repositoryPath + "/.githooks"
            try FileManager.default.createDirectory(
                atPath: customDirectory,
                withIntermediateDirectories: false,
                attributes: [
                    FileAttributeKey.posixPermissions: 0o700
                ]
            )
            let customTrace =
                custom.fixture.temporary.path + "/custom-trace.log"
            try installReferenceHook(
                custom.fixture,
                body:
                    "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(customTrace)'\nexit 0\n",
                hooksDirectory: customDirectory
            )
            let customResult = try execute(
                fixture: custom.fixture,
                operation: try refOnlyOperation(
                    custom.fixture,
                    executable: executable
                ),
                executable: executable
            )
            let customPhases = try String(
                contentsOfFile: customTrace,
                encoding: .utf8
            )
            try expect(
                customResult.code == .updated
                    && (
                        customPhases.contains("prepared")
                        || customPhases.contains("preparing")
                    )
                    && customPhases.contains("committed"),
                "effective core.hooksPath was not traced"
            )

            let absent = try makeBehindFixture(
                "body4-absent-hookspath",
                executable: executable
            )
            defer { absent.fixture.remove() }
            try absent.fixture.git([
                "config", "core.hooksPath", ".missing-hooks",
            ])
            let absentInventory =
                try absent.fixture.inventory(
                    executable: executable
                )
            try expect(
                absentInventory.selectableOperations
                    .allSatisfy {
                        $0.kind != .fastForward
                    }
                    && absentInventory.cards.first?
                        .fastForwardRefusal?
                        .contains("hook identity")
                        == true,
                "absent custom hook path became selectable"
            )

            let linked = try makeBehindFixture(
                "body4-linked-hookspath",
                executable: executable
            )
            defer { linked.fixture.remove() }
            try linked.fixture.git([
                "config", "core.hooksPath", ".linked-hooks/hooks",
            ])
            let physicalHooks =
                linked.fixture.repositoryPath
                + "/physical-hooks/hooks"
            try FileManager.default.createDirectory(
                atPath: physicalHooks,
                withIntermediateDirectories: true,
                attributes: [
                    FileAttributeKey.posixPermissions: 0o700
                ]
            )
            try FileManager.default.createSymbolicLink(
                atPath:
                    linked.fixture.repositoryPath
                    + "/.linked-hooks",
                withDestinationPath: "physical-hooks"
            )
            let linkedInventory =
                try linked.fixture.inventory(
                    executable: executable
                )
            try expect(
                linkedInventory.selectableOperations
                    .allSatisfy {
                        $0.kind != .fastForward
                    }
                    && linkedInventory.cards.first?
                        .fastForwardRefusal?
                        .contains("hook identity")
                        == true,
                "symlinked custom hook parent became selectable"
            )

            let unsupported = try makeBehindFixture(
                "body4-unsupported-hookspath-expansion",
                executable: executable
            )
            defer { unsupported.fixture.remove() }
            try unsupported.fixture.git([
                "config", "core.hooksPath", "~root/hooks",
            ])
            let misleadingDirectory =
                unsupported.fixture.repositoryPath
                + "/~root/hooks"
            try FileManager.default.createDirectory(
                atPath: misleadingDirectory,
                withIntermediateDirectories: true,
                attributes: [
                    FileAttributeKey.posixPermissions: 0o700
                ]
            )
            let unsupportedInventory =
                try unsupported.fixture.inventory(
                    executable: executable
                )
            try expect(
                unsupportedInventory.selectableOperations
                    .allSatisfy {
                        $0.kind != .fastForward
                    }
                    && unsupportedInventory.cards.first?
                        .fastForwardRefusal?
                        .contains("hook identity")
                        == true,
                "unsupported Git hook-path expansion became selectable"
            )
        }

        if sections.contains("veto") {
            let veto = try makeBehindFixture(
                "body4-veto-hook",
                executable: executable
            )
            defer { veto.fixture.remove() }
            let vetoTrace =
                veto.fixture.temporary.path + "/veto.log"
            try installReferenceHook(
                veto.fixture,
                body:
                    """
                    #!/bin/sh
                    payload="$(cat)"
                    printf '%s\n' "$1" >> '\(vetoTrace)'
                    case "$payload" in
                      *" refs/heads/main"*) exit 1 ;;
                    esac
                    exit 0
                    """
            )
            let vetoResult = try execute(
                fixture: veto.fixture,
                operation: try refOnlyOperation(
                    veto.fixture,
                    executable: executable
                ),
                executable: executable
            )
            let vetoPhases = try String(
                contentsOfFile: vetoTrace,
                encoding: .utf8
            )
            let vetoCurrent = try veto.fixture.gitText([
                "rev-parse", "refs/heads/main",
            ])
            try expect(
                vetoResult.code == .failedUpdate
                    && !vetoResult.mainUpdated
                    && (
                        vetoPhases.contains("prepared")
                        || vetoPhases.contains("preparing")
                    )
                    && vetoPhases.contains("aborted")
                    && vetoCurrent == veto.local,
                "reference-transaction veto changed the ref "
                    + "or hid the aborted phase: "
                    + "code=\(vetoResult.code.rawValue) "
                    + "updated=\(vetoResult.mainUpdated) "
                    + "phases=\(vetoPhases.replacingOccurrences(of: "\n", with: ",")) "
                    + "current=\(vetoCurrent)"
            )

            let residue = try makeBehindFixture(
                "body4-post-hook-residue",
                executable: executable
            )
            defer { residue.fixture.remove() }
            let residuePath =
                residue.fixture.repositoryPath
                + "/post-hook-residue.txt"
            try installReferenceHook(
                residue.fixture,
                body:
                    """
                    #!/bin/sh
                    payload="$(cat)"
                    case "$1:$payload" in
                      committed:*" refs/heads/main"*)
                        printf 'residue\n' > '\(residuePath)'
                        ;;
                    esac
                    exit 0
                    """
            )
            let residueResult = try execute(
                fixture: residue.fixture,
                operation: try refOnlyOperation(
                    residue.fixture,
                    executable: executable
                ),
                executable: executable
            )
            let residueExists =
                FileManager.default.fileExists(
                    atPath: residuePath
                )
            try expect(
                residueResult.code == .updatedWithWarning
                    && residueResult.mainUpdated
                    && residueExists,
                "post-hook residue was not scoped to a warning"
                    + ": code=\(residueResult.code.rawValue) "
                    + "updated=\(residueResult.mainUpdated) "
                    + "exists=\(residueExists)"
            )
        }
    }

    private static func compatibilityRelease(
        executable: String
    ) throws {
        let fixtures = fixtureDirectory
        let reportPath =
            fixtures + "/legacy-v1-report.json"
        let logPath =
            fixtures + "/legacy-v1-latest.log"
        let reportBytes = try Data(
            contentsOf: URL(fileURLWithPath: reportPath)
        )
        let logBytes = try Data(
            contentsOf: URL(fileURLWithPath: logPath)
        )
        try expect(
            sha256(reportBytes)
                == "d3030cc8a53fbb0f9ef85974d0b0fdf04496f7f50bdcc2744f5f41230ec995af"
                && sha256(logBytes)
                    == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7",
            "legacy fixture bytes drifted"
        )
        let report = try JSONDecoder().decode(
            RunReport.self,
            from: reportBytes
        )
        try expect(
            LegacyRunPresentation.label
                == "Legacy run — clone-based model"
                && LegacyRunPresentation.isLegacy(report)
                && report.repositoryModel == nil
                && report.results.first?.repository.displayName
                    == "legacy-repo"
                && report.results.allSatisfy {
                    $0.operationID == nil
                        && $0.defaultBranch == nil
                },
            "legacy report label or clone-only model changed"
        )

        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let location = try StateLocation.isolated(
            root: temporary.path
        )
        try TestIsolation.initializeState(at: location)
        let state = try SecureStateDirectory.open(location)
        try replaceLatest(logBytes, state: state)
        let originalHash = try fileSHA256(
            state.path + "/latest.log"
        )
        let read = try RunLogReader.snapshot(state: state)
        let reopened =
            RunLogReader.completedLegacyReport(
                in: read.records
            )
        let hashAfterRead = try fileSHA256(
            state.path + "/latest.log"
        )
        try expect(
            read.disposition == .legacy
                && read.records.count == 5
                && reopened == report
                && read.records.first?.intent?.candidates.first?
                    .displayName == "legacy-repo"
                && RunRecoveryInspector.inspect(
                    at: location
                ) == .previousReport(report)
                && hashAfterRead == originalHash,
            "legacy log was not reopened read-only"
        )
        try expect(
            !FileManager.default.fileExists(
                atPath: state.path + "/retention"
            )
                && !FileManager.default.fileExists(
                    atPath: state.path + "/"
                        + RepositoryAuthorityStore.filename
                ),
            "legacy evidence was promoted into v2 state"
        )

        let lines = logBytes.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        )
        let fixtureRecords = try lines.map {
            try JSONSerialization.jsonObject(
                with: Data($0)
            ) as! [String: Any]
        }
        func expectTerminalRejection(
            _ records: [[String: Any]],
            _ name: String
        ) throws {
            try replaceLatest(
                try encodedLog(records),
                state: state
            )
            try expectIncompatible(state, name)
            try expectThrows(
                "\(name) passed durable validation"
            ) {
                try DurableRunLogEvidence.validate(
                    state: state
                )
            }
        }
        func displayNameVariant(
            _ displayName: String
        ) -> [[String: Any]] {
            var records = fixtureRecords
            var intent = records[0]["intent"] as! [String: Any]
            var candidates = intent["candidates"] as! [[String: Any]]
            candidates[0]["displayName"] = displayName
            intent["candidates"] = candidates
            records[0]["intent"] = intent
            var report = records[2]["report"] as! [String: Any]
            var results = report["results"] as! [[String: Any]]
            var repository = results[0]["repository"] as! [String: Any]
            repository["displayName"] = displayName
            results[0]["repository"] = repository
            report["results"] = results
            records[2]["report"] = report
            return records
        }
        for invalid in [
            "other/legacy-repo",
            "owner/other",
            "owner/legacy-repo/extra",
            "/owner/legacy-repo",
            "owner//legacy-repo",
            "owner/./legacy-repo",
            "owner/../legacy-repo",
            #"owner\legacy-repo"#,
            "owner%2Flegacy-repo",
            "owner%5Clegacy-repo",
            "owner/legacy-repo\u{0000}",
            " owner/legacy-repo",
            "owner/legacy-repo ",
        ] {
            let variant = try encodedLog(
                displayNameVariant(invalid)
            )
            try replaceLatest(variant, state: state)
            let before = try fileSHA256(
                state.path + "/latest.log"
            )
            try expectIncompatible(
                state,
                "unsafe historical display label \(invalid)"
            )
            try expect(
                try fileSHA256(state.path + "/latest.log") == before,
                "display-label refusal changed latest.log"
            )
            try expectThrows(
                "unsafe historical display label passed durable validation"
            ) {
                try DurableRunLogEvidence.validate(state: state)
            }
        }
        try replaceLatest(logBytes, state: state)
        for count in [3, 4] {
            let historical = Array(
                fixtureRecords.prefix(count)
            )
            try replaceLatest(
                try encodedLog(historical),
                state: state
            )
            let historicalRead =
                try RunLogReader.snapshot(state: state)
            try expect(
                historicalRead.disposition == .legacy
                    && historicalRead.records.count == count,
                "historical terminal prefix \(count) was rejected"
            )
            try DurableRunLogEvidence.validate(state: state)
        }

        var earlyFinal = fixtureRecords
        earlyFinal.swapAt(3, 4)
        for index in earlyFinal.indices {
            earlyFinal[index]["sequence"] = index + 1
        }
        try expectTerminalRejection(
            earlyFinal,
            "final event before worker exit"
        )

        func appended(
            _ source: [String: Any],
            type: String? = nil
        ) -> [[String: Any]] {
            var records = fixtureRecords
            var record = source
            record["sequence"] = records.count + 1
            if let type {
                record["type"] = type
            }
            records.append(record)
            return records
        }
        try expectTerminalRejection(
            appended(fixtureRecords[3]),
            "duplicate worker exit"
        )
        try expectTerminalRejection(
            appended(fixtureRecords[4]),
            "duplicate final event"
        )
        try expectTerminalRejection(
            appended(
                fixtureRecords[3],
                type: "control"
            ),
            "record after final event"
        )

        func finalEventVariant(
            _ update: (inout [String: Any]) -> Void
        ) -> [[String: Any]] {
            var records = fixtureRecords
            var event =
                records[4]["event"] as! [String: Any]
            update(&event)
            records[4]["event"] = event
            return records
        }
        try expectTerminalRejection(
            finalEventVariant {
                $0["type"] = "diagnostic"
            },
            "wrong-kind final event"
        )
        try expectTerminalRejection(
            finalEventVariant {
                $0["run"] =
                    "22222222-2222-4222-8222-222222222222"
            },
            "wrong-run final event"
        )
        try expectTerminalRejection(
            finalEventVariant {
                $0["repositoryID"] = "owner/fake"
            },
            "fake final event"
        )
        try expectTerminalRejection(
            finalEventVariant {
                $0["message"] = "mismatched report"
            },
            "report/event mismatch"
        )

        try replaceLatest(
            Data(lines[0]) + Data("\n".utf8)
                + Data(lines[1]) + Data("\n".utf8),
            state: state
        )
        let incompleteHash = try fileSHA256(
            state.path + "/latest.log"
        )
        let incompleteRecovery =
            RunRecoveryInspector.inspect(
                at: location
            )
        let incompleteHashAfter = try fileSHA256(
            state.path + "/latest.log"
        )
        try expect(
            RunLogReader.snapshot(state: state)
                .disposition == .legacy
                && incompleteRecovery == .needsAttention
                && incompleteHashAfter == incompleteHash,
            "interrupted legacy evidence was replayed or rewritten"
        )

        try replaceLatest(
            logBytes.dropLast(),
            state: state
        )
        try expectIncompatible(state, "truncated legacy input")
        try replaceLatest(
            Data("{\"broken\":\n".utf8),
            state: state
        )
        try expectIncompatible(state, "malformed legacy input")
        var newer =
            try JSONSerialization.jsonObject(
                with: Data(lines[0])
            ) as! [String: Any]
        newer["futureField"] = true
        let newerBytes =
            try JSONSerialization.data(
                withJSONObject: newer,
                options: [.sortedKeys]
            ) + Data("\n".utf8)
        try replaceLatest(newerBytes, state: state)
        try expectIncompatible(state, "newer legacy input")

        var mixedRecords = fixtureRecords
        var mixedReport =
            mixedRecords[2]["report"] as! [String: Any]
        mixedReport["repositoryModel"] = "v2"
        mixedRecords[2]["report"] = mixedReport
        try replaceLatest(
            try encodedLog(mixedRecords),
            state: state
        )
        try expectIncompatible(
            state,
            "mixed legacy/current generation"
        )

        var duplicateRecords = fixtureRecords
        var duplicateFinish = duplicateRecords[2]
        duplicateFinish["sequence"] =
            duplicateRecords.count + 1
        duplicateRecords.append(duplicateFinish)
        try replaceLatest(
            try encodedLog(duplicateRecords),
            state: state
        )
        try expectIncompatible(
            state,
            "duplicate legacy completion"
        )

        try replaceLatest(logBytes, state: state)
        try expectThrows(
            "oversized legacy input was accepted"
        ) {
            _ = try RunLogReader.snapshot(
                state: state,
                maximumBytes: logBytes.count - 1
            )
        }

        try installAuthorityAndRetention(state: state)
        let durableBefore = try DurableBody4Snapshot(
            state: state
        )
        try InstallationLifecycle
            .testingPreserveAuthorityDuringRemoval(
                at: location
            )
        try expect(
            try DurableBody4Snapshot(state: state)
                == durableBefore,
            "verified uninstall validation changed durable v1, "
                + "authority, or retention evidence"
        )
        try DurableRunLogEvidence.validate(state: state)
        try failureCuts(
            state: state,
            location: location,
            legacyBytes: logBytes
        )
        try v2EventPreservation(
            state: state,
            location: location
        )
        try isolatedCompatibilityJourney(
            executable: executable,
            legacyBytes: logBytes,
            expectedLegacyReport: report
        )
    }

    private static func isolatedCompatibilityJourney(
        executable: String,
        legacyBytes: Data,
        expectedLegacyReport: RunReport
    ) throws {
        let prepared = try makeBehindFixture(
            "body4-isolated-journey",
            executable: executable
        )
        defer { prepared.fixture.remove() }
        let operation = try refOnlyOperation(
            prepared.fixture,
            executable: executable
        )
        let coordinator = RunCoordinator(
            configuration: CoordinatorConfiguration(
                stateLocation: prepared.fixture.stateLocation,
                trampolineExecutable: executable,
                transportMapping: prepared.fixture.mapping
            ),
            account: prepared.fixture.account
        )
        let report = try coordinator.run(
            runID: RunIdentity.make(),
            operations: [operation],
            cancellation: CancellationToken(),
            eventSink: { _ in }
        )
        let current = try? prepared.fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        try expect(
            report.repositoryModel == "v2"
                && report.results.count == 1
                && report.results[0].code == .updated
                && current == prepared.target,
            "isolated authority-to-CAS report journey failed: "
                + "model=\(report.repositoryModel ?? "nil") "
                + "count=\(report.results.count) "
                + "code=\(report.results.first?.code.rawValue ?? "nil") "
                + "detail=\(report.results.first?.technicalDetail ?? "nil") "
                + "current=\(current ?? "nil") "
                + "target=\(prepared.target)"
        )
        let state = try SecureStateDirectory.open(
            prepared.fixture.stateLocation
        )
        let generated =
            try RunLogReader.snapshot(state: state)
        let terminal = Array(generated.records.suffix(3))
        try expect(
            generated.disposition == .current
                && terminal.map(\.type)
                    == [
                        "run_finished", "worker_exit", "event",
                    ]
                && terminal[0].report == report
                && terminal[2].event?.type == .runFinished
                && terminal[2].event?.run == report.run
                && terminal[2].event?.message == report.summary,
            "coordinator terminal log did not round-trip"
        )
        try DurableRunLogEvidence.validate(state: state)
        try replaceLatest(legacyBytes, state: state)
        let before = try fileSHA256(
            state.path + "/latest.log"
        )
        let reopened = RunRecoveryInspector.inspect(
            at: prepared.fixture.stateLocation
        )
        let after = try fileSHA256(
            state.path + "/latest.log"
        )
        try expect(
            reopened
                == .previousReport(
                    expectedLegacyReport
                ) && after == before,
            "isolated journey did not reopen legacy evidence read-only"
        )
    }

    private static func failureCuts(
        state: SecureStateDirectory,
        location: StateLocation,
        legacyBytes: Data
    ) throws {
        let latest = state.path + "/latest.log"
        let sibling = state.path + "/latest-hardlink"
        guard link(latest, sibling) == 0 else {
            throw Body4SelfTestError(
                "could not create latest.log hardlink cut"
            )
        }
        defer { _ = unlink(sibling) }
        try expectThrows(
            "hardlinked latest.log was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        _ = unlink(sibling)

        let incomplete =
            state.path
            + "/retention/.incomplete-ret-body4-fixture"
        try FileManager.default.createDirectory(
            atPath: incomplete,
            withIntermediateDirectories: false,
            attributes: [
                FileAttributeKey.posixPermissions: 0o700
            ]
        )
        try expectThrows(
            "incomplete retention slot was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        try FileManager.default.removeItem(
            atPath: incomplete
        )

        let authority =
            state.path + "/"
            + RepositoryAuthorityStore.filename
        let authorityBytes = try Data(
            contentsOf: URL(fileURLWithPath: authority)
        )
        try Data("{}\n".utf8).write(
            to: URL(fileURLWithPath: authority),
            options: .atomic
        )
        guard chmod(authority, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not secure corrupt authority cut"
            )
        }
        try expectThrows(
            "corrupt authority was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        try authorityBytes.write(
            to: URL(fileURLWithPath: authority),
            options: .atomic
        )
        guard chmod(authority, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not restore authority fixture"
            )
        }
        var futureAuthority =
            try JSONSerialization.jsonObject(
                with: authorityBytes
            ) as! [String: Any]
        futureAuthority["futureField"] = true
        try JSONSerialization.data(
            withJSONObject: futureAuthority,
            options: [.sortedKeys]
        ).write(
            to: URL(fileURLWithPath: authority),
            options: .atomic
        )
        guard chmod(authority, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not secure newer authority cut"
            )
        }
        try expectThrows(
            "newer authority schema was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        try authorityBytes.write(
            to: URL(fileURLWithPath: authority),
            options: .atomic
        )
        guard chmod(authority, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not restore authority after newer cut"
            )
        }

        try replaceLatest(
            Data("{\"schema\":\"future/v9\"}\n".utf8),
            state: state
        )
        try expectThrows(
            "newer latest.log was accepted by lifecycle"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        try replaceLatest(legacyBytes, state: state)

        guard chmod(latest, 0o400) == 0 else {
            throw Body4SelfTestError(
                "could not create wrong-mode latest.log cut"
            )
        }
        try expectThrows(
            "wrong-mode latest.log was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        guard chmod(latest, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not restore latest.log mode"
            )
        }

        let manifest =
            state.path
            + "/retention/ret-body4-fixture/manifest.json"
        let manifestBytes = try Data(
            contentsOf: URL(fileURLWithPath: manifest)
        )
        var futureManifest =
            try JSONSerialization.jsonObject(
                with: manifestBytes
            ) as! [String: Any]
        futureManifest["futureField"] = true
        try JSONSerialization.data(
            withJSONObject: futureManifest,
            options: [.sortedKeys]
        ).write(
            to: URL(fileURLWithPath: manifest),
            options: .atomic
        )
        guard chmod(manifest, 0o400) == 0 else {
            throw Body4SelfTestError(
                "could not protect newer retention cut"
            )
        }
        try expectThrows(
            "newer retention artifact was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        try manifestBytes.write(
            to: URL(fileURLWithPath: manifest),
            options: .atomic
        )
        guard chmod(manifest, 0o400) == 0 else {
            throw Body4SelfTestError(
                "could not restore retention after newer cut"
            )
        }
        guard chmod(manifest, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not create wrong-mode retention cut"
            )
        }
        try expectThrows(
            "wrong-mode retention artifact was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        guard chmod(manifest, 0o400) == 0 else {
            throw Body4SelfTestError(
                "could not restore retention mode"
            )
        }

        let bundle =
            state.path
            + "/retention/ret-body4-fixture/branch.bundle"
        let heldBundle = state.path + "/branch.bundle.held"
        guard rename(bundle, heldBundle) == 0 else {
            throw Body4SelfTestError(
                "could not create missing retention payload cut"
            )
        }
        try expectThrows(
            "missing retention payload was accepted"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }
        guard rename(heldBundle, bundle) == 0 else {
            throw Body4SelfTestError(
                "could not restore retention payload"
            )
        }
    }

    private static func v2EventPreservation(
        state: SecureStateDirectory,
        location: StateLocation
    ) throws {
        do {
            let authority = try RunAuthority.acquireRun(
                at: location
            )
            defer { authority.release() }
            let run = RunIdentity.make()
            let node = try Body3BatchNode(
                id: "body3-node:body4-v2-fields",
                repositoryID: "owner/legacy-repo",
                commonDirectoryKey: "clone:body4",
                kind: .policyInvalidation,
                dependencies: [],
                payload: .policyInvalidation(
                    repositoryID: "owner/legacy-repo"
                ),
                requiresExclusiveWorkerPool: true
            )
            let plan = try Body3BatchPlan(
                run: run,
                policyEvidenceDigest: "body4-policy",
                nodes: [node]
            )
            let writer = try Body3RunLogWriter(
                authority: authority,
                plan: plan
            )
            _ = try writer.append(
                type: "node_started",
                repository: "owner/legacy-repo",
                operation: node.id,
                kind: node.kind.rawValue,
                phase: "Policy reinspection",
                worker: 1,
                recommendation: "Keep",
                selection: "operator_override",
                awa: "unavailable",
                retention: "operator_override_risk",
                status: .running,
                detail: "Body 4 v2 override fields",
                technicalDetail: "sanitized technical evidence"
            )
            try writer.flush()
        }
        let latest = state.path + "/latest.log"
        let original = try Data(
            contentsOf: URL(fileURLWithPath: latest)
        )
        var records = try original.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        ).map { line in
            guard let record =
                    try JSONSerialization.jsonObject(
                        with: Data(line)
                    ) as? [String: Any] else {
                throw Body4SelfTestError(
                    "could not decode sanitized v2 lifecycle fixture"
                )
            }
            return record
        }
        guard let eventIndex = records.firstIndex(where: {
            $0["type"] as? String == "node_started"
        }) else {
            throw Body4SelfTestError(
                "sanitized v2 lifecycle fixture omitted its event"
            )
        }
        try expect(
            records[eventIndex]["detail"] as? String
                == "Body 4 v2 override fields"
                && records[eventIndex]["technicalDetail"] as? String
                    == "sanitized technical evidence",
            "detail and technicalDetail did not round-trip"
        )
        try DurableRunLogEvidence.validate(state: state)
        try InstallationLifecycle
            .testingPreserveAuthorityDuringRemoval(
                at: location
            )
        let before = try fileSHA256(latest)
        try expect(
            try fileSHA256(latest) == before,
            "v2 override/event evidence changed during lifecycle validation"
        )

        records[eventIndex]["unknownTechnicalSibling"] = "refuse"
        try replaceLatest(
            try encodedLog(records),
            state: state
        )
        try expectThrows(
            "unknown v2 sibling key passed durable validation"
        ) {
            try DurableRunLogEvidence.validate(state: state)
        }
        try expectThrows(
            "unknown v2 sibling key passed lifecycle validation"
        ) {
            try InstallationLifecycle
                .testingPreserveAuthorityDuringRemoval(
                    at: location
                )
        }

        records[eventIndex].removeValue(
            forKey: "unknownTechnicalSibling"
        )
        records[eventIndex].removeValue(
            forKey: "technicalDetail"
        )
        try replaceLatest(
            try encodedLog(records),
            state: state
        )
        try DurableRunLogEvidence.validate(state: state)
        try InstallationLifecycle
            .testingPreserveAuthorityDuringRemoval(
                at: location
            )

        try replaceLatest(original, state: state)
        try DurableRunLogEvidence.validate(state: state)
    }

    private static func installAuthorityAndRetention(
        state: SecureStateDirectory
    ) throws {
        let authority = try RepositoryAuthorityDocument(
            revision: 1,
            records: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let authorityPath =
            state.path + "/"
            + RepositoryAuthorityStore.filename
        try encoder.encode(authority).write(
            to: URL(fileURLWithPath: authorityPath),
            options: .atomic
        )
        guard chmod(authorityPath, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not secure authority fixture"
            )
        }
        let retention = state.path + "/retention"
        let artifact = retention + "/ret-body4-fixture"
        try FileManager.default.createDirectory(
            atPath: artifact,
            withIntermediateDirectories: true,
            attributes: [
                FileAttributeKey.posixPermissions: 0o700
            ]
        )
        guard chmod(retention, 0o700) == 0,
            chmod(artifact, 0o700) == 0
        else {
            throw Body4SelfTestError(
                "could not secure retention fixture"
            )
        }
        var stateInfo = stat()
        guard lstat(state.path, &stateInfo) == 0 else {
            throw Body4SelfTestError(
                "could not inspect retention fixture state"
            )
        }
        let tip = String(repeating: "a", count: 40)
        let bundleBytes = Data(
            "Body 4 protected branch bundle fixture\n".utf8
        )
        let bundlePath = artifact + "/branch.bundle"
        try bundleBytes.write(
            to: URL(fileURLWithPath: bundlePath),
            options: .atomic
        )
        guard chmod(bundlePath, 0o400) == 0 else {
            throw Body4SelfTestError(
                "could not protect retention payload"
            )
        }
        let proof = RetentionRestoreProof(
            verifiedAt: "2026-09-01T00:00:00.000Z",
            exactTipOID: tip,
            bundleVerified: true,
            connectivityVerified: true,
            entryManifestVerified: true,
            indexVerified: true,
            statusDigestVerified: true
        )
        let manifest = try RetentionManifest(
            artifactID: "ret-body4-fixture",
            repositoryID: "owner/legacy-repo",
            cloneID: "clone:body4",
            commonDirectoryIdentity:
                RepositoryDirectoryIdentity(
                    FileIdentity(stateInfo)
                ),
            worktreeID: nil,
            worktreeRootIdentity: nil,
            registrationIdentity: nil,
            branchRef: "refs/heads/evidence",
            tipOID: tip,
            objectFormat: "sha1",
            entries: [],
            indexSHA256: nil,
            sharedIndexFiles: [:],
            statusSHA256: nil,
            includedPaths: [],
            excludedPaths: [],
            secretShapedPaths: [],
            possibleSecretsAuthorized: true,
            createdAt: "2026-09-01T00:00:00.000Z",
            componentSHA256: [
                "branch.bundle": sha256(bundleBytes)
            ],
            restoreProof: proof,
            restoreInstructions: [
                "Readable evidence only; no automatic restore."
            ]
        )
        let manifestPath = artifact + "/manifest.json"
        try encoder.encode(manifest).write(
            to: URL(fileURLWithPath: manifestPath),
            options: .atomic
        )
        guard chmod(manifestPath, 0o400) == 0 else {
            throw Body4SelfTestError(
                "could not protect retention manifest"
            )
        }
        _ = try RetentionArtifactStore(
            state: state,
            account: try EffectiveAccount.current()
        ).list()
    }

    private struct PreparedRefOnly {
        let fixture: Body2Fixture
        let local: String
        let target: String
    }

    private static func makeBehindFixture(
        _ name: String,
        executable: String
    ) throws -> PreparedRefOnly {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: name
        )
        _ = try fixture.authorizedInventory(
            executable: executable
        )
        let local = try fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        try fixture.git(["checkout", "--quiet", "--detach"])
        try commit(fixture, value: name)
        let target = try fixture.gitText([
            "rev-parse", "HEAD",
        ])
        try fixture.git([
            "push", "--quiet", fixture.remotePath,
            "HEAD:refs/heads/main",
        ])
        try refreshTracking(fixture)
        return PreparedRefOnly(
            fixture: fixture,
            local: local,
            target: target
        )
    }

    private static func refreshTracking(
        _ fixture: Body2Fixture
    ) throws {
        try fixture.git([
            "fetch", "--quiet", fixture.remotePath,
            "refs/heads/main:refs/remotes/origin/main",
        ])
    }

    private static func commit(
        _ fixture: Body2Fixture,
        value: String
    ) throws {
        try Data("\(value)\n".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.repositoryPath + "/value.txt")
        )
        try fixture.git(["add", "value.txt"])
        try fixture.git([
            "commit", "--quiet", "-m", value,
        ])
    }

    private static func onlyCard(
        _ fixture: Body2Fixture,
        executable: String
    ) throws -> RepositoryCard {
        try require(
            try fixture.inventory(
                executable: executable
            ).cards.first,
            "fixture card is missing"
        )
    }

    private static func refOnlyOperation(
        _ fixture: Body2Fixture,
        executable: String
    ) throws -> PlannedOperation {
        let inventory = try fixture.inventory(
            executable: executable
        )
        let operation = try require(
            inventory.selectableOperations.first(where: {
                $0.kind == .fastForward
            }),
            "ref-only Fast-forward is not selectable: "
                + (inventory.cards.first?
                    .fastForwardRefusal
                    ?? "no refusal was reported")
                + " warnings="
                + (inventory.cards.first?.clones
                    .flatMap(\.warnings)
                    .joined(separator: "|")
                    ?? "none")
                + " block="
                + (inventory.cards.first?.clones.first?
                    .sourceSnapshot.blockedReason?
                    .rawValue
                    ?? "none")
        )
        try expect(
            operation.target.mode == .refOnly
                && operation.target.worktree == nil
                && operation.target.operationHookSHA256 != nil
                && operation.target.registrationSetSHA256
                    != nil
                && operation.target.preservationSHA256
                    != nil
                && operation.target.canonicalClone.branches
                    .first(where: {
                        $0.fullRef
                            == operation.target.resolvedDefault
                            .localRef
                    })?.claimingWorktreeIDs.isEmpty == true,
            "selected Fast-forward did not carry ref-only identity"
        )
        return operation
    }

    private static func execute(
        fixture: Body2Fixture,
        operation: PlannedOperation,
        executable: String,
        audit: CommandAudit? = nil,
        afterFetch:
            (@Sendable (String, RepositoryCandidate) -> Void)? = nil,
        beforeAction:
            (
                @Sendable (
                    PlannedOperationKind,
                    RepositoryCandidate
                ) -> Void
            )? = nil,
        runtimeEligibility:
            (@Sendable (RepositoryCandidate) throws -> Void)? = nil,
        finalMutationOnUpdate: String? = nil
    ) throws -> RepositoryResult {
        let authority = try RunAuthority.acquireRun(
            at: fixture.stateLocation
        )
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { Darwin.close(lease) }
        let configuration = GitTransactionConfiguration(
            trampolineExecutable: executable,
            operationLeaseDescriptor: lease,
            transportMapping: fixture.mapping,
            afterFetchCapture: afterFetch,
            finalMutationOnUpdate: finalMutationOnUpdate,
            runtimeEligibilityCheck: runtimeEligibility,
            maintenanceBeforeAction: beforeAction
        )
        let runner = DescriptorProcessRunner(audit: audit)
        if operation.kind == .fastForward {
            return FastForwardTransactionV2(
                runner: runner,
                configuration: configuration,
                account: fixture.account
            ).execute(
                operation: operation,
                cancellation: CancellationToken(),
                phase: { _ in }
            )
        }
        return RepositoryMaintenanceTransaction(
            runner: runner,
            configuration: configuration,
            account: fixture.account
        ).execute(
            operation: operation,
            cancellation: CancellationToken(),
            phase: { _ in }
        )
    }

    private static func refs(
        _ fixture: Body2Fixture,
        excluding excluded: String
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        let text = try fixture.gitText([
            "for-each-ref",
            "--format=%(refname) %(objectname)",
            "refs/",
        ])
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2 else {
                throw Body4SelfTestError(
                    "test ref inventory is malformed"
                )
            }
            let name = String(fields[0])
            if name != excluded {
                result[name] = String(fields[1])
            }
        }
        return result
    }

    private static func updateRefActions(
        _ audit: CommandAudit
    ) -> [CommandInvocation] {
        audit.invocations.filter {
            $0.arguments.contains("update-ref")
        }
    }

    private static func installReferenceHook(
        _ fixture: Body2Fixture,
        body: String,
        hooksDirectory: String? = nil
    ) throws {
        let hook =
            (hooksDirectory
                ?? fixture.repositoryPath + "/.git/hooks")
            + "/reference-transaction"
        try Data(body.utf8).write(
            to: URL(fileURLWithPath: hook)
        )
        guard chmod(hook, 0o700) == 0 else {
            throw Body4SelfTestError(
                "could not install reference hook"
            )
        }
    }

    private static var fixtureDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Tests/ShadowSyncSelfTests/Fixtures"
            ).path
    }

    private static func replaceLatest(
        _ bytes: some DataProtocol,
        state: SecureStateDirectory
    ) throws {
        let path = state.path + "/latest.log"
        try Data(bytes).write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )
        guard chmod(path, 0o600) == 0 else {
            throw Body4SelfTestError(
                "could not secure latest.log fixture"
            )
        }
    }

    private static func encodedLog(
        _ records: [[String: Any]]
    ) throws -> Data {
        var data = Data()
        for record in records {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: record,
                    options: [.sortedKeys]
                )
            )
            data.append(0x0A)
        }
        return data
    }

    private static func expectIncompatible(
        _ state: SecureStateDirectory,
        _ name: String
    ) throws {
        let read = try RunLogReader.snapshot(state: state)
        guard case .incompatible = read.disposition else {
            throw Body4SelfTestError(
                "\(name) was accepted"
            )
        }
    }

    private static func fileSHA256(
        _ path: String
    ) throws -> String {
        sha256(
            try Data(
                contentsOf: URL(fileURLWithPath: path)
            ))
    }

    private static func sha256(
        _ data: Data
    ) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Body4SelfTestError(
                        "test fixture write failed"
                    )
                }
            }
        }
    }

    private static func replaceCommonOperationLock(
        _ fixture: Body2Fixture
    ) throws {
        let commonDirectory =
            fixture.repositoryPath + "/.git"
        let key = String(
            SHA256.hash(
                data: Data(commonDirectory.utf8)
            ).map {
                String(format: "%02x", $0)
            }.joined().prefix(24)
        )
        let path =
            fixture.home
            + "/.local/state/awa/locks/common-\(key).lock"
        guard unlink(path) == 0 else {
            throw Body4SelfTestError(
                "could not unlink operation-lock fixture"
            )
        }
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw Body4SelfTestError(
                "could not replace operation-lock fixture"
            )
        }
        Darwin.close(descriptor)
    }

    private static func replaceCommonOperationLockDirectory(
        _ fixture: Body2Fixture
    ) throws {
        let path =
            fixture.home + "/.local/state/awa/locks"
        let moved =
            fixture.home + "/.local/state/awa/locks-replaced"
        guard rename(path, moved) == 0,
            mkdir(path, 0o700) == 0
        else {
            throw Body4SelfTestError(
                "could not replace operation-lock directory fixture"
            )
        }
    }

    private static func require<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw Body4SelfTestError(message)
        }
        return value
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw Body4SelfTestError(message)
        }
    }

    private static func expectThrows(
        _ message: String,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw Body4SelfTestError(message)
    }
}

private final class LockedBody4Mutation:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var error: Error?

    func capture(_ body: () throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try body()
        } catch {
            self.error = error
        }
    }

    func rethrowIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw error
        }
    }
}

private struct DurableBody4Snapshot: Equatable {
    private struct Entry: Equatable {
        let identity: FileIdentity
        let mode: UInt16
        let size: Int64
        let sha256: String?
    }

    private let entries: [String: Entry]

    init(state: SecureStateDirectory) throws {
        let roots = [
            "latest.log",
            RepositoryAuthorityStore.filename,
            "retention",
        ]
        var captured: [String: Entry] = [:]
        for root in roots {
            let path = state.path + "/\(root)"
            try Self.capture(
                path: path,
                relative: root,
                into: &captured
            )
        }
        entries = captured
    }

    private static func capture(
        path: String,
        relative: String,
        into result: inout [String: Entry]
    ) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Body4SelfTestError(
                "durable snapshot entry is missing"
            )
        }
        let kind = mode_t(info.st_mode) & S_IFMT
        let digest: String?
        if kind == S_IFREG {
            let data = try Data(
                contentsOf: URL(fileURLWithPath: path)
            )
            digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        } else if kind == S_IFDIR {
            digest = nil
        } else {
            throw Body4SelfTestError(
                "durable snapshot found an unsafe entry"
            )
        }
        result[relative] = Entry(
            identity: FileIdentity(info),
            mode: UInt16(info.st_mode & 0o7777),
            size: Int64(info.st_size),
            sha256: digest
        )
        if kind == S_IFDIR {
            for name in try FileManager.default
                .contentsOfDirectory(atPath: path).sorted()
            {
                try capture(
                    path: path + "/\(name)",
                    relative: relative + "/\(name)",
                    into: &result
                )
            }
        }
    }
}

private struct Body4SelfTestError:
    Error, CustomStringConvertible
{
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
