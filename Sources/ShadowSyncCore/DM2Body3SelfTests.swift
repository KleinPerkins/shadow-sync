#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation

public enum V2Body3SelfTestRunner {
    public typealias Observer = (String) -> Void

    public static func runAll(
        testExecutable: String,
        observer: Observer = { _ in }
    ) throws {
        for id in [
            "DM2-T08 recommendation-permission",
            "DM2-T09 recovery-artifact",
            "DM2-T10 AWA-advisory-override",
            "DM2-T11 batch-cancel-policy",
            "DM2-T12 card-events-recovery",
            "DM2-T15 native-removal-override",
            "DM2-T16 direct-human-runtime",
        ] {
            try runFocused(
                String(id.prefix(7)).lowercased(),
                testExecutable: testExecutable,
                observer: observer
            )
        }
    }

    public static func runFocused(
        _ requested: String,
        testExecutable: String,
        observer: Observer = { _ in }
    ) throws {
        let id = requested.lowercased()
            .replacingOccurrences(of: "dm2-", with: "")
        switch id {
        case "t08":
            try RuntimeFixtureSession.withCase("DM2-T08 recommendation-permission") {
                try recommendationPermission(
                    executable: testExecutable
                )
            }
            observer("DM2-T08 recommendation-permission")
        case "t09":
            try RuntimeFixtureSession.withCase("DM2-T09 recovery-artifact") {
                try recoveryArtifact(
                    executable: testExecutable
                )
            }
            observer("DM2-T09 recovery-artifact")
        case "t10":
            try RuntimeFixtureSession.withCase("DM2-T10 AWA-advisory-override") {
                try awaAdvisoryOverride(
                    executable: testExecutable
                )
            }
            observer("DM2-T10 AWA-advisory-override")
        case "t11":
            try RuntimeFixtureSession.withCase("DM2-T11 batch-cancel-policy") {
                try batchCancelPolicy(
                    executable: testExecutable
                )
            }
            observer("DM2-T11 batch-cancel-policy")
        case "t12":
            try RuntimeFixtureSession.withCase("DM2-T12 card-events-recovery") {
                try cardEventsRecovery(
                    executable: testExecutable
                )
            }
            observer("DM2-T12 card-events-recovery")
        case "t15":
            try RuntimeFixtureSession.withCase("DM2-T15 native-removal-override") {
                try nativeRemovalOverride(
                    executable: testExecutable
                )
            }
            observer("DM2-T15 native-removal-override")
        case "t15-branch":
            try RuntimeFixtureSession.withCase("DM2-T15 branch-removal focused cut") {
                try branchCASAndClaimGate(
                    executable: testExecutable
                )
            }
            observer(
                "DM2-T15 branch-removal focused cut"
            )
        case "t16":
            try RuntimeFixtureSession.withCase("DM2-T16 direct-human-runtime") {
                try directHumanRuntime(
                    executable: testExecutable
                )
            }
            observer("DM2-T16 direct-human-runtime")
        default:
            throw Body3SelfTestError(
                "unknown focused Body 3 test \(requested)"
            )
        }
    }

    public static func runBetaV06(
        observer: Observer = { _ in }
    ) throws {
        try RuntimeFixtureSession.withCase("BETA-V06-BODY3-COMPATIBILITY") {
            let run = RunIdentity.make()
            let node = try Body3BatchNode(
                id:
                    "body3-node:policyInvalidation:"
                    + String(run.prefix(12)),
                repositoryID: "fixture/v06",
                commonDirectoryKey: "clone:v06",
                kind: .policyInvalidation,
                dependencies: [],
                payload: .policyInvalidation(
                    repositoryID: "fixture/v06"
                ),
                requiresExclusiveWorkerPool: true
            )
            let start =
                "2027-01-15T08:00:00.000Z"
            let end =
                "2027-01-15T08:00:02.000Z"
            let plan = try Body3BatchPlan(
                run: run,
                createdAt: start,
                policyEvidenceDigest:
                    String(repeating: "a", count: 64),
                nodes: [node]
            )
            let secret = String(repeating: "x", count: 3_000)
            let result = Body3BatchNodeResult(
                node: node,
                status: .succeeded,
                worker: 1,
                startedAt: start,
                endedAt: end,
                durationMilliseconds: 2_000,
                detail: "Public completion.",
                technicalDetail:
                    "token=private-value "
                    + "https://user:pass@example.test/private "
                    + "/" + "Users/operator/private HOME="
                    + "/" + "Users/operator "
                    + secret
            )
            guard let technical = result.technicalDetail else {
                throw Body3SelfTestError(
                    "v0.6 technical detail was dropped"
                )
            }
            try expect(
                technical.utf8.count
                    <= Body3TechnicalDetail.maximumUTF8Bytes
                    && !technical.contains("private-value")
                    && !technical.contains("example.test")
                    && !technical.contains("/Users/operator")
                    && technical.contains("[REDACTED"),
                "v0.6 technical detail was not bounded and redacted"
            )
            let report = try Body3BatchReport(
                run: run,
                startedAt: start,
                endedAt: end,
                cancelled: false,
                results: [result]
            )
            let metadata = try Body3BatchMetadata.derive(
                plan: plan,
                report: report
            )
            try expect(
                metadata.durationMilliseconds == 2_000
                    && metadata.repositoryIDs
                        == ["fixture/v06"]
                    && metadata.attemptedActionCount == 1
                    && metadata.outcomeCounts[.succeeded]
                        == 1,
                "v0.6 historical metadata derivation changed"
            )
            let contradictory = try Body3BatchReport(
                run: run,
                startedAt: end,
                endedAt: start,
                cancelled: false,
                results: [result]
            )
            do {
                _ = try Body3BatchMetadata.derive(
                    plan: plan,
                    report: contradictory
                )
                throw Body3SelfTestError(
                    "contradictory v0.6 metadata was accepted"
                )
            } catch is GitSafetyError {
                // Expected.
            }

            let oldResult = Body3BatchNodeResult(
                node: node,
                status: .succeeded,
                worker: 1,
                startedAt: start,
                endedAt: end,
                durationMilliseconds: 2_000,
                detail: "Public completion."
            )
            let oldReport = try Body3BatchReport(
                run: run,
                startedAt: start,
                endedAt: end,
                cancelled: false,
                results: [oldResult]
            )
            let records = [
                Body3LogRecord(
                    run: run,
                    sequence: 1,
                    type: "plan",
                    phase: "Queued",
                    detail:
                        "Immutable selected operation plan recorded.",
                    plan: plan
                ),
                Body3LogRecord(
                    run: run,
                    sequence: 2,
                    type: "node_started",
                    repository: node.repositoryID,
                    operation: node.id,
                    kind: node.kind.rawValue,
                    phase: node.kind.phase,
                    worker: 1,
                    status: .running,
                    detail: "Node admitted."
                ),
                Body3LogRecord(
                    run: run,
                    sequence: 3,
                    type: "node_terminal",
                    repository: node.repositoryID,
                    operation: node.id,
                    kind: node.kind.rawValue,
                    phase: node.kind.phase,
                    worker: 1,
                    status: .succeeded,
                    detail: oldResult.detail,
                    durationMilliseconds: 2_000
                ),
                Body3LogRecord(
                    run: run,
                    sequence: 4,
                    type: "run_finished",
                    phase: "Complete",
                    status: .succeeded,
                    detail: "One node reached terminal state.",
                    report: oldReport
                ),
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            var oldV2 = Data()
            for record in records {
                let encoded = try encoder.encode(record)
                try expect(
                    !String(decoding: encoded, as: UTF8.self)
                        .contains("\"technicalDetail\""),
                    "nil additive field changed old v2 bytes"
                )
                oldV2.append(encoded)
                oldV2.append(0x0A)
            }
            let decoded = Body3RunLogReader.decode(oldV2)
            try expect(
                decoded == records
                    && decoded.allSatisfy {
                        $0.technicalDetail == nil
                    },
                "pre-v0.6 v2 log no longer decodes"
            )
            let pinnedPath = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Tests/ShadowSyncSelfTests/Fixtures/"
                        + "pre-v06-v2-latest.log"
                )
            let pinnedOldV2 = try Data(
                contentsOf: pinnedPath
            )
            let pinnedDigest = SHA256.hash(
                data: pinnedOldV2
            ).map {
                String(format: "%02x", $0)
            }.joined()
            let pinnedRecords =
                Body3RunLogReader.decode(pinnedOldV2)
            try expect(
                pinnedDigest
                    == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a"
                    && pinnedRecords.count == 4
                    && pinnedRecords.first?.plan != nil
                    && pinnedRecords.last?.report != nil
                    && pinnedRecords.allSatisfy {
                        $0.technicalDetail == nil
                            && (
                                $0.report?.results.allSatisfy {
                                    $0.technicalDetail == nil
                                } ?? true
                            )
                    },
                "pinned pre-v0.6 v2 fixture drifted or stopped decoding"
            )

            var malformedLines = oldV2.split(
                separator: 0x0A
            ).map(Data.init)
            var malformedObject =
                try JSONSerialization.jsonObject(
                    with: malformedLines[2]
                ) as! [String: Any]
            malformedObject["technicalDetail"] =
                "/" + "Users/operator/unredacted/token=private"
            malformedLines[2] = try JSONSerialization.data(
                withJSONObject: malformedObject,
                options: [.sortedKeys]
            )
            var malformed = Data()
            for line in malformedLines {
                malformed.append(line)
                malformed.append(0x0A)
            }
            try expect(
                Body3RunLogReader.decode(malformed).isEmpty,
                "unredacted v0.6 detail did not fail closed"
            )
            let malformedState = try M1TemporaryDirectory()
            defer { malformedState.remove() }
            let malformedLocation = try StateLocation.isolated(
                root: malformedState.path
            )
            try TestIsolation.initializeState(at: malformedLocation)
            var malformedAuthority: RunAuthority? =
                try RunAuthority.acquireRun(
                    at: malformedLocation
                )
            var malformedWriter: Body3RunLogWriter? =
                try Body3RunLogWriter(
                    authority: malformedAuthority!,
                    plan: plan
                )
            try malformedWriter?.flush()
            malformedWriter = nil
            malformedAuthority?.release()
            malformedAuthority = nil
            try malformed.writeFixtureAtomically(
                to: URL(
                    fileURLWithPath:
                        malformedLocation.path
                        + "/latest.log"
                )
            )
            let malformedHome =
                malformedState.path + "/home"
            try FileManager.default.createDirectory(
                atPath: malformedHome,
                withIntermediateDirectories: true
            )
            let malformedRecovery =
                Body3RunRecoveryInspector.inspect(
                    at: malformedLocation,
                    account:
                        try EffectiveAccount.isolated(
                            homeDirectory: malformedHome
                        )
                )
            try expect(
                malformedRecovery == .needsAttention,
                "complete malformed v0.6 log allowed a new run"
            )
        }
        observer("BETA-V06-BODY3-COMPATIBILITY")
    }

    public static func runBetaV07(
        observer: Observer = { _ in }
    ) throws {
        try RuntimeFixtureSession.withCase("BETA-V07-BODY3-LINEAR-LOG") {
            let compiledBefore =
                Redactor.testingCompiledExpressionIdentifiers
            try expect(
                compiledBefore.count == 8,
                "v0.7 redaction expression set changed"
            )
            let records = (1...1_632).map { sequence in
                Body3LogRecord(
                    run: "v07-high-volume",
                    sequence: sequence,
                    type: "command",
                    repository:
                        "fixture/repository-\(sequence % 5)",
                    operation:
                        "operation-\(sequence % 20)",
                    phase: "High-volume fixture",
                    worker: sequence % 2 + 1,
                    executable: "/usr/bin/git",
                    arguments: [
                        "status",
                        "token=ghp_abcdefghijklmnopqrstuvwxyz",
                        String(repeating: "x", count: 96),
                    ],
                    outcome: "exit 0",
                    detail:
                        "record \(sequence) authorization=Bearer secret-value"
                )
            }
            let maximumCharacters = 8_192
            let projection = Body3RunLogProjection(
                maximumCharacters: maximumCharacters
            )
            for record in records.prefix(816) {
                projection.append(record)
            }
            try expect(
                projection.metrics.recordVisits == 816,
                "v0.7 projection revisited a prior prefix"
            )
            for record in records.dropFirst(816) {
                projection.append(record)
            }
            let canonical = Body3RunLogReader.render(
                records,
                maximumCharacters:
                    maximumCharacters
            )
            let metrics = projection.metrics
            try expect(
                projection.text == canonical,
                "v0.7 incremental projection changed bounded rendering"
            )
            try expect(
                metrics.recordVisits == records.count
                    && metrics.retainedCharacterCount
                        <= maximumCharacters
                    && metrics.omittedEarlierEvents,
                "v0.7 projection work or retained bound is invalid"
            )
            let expectedCharacters = records.map(
                Body3RunLogReader.renderLine
            ).joined(separator: "\n").count
            try expect(
                metrics.renderedCharacterCount
                    == expectedCharacters,
                "v0.7 projection did not account once per rendered character"
            )
            try expect(
                !projection.text.contains("secret-value")
                    && !projection.text.contains("ghp_"),
                "v0.7 incremental projection leaked redacted data"
            )
            let compiledAfter =
                Redactor.testingCompiledExpressionIdentifiers
            try expect(
                compiledAfter == compiledBefore,
                "v0.7 redaction expressions were recompiled"
            )
            let unicodeRecords = (1...40).map {
                sequence in
                Body3LogRecord(
                    run: "v07-unicode",
                    sequence: sequence,
                    type: "event",
                    detail:
                        "👩🏽‍💻 café e\u{301} record \(sequence)"
                )
            }
            let unicodeProjection =
                Body3RunLogProjection(
                    maximumCharacters: 128
                )
            let visible = NSMutableString()
            var includesMarker = false
            var sawDistinctUTF16Count = false
            for record in unicodeRecords {
                let mutation =
                    unicodeProjection.append(record)
                visible.append(mutation.appendedText)
                if mutation.removedLeadingUTF16Units > 0 {
                    let bodyStart = includesMarker
                        ? Body3RunLogProjection
                            .omissionMarker.utf16.count
                        : 0
                    visible.deleteCharacters(
                        in: NSRange(
                            location: bodyStart,
                            length:
                                mutation
                                    .removedLeadingUTF16Units
                        )
                    )
                }
                if mutation.startedOmittingEarlierEvents {
                    visible.insert(
                        Body3RunLogProjection
                            .omissionMarker,
                        at: 0
                    )
                    includesMarker = true
                }
                sawDistinctUTF16Count =
                    sawDistinctUTF16Count
                    || mutation.removedLeadingUTF16Units
                        != mutation
                            .removedLeadingCharacters
            }
            try expect(
                visible as String
                    == unicodeProjection.text
                    && unicodeProjection.text
                        == Body3RunLogReader.render(
                            unicodeRecords,
                            maximumCharacters: 128
                        )
                    && sawDistinctUTF16Count,
                "v0.7 Unicode projection or UTF-16 mutation changed bounded rendering"
            )
        }
        observer("BETA-V07-BODY3-LINEAR-LOG")
    }

