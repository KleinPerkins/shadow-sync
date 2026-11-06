#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum M1SelfTestRunner {
    public static func runAll(
        testExecutable: String,
        onPass: (String) -> Void = { _ in }
    ) throws -> [String] {
        signal(SIGPIPE, SIG_IGN)
        guard testExecutable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: testExecutable) else {
            throw M1SelfTestError.message("testing app executable is unavailable")
        }
        let tests: [(String, () throws -> Void)] = [
            ("descriptor-owner-cancellation-ordering", { try RunnerOwnerOrderingFixtures.descriptor(executable: testExecutable) }),
            ("models-origins-redaction", testModelsOriginsAndRedaction),
            ("owned-process-reaper-exited-child", testOwnedProcessReaperExitedChild),
            ("report-summary-result-classes", testReportSummaryResultClasses),
            ("worker-exit-report-authority", testWorkerExitReportAuthority),
            ("run-log-identity-recovery", testRunLogIdentityRecovery),
            ("m1-worker-admission-invariant", testM1WorkerAdmissionInvariant),
            ("discovery-error-presentation", testDiscoveryErrorPresentation),
            ("closed-command-environment", testClosedCommandAndEnvironment),
            ("repository-metadata-and-object-graph", testRepositoryMetadataAndObjectGraph),
            (
                "trampoline-root-identity",
                { try testTrampolineRootIdentity(executable: testExecutable) }
            ),
            (
                "combined-hidden-index-flags-preflight",
                { try testCombinedHiddenIndexFlagsPreflight(executable: testExecutable) }
            ),
            (
                "m2-effective-custom-transport-pre-fetch",
                { try testM2EffectiveCustomTransport(executable: testExecutable) }
            ),
            (
                "one-run-owner-log-preservation",
                { try testOneRunOwnerAndLogPreservation(executable: testExecutable) }
            ),
            ("inherited-operation-lease", testInheritedOperationLease),
            (
                "frozen-config-recovery-live-refusal",
                { try testFrozenConfigRecoveryAndLiveRefusal(executable: testExecutable) }
            ),
            (
                "git-descendant-lease-isolation",
                { try testGitDescendantLeaseIsolation(executable: testExecutable) }
            ),
            ("hardlink-framing-partial-tail", testHardlinkFramingAndPartialTail),
            (
                "child-metadata-mismatch",
                { try testChildMetadataMismatch(executable: testExecutable) }
            ),
            (
                "child-start-admission-race",
                { try testChildStartAdmissionRace(executable: testExecutable) }
            ),
            (
                "child-spawn-descriptor-collision",
                {
                    try testChildSpawnDescriptorCollision(
                        executable: testExecutable
                    )
                }
            ),
            (
                "child-identity-capture-failure",
                { try testChildIdentityCaptureFailure(executable: testExecutable) }
            ),
            (
                "child-graph-config-races",
                { try testChildGraphAndConfigRaces(executable: testExecutable) }
            ),
            (
                "log-failure-cancels-admission",
                { try testLogFailureCancelsAdmission(executable: testExecutable) }
            ),
            (
                "fetch-porcelain-freezes-target",
                { try testFetchPorcelainFreezesTarget(executable: testExecutable) }
            ),
            (
                "snapshot-argv-privacy-size",
                { try testSnapshotArgvPrivacyAndSize(executable: testExecutable) }
            ),
            ("machine-output-integrity", testMachineOutputIntegrity),
            (
                "final-pre-spawn-mutations",
                { try testFinalPreSpawnMutations(executable: testExecutable) }
            ),
            (
                "cancellation-taxonomy-boundaries",
                { try testCancellationTaxonomyBoundaries(executable: testExecutable) }
            ),
            (
                "post-fetch-cancellation-no-update",
                { try testPostFetchCancellationNoUpdate(executable: testExecutable) }
            ),
            (
                "cancelled-fetch-termination",
                { try testCancelledFetchTermination(executable: testExecutable) }
            ),
            ("peer-close-channels", testPeerCloseChannels),
            (
                "channel-eof-process-drain",
                { try testChannelEOFProcessDrain(executable: testExecutable) }
            ),
        ]
        var completed: [String] = []
        for (name, test) in tests {
            do {
                try RuntimeFixtureSession.withCase(name) { try test() }
                completed.append(name)
                onPass(name)
            } catch {
                throw M1SelfTestError.testFailed(name, String(describing: error))
            }
        }
        return completed
    }

    private static func testOwnedProcessReaperExitedChild() throws {
        // Preserve the twenty already-exited/zero-timeout cases using the sole
        // original owner; Foundation Process must not introduce another reaper.
        for _ in 0..<20 {
            let child = try M1FixtureChild(.exited)
            defer { child.stop() }
            try child.resume()
            let deadline = MonotonicDeadline(seconds: 2)
            while child.owner.poll() == .running && child.owner.terminalStatusHeld == nil && !deadline.hasExpired {
                usleep(1_000)
            }
            try check(try child.waitForExit(timeout: 0) == 0, "already-exited child was not reaped")
        }
    }

    private static func testModelsOriginsAndRedaction() throws {
        let ssh = try require(
            GitHubIdentity.parse("git@github.com:Fixture-Owner/Fixture.git"),
            "supported SSH origin did not parse"
        )
        let https = try require(
            GitHubIdentity.parse("https://github.com/fixture-owner/fixture"),
            "supported HTTPS origin did not parse"
        )
        try check(ssh.transport == .ssh, "SSH transport was not retained")
        try check(https.transport == .https, "HTTPS transport was not retained")
        try check(
            ssh.canonicalName == https.canonicalName,
            "same GitHub identity did not canonicalize equally"
        )
        let rewritten = try GitTransaction.validatedEffectiveIdentity(
            "git@github.com:fixture-owner/fixture.git",
            rawIdentity: https
        )
        try check(
            rewritten.canonicalName == https.canonicalName,
            "same-identity GitHub transport rewrite was refused"
        )
        try check(
            throwsError {
                _ = try GitTransaction.validatedEffectiveIdentity(
                    "git@github.com:other-owner/fixture.git",
                    rawIdentity: https
                )
            },
            "effective GitHub retargeting was accepted"
        )
        try check(
            GitHubIdentity.parse("https://token@github.com/fixture-owner/fixture.git") == nil,
            "credential-bearing origin was accepted"
        )
        try check(
            GitHubIdentity.parse("ssh://example.invalid/fixture-owner/fixture.git") == nil,
            "non-GitHub origin was accepted"
        )
        let dotted = Data(
            """
            [remote.origin]
                url = git@github.com:fixture-owner/fixture.git
                uploadpack = hostile
            """.utf8
        )
        try check(
            throwsError { _ = try RawGitConfig.parse(dotted) },
            "deprecated dotted remote subsection was accepted"
        )
        let customSSH = Data(
            """
            [core]
                sshCommand = /private/tmp/hostile-ssh
            [remote "origin"]
                url = git@github.com:fixture-owner/fixture.git
            """.utf8
        )
        try check(
            throwsError { _ = try RawGitConfig.parse(customSSH) },
            "ordinary local core.sshCommand was accepted"
        )
        try check(
            try RepositoryHandle.activeSystemPath(from: Data()) == nil,
            "empty active system configuration activated a candidate"
        )
        let activeSystemRecords = Data(
            "file:/private/tmp/active-system\u{0}core.editor\u{0}".utf8
        )
        try check(
            try RepositoryHandle.activeSystemPath(from: activeSystemRecords)
                == "/private/tmp/active-system",
            "active system configuration source was not selected exactly"
        )

        let candidate = RepositoryCandidate(
            id: "fixture",
            displayName: "Fixture",
            path: "/private/tmp/fixture",
            rawOrigin: "git@github.com:fixture-owner/fixture.git"
        )
        let result = RepositoryResult(
            repository: candidate,
            code: .alreadyCurrent,
            fetched: true,
            mainUpdated: false,
            beforeCommit: String(repeating: "a", count: 40),
            targetCommit: String(repeating: "a", count: 40),
            afterCommit: String(repeating: "a", count: 40),
            startedAt: "2026-09-03T00:00:00.000Z",
            endedAt: "2026-09-03T00:00:00.001Z",
            durationMilliseconds: 1,
            explanation: "Local main is already current."
        )
        let report = RunReport(
            run: "run",
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            cancelled: false,
            results: [result]
        )
        try check(
            report.summary == "Run complete — 0 updated, 1 already current.",
            "report summary was not explicit"
        )

        let redacted = Redactor.subprocessBytes(
            Data(
                """
                https://fixture:secret-value@github.com/fixture-owner/fixture.git
                Authorization: Bearer secret-value
                password=secret-value
                api_key=api-key-secret-value
                api-key=hyphen-api-secret-value
                access_token=access-token-secret-value
                access-token=hyphen-access-secret-value
                credential=credential-secret-value
                credentials=credentials-secret-value
                PAT=pat-secret-value
                Bearer standalone-bearer-secret
                ssh://fixture:ssh-url-secret@example.invalid/repository
                github_pat_1234567890abcdefghijklmnop
                ghp_1234567890abcdefghijklmnop
                -----BEGIN OPENSSH PRIVATE KEY-----
                private-key-seed-value
                -----END OPENSSH PRIVATE KEY-----
                """.utf8
            )
        )
        try check(!redacted.contains("fixture:secret-value"), "URL credential was retained")
        try check(!redacted.contains("Bearer secret-value"), "authorization value was retained")
        try check(!redacted.contains("password=secret-value"), "password was retained")
        for secret in [
            "api-key-secret-value",
            "access-token-secret-value",
            "hyphen-api-secret-value",
            "hyphen-access-secret-value",
            "credential-secret-value",
            "credentials-secret-value",
            "pat-secret-value",
            "standalone-bearer-secret",
            "ssh-url-secret",
            "github_pat_1234567890abcdefghijklmnop",
            "ghp_1234567890abcdefghijklmnop",
            "private-key-seed-value",
        ] {
            try check(!redacted.contains(secret), "common credential form was retained")
        }
        try check(redacted.contains("[REDACTED]"), "redaction marker was omitted")
        try check(
            Redactor.subprocessBytes(
                Data(repeating: 0x61, count: Redactor.subprocessByteLimit + 1)
            ).hasSuffix("[output truncated]"),
            "subprocess output was not bounded"
        )
    }

    private static func testReportSummaryResultClasses() throws {
        let updatedWarning = makeResult(code: .updatedWithWarning, updated: true)
        let skipped = makeResult(code: .skippedDirty)
        let failed = makeResult(code: .failedInspection)
        let issues = RunReport(
            run: "issues",
            startedAt: updatedWarning.startedAt,
            endedAt: updatedWarning.endedAt,
            cancelled: false,
            results: [updatedWarning, skipped, failed]
        )
        try check(issues.updatedCount == 1, "updated warning was not counted as updated")
        try check(
            issues.summary.contains("1 updated, 1 skipped, 1 failed"),
            "updated warning was incorrectly counted as skipped"
        )
        let cancellationCodes: [ResultCode] = [
            .cancelledPending, .cancelledDuringFetch, .cancelledNoUpdate,
        ]
        let cancellation = RunReport(
            run: "cancelled",
            startedAt: updatedWarning.startedAt,
            endedAt: updatedWarning.endedAt,
            cancelled: true,
            results: [makeResult(code: .alreadyCurrent)]
                + cancellationCodes.map { makeResult(code: $0) }
        )
        try check(
            cancellation.summary.contains("1 repositories completed"),
            "cancelled in-flight rows were counted as completed"
        )
        try check(
            cancellation.summary
                == "Run cancelled — 1 repositories completed before cancellation; 3 were not run. Completed updates were kept.",
            "cancelled rows were not reported as incomplete"
        )
        try check(
            cancellation.cancellationState == .cancelled,
            "run cancellation state was not explicit"
        )
        for code in ResultCode.allCases {
            let expected: ResultClass
            switch code {
            case .updated, .alreadyCurrent, .updatedBeforeCancellation:
                expected = .success
            case .updatedWithWarning, .skippedAhead, .skippedDiverged, .skippedDirty,
                 .skippedBusy, .skippedDetachedHead, .skippedPrimaryNotOnMain,
                 .skippedMainInLinkedWorktree,
                 .skippedLocalMainMissing, .skippedRemoteMainMissing,
                 .skippedHiddenIndexState, .skippedUnsupportedHookFramework,
                 .skippedRepositoryRemoved, .skippedOriginChanged,
                 .skippedIgnoredFileCollision:
                expected = .warning
            case .failedInspection, .failedFetchAuthentication, .failedFetchNetwork,
                 .failedFetch, .failedUpdate, .needsAttention:
                expected = .failure
            case .cancelledPending, .cancelledDuringFetch, .cancelledNoUpdate:
                expected = .cancelled
            }
            try check(code.resultClass == expected, "result class drifted for \(code.rawValue)")
        }
    }

    private static func testWorkerExitReportAuthority() throws {
        try check(
            WorkerExitPresentationDecision.resolve(
                status: 17,
                hasValidatedCompleteReport: true
            ) == .preserveCompletedReport,
            "nonzero worker exit overrode a validated complete report"
        )
        try check(
            WorkerExitPresentationDecision.resolve(
                status: 17,
                hasValidatedCompleteReport: false
            ) == .presentFailure(status: 17),
            "nonzero worker exit without a complete report did not fail"
        )
        try check(
            WorkerExitPresentationDecision.resolve(
                status: 0,
                hasValidatedCompleteReport: false
            ) == .presentFailure(status: 0),
            "clean worker exit without a complete report was treated as complete"
        )
    }

    private static func testRunLogIdentityRecovery() throws {
        let expectedRunID = RunIdentity.make()
        let staleRunID = RunIdentity.make()
        let currentReport = RunReport(
            run: expectedRunID,
            startedAt: "2026-09-04T00:00:00.000Z",
            endedAt: "2026-09-04T00:00:00.001Z",
            cancelled: false,
            results: [makeResult(code: .alreadyCurrent)]
        )
        let staleReport = RunReport(
            run: staleRunID,
            startedAt: "2026-09-03T00:00:00.000Z",
            endedAt: "2026-09-03T00:00:00.001Z",
            cancelled: false,
            results: [makeResult(code: .alreadyCurrent)]
        )
        let matching = LogRecord(
            run: expectedRunID,
            sequence: 1,
            type: "run_finished",
            report: currentReport
        )
        let stale = LogRecord(
            run: staleRunID,
            sequence: 1,
            type: "run_finished",
            report: staleReport
        )
        let mismatchedPayload = LogRecord(
            run: expectedRunID,
            sequence: 1,
            type: "run_finished",
            report: staleReport
        )
        let partial = LogRecord(
            run: expectedRunID,
            sequence: 1,
            type: "repository_result"
        )

        let recovered = RunLogReader.completedReport(
            in: [matching],
            matching: expectedRunID
        )
        try check(recovered == currentReport, "matching terminal report was not recovered")
        try check(
            WorkerExitPresentationDecision.resolve(
                status: 17,
                hasValidatedCompleteReport: recovered != nil
            ) == .preserveCompletedReport,
            "matching recovered report was overridden by nonzero exit"
        )
        for records in [[stale], [mismatchedPayload], [partial], []] {
            let invalid = RunLogReader.completedReport(
                in: records,
                matching: expectedRunID
            )
            try check(invalid == nil, "stale, malformed, partial, or absent report was recovered")
            try check(
                WorkerExitPresentationDecision.resolve(
                    status: 17,
                    hasValidatedCompleteReport: invalid != nil
                ) == .presentFailure(status: 17),
                "invalid recovery suppressed current-worker failure"
            )
        }
    }

    private static func testM1WorkerAdmissionInvariant() throws {
        let first = RepositoryCandidate(
            id: "fixture-owner/first",
            displayName: "First",
            path: "/private/tmp/first",
            rawOrigin: "git@github.com:fixture-owner/first.git"
        )
        let second = RepositoryCandidate(
            id: "fixture-owner/second",
            displayName: "Second",
            path: "/private/tmp/second",
            rawOrigin: "git@github.com:fixture-owner/second.git"
        )
        try check(M1Selection.onlyCandidate(in: []) == nil, "empty M1 selection was admitted")
        try check(
            M1Selection.onlyCandidate(in: [first]) == first,
            "single M1 selection was not admitted"
        )
        try check(
            M1Selection.onlyCandidate(in: [first, second]) == nil,
            "multiple M1 selections were admitted"
        )
        try check(
            M1Selection.admits(request: first, discovered: [first]),
            "exact single worker request was not admitted"
        )
        try check(
            !M1Selection.admits(request: second, discovered: [first]),
            "forged worker request was admitted"
        )
        try check(
            !M1Selection.admits(request: first, discovered: []),
            "worker request was admitted without discovery"
        )
        try check(
            !M1Selection.admits(request: first, discovered: [first, second]),
            "first-row worker request was admitted from multiple discoveries"
        )
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let realHome = try EffectiveAccount.current().homeDirectory
        let crafted = try JSONSerialization.data(withJSONObject: [
            "logicalURL": "git@github.com:fixture-owner/fixture.git",
            "localRepositoryPath": realHome,
            "containmentRoot": temporary.path,
        ])
        try check(
            throwsError {
                try JSONDecoder().decode(TransportMapping.self, from: crafted)
            },
            "custom-decoded transport mapping bypassed containment validation"
        )
        try check(
            throwsError { try StateLocation.isolated(root: realHome) },
            "testing state accepted the real home"
        )
        try check(
            throwsError { try EffectiveAccount.isolated(homeDirectory: realHome) },
            "testing account accepted the real home"
        )
    }

    private static func testDiscoveryErrorPresentation() throws {
        let expected: [(M1RepositoryDiscoveryError, String)] = [
            (.accountUnavailable, "Account Information Unavailable"),
            (.requiredRootUnavailable, "Required ~/dev Folder Unavailable"),
            (.locationUnavailable, "Required ~/dev Folder Unavailable"),
            (.unsupportedLayout, "Required ~/dev Folder Unavailable"),
            (.invalidRepositoryMetadata, "Repository Could Not Be Verified"),
        ]
        for (error, title) in expected {
            let presentation = RepositoryDiscoveryFailurePresentation.forError(error)
            try check(presentation.messageText == title, "discovery failure title was inaccurate")
            try check(
                !presentation.messageText.contains("Safety Policy"),
                "M1 discovery failure claimed policy unavailability"
            )
            try check(
                !presentation.informativeText.contains("No repositories were checked"),
                "M1 discovery failure used the policy-only recovery copy"
            )
        }

        let fallback = RepositoryDiscoveryFailurePresentation.forError(
            GitSafetyError.unsafeRepository("fixture")
        )
        try check(fallback.messageText == "Repository Check Failed", "fallback title was inaccurate")
        try check(
            fallback.informativeText.contains("layout and Git metadata"),
            "fallback recovery was not actionable"
        )

        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = URL(fileURLWithPath: temporary.path)
            .appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let discovery = try M1RepositoryDiscovery(testingHomeDirectory: home.path)
        var missingError: M1RepositoryDiscoveryError?
        do {
            _ = try discovery.discover()
        } catch let error as M1RepositoryDiscoveryError {
            missingError = error
        }
        try check(
            missingError == .requiredRootUnavailable,
            "missing canonical root was reported as an empty candidate list"
        )
        let missingPresentation = RepositoryDiscoveryFailurePresentation.forError(
            missingError ?? M1RepositoryDiscoveryError.accountUnavailable
        )
        try check(
            missingPresentation.informativeText.contains("Restore or check out ~/dev"),
            "missing-root recovery was not actionable"
        )

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("dev", isDirectory: true),
            withIntermediateDirectories: false
        )
        try check(
            try discovery.discover().isEmpty,
            "valid non-repository ~/dev was not an honest no-candidate result"
        )
        let empty = RepositoryDiscoveryEmptyPresentation.m1NoCandidate
        try check(
            empty.messageText == "No Eligible Repository Found"
                && empty.informativeText.contains("found ~/dev")
                && empty.informativeText.contains("No update was started"),
            "valid no-candidate presentation was inaccurate"
        )
    }

    private static func testClosedCommandAndEnvironment() throws {
        let objectID = String(repeating: "a", count: 40)
        let fetch = [
            "--no-replace-objects",
            "fetch",
            "--porcelain",
            "--verbose",
            "--no-write-fetch-head",
            "--no-tags",
            "--no-prune",
            "--no-recurse-submodules",
            "--no-auto-maintenance",
            "origin",
            "refs/heads/main:refs/remotes/origin/main",
        ]
        let update = [
            "--no-replace-objects",
            "--no-lazy-fetch",
            "merge",
            "--ff-only",
            "--no-overwrite-ignore",
            "--no-autostash",
            objectID,
        ]
        try check(try !GitCommandPolicy.validate(fetch), "safe fetch was not accepted")
        try check(try !GitCommandPolicy.validate(update), "safe update was not accepted")
        try check(
            rejectsGitCommand(fetch.filter { $0 != "--porcelain" }),
            "fetch without porcelain output was accepted"
        )
        try check(
            rejectsGitCommand(fetch.filter { $0 != "--verbose" }),
            "fetch without explicit equal-ref porcelain output was accepted"
        )
        try check(
            rejectsGitCommand(fetch.filter { $0 != "--no-write-fetch-head" }),
            "fetch without no-write-fetch-head was accepted"
        )
        try check(
            rejectsGitCommand(fetch.filter { $0 != "--no-recurse-submodules" }),
            "fetch without no-recursion was accepted"
        )
        try check(
            rejectsGitCommand(fetch.filter { $0 != "--no-auto-maintenance" }),
            "fetch without no-auto-maintenance was accepted"
        )
        try check(
            rejectsGitCommand(update.filter { $0 != "--no-lazy-fetch" }),
            "merge without no-lazy-fetch was accepted"
        )
        try check(
            rejectsGitCommand(update.filter { $0 != "--no-autostash" }),
            "merge without no-autostash was accepted"
        )
        try check(
            rejectsGitCommand([
                "--no-replace-objects",
                "fetch",
                "--porcelain",
                "--verbose",
                "--no-write-fetch-head",
                "--no-tags",
                "--no-prune",
                "--no-recurse-submodules",
                "--no-auto-maintenance",
                "origin",
                "+refs/heads/main:refs/remotes/origin/main",
            ]),
            "force refspec was accepted"
        )
        for arguments in [
            ["--no-replace-objects", "pull", "origin", "main"],
            ["--no-replace-objects", "reset", "--hard", objectID],
            ["--no-replace-objects", "push", "--force", "origin", "main"],
        ] {
            try check(rejectsGitCommand(arguments), "banned command was accepted")
        }

        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = URL(fileURLWithPath: temporary.path)
            .appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let account = EffectiveAccount(
            uid: geteuid(),
            username: "fixture",
            homeDirectory: home.path
        )
        let environment = ClosedGitEnvironment.make(
            account: account,
            transport: .ssh,
            inherited: [
                "SSH_AUTH_SOCK": "/not/a/socket",
                "GIT_TRACE": "/private/tmp/forbidden-trace",
                "GIT_TRACE2_EVENT": "/private/tmp/forbidden-trace2",
                "GIT_REDIRECT_STDERR": "/private/tmp/forbidden-output",
                "GIT_ASKPASS": "/private/tmp/forbidden-askpass",
                "GIT_SSH_COMMAND": "/private/tmp/forbidden-ssh",
                "TOKEN": "do-not-inherit",
            ]
        )
        try check(environment["HOME"] == account.homeDirectory, "fixed HOME was not set")
        try check(environment["PATH"] == ClosedGitEnvironment.fixedPath, "PATH was not fixed")
        try check(environment["GIT_TERMINAL_PROMPT"] == "0", "terminal prompt was not disabled")
        try check(environment["GIT_ASKPASS"] == "/usr/bin/false", "Git askpass was not disabled")
        try check(environment["SSH_ASKPASS"] == "/usr/bin/false", "SSH askpass was not disabled")
        try check(environment["GIT_NO_REPLACE_OBJECTS"] == "1", "replacement objects were enabled")
        try check(
            environment["GIT_SSH_COMMAND"] == ClosedGitEnvironment.fixedSSHCommand,
            "SSH command was not fixed"
        )
        for key in ["SSH_AUTH_SOCK", "GIT_TRACE", "GIT_TRACE2_EVENT", "GIT_REDIRECT_STDERR", "TOKEN"] {
            try check(environment[key] == nil, "inherited \(key) survived")
        }

        let socketPath = URL(fileURLWithPath: temporary.path)
            .appendingPathComponent("agent.sock").path
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw M1SelfTestError.systemCall("agent socket", errno) }
        defer { close(socketDescriptor); _ = unlink(socketPath) }
        guard fcntl(socketDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw M1SelfTestError.systemCall("agent socket close-on-exec", errno)
        }
        var address = sockaddr_un()
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw M1SelfTestError.message("agent socket path too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0 else {
            throw M1SelfTestError.systemCall("bind agent socket", errno)
        }
        let validEnvironment = ClosedGitEnvironment.make(
            account: account,
            transport: .ssh,
            inherited: [
                "SSH_AUTH_SOCK": socketPath,
                "SHADOW_SYNC_UNRELATED_SENTINEL": "must-not-survive",
            ]
        )
        try check(
            validEnvironment["SSH_AUTH_SOCK"] == socketPath,
            "controlled Unix agent socket did not survive the closed Git environment"
        )
        try check(
            validEnvironment["SHADOW_SYNC_UNRELATED_SENTINEL"] == nil,
            "unrelated sentinel survived beside the agent socket"
        )
        try check(
            ClosedGitEnvironment.make(
                account: account,
                transport: .https,
                inherited: ["SSH_AUTH_SOCK": socketPath]
            )["SSH_AUTH_SOCK"] == nil,
            "SSH agent socket survived into a non-SSH Git transport"
        )
        let ordinaryFile = URL(fileURLWithPath: temporary.path)
            .appendingPathComponent("not-a-socket").path
        try Data().write(to: URL(fileURLWithPath: ordinaryFile))
        for invalid in [ordinaryFile, "relative-agent.sock", "/does/not/exist/agent.sock"] {
            try check(
                ClosedGitEnvironment.make(
                    account: account,
                    transport: .ssh,
                    inherited: ["SSH_AUTH_SOCK": invalid]
                )["SSH_AUTH_SOCK"] == nil,
                "invalid agent socket value survived: \(invalid)"
            )
        }
    }

    private static func testRepositoryMetadataAndObjectGraph() throws {
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let aliasParent = URL(fileURLWithPath: fixture.rootPath)
                .appendingPathComponent("parent-alias").path
            guard symlink(fixture.rootPath, aliasParent) == 0 else {
                throw M1SelfTestError.systemCall("create repository parent alias", errno)
            }
            let aliasPath = URL(fileURLWithPath: aliasParent)
                .appendingPathComponent("repository").path
            let aliased = try RepositoryHandle.fixedCandidate(path: aliasPath)
            let physicalHandle = try RepositoryHandle.open(fixture.candidate)
            try check(
                aliased.path == fixture.candidate.path,
                "descriptor path did not canonicalize an equivalent parent alias"
            )
            try check(
                !RepositoryRootPathIdentity.matches(
                    path: aliasPath,
                    expected: physicalHandle.identity.root
                ),
                "user-owned parent alias matched descriptor root identity"
            )
            let trustedAliasPath =
                "/tmp/"
                + fixture.repositoryPath.dropFirst("/private/tmp/".count)
            try check(
                fixture.repositoryPath.hasPrefix("/private/tmp/")
                    && RepositoryRootPathIdentity.matches(
                        path: trustedAliasPath,
                        expected: physicalHandle.identity.root
                    ),
                "trusted system path alias did not match descriptor root identity"
            )
            try check(
                aliased.rootIdentity == fixture.candidate.rootIdentity
                    && aliased.gitDirectoryIdentity == fixture.candidate.gitDirectoryIdentity
                    && aliased.commonDirectoryIdentity
                        == fixture.candidate.commonDirectoryIdentity,
                "equivalent path spelling changed bound repository identity"
            )
            let finalAlias = URL(fileURLWithPath: fixture.rootPath)
                .appendingPathComponent("repository-final-alias").path
            guard symlink(fixture.repositoryPath, finalAlias) == 0 else {
                throw M1SelfTestError.systemCall("create final repository alias", errno)
            }
            try check(
                throwsError { try RepositoryHandle.fixedCandidate(path: finalAlias) },
                "unsafe final repository symlink was admitted"
            )
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let captured = fixture.candidate
            let capturedHandle = try RepositoryHandle.open(captured)
            let moved = URL(fileURLWithPath: fixture.rootPath)
                .appendingPathComponent("repository-original").path
            try FileManager.default.moveItem(atPath: fixture.repositoryPath, toPath: moved)
            try FileManager.default.createDirectory(
                atPath: fixture.repositoryPath,
                withIntermediateDirectories: false
            )
            try check(
                !RepositoryRootPathIdentity.matches(
                    path: fixture.repositoryPath,
                    expected: capturedHandle.identity.root
                ),
                "replacement inode matched the captured repository root identity"
            )
            try check(
                throwsError { try RepositoryHandle.open(captured) },
                "same canonical path with a different inode was admitted"
            )
        }

        try check(
            throwsError {
                try RawGitConfig.parse(
                    Data(
                        """
                        [extensions]
                            worktreeConfig = true
                        [remote "origin"]
                            url = git@github.com:fixture-owner/fixture-repo.git
                        """.utf8
                    )
                )
            },
            "extensions.worktreeConfig was accepted"
        )
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try Data("[core]\n".utf8).write(
                to: URL(fileURLWithPath: fixture.repositoryPath)
                    .appendingPathComponent(".git/config.worktree")
            )
            try check(
                throwsError { try RepositoryHandle.open(fixture.candidate) },
                ".git/config.worktree was accepted"
            )
        }
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let handle = try RepositoryHandle.open(fixture.candidate)
            let configURL = URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent(".git/config")
            let handleForWrite = try FileHandle(forWritingTo: configURL)
            try handleForWrite.seekToEnd()
            try handleForWrite.write(contentsOf: Data("\n# changed after admission\n".utf8))
            try handleForWrite.close()
            try check(throwsError { try handle.revalidate() }, "metadata change was not detected")
        }

        for relativePath in ["refs/replace", "info/grafts", "objects/info/alternates"] {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let handle = try RepositoryHandle.open(fixture.candidate)
            let target = URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent(".git")
                .appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if relativePath == "refs/replace" {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: false
                )
            } else {
                try Data("fixture\n".utf8).write(to: target)
            }
            try check(
                throwsError { try handle.rejectReplacementAndGraftState() },
                "\(relativePath) was not refused"
            )
        }
    }

    private static func testTrampolineRootIdentity(executable: String) throws {
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let aliasParent = URL(fileURLWithPath: fixture.rootPath)
                .appendingPathComponent("trampoline-parent-alias").path
            guard symlink(fixture.rootPath, aliasParent) == 0 else {
                throw M1SelfTestError.systemCall("create trampoline parent alias", errno)
            }
            let aliasedPath = URL(fileURLWithPath: aliasParent)
                .appendingPathComponent("repository").path
            let aliasedCandidate = try RepositoryHandle.fixedCandidate(path: aliasedPath)
            let handle = try RepositoryHandle.open(aliasedCandidate)
            let frozen = try handle.freezeConfiguration(
                account: fixture.account,
                additionalConfiguration: fixture.mapping.gitConfigText
            )
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            defer { authority.release() }
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            let result = try DescriptorProcessRunner().run(
                ProcessRequest(
                    executable: DescriptorProcessRunner.gitPath,
                    arguments: [
                        "-c", GitCommandPolicy.testRootMarker,
                        "--no-replace-objects", "--no-lazy-fetch",
                        "status", "--porcelain=v1", "-z", "--untracked-files=all",
                    ],
                    environment: fixture.closedEnvironment(
                        frozenConfigPath: frozen.snapshot.frozenPath
                    ),
                    workingDirectoryDescriptor: handle.worktreeDescriptor,
                    inheritedLeaseDescriptor: lease,
                    frozenConfigDescriptor: frozen.descriptor,
                    frozenConfigDirectoryDescriptor: frozen.directoryDescriptor,
                    timeoutSeconds: 5,
                    trampolineExecutable: executable,
                    executionSnapshot: try handle.executionSnapshot(
                        account: fixture.account,
                        frozenConfiguration: frozen,
                        admission: nil
                    )
                ),
                cancellation: CancellationToken()
            )
            try check(
                result.exitedSuccessfully,
                "descriptor-equivalent root alias was refused by the Git trampoline"
            )
        }

        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let currentDescriptor = Darwin.open(
                fixture.repositoryPath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard currentDescriptor >= 0 else {
                throw M1SelfTestError.systemCall("open original trampoline root", errno)
            }
            defer { close(currentDescriptor) }
            var currentStat = stat()
            guard fstat(currentDescriptor, &currentStat) == 0 else {
                throw M1SelfTestError.systemCall("stat original trampoline root", errno)
            }
            let movedPath = URL(fileURLWithPath: fixture.rootPath)
                .appendingPathComponent("trampoline-original").path
            try FileManager.default.moveItem(
                atPath: fixture.repositoryPath,
                toPath: movedPath
            )
            try FileManager.default.createDirectory(
                atPath: fixture.repositoryPath,
                withIntermediateDirectories: false
            )
            let replacementDescriptor = Darwin.open(
                fixture.repositoryPath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard replacementDescriptor >= 0 else {
                throw M1SelfTestError.systemCall("open replacement trampoline root", errno)
            }
            defer { close(replacementDescriptor) }
            try check(
                throwsError {
                    try GitChildRootIdentity.validate(
                        expectedDescriptor: replacementDescriptor,
                        currentDescriptor: currentDescriptor,
                        snapshotRoot: FileIdentity(currentStat)
                    )
                },
                "trampoline admitted a replacement inode at the canonical root path"
            )
        }
    }

    private static func testCombinedHiddenIndexFlagsPreflight(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        try fixture.git(["push", fixture.remotePath, "main:main"])

        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }

        func resetFlags() throws {
            try fixture.git(["update-index", "--no-assume-unchanged", "value.txt"])
            try fixture.git(["update-index", "--no-skip-worktree", "value.txt"])
        }
        func execute(audit: CommandAudit) -> RepositoryResult {
            GitTransaction(
                runner: DescriptorProcessRunner(audit: audit),
                configuration: GitTransactionConfiguration(
                    trampolineExecutable: executable,
                    operationLeaseDescriptor: lease,
                    transportMapping: fixture.mapping
                ),
                account: fixture.account
            ).execute(
                candidate: fixture.candidate,
                cancellation: CancellationToken(),
                phase: { _ in }
            )
        }

        try resetFlags()
        let ordinaryListing = try fixture.gitOutput(["ls-files", "-v", "-z", "--", "value.txt"])
        try check(
            ordinaryListing == Data("H value.txt\u{0}".utf8),
            "ordinary Git-generated index marker was not H-space"
        )
        try GitIndexVisibility.validate(ordinaryListing)
        let ordinaryAudit = CommandAudit()
        let ordinaryResult = execute(audit: ordinaryAudit)
        try check(
            ordinaryResult.code == .alreadyCurrent && ordinaryResult.fetched,
            "ordinary index state was not admitted through fetch: \(ordinaryResult.code.rawValue) \(ordinaryResult.technicalDetail ?? "")"
        )
        try check(
            ordinaryAudit.invocations.contains { $0.arguments.contains("fetch") },
            "ordinary index state did not reach the fetch boundary"
        )

        let cases: [(String, [String], UInt8)] = [
            ("assume-unchanged", ["--assume-unchanged"], 0x68),
            ("skip-worktree", ["--skip-worktree"], 0x53),
            (
                "combined",
                ["--assume-unchanged", "--skip-worktree"],
                0x73
            ),
        ]
        for (name, flags, marker) in cases {
            try resetFlags()
            for flag in flags {
                try fixture.git(["update-index", flag, "value.txt"])
            }
            let listing = try fixture.gitOutput(["ls-files", "-v", "-z", "--", "value.txt"])
            try check(listing.first == marker, "\(name) Git-generated marker was unexpected")
            try check(
                throwsError { try GitIndexVisibility.validate(listing) },
                "\(name) Git-generated marker was accepted"
            )

            let fetchHead = URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent(".git/FETCH_HEAD")
            try? FileManager.default.removeItem(at: fetchHead)
            let audit = CommandAudit()
            let result = execute(audit: audit)
            try check(
                result.code == .skippedHiddenIndexState,
                "\(name) was not classified as hidden index state"
            )
            try check(!result.fetched, "\(name) reached fetch")
            try check(!result.mainUpdated, "\(name) changed local main")
            try check(result.beforeCommit == nil, "\(name) passed the preflight boundary")
            try check(
                !audit.invocations.contains {
                    $0.arguments.contains("fetch") || $0.arguments.contains("merge")
                },
                "\(name) admitted a network or update command"
            )
            try check(
                !FileManager.default.fileExists(atPath: fetchHead.path),
                "\(name) created FETCH_HEAD"
            )
        }

        for marker in ["K", "M", "?"] {
            try check(
                throwsError {
                    try GitIndexVisibility.validate(Data("\(marker) unsafe.txt\u{0}".utf8))
                },
                "unexpected index marker \(marker) was accepted"
            )
        }
        try check(
            ordinaryResult.beforeCommit != nil,
            "ordinary index state did not complete preflight"
        )
        try check(
            !ordinaryResult.mainUpdated,
            "ordinary equal repository unexpectedly changed local main"
        )
        try check(
            ordinaryResult.afterCommit == ordinaryResult.beforeCommit,
            "ordinary equal repository did not preserve local main"
        )
        try check(
            ordinaryAudit.invocations.allSatisfy {
                !$0.arguments.contains("merge")
            },
            "ordinary equal repository reached update"
        )
    }

    private static func testM2EffectiveCustomTransport(executable: String) throws {
        let configurations = [
            """
            [core]
                sshCommand = /usr/bin/false
            """,
            """
            [remote "origin"]
                uploadpack = /usr/bin/false
            """,
        ]
        for configuration in configurations {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try Data(configuration.utf8).write(
                to: URL(fileURLWithPath: fixture.account.homeDirectory)
                    .appendingPathComponent(".gitconfig")
            )
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            defer { authority.release() }
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            let audit = CommandAudit()
            let result = GitTransaction(
                runner: DescriptorProcessRunner(audit: audit),
                configuration: GitTransactionConfiguration(
                    trampolineExecutable: executable,
                    operationLeaseDescriptor: lease,
                    transportMapping: fixture.mapping
                ),
                account: fixture.account
            ).execute(
                candidate: fixture.candidate,
                cancellation: CancellationToken(),
                phase: { _ in }
            )
            try check(
                result.code == .failedInspection,
                "effective custom transport was not refused"
            )
            try check(
                !audit.invocations.contains(where: { $0.arguments.contains("fetch") }),
                "effective custom transport reached fetch"
            )
        }
    }

    private static func testOneRunOwnerAndLogPreservation(executable: String) throws {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let state = try SecureStateDirectory.open(location)
        let logURL = URL(fileURLWithPath: state.path).appendingPathComponent("latest.log")
        let prior = Data("previous run remains intact\n".utf8)
        try prior.write(to: logURL)
        guard chmod(logURL.path, 0o600) == 0 else {
            throw M1SelfTestError.systemCall("chmod latest.log", errno)
        }

        let holder = try M1LockHolder(executable: executable, root: temporary.path)
        defer { holder.stop() }
        try check(
            throwsError { try RunAuthority.acquireRun(at: location) },
            "second run acquired authority"
        )
        try check(try Data(contentsOf: logURL) == prior, "contender changed the prior log")

        try holder.finish()
        let next = try RunAuthority.acquireRun(at: location)
        next.release()
    }

    private static func testInheritedOperationLease() throws {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try RunAuthority.acquireRun(at: location)
        let child: M1FixtureChild = try {
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            return try M1FixtureChild(.lease(lease))
        }()
        defer { child.stop() }
        try child.resume()
        authority.release()

        try check(
            throwsError { try RunAuthority.acquireRun(at: location) },
            "surviving lease allowed another run"
        )
        try check(
            throwsError { try RunAuthority.acquireLifecycleMutation(at: location) },
            "surviving lease allowed lifecycle mutation"
        )

        try check(try child.waitForExit(timeout: 5) == 0, "lease holder failed")
        let lifecycle = try RunAuthority.acquireLifecycleMutation(at: location)
        lifecycle.release()
    }

    private static func testFrozenConfigRecoveryAndLiveRefusal(
        executable: String
    ) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let handle = try RepositoryHandle.open(fixture.candidate)
        var recoveryPass: FrozenGitConfiguration? = try handle.freezeConfiguration(
            account: fixture.account
        )
        recoveryPass = nil
        _ = recoveryPass
        let initial = try snapshotDirectoryNames()
        var first: FrozenGitConfiguration? = try handle.freezeConfiguration(
            account: fixture.account
        )
        var second: FrozenGitConfiguration? = try handle.freezeConfiguration(
            account: fixture.account
        )
        let live = try snapshotDirectoryNames().subtracting(initial)
        try check(live.count == 2, "live frozen config snapshot was recovered")
        second = nil
        first = nil
        _ = second
        _ = first
        try check(
            try snapshotDirectoryNames() == initial,
            "normal frozen config cleanup left residue"
        )

        let child = try M1FixtureChild(.orphanSnapshot(executable, fixture.repositoryPath, fixture.account.homeDirectory))
        defer { child.stop() }
        try child.resume()
        try check(try child.waitForExit(timeout: 10) == 0, "orphan snapshot child failed")
        try check(
            try snapshotDirectoryNames().subtracting(initial).count == 1,
            "orphan snapshot was not retained for recovery"
        )
        var recovered: FrozenGitConfiguration? = try handle.freezeConfiguration(
            account: fixture.account
        )
        try check(
            try snapshotDirectoryNames().subtracting(initial).count == 1,
            "stale snapshot recovery did not preserve only the new live snapshot"
        )
        recovered = nil
        _ = recovered
        try check(
            try snapshotDirectoryNames() == initial,
            "stale snapshot recovery left residue"
        )
    }

    private static func testGitDescendantLeaseIsolation(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let sentinel = URL(fileURLWithPath: fixture.rootPath)
            .appendingPathComponent("lease-fd-result").path
        let monitor = URL(fileURLWithPath: fixture.rootPath)
            .appendingPathComponent("hostile-fsmonitor.sh").path
        guard let interpreter = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_PYTHON"],
              interpreter.hasPrefix("/"), !interpreter.contains("\n"), !interpreter.contains("\0") else {
            throw M1SelfTestError.message("qualified fixture interpreter is required")
        }
        let quotedInterpreter = "'" + interpreter.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        \(quotedInterpreter) -I -S -B -c 'import fcntl,sys
        leaked=[]
        for fd in (195,196,198):
            try:
                fcntl.fcntl(fd, fcntl.F_GETFD)
                leaked.append(fd)
            except OSError:
                pass
        try:
            fcntl.flock(198, fcntl.LOCK_UN)
            unlocked=True
        except OSError:
            unlocked=False
        value="closed" if not leaked and not unlocked else "inherited"
        open(sys.argv[1], "w").write(value)' '\(sentinel)'
        /bin/sleep 2
        exit 0
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: monitor))
        guard chmod(monitor, 0o700) == 0 else {
            throw M1SelfTestError.systemCall("chmod hostile fsmonitor", errno)
        }
        try fixture.git(["config", "core.fsmonitor", monitor])
        let candidate = try RepositoryHandle.fixedCandidate(
            path: fixture.repositoryPath
        )
        let handle = try RepositoryHandle.open(candidate)
        let frozen = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        var leaseOpen = true
        defer { if leaseOpen { close(lease) } }
        let request = ProcessRequest(
            executable: DescriptorProcessRunner.gitPath,
            arguments: [
                "-c", GitCommandPolicy.fdAuditMarker,
                "--no-replace-objects", "--no-lazy-fetch",
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
            ],
            environment: fixture.closedEnvironment(
                frozenConfigPath: frozen.snapshot.frozenPath
            ),
            workingDirectoryDescriptor: handle.worktreeDescriptor,
            inheritedLeaseDescriptor: lease,
            frozenConfigDescriptor: frozen.descriptor,
            frozenConfigDirectoryDescriptor: frozen.directoryDescriptor,
            timeoutSeconds: 10,
            trampolineExecutable: executable,
            executionSnapshot: try handle.executionSnapshot(
                account: fixture.account,
                frozenConfiguration: frozen,
                admission: nil
            )
        )
        authority.release()
        let completed = DispatchGroup()
        let cancellation = CancellationToken()
        let resultBox = ProcessResultBox()
        completed.enter()
        defer {
            cancellation.cancel()
            while completed.wait(timeout: .now() + 6) != .success {
                fputs("M1 FIXTURE RUNNER CLEANUP PENDING\n", stderr); fflush(stderr)
            }
        }
        DispatchQueue.global().async {
            defer { completed.leave() }
            do {
                resultBox.store(
                    try DescriptorProcessRunner().run(
                        request,
                        cancellation: cancellation
                    )
                )
            } catch {
                resultBox.store(error)
            }
        }
        let deadline = MonotonicDeadline(seconds: 5)
        while !deadline.hasExpired,
              !FileManager.default.fileExists(atPath: sentinel) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try check(
            try String(contentsOfFile: sentinel, encoding: .utf8) == "closed",
            "Git hook inherited or unlocked operation lease FD 198"
        )
        try check(
            throwsError { try RunAuthority.acquireRun(at: fixture.stateLocation) },
            "contender acquired operation lease while supervisor was active"
        )
        guard completed.wait(timeout: .now() + 10) == .success else {
            throw M1SelfTestError.message("hostile fsmonitor Git command did not finish")
        }
        close(lease); leaseOpen = false
        let result = try resultBox.get()
        try check(result.exitedSuccessfully, "controlled fsmonitor Git command failed")
        let next = try RunAuthority.acquireRun(at: fixture.stateLocation)
        next.release()
    }

    private static func snapshotDirectoryNames() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: "/private/tmp"
        )
        let prefix = URL(fileURLWithPath: try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.")).lastPathComponent
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    private static func testHardlinkFramingAndPartialTail() throws {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let location = try StateLocation.isolated(root: temporary.path)
        try TestIsolation.initializeState(at: location)
        let authority = try RunAuthority.acquireRun(at: location)
        defer { authority.release() }

        let logURL = URL(fileURLWithPath: authority.stateDirectory.path)
            .appendingPathComponent("latest.log")
        let aliasURL = URL(fileURLWithPath: temporary.path).appendingPathComponent("log-alias")
        let original = Data("do not truncate\n".utf8)
        try original.write(to: logURL)
        guard chmod(logURL.path, 0o600) == 0,
              link(logURL.path, aliasURL.path) == 0 else {
            throw M1SelfTestError.systemCall("prepare hardlinked log", errno)
        }
        try check(
            throwsError { try RunLogWriter(authority: authority, runID: "hardlink") },
            "hardlinked log was accepted"
        )
        try check(try Data(contentsOf: logURL) == original, "hardlinked log was truncated")
        guard unlink(aliasURL.path) == 0 else {
            throw M1SelfTestError.systemCall("unlink log alias", errno)
        }

        let writer = try RunLogWriter(
            authority: authority,
            runID: "11111111-1111-4111-8111-111111111111"
        )
        let attemptedForgery =
            "child line\n{\"schema\":\"shadow-sync-log/v1\",\"type\":\"forged\"}\nAuthorization: Bearer fixture-secret"
        try writer.append(type: "subprocess", data: attemptedForgery)
        try writer.flush()

        let appendDescriptor = Darwin.open(
            logURL.path,
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        )
        guard appendDescriptor >= 0 else {
            throw M1SelfTestError.systemCall("open partial log tail", errno)
        }
        defer { close(appendDescriptor) }
        try writeAll(
            Data("{\"schema\":\"shadow-sync-log/v1\"".utf8),
            descriptor: appendDescriptor
        )

        let records = try RunLogReader.records(state: authority.stateDirectory)
        try check(records.count == 1, "forged or partial bytes became records")
        try check(records.first?.type == "subprocess", "valid framed record was lost")
        try check(
            records.first?.data?.contains("\n{\"schema\"") == true,
            "subprocess newline data was not preserved inside its field"
        )
        try check(
            records.first?.data?.contains("fixture-secret") == false,
            "subprocess credential entered the log"
        )
        var info = stat()
        try check(lstat(logURL.path, &info) == 0, "latest log disappeared")
        try check(info.st_nlink == 1, "latest log link count changed")
        try check((info.st_mode & 0o777) == 0o600, "latest log mode is not 0600")
    }

    private static func testChildMetadataMismatch(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let handle = try RepositoryHandle.open(fixture.candidate)
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let frozenConfiguration = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        let snapshot = try handle.executionSnapshot(
            account: fixture.account,
            frozenConfiguration: frozenConfiguration,
            admission: nil
        )

        let configPath = URL(fileURLWithPath: fixture.repositoryPath)
            .appendingPathComponent(".git/config").path
        let runner = DescriptorProcessRunner(beforeGatePublication: {
            if let config = try? FileHandle(forWritingTo: URL(fileURLWithPath: configPath)) {
                _ = try? config.seekToEnd()
                try? config.write(contentsOf: Data("\n# changed before child execution\n".utf8))
                try? config.close()
            }
        })

        let result = try runner.run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: [
                    "-c", GitCommandPolicy.testRootMarker,
                    "--no-replace-objects",
                    "--no-lazy-fetch",
                    "rev-parse",
                    "--verify",
                    "HEAD^{commit}",
                ],
                environment: fixture.closedEnvironment(
                    frozenConfigPath: frozenConfiguration.snapshot.frozenPath
                ),
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: lease,
                frozenConfigDescriptor: frozenConfiguration.descriptor,
                frozenConfigDirectoryDescriptor:
                    frozenConfiguration.directoryDescriptor,
                timeoutSeconds: 5,
                trampolineExecutable: executable,
                executionSnapshot: snapshot
            ),
            cancellation: CancellationToken()
        )
        try check(result.status == 125, "metadata-mismatched child was not refused")
        try check(
            String(decoding: result.output, as: UTF8.self)
                .contains("refused changed repository metadata"),
            "metadata refusal was not reported"
        )
        try check(processGroupIsGone(result.processID), "refused child process group survived")
    }

    private static func testChildStartAdmissionRace(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let handle = try RepositoryHandle.open(fixture.candidate)
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let token = CancellationToken()
        let frozenConfiguration = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        let spawn = M1SpawnAnchorBox()
        let runner = DescriptorProcessRunner(testingSpawnObserver: { spawn.store($0) },
            beforeGatePublication: { _ in token.cancel() })
        let result = try runner.run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: [
                    "-c", GitCommandPolicy.fdAuditMarker,
                    "--no-replace-objects", "--no-lazy-fetch",
                    "rev-parse", "--verify", "HEAD^{commit}",
                ],
                environment: fixture.closedEnvironment(
                    frozenConfigPath: frozenConfiguration.snapshot.frozenPath
                ),
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: lease,
                frozenConfigDescriptor: frozenConfiguration.descriptor,
                frozenConfigDirectoryDescriptor: frozenConfiguration.directoryDescriptor,
                timeoutSeconds: 5,
                trampolineExecutable: executable,
                executionSnapshot: try handle.executionSnapshot(
                    account: fixture.account,
                    frozenConfiguration: frozenConfiguration,
                    admission: nil
                )
            ),
            cancellation: token
        )
        try check(result.cancelled, "spawn-racing cancellation was not retained")
        try check(result.status != 0, "cancelled child start gate released Git")
        try check(result.status == 128 + SIGKILL && result.stdout.isEmpty && result.stderr.isEmpty,
            "cancelled suspended child executed before admission")
        try check(spawn.value?.unexecutedProof() != nil,
            "cancelled spawn lacks original never-resumed retirement proof")
        try check(processGroupIsGone(result.processID), "cancelled start process group survived")
    }

    private static func testChildIdentityCaptureFailure(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let handle = try RepositoryHandle.open(fixture.candidate)
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let frozenConfiguration = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        let unrelated = try M1FixtureChild(.unrelated)
        defer { unrelated.stop() }
        try unrelated.resume()
        let spawn = M1SpawnAnchorBox()
        let runner = DescriptorProcessRunner(testingSpawnObserver: { spawn.store($0) },
            testingIdentityCapture: { _, _, _ in nil })
        let result = try runner.run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: [
                    "-c", GitCommandPolicy.fdAuditMarker,
                    "--no-replace-objects", "--no-lazy-fetch",
                    "rev-parse", "--verify", "HEAD^{commit}",
                ],
                environment: fixture.closedEnvironment(
                    frozenConfigPath: frozenConfiguration.snapshot.frozenPath
                ),
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: lease,
                frozenConfigDescriptor: frozenConfiguration.descriptor,
                frozenConfigDirectoryDescriptor: frozenConfiguration.directoryDescriptor,
                timeoutSeconds: 1,
                trampolineExecutable: executable,
                executionSnapshot: try handle.executionSnapshot(
                    account: fixture.account,
                    frozenConfiguration: frozenConfiguration,
                    admission: nil
                )
            ),
            cancellation: CancellationToken()
        )
        try check(result.cancelled && result.status == 128 + SIGKILL
            && result.stdout.isEmpty && result.stderr.isEmpty,
            "identity-failed suspended child executed before admission")
        try check(spawn.value?.unexecutedProof() != nil,
            "identity-failed spawn lacks original never-resumed retirement proof")
        try check(
            processGroupIsGone(result.processID),
            "identity-failed child process group survived"
        )
        try check(unrelated.owner.identity.isCurrent(expectedGeneration: unrelated.owner.identity.generation)
            && unrelated.owner.terminalStatusHeld == nil,
            "identity failure signalled an unrelated process")
    }

    private static func testChildSpawnDescriptorCollision(
        executable: String
    ) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let handle = try RepositoryHandle.open(fixture.candidate)
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let frozenConfiguration = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        var fillerDescriptors: [Int32] = []
        defer { closeDescriptors(fillerDescriptors) }
        while true {
            let descriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw M1SelfTestError.systemCall(
                    "open descriptor-collision filler",
                    errno
                )
            }
            if descriptor > 192 {
                close(descriptor)
                break
            }
            fillerDescriptors.append(descriptor)
        }
        errno = 0
        try check(
            fcntl(193, F_GETFD) == -1 && errno == EBADF,
            "descriptor-collision fixture could not reserve FD 193"
        )
        let result = try DescriptorProcessRunner().run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: [
                    "-c", GitCommandPolicy.fdAuditMarker,
                    "--no-replace-objects", "--no-lazy-fetch",
                    "rev-parse", "--verify", "HEAD^{commit}",
                ],
                environment: fixture.closedEnvironment(
                    frozenConfigPath: frozenConfiguration.snapshot.frozenPath
                ),
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: lease,
                frozenConfigDescriptor: frozenConfiguration.descriptor,
                frozenConfigDirectoryDescriptor: frozenConfiguration.directoryDescriptor,
                timeoutSeconds: 5,
                trampolineExecutable: executable,
                executionSnapshot: try handle.executionSnapshot(
                    account: fixture.account,
                    frozenConfiguration: frozenConfiguration,
                    admission: nil
                )
            ),
            cancellation: CancellationToken()
        )
        try check(
            result.exitedSuccessfully,
            "reserved child descriptors collided with spawn inputs"
        )
    }

    private static func testChildGraphAndConfigRaces(executable: String) throws {
        enum Mutation: Equatable, Sendable {
            case repositoryConfig
            case worktreeConfig
            case replacement
            case packedReplacement
            case alternate
            case globalTransport
        }
        for mutation in [
            Mutation.repositoryConfig,
            .worktreeConfig,
            .replacement,
            .packedReplacement,
            .alternate,
            .globalTransport,
        ] {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            if mutation == .globalTransport {
                try Data(
                    """
                    [url "https://github.com/fixture-owner/fixture-repo.git"]
                        insteadOf = git@github.com:fixture-owner/fixture-repo.git
                    """.utf8
                ).write(to: URL(fileURLWithPath: fixture.account.homeDirectory)
                    .appendingPathComponent(".gitconfig"))
            }
            let handle = try RepositoryHandle.open(fixture.candidate)
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            let lease = try authority.duplicateOperationLease()
            let frozenConfiguration = try handle.freezeConfiguration(
                account: fixture.account,
                additionalConfiguration: fixture.mapping.gitConfigText
            )
            let snapshot = try handle.executionSnapshot(
                account: fixture.account,
                frozenConfiguration: frozenConfiguration,
                admission: nil
            )
            let repositoryPath = fixture.repositoryPath
            let remotePath = fixture.remotePath
            let accountHome = fixture.account.homeDirectory
            let runner = DescriptorProcessRunner(beforeGatePublication: {
                let git = URL(fileURLWithPath: repositoryPath)
                    .appendingPathComponent(".git")
                switch mutation {
                case .repositoryConfig:
                    let config = git.appendingPathComponent("config")
                    if let file = try? FileHandle(forWritingTo: config) {
                        _ = try? file.seekToEnd()
                        try? file.write(contentsOf: Data("\n# gate race\n".utf8))
                        try? file.close()
                    }
                case .worktreeConfig:
                    try? Data("[core]\n".utf8).write(
                        to: git.appendingPathComponent("config.worktree")
                    )
                case .replacement:
                    try? FileManager.default.createDirectory(
                        at: git.appendingPathComponent("refs/replace"),
                        withIntermediateDirectories: true
                    )
                case .packedReplacement:
                    try? Data(
                        "\(String(repeating: "a", count: 40)) refs/replace/race\n".utf8
                    ).write(to: git.appendingPathComponent("packed-refs"))
                case .alternate:
                    try? Data("\(remotePath)/objects\n".utf8).write(
                        to: git.appendingPathComponent("objects/info/alternates")
                    )
                case .globalTransport:
                    try? Data(
                        """
                        [url "ssh://git@github.com/fixture-owner/fixture-repo.git"]
                            insteadOf = git@github.com:fixture-owner/fixture-repo.git
                        """.utf8
                    ).write(to: URL(fileURLWithPath: accountHome)
                        .appendingPathComponent(".gitconfig"))
                }
            })
            let result = try runner.run(
                ProcessRequest(
                    executable: DescriptorProcessRunner.gitPath,
                    arguments: [
                        "-c", GitCommandPolicy.testRootMarker,
                        "--no-replace-objects", "--no-lazy-fetch",
                        "rev-parse", "--verify", "HEAD^{commit}",
                    ],
                    environment: fixture.closedEnvironment(
                        frozenConfigPath: frozenConfiguration.snapshot.frozenPath
                    ),
                    workingDirectoryDescriptor: handle.worktreeDescriptor,
                    inheritedLeaseDescriptor: lease,
                    frozenConfigDescriptor: frozenConfiguration.descriptor,
                    frozenConfigDirectoryDescriptor: frozenConfiguration.directoryDescriptor,
                    timeoutSeconds: 5,
                    trampolineExecutable: executable,
                    executionSnapshot: snapshot
                ),
                cancellation: CancellationToken()
            )
            close(lease)
            authority.release()
            try check(result.status == 125, "child accepted \(mutation) gate mutation")
            try check(processGroupIsGone(result.processID), "mutation-refused child survived")
        }
    }

    private static func testLogFailureCancelsAdmission(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let audit = CommandAudit()
        let token = CancellationToken()
        let coordinator = RunCoordinator(
            configuration: CoordinatorConfiguration(
                stateLocation: fixture.stateLocation,
                trampolineExecutable: executable,
                transportMapping: fixture.mapping,
                failAfterLoggedRecords: 1
            ),
            audit: audit,
            account: fixture.account
        )
        try check(
            throwsError {
                try coordinator.run(
                    runID: RunIdentity.make(),
                    candidate: fixture.candidate,
                    cancellation: token,
                    eventSink: { _ in }
                )
            },
            "injected log failure did not fail the run"
        )
        try check(token.isCancelled, "log failure did not close admission")
        try check(audit.invocations.isEmpty, "Git ran after the phase log failed")
    }

    private static func testFetchPorcelainFreezesTarget(executable: String) throws {
        let target = String(repeating: "b", count: 40)
        let laterMutableRef = String(repeating: "c", count: 40)
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let transaction = GitTransaction(
            runner: DescriptorProcessRunner(),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: nil,
                operationLeaseDescriptor: nil
            ),
            account: fixture.account
        )
        let captured = try transaction.capturedFetchTarget(
            stdout: Data(
                "* \(String(repeating: "0", count: 40)) \(target) refs/remotes/origin/main\n"
                    .utf8
            ),
            truncated: false
        )
        try check(captured == target, "fetch porcelain target was not captured")
        try check(captured != laterMutableRef, "later mutable ref replaced the captured target")
        let fastForward = try transaction.capturedFetchTarget(
            stdout: Data(
                "  \(String(repeating: "a", count: 40)) \(target) refs/remotes/origin/main\n"
                    .utf8
            ),
            truncated: false
        )
        try check(fastForward == target, "fast-forward porcelain target was not captured")
        try check(
            fetchTargetFailureCode(
                transaction,
                output: Data(
                    "= \(String(repeating: "a", count: 40)) \(target) refs/remotes/origin/other\n"
                        .utf8
                )
            ) == .failedInspection,
            "zero matching fetch targets were not classified as failed inspection"
        )
        try check(
            fetchTargetFailureCode(
                transaction,
                output: Data(
                    """
                    * \(String(repeating: "0", count: 40)) \(target) refs/remotes/origin/main
                    = \(target) \(target) refs/remotes/origin/main

                    """.utf8
                )
            ) == .failedInspection,
            "duplicate matching fetch targets were not classified as failed inspection"
        )
        try check(
            fetchTargetFailureCode(
                transaction,
                output: Data("* old not-an-oid refs/remotes/origin/main\n".utf8)
            ) == .failedInspection,
            "malformed matching fetch target was not classified as failed inspection"
        )

        try fixture.git(["push", fixture.remotePath, "main:main"])
        let before = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("target\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("target.txt")
        )
        try fixture.git(["add", "target.txt"])
        try fixture.git(["commit", "--quiet", "-m", "target"])
        let targetOID = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["push", fixture.remotePath, "main:main"])
        try fixture.git(["reset", "--hard", before])
        let remoteTrackingPath = URL(fileURLWithPath: fixture.repositoryPath)
            .appendingPathComponent(".git/refs/remotes/origin/main").path
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let moved = M1AtomicFlag()
        let transactionWithRace = GitTransaction(
            runner: DescriptorProcessRunner(),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: executable,
                operationLeaseDescriptor: lease,
                transportMapping: fixture.mapping,
                afterFetchCapture: { captured, _ in
                    guard captured == targetOID else {
                        return
                    }
                    try? Data("\(before)\n".utf8).write(
                        to: URL(fileURLWithPath: remoteTrackingPath),
                        options: .atomic
                    )
                    moved.set()
                }
            ),
            account: fixture.account
        )
        let result = transactionWithRace.execute(
            candidate: fixture.candidate,
            cancellation: CancellationToken(),
            phase: { _ in }
        )
        try check(
            moved.value,
            "moving-ref regression did not mutate origin/main: \(result.code.rawValue), \(result.technicalDetail ?? "none")"
        )
        try check(result.code == .updated, "captured target was not used after ref mutation")
        try check(result.targetCommit == targetOID, "fetch porcelain target was replaced")
        try check(result.afterCommit == targetOID, "merge did not use the frozen fetched OID")
    }

    private static func testSnapshotArgvPrivacyAndSize(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let secret = "github_pat_snapshot_secret_1234567890"
        let largeComments = String(repeating: "# bounded configuration padding\n", count: 6_000)
        try Data(
            """
            [credential]
                helper = "!printf \(secret)"
            \(largeComments)
            """.utf8
        ).write(
            to: URL(fileURLWithPath: fixture.account.homeDirectory)
                .appendingPathComponent(".gitconfig")
        )
        let handle = try RepositoryHandle.open(fixture.candidate)
        let frozen = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let audit = CommandAudit()
        let result = try DescriptorProcessRunner(audit: audit).run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: [
                    "-c", GitCommandPolicy.testRootMarker,
                    "--no-replace-objects", "--no-lazy-fetch",
                    "status", "--porcelain=v1", "-z", "--untracked-files=all",
                ],
                environment: fixture.closedEnvironment(
                    frozenConfigPath: frozen.snapshot.frozenPath
                ),
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: lease,
                frozenConfigDescriptor: frozen.descriptor,
                frozenConfigDirectoryDescriptor: frozen.directoryDescriptor,
                timeoutSeconds: 5,
                trampolineExecutable: executable,
                executionSnapshot: try handle.executionSnapshot(
                    account: fixture.account,
                    frozenConfiguration: frozen,
                    admission: nil
                )
            ),
            cancellation: CancellationToken()
        )
        try check(result.exitedSuccessfully, "large frozen configuration did not spawn")
        let auditedArgv = audit.invocations.flatMap(\.spawnArguments).joined(separator: "\n")
        try check(!auditedArgv.contains(secret), "raw config secret entered spawned argv")
        try check(
            !auditedArgv.contains(Data(secret.utf8).base64EncodedString()),
            "base64 config secret entered spawned argv"
        )
        try check(auditedArgv.utf8.count < 64_000, "bounded metadata approached ARG_MAX")
    }

    private static func testMachineOutputIntegrity() throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let transaction = GitTransaction(
            runner: DescriptorProcessRunner(),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: nil,
                operationLeaseDescriptor: nil
            ),
            account: fixture.account
        )
        let target = String(repeating: "d", count: 40)
        let valid = Data("* \(String(repeating: "0", count: 40)) \(target) refs/remotes/origin/main\n".utf8)
        try check(
            try transaction.capturedFetchTarget(stdout: valid, truncated: false) == target,
            "complete stdout target was not parsed"
        )
        try check(
            fetchTargetFailureCode(
                transaction,
                output: Data("forged diagnostic \(target) refs/remotes/origin/main\n".utf8)
            ) == .failedInspection,
            "unknown stdout record was accepted"
        )
        try check(
            throwsError {
                try transaction.capturedFetchTarget(stdout: valid, truncated: true)
            },
            "truncated stdout was accepted"
        )
        try check(
            throwsError {
                try transaction.capturedFetchTarget(stdout: Data(), truncated: false)
            },
            "stderr-only target could satisfy stdout parser"
        )
    }

    private static func testFinalPreSpawnMutations(executable: String) throws {
        for mutation in [
            GitCommandPolicy.finalConfigMutationMarker,
            GitCommandPolicy.finalGraphMutationMarker,
            GitCommandPolicy.finalFrozenSwapMarker,
        ] {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let before = String(
                decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try Data("next\n".utf8).write(
                to: URL(fileURLWithPath: fixture.repositoryPath)
                    .appendingPathComponent("next.txt")
            )
            try fixture.git(["add", "next.txt"])
            try fixture.git(["commit", "--quiet", "-m", "next"])
            let target = String(
                decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try fixture.git(["push", fixture.remotePath, "main:main"])
            try fixture.git(["reset", "--hard", before])
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            defer { authority.release() }
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            let result = GitTransaction(
                runner: DescriptorProcessRunner(),
                configuration: GitTransactionConfiguration(
                    trampolineExecutable: executable,
                    operationLeaseDescriptor: lease,
                    transportMapping: fixture.mapping,
                    finalMutationOnFetch: mutation
                ),
                account: fixture.account
            ).execute(
                candidate: fixture.candidate,
                cancellation: CancellationToken(),
                phase: { _ in }
            )
            try check(!result.mainUpdated, "\(mutation) changed local main")
            if mutation == GitCommandPolicy.finalConfigMutationMarker {
                let fetched: Data
                do {
                    fetched = try fixture.gitOutput(["rev-parse", "refs/remotes/origin/main"])
                } catch {
                    let detail = String((result.technicalDetail ?? "none").prefix(2_048))
                    throw M1SelfTestError.message("final-config tracking ref absent; result=\(result.code.rawValue), fetched=\(result.fetched), detail=\(detail); query=\(error)")
                }
                try check(
                    String(decoding: fetched, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == target,
                    "frozen config did not bind the final fetch target"
                )
            } else if mutation == GitCommandPolicy.finalGraphMutationMarker {
                try check(
                    result.code == .failedInspection,
                    "final graph mutation did not fail safely"
                )
            } else {
                try check(
                    result.resultClass == .failure,
                    "final frozen config swap attempt did not fail safely"
                )
                let remoteTarget = try fixture.gitOutput([
                    "--git-dir", fixture.remotePath,
                    "rev-parse", "refs/heads/main",
                ])
                try check(
                    String(decoding: remoteTarget, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == target,
                    "frozen config swap altered the mapped fetch destination"
                )
            }
        }
    }

    private static func testCancellationTaxonomyBoundaries(executable: String) throws {
        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            let before = String(
                decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            defer { authority.release() }
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            let audit = CommandAudit()
            let cancellation = CancellationToken()
            cancellation.cancel()
            let result = GitTransaction(
                runner: DescriptorProcessRunner(audit: audit),
                configuration: GitTransactionConfiguration(
                    trampolineExecutable: executable,
                    operationLeaseDescriptor: lease,
                    transportMapping: fixture.mapping
                ),
                account: fixture.account
            ).execute(
                candidate: fixture.candidate,
                cancellation: cancellation,
                phase: { _ in }
            )
            let observed = String(
                decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try check(result.code == .cancelledPending, "pre-inspection cancellation was not pending")
            try check(result.beforeCommit == nil, "pre-inspection cancellation claimed inspection")
            try check(result.targetCommit == nil, "pre-inspection cancellation claimed a target")
            try check(!result.fetched, "pre-inspection cancellation claimed fetch completion")
            try check(!result.mainUpdated, "pre-inspection cancellation claimed an update")
            try check(audit.invocations.isEmpty, "pre-inspection cancellation invoked Git")
            try check(observed == before, "pre-inspection cancellation changed local main")
        }

        do {
            let fixture = try M1GitFixture()
            defer { fixture.remove() }
            try fixture.git(["push", fixture.remotePath, "main:main"])
            let before = String(
                decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
            defer { authority.release() }
            let lease = try authority.duplicateOperationLease()
            defer { close(lease) }
            let audit = CommandAudit()
            let cancellation = CancellationToken()
            let result = GitTransaction(
                runner: DescriptorProcessRunner(audit: audit),
                configuration: GitTransactionConfiguration(
                    trampolineExecutable: executable,
                    operationLeaseDescriptor: lease,
                    transportMapping: fixture.mapping,
                    afterPreflight: { _ in cancellation.cancel() }
                ),
                account: fixture.account
            ).execute(
                candidate: fixture.candidate,
                cancellation: cancellation,
                phase: { _ in }
            )
            let observed = String(
                decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try check(
                result.code == .cancelledNoUpdate,
                "post-preflight cancellation claimed the repository was pending"
            )
            try check(result.beforeCommit == before, "post-preflight cancellation lost inspected main")
            try check(result.afterCommit == before, "post-preflight cancellation lost unchanged main")
            try check(result.targetCommit == nil, "post-preflight cancellation claimed a fetch target")
            try check(!result.fetched, "post-preflight cancellation claimed fetch completion")
            try check(!result.mainUpdated, "post-preflight cancellation claimed an update")
            try check(
                !audit.invocations.contains { $0.arguments.contains("fetch") },
                "post-preflight cancellation started fetch"
            )
            try check(observed == before, "post-preflight cancellation changed local main")
        }
    }

    private static func testPostFetchCancellationNoUpdate(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        try fixture.git(["push", fixture.remotePath, "main:main"])
        let before = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("post-fetch cancellation\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("post-fetch.txt")
        )
        try fixture.git(["add", "post-fetch.txt"])
        try fixture.git(["commit", "--quiet", "-m", "post-fetch target"])
        let target = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["push", fixture.remotePath, "main:main"])
        try fixture.git(["reset", "--hard", before])

        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let cancellation = CancellationToken()
        let transaction = GitTransaction(
            runner: DescriptorProcessRunner(afterProcessExit: { arguments, status in
                if status == 0, arguments.contains("fetch") {
                    cancellation.cancel()
                }
            }),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: executable,
                operationLeaseDescriptor: lease,
                transportMapping: fixture.mapping
            ),
            account: fixture.account
        )
        let result = transaction.execute(
            candidate: fixture.candidate,
            cancellation: cancellation,
            phase: { _ in }
        )
        let observed = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try check(result.code == .cancelledNoUpdate, "post-fetch cancellation used the wrong code")
        try check(result.fetched, "post-fetch cancellation did not retain fetch completion")
        try check(!result.mainUpdated, "post-fetch cancellation claimed an update")
        try check(result.beforeCommit == before, "post-fetch cancellation lost the starting commit")
        try check(result.targetCommit == target, "post-fetch cancellation lost the fetched target")
        try check(result.afterCommit == before, "post-fetch cancellation reported a changed main")
        try check(observed == before, "post-fetch cancellation changed local main")
        try check(
            result.explanation.contains("Fetch completed"),
            "post-fetch cancellation explanation denied the completed fetch"
        )
    }

    private static func testCancelledFetchTermination(executable: String) throws {
        let lateCancellationAfterFailure = ProcessResult(
            status: 1,
            stdout: Data(),
            stderr: Data(),
            stdoutTruncated: false,
            stderrTruncated: false,
            outputByteLimit: 16_384,
            timedOut: false,
            cancelled: true,
            terminationRequested: false,
            processID: 1
        )
        try check(
            FetchProcessOutcome.resolve(lateCancellationAfterFailure) == .failed,
            "late cancellation replaced an observed nonzero fetch failure"
        )
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        try fixture.git(["push", fixture.remotePath, "main:main"])
        let before = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("cancelled fetch\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("cancelled-fetch.txt")
        )
        try fixture.git(["add", "cancelled-fetch.txt"])
        try fixture.git(["commit", "--quiet", "-m", "cancelled fetch target"])
        try fixture.git(["push", fixture.remotePath, "main:main"])
        try fixture.git(["reset", "--hard", before])

        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let cancellation = CancellationToken()
        let transaction = GitTransaction(
            runner: DescriptorProcessRunner(
                beforeGatePublicationForRequest: { arguments in
                    if arguments.contains("fetch") {
                        cancellation.cancel()
                    }
                }
            ),
            configuration: GitTransactionConfiguration(
                trampolineExecutable: executable,
                operationLeaseDescriptor: lease,
                transportMapping: fixture.mapping
            ),
            account: fixture.account
        )
        let result = transaction.execute(
            candidate: fixture.candidate,
            cancellation: cancellation,
            phase: { _ in }
        )
        let observed = String(
            decoding: try fixture.gitOutput(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try check(
            result.code == .cancelledDuringFetch,
            "terminated fetch was not classified as cancelled during fetch"
        )
        try check(!result.fetched, "terminated fetch claimed completion")
        try check(!result.mainUpdated, "terminated fetch claimed a local update")
        try check(result.targetCommit == nil, "terminated fetch claimed a captured target")
        try check(result.beforeCommit == before, "terminated fetch lost the starting commit")
        try check(result.afterCommit == nil, "terminated fetch claimed an observed update")
        try check(observed == before, "terminated fetch changed local main")
    }

    private static func testPeerCloseChannels() throws {
        signal(SIGPIPE, SIG_IGN)
        var requestPipe: [Int32] = [-1, -1]
        guard pipe(&requestPipe) == 0 else {
            throw M1SelfTestError.systemCall("pipe peer close", errno)
        }
        close(requestPipe[0])
        defer { close(requestPipe[1]) }
        try check(
            throwsError {
                try JSONLineChannel.write(
                    WorkerControlMessage(command: .cancel),
                    descriptor: requestPipe[1]
                )
            },
            "closed request peer did not surface EPIPE"
        )
        var controlPipe: [Int32] = [-1, -1]
        guard pipe(&controlPipe) == 0 else {
            throw M1SelfTestError.systemCall("pipe control close", errno)
        }
        let token = CancellationToken()
        let monitor = CancellationChannelMonitor(descriptor: controlPipe[0], token: token)
        monitor.start()
        close(controlPipe[1])
        for _ in 0..<100 where !token.isCancelled {
            usleep(10_000)
        }
        monitor.stop()
        try check(token.isCancelled, "control peer close did not cancel")
    }

    private static func testChannelEOFProcessDrain(executable: String) throws {
        let fixture = try M1GitFixture()
        defer { fixture.remove() }
        let hookURL = URL(fileURLWithPath: fixture.rootPath)
            .appendingPathComponent("blocking-fsmonitor.sh")
        let hookPIDURL = URL(fileURLWithPath: fixture.rootPath)
            .appendingPathComponent("blocking-fsmonitor.pid")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "\(hookPIDURL.path)"
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: hookURL)
        guard chmod(hookURL.path, 0o700) == 0 else {
            throw M1SelfTestError.systemCall("chmod fsmonitor fixture", errno)
        }
        try fixture.git(["config", "core.fsmonitor", hookURL.path])

        let candidate = try RepositoryHandle.fixedCandidate(path: fixture.repositoryPath)
        let handle = try RepositoryHandle.open(candidate)
        let authority = try RunAuthority.acquireRun(at: fixture.stateLocation)
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }

        let frozenConfiguration = try handle.freezeConfiguration(
            account: fixture.account,
            additionalConfiguration: fixture.mapping.gitConfigText
        )
        var controlPipe: [Int32] = [-1, -1]
        guard pipe(&controlPipe) == 0 else {
            throw M1SelfTestError.systemCall("pipe cancellation channel", errno)
        }
        let token = CancellationToken()
        let monitor = CancellationChannelMonitor(descriptor: controlPipe[0], token: token)
        monitor.start()
        defer { monitor.stop() }

        let controlWrite = controlPipe[1]
        let writer = DispatchGroup()
        writer.enter()
        defer {
            while writer.wait(timeout: .now() + 3) != .success {
                fputs("M1 FIXTURE CHANNEL CLEANUP PENDING\n", stderr); fflush(stderr)
            }
        }
        Thread.detachNewThread {
            defer { close(controlWrite); writer.leave() }
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: hookPIDURL.path) {
                    break
                }
                usleep(10_000)
            }
        }

        let started = MonotonicInstant.now()
        let result = try DescriptorProcessRunner().run(
            ProcessRequest(
                executable: DescriptorProcessRunner.gitPath,
                arguments: [
                    "-c", GitCommandPolicy.testRootMarker,
                    "--no-replace-objects",
                    "--no-lazy-fetch",
                    "status",
                    "--porcelain=v1",
                    "-z",
                    "--untracked-files=all",
                ],
                environment: fixture.closedEnvironment(
                    frozenConfigPath: frozenConfiguration.snapshot.frozenPath
                ),
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor: lease,
                frozenConfigDescriptor: frozenConfiguration.descriptor,
                frozenConfigDirectoryDescriptor: frozenConfiguration.directoryDescriptor,
                timeoutSeconds: 10,
                trampolineExecutable: executable,
                executionSnapshot: try handle.executionSnapshot(
                    account: fixture.account,
                    frozenConfiguration: frozenConfiguration,
                    admission: nil
                )
            ),
            cancellation: token
        )
        try check(token.isCancelled, "channel EOF did not cancel")
        try check(result.cancelled, "runner did not report cancellation")
        try check(
            MonotonicInstant.now().milliseconds(since: started) < 8_000,
            "cancellation exceeded its bound"
        )
        try check(
            FileManager.default.fileExists(atPath: hookPIDURL.path),
            "blocking descendant was not exercised"
        )
        try check(processGroupIsGone(result.processID), "Git process group survived cancellation")
        let hookPIDText = try String(contentsOf: hookPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hookPID = try require(pid_t(hookPIDText), "invalid descendant process identifier")
        try check(processIsGone(hookPID), "Git descendant survived cancellation")
    }

    private static func rejectsGitCommand(_ arguments: [String]) -> Bool {
        throwsError { try GitCommandPolicy.validate(arguments) }
    }

    private static func makeResult(
        code: ResultCode,
        updated: Bool = false
    ) -> RepositoryResult {
        RepositoryResult(
            repository: RepositoryCandidate(
                id: "fixture",
                displayName: "Fixture",
                path: "/private/tmp/fixture",
                rawOrigin: "git@github.com:fixture-owner/fixture.git"
            ),
            code: code,
            fetched: false,
            mainUpdated: updated,
            beforeCommit: nil,
            targetCommit: nil,
            afterCommit: nil,
            startedAt: "2026-09-03T00:00:00.000Z",
            endedAt: "2026-09-03T00:00:00.001Z",
            durationMilliseconds: 1,
            explanation: code.rawValue
        )
    }

    private static func throwsError<T>(_ body: () throws -> T) -> Bool {
        do {
            _ = try body()
            return false
        } catch {
            return true
        }
    }

    private static func fetchTargetFailureCode(
        _ transaction: GitTransaction,
        output: Data
    ) -> ResultCode? {
        do {
            _ = try transaction.capturedFetchTarget(stdout: output, truncated: false)
            return nil
        } catch let error as FetchTargetCaptureError {
            return error.resultCode
        } catch {
            return nil
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw M1SelfTestError.message(message)
        }
        return value
    }

    private static func check(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw M1SelfTestError.message(message)
        }
    }
}

private final class M1SpawnAnchorBox: @unchecked Sendable {
    private let mutex = NSLock()
    private var anchor: OwnedSpawnAnchor?
    func store(_ value: OwnedSpawnAnchor) { mutex.lock(); anchor = value; mutex.unlock() }
    var value: OwnedSpawnAnchor? { mutex.lock(); defer { mutex.unlock() }; return anchor }
}

private final class M1AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class M1TemporaryDirectory {
    let path: String

    init() throws {
        var storage = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-self-tests.") + "XXXXXX").utf8CString)
        guard let created = storage.withUnsafeMutableBufferPointer({
            mkdtemp($0.baseAddress)
        }) else {
            throw M1SelfTestError.systemCall("mkdtemp", errno)
        }
        path = String(cString: created)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit {
        remove()
    }
}

private final class ProcessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProcessResult?
    private var error: Error?

    func store(_ value: ProcessResult) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func store(_ value: Error) {
        lock.lock()
        error = value
        lock.unlock()
    }

    func get() throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw error
        }
        guard let result else {
            throw M1SelfTestError.message("process result was not recorded")
        }
        return result
    }
}