    private static func currentDirectoryChild(_ path: String) throws -> (OwnedSpawnAnchor, OwnedDirectChild) {
        let registry = try RuntimeFixtureSession.current()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try expect(posix_spawn_file_actions_init(&actions) == 0, "current-directory child file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try expect(posix_spawnattr_init(&attributes) == 0, "current-directory child attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try expect(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0, "current-directory child null stream")
        }
        try expect(posix_spawn_file_actions_addchdir_np(&actions, path) == 0,
                   "current-directory child cwd")
        var defaults = sigset_t(); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var mask = sigset_t(); sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try expect(posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
            && posix_spawnattr_setsigmask(&attributes, &mask) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setflags(&attributes, flags) == 0, "current-directory child closed attributes")
        let strings = (["/bin/sleep", "30"] as [String]).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try expect(strings.allSatisfy { $0 != nil }, "current-directory child arguments")
        var argv = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in
            try environment.withUnsafeMutableBufferPointer { ev in
                try RuntimeFixtureSpawn.spawn(registry: registry, executable: "/bin/sleep",
                    actions: &actions, attributes: &attributes, arguments: av.baseAddress,
                    environment: ev.baseAddress, streamsDrained: { true })
            }
        }
        do {
            let owner = try anchor.transfer(expectedExecutable: "/bin/sleep", generation: RunIdentity.make(),
                                            reapPolicy: .afterGroupDrain)
            try expect(owner.send(SIGCONT), "current-directory child admission refused")
            return (anchor, owner)
        } catch {
            RuntimeFixtureSession.drain(anchor)
            throw error
        }
    }

    private static func recommendationPermission(
        executable: String
    ) throws {
        let clean = WorktreeFileState(
            trackedChanges: 0,
            untrackedFiles: 0,
            ignoredFiles: 0,
            hiddenIndexState: false,
            operationState: .clear
        )
        let dirty = WorktreeFileState(
            trackedChanges: 2,
            untrackedFiles: 1,
            ignoredFiles: 1,
            hiddenIndexState: true,
            operationState: .clear
        )
        func worktree(
            file: WorktreeFileState? = clean,
            awa: AWAEvidence = .notManaged,
            purpose: WorkPurpose? = .completed,
            activity: ActivityBand? = .idle,
            preserved: Bool? = true,
            supported: Bool = true,
            failed: Bool = false,
            current: Bool = false,
            locked: Bool = false
        ) -> RemovalPreview {
            RemovalPreviewOracle.worktree(
                isResolvedDefaultClaim: false,
                policyCategory: .writable,
                verification: .verified,
                fileState: file,
                awa: awa,
                purpose: purpose,
                activity: activity,
                branchTipPreserved: preserved,
                recoverySupported: supported,
                preservationFailed: failed,
                currentSession: current,
                isLocked: locked
            )
        }
        try expect(
            worktree().recommendation == .recommended,
            "fulfilled clean Worktree was not Recommended"
        )
        try expect(
            worktree(file: dirty).recommendation == .recovery,
            "capturable dirty Worktree did not require recovery"
        )
        try expect(
            worktree(file: dirty, supported: false)
                .recommendation == .override,
            "unsupported recovery did not become Override risk"
        )
        for preview in [
            worktree(activity: .recent),
            worktree(purpose: .active),
            worktree(current: true),
            worktree(locked: true),
            worktree(file: nil),
            worktree(awa: AWAEvidence(
                state: .active,
                explanation: "active",
                blocksRemoval: true
            )),
            worktree(awa: AWAEvidence(
                state: .stale,
                explanation: "stale",
                blocksRemoval: true
            )),
            worktree(awa: AWAEvidence(
                state: .unavailable,
                explanation: "unavailable",
                blocksRemoval: true
            )),
        ] {
            try expect(
                preview.recommendation == .keep,
                "protective Worktree evidence did not recommend Keep"
            )
            try expect(
                preview.permission == .previewOnly,
                "Worktree recommendation granted permission"
            )
        }

        func branch(
            claims: [String] = [],
            purpose: WorkPurpose = .completed,
            activity: ActivityBand = .idle,
            preserved: Bool? = true,
            supported: Bool = true,
            failed: Bool = false,
            current: Bool = false
        ) -> RemovalPreview {
            RemovalPreviewOracle.branch(
                isResolvedDefault: false,
                policyCategory: .writable,
                claimIDs: claims,
                purpose: purpose,
                activity: activity,
                tipPreserved: preserved,
                recoverySupported: supported,
                preservationFailed: failed,
                currentSession: current
            )
        }
        try expect(
            branch().recommendation == .recommended,
            "preserved fulfilled Branch was not Recommended"
        )
        try expect(
            branch(preserved: false).recommendation
                == .recovery,
            "capturable unique Branch did not require recovery"
        )
        try expect(
            branch(preserved: false, supported: false)
                .recommendation == .override,
            "unpreserved unsupported Branch was not Override risk"
        )
        let claimed = branch(
            claims: ["worktree:claim"],
            purpose: .completed,
            preserved: true,
            failed: true,
            current: true
        )
        try expect(
            claimed.recommendation == .keep
                && claimed.permission == .dependencyBlocked,
            "Branch claims did not take closed precedence"
        )
        for preview in [
            branch(purpose: .active),
            branch(purpose: .closedIncomplete),
            branch(purpose: .ambiguous),
            branch(activity: .recent),
            branch(current: true),
        ] {
            try expect(
                preview.recommendation == .keep
                    && preview.permission == .previewOnly,
                "protective Branch evidence did not stay independent from permission"
            )
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func band(_ days: Int) -> ActivityBand {
            ActivityBandOracle.classify(
                capturedNow: now,
                commitDate: now.addingTimeInterval(
                    -Double(days) * 86_400
                ),
                associatedPullRequests: []
            )
        }
        try expect(
            band(7) == .recent && band(8) == .idle
                && band(30) == .idle
                && band(31) == .staleCandidate,
            "7/8/30/31 complete-day boundaries changed"
        )

        let fixture = try Body3Fixture(
            repositoryName: "body3-t08"
        )
        defer { fixture.remove() }
        let path = try fixture.addWorktree(
            "recommended",
            managedByAWA: false
        )
        let (anchor, activeProcess) = try currentDirectoryChild(path)
        defer { RuntimeFixtureSession.drain(anchor) }
        usleep(20_000)
        try expect(
            try CurrentSessionWorktreeDetector.inspectOwnedChild(
                worktreePath: path,
                account: fixture.account,
                child: activeProcess
            ) == .active,
            "live current-directory process was not a current-session signal"
        )
        RuntimeFixtureSession.drain(anchor)
        guard case .reaped = activeProcess.observation else {
            throw Body3SelfTestError("current-session fixture child was not reaped")
        }
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let recommended = try fixture.worktreeCandidate(
            inventory: inventory,
            path: path,
            preview: worktree()
        )
        let keep = try fixture.worktreeCandidate(
            inventory: inventory,
            path: path,
            preview: worktree(activity: .recent),
            identitySuffix: "keep",
            currentSession: false
        )
        var selections = RemovalSelectionSet()
        try selections.selectAllRecommended([
            recommended, keep,
        ], selected: true)
        try expect(
            Set(selections.selections.keys)
                == [recommended.id],
            "cleanup Select All was not Recommended-only: "
                + (recommended.hardExclusion ?? "no hard exclusion")
        )
        try selections.set(
            candidate: keep,
            selected: true,
            intent: .removeAnyway
        )
        try expect(
            selections.selections[keep.id]?.intent
                == .removeAnyway,
            "Keep did not require an individual explicit choice"
        )
        let recommendedSelection = try RemovalSelection(
            candidate: recommended,
            intent: .remove,
            includePossibleSecrets: false
        )
        let recommendedPlan = try Body3BatchPlanner.make(
            run: RunIdentity.make(),
            operations: [],
            removals: [recommendedSelection]
        )
        try expect(
            !recommendedPlan.nodes.contains {
                $0.kind == .retention
            },
            "Recommended clean cleanup planned an inapplicable recovery artifact"
        )
        let keepSelection = try require(
            selections.selections[keep.id],
            "Keep override selection disappeared"
        )
        let keepPrepared =
            try PreparedRemovalOracle.prepare(
                selection: keepSelection,
                retention: nil
            )
        let keepConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: keepPrepared,
                        retained: true
                    ),
                ]
            )
        let newlyActive =
            try fixture.worktreeCandidate(
                inventory: inventory,
                path: path,
                preview: worktree(
                    activity: .recent
                ),
                identitySuffix: "keep",
                currentSession: true
            )
        let newlyActivePrepared =
            try PreparedRemovalOracle.prepare(
                selection: RemovalSelection(
                    candidate: newlyActive,
                    intent: .removeAnyway,
                    includePossibleSecrets: false
                ),
                retention: nil
            )
        try expect(
            !keepConfirmation.authorizes(
                newlyActivePrepared
            ),
            "new current-session activity reused a same-class confirmation"
        )
        let newlyAWAWarned =
            try fixture.worktreeCandidate(
                inventory: inventory,
                path: path,
                preview: worktree(
                    activity: .recent
                ),
                identitySuffix: "keep",
                currentSession: false,
                awaEvidence: AWAEvidence(
                    state: .active,
                    explanation:
                        "New active lease.",
                    blocksRemoval: true
                )
            )
        let newlyAWAPrepared =
            try PreparedRemovalOracle.prepare(
                selection: RemovalSelection(
                    candidate: newlyAWAWarned,
                    intent: .removeAnyway,
                    includePossibleSecrets: false
                ),
                retention: nil
            )
        try expect(
            !keepConfirmation.authorizes(
                newlyAWAPrepared
            ),
            "new AWA liveness risk reused a same-class confirmation"
        )
    }

    private static func recoveryArtifact(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t09"
        )
        defer { fixture.remove() }
        let path = try fixture.addWorktree(
            "recovery",
            managedByAWA: false,
            uniqueCommit: true
        )
        try fixture.makeRecoveryState(at: path)
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let preview = RemovalPreviewOracle.worktree(
            isResolvedDefaultClaim: false,
            policyCategory: .writable,
            verification: .verified,
            fileState: WorktreeFileState(
                trackedChanges: 3,
                untrackedFiles: 2,
                ignoredFiles: 1,
                hiddenIndexState: true,
                operationState: .clear
            ),
            awa: .notManaged,
            purpose: .completed,
            activity: .idle,
            branchTipPreserved: false
        )
        let candidate = try fixture.worktreeCandidate(
            inventory: inventory,
            path: path,
            preview: preview
        )
        let declined = try RemovalSelection(
            candidate: candidate,
            intent: .removeWithRecovery,
            includePossibleSecrets: false
        )
        let store = try fixture.retentionStore()
        let before = try store.list()
        let declinedPreparation = store.prepare(
            selection: declined,
            cancellation: CancellationToken()
        )
        guard case let .incomplete(
            excluded, secrets, _
        ) = declinedPreparation else {
            throw Body3SelfTestError(
                "secret-declined artifact was not incomplete"
            )
        }
        try expect(
            !excluded.isEmpty && !secrets.isEmpty,
            "secret-declined omissions were not bounded and explicit"
        )
        try expect(
            try store.list() == before,
            "secret-declined recovery published payload bytes"
        )
        let declinedPrepared =
            try PreparedRemovalOracle.prepare(
                selection: declined,
                retention: declinedPreparation
            )
        try expect(
            declinedPrepared.finalClass
                == .operatorOverrideRisk
                && declinedPrepared.artifact == nil
                && declinedPrepared.consequence
                    .contains(".env"),
            "secret decline did not become a named Operator override risk"
        )

        let accepted = try RemovalSelection(
            candidate: candidate,
            intent: .removeWithRecovery,
            includePossibleSecrets: true
        )
        let preparation = store.prepare(
            selection: accepted,
            cancellation: CancellationToken()
        )
        guard case let .completed(summary) = preparation else {
            let diagnostic: String
            switch preparation {
            case let .incomplete(_, _, reason):
                diagnostic = reason
            case .cancelled:
                diagnostic = "cancelled"
            case .completed:
                diagnostic = "unexpected"
            }
            throw Body3SelfTestError(
                "restore-proven artifact was not completed: \(diagnostic)"
            )
        }
        try expect(
            summary.tipOID == candidate.expectedOID
                && summary.restoreProven
                && (try store.verify(summary)),
            "artifact did not restore exact tip/files/index/status"
        )
        let recoveryPrepared =
            try PreparedRemovalOracle.prepare(
                selection: accepted,
                retention: preparation
            )
        let recommendedCandidate =
            try fixture.worktreeCandidate(
                inventory: inventory,
                path: path,
                preview: RemovalPreview(
                    recommendation: .recommended,
                    permission: .previewOnly,
                    explanation:
                        "Fulfilled, clean, and preserved."
                ),
                identitySuffix: "recommended-group"
            )
        let overrideCandidate =
            try fixture.worktreeCandidate(
                inventory: inventory,
                path: path,
                preview: RemovalPreview(
                    recommendation: .keep,
                    permission: .previewOnly,
                    explanation:
                        "Active work recommends Keep.",
                    overrideConsequence:
                        "Removing may disrupt active work."
                ),
                identitySuffix: "override-group"
            )
        let recommendedPrepared =
            try PreparedRemovalOracle.prepare(
                selection: RemovalSelection(
                    candidate: recommendedCandidate,
                    intent: .remove,
                    includePossibleSecrets: false
                ),
                retention: nil
            )
        let overridePrepared =
            try PreparedRemovalOracle.prepare(
                selection: RemovalSelection(
                    candidate: overrideCandidate,
                    intent: .removeAnyway,
                    includePossibleSecrets: false
                ),
                retention: nil
            )
        let grouped = try GroupedRemovalConfirmation(
            run: RunIdentity.make(),
            rows: [
                ConfirmedRemovalRow(
                    prepared: recommendedPrepared,
                    retained: true
                ),
                ConfirmedRemovalRow(
                    prepared: recoveryPrepared,
                    retained: true
                ),
                ConfirmedRemovalRow(
                    prepared: overridePrepared,
                    retained: true
                ),
            ]
        )
        try expect(
            grouped.rows(in: .recommended).count == 1
                && grouped.rows(in: .recoveryBacked)
                    .count == 1
                && grouped.rows(
                    in: .operatorOverrideRisk
                ).count == 1,
            "grouped confirmation did not preserve all three final classes"
        )
        let manifestURL = URL(
            fileURLWithPath: summary.path
        ).appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            RetentionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let paths = Set(manifest.entries.map(\.path))
        try expect(
            manifest.schema == shadowSyncRetentionSchema
                && manifest.possibleSecretsAuthorized
                && manifest.restoreProof.isComplete
                && manifest.indexSHA256 != nil
                && manifest.statusSHA256 != nil
                && !manifest.sharedIndexFiles.isEmpty
                && manifest.componentSHA256[
                    "branch.bundle"
                ] != nil
                && manifest.componentSHA256[
                    "worktree.tar"
                ] != nil
                && paths.contains("tracked.txt")
                && paths.contains("staged.txt")
                && paths.contains("untracked.txt")
                && paths.contains(".env")
                && paths.contains("empty")
                && paths.contains("link-to-tracked"),
            "artifact omitted required history/file/index classes"
        )
        var artifactInfo = stat()
        var manifestInfo = stat()
        try expect(
            lstat(summary.path, &artifactInfo) == 0
                && (artifactInfo.st_mode & 0o777) == 0o700
                && lstat(manifestURL.path, &manifestInfo) == 0
                && (manifestInfo.st_mode & 0o777) == 0o400,
            "published artifact permissions are not private"
        )
        var unknownExtensionIndex = Data("DIRC".utf8)
        for value in [UInt32(2), UInt32(0)] {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) {
                unknownExtensionIndex.append(
                    contentsOf: $0
                )
            }
        }
        unknownExtensionIndex.append(
            Data("ZZZZ".utf8)
        )
        var zeroSize = UInt32(0).bigEndian
        withUnsafeBytes(of: &zeroSize) {
            unknownExtensionIndex.append(
                contentsOf: $0
            )
        }
        unknownExtensionIndex.append(
            contentsOf: Insecure.SHA1.hash(
                data: unknownExtensionIndex
            )
        )
        let unknownExtensionRejected: Bool
        do {
            _ = try RetentionArtifactTesting
                .validateIndex(
                    unknownExtensionIndex,
                    objectIDBytes: 20
                )
            unknownExtensionRejected = false
        } catch {
            unknownExtensionRejected = true
        }
        try expect(
            unknownExtensionRejected,
            "unknown index extension did not fail completeness"
        )
        let completedCount = try store.list().count
        let cancelled = CancellationToken()
        cancelled.cancel()
        try expect(
            store.prepare(
                selection: accepted,
                cancellation: cancelled
            ) == .cancelled
                && (try store.list().count) == completedCount,
            "cancellation did not preserve completed artifacts"
        )
        let cwd = Darwin.open(
            fixture.repositoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        try expect(cwd >= 0, "could not open cancellation fixture cwd")
        defer { Darwin.close(cwd) }
        let descriptorsBefore = try FileManager.default
            .contentsOfDirectory(atPath: "/dev/fd").count
        let preCancelled = CancellationToken()
        preCancelled.cancel()
        do {
            _ = try ClosedProcessRunner().run(
                command: ClosedProcessCommand(
                    executable: "/usr/bin/true",
                    arguments: []
                ),
                environment:
                    ClosedProcessRunner.environment(
                        account: fixture.account
                    ),
                workingDirectoryDescriptor: cwd,
                account: fixture.account,
                timeout: 5,
                cancellation: preCancelled
            )
            throw Body3SelfTestError(
                "pre-cancelled child was admitted"
            )
        } catch GitSafetyError.cancelled {
            // Expected before child admission.
        }
        let descriptorsAfter = try FileManager.default
            .contentsOfDirectory(atPath: "/dev/fd").count
        try expect(
            descriptorsAfter == descriptorsBefore,
            "pre-cancelled child admission leaked descriptors"
        )

        let hardlink = path + "/hardlink.txt"
        try expect(
            link(path + "/tracked.txt", hardlink) == 0,
            "could not create hardlink fixture"
        )
        let changedInventory = try fixture.cleanupInventory(
            executable: executable
        )
        let changed = try fixture.worktreeCandidate(
            inventory: changedInventory,
            path: path,
            preview: preview
        )
        let changedSelection = try RemovalSelection(
            candidate: changed,
            intent: .removeWithRecovery,
            includePossibleSecrets: true
        )
        guard case .incomplete = store.prepare(
            selection: changedSelection,
            cancellation: CancellationToken()
        ) else {
            throw Body3SelfTestError(
                "hardlinked payload did not fail completeness"
            )
        }
        try expect(
            try store.list().count == completedCount,
            "failed artifact removed or replaced a completed artifact"
        )
        try FileManager.default.removeItem(
            atPath: hardlink
        )

        let special = path + "/special.pipe"
        try expect(
            mkfifo(special, 0o600) == 0,
            "could not create special-file fixture"
        )
        guard case .incomplete = store.prepare(
            selection: accepted,
            cancellation: CancellationToken()
        ) else {
            throw Body3SelfTestError(
                "special file did not fail recovery completeness"
            )
        }
        try FileManager.default.removeItem(
            atPath: special
        )

        let escaping = path + "/escaping-link"
        try FileManager.default.createSymbolicLink(
            atPath: escaping,
            withDestinationPath: "/private/tmp"
        )
        guard case .incomplete = store.prepare(
            selection: accepted,
            cancellation: CancellationToken()
        ) else {
            throw Body3SelfTestError(
                "escaping symlink did not fail recovery completeness"
            )
        }
        try FileManager.default.removeItem(
            atPath: escaping
        )

        let unreadable = path + "/unreadable.bin"
        try Data("private\n".utf8).write(
            to: URL(fileURLWithPath: unreadable)
        )
        try expect(
            chmod(unreadable, 0o000) == 0,
            "could not protect unreadable fixture"
        )
        let unreadablePreparation = store.prepare(
            selection: accepted,
            cancellation: CancellationToken()
        )
        _ = chmod(unreadable, 0o600)
        try FileManager.default.removeItem(
            atPath: unreadable
        )
        guard case .incomplete =
                unreadablePreparation else {
            throw Body3SelfTestError(
                "unreadable file did not fail recovery completeness"
            )
        }

        let race = path + "/concurrent.bin"
        try Data(
            repeating: 0x61,
            count: 32 * 1_024 * 1_024
        ).write(to: URL(fileURLWithPath: race))
        let stop = LockedStopFlag()
        let mutation = DispatchGroup()
        mutation.enter()
        DispatchQueue.global().async {
            while !stop.shouldStop {
                _ = utimes(race, nil)
            }
            mutation.leave()
        }
        let concurrentPreparation = store.prepare(
            selection: accepted,
            cancellation: CancellationToken()
        )
        stop.stop()
        mutation.wait()
        try FileManager.default.removeItem(
            atPath: race
        )
        guard case .incomplete =
                concurrentPreparation else {
            throw Body3SelfTestError(
                "concurrent file change did not fail recovery completeness"
            )
        }
        try expect(
            try store.list().count == completedCount,
            "failed completeness cases changed completed artifacts"
        )
        let retentionEntries = try FileManager.default
            .contentsOfDirectory(
                atPath:
                    fixture.stateLocation.path
                        + "/retention"
            )
        try expect(
            retentionEntries.allSatisfy {
                !$0.hasPrefix(".incomplete-")
            },
            "failed recovery left an owned incomplete slot"
        )
        try InstallationLifecycle
            .testingPreserveAuthorityDuringRemoval(
                at: fixture.stateLocation
            )
        try expect(
            try store.verify(summary),
            "lifecycle cleanup did not preserve the completed recovery artifact"
        )

        try expect(
            chmod(manifestURL.path, 0o600) == 0,
            "could not prepare corruption fixture"
        )
        var corrupt = try Data(
            contentsOf: manifestURL
        )
        corrupt[corrupt.startIndex] ^= 0xff
        try corrupt.write(to: manifestURL)
        try expect(
            chmod(manifestURL.path, 0o400) == 0,
            "could not restore protected manifest mode"
        )
        let corruptionRejected: Bool
        do {
            corruptionRejected =
                try !store.verify(summary)
        } catch {
            corruptionRejected = true
        }
        try expect(
            corruptionRejected,
            "corrupted completed artifact remained trusted"
        )
    }

    private static func awaAdvisoryOverride(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t10"
        )
        defer { fixture.remove() }
        let path = try fixture.addWorktree(
            "awa-refusal",
            managedByAWA: true
        )
        let script = try fixture.installAWA(exitStatus: 23)
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let base = try fixture.worktree(
            inventory: inventory,
            path: path
        )
        let log = fixture.temporary.path + "/awa.log"
        let cwd = Darwin.open(
            fixture.repositoryPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        try expect(cwd >= 0, "could not open AWA fixture cwd")
        defer { close(cwd) }
        let adapter = AWAWorktreeCleanupAdapter(
            executablePath: script,
            account: fixture.account
        )
        let result = adapter.clean(
            worktree: base,
            workingDirectoryDescriptor: cwd,
            cancellation: CancellationToken()
        )
        try expect(
            result.disposition == .refused
                && result.command?.arguments
                    == ["clean", "--path", path],
            "AWA preferred refusal did not retain exact advisory argv"
        )
        let recorded = try String(
            contentsOfFile: log,
            encoding: .utf8
        )
        try expect(
            recorded.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) == "clean|--path|\(path)",
            "AWA adapter invoked an unapproved verb or option"
        )
        try FileManager.default.removeItem(atPath: script)
        let missing = adapter.clean(
            worktree: base,
            workingDirectoryDescriptor: cwd,
            cancellation: CancellationToken()
        )
        try expect(
            missing.disposition == .unavailable,
            "missing AWA adapter was not advisory unavailable"
        )
        _ = try fixture.installAWA(exitStatus: 3)
        let unavailable = adapter.clean(
            worktree: base,
            workingDirectoryDescriptor: cwd,
            cancellation: CancellationToken()
        )
        try expect(
            unavailable.disposition == .unavailable
                && unavailable.command?.arguments
                    == ["clean", "--path", path],
            "installed AWA engine-unavailable result was not advisory unavailable"
        )

        let successPath = try fixture.addWorktree(
            "awa-success",
            managedByAWA: true
        )
        _ = try fixture.installAWA(
            exitStatus: 0,
            removeOnSuccess: true
        )
        let successInventory =
            try fixture.cleanupInventory(
                executable: executable
            )
        let successCandidate = try require(
            RepositoryInventoryRemovalCandidates.make(
                from: successInventory,
                protectedPaths: [
                    fixture.stateLocation.path,
                    executable,
                ]
            ).first {
                $0.worktree?.path == successPath
            },
            "successful AWA removal candidate was unavailable"
        )
        let successSelection = try RemovalSelection(
            candidate: successCandidate,
            intent: successCandidate.defaultIntent,
            includePossibleSecrets: false
        )
        let successPrepared =
            try PreparedRemovalOracle.prepare(
                selection: successSelection,
                retention: nil
            )
        let successConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: successPrepared,
                        retained: true
                    ),
                ]
            )
        let successResult = try fixture.remove(
            successPrepared,
            confirmation: successConfirmation,
            executable: executable
        )
        try expect(
            successResult.status == .succeeded
                && successResult.awaDisposition
                    == .succeeded
                && successResult.commands.count == 1
                && successResult.commands[0].executable
                    == fixture.home
                        + "/dev/_ops/bin/dev-worktree.sh"
                && !FileManager.default.fileExists(
                    atPath: successPath
                )
                && successResult.residue
                    .worktreeRegistrationPresent == false,
            "successful preferred AWA removal was not independently postflighted"
        )
    }

    private static func batchCancelPolicy(
        executable: String
    ) throws {
        let nodes = try [
            node("a", repository: "owner/a", common: "one"),
            node("b", repository: "owner/b", common: "two"),
            node("c", repository: "owner/c", common: "one"),
            node(
                "d",
                repository: "owner/d",
                common: "three",
                dependencies: [
                    Body3BatchDependency(
                        nodeID: "body3-node:a"
                    ),
                ]
            ),
        ]
        let plan = try Body3BatchPlan(
            run: RunIdentity.make(),
            policyEvidenceDigest: "policy",
            nodes: nodes
        )
        let probe = BatchConcurrencyProbe()
        let report = try Body3BatchCoordinator().execute(
            plan: plan,
            control: Body3BatchControl()
        ) { node, _, _ in
            probe.enter(node.commonDirectoryKey)
            usleep(50_000)
            probe.leave(node.commonDirectoryKey)
            return Body3BatchNodeOutcome(
                status: .succeeded,
                detail: "ok"
            )
        }
        try expect(
            report.results.count == nodes.count
                && report.results.allSatisfy {
                    $0.status == .succeeded
                }
                && probe.maximumActive == 2
                && !probe.overlappedCommonDirectory,
            "batch violated exact two-worker/common-dir serialization"
        )

        let circuitNodes = try (1...4).map {
            try node(
                "infra-\($0)",
                repository: "owner/infra",
                common: "infra",
                dependencies: $0 == 1 ? [] : [
                    Body3BatchDependency(
                        nodeID:
                            "body3-node:infra-\($0 - 1)",
                        requiresSuccess: false
                    ),
                ]
            )
        }
        let circuitPlan = try Body3BatchPlan(
            run: RunIdentity.make(),
            policyEvidenceDigest: "policy",
            nodes: circuitNodes
        )
        let circuitControl = Body3BatchControl()
        let circuitReport = try Body3BatchCoordinator()
            .execute(
                plan: circuitPlan,
                control: circuitControl
            ) { _, _, _ in
                Body3BatchNodeOutcome(
                    status: .failed,
                    detail: "network",
                    infrastructureFailure:
                        Body3InfrastructureFailure(
                            category: "dns",
                            stableFields: ["same"]
                        )
                )
            }
        try expect(
            circuitReport.paused
                && circuitReport.results.count == 4
                && circuitReport.results.last?.status
                    == .skipped,
            "three equal infrastructure signatures did not pause and drain"
        )

        let cancellationFixture = try Body3Fixture(
            repositoryName: "body3-t11-cancel"
        )
        defer { cancellationFixture.remove() }
        let cancellationPath =
            try cancellationFixture.addWorktree(
                "cancel-residue",
                managedByAWA: false
            )
        try cancellationFixture.makeRecoveryState(
            at: cancellationPath
        )
        let cancellationInventory =
            try cancellationFixture.cleanupInventory(
                executable: executable
            )
        let residueCandidate = try require(
            RepositoryInventoryRemovalCandidates.make(
                from: cancellationInventory,
                protectedPaths: [
                    cancellationFixture
                        .stateLocation.path,
                    executable,
                ]
            ).first {
                $0.worktree?.path == cancellationPath
            },
            "cancellation residue candidate was unavailable"
        )
        try expect(
            residueCandidate.canSelect,
            "cancellation fixture was not selectable: exclusion=\(residueCandidate.hardExclusion ?? "none") permission=\(residueCandidate.preview.permission.rawValue) recommendation=\(residueCandidate.preview.recommendation.rawValue)"
        )
        let recoverySelection = try RemovalSelection(
            candidate: residueCandidate,
            intent: residueCandidate.defaultIntent,
            includePossibleSecrets: true
        )
        let fastForwardOperation = try require(
            cancellationInventory.selectableOperations
                .first {
                    $0.kind == .fastForward
                },
            "full DAG fixture omitted Fast-forward"
        )
        let prunable =
            try cancellationFixture
                .makePrunableRegistration(
                    "repair-before-removal"
                )
        let repairTarget =
            try DefaultBranchUpdateTarget(
                repository:
                    fastForwardOperation.target
                        .repository,
                canonicalClone:
                    fastForwardOperation.target
                        .canonicalClone,
                resolvedDefault:
                    fastForwardOperation.target
                        .resolvedDefault,
                expectedLocalOID:
                    fastForwardOperation.target
                        .expectedLocalOID,
                expectedFetchedOID:
                    fastForwardOperation.target
                        .expectedFetchedOID,
                mode: .metadataMaintenance,
                worktreeID: nil,
                relation: .unavailable
            )
        let repairOperation = try PlannedOperation(
            kind: .repairPruneRegistrations,
            target: repairTarget,
            maintenanceEvidence: .prune([
                prunable,
            ])
        )
        let recoveryPlan = try Body3BatchPlanner.make(
            run: RunIdentity.make(),
            operations: [
                repairOperation,
                fastForwardOperation,
            ],
            removals: [recoverySelection]
        )
        let retentionID = try require(
            recoveryPlan.nodes.first {
                $0.kind == .retention
            }?.id,
            "recovery planning omitted retention"
        )
        let plannedRemoval = try require(
            recoveryPlan.nodes.first {
                $0.kind == .worktreeRemoval
            },
            "recovery planning omitted worktree removal"
        )
        let repairNode = try require(
            recoveryPlan.nodes.first {
                $0.kind == .repair
            },
            "full DAG omitted Repair node"
        )
        let afterRepair = try require(
            recoveryPlan.nodes.first {
                if case let .reinspection(
                    _, _, reason
                ) = $0.payload {
                    return reason == "after-repair"
                }
                return false
            },
            "full DAG omitted post-Repair inspection"
        )
        let fastForwardNode = try require(
            recoveryPlan.nodes.first {
                $0.kind == .fastForward
            },
            "full DAG omitted Fast-forward node"
        )
        let afterFastForward = try require(
            recoveryPlan.nodes.first {
                if case let .reinspection(
                    _, _, reason
                ) = $0.payload {
                    return reason == "after-fast-forward"
                }
                return false
            },
            "full DAG omitted post-Fast-forward inspection"
        )
        let confirmationNode = try require(
            recoveryPlan.nodes.first {
                $0.kind
                    == .groupedRemovalConfirmation
            },
            "full DAG omitted grouped confirmation"
        )
        let residueNode = try require(
            recoveryPlan.nodes.first {
                $0.kind == .residueVerification
            },
            "full DAG omitted residue verification"
        )
        let removalSafetyPrerequisites =
            RunCoordinator
                .testingRemovalSafetyPrerequisites(
                    recoveryPlan
                )
        try expect(
            afterRepair.dependencies.contains {
                $0.nodeID == repairNode.id
            }
                && fastForwardNode.dependencies.contains {
                    $0.nodeID == afterRepair.id
                }
                && afterFastForward.dependencies.contains {
                    $0.nodeID == fastForwardNode.id
                }
                && recoveryPlan.nodes.first {
                    $0.id == retentionID
                }?.dependencies.contains {
                    $0.nodeID == afterFastForward.id
                } == true
                && confirmationNode.dependencies.contains {
                    $0.nodeID == retentionID
                        && !$0.requiresSuccess
                }
                && plannedRemoval.dependencies.contains {
                    $0.nodeID == retentionID
                        && !$0.requiresSuccess
                }
                && plannedRemoval.dependencies.contains {
                    $0.nodeID == confirmationNode.id
                }
                && residueNode.dependencies.contains {
                    $0.nodeID == plannedRemoval.id
                        && !$0.requiresSuccess
                }
                && removalSafetyPrerequisites[
                    residueCandidate.id
                ]?.contains(afterFastForward.id)
                    == true
                && removalSafetyPrerequisites[
                    residueCandidate.id
                ]?.contains(retentionID)
                    == false,
            "Repair→inspection→Fast-forward→inspection→recovery→confirmation→removal→residue DAG changed"
        )
        try cancellationFixture.git([
            "worktree", "prune",
        ])
        let operationsOnlyPlan =
            try Body3BatchPlanner.make(
                run: RunIdentity.make(),
                operations: [
                    fastForwardOperation,
                ],
                removals: []
            )
        try expect(
            !operationsOnlyPlan.nodes.contains {
                $0.kind
                    == .groupedRemovalConfirmation
            },
            "operations-only DAG invented a removal confirmation"
        )
        let operationsOnlyConfirmation =
            LockedFlag()
        let operationsOnlyReport =
            try RunCoordinator(
                configuration:
                    CoordinatorConfiguration(
                        stateLocation:
                            cancellationFixture
                                .stateLocation,
                        trampolineExecutable:
                            executable,
                        transportMapping:
                            cancellationFixture.mapping
                    ),
                account:
                    cancellationFixture.account
            ).runBody3(
                plan: operationsOnlyPlan,
                selectedScope: try .testing(
                    plan: operationsOnlyPlan
                ),
                cancellation: CancellationToken(),
                inventoryProvider: { _ in
                    cancellationInventory
                }
            ) {
                if $0.confirmation != nil {
                    operationsOnlyConfirmation.set()
                }
            }
        try expect(
            !operationsOnlyConfirmation.value
                && !operationsOnlyReport.cancelled
                && !operationsOnlyReport.paused
                && operationsOnlyReport.results
                    .allSatisfy {
                        $0.status == .succeeded
                    },
            "operations-only Body 3 execution failed or requested removal confirmation: cancelled=\(operationsOnlyReport.cancelled) paused=\(operationsOnlyReport.paused) results=\(operationsOnlyReport.results.map { "\($0.node.kind.rawValue):\($0.status.rawValue):\($0.detail)" }.joined(separator: "|"))"
        )

        let devFixture = try Body3Fixture(
            repositoryName: "governed-root",
            owner: "fixture-owner",
            devUmbrella: true
        )
        defer { devFixture.remove() }
        let devRemovalPath = try devFixture.addWorktree(
            "dev-removal",
            managedByAWA: false
        )
        let devInventory =
            try devFixture.cleanupInventory(
                executable: executable
            )
        let devFastForward = try require(
            devInventory.selectableOperations.first {
                $0.kind == .fastForward
                    && $0.target.repository.id
                        == "fixture-owner/governed-root"
            },
            "~/dev terminal fixture omitted Fast-forward"
        )
        let devRemoval = try require(
            RepositoryInventoryRemovalCandidates.make(
                from: devInventory,
                protectedPaths: [
                    devFixture.stateLocation.path,
                    executable,
                ]
            ).first {
                $0.worktree?.path == devRemovalPath
            },
            "~/dev terminal fixture omitted removal row"
        )
        try expect(
            devRemoval.canSelect,
            "~/dev fixture was not selectable before planner policy: exclusion=\(devRemoval.hardExclusion ?? "none") permission=\(devRemoval.preview.permission.rawValue)"
        )
        let devRemovalSelection = try RemovalSelection(
            candidate: devRemoval,
            intent: devRemoval.defaultIntent,
            includePossibleSecrets: false
        )
        try expect(
            (try? Body3BatchPlanner.make(
                run: RunIdentity.make(),
                operations: [devFastForward],
                removals: [devRemovalSelection]
            )) == nil,
            "~/dev Fast-forward admitted Repair/Remove in the same batch"
        )
        let terminalDevPlan = try Body3BatchPlanner.make(
            run: RunIdentity.make(),
            operations: [
                repairOperation,
                fastForwardOperation,
                devFastForward,
            ],
            removals: [recoverySelection]
        )
        let devUpdateIndex = try require(
            terminalDevPlan.nodes.firstIndex {
                $0.kind == .fastForward
                    && $0.repositoryID
                        == "fixture-owner/governed-root"
            },
            "~/dev terminal Fast-forward node was omitted"
        )
        try expect(
            terminalDevPlan.nodes[devUpdateIndex]
                .requiresExclusiveWorkerPool
                && devUpdateIndex
                    == terminalDevPlan.nodes.count - 2
                && terminalDevPlan.nodes.last?.kind
                    == .policyInvalidation,
            "~/dev Fast-forward was not scheduled last, alone, then invalidated"
        )
        let rootRole = GovernedRootRole.testing()
        try expect(Body3BatchPlanner.matchesPolicyBoundary(terminalDevPlan, governedRoot: rootRole),
                   "planner did not reproduce its bound policy DAG")
        func alteredRootPlan(_ nodes: [Body3BatchNode]) throws -> Body3BatchPlan {
            try Body3BatchPlan(run: terminalDevPlan.run,
                              policyEvidenceDigest: terminalDevPlan.policyEvidenceDigest,
                              nodes: nodes)
        }
        let terminalUpdate = terminalDevPlan.nodes[devUpdateIndex]
        var nonexclusive = terminalDevPlan.nodes
        nonexclusive[devUpdateIndex] = try Body3BatchNode(id: terminalUpdate.id,
            repositoryID: terminalUpdate.repositoryID, commonDirectoryKey: terminalUpdate.commonDirectoryKey,
            kind: terminalUpdate.kind, dependencies: terminalUpdate.dependencies,
            payload: terminalUpdate.payload, requiresExclusiveWorkerPool: false)
        var early = terminalDevPlan.nodes
        early[devUpdateIndex] = try Body3BatchNode(id: terminalUpdate.id,
            repositoryID: terminalUpdate.repositoryID, commonDirectoryKey: terminalUpdate.commonDirectoryKey,
            kind: terminalUpdate.kind, dependencies: [], payload: terminalUpdate.payload,
            requiresExclusiveWorkerPool: true)
        for altered in [try alteredRootPlan(nonexclusive), try alteredRootPlan(early),
                        try alteredRootPlan(Array(terminalDevPlan.nodes.dropLast()))] {
            try expect(!Body3BatchPlanner.matchesPolicyBoundary(altered, governedRoot: rootRole),
                       "serialized plan bypassed root-update isolation or invalidation")
        }
        try expect(!Body3BatchPlanner.matchesPolicyBoundary(terminalDevPlan,
                       governedRoot: .testing(repositoryID: "fixture-owner/other-root"))
            && !Body3BatchPlanner.matchesPolicyBoundary(terminalDevPlan,
                       governedRoot: .testing(policyDigest: String(repeating: "a", count: 64))),
                   "plan survived a changed root identity or policy digest")
        let cancellationNodes = try [
            node(
                "cancel-running",
                repository:
                    residueCandidate.repository.id,
                common: residueCandidate.clone.id
            ),
            node(
                "cancel-queued",
                repository:
                    residueCandidate.repository.id,
                common: residueCandidate.clone.id,
                dependencies: [
                    Body3BatchDependency(
                        nodeID:
                            "body3-node:cancel-running"
                    ),
                ]
            ),
            Body3BatchNode(
                id: "body3-node:cancel-postflight",
                repositoryID:
                    residueCandidate.repository.id,
                commonDirectoryKey:
                    residueCandidate.clone.id,
                kind: .residueVerification,
                dependencies: [
                    Body3BatchDependency(
                        nodeID:
                            "body3-node:cancel-running",
                        requiresSuccess: false
                    ),
                ],
                payload: .residue(residueCandidate)
            ),
        ]
        let cancellationPlan = try Body3BatchPlan(
            run: RunIdentity.make(),
            policyEvidenceDigest: "policy",
            nodes: cancellationNodes
        )
        let cancellationControl = Body3BatchControl()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + 0.03
        ) {
            cancellationControl.cancel()
        }
        let cancelled = try Body3BatchCoordinator()
            .execute(
                plan: cancellationPlan,
                control: cancellationControl
            ) { node, _, token in
                if node.kind == .residueVerification {
                    return Body3BatchNodeOutcome(
                        status: .succeeded,
                        detail: "postflight"
                    )
                }
                while !token.isCancelled {
                    usleep(2_000)
                }
                return Body3BatchNodeOutcome(
                    status: .cancelled,
                    detail: "reaped"
                )
            }
        try expect(
            cancelled.cancelled
                && cancelled.results.allSatisfy {
                    $0.status.isTerminal
                }
                && cancelled.results.filter {
                    $0.status == .cancelled
                }.count == 1
                && cancelled.results.filter {
                    $0.status == .skipped
                }.count == 1
                && cancelled.results.filter {
                    $0.node.kind == .residueVerification
                        && $0.status == .succeeded
                }.count == 1,
            "batch cancellation did not close admission and terminalize all nodes"
        )
    }

    private static func cardEventsRecovery(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t12"
        )
        defer { fixture.remove() }
        try isolatedMixedCancellationJourney(
            fixture: fixture,
            executable: executable
        )
        let plan = try Body3BatchPlan(
            run: RunIdentity.make(),
            policyEvidenceDigest: "policy",
            nodes: [
                try node(
                    "event",
                    repository: "owner/body3-t12",
                    common: "event"
                ),
            ]
        )
        let authority = try RunAuthority.acquireRun(
            at: fixture.stateLocation
        )
        defer { authority.release() }
        let writer = try Body3RunLogWriter(
            authority: authority,
            plan: plan
        )
        _ = try writer.append(
            type: "node_started",
            repository: "owner/body3-t12",
            operation: "body3-node:event",
            kind: Body3BatchNodeKind
                .worktreeRemoval.rawValue,
            phase: "Remove Worktree",
            worker: 1,
            recommendation:
                RemovalRecommendation.keep.rawValue,
            selection:
                RemovalSelectionIntent
                    .operatorOverride.rawValue,
            awa: AWAEvidenceState.stale.rawValue,
            retention:
                RemovalFinalClass
                    .operatorOverrideRisk.rawValue,
            artifact: "ret-fixture",
            restore: "Restore locally.",
            command: Body3CommandLogEvidence(
                RemovalCommandEvidence(
                    executable: "/usr/bin/git",
                    arguments: [
                        "--git-dir=/private/tmp/repo/.git",
                        "worktree", "remove", "--force",
                        "/private/tmp/worktree",
                    ],
                    forceLevel: .singleForce,
                    outcome: "refused"
                )
            ),
            status: .running,
            residue: "path=true registration=true",
            recovery:
                "Postflight interrupted nodes without retry.",
            detail:
                "https://operator:secret@example.com token=ghp_abcdefghijklmnopqrstuvwxyz"
        )
        try writer.flush()
        let records = try Body3RunLogReader.records(
            state: authority.stateDirectory
        )
        try expect(
            records.count == 2
                && records[0].plan == plan
                && records[1].executable == "/usr/bin/git"
                && records[1].arguments?.contains(
                    "worktree"
                ) == true
                && !(records[1].detail ?? "")
                    .contains("operator:secret")
                && !(records[1].detail ?? "")
                    .contains("ghp_"),
            "v2 event framing/fields/redaction changed"
        )
        let rendered = Body3RunLogReader.render(records)
        try expect(
            rendered.contains("Remove Worktree")
                && rendered.contains("worktree remove"),
            "validated live-log rendering omitted exact bounded evidence"
        )
        let recovered =
            Body3InterruptedRunReconstructor.reconstruct(
                records: records
            ) { _ in
                Body3RecoveredNodeDisposition(
                    status: .failed,
                    detail:
                        "Fresh postflight found residue."
                )
            }
        let recoveredAgain =
            Body3InterruptedRunReconstructor.reconstruct(
                records: records
            ) { _ in
                Body3RecoveredNodeDisposition(
                    status: .failed,
                    detail:
                        "Fresh postflight found residue."
                )
            }
        guard let recovered else {
            throw Body3SelfTestError(
                "interrupted recovery returned no report"
            )
        }
        let recoveredMetadata =
            try Body3BatchMetadata.derive(
                plan: plan,
                report: recovered
            )
        try expect(
            recovered.cancelled
                && recovered.results.count == 1
                && recovered.results[0].status
                    == .failed
                && recovered.results[0].detail
                    .contains("without retry") == true,
            "interrupted recovery retried or lost exact plan truth"
        )
        try expect(
            recovered == recoveredAgain
                && recovered.endedAt
                    == records.last?.timestamp
                && recovered.results[0].startedAt
                    == records[1].timestamp
                && recoveredMetadata.attemptedActionCount
                    == 1,
            "interrupted historical timing was not durable and deterministic"
        )
        let logPath = fixture.stateLocation.path
            + "/latest.log"
        let descriptor = Darwin.open(
            logPath,
            O_WRONLY | O_APPEND | O_CLOEXEC
        )
        try expect(descriptor >= 0, "could not append partial log tail")
        let partial = Data("{\"partial\":".utf8)
        _ = partial.withUnsafeBytes {
            Darwin.write(
                descriptor,
                $0.baseAddress!,
                $0.count
            )
        }
        close(descriptor)
        try expect(
            try Body3RunLogReader.records(
                state: authority.stateDirectory
            ) == records,
            "partial tail invalidated the contiguous event prefix"
        )
        try InstallationLifecycle
            .testingPreserveAuthorityDuringRemoval(
                at: fixture.stateLocation
            )
        try expect(
            try Body3RunLogReader.records(
                state: authority.stateDirectory
            ) == records,
            "lifecycle cleanup did not preserve latest.log"
        )
    }

    private static func isolatedMixedCancellationJourney(
        fixture: Body3Fixture,
        executable: String
    ) throws {
        let worktreePath = try fixture.addWorktree(
            "mixed-cancel",
            managedByAWA: true,
            uniqueCommit: true
        )
        let cleanWorktreePath = try fixture.addWorktree(
            "mixed-clean",
            managedByAWA: true
        )
        try fixture.makeRecoveryState(at: worktreePath)
        _ = try fixture.installAWA(exitStatus: 1)
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let candidates =
            RepositoryInventoryRemovalCandidates.make(
                from: inventory,
                protectedPaths: [
                    fixture.stateLocation.path,
                    executable,
                ]
            )
        let candidate = try require(
            candidates.first {
                $0.worktree?.path == worktreePath
            },
            "mixed journey removal candidate was unavailable"
        )
        let cleanCandidate = try require(
            candidates.first {
                $0.worktree?.path == cleanWorktreePath
            },
            "mixed journey clean removal candidate was unavailable"
        )
        let branchCandidate = try require(
            candidates.first {
                $0.kind == .branch
                    && !$0.dependencies.isEmpty
            },
            "mixed journey branch presentation was unavailable"
        )
        let worktreeSnapshot =
            RemovalCardPresentationSnapshot(
                candidate: cleanCandidate
            )
        let branchSnapshot =
            RemovalCardPresentationSnapshot(
                candidate: branchCandidate
            )
        try expect(
            worktreeSnapshot.identityLabel == "WORKTREE"
                && worktreeSnapshot.identityGlyph == "▱"
                && worktreeSnapshot.identitySystemSymbol
                    == "folder"
                && worktreeSnapshot
                    .secondaryIdentitySystemSymbol
                    == "arrow.triangle.branch"
                && worktreeSnapshot.accent == .teal
                && worktreeSnapshot.recommendationLabel
                    == cleanCandidate.preview
                        .recommendation.operatorLabel
                && branchSnapshot.identityLabel == "BRANCH"
                && branchSnapshot.identityGlyph == "⑂"
                && branchSnapshot.identitySystemSymbol
                    == "arrow.triangle.branch"
                && branchSnapshot
                    .secondaryIdentitySystemSymbol == nil
                && branchSnapshot.accent == .purple
                && branchSnapshot.dependencies
                    == branchCandidate.dependencies
                && branchSnapshot.actionLabel
                    == "Remove claiming Worktrees first"
                && !branchSnapshot.selectable
                && !branchSnapshot.selectAllEligible
                && !branchSnapshot.pullRequestLabels.isEmpty
                && [
                    PullRequestState.draft,
                    .open,
                    .merged,
                    .closed,
                ].map(RemovalPullRequestAccent.init)
                    == [
                        .draft, .open, .merged, .closed,
                    ],
            "Worktree/Branch visual, PR, badge, or dependency snapshot changed"
        )
        let selection = try RemovalSelection(
            candidate: candidate,
            intent: candidate.defaultIntent,
            includePossibleSecrets: true
        )
        let cleanSelection = try RemovalSelection(
            candidate: cleanCandidate,
            intent: cleanCandidate.defaultIntent,
            includePossibleSecrets: false
        )
        let plan = try Body3BatchPlanner.make(
            run: RunIdentity.make(),
            operations: [],
            removals: [selection, cleanSelection]
        )
        let sawConfirmation = LockedFlag()
        let coordinator = RunCoordinator(
            configuration: CoordinatorConfiguration(
                stateLocation: fixture.stateLocation,
                trampolineExecutable: executable,
                transportMapping: fixture.mapping
            ),
            account: fixture.account
        )
        let report = try coordinator.runBody3(
            plan: plan,
            selectedScope: try .testing(plan: plan),
            cancellation: CancellationToken(),
            inventoryProvider: { _ in inventory }
        ) { event in
            if let request = event.confirmation {
                sawConfirmation.set()
                request.cancel()
            }
        }
        let artifacts = try fixture.retentionStore().list()
        let awaLog = fixture.temporary.path + "/awa.log"
        let recovered = Body3RunRecoveryInspector.inspect(
            at: fixture.stateLocation,
            account: fixture.account
        )
        let retentionNames = try FileManager.default
            .contentsOfDirectory(
                atPath:
                    fixture.stateLocation.path
                        + "/retention"
            )
        let recoveredRun: Body3RecoveredRun?
        if case let .previous(value) = recovered {
            recoveredRun = value
        } else {
            recoveredRun = nil
        }
        try expect(
            sawConfirmation.value
                && report.cancelled
                && report.results.allSatisfy {
                    $0.status.isTerminal
                }
                && FileManager.default.fileExists(
                    atPath: worktreePath
                )
                && FileManager.default.fileExists(
                    atPath: cleanWorktreePath
                )
                && artifacts.count == 1
                && artifacts[0].restoreProven
                && retentionNames.allSatisfy {
                    !$0.hasPrefix(".incomplete-")
                }
                && !FileManager.default.fileExists(
                    atPath: awaLog
                )
                && !FileManager.default.fileExists(
                    atPath:
                        fixture.stateLocation.path
                            + "/host.sock"
                )
                && recoveredRun?.plan == plan
                && recoveredRun?.report == report
                && recoveredRun?.requiresReview
                    == true,
            "isolated mixed recovery/cancel journey mutated source or left owned residue"
        )
    }

    private static func nativeRemovalOverride(
        executable: String
    ) throws {
        try dirtySingleForceRemoval(executable: executable)
        try lockedDoubleForceRemoval(executable: executable)
        try branchCASAndClaimGate(executable: executable)
    }

    private static func dirtySingleForceRemoval(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t15-dirty"
        )
        defer { fixture.remove() }
        let path = try fixture.addWorktree(
            "dirty",
            managedByAWA: true,
            uniqueCommit: true
        )
        try fixture.makeRecoveryState(at: path)
        _ = try fixture.installAWA(exitStatus: 19)
        let hookLog = try fixture
            .installReferenceTransactionTrace(
                "dirty-worktree-remove"
            )
        try Data("marker only\n".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.repositoryPath
                    + "/.fixture-hook"
            )
        )
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let preview = RemovalPreviewOracle.worktree(
            isResolvedDefaultClaim: false,
            policyCategory: .writable,
            verification: .verified,
            fileState: WorktreeFileState(
                trackedChanges: 2,
                untrackedFiles: 1,
                ignoredFiles: 1,
                hiddenIndexState: false,
                operationState: .clear
            ),
            awa: AWAEvidence(
                state: .stale,
                explanation: "stale",
                blocksRemoval: true
            ),
            purpose: .completed,
            activity: .idle,
            branchTipPreserved: false
        )
        let candidate = try fixture.worktreeCandidate(
            inventory: inventory,
            path: path,
            preview: preview
        )
        let selection = try RemovalSelection(
            candidate: candidate,
            intent: .removeAnyway,
            includePossibleSecrets: true
        )
        let preparation = try fixture.retentionStore()
            .prepare(
                selection: selection,
                cancellation: CancellationToken()
            )
        let prepared = try PreparedRemovalOracle.prepare(
            selection: selection,
            retention: preparation
        )
        let confirmation = try GroupedRemovalConfirmation(
            run: RunIdentity.make(),
            rows: [
                ConfirmedRemovalRow(
                    prepared: prepared,
                    retained: true
                ),
            ]
        )
        let result = try fixture.remove(
            prepared,
            confirmation: confirmation,
            executable: executable
        )
        let git = result.commands.filter {
            $0.executable == DescriptorProcessRunner.gitPath
        }
        try expect(
            result.status == .succeeded
                && result.awaDisposition == .refused
                && git.count == 2
                && git[0].forceLevel == .ordinaryOnly
                && git[1].forceLevel == .singleForce
                && !FileManager.default
                    .fileExists(atPath: path)
                && result.residue
                    .worktreeRegistrationPresent == false
                && prepared.artifact?.restoreProven == true
                && (
                    try String(
                        contentsOfFile: hookLog,
                        encoding: .utf8
                    )
                ).isEmpty,
            "dirty removal did not follow AWA→ordinary→single-force with protected recovery: status=\(result.status.rawValue) awa=\(result.awaDisposition.rawValue) commands=\(result.commands.map { "\($0.executable):\($0.forceLevel.rawValue):\($0.outcome)" }.joined(separator: "|")) pathPresent=\(FileManager.default.fileExists(atPath: path)) registration=\(String(describing: result.residue.worktreeRegistrationPresent)) attention=\(result.residue.needsAttention) artifact=\(String(describing: prepared.artifact?.restoreProven)) explanation=\(result.explanation)"
        )
    }

    private static func lockedDoubleForceRemoval(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t15-locked"
        )
        defer { fixture.remove() }
        let path = try fixture.addWorktree(
            "locked",
            managedByAWA: false
        )
        try fixture.git([
            "worktree", "lock", "--reason",
            "Body 3 fixture", path,
        ])
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let preview = RemovalPreviewOracle.worktree(
            isResolvedDefaultClaim: false,
            policyCategory: .writable,
            verification: .verified,
            fileState: WorktreeFileState(
                trackedChanges: 0,
                untrackedFiles: 0,
                ignoredFiles: 0,
                hiddenIndexState: false,
                operationState: .clear
            ),
            awa: .notManaged,
            purpose: .completed,
            activity: .idle,
            branchTipPreserved: true,
            isLocked: true
        )
        let candidate = try fixture.worktreeCandidate(
            inventory: inventory,
            path: path,
            preview: preview
        )
        let selection = try RemovalSelection(
            candidate: candidate,
            intent: .removeAnyway,
            includePossibleSecrets: true
        )
        let preparation = try fixture.retentionStore()
            .prepare(
                selection: selection,
                cancellation: CancellationToken()
            )
        let prepared = try PreparedRemovalOracle.prepare(
            selection: selection,
            retention: preparation
        )
        try expect(
            prepared.finalClass == .operatorOverrideRisk
                && prepared.forceLevel
                    == .doubleForceLocked,
            "locked Worktree did not remain explicit override after recovery"
        )
        let confirmation = try GroupedRemovalConfirmation(
            run: RunIdentity.make(),
            rows: [
                ConfirmedRemovalRow(
                    prepared: prepared,
                    retained: true
                ),
            ]
        )
        let result = try fixture.remove(
            prepared,
            confirmation: confirmation,
            executable: executable
        )
        try expect(
            result.status == .succeeded
                && result.commands.contains {
                    $0.forceLevel == .doubleForceLocked
                        && $0.arguments.suffix(3)
                            == [
                                "--force", "--force",
                                path,
                            ]
                },
            "locked removal did not admit exact double force"
        )
    }

    private static func branchCASAndClaimGate(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t15-branch"
        )
        defer { fixture.remove() }
        try fixture.git([
            "branch", "feature-cas",
        ])
        try fixture.git([
            "branch", "feature-ordinary",
        ])
        try fixture.git([
            "branch", "--set-upstream-to=origin/main",
            "feature-ordinary",
        ])
        let claimedPath = try fixture.addWorktree(
            "claimed",
            managedByAWA: false
        )
        let hookLog = try fixture
            .installReferenceTransactionTrace(
                "branch-removal"
            )
        try Data("marker only\n".utf8).write(
            to: URL(
                fileURLWithPath:
                    fixture.repositoryPath
                    + "/.fixture-hook"
            )
        )
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let casPreview = RemovalPreview(
            recommendation: .override,
            permission: .previewOnly,
            explanation:
                "Explicit history-loss fixture.",
            overrideConsequence:
                "Unique local history may become unreachable."
        )
        let ordinary = try fixture.branchCandidate(
            inventory: inventory,
            name: "feature-ordinary",
            preview: RemovalPreview(
                recommendation: .recommended,
                permission: .previewOnly,
                explanation:
                    "Fulfilled history is preserved by the default branch."
            )
        )
        let ordinarySelection = try RemovalSelection(
            candidate: ordinary,
            intent: .remove,
            includePossibleSecrets: false
        )
        let ordinaryPrepared =
            try PreparedRemovalOracle.prepare(
                selection: ordinarySelection,
                retention: nil
            )
        let ordinaryConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: ordinaryPrepared,
                        retained: true
                    ),
                ]
            )
        let ordinaryResult = try fixture.remove(
            ordinaryPrepared,
            confirmation: ordinaryConfirmation,
            executable: executable
        )
        let ordinaryTrace = try String(
            contentsOfFile: hookLog,
            encoding: .utf8
        )
        try expect(
            ordinaryResult.status == .succeeded
                && ordinaryResult.commands.count == 1
                && ordinaryResult.commands[0].arguments
                    .suffix(3)
                    == [
                        "branch", "-d",
                        "feature-ordinary",
                    ]
                && ordinaryTrace.contains(
                    "prepared\ncommitted\n"
                )
                && (try fixture.gitText([
                    "config", "--get-regexp",
                    "^branch\\.feature-ordinary\\.",
                ], allowFailure: true)).isEmpty,
            "Recommended Branch did not use non-force branch -d with native hook trace: status=\(ordinaryResult.status.rawValue) commands=\(ordinaryResult.commands.map(\.arguments)) trace=\(ordinaryTrace.replacingOccurrences(of: "\n", with: "|")) explanation=\(ordinaryResult.explanation)"
        )
        try Data().write(
            to: URL(fileURLWithPath: hookLog)
        )
        let afterOrdinaryInventory =
            try fixture.cleanupInventory(
                executable: executable
            )
        let cas = try fixture.branchCandidate(
            inventory: afterOrdinaryInventory,
            name: "feature-cas",
            preview: casPreview
        )
        let casSelection = try RemovalSelection(
            candidate: cas,
            intent: .operatorOverride,
            includePossibleSecrets: false
        )
        let casPrepared = try PreparedRemovalOracle.prepare(
            selection: casSelection,
            retention: nil
        )
        let casConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: casPrepared,
                        retained: true
                    ),
                ]
            )
        let casResult = try fixture.remove(
            casPrepared,
            confirmation: casConfirmation,
            executable: executable
        )
        try expect(
            casResult.status == .succeeded
                && casResult.commands.count == 1
                && casResult.commands[0].arguments
                    .contains("update-ref")
                && casResult.commands[0].arguments
                    .contains(cas.expectedOID!)
                && (try fixture.gitText([
                    "show-ref", "--verify", "--quiet",
                    "refs/heads/feature-cas",
                ], allowFailure: true)).isEmpty
                && (
                    try String(
                        contentsOfFile: hookLog,
                        encoding: .utf8
                    )
                ).contains("prepared\ncommitted\n"),
            "Branch override did not use exact expected-old CAS"
        )

        try Data("first\n".utf8).write(
            to: URL(
                fileURLWithPath:
                    claimedPath + "/tracked.txt"
            )
        )
        let claimedInventory = try fixture.cleanupInventory(
            executable: executable
        )
        let contentCandidate =
            try fixture.worktreeCandidate(
                inventory: claimedInventory,
                path: claimedPath,
                preview: RemovalPreview(
                    recommendation: .override,
                    permission: .previewOnly,
                    explanation:
                        "Explicit content-risk fixture.",
                    overrideConsequence:
                        "Local content may be lost."
                )
            )
        let contentSelection = try RemovalSelection(
            candidate: contentCandidate,
            intent: .operatorOverride,
            includePossibleSecrets: false
        )
        let contentPrepared =
            try PreparedRemovalOracle.prepare(
                selection: contentSelection,
                retention: nil
            )
        let contentConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: contentPrepared,
                        retained: true
                    ),
                ]
            )
        try Data("other\n".utf8).write(
            to: URL(
                fileURLWithPath:
                    claimedPath + "/tracked.txt"
            )
        )
        let contentResult = try fixture.remove(
            contentPrepared,
            confirmation: contentConfirmation,
            executable: executable
        )
        try expect(
            contentResult.status == .failed
                && contentResult.commands.isEmpty
                && FileManager.default
                    .fileExists(atPath: claimedPath),
            "same-shape Worktree content drift escaped the final content/index gate"
        )
        let claimed = try fixture.branchCandidate(
            inventory: claimedInventory,
            name: "claimed",
            preview: casPreview
        )
        let claimedSelection = try RemovalSelection(
            candidate: claimed,
            intent: .operatorOverride,
            includePossibleSecrets: false
        )
        let claimedPrepared =
            try PreparedRemovalOracle.prepare(
                selection: claimedSelection,
                retention: nil
            )
        let claimedConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: claimedPrepared,
                        retained: true
                    ),
                ]
            )
        let claimedResult = try fixture.remove(
            claimedPrepared,
            confirmation: claimedConfirmation,
            executable: executable
        )
        try expect(
            claimedResult.status == .refused
                && claimedResult.commands.isEmpty
                && FileManager.default
                    .fileExists(atPath: claimedPath)
                && !(try fixture.gitText([
                    "show-ref", "--verify",
                    "refs/heads/claimed",
                ])).isEmpty,
            "Branch claims were overridden or mutated"
        )
    }

    private static func directHumanRuntime(
        executable: String
    ) throws {
        let fixture = try Body3Fixture(
            repositoryName: "body3-t16"
        )
        defer { fixture.remove() }
        let path = try fixture.addWorktree(
            "visible-override",
            managedByAWA: true
        )
        let inventory = try fixture.cleanupInventory(
            executable: executable
        )
        let candidates =
            RepositoryInventoryRemovalCandidates.make(
                from: inventory,
                protectedPaths: [
                    fixture.stateLocation.path,
                    executable,
                ]
            )
        let feature = try require(
            candidates.first {
                $0.worktree?.path == path
            },
            "verified non-default AWA Worktree was hidden"
        )
        let defaultBranch = try require(
            candidates.first {
                $0.branch?.name == "main"
            },
            "default Branch exclusion was hidden"
        )
        let primaryWorktree = try require(
            candidates.first {
                $0.worktree?.isPrimary == true
            },
            "canonical primary Worktree exclusion was hidden"
        )
        try expect(
            feature.canSelect
                && feature.preview.recommendation == .override
                && feature.defaultIntent == .operatorOverride,
            "AWA evidence vetoed the visible human override path"
        )
        try expect(
            defaultBranch.hardExclusion != nil
                && !defaultBranch.canSelect
                && primaryWorktree.hardExclusion != nil
                && !primaryWorktree.canSelect,
            "resolved default or canonical target received a cleanup grammar"
        )
        let unresolvedBoundary =
            RepositoryInventoryRemovalCandidates.make(
                from: inventory,
                protectedPaths: [executable],
                protectionBoundaryEstablished: false
            )
        let stateContained =
            RepositoryInventoryRemovalCandidates.make(
                from: inventory,
                protectedPaths: [
                    fixture.repositoryPath,
                    executable,
                ]
            )
        try expect(
            !unresolvedBoundary.isEmpty
                && unresolvedBoundary.allSatisfy {
                    !$0.canSelect
                        && $0.hardExclusion != nil
                }
                && !stateContained.isEmpty
                && stateContained.allSatisfy {
                    !$0.canSelect
                        && $0.hardExclusion != nil
                },
            "missing state authority or a state-contained clone exposed cleanup controls"
        )
        let protectedSelection = try RemovalSelection(
            candidate: feature,
            intent: feature.defaultIntent,
            includePossibleSecrets: false
        )
        let protectedPrepared =
            try PreparedRemovalOracle.prepare(
                selection: protectedSelection,
                retention: nil
            )
        let protectedConfirmation =
            try GroupedRemovalConfirmation(
                run: RunIdentity.make(),
                rows: [
                    ConfirmedRemovalRow(
                        prepared: protectedPrepared,
                        retained: true
                    ),
                ]
            )
        let protectedResult = try fixture.remove(
            protectedPrepared,
            confirmation: protectedConfirmation,
            executable: executable,
            additionalProtectedPaths: [
                fixture.repositoryPath,
            ]
        )
        try expect(
            protectedResult.status == .refused
                && protectedResult.commands.isEmpty
                && FileManager.default
                    .fileExists(atPath: path),
            "runtime removal admitted a clone contained by private state"
        )
        let prefix = [
            "-c", GitCommandPolicy.testRootMarker,
            "--no-replace-objects", "--no-lazy-fetch",
        ]
        let common = fixture.repositoryPath + "/.git"
        let worktreeAllowed = try GitCommandPolicy.validate(
            prefix + [
                "--git-dir=\(common)",
                "worktree", "remove", path,
            ],
            expectedCommonDirectory: common,
            expectedWorktreePath: path
        )
        let remoteRejected = (try? GitCommandPolicy.validate(
            prefix + [
                "push", "origin", "--delete",
                "visible-override",
            ]
        )) == nil
        let forceDeleteRejected =
            (try? GitCommandPolicy.validate(
                prefix + [
                    "branch", "-D", "visible-override",
                ]
            )) == nil
        let optionBranchRejected =
            (try? GitCommandPolicy.validate(
                prefix + [
                    "-C", fixture.repositoryPath,
                    "branch", "-d", "-unsafe",
                ],
                expectedWorktreePath:
                    fixture.repositoryPath
            )) == nil
        try expect(
            worktreeAllowed
                && remoteRejected
                && forceDeleteRejected
                && optionBranchRejected,
            "command grammar admitted remote or branch -D mutation"
        )

        let duplicatePath =
            try fixture.addDuplicateCloneWorktree(
                cloneName: "body3-t16-duplicate",
                branch: "duplicate-feature"
            )
        let duplicateInventory = try fixture.authorizedInventory(
            executable: executable
        )
        let selectedClone = try require(
            duplicateInventory.cards.flatMap(\.clones).first {
                $0.primaryRoot == fixture.repositoryPath
            },
            "selected physical clone disappeared after duplicate discovery"
        )
        let selectedScope = try ValidatedSelectedRepositoryScope.testing(
            candidates: [selectedClone.sourceSnapshot]
        )
        // Current chooser authority selects one physical root per origin. The
        // older Body 3 inventory-wide cleanup fixture must not authorize its
        // newly discovered duplicate through the selected root's capability.
        let mixedAuthority = try? VerifiedRepositoryAuthorityCapability(
            scope: selectedScope,
            inventory: duplicateInventory
        )
        try expect(
            duplicateInventory.cards.flatMap(\.clones).contains {
                $0.primaryRoot != fixture.repositoryPath
                    && $0.worktrees.contains { $0.path == duplicatePath }
            }
                && mixedAuthority == nil
                && FileManager.default.fileExists(atPath: duplicatePath)
                && FileManager.default.fileExists(atPath: path),
            "selected authority admitted an unselected duplicate physical clone"
        )
    }

    private static func node(
        _ suffix: String,
        repository: String,
        common: String,
        dependencies: [Body3BatchDependency] = []
    ) throws -> Body3BatchNode {
        try Body3BatchNode(
            id: "body3-node:\(suffix)",
            repositoryID: repository,
            commonDirectoryKey: common,
            kind: .reinspection,
            dependencies: dependencies,
            payload: .reinspection(
                repositoryID: repository,
                cloneID: common,
                reason: suffix
            )
        )
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw Body3SelfTestError(message)
        }
    }

    fileprivate static func require<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw Body3SelfTestError(message)
        }
        return value
    }
}

private final class BatchConcurrencyProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var keys = Set<String>()
    private(set) var maximumActive = 0
    private(set) var overlappedCommonDirectory = false

    func enter(_ key: String?) {
        lock.lock()
        active += 1
        maximumActive = max(maximumActive, active)
        if let key {
            if keys.contains(key) {
                overlappedCommonDirectory = true
            }
            keys.insert(key)
        }
        lock.unlock()
    }

    func leave(_ key: String?) {
        lock.lock()
        active -= 1
        if let key { keys.remove(key) }
        lock.unlock()
    }
}

private final class LockedFlag:
    @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LockedStopFlag:
    @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func stop() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct Body3SelfTestError:
    Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

private struct Body3FixturePullRequestLookup: PullRequestLookingUp, Sendable {
    func lookup(
        repositoryID: String,
        branch: String,
        tipOID: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult {
        cancellation.isCancelled
            ? .unavailable(.cancelled)
            : PullRequestLookupResult(records: [], unavailableReason: nil)
    }
}

final class Body3Fixture {
    let temporary: M1TemporaryDirectory
    let home: String
    let repositoryPath: String
    let remotePath: String
    let stateLocation: StateLocation
    let mapping: TransportMapping
    let account: EffectiveAccount
    let logicalURL: String
    init(
        repositoryName: String,
        owner: String = "owner",
        devUmbrella: Bool = false
    ) throws {
        temporary = try M1TemporaryDirectory()
        home = temporary.path + "/home"
        repositoryPath = devUmbrella
            ? home + "/dev"
            : home + "/dev/personal/\(repositoryName)"
        remotePath =
            temporary.path + "/\(repositoryName).git"
        logicalURL =
            "git@github.com:\(owner)/\(repositoryName).git"
        try FileManager.default.createDirectory(
            atPath: devUmbrella
                ? home : home + "/dev/personal",
            withIntermediateDirectories: true
        )
        try Self.installPolicy(home: home)
        try Self.gitProcess([
            "init", "--quiet",
            "--initial-branch=main", repositoryPath,
        ])
        try Self.gitProcess([
            "-C", repositoryPath, "config",
            "user.name", "Body 3 Fixture",
        ])
        try Self.gitProcess([
            "-C", repositoryPath, "config",
            "user.email", "fixture@example.invalid",
        ])
        try Data("initial\n".utf8).write(
            to: URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent("tracked.txt")
        )
        try Data(".env\n".utf8).write(
            to: URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent(".gitignore")
        )
        var initialPaths = [
            "tracked.txt", ".gitignore",
        ]
        if devUmbrella {
            initialPaths += [
                "_ops/policy/worktree-policy.yml",
                "_ops/bin/baseline-lib.sh",
                "_ops/bin/install-identity-guard.sh",
            ]
        }
        try Self.gitProcess([
            "-C", repositoryPath, "add",
        ] + initialPaths)
        try Self.gitProcess([
            "-C", repositoryPath, "commit",
            "--quiet", "-m", "initial",
        ])
        try Self.gitProcess([
            "init", "--bare", "--quiet",
            "--initial-branch=main", remotePath,
        ])
        try Self.gitProcess([
            "-C", repositoryPath, "remote",
            "add", "origin", logicalURL,
        ])
        try Self.gitProcess([
            "-c",
            "url.file://\(remotePath)/.insteadOf=\(logicalURL)",
            "-C", repositoryPath, "push",
            "--quiet", "-u", "origin", "main",
        ])
        stateLocation = try StateLocation.isolated(
            root: temporary.path
        )
        try TestIsolation.initializeState(at: stateLocation)
        mapping = try TransportMapping(
            logicalURL: logicalURL,
            localRepositoryPath: remotePath,
            containmentRoot: temporary.path
        )
        account = try EffectiveAccount.isolated(
            homeDirectory: home
        )
    }