struct M1GitFixture {
    let temporary: M1TemporaryDirectory
    let rootPath: String
    let repositoryPath: String
    let remotePath: String
    let stateLocation: StateLocation
    let candidate: RepositoryCandidate
    let mapping: TransportMapping
    let account: EffectiveAccount
    let closedEnvironment: [String: String]

    init() throws {
        let temporary = try M1TemporaryDirectory()
        self.temporary = temporary
        rootPath = temporary.path
        repositoryPath = URL(fileURLWithPath: rootPath).appendingPathComponent("repository").path
        remotePath = URL(fileURLWithPath: rootPath).appendingPathComponent("remote.git").path
        stateLocation = try StateLocation.isolated(root: rootPath)
        try TestIsolation.initializeState(at: stateLocation)

        try Self.runGit(["init", "--bare", "--quiet", "--initial-branch=main", remotePath])
        // git init creates with default umask (typically 0755); TestIsolation
        // requires all contained directories to be owner-private (0700).
        guard chmod(remotePath, 0o700) == 0 else {
            throw M1SelfTestError.systemCall("chmod remote.git", errno)
        }
        try Self.runGit(["init", "--quiet", "--initial-branch=main", repositoryPath])
        guard chmod(repositoryPath, 0o700) == 0 else {
            throw M1SelfTestError.systemCall("chmod repository", errno)
        }
        try Self.runGit(["-C", repositoryPath, "config", "user.name", "M1 Fixture"])
        try Self.runGit([
            "-C", repositoryPath, "config", "user.email", "fixture@example.invalid",
        ])
        try Data("fixture\n".utf8).write(
            to: URL(fileURLWithPath: repositoryPath).appendingPathComponent("value.txt")
        )
        try Self.runGit(["-C", repositoryPath, "add", "value.txt"])
        try Self.runGit(["-C", repositoryPath, "commit", "--quiet", "-m", "fixture"])
        let logicalOrigin = "git@github.com:fixture-owner/fixture-repo.git"
        try Self.runGit(["-C", repositoryPath, "remote", "add", "origin", logicalOrigin])
        candidate = try RepositoryHandle.fixedCandidate(path: repositoryPath)
        mapping = try TransportMapping(
            logicalURL: logicalOrigin,
            localRepositoryPath: remotePath,
            containmentRoot: rootPath
        )
        let home = URL(fileURLWithPath: rootPath).appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        account = EffectiveAccount(
            uid: geteuid(),
            username: "fixture",
            homeDirectory: home
        )
        closedEnvironment = ClosedGitEnvironment.make(
            account: account,
            transport: .ssh,
            inherited: [:]
        )
    }