    var mainOID: String {
        (try? gitText(["rev-parse", "main"]))
            ?? String(repeating: "0", count: 40)
    }

    func addWorktree(
        _ name: String,
        managedByAWA: Bool,
        uniqueCommit: Bool = false
    ) throws -> String {
        try git(["branch", name, "main"])
        let root = managedByAWA
            ? home + "/.local/share/awa/worktrees"
            : home + "/.cursor/worktrees"
        let path = root + "/\(name)"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        try git([
            "worktree", "add", "--quiet", path, name,
        ])
        if uniqueCommit {
            try Data("unique\n".utf8).write(
                to: URL(fileURLWithPath: path)
                    .appendingPathComponent("unique.txt")
            )
            try gitAt(path, ["add", "unique.txt"])
            try gitAt(path, [
                "commit", "--quiet", "-m", "unique",
            ])
        }
        return path
    }

    func makePrunableRegistration(
        _ name: String
    ) throws -> PrunableRegistrationEvidence {
        let path = try addWorktree(
            name,
            managedByAWA: false
        )
        let relative = try gitText([
            "rev-parse", "--git-path",
            "worktrees/\(name)",
        ])
        let registration = relative.hasPrefix("/")
            ? relative
            : repositoryPath + "/" + relative
        func metadata(
            _ path: String
        ) throws -> stat {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw Body3SelfTestError(
                    "could not inspect prunable fixture metadata"
                )
            }
            return info
        }
        let registrationInfo = try metadata(
            registration
        )
        let gitdirInfo = try metadata(
            registration + "/gitdir"
        )
        let headInfo = try metadata(
            registration + "/HEAD"
        )
        let commondirInfo = try metadata(
            registration + "/commondir"
        )
        let oid = try gitText([
            "rev-parse", "refs/heads/\(name)",
        ])
        try FileManager.default.removeItem(
            atPath: path
        )
        return try PrunableRegistrationEvidence(
            registrationID:
                URL(fileURLWithPath: registration)
                    .lastPathComponent,
            expectedWorktreePath: path,
            branchRef: "refs/heads/\(name)",
            branchOID: oid,
            registrationIdentity:
                RepositoryDirectoryIdentity(
                    FileIdentity(registrationInfo)
                ),
            gitdirIdentity:
                RepositoryMetadataFileIdentity(
                    gitdirInfo
                ),
            headIdentity:
                RepositoryMetadataFileIdentity(
                    headInfo
                ),
            commondirIdentity:
                RepositoryMetadataFileIdentity(
                    commondirInfo
                )
        )
    }

    func addDuplicateCloneWorktree(
        cloneName: String,
        branch: String
    ) throws -> String {
        let clonePath =
            home + "/dev/personal/\(cloneName)"
        try Self.gitProcess([
            "-c",
            "url.file://\(remotePath)/.insteadOf=\(logicalURL)",
            "clone", "--quiet", logicalURL, clonePath,
        ])
        try Self.gitProcess([
            "-C", clonePath, "config",
            "user.name", "Body 3 Fixture",
        ])
        try Self.gitProcess([
            "-C", clonePath, "config",
            "user.email", "fixture@example.invalid",
        ])
        try Self.gitProcess([
            "-C", clonePath, "branch", branch, "main",
        ])
        let root = home + "/.cursor/worktrees"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let path = root + "/\(cloneName)-\(branch)"
        try Self.gitProcess([
            "-C", clonePath, "worktree", "add",
            "--quiet", path, branch,
        ])
        return path
    }

    func makeRecoveryState(at path: String) throws {
        try Data("staged\n".utf8).write(
            to: URL(fileURLWithPath: path)
                .appendingPathComponent("staged.txt")
        )
        try gitAt(path, ["add", "staged.txt"])
        try Data("changed\n".utf8).write(
            to: URL(fileURLWithPath: path)
                .appendingPathComponent("tracked.txt")
        )
        try Data("untracked\n".utf8).write(
            to: URL(fileURLWithPath: path)
                .appendingPathComponent("untracked.txt")
        )
        try Data("secret\n".utf8).write(
            to: URL(fileURLWithPath: path)
                .appendingPathComponent(".env")
        )
        try FileManager.default.createDirectory(
            atPath: path + "/empty",
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: path + "/link-to-tracked",
            withDestinationPath: "tracked.txt"
        )
        guard chmod(path + "/tracked.txt", 0o755) == 0 else {
            throw Body3SelfTestError(
                "could not set executable mode fixture"
            )
        }
        try gitAt(path, [
            "update-index", "--split-index",
        ])
    }