    func git(_ arguments: [String]) throws {
        _ = try Self.runGit(["-C", repositoryPath] + arguments)
    }

    func gitOutput(_ arguments: [String]) throws -> Data {
        try Self.runGit(["-C", repositoryPath] + arguments)
    }

    func closedEnvironment(frozenConfigPath: String) -> [String: String] {
        ClosedGitEnvironment.make(
            account: account,
            transport: .ssh,
            frozenConfigPath: frozenConfigPath,
            inherited: [:]
        )
    }

    func remove() {
        temporary.remove()
    }

    @discardableResult
    static func runGit(_ arguments: [String]) throws -> Data {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = temporary.path + "/home"
        try FileManager.default.createDirectory(atPath: home,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let directory = Darwin.open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw M1SelfTestError.systemCall("fixture Git directory", errno) }
        defer { close(directory) }
        let result = try ClosedProcessRunner(outputLimit: DescriptorProcessRunner.completeRepositoryOutputLimit).run(
            command: ClosedProcessCommand(executable: discoveryFixtureGitExecutable, arguments: arguments),
            environment: ClosedProcessRunner.environment(account: account),
            workingDirectoryDescriptor: directory, account: account, timeout: 10,
            cancellation: CancellationToken())
        guard result.status == 0 && !result.cancelled && !result.timedOut
                && !result.stdoutTruncated && !result.stderrTruncated else {
            throw M1SelfTestError.message("fixture Git failed: " + String(decoding: result.output, as: UTF8.self))
        }
        return result.output
    }

}