    func inventory(
        executable: String
    ) throws -> RepositoryInventory {
        try RepositoryInventoryDiscovery(
            executablePath: executable,
            isolatedRoot: temporary.path,
            transportMapping: mapping
        ).discoverInventory()
    }

    // Cleanup is a separate authorized inspection, never part of initial discovery.
    func cleanupInventory(
        executable: String
    ) throws -> RepositoryInventory {
        let initial = try authorizedInventory(executable: executable)
        let discovery = try RepositoryInventoryDiscovery(
            executablePath: executable,
            isolatedRoot: temporary.path,
            transportMapping: mapping,
            pullRequestLookup: Body3FixturePullRequestLookup()
        )
        let scope = try ValidatedSelectedRepositoryScope.testing(
            candidates: initial.cards.flatMap(\.clones).map(\.sourceSnapshot)
        )
        let capability = try VerifiedRepositoryAuthorityCapability(
            scope: scope,
            inventory: initial
        )
        return try discovery.inspectCleanup(
            inventory: initial,
            repositoryIDs: scope.repositoryIDs,
            capability: capability
        )
    }

    func authorizedInventory(
        executable: String
    ) throws -> RepositoryInventory {
        let initial = try inventory(
            executable: executable
        )
        if initial.cards.first?.authority.status
            == .usable {
            return initial
        }
        let clone =
            try V2Body3SelfTestRunner.require(
                initial.cards.first?.clones.first {
                    $0.primaryRoot == repositoryPath
                },
                "fixture canonical clone missing"
            )
        guard clone.isAuthorityEligible else {
            throw Body3SelfTestError(
                "fixture canonical clone is not eligible: \(clone.warnings)"
            )
        }
        let state = try SecureStateDirectory.open(
            stateLocation
        )
        let store = RepositoryAuthorityStore(
            state: state
        )
        _ = try store.confirmOnboarding(
            proposals: [
                CanonicalAuthorityProposal(clone: clone),
            ],
            selectedRepositoryIDs: [
                clone.repositoryID,
            ],
            freshClones: [clone],
            expectedFileIdentity: nil
        )
        return try inventory(executable: executable)
    }

    func worktree(
        inventory: RepositoryInventory,
        path: String
    ) throws -> Worktree {
        try V2Body3SelfTestRunner.require(
            inventory.cards.first?.clones
                .flatMap(\.worktrees)
                .first { $0.path == path },
            "fixture Worktree missing"
        )
    }

    func worktreeCandidate(
        inventory: RepositoryInventory,
        path: String,
        preview: RemovalPreview,
        identitySuffix: String? = nil,
        currentSession: Bool? = nil,
        awaEvidence: AWAEvidence? = nil
    ) throws -> RemovalCandidate {
        let card = try V2Body3SelfTestRunner.require(
            inventory.cards.first,
            "fixture card missing"
        )
        let originalClone =
            try V2Body3SelfTestRunner.require(
                card.clones.first {
                    $0.primaryRoot == repositoryPath
                },
                "fixture clone missing"
            )
        guard let original =
                originalClone.worktrees.first(where: {
                    $0.path == path
                }) else {
            throw Body3SelfTestError(
                "fixture Worktree missing: expected \(path), observed \(originalClone.worktrees.map(\.path)); warnings \(originalClone.warnings)"
            )
        }
        let rebuilt = try Worktree(
            id: identitySuffix.map {
                original.id + ":\($0)"
            } ?? original.id,
            cloneID: original.cloneID,
            path: original.path,
            rootIdentity: original.rootIdentity,
            registrationIdentity:
                original.registrationIdentity,
            attachedBranchRef:
                original.attachedBranchRef,
            detachedOID: original.detachedOID,
            isPrimary: original.isPrimary,
            isLocked: original.isLocked,
            locationKind: original.locationKind,
            verification: original.verification,
            cleanliness: original.cleanliness,
            fileState: original.fileState,
            contentEvidenceDigest:
                original.contentEvidenceDigest,
            relationToDefault:
                original.relationToDefault,
            tipCommitDate: original.tipCommitDate,
            awaEvidence:
                awaEvidence
                    ?? original.awaEvidence,
            purpose: original.purpose,
            activity: original.activity,
            currentSession:
                currentSession
                    ?? original.currentSession,
            removalPreview: preview,
            warning: original.warning
        )
        let rebuiltClone = try LocalClone(
            repositoryID: originalClone.repositoryID,
            sourceSnapshot:
                originalClone.sourceSnapshot,
            effectiveOrigin:
                originalClone.effectiveOrigin,
            originParityVerified:
                originalClone.originParityVerified,
            policyCategory:
                originalClone.policyCategory,
            kind: originalClone.kind,
            worktrees:
                originalClone.worktrees.map {
                    $0.path == path ? rebuilt : $0
                },
            branches: originalClone.branches,
            warnings: originalClone.warnings
        )
        return try RemovalCandidate(
            repository: card.repository,
            clone: rebuiltClone,
            worktree: rebuilt
        )
    }