// Fixed testing protocols only. Custody begins at the original suspended spawn;
// no decoded PID can be adopted, signalled, or independently reaped here.
private final class M1FixtureChild {
    enum Role {
        case exited, unrelated, lease(Int32)
        case lock(String, String, Int32, Int32)
        case orphanSnapshot(String, String, String)
    }
    let anchor: OwnedSpawnAnchor
    let owner: OwnedDirectChild
    private let streamsDrained: @Sendable () -> Bool

    init(_ role: Role, streamsDrained: @escaping @Sendable () -> Bool = { true }) throws {
        let registry = try RuntimeFixtureSession.current()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw M1SelfTestError.message("fixture child file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw M1SelfTestError.message("fixture child attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else {
                throw M1SelfTestError.message("fixture child null stream")
            }
        }
        var arguments: [String]
        var environment = ["PATH=\(ClosedGitEnvironment.fixedPath)", "LANG=C", "LC_ALL=C"]
        switch role {
        case .exited: arguments = ["/bin/sleep", "0"]
        case .unrelated: arguments = ["/bin/sleep", "30"]
        case .lease(let lease):
            arguments = ["/bin/sleep", "2"]
            guard posix_spawn_file_actions_adddup2(&actions, lease, DescriptorProcessRunner.inheritedLeaseFD) == 0 else {
                throw M1SelfTestError.message("fixture child lease")
            }
        case .lock(let executable, let root, let ready, let release):
            arguments = [executable, "--shadow-sync-m1-lock-holder", root, String(ready), String(release)]
            for fd in [ready, release] {
                guard fd > STDERR_FILENO, posix_spawn_file_actions_addinherit_np(&actions, fd) == 0 else {
                    throw M1SelfTestError.message("fixture child lock channel")
                }
            }
        case .orphanSnapshot(let executable, let repository, let home):
            arguments = [executable, "--shadow-sync-m1-orphan-snapshot", repository, home]
            environment.append("HOME=\(home)")
        }
        // The child must share this exact attempt's frozen-config namespace.
        _ = try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.")
        if let namespace = ProcessInfo.processInfo.environment["SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE"] {
            environment.append("SHADOW_SYNC_RUNTIME_FIXTURE_NAMESPACE=\(namespace)")
        }
        var defaults = sigset_t(); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var mask = sigset_t(); sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw M1SelfTestError.message("fixture child closed attributes")
        }
        let executable = arguments[0]
        let anchor = try withCStringArray(arguments) { argv in
            try withCStringArray(environment) { envp in
                try RuntimeFixtureSpawn.spawn(registry: registry, executable: executable,
                    actions: &actions, attributes: &attributes, arguments: argv,
                    environment: envp, streamsDrained: streamsDrained)
            }
        }
        do {
            self.owner = try anchor.transfer(expectedExecutable: executable,
                generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
            self.anchor = anchor
            self.streamsDrained = streamsDrained
        } catch {
            RuntimeFixtureSession.drain(anchor)
            throw error
        }
    }
    func resume() throws {
        guard owner.send(SIGCONT) else { throw M1SelfTestError.message("fixture child admission refused") }
    }
    func waitForExit(timeout: TimeInterval) throws -> Int32 {
        let deadline = MonotonicDeadline(seconds: timeout)
        while true {
            switch owner.reapAfterGroupDrain(streamsDrained: streamsDrained()) {
            case .reaped(let status):
                RuntimeFixtureSession.drain(anchor)
                return status
            case .ownershipFailure(let code):
                throw M1SelfTestError.systemCall("fixture child ownership", code)
            case .running: break
            }
            guard !deadline.hasExpired else { throw M1SelfTestError.message("fixture child missed its deadline") }
            usleep(1_000)
        }
    }
    func stop() { RuntimeFixtureSession.drain(anchor) }
    deinit { stop() }
}

// Readiness is a real nonblocking stream. EOF remains required for child
// retirement; seeing the readiness byte never substitutes for drain evidence.
private final class M1ReadyChannel: @unchecked Sendable {
    private let mutex = NSLock()
    private let descriptor: Int32
    private var eof = false, invalid = false
    private var count = 0
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    private func readLocked() {
        guard !eof else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        while true {
            let size = Darwin.read(descriptor, &bytes, bytes.count)
            if size > 0 {
                count += size
                if count != 1 || bytes[0] != 1 { invalid = true }
            } else if size == 0 { eof = true; return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else { invalid = true; return }
        }
    }
    var ready: Bool {
        mutex.lock(); defer { mutex.unlock() }
        readLocked(); return count == 1 && !invalid
    }
    var drained: Bool {
        mutex.lock(); defer { mutex.unlock() }
        readLocked(); return eof
    }
}

private final class M1LockHolder {
    private let child: M1FixtureChild
    private let readyDescriptor: Int32
    private let channel: M1ReadyChannel
    private var releaseDescriptor: Int32
    private var finished = false

    init(executable: String, root: String) throws {
        var readyPipe: [Int32] = [-1, -1], releasePipe: [Int32] = [-1, -1]
        guard pipe(&readyPipe) == 0, pipe(&releasePipe) == 0 else {
            closeDescriptors(readyPipe + releasePipe)
            throw M1SelfTestError.systemCall("pipe lock holder", errno)
        }
        var transferred = false
        defer { if !transferred { closeDescriptors(readyPipe + releasePipe) } }
        for fd in readyPipe + releasePipe {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw M1SelfTestError.systemCall("lock holder close-on-exec", errno)
            }
        }
        guard fcntl(readyPipe[0], F_SETFL, O_NONBLOCK) == 0 else {
            throw M1SelfTestError.systemCall("lock holder nonblocking readiness", errno)
        }
        let channel = M1ReadyChannel(readyPipe[0])
        let child = try M1FixtureChild(.lock(executable, root, readyPipe[1], releasePipe[0]),
            streamsDrained: { channel.drained })
        close(readyPipe[1]); readyPipe[1] = -1
        close(releasePipe[0]); releasePipe[0] = -1
        do {
            try child.resume()
            let deadline = MonotonicDeadline(seconds: 5)
            while !channel.ready && child.owner.poll() == .running && !deadline.hasExpired { usleep(1_000) }
            guard channel.ready else { throw M1SelfTestError.message("lock holder did not become ready") }
        } catch {
            close(releasePipe[1]); releasePipe[1] = -1
            child.stop() // Keep the readiness FD and channel until actual EOF/reap.
            throw error
        }
        self.child = child; self.channel = channel
        readyDescriptor = readyPipe[0]; releaseDescriptor = releasePipe[1]
        transferred = true
    }
    func finish() throws {
        guard !finished else { return }
        var release: UInt8 = 1
        guard Darwin.write(releaseDescriptor, &release, 1) == 1 else {
            throw M1SelfTestError.systemCall("release lock holder", errno)
        }
        close(releaseDescriptor); releaseDescriptor = -1
        guard try child.waitForExit(timeout: 5) == 0, channel.drained else {
            throw M1SelfTestError.message("lock holder failed")
        }
        finished = true
    }
    func stop() {
        if releaseDescriptor >= 0 { close(releaseDescriptor); releaseDescriptor = -1 }
        child.stop()
        finished = true
    }
    deinit { stop(); close(readyDescriptor) }
}

private enum M1SelfTestError: Error, CustomStringConvertible {
    case message(String)
    case systemCall(String, Int32)
    case testFailed(String, String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        case let .systemCall(name, code):
            return "\(name) failed (\(code))"
        case let .testFailed(name, reason):
            return "\(name): \(reason)"
        }
    }
}

private func processGroupIsGone(_ processID: pid_t) -> Bool {
    errno = 0
    return kill(-processID, 0) == -1 && errno == ESRCH
}

private func processIsGone(_ processID: pid_t) -> Bool {
    errno = 0
    return kill(processID, 0) == -1 && errno == ESRCH
}

private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else {
            return
        }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                base.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw M1SelfTestError.systemCall("write", errno)
            }
            offset += count
        }
    }
}

private func closeDescriptors(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 {
        close(descriptor)
    }
}

private func withCStringArray<T>(
    _ values: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> T
) throws -> T {
    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    guard pointers.allSatisfy({ $0 != nil }) else { throw M1SelfTestError.message("fixture child arguments") }
    var mutable = pointers
    mutable.append(nil)
    return try mutable.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress)
    }
}
#endif