    func branchCandidate(
        inventory: RepositoryInventory,
        name: String,
        preview: RemovalPreview
    ) throws -> RemovalCandidate {
        let card = try V2Body3SelfTestRunner.require(
            inventory.cards.first,
            "fixture card missing"
        )
        let originalClone =
            try V2Body3SelfTestRunner.require(
                card.clones.first {
                    $0.primaryRoot == repositoryPath
                },
                "fixture clone missing"
            )
        let original =
            try V2Body3SelfTestRunner.require(
                originalClone.branches.first {
                    $0.name == name
                },
                "fixture Branch missing"
            )
        let rebuilt = try Branch(
            cloneID: original.cloneID,
            fullRef: original.fullRef,
            tipOID: original.tipOID,
            claimingWorktreeIDs:
                original.claimingWorktreeIDs,
            relationToDefault:
                original.relationToDefault
                    ?? DefaultBranchRelation(
                        kind: .equal,
                        aheadCount: 0,
                        behindCount: 0
                    ),
            upstream: original.upstream,
            commitDate: original.commitDate,
            pullRequests: original.pullRequests ?? [],
            pullRequestAvailability:
                original.pullRequestAvailability
                    ?? .available,
            purpose: original.purpose
                ?? PurposeAssessment(
                    purpose: .integrated,
                    exactAssociations: [],
                    allCandidates: [],
                    explanation:
                        "Synthetic selected fixture has complete preserved-history evidence."
                ),
            activity: original.activity
                ?? .staleCandidate,
            removalPreview: preview
        )
        let rebuiltClone = try LocalClone(
            repositoryID: originalClone.repositoryID,
            sourceSnapshot:
                originalClone.sourceSnapshot,
            effectiveOrigin:
                originalClone.effectiveOrigin,
            originParityVerified:
                originalClone.originParityVerified,
            policyCategory:
                originalClone.policyCategory,
            kind: originalClone.kind,
            worktrees: originalClone.worktrees,
            branches:
                originalClone.branches.map {
                    $0.name == name ? rebuilt : $0
                },
            warnings: originalClone.warnings
        )
        return try RemovalCandidate(
            repository: card.repository,
            clone: rebuiltClone,
            branch: rebuilt
        )
    }

    func retentionStore() throws
        -> RetentionArtifactStore {
        RetentionArtifactStore(
            state: try SecureStateDirectory.open(
                stateLocation
            ),
            account: account
        )
    }

    func installAWA(
        exitStatus: Int32,
        removeOnSuccess: Bool = false
    ) throws -> String {
        let path =
            home + "/dev/_ops/bin/dev-worktree.sh"
        let log = temporary.path + "/awa.log"
        let script = """
        #!/bin/bash
        [ "$AWA_POLICY" = "\(home)/dev/_ops/policy/worktree-policy.yml" ] || exit 91
        [ "$AWA_GOVERNED_ROOT" = "\(home)/dev" ] || exit 92
        printf '%s|%s|%s\\n' "$1" "$2" "$3" >> "\(log)"
        \(removeOnSuccess ? #"/usr/bin/git worktree remove "$3" || exit $?"# : "")
        exit \(exitStatus)
        """
        try Data(script.utf8).write(
            to: URL(fileURLWithPath: path)
        )
        guard chmod(path, 0o700) == 0 else {
            throw Body3SelfTestError(
                "could not install AWA fixture"
            )
        }
        return path
    }

    func installReferenceTransactionTrace(
        _ name: String
    ) throws -> String {
        let hooks = repositoryPath + "/.git/hooks"
        let log = temporary.path + "/\(name)-hook.log"
        let path = hooks + "/reference-transaction"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$1" >> "\(log)"
        exit 0
        """
        try Data(script.utf8).write(
            to: URL(fileURLWithPath: path)
        )
        guard chmod(path, 0o700) == 0 else {
            throw Body3SelfTestError(
                "could not install reference transaction trace"
            )
        }
        try Data().write(
            to: URL(fileURLWithPath: log)
        )
        return log
    }

    func remove(
        _ prepared: PreparedRemoval,
        confirmation: GroupedRemovalConfirmation,
        executable: String,
        additionalProtectedPaths: [String] = []
    ) throws -> RemovalExecutionResult {
        let authority = try RunAuthority.acquireRun(
            at: stateLocation
        )
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let git = GitTransactionConfiguration(
            trampolineExecutable: executable,
            operationLeaseDescriptor: lease,
            transportMapping: mapping
        )
        return RemovalTransaction(
            runner: DescriptorProcessRunner(),
            configuration:
                RemovalTransactionConfiguration(
                    git: git,
                    stateLocation: stateLocation,
                    awaExecutablePath:
                        home
                            + "/dev/_ops/bin/dev-worktree.sh",
                    protectedPaths: [
                        stateLocation.path,
                        executable,
                    ] + additionalProtectedPaths
                ),
            account: account
        ).execute(
            prepared: prepared,
            confirmation: confirmation,
            cancellation: CancellationToken()
        )
    }

    func git(
        _ arguments: [String],
        allowFailure: Bool = false
    ) throws {
        _ = try Self.gitProcess(
            ["-C", repositoryPath] + arguments,
            allowFailure: allowFailure
        )
    }

    func gitAt(
        _ path: String,
        _ arguments: [String],
        allowFailure: Bool = false
    ) throws {
        _ = try Self.gitProcess(
            ["-C", path] + arguments,
            allowFailure: allowFailure
        )
    }

    func gitText(
        _ arguments: [String],
        allowFailure: Bool = false
    ) throws -> String {
        String(
            decoding: try Self.gitProcess(
                ["-C", repositoryPath] + arguments,
                allowFailure: allowFailure
            ),
            as: UTF8.self
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    func remove() {
        temporary.remove()
    }

    private static func installPolicy(
        home: String
    ) throws {
        let root = home + "/dev/_ops"
        try FileManager.default.createDirectory(
            atPath: root + "/policy",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/bin",
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
          if [ "$ownerrepo_lc" = "blocked/example" ]; then
            return 0
          fi
          return 0
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
                root + "/policy/worktree-policy.yml")
        )
        try Data(baseline.utf8).write(
            to: URL(fileURLWithPath:
                root + "/bin/baseline-lib.sh")
        )
        try Data(hookInstaller.utf8).write(
            to: URL(fileURLWithPath:
                root + "/bin/install-identity-guard.sh")
        )
    }

    @discardableResult
    private static func gitProcess(
        _ arguments: [String],
        allowFailure: Bool = false
    ) throws -> Data {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = temporary.path + "/home"
        try FileManager.default.createDirectory(atPath: home,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let directory = Darwin.open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Body3SelfTestError("fixture command directory unavailable") }
        defer { close(directory) }
        let result = try ClosedProcessRunner(outputLimit: DescriptorProcessRunner.completeRepositoryOutputLimit).run(
            command: ClosedProcessCommand(executable: discoveryFixtureGitExecutable, arguments: arguments),
            environment: ClosedProcessRunner.environment(account: account),
            workingDirectoryDescriptor: directory, account: account, timeout: 30,
            cancellation: CancellationToken())
        guard (allowFailure || result.status == 0) && !result.cancelled && !result.timedOut
                && !result.stdoutTruncated && !result.stderrTruncated else {
            throw Body3SelfTestError("fixture command failed: " + Redactor.subprocessBytes(result.output))
        }
        return result.output
    }
}
#endif
