#if SHADOW_SYNC_TESTING
import Darwin
import CryptoKit
import Foundation

public enum V2Body2SelfTestRunner {
    public static func runAll(
        testExecutable: String,
        progress: (String) -> Void
    ) throws -> Int {
        let tests: [(String, () throws -> Void)] = [
            (
                "DM2-T07 inventory-purpose closed oracles",
                {
                    try testPurposeAndActivity(
                        testExecutable: testExecutable
                    )
                }
            ),
            (
                "DM2-T14 gh-adapter closed execution",
                { try testGitHubAdapter() }
            ),
            (
                "DM2-T06 R01 exact prune Repair",
                { try testPrune(testExecutable: testExecutable) }
            ),
            (
                "DM2-T06 R02 moved worktree Repair",
                { try testMovedRepair(testExecutable: testExecutable) }
            ),
            (
                "DM2-T06 R03 origin HEAD explanation",
                { try testOriginHeadExplanation(testExecutable: testExecutable) }
            ),
            (
                "DM2-T06 R04 SHA-1 Initialize",
                {
                    try testInitialize(
                        testExecutable: testExecutable,
                        objectFormat: "sha1"
                    )
                }
            ),
            (
                "DM2-T06 R04 SHA-256 Initialize",
                {
                    try testInitialize(
                        testExecutable: testExecutable,
                        objectFormat: "sha256"
                    )
                }
            ),
            (
                "DM2-T05 maintenance hook and command audit",
                {
                    try testHookAndCommandAudit(
                        testExecutable: testExecutable
                    )
                }
            ),
        ]
        var passed = 0
        for (name, test) in tests {
            do {
                try RuntimeFixtureSession.withCase(name) { try test() }
                passed += 1
                progress(name)
            } catch {
                throw Body2SelfTestError.failed(
                    "\(name): \(error)"
                )
            }
        }
        return passed
    }

    public static func runFocused(
        _ identifier: String,
        testExecutable: String,
        progress: (String) -> Void
    ) throws {
        let test: () throws -> Void
        switch identifier {
        case "t05":
            test = {
                try testHookAndCommandAudit(
                    testExecutable: testExecutable
                )
            }
        case "r01":
            test = {
                try testPrune(
                    testExecutable: testExecutable
                )
            }
        case "r02":
            test = {
                try testMovedRepair(
                    testExecutable: testExecutable
                )
            }
        case "r03":
            test = {
                try testOriginHeadExplanation(
                    testExecutable: testExecutable
                )
            }
        case "r04-sha1":
            test = {
                try testInitialize(
                    testExecutable: testExecutable,
                    objectFormat: "sha1"
                )
            }
        case "r04-sha256":
            test = {
                try testInitialize(
                    testExecutable: testExecutable,
                    objectFormat: "sha256"
                )
            }
        default:
            throw Body2SelfTestError.message(
                "unknown Body 2 focused test"
            )
        }
        do {
            let caseID = identifier == "t05"
                ? "DM2-T05 maintenance hook and command audit" : "DM2-T06 \(identifier)"
            try RuntimeFixtureSession.withCase(caseID) { try test() }
            progress(
                identifier == "t05"
                    ? "DM2-T05 maintenance hook and command audit"
                    : "DM2-T06 \(identifier)"
            )
        } catch {
            throw Body2SelfTestError.message(
                "\(identifier == "t05" ? "DM2-T05" : "DM2-T06 \(identifier)"): \(error)"
            )
        }
    }

    private static func testPurposeAndActivity(
        testExecutable: String
    ) throws {
        let oid = String(repeating: "a", count: 40)
        let otherOID = String(repeating: "b", count: 40)
        let merged = try pullRequest(
            number: 1,
            state: .merged,
            oid: oid
        )
        let completed = PurposeOracle.assess(
            repositoryID: "owner/repo",
            branch: "feature",
            tipOID: oid,
            pullRequests: [merged],
            pullRequestAvailability: .available,
            tipIntegratedIntoDefault: true
        )
        try check(
            completed.purpose == .completed,
            "exact merged evidence did not precede ancestry"
        )
        let open = try pullRequest(
            number: 2,
            state: .open,
            oid: oid
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [open],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: true
            ).purpose == .active,
            "active evidence did not precede ancestry"
        )
        let draft = try pullRequest(
            number: 8,
            state: .draft,
            oid: oid
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [draft],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: false
            ).purpose == .active,
            "exact Draft evidence was not Active"
        )
        let fork = try PullRequestRecord(
            number: 3,
            url: "https://github.com/owner/repo/pull/3",
            repositoryID: "owner/repo",
            state: .open,
            headRefName: "feature",
            headRefOID: oid,
            isCrossRepository: true,
            updatedAt: "2026-09-09T12:00:00Z",
            closedAt: nil,
            mergedAt: nil
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [fork],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: false
            ).purpose == .ambiguous,
            "fork evidence was not ambiguous"
        )
        let duplicate = try pullRequest(
            number: 4,
            state: .closed,
            oid: oid
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [merged, duplicate],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: true
            ).purpose == .ambiguous,
            "multiple exact associations were not ambiguous"
        )
        let superseded = try pullRequest(
            number: 5,
            state: .merged,
            oid: otherOID
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [superseded],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: false
            ).purpose == .superseded,
            "OID change did not recompute as superseded"
        )
        let closed = try pullRequest(
            number: 6,
            state: .closed,
            oid: oid
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [closed],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: false
            ).purpose == .closedIncomplete,
            "closed incomplete evidence was misclassified"
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [closed],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: true
            ).purpose == .integrated,
            "independent ancestry did not precede Closed incomplete"
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: true
            ).purpose == .integrated,
            "independent ancestry did not yield Integrated"
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: false
            ).purpose == .noKnownPullRequest,
            "empty available query did not yield No known PR"
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [],
                pullRequestAvailability: .unavailable,
                tipIntegratedIntoDefault: false
            ).purpose == .unavailable,
            "adapter failure did not yield Unavailable"
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: oid,
                pullRequests: [],
                pullRequestAvailability: .unavailable,
                tipIntegratedIntoDefault: true
            ).purpose == .integrated,
            "verified ancestry was lost during GitHub unavailability"
        )
        try check(
            PurposeOracle.assess(
                repositoryID: "owner/repo",
                branch: "feature",
                tipOID: nil,
                pullRequests: [open],
                pullRequestAvailability: .available,
                tipIntegratedIntoDefault: false
            ).purpose == .unavailable,
            "missing branch-tip identity was not unavailable"
        )
        try check(
            throwsError {
                _ = try PullRequestRecord(
                    number: 9,
                    url: "https://github.com/owner/repo/pull/9",
                    repositoryID: "owner/repo",
                    state: .merged,
                    headRefName: "feature",
                    headRefOID: oid,
                    isCrossRepository: false,
                    updatedAt: "2026-09-09T12:00:00Z",
                    closedAt: nil,
                    mergedAt: nil
                )
            },
            "contradictory merged PR evidence was accepted"
        )

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expected: [(Int, ActivityBand)] = [
            (7, .recent),
            (8, .idle),
            (30, .idle),
            (31, .staleCandidate),
        ]
        for (days, band) in expected {
            try check(
                ActivityBandOracle.classify(
                    capturedNow: now,
                    commitDate: now.addingTimeInterval(
                        -TimeInterval(days)
                            * ActivityBandOracle.completeDay
                    ),
                    associatedPullRequests: []
                ) == band,
                "activity boundary \(days) was wrong"
            )
        }
        try check(
            ActivityBandOracle.classify(
                capturedNow: now,
                commitDate: nil,
                associatedPullRequests: []
            ) == .unavailable,
            "unknown activity was not unavailable"
        )
        let updatedAtBoundary = try PullRequestRecord(
            number: 10,
            url: "https://github.com/owner/repo/pull/10",
            repositoryID: "owner/repo",
            state: .open,
            headRefName: "feature",
            headRefOID: oid,
            isCrossRepository: false,
            updatedAt: ISO8601DateFormatter().string(
                from: now.addingTimeInterval(
                    -8 * ActivityBandOracle.completeDay
                )
            ),
            closedAt: nil,
            mergedAt: nil
        )
        try check(
            ActivityBandOracle.classify(
                capturedNow: now,
                commitDate: now.addingTimeInterval(
                    -31 * ActivityBandOracle.completeDay
                ),
                associatedPullRequests: [updatedAtBoundary]
            ) == .idle,
            "exact associated PR update did not control newest activity"
        )
        let branchPreview = RemovalPreviewOracle.branch(
            isResolvedDefault: false,
            policyCategory: .writable,
            claimIDs: ["worktree:claim"],
            purpose: .completed,
            activity: .staleCandidate,
            tipPreserved: true
        )
        try check(
            branchPreview.permission == .dependencyBlocked,
            "purpose and age incorrectly authorized branch removal"
        )
        let worktreePreview = RemovalPreviewOracle.worktree(
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
            activity: .staleCandidate,
            branchTipPreserved: true
        )
        try check(
            worktreePreview.recommendation == .recommended
                && worktreePreview.permission == .previewOnly,
            "recommendation became cleanup permission"
        )
        let hardExcluded = RemovalPreviewOracle.branch(
            isResolvedDefault: true,
            policyCategory: .writable,
            claimIDs: [],
            purpose: .completed,
            activity: .staleCandidate,
            tipPreserved: true
        )
        let recovery = RemovalPreviewOracle.branch(
            isResolvedDefault: false,
            policyCategory: .writable,
            claimIDs: [],
            purpose: .completed,
            activity: .staleCandidate,
            tipPreserved: false
        )
        let override = RemovalPreviewOracle.worktree(
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
            awa: AWAEvidence(
                state: .unavailable,
                explanation: "fixture",
                blocksRemoval: true,
                forceOverridableUnknown: true
            ),
            purpose: .completed,
            activity: .staleCandidate,
            branchTipPreserved: true
        )
        let historyOverride = RemovalPreviewOracle.branch(
            isResolvedDefault: false,
            policyCategory: .writable,
            claimIDs: [],
            purpose: .closedIncomplete,
            activity: .staleCandidate,
            tipPreserved: false
        )
        try check(
            hardExcluded.recommendation == .hardExcluded
                && hardExcluded.permission == .hardExcluded
                && recovery.recommendation == .recovery
                && recovery.permission == .previewOnly
                && recovery.recoveryConsequence != nil
                && override.recommendation == .override
                && override.permission == .previewOnly
                && override.overrideConsequence != nil
                && historyOverride.recommendation == .keep
                && historyOverride.overrideConsequence != nil,
            "removal preview states or consequence boundaries are incomplete"
        )
        try testLifecycleInventory(
            testExecutable: testExecutable
        )
    }

    private static func testGitHubAdapter() throws {
        try check(
            ReadOnlyGitHubCLIAdapter.approvedPaths == [
                "/opt/homebrew/bin/gh",
                "/usr/local/bin/gh",
            ],
            "approved gh path set changed"
        )
        let expectedArguments = [
            "pr", "list",
            "--repo", "owner/repo",
            "--head", "feature/topic",
            "--state", "all",
            "--limit", "100",
            "--json",
            "number,url,state,isDraft,headRefName,headRefOid,isCrossRepository,updatedAt,closedAt,mergedAt",
        ]
        try check(
            try ReadOnlyGitHubCLIAdapter.arguments(
                repositoryID: "owner/repo",
                branch: "feature/topic"
            ) == expectedArguments,
            "gh argv grammar changed"
        )
        try check(
            throwsError {
                _ = try ReadOnlyGitHubCLIAdapter.arguments(
                    repositoryID: "--help/repo",
                    branch: "feature"
                )
            } && throwsError {
                _ = try ReadOnlyGitHubCLIAdapter.arguments(
                    repositoryID: "owner/repo",
                    branch: "--help"
                )
            },
            "option-shaped gh input was accepted"
        )
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = temporary.path + "/home"
        try FileManager.default.createDirectory(
            atPath: home,
            withIntermediateDirectories: true
        )
        let account = EffectiveAccount(
            uid: geteuid(),
            username: "fixture",
            homeDirectory: home
        )
        let unqualifiedAudit = LockedCounter()
        let unqualified = ReadOnlyGitHubCLIAdapter(
            account: account,
            audit: { _ in _ = unqualifiedAudit.increment() }
        )
        let refused = unqualified.lookup(
            repositoryID: "owner/repo", branch: "feature",
            tipOID: String(repeating: "a", count: 40),
            cancellation: CancellationToken()
        )
        try check(refused.unavailableReason == .unqualified
            && refused.records.isEmpty && unqualifiedAudit.value == 0,
            "unqualified production GitHub adapter did not refuse before invocation")
        let cancelled = CancellationToken()
        cancelled.cancel()
        try check(unqualified.lookup(
            repositoryID: "owner/repo", branch: "feature",
            tipOID: String(repeating: "a", count: 40), cancellation: cancelled
        ).unavailableReason == .cancelled && unqualifiedAudit.value == 0,
            "unqualified GitHub adapter lost cancellation or invoked a child")
        let environment =
            ReadOnlyGitHubCLIAdapter.environment(account: account)
        try check(
            environment["HOME"] == home
                && environment["GH_TOKEN"] == nil
                && environment["GITHUB_TOKEN"] == nil
                && environment["GH_PROMPT_DISABLED"] == "1",
            "gh environment is not closed"
        )
        try check(
            Set(environment.keys) == Set([
                "HOME", "LANG", "LC_ALL",
                "GH_PROMPT_DISABLED", "GH_PAGER", "PAGER",
                "NO_COLOR", "CLICOLOR",
            ])
                && environment["LANG"] == "C"
                && environment["LC_ALL"] == "C"
                && environment["GH_PAGER"] == "cat"
                && environment["PAGER"] == "cat"
                && environment["NO_COLOR"] == "1"
                && environment["CLICOLOR"] == "0",
            "gh closed environment key set changed"
        )
        let executable = temporary.path + "/fake-gh"
        try compileC(
            """
            #include <stdio.h>
            int main(void) {
              fputs("[{\\\"number\\\":7,\\\"url\\\":\\\"https://github.com/owner/repo/pull/7\\\",\\\"state\\\":\\\"OPEN\\\",\\\"isDraft\\\":false,\\\"headRefName\\\":\\\"feature\\\",\\\"headRefOid\\\":\\\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\\",\\\"isCrossRepository\\\":false,\\\"updatedAt\\\":\\\"2026-09-09T12:00:00Z\\\",\\\"closedAt\\\":null,\\\"mergedAt\\\":null}]", stdout);
              return 0;
            }
            """,
            output: executable
        )
        let audit = LockedCounter()
        let adapter = ReadOnlyGitHubCLIAdapter(
            account: account,
            testingExecutablePath: executable,
            audit: { _ in _ = audit.increment() }
        )
        let first = adapter.lookup(
            repositoryID: "owner/repo",
            branch: "feature",
            tipOID: String(repeating: "a", count: 40),
            cancellation: CancellationToken()
        )
        let second = adapter.lookup(
            repositoryID: "owner/repo",
            branch: "feature",
            tipOID: String(repeating: "a", count: 40),
            cancellation: CancellationToken()
        )
        let changedOID = adapter.lookup(
            repositoryID: "owner/repo",
            branch: "feature",
            tipOID: String(repeating: "b", count: 40),
            cancellation: CancellationToken()
        )
        try check(
            first.records.count == 1
                && second == first
                && changedOID.records.count == 1
                && audit.value == 2,
            "gh output, one-run cache, or OID invalidation failed"
        )
        for index in 0...512 {
            _ = adapter.lookup(
                repositoryID: "owner/repo",
                branch: "cache-\(index)",
                tipOID: String(
                    format: "%040llx",
                    UInt64(index + 1)
                ),
                cancellation: CancellationToken()
            )
        }
        try check(
            adapter.testingCacheCount == 512,
            "gh one-run memoization exceeded its fixed capacity"
        )
        let malformed = Data("[{\"number\":1,\"extra\":true}]".utf8)
        try check(
            throwsError {
                _ = try ReadOnlyGitHubCLIAdapter.parse(
                    malformed,
                    repositoryID: "owner/repo"
                )
            },
            "malformed gh output was accepted"
        )
        let limitRows: [[String: Any]] = (1...100).map {
            [
                "number": $0,
                "url":
                    "https://github.com/owner/repo/pull/\($0)",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "feature",
                "headRefOid":
                    String(repeating: "a", count: 40),
                "isCrossRepository": false,
                "updatedAt": "2026-09-09T12:00:00Z",
                "closedAt": NSNull(),
                "mergedAt": NSNull(),
            ]
        }
        let limitData = try JSONSerialization.data(
            withJSONObject: limitRows
        )
        try check(
            throwsError {
                _ = try ReadOnlyGitHubCLIAdapter.parse(
                    limitData,
                    repositoryID: "owner/repo"
                )
            },
            "gh limit-bound result was treated as complete"
        )

        let sleeper = temporary.path + "/sleep-gh"
        try compileC(
            """
            #include <unistd.h>
            int main(void) { sleep(30); return 0; }
            """,
            output: sleeper
        )
        let timeoutAdapter = ReadOnlyGitHubCLIAdapter(
            account: account,
            testingExecutablePath: sleeper,
            testingTimeoutSeconds: 0.2
        )
        let timedOut = timeoutAdapter.lookup(
            repositoryID: "owner/repo",
            branch: "timeout",
            tipOID: String(repeating: "c", count: 40),
            cancellation: CancellationToken()
        )
        try check(
            timedOut.unavailableReason == .timeout,
            "gh timeout did not degrade to unavailable"
        )
        let cancellation = CancellationToken()
        cancellation.cancel()
        try check(
            timeoutAdapter.lookup(
                repositoryID: "owner/repo",
                branch: "cancel",
                tipOID: String(repeating: "d", count: 40),
                cancellation: cancellation
            ).unavailableReason == .cancelled,
            "gh cancellation did not degrade to unavailable"
        )
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let activeCancellation = CancellationToken()
        let lookupBox = LookupBox()
        let concurrentAdapter = ReadOnlyGitHubCLIAdapter(
            account: account,
            testingExecutablePath: sleeper,
            testingTimeoutSeconds: 5,
            audit: { _ in started.signal() }
        )
        DispatchQueue.global().async {
            lookupBox.set(concurrentAdapter.lookup(
                repositoryID: "owner/repo",
                branch: "concurrent-a",
                tipOID: String(repeating: "1", count: 40),
                cancellation: activeCancellation
            ))
            finished.signal()
        }
        try check(
            started.wait(timeout: .now() + 2) == .success,
            "gh concurrency fixture did not start"
        )
        let busy = concurrentAdapter.lookup(
            repositoryID: "owner/repo",
            branch: "concurrent-b",
            tipOID: String(repeating: "2", count: 40),
            cancellation: CancellationToken()
        )
        activeCancellation.cancel()
        try check(
            finished.wait(timeout: .now() + 5) == .success
                && lookupBox.value?.unavailableReason
                    == .cancelled
                && busy.unavailableReason == .busy,
            "gh global child bound or live cancellation/reap failed"
        )
        let oversized = temporary.path + "/large-gh"
        try compileC(
            """
            #include <stdio.h>
            int main(void) {
              for (int i = 0; i < 70000; i++) fputc('x', stdout);
              return 0;
            }
            """,
            output: oversized
        )
        try check(
            ReadOnlyGitHubCLIAdapter(
                account: account,
                testingExecutablePath: oversized
            ).lookup(
                repositoryID: "owner/repo",
                branch: "large",
                tipOID: String(repeating: "e", count: 40),
                cancellation: CancellationToken()
            ).unavailableReason == .truncated,
            "gh output bound did not fail closed"
        )
        let failures = temporary.path + "/failure-gh"
        try compileC(
            """
            #include <stdio.h>
            #include <string.h>
            int main(int argc, char **argv) {
              const char *head = "";
              for (int i = 1; i + 1 < argc; i++) {
                if (strcmp(argv[i], "--head") == 0) head = argv[i + 1];
              }
              if (strstr(head, "auth")) {
                fputs("authentication failed token=ghp_fixture_secret", stderr);
              } else if (strstr(head, "rate")) {
                fputs("secondary rate limit", stderr);
              } else {
                fputs("network connection refused", stderr);
              }
              return 1;
            }
            """,
            output: failures
        )
        let failureAdapter = ReadOnlyGitHubCLIAdapter(
            account: account,
            testingExecutablePath: failures
        )
        let authentication = failureAdapter.lookup(
            repositoryID: "owner/repo",
            branch: "auth",
            tipOID: String(repeating: "3", count: 40),
            cancellation: CancellationToken()
        )
        let network = failureAdapter.lookup(
            repositoryID: "owner/repo",
            branch: "network",
            tipOID: String(repeating: "4", count: 40),
            cancellation: CancellationToken()
        )
        let rate = failureAdapter.lookup(
            repositoryID: "owner/repo",
            branch: "rate",
            tipOID: String(repeating: "5", count: 40),
            cancellation: CancellationToken()
        )
        let encodedFailure = String(
            decoding: try JSONEncoder().encode(authentication),
            as: UTF8.self
        )
        try check(
            authentication.unavailableReason == .authentication
                && network.unavailableReason == .network
                && rate.unavailableReason == .rateLimited
                && !encodedFailure.contains("fixture_secret"),
            "gh auth/network/rate degradation or redaction failed"
        )
        let unsafeMode = temporary.path + "/unsafe-gh"
        try FileManager.default.copyItem(
            atPath: executable,
            toPath: unsafeMode
        )
        guard chmod(unsafeMode, 0o777) == 0 else {
            throw Body2SelfTestError.message(
                "could not create unsafe gh fixture"
            )
        }
        try check(
            ReadOnlyGitHubCLIAdapter(
                account: account,
                testingExecutablePath: unsafeMode
            ).lookup(
                repositoryID: "owner/repo",
                branch: "unsafe-mode",
                tipOID: String(repeating: "6", count: 40),
                cancellation: CancellationToken()
            ).unavailableReason == .executableDrift,
            "group/world-writable gh executable was admitted"
        )
        let raced = temporary.path + "/race-gh"
        try FileManager.default.copyItem(
            atPath: executable,
            toPath: raced
        )
        let raceAdapter = ReadOnlyGitHubCLIAdapter(
            account: account,
            testingExecutablePath: raced,
            testingBeforeIdentityPublication: {
                try? FileManager.default.removeItem(atPath: raced)
                try? FileManager.default.copyItem(
                    atPath: "/usr/bin/true",
                    toPath: raced
                )
            }
        )
        try check(
            raceAdapter.lookup(
                repositoryID: "owner/repo",
                branch: "race",
                tipOID: String(repeating: "f", count: 40),
                cancellation: CancellationToken()
            ).unavailableReason == .executableDrift,
            "gh executable identity race was not refused"
        )
    }

    private static func testLifecycleInventory(
        testExecutable: String
    ) throws {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "inventory-repo"
        )
        defer { fixture.remove() }
        let noStaleInventory =
            try fixture.authorizedInventory(
            executable: testExecutable
        )
        try check(
            noStaleInventory.cards.allSatisfy {
                $0.maintenanceRefusals.isEmpty
                    && (
                        $0.maintenanceDiagnostics
                            ?? []
                    ).isEmpty
            },
            "R01 rendered unavailable Repair with no stale registration"
        )
        let exclude = fixture.temporary.path + "/global-excludes"
        try Data("ignored.txt\n".utf8).write(
            to: URL(fileURLWithPath: exclude)
        )
        try fixture.git([
            "config", "core.excludesfile", exclude,
        ])
        try fixture.git(["branch", "feature"])
        try fixture.git([
            "branch", "--set-upstream-to=origin/main",
            "feature",
        ])
        let featurePath = fixture.workRoot + "/inventory-feature"
        let detachedPath = fixture.workRoot + "/inventory-detached"
        try fixture.git([
            "worktree", "add", "--quiet",
            featurePath, "feature",
        ])
        try fixture.git([
            "worktree", "add", "--quiet", "--detach",
            detachedPath, "HEAD",
        ])
        try Data("primary changed\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repositoryPath)
                .appendingPathComponent("value.txt")
        )
        try Data("untracked\n".utf8).write(
            to: URL(fileURLWithPath: featurePath)
                .appendingPathComponent("untracked.txt")
        )
        try Data("ignored\n".utf8).write(
            to: URL(fileURLWithPath: featurePath)
                .appendingPathComponent("ignored.txt")
        )
        try fixture.gitAt(
            featurePath,
            ["update-index", "--skip-worktree", "value.txt"]
        )
        let featureOID = try fixture.gitText([
            "rev-parse", "refs/heads/feature",
        ])
        let record = try PullRequestRecord(
            number: 12,
            url:
                "https://github.com/owner/inventory-repo/pull/12",
            repositoryID: "owner/inventory-repo",
            state: .open,
            headRefName: "feature",
            headRefOID: featureOID,
            isCrossRepository: false,
            updatedAt: WallClock.timestamp(),
            closedAt: nil,
            mergedAt: nil
        )
        let inventory = try fixture.cleanupInventory(
            executable: testExecutable,
            pullRequestLookup: FixturePullRequestLookup(
                branch: "feature",
                result: PullRequestLookupResult(
                    records: [record],
                    unavailableReason: nil
                )
            )
        )
        let clone = try require(
            inventory.cards.first?.clones.first {
                $0.primaryRoot == fixture.repositoryPath
            },
            "lifecycle clone inventory is missing"
        )
        let primary = try require(
            clone.worktrees.first(where: \.isPrimary),
            "primary worktree inventory is missing"
        )
        let feature = try require(
            clone.worktrees.first {
                $0.path == featurePath
            },
            "feature worktree inventory is missing"
        )
        let detached = try require(
            clone.worktrees.first {
                $0.path == detachedPath
            },
            "detached worktree inventory is missing"
        )
        let branch = try require(
            clone.branches.first {
                $0.fullRef == "refs/heads/feature"
            },
            "feature branch inventory is missing"
        )
        let inventoryChecks: [(String, Bool)] = [
            ("worktree count", clone.worktrees.count == 3),
            ("primary tracked changes", primary.fileState?.trackedChanges == 1),
            ("feature untracked files", feature.fileState?.untrackedFiles == 1),
            ("feature ignored files", feature.fileState?.ignoredFiles == 1),
            ("feature hidden index", feature.fileState?.hiddenIndexState == true),
            ("detached commit", detached.detachedOID != nil),
            ("detached branch absence", detached.attachedBranchRef == nil),
            ("feature default relation", feature.relationToDefault?.kind == .equal),
            ("feature commit date", feature.tipCommitDate != nil),
            ("detached default relation", detached.relationToDefault?.kind == .equal),
            ("detached commit date", detached.tipCommitDate != nil),
            ("branch claimant", branch.claimingWorktreeIDs == [feature.id]),
            ("branch default relation", branch.relationToDefault?.kind == .equal),
            ("upstream ref", branch.upstream?.fullRef == "refs/remotes/origin/main"),
            ("upstream local commit", branch.upstream?.localOID == featureOID),
            ("upstream remote commit", branch.upstream?.upstreamOID == featureOID),
            ("upstream relation", branch.upstream?.relation == .equal),
            ("branch commit date", branch.commitDate != nil),
            ("pull request", branch.pullRequests == [record]),
            ("purpose", branch.purpose?.purpose == .active),
            ("activity", branch.activity == .recent),
            ("removal dependency", branch.removalPreview?.permission == .dependencyBlocked),
        ]
        let failedChecks = inventoryChecks.filter { !$0.1 }.map { $0.0 }
        try check(
            failedChecks.isEmpty,
            "lifecycle inventory failed: " + failedChecks.joined(separator: ", ")
                + "; warnings: " + clone.warnings.joined(separator: "; ")
        )
    }

    private static func testPrune(
        testExecutable: String
    ) throws {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "prune-repo"
        )
        defer { fixture.remove() }
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        let preservedPath =
            fixture.workRoot + "/preserved-linked"
        try fixture.git([
            "worktree", "add", "--quiet", "-b",
            "preserved-linked", preservedPath,
        ])
        try Data("preserved staged bytes\n".utf8).write(
            to: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("value.txt")
        )
        for index in 0..<512 {
            let name = String(
                format:
                    "preserved-inventory-%04d-%@.txt",
                index,
                String(repeating: "x", count: 48)
            )
            try Data("tracked\n".utf8).write(
                to: URL(fileURLWithPath: preservedPath)
                    .appendingPathComponent(name)
            )
        }
        try fixture.gitAt(
            preservedPath,
            ["add", "--", "."]
        )
        let minimumGeneratedInventoryBytes =
            512 * (
                1 + 1 + 40 + 1 + 6 + 1
                    + "preserved-inventory-0000-.txt"
                        .utf8.count
                    + 48 + 1
            )
        try check(
            minimumGeneratedInventoryBytes > 16_384
                && minimumGeneratedInventoryBytes
                    < DescriptorProcessRunner
                        .completeRepositoryOutputLimit,
            "R01 preservation fixture did not cross the legacy output cap"
        )
        try Data("preserved untracked bytes\n".utf8).write(
            to: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("untracked.txt")
        )
        let preservedIndexPath = try fixture.gitTextAt(
            preservedPath,
            ["rev-parse", "--git-path", "index"]
        )
        let preservedIndexBefore = try Data(
            contentsOf: URL(
                fileURLWithPath: preservedIndexPath
            )
        )
        let preservedValueBefore = try Data(
            contentsOf: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("value.txt")
        )
        let preservedUntrackedBefore = try Data(
            contentsOf: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("untracked.txt")
        )
        let preservedRefBefore = try fixture.gitText([
            "rev-parse", "refs/heads/preserved-linked",
        ])
        let stalePath = fixture.workRoot + "/stale-old"
        let secondStalePath =
            fixture.workRoot + "/second-stale-old"
        try fixture.git(["branch", "stale"])
        try fixture.git(["branch", "second-stale"])
        try fixture.git([
            "worktree", "add", "--quiet",
            stalePath, "stale",
        ])
        try fixture.git([
            "worktree", "add", "--quiet",
            secondStalePath, "second-stale",
        ])
        let staleOID = try fixture.gitText([
            "rev-parse", "refs/heads/stale",
        ])
        let secondStaleOID = try fixture.gitText([
            "rev-parse", "refs/heads/second-stale",
        ])
        try FileManager.default.removeItem(atPath: stalePath)
        try FileManager.default.removeItem(
            atPath: secondStalePath
        )
        let hookLog = fixture.temporary.path + "/prune-hook.log"
        try fixture.installHook(
            "reference-transaction",
            logPath: hookLog,
            exitStatus: 1
        )
        let inventory = try fixture.cleanupInventory(
            executable: testExecutable
        )
        let operation = try require(
            inventory.selectableOperations.first {
                $0.kind == .repairPruneRegistrations
            },
            "R01 operation was not discovered: "
                + (
                    inventory.cards.first?
                        .maintenanceRefusals.joined(
                            separator: " | "
                        ) ?? "no card"
                )
                + " branches="
                + (
                    inventory.cards.first?.clones.first?
                        .branches.map {
                            "\($0.fullRef)=\($0.tipOID ?? "nil")"
                        }.joined(separator: ",") ?? "none"
                )
        )
        guard case let .prune(items)? =
                operation.maintenanceEvidence else {
            throw Body2SelfTestError.message(
                "R01 evidence is missing"
            )
        }
        try check(
            operation.target.canonicalClone.sourceSnapshot
                .linkedWorktrees.isEmpty
                && operation.target.canonicalClone.worktrees
                    .contains {
                        $0.path == preservedPath
                            && $0.verification == .verified
                    },
            "R01 fixture did not preserve immutable clone evidence independently of the source snapshot"
        )
        try check(
            items.count == 2
                && Set(items.map(\.branchRef)) == Set([
                    "refs/heads/stale",
                    "refs/heads/second-stale",
                ])
                && items.allSatisfy {
                    $0.branchOID == staleOID
                        && $0.branchOID == secondStaleOID
                },
            "R01 did not bind exact registration and ref evidence"
        )
        let subsetOperation = try PlannedOperation(
            kind: .repairPruneRegistrations,
            target: operation.target,
            maintenanceEvidence: .prune([items[0]])
        )
        let subsetResult = try fixture.execute(
            subsetOperation,
            executable: testExecutable
        )
        try check(
            subsetResult.code == .failedInspection
                && FileManager.default.fileExists(
                    atPath:
                        fixture.repositoryPath + "/.git/worktrees/"
                            + items[0].registrationID
                )
                && FileManager.default.fileExists(
                    atPath:
                        fixture.repositoryPath + "/.git/worktrees/"
                            + items[1].registrationID
                ),
            "R01 admitted an unselected item from Git's exact prune set"
        )
        let audit = CommandAudit()
        let defaultOIDBefore = try fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        let primaryBytesBefore = try Data(
            contentsOf: URL(
                fileURLWithPath: fixture.repositoryPath
            ).appendingPathComponent("value.txt")
        )
        let execution = try fixture.execute(
            operation,
            executable: testExecutable,
            audit: audit
        )
        let preservedStaleOID = try fixture.gitText([
            "rev-parse", "refs/heads/stale",
        ])
        let defaultOIDAfter = try fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        let primaryBytesAfter = try Data(
            contentsOf: URL(
                fileURLWithPath: fixture.repositoryPath
            ).appendingPathComponent("value.txt")
        )
        let preservedIndexAfter = try Data(
            contentsOf: URL(
                fileURLWithPath: preservedIndexPath
            )
        )
        let preservedValueAfter = try Data(
            contentsOf: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("value.txt")
        )
        let preservedUntrackedAfter = try Data(
            contentsOf: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("untracked.txt")
        )
        let preservedRefAfter = try fixture.gitText([
            "rev-parse", "refs/heads/preserved-linked",
        ])
        try check(
            execution.code == .updated
                && execution.mainUpdated
                && preservedStaleOID == staleOID,
            "R01 did not preserve the branch ref: "
                + "\(execution.code.rawValue) "
                + (execution.technicalDetail ?? execution.explanation)
                + " before=\(staleOID) after=\(preservedStaleOID)"
        )
        try check(
            defaultOIDAfter == defaultOIDBefore
                && primaryBytesAfter == primaryBytesBefore
                && preservedIndexAfter
                    == preservedIndexBefore
                && preservedValueAfter
                    == preservedValueBefore
                && preservedUntrackedAfter
                    == preservedUntrackedBefore
                && preservedRefAfter
                    == preservedRefBefore,
            "R01 changed the unrelated default or preserved linked worktree bytes, index, or ref"
        )
        let actions = audit.invocations.filter {
            $0.arguments.contains("prune")
                && !$0.arguments.contains("--dry-run")
        }
        try check(
            actions.count == 1
                && actions[0].arguments.suffix(4)
                    == [
                        "worktree", "prune",
                        "--verbose", "--expire=now",
                    ]
                && !FileManager.default.fileExists(
                    atPath: stalePath
                )
                && !FileManager.default.fileExists(
                    atPath: secondStalePath
                ),
            "R01 action count or absent path postflight is wrong"
        )
        try check(
            !FileManager.default.fileExists(atPath: hookLog),
            "R01 invoked an unsupported reference hook"
        )
        try FileManager.default.removeItem(
            atPath:
                fixture.repositoryPath
                    + "/.git/hooks/reference-transaction"
        )

        let racePath = fixture.workRoot + "/race-old"
        try fixture.git(["branch", "race"])
        try fixture.git([
            "worktree", "add", "--quiet",
            racePath, "race",
        ])
        try FileManager.default.removeItem(atPath: racePath)
        let racedInventory = try fixture.cleanupInventory(
            executable: testExecutable
        )
        let racedOperation = try require(
            racedInventory.selectableOperations.first {
                $0.kind == .repairPruneRegistrations
            },
            "R01 race operation was not discovered"
        )
        let common = fixture.repositoryPath + "/.git"
        let reappeared = LockedFlag()
        let reappearedResult = try fixture.execute(
            racedOperation,
            executable: testExecutable,
            maintenanceBeforeAction: { kind, _ in
                guard kind == .repairPruneRegistrations,
                      reappeared.setOnce() else {
                    return
                }
                try? FileManager.default.createDirectory(
                    atPath: racePath,
                    withIntermediateDirectories: false
                )
            }
        )
        try check(
            reappearedResult.code == .failedInspection
                && FileManager.default.fileExists(
                    atPath: racePath
                ),
            "R01 did not refuse a reappeared worktree root"
        )
        try FileManager.default.removeItem(
            atPath: racePath
        )

        let raceOID = try fixture.gitText([
            "rev-parse", "refs/heads/race",
        ])
        let changedRef = LockedFlag()
        let changedRefResult = try fixture.execute(
            racedOperation,
            executable: testExecutable,
            maintenanceBeforeAction: { kind, _ in
                guard kind == .repairPruneRegistrations,
                      changedRef.setOnce() else {
                    return
                }
                try? Data(
                    "\(String(repeating: "0", count: 40))\n".utf8
                ).write(
                    to: URL(fileURLWithPath: common)
                        .appendingPathComponent(
                            "refs/heads/race"
                        )
                )
            }
        )
        try check(
            changedRefResult.code == .failedInspection,
            "R01 did not refuse branch-ref drift"
        )
        try Data("\(raceOID)\n".utf8).write(
            to: URL(fileURLWithPath: common)
                .appendingPathComponent(
                    "refs/heads/race"
                )
        )

        let preservationAudit = CommandAudit()
        let changedPreservedState = LockedFlag()
        let changedPreservedResult = try fixture.execute(
            racedOperation,
            executable: testExecutable,
            audit: preservationAudit,
            maintenanceBeforeAction: { kind, _ in
                guard kind == .repairPruneRegistrations,
                      changedPreservedState.setOnce() else {
                    return
                }
                try? Data(
                    "preserved pre-mutation drift\n".utf8
                ).write(
                    to: URL(fileURLWithPath: preservedPath)
                        .appendingPathComponent("value.txt")
                )
            }
        )
        let preservationActions =
            preservationAudit.invocations.filter {
                $0.arguments.contains("prune")
                    && !$0.arguments.contains("--dry-run")
            }
        try check(
            changedPreservedResult.code == .failedInspection
                && !changedPreservedResult.mainUpdated
                && preservationActions.isEmpty
                && FileManager.default.fileExists(
                    atPath:
                        common + "/worktrees/"
                            + (try requirePruneID(
                                racedOperation
                            ))
                ),
            "R01 mutated before refusing preserved-worktree drift"
        )
        try preservedValueBefore.write(
            to: URL(fileURLWithPath: preservedPath)
                .appendingPathComponent("value.txt")
        )

        let injected = LockedFlag()
        let racedResult = try fixture.execute(
            racedOperation,
            executable: testExecutable,
            maintenanceBeforeAction: { kind, _ in
                guard kind == .repairPruneRegistrations,
                      injected.setOnce() else {
                    return
                }
                let source = common + "/worktrees/"
                    + (try! requirePruneID(racedOperation))
                let destination =
                    common + "/worktrees/injected"
                try? FileManager.default.copyItem(
                    atPath: source,
                    toPath: destination
                )
            }
        )
        try check(
            racedResult.code == .failedInspection
                && !racedResult.mainUpdated,
            "R01 final exact-set drift was not refused"
        )

        let activeFixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "prune-active-repo"
        )
        defer { activeFixture.remove() }
        _ = try activeFixture.authorizedInventory(
            executable: testExecutable
        )
        let activePath =
            activeFixture.workRoot + "/active-stale"
        try activeFixture.git(["branch", "active-stale"])
        try activeFixture.git([
            "worktree", "add", "--quiet",
            activePath, "active-stale",
        ])
        try FileManager.default.removeItem(
            atPath: activePath
        )
        let activeRecord = try activeFixture.installActiveRoot(
            for: activePath,
            branch: "active-stale"
        )
        let activeInventory =
            try activeFixture.inventory(
                executable: testExecutable
            )
        try check(
            !activeInventory.selectableOperations.contains {
                $0.kind == .repairPruneRegistrations
            },
            "R01 offered Repair despite active AWA heartbeat evidence"
        )
        try FileManager.default.removeItem(
            atPath: activeRecord
        )
        try activeFixture.git(["branch", "primary-feature"])
        try activeFixture.git([
            "checkout", "--quiet", "primary-feature",
        ])
        let defaultPath =
            activeFixture.workRoot + "/default-stale"
        try activeFixture.git([
            "worktree", "add", "--quiet",
            defaultPath, "main",
        ])
        try FileManager.default.removeItem(
            atPath: defaultPath
        )
        let detachedPath =
            activeFixture.workRoot + "/detached-stale"
        try activeFixture.git([
            "worktree", "add", "--detach", "--quiet",
            detachedPath, "main",
        ])
        try FileManager.default.removeItem(
            atPath: detachedPath
        )
        let unknownPath =
            activeFixture.workRoot + "/unknown-stale"
        try activeFixture.git(["branch", "unknown-stale"])
        try activeFixture.git([
            "worktree", "add", "--quiet",
            unknownPath, "unknown-stale",
        ])
        try FileManager.default.removeItem(
            atPath: unknownPath
        )
        try activeFixture.git([
            "update-ref", "-d",
            "refs/heads/unknown-stale",
        ])
        let lockedPath =
            activeFixture.workRoot + "/locked-stale"
        try activeFixture.git(["branch", "locked-stale"])
        try activeFixture.git([
            "worktree", "add", "--quiet",
            lockedPath, "locked-stale",
        ])
        try activeFixture.git([
            "worktree", "lock", lockedPath,
        ])
        try FileManager.default.removeItem(
            atPath: lockedPath
        )
        let excludedInventory =
            try activeFixture.inventory(
                executable: testExecutable
            )
        try check(
            !excludedInventory.selectableOperations.contains {
                $0.kind == .repairPruneRegistrations
            }
                && excludedInventory.cards.contains {
                    !$0.maintenanceRefusals.isEmpty
                }
                && (try activeFixture.gitText([
                    "worktree", "list", "--porcelain",
                ])).contains("locked"),
            "R01 offered generic Repair for default, detached, unknown, or locked claims"
        )

        let copyFixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "repair-copy-repo"
        )
        defer { copyFixture.remove() }
        _ = try copyFixture.authorizedInventory(
            executable: testExecutable
        )
        let branchBackedPath =
            copyFixture.workRoot + "/branch-backed-stale"
        try copyFixture.git(["branch", "branch-backed-stale"])
        try copyFixture.git([
            "worktree", "add", "--quiet",
            branchBackedPath, "branch-backed-stale",
        ])
        try FileManager.default.removeItem(
            atPath: branchBackedPath
        )
        let copyDetachedPath =
            copyFixture.workRoot + "/detached-stale"
        try copyFixture.git([
            "worktree", "add", "--detach", "--quiet",
            copyDetachedPath, "main",
        ])
        try FileManager.default.removeItem(
            atPath: copyDetachedPath
        )
        let copyInventory = try copyFixture.inventory(
            executable: testExecutable
        )
        let copyCard = try require(
            copyInventory.cards.first,
            "R01 mixed stale card is missing"
        )
        let publicCopy =
            copyCard.maintenanceRefusals.joined(
                separator: " "
            )
        let diagnosticCopy =
            (copyCard.maintenanceDiagnostics ?? [])
                .joined(separator: " ")
        try check(
            !copyInventory.selectableOperations.contains {
                $0.kind == .repairPruneRegistrations
            }
                && publicCopy ==
                    "Repair unavailable: 1 of 2 stale registrations is detached and cannot be safely removed. Nothing will be changed."
                && !publicCopy.contains("detached-stale")
                && diagnosticCopy.contains(
                    "HEAD is detached"
                )
                && diagnosticCopy.contains(
                    "detached-stale"
                ),
            "R01 mixed stale Repair copy, diagnostics, or safety boundary changed"
        )
        try check(
            RepositoryMaintenancePlanner
                .unavailableRepairMessage(
                    total: 3,
                    unproven: 2,
                    detached: 1
                )
                == "Repair unavailable: 2 of 3 stale registrations cannot be safely removed; 1 is detached and 1 lacks independent proof. Nothing will be changed."
                && RepositoryMaintenancePlanner
                    .unavailableRepairMessage(
                        total: 2,
                        unproven: 2,
                        detached: 0
                    )
                    == "Repair unavailable: 2 of 2 stale registrations cannot be independently proven safe to remove. Nothing will be changed."
                && RepositoryMaintenancePlanner
                    .unavailableRepairMessage(
                        total: 1,
                        unproven: 1,
                        detached: 1
                    )
                    == "Repair unavailable: 1 of 1 stale registration is detached and cannot be safely removed. Nothing will be changed.",
            "R01 Repair-unavailable count or pluralization matrix changed"
        )
    }

    private static func testMovedRepair(
        testExecutable: String
    ) throws {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "moved-repo"
        )
        defer { fixture.remove() }
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        let oldPath = fixture.workRoot + "/moved-old"
        let newPath = fixture.workRoot + "/moved-new"
        try fixture.git(["branch", "moved"])
        try fixture.git([
            "worktree", "add", "--quiet",
            oldPath, "moved",
        ])
        try FileManager.default.moveItem(
            atPath: oldPath,
            toPath: newPath
        )
        let exclude = fixture.temporary.path + "/moved-excludes"
        try Data("ignored.txt\n".utf8).write(
            to: URL(fileURLWithPath: exclude)
        )
        try fixture.git([
            "config", "core.excludesfile", exclude,
        ])
        try Data("ignored payload\n".utf8).write(
            to: URL(fileURLWithPath: newPath)
                .appendingPathComponent("ignored.txt")
        )
        let hookLog = fixture.temporary.path + "/repair-hook.log"
        try fixture.installHook(
            "reference-transaction",
            logPath: hookLog,
            exitStatus: 1
        )
        let inventory = try fixture.cleanupInventory(
            executable: testExecutable
        )
        let operation = try require(
            inventory.selectableOperations.first {
                $0.kind == .repairMovedWorktree
            },
            "R02 operation was not discovered"
        )
        guard case let .repairMoved(evidence)? =
                operation.maintenanceEvidence else {
            throw Body2SelfTestError.message(
                "R02 evidence is missing"
            )
        }
        try check(
            evidence.previousPath == oldPath
                && evidence.verifiedPath == newPath
                && evidence.branchRef == "refs/heads/moved",
            "R02 candidate evidence is not exact"
        )
        let before = try fixture.gitText([
            "rev-parse", "refs/heads/moved",
        ])
        let defaultBefore = try fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        let registrationPath =
            fixture.repositoryPath + "/.git/worktrees/"
                + evidence.registrationID
        let indexBefore = try Data(
            contentsOf: URL(
                fileURLWithPath: registrationPath
            ).appendingPathComponent("index")
        )
        let valueBefore = try Data(
            contentsOf: URL(fileURLWithPath: newPath)
                .appendingPathComponent("value.txt")
        )
        let ignoredBefore = try Data(
            contentsOf: URL(fileURLWithPath: newPath)
                .appendingPathComponent("ignored.txt")
        )
        let audit = CommandAudit()
        let result = try fixture.execute(
            operation,
            executable: testExecutable,
            audit: audit
        )
        let list = try fixture.gitText([
            "worktree", "list", "--porcelain",
        ])
        let preservedMovedOID = try fixture.gitText([
            "rev-parse", "refs/heads/moved",
        ])
        let defaultAfter = try fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        let indexAfter = try Data(
            contentsOf: URL(
                fileURLWithPath: registrationPath
            ).appendingPathComponent("index")
        )
        let valueAfter = try Data(
            contentsOf: URL(fileURLWithPath: newPath)
                .appendingPathComponent("value.txt")
        )
        let ignoredAfter = try Data(
            contentsOf: URL(fileURLWithPath: newPath)
                .appendingPathComponent("ignored.txt")
        )
        try check(
            result.code == .updated
                && list.contains("worktree \(newPath)")
                && !list.contains("worktree \(oldPath)")
                && preservedMovedOID == before
                && defaultAfter == defaultBefore
                && indexAfter == indexBefore
                && valueAfter == valueBefore
                && ignoredAfter == ignoredBefore,
            "R02 did not reconnect exactly one preserved worktree: "
                + "\(result.code.rawValue) "
                + (result.technicalDetail ?? result.explanation)
                + " list=\(list)"
        )
        let repairActions = audit.invocations.filter {
            $0.arguments.contains("repair")
        }
        try check(
            repairActions.count == 1
                && repairActions[0].arguments.suffix(3)
                    == ["worktree", "repair", newPath]
                && !repairActions[0].arguments.contains("--force"),
            "R02 command was repeated or widened"
        )
        try check(
            !FileManager.default.fileExists(atPath: hookLog),
            "R02 invoked an unsupported reference hook"
        )
        try FileManager.default.removeItem(
            atPath:
                fixture.repositoryPath
                    + "/.git/hooks/reference-transaction"
        )

        let dirtyOld = fixture.workRoot + "/dirty-old"
        let dirtyNew = fixture.workRoot + "/dirty-new"
        try fixture.git(["branch", "dirty"])
        try fixture.git([
            "worktree", "add", "--quiet",
            dirtyOld, "dirty",
        ])
        try FileManager.default.moveItem(
            atPath: dirtyOld,
            toPath: dirtyNew
        )
        try Data("dirty\n".utf8).write(
            to: URL(fileURLWithPath: dirtyNew)
                .appendingPathComponent("dirty.txt")
        )
        let dirtyInventory = try fixture.cleanupInventory(
            executable: testExecutable
        )
        try check(
            !dirtyInventory.selectableOperations.contains {
                guard $0.kind == .repairMovedWorktree,
                      case let .repairMoved(item)? =
                        $0.maintenanceEvidence else {
                    return false
                }
                return item.verifiedPath == dirtyNew
            },
            "dirty moved worktree became a Repair suggestion"
        )

        let hiddenOld = fixture.workRoot + "/hidden-old"
        let hiddenNew = fixture.workRoot + "/hidden-new"
        try fixture.git(["branch", "hidden"])
        try fixture.git([
            "worktree", "add", "--quiet",
            hiddenOld, "hidden",
        ])
        try FileManager.default.moveItem(
            atPath: hiddenOld,
            toPath: hiddenNew
        )
        try fixture.gitAt(
            hiddenNew,
            ["update-index", "--skip-worktree", "value.txt"]
        )
        let hiddenInventory = try fixture.cleanupInventory(
            executable: testExecutable
        )
        try check(
            !hiddenInventory.selectableOperations.contains {
                guard $0.kind == .repairMovedWorktree,
                      case let .repairMoved(item)? =
                        $0.maintenanceEvidence else {
                    return false
                }
                return item.verifiedPath == hiddenNew
            },
            "hidden-index moved worktree became a Repair suggestion"
        )

        let activeFixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "moved-active-repo"
        )
        defer { activeFixture.remove() }
        _ = try activeFixture.authorizedInventory(
            executable: testExecutable
        )
        let activeOld =
            activeFixture.workRoot + "/active-old"
        let activeNew =
            activeFixture.workRoot + "/active-new"
        try activeFixture.git(["branch", "active"])
        try activeFixture.git([
            "worktree", "add", "--quiet",
            activeOld, "active",
        ])
        try FileManager.default.moveItem(
            atPath: activeOld,
            toPath: activeNew
        )
        let activeExcludes =
            activeFixture.temporary.path + "/active-excludes"
        try Data("ignored.txt\n".utf8).write(
            to: URL(fileURLWithPath: activeExcludes)
        )
        try activeFixture.git([
            "config", "core.excludesfile", activeExcludes,
        ])
        try Data("preview bytes\n".utf8).write(
            to: URL(fileURLWithPath: activeNew)
                .appendingPathComponent("ignored.txt")
        )
        let activeRecord = try activeFixture
            .installActiveRoot(
                for: activeNew,
                branch: "active"
            )
        try check(
            !(try activeFixture.inventory(
                executable: testExecutable
            )).selectableOperations.contains {
                $0.kind == .repairMovedWorktree
            },
            "R02 offered Repair despite active AWA heartbeat evidence"
        )
        try FileManager.default.removeItem(
            atPath: activeRecord
        )
        let unlocked = try activeFixture.inventory(
            executable: testExecutable
        )
        try check(
            unlocked.selectableOperations.contains {
                $0.kind == .repairMovedWorktree
            },
            "R02 treated a released or absent common lock as held"
        )
        let common = activeFixture.repositoryPath + "/.git"
        let lockPath = sharedLockPath(
            home: activeFixture.home,
            commonDirectory: common
        )
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: lockPath)
                .deletingLastPathComponent().path,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ]
        )
        let lockDescriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC,
            0o600
        )
        guard lockDescriptor >= 0,
              flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            if lockDescriptor >= 0 {
                close(lockDescriptor)
            }
            throw Body2SelfTestError.message(
                "could not hold R02 common lock"
            )
        }
        var lockIsOpen = true
        defer {
            if lockIsOpen {
                _ = flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
        }
        let locked = try activeFixture.inventory(
            executable: testExecutable
        )
        _ = flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockIsOpen = false
        let released = try activeFixture.inventory(
            executable: testExecutable
        )
        try check(
            !locked.selectableOperations.contains {
                $0.kind == .repairMovedWorktree
            }
                && released.selectableOperations.contains {
                    $0.kind == .repairMovedWorktree
                },
            "R02 offered Repair while the common lock was held"
        )
        let previewDriftOperation = try require(
            released.selectableOperations.first {
                $0.kind == .repairMovedWorktree
            },
            "R02 payload-drift operation is missing"
        )
        try Data("changed preview bytes\n".utf8).write(
            to: URL(fileURLWithPath: activeNew)
                .appendingPathComponent("ignored.txt")
        )
        let payloadAudit = CommandAudit()
        let previewDriftResult = try activeFixture.execute(
            previewDriftOperation,
            executable: testExecutable,
            audit: payloadAudit
        )
        try check(
            previewDriftResult.code == .failedInspection
                && !payloadAudit.invocations.contains {
                    $0.arguments.contains("repair")
                },
            "R02 payload drift after preview reached the Git action"
        )
        try Data("preview bytes\n".utf8).write(
            to: URL(fileURLWithPath: activeNew)
                .appendingPathComponent("ignored.txt")
        )
        let moveRaceInventory = try activeFixture.inventory(
            executable: testExecutable
        )
        let moveRaceOperation = try require(
            moveRaceInventory.selectableOperations.first {
                $0.kind == .repairMovedWorktree
            },
            "R02 move-race operation is missing"
        )
        let racedPath =
            activeFixture.workRoot + "/active-raced"
        let movedOnce = LockedFlag()
        let raceAudit = CommandAudit()
        let moveRaceResult = try activeFixture.execute(
            moveRaceOperation,
            executable: testExecutable,
            audit: raceAudit,
            maintenanceBeforeAction: { kind, _ in
                guard kind == .repairMovedWorktree,
                      movedOnce.setOnce() else {
                    return
                }
                try? FileManager.default.moveItem(
                    atPath: activeNew,
                    toPath: racedPath
                )
            }
        )
        try check(
            moveRaceResult.code == .failedInspection
                && !raceAudit.invocations.contains {
                    $0.arguments.contains("repair")
                },
            "R02 concurrent path move reached the Git action"
        )

        let postFixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "moved-postflight-repo"
        )
        defer { postFixture.remove() }
        _ = try postFixture.authorizedInventory(
            executable: testExecutable
        )
        let postOld = postFixture.workRoot + "/post-old"
        let postNew = postFixture.workRoot + "/post-new"
        try postFixture.git(["branch", "post"])
        try postFixture.git([
            "worktree", "add", "--quiet",
            postOld, "post",
        ])
        try FileManager.default.moveItem(
            atPath: postOld,
            toPath: postNew
        )
        let postOperation = try require(
            try postFixture.inventory(
                executable: testExecutable
            ).selectableOperations.first {
                $0.kind == .repairMovedWorktree
            },
            "R02 postflight operation is missing"
        )
        let changedAfterAction = LockedFlag()
        let postResult = try postFixture.execute(
            postOperation,
            executable: testExecutable,
            maintenanceAfterAction: { kind, _ in
                guard kind == .repairMovedWorktree,
                      changedAfterAction.setOnce() else {
                    return
                }
                try? Data("external change\n".utf8).write(
                    to: URL(fileURLWithPath: postNew)
                        .appendingPathComponent(
                            "postflight.txt"
                        )
                )
            }
        )
        try check(
            postResult.code == .needsAttention
                && !postResult.mainUpdated,
            "R02 postcondition mismatch was not reported as Needs Attention"
        )
    }

    private static func testOriginHeadExplanation(
        testExecutable: String
    ) throws {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "origin-head-repo"
        )
        defer { fixture.remove() }
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        try fixture.git([
            "symbolic-ref", "-d",
            "refs/remotes/origin/HEAD",
        ], allowFailure: true)
        let card = try require(
            try fixture.inventory(
                executable: testExecutable
            ).cards.first,
            "R03 card is missing"
        )
        try check(
            card.originHeadExplanation?
                .contains("no repair is needed") == true
                && !card.maintenanceOperations.contains {
                    $0.id.lowercased().contains("origin")
                },
            "R03 created a repair or omitted exact explanation"
        )
        try fixture.git([
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/not-main",
        ])
        let staleCard = try require(
            try fixture.inventory(
                executable: testExecutable
            ).cards.first,
            "R03 stale card is missing"
        )
        let localOriginHead = try fixture.gitText([
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
        ])
        try check(
            staleCard.originHeadExplanation?
                .contains("no repair is needed") == true
                && localOriginHead
                    == "refs/remotes/origin/not-main"
                && !staleCard.maintenanceOperations.contains {
                    $0.id.lowercased().contains("origin")
                },
            "R03 stale origin/HEAD was mutated or became an operation"
        )
    }

    private static func testInitialize(
        testExecutable: String,
        objectFormat: String
    ) throws {
        let fixture: Body2Fixture
        do {
            fixture = try Body2Fixture(
                objectFormat: objectFormat,
                repositoryName: "init-\(objectFormat)"
            )
        } catch {
            if objectFormat == "sha256",
               String(describing: error)
                .localizedCaseInsensitiveContains("unknown") {
                return
            }
            throw error
        }
        defer { fixture.remove() }
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        try fixture.git(["branch", "feature"])
        try fixture.git(["checkout", "--quiet", "feature"])
        try fixture.git(["branch", "-D", "main"])
        let beforeBranch = try fixture.gitText([
            "symbolic-ref", "--short", "HEAD",
        ])
        let beforeStatus = try fixture.gitData([
            "status", "--porcelain=v1", "-z",
            "--untracked-files=all",
        ])
        let inventory = try fixture.inventory(
            executable: testExecutable
        )
        let operation = try require(
            inventory.selectableOperations.first {
                $0.kind == .initializeDefaultBranch
            },
            "R04 operation was not discovered"
        )
        try check(
            operation.target.expectedLocalOID == nil
                && operation.target.mode == .initializeAbsent,
            "R04 was not modeled as explicit Initialize"
        )
        let audit = CommandAudit()
        let result = try fixture.execute(
            operation,
            executable: testExecutable,
            audit: audit
        )
        let localMain = try fixture.gitText([
            "rev-parse", "refs/heads/main",
        ])
        let remoteMain = try fixture.gitText([
            "rev-parse", "refs/remotes/origin/main",
        ])
        let afterBranch = try fixture.gitText([
            "symbolic-ref", "--short", "HEAD",
        ])
        let afterStatus = try fixture.gitData([
            "status", "--porcelain=v1", "-z",
            "--untracked-files=all",
        ])
        try check(
            result.code == .updated
                && result.mainUpdated
                && localMain == remoteMain
                && localMain.count
                    == (objectFormat == "sha256" ? 64 : 40)
                && afterBranch == beforeBranch
                && afterStatus == beforeStatus,
            "R04 changed checkout/index/worktree or initialized the wrong OID"
        )
        let updateActions = audit.invocations.filter {
            $0.arguments.contains("update-ref")
        }
        try check(
            updateActions.count == 1
                && updateActions[0].arguments.suffix(4)
                    == [
                        "update-ref",
                        "refs/heads/main",
                        localMain,
                        String(
                            repeating: "0",
                            count: objectFormat == "sha256"
                                ? 64 : 40
                        ),
                    ]
                && !audit.invocations.contains {
                    $0.arguments.contains("checkout")
                        || $0.arguments.contains("switch")
                },
            "R04 command grammar widened or switched a worktree"
        )
        if objectFormat == "sha1" {
            try testInitializeRefusals(
                testExecutable: testExecutable
            )
        }
    }

    private static func testInitializeRefusals(
        testExecutable: String
    ) throws {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "init-refusals"
        )
        defer { fixture.remove() }
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        try fixture.git(["branch", "feature"])
        try fixture.git(["checkout", "--quiet", "feature"])
        try fixture.git(["branch", "-D", "main"])
        let operation = try require(
            try fixture.inventory(
                executable: testExecutable
            ).selectableOperations.first {
                $0.kind == .initializeDefaultBranch
            },
            "Initialize refusal fixture has no operation"
        )
        let failedCAS = try fixture.execute(
            operation,
            executable: testExecutable,
            finalMutationOnUpdate:
                GitCommandPolicy.syntheticUpdateFailureMarker
        )
        try check(
            failedCAS.code == .failedUpdate
                && !failedCAS.mainUpdated
                && (try? fixture.gitText([
                    "rev-parse", "--verify",
                    "refs/heads/main",
                ])) == nil,
            "Initialize CAS failure was retried or misreported"
        )
        let target = operation.target.expectedFetchedOID
        let common = fixture.repositoryPath + "/.git"
        let competing = try fixture.execute(
            operation,
            executable: testExecutable,
            maintenanceBeforeAction: { kind, _ in
                guard kind == .initializeDefaultBranch else {
                    return
                }
                try? Data("\(target)\n".utf8).write(
                    to: URL(fileURLWithPath: common)
                        .appendingPathComponent(
                            "refs/heads/main"
                        )
                )
            }
        )
        try check(
            competing.code == .failedInspection
                && !competing.mainUpdated,
            "competing default-ref creation was not refused"
        )
        try fixture.git([
            "update-ref", "-d", "refs/heads/main",
        ])
        try fixture.git([
            "update-ref", "refs/heads/main/topic", target,
        ])
        let namespaceInventory = try fixture.inventory(
            executable: testExecutable
        )
        try check(
            !namespaceInventory.selectableOperations.contains {
                $0.kind == .initializeDefaultBranch
            },
            "conflicting default-ref namespace offered Initialize"
        )
        try fixture.git([
            "update-ref", "-d", "refs/heads/main/topic",
        ])
        let operationLock =
            common + "/index.lock"
        try Data().write(
            to: URL(fileURLWithPath: operationLock)
        )
        let busyInventory = try fixture.inventory(
            executable: testExecutable
        )
        try FileManager.default.removeItem(
            atPath: operationLock
        )
        try check(
            !busyInventory.selectableOperations.contains {
                $0.kind == .initializeDefaultBranch
            },
            "active Git operation offered Initialize"
        )
        let alternate =
            common + "/objects/info/alternates"
        try Data("/private/tmp/untrusted-objects\n".utf8)
            .write(to: URL(fileURLWithPath: alternate))
        let alternateInventory = try fixture.inventory(
            executable: testExecutable
        )
        try FileManager.default.removeItem(
            atPath: alternate
        )
        try check(
            !alternateInventory.selectableOperations.contains {
                $0.kind == .initializeDefaultBranch
            },
            "object alternate ambiguity offered Initialize"
        )
        _ = try fixture.inventory(executable: testExecutable)
        let lockPath = sharedLockPath(
            home: fixture.home,
            commonDirectory: common
        )
        let lockDescriptor = Darwin.open(
            lockPath,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockDescriptor >= 0,
              flock(
                  lockDescriptor,
                  LOCK_EX | LOCK_NB
              ) == 0 else {
            if lockDescriptor >= 0 {
                close(lockDescriptor)
            }
            throw Body2SelfTestError.message(
                "could not hold shared common-directory lock"
            )
        }
        var lockIsOpen = true
        defer {
            if lockIsOpen {
                _ = flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
        }
        let lockedInventory = try fixture.inventory(
            executable: testExecutable
        )
        _ = flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockIsOpen = false
        let releasedInventory = try fixture.inventory(
            executable: testExecutable
        )
        try check(
            !lockedInventory.selectableOperations.contains {
                $0.kind == .initializeDefaultBranch
            }
                && releasedInventory.selectableOperations.contains {
                    $0.kind == .initializeDefaultBranch
                },
            "held shared common-directory lock offered Initialize"
        )
        let postOperation = try require(
            releasedInventory.selectableOperations.first {
                $0.kind == .initializeDefaultBranch
            },
            "Initialize postflight operation is missing"
        )
        let changedAfterAction = LockedFlag()
        let postResult = try fixture.execute(
            postOperation,
            executable: testExecutable,
            maintenanceAfterAction: { kind, _ in
                guard kind == .initializeDefaultBranch,
                      changedAfterAction.setOnce() else {
                    return
                }
                try? Data("\(target)\n".utf8).write(
                    to: URL(fileURLWithPath: common)
                        .appendingPathComponent(
                            "refs/heads/postflight-race"
                        )
                )
            }
        )
        try check(
            postResult.code == .needsAttention
                && (try? fixture.gitText([
                    "rev-parse", "refs/heads/main",
                ])) == target,
            "Initialize postcondition mismatch was not reported truthfully"
        )
    }

    private static func testHookAndCommandAudit(
        testExecutable: String
    ) throws {
        let forbidden: [[String]] = [
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "worktree", "remove", "/private/tmp/x",
            ],
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "branch", "-D", "feature",
            ],
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "update-ref", "-d", "refs/heads/feature",
            ],
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "remote", "set-head", "origin", "--auto",
            ],
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "--git-dir=/private/tmp/common",
                "worktree", "repair", "--force",
                "/private/tmp/worktree",
            ],
        ]
        for command in forbidden {
            try check(
                throwsError {
                    _ = try GitCommandPolicy.validate(command)
                },
                "cleanup command entered the Body 2 grammar"
            )
        }
        try check(
            PlannedOperationKind.allBody2Cases.map(\.rawValue)
                == [
                    "fastForward",
                    "repairPruneRegistrations",
                    "repairMovedWorktree",
                    "initializeDefaultBranch",
                ]
                && PlannedOperationKind.allBody2Cases.allSatisfy {
                    !$0.rawValue.lowercased().contains("cleanup")
                        && $0.rawValue.lowercased() != "repair"
                },
            "operation enum contains a generic Repair or cleanup mutation"
        )

        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "hook-repo"
        )
        defer { fixture.remove() }
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        try fixture.git(["branch", "feature"])
        try fixture.git(["checkout", "--quiet", "feature"])
        try fixture.git(["branch", "-D", "main"])
        let hookLog = fixture.temporary.path + "/hook.log"
        let hookPath =
            fixture.repositoryPath
                + "/.git/hooks/reference-transaction"
        try Data(
            """
            #!/bin/sh
            payload="$(cat)"
            printf '%s\\n' "$1" >> '\(hookLog)'
            case "$1" in
              prepared|preparing)
                case "$payload" in
                  *" refs/heads/main") exit 1 ;;
                esac
                ;;
            esac
            exit 0
            """.utf8
        ).write(to: URL(fileURLWithPath: hookPath))
        guard chmod(hookPath, 0o700) == 0 else {
            throw Body2SelfTestError.message(
                "could not install fixture hook"
            )
        }
        let hookInventory = try fixture.inventory(
            executable: testExecutable
        )
        let operation = try require(
            hookInventory.selectableOperations.first {
                $0.kind == .initializeDefaultBranch
            },
            "hook Initialize was not discovered: "
                + (
                    String(
                        data: try JSONEncoder().encode(hookInventory),
                        encoding: .utf8
                    ) ?? "<unencodable inventory>"
                )
        )
        let audit = CommandAudit()
        let result = try fixture.execute(
            operation,
            executable: testExecutable,
            audit: audit
        )
        let trace = (try? String(
            contentsOfFile: hookLog,
            encoding: .utf8
        )) ?? ""
        let branchAbsent = (try? fixture.gitText([
            "rev-parse", "--verify",
            "refs/heads/main",
        ])) == nil
        let sawPreparingPhase =
            trace.contains("prepared")
            || trace.contains("preparing")
        let diagnostic = [
            "code=\(result.code.rawValue)",
            "mainUpdated=\(result.mainUpdated)",
            "preparing=\(sawPreparingPhase)",
            "aborted=\(trace.contains("aborted"))",
            "branchAbsent=\(branchAbsent)",
            "explanation=\(result.explanation)",
            "detail=\(result.technicalDetail ?? "<none>")",
            "lastCommands=\(audit.invocations.suffix(5).map(\.arguments))",
        ].joined(separator: " ")
        try check(
            result.code == .failedUpdate
                && !result.mainUpdated
                && sawPreparingPhase
                && trace.contains("aborted")
                && branchAbsent,
            "update-ref hook veto or trace was not truthful "
                + diagnostic
        )
    }

    private static func pullRequest(
        number: Int,
        state: PullRequestState,
        oid: String
    ) throws -> PullRequestRecord {
        try PullRequestRecord(
            number: number,
            url: "https://github.com/owner/repo/pull/\(number)",
            repositoryID: "owner/repo",
            state: state,
            headRefName: "feature",
            headRefOID: oid,
            isCrossRepository: false,
            updatedAt: "2026-09-09T12:00:00Z",
            closedAt: state == .closed
                ? "2026-09-09T12:00:00Z" : nil,
            mergedAt: state == .merged
                ? "2026-09-09T12:00:00Z" : nil
        )
    }

    private static func compileC(
        _ source: String,
        output: String
    ) throws {
        let sourcePath = output + ".c"
        try Data(source.utf8).write(
            to: URL(fileURLWithPath: sourcePath)
        )
        _ = try runProcess(
            executable: "/usr/bin/clang",
            arguments: [sourcePath, "-o", output]
        )
        guard chmod(output, 0o700) == 0 else {
            throw Body2SelfTestError.message(
                "could not protect fake gh executable"
            )
        }
    }

    private static func sharedLockPath(
        home: String,
        commonDirectory: String
    ) -> String {
        let key = String(
            SHA256.hash(
                data: Data(commonDirectory.utf8)
            ).map {
                String(format: "%02x", $0)
            }.joined().prefix(24)
        )
        return home
            + "/.local/state/awa/locks/common-\(key).lock"
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        allowFailure: Bool = false
    ) throws -> Data {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = temporary.path + "/home"
        try FileManager.default.createDirectory(atPath: home,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let directory = Darwin.open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Body2SelfTestError.message("fixture command directory unavailable") }
        defer { close(directory) }
        guard executable == "/usr/bin/clang" else {
            throw Body2SelfTestError.message("unsupported fixture compiler")
        }
        let result = try ClosedProcessRunner(outputLimit: DescriptorProcessRunner.completeRepositoryOutputLimit).run(
            command: ClosedProcessCommand(executable: "/Library/Developer/CommandLineTools/usr/bin/clang",
                arguments: ["-save-temps=obj", "-isysroot", "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"] + arguments),
            environment: ClosedProcessRunner.environment(account: account),
            workingDirectoryDescriptor: directory, account: account, timeout: 20,
            cancellation: CancellationToken())
        guard (allowFailure || result.status == 0) && !result.cancelled && !result.timedOut
                && !result.stdoutTruncated && !result.stderrTruncated else {
            throw Body2SelfTestError.message("fixture command failed: " + Redactor.subprocessBytes(result.output))
        }
        return result.output
    }

    private static func requirePruneID(
        _ operation: PlannedOperation
    ) throws -> String {
        guard case let .prune(items)? =
                operation.maintenanceEvidence,
              items.count == 1 else {
            throw Body2SelfTestError.message(
                "prune operation has no exact ID"
            )
        }
        return items[0].registrationID
    }

    fileprivate static func require<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw Body2SelfTestError.message(message)
        }
        return value
    }

    private static func check(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw Body2SelfTestError.message(message)
        }
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
}

private extension PlannedOperationKind {
    static var allBody2Cases: [PlannedOperationKind] {
        [
            .fastForward,
            .repairPruneRegistrations,
            .repairMovedWorktree,
            .initializeDefaultBranch,
        ]
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        count += 1
        let value = count
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !set else { return false }
        set = true
        return true
    }
}

private final class LookupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PullRequestLookupResult?

    func set(_ value: PullRequestLookupResult) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: PullRequestLookupResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct FixturePullRequestLookup:
    PullRequestLookingUp, Sendable {
    let branch: String
    let result: PullRequestLookupResult

    func lookup(
        repositoryID: String,
        branch: String,
        tipOID: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult {
        cancellation.isCancelled
            ? .unavailable(.cancelled)
            : (branch == self.branch
                ? result
                : PullRequestLookupResult(
                    records: [],
                    unavailableReason: nil
                ))
    }
}

final class Body2Fixture: @unchecked Sendable {
    let temporary: M1TemporaryDirectory
    let workRoot: String
    let repositoryPath: String
    let remotePath: String
    let home: String
    let stateLocation: StateLocation
    let mapping: TransportMapping
    let account: EffectiveAccount

    init(
        objectFormat: String,
        repositoryName: String
    ) throws {
        temporary = try M1TemporaryDirectory()
        home = temporary.path + "/home"
        workRoot = home + "/dev/personal"
        repositoryPath = workRoot + "/\(repositoryName)"
        remotePath = temporary.path + "/\(repositoryName).git"
        try FileManager.default.createDirectory(
            atPath: workRoot,
            withIntermediateDirectories: true
        )
        try Self.installPolicy(home: home)
        var initArguments = [
            "init", "--quiet",
            "--initial-branch=main",
        ]
        if objectFormat == "sha256" {
            initArguments.append("--object-format=sha256")
        }
        try Self.gitProcess(
            initArguments + [repositoryPath]
        )
        try Self.gitProcess([
            "-C", repositoryPath,
            "config", "user.name", "Body 2 Fixture",
        ])
        try Self.gitProcess([
            "-C", repositoryPath,
            "config", "user.email",
            "fixture@example.invalid",
        ])
        try Data("fixture\n".utf8).write(
            to: URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent("value.txt")
        )
        try Self.gitProcess([
            "-C", repositoryPath, "add", "value.txt",
        ])
        try Self.gitProcess([
            "-C", repositoryPath,
            "commit", "--quiet", "-m", "fixture",
        ])
        var bareArguments = [
            "init", "--bare", "--quiet",
            "--initial-branch=main",
        ]
        if objectFormat == "sha256" {
            bareArguments.append("--object-format=sha256")
        }
        try Self.gitProcess(bareArguments + [remotePath])
        let logical =
            "git@github.com:owner/\(repositoryName).git"
        try Self.gitProcess([
            "-C", repositoryPath,
            "remote", "add", "origin", logical,
        ])
        let mappingArgument =
            "url.file://\(remotePath)/.insteadOf=\(logical)"
        try Self.gitProcess([
            "-c", mappingArgument,
            "-C", repositoryPath,
            "push", "--quiet", "-u", "origin", "main",
        ])
        stateLocation = try StateLocation.isolated(
            root: temporary.path
        )
        try TestIsolation.initializeState(at: stateLocation)
        mapping = try TransportMapping(
            logicalURL: logical,
            localRepositoryPath: remotePath,
            containmentRoot: temporary.path
        )
        account = try EffectiveAccount.isolated(
            homeDirectory: home
        )
    }

    func inventory(
        executable: String,
        pullRequestLookup: any PullRequestLookingUp =
            UnavailablePullRequestLookup()
    ) throws -> RepositoryInventory {
        try RepositoryInventoryDiscovery(
            executablePath: executable,
            isolatedRoot: temporary.path,
            transportMapping: mapping,
            pullRequestLookup: pullRequestLookup
        ).discoverInventory()
    }

    // Discovery deliberately defers cleanup details. Older maintenance tests
    // must enter the same authority-checked inspection used by the product;
    // changing the shared inventory helper would hide pre-inspection regressions.
    func cleanupInventory(
        executable: String,
        pullRequestLookup: any PullRequestLookingUp =
            UnavailablePullRequestLookup()
    ) throws -> RepositoryInventory {
        let discovery = try RepositoryInventoryDiscovery(
            executablePath: executable,
            isolatedRoot: temporary.path,
            transportMapping: mapping,
            pullRequestLookup: pullRequestLookup
        )
        let initial = try discovery.discoverInventory()
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
        let initial = try inventory(executable: executable)
        let clone = try V2Body2SelfTestRunner.require(
            initial.cards.first?.clones.first,
            "fixture clone is missing"
        )
        let state = try SecureStateDirectory.open(
            stateLocation
        )
        let store = RepositoryAuthorityStore(state: state)
        _ = try store.confirmOnboarding(
            proposals: [
                CanonicalAuthorityProposal(clone: clone),
            ],
            selectedRepositoryIDs: [clone.repositoryID],
            freshClones: [clone],
            expectedFileIdentity: nil
        )
        return try inventory(executable: executable)
    }

    func execute(
        _ operation: PlannedOperation,
        executable: String,
        audit: CommandAudit? = nil,
        finalMutationOnUpdate: String? = nil,
        maintenanceBeforeAction:
            (@Sendable (
                PlannedOperationKind,
                RepositoryCandidate
            ) -> Void)? = nil,
        maintenanceAfterAction:
            (@Sendable (
                PlannedOperationKind,
                RepositoryCandidate
            ) -> Void)? = nil
    ) throws -> RepositoryResult {
        let authority = try RunAuthority.acquireRun(
            at: stateLocation
        )
        defer { authority.release() }
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let configuration = GitTransactionConfiguration(
            trampolineExecutable: executable,
            operationLeaseDescriptor: lease,
            transportMapping: mapping,
            finalMutationOnUpdate: finalMutationOnUpdate,
            maintenanceBeforeAction:
                maintenanceBeforeAction,
            maintenanceAfterAction:
                maintenanceAfterAction
        )
        return RepositoryMaintenanceTransaction(
            runner: DescriptorProcessRunner(
                audit: audit,
                outputLimit:
                    DescriptorProcessRunner
                        .completeRepositoryOutputLimit
            ),
            configuration: configuration,
            account: account
        ).execute(
            operation: operation,
            cancellation: CancellationToken(),
            phase: { _ in }
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

    func installHook(
        _ name: String,
        logPath: String,
        exitStatus: Int32
    ) throws {
        let hook = repositoryPath + "/.git/hooks/\(name)"
        try Data(
            """
            #!/bin/sh
            printf '%s:%s\\n' '\(name)' "$1" >> '\(logPath)'
            exit \(exitStatus)
            """.utf8
        ).write(to: URL(fileURLWithPath: hook))
        guard chmod(hook, 0o700) == 0 else {
            throw Body2SelfTestError.message(
                "could not install fixture hook"
            )
        }
    }

    func installActiveRoot(
        for worktreePath: String,
        branch: String
    ) throws -> String {
        let roots = home
            + "/.local/state/awa/roots"
        try FileManager.default.createDirectory(
            atPath: roots,
            withIntermediateDirectories: true
        )
        let name = URL(
            fileURLWithPath: worktreePath
        ).lastPathComponent.lowercased()
        let hash = String(
            SHA256.hash(
                data: Data(worktreePath.utf8)
            ).map {
                String(format: "%02x", $0)
            }.joined().prefix(16)
        )
        let path = roots + "/\(name)-\(hash).json"
        let document: [String: Any] = [
            "schema": "active_root/v1",
            "root_path": worktreePath,
            "git_common_dir": repositoryPath + "/.git",
            "branch": branch,
            "last_heartbeat_epoch":
                Int(Date().timeIntervalSince1970),
        ]
        try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        ).write(to: URL(fileURLWithPath: path))
        guard chmod(path, 0o600) == 0 else {
            throw Body2SelfTestError.message(
                "could not protect fixture active-root record"
            )
        }
        return path
    }

    func gitText(_ arguments: [String]) throws -> String {
        String(
            decoding: try gitData(arguments),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitTextAt(
        _ path: String,
        _ arguments: [String]
    ) throws -> String {
        String(
            decoding: try Self.gitProcess(
                ["-C", path] + arguments
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func gitData(_ arguments: [String]) throws -> Data {
        try Self.gitProcess(
            ["-C", repositoryPath] + arguments
        )
    }

    func remove() {
        temporary.remove()
    }

    private static func installPolicy(home: String) throws {
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
        guard directory >= 0 else { throw Body2SelfTestError.message("fixture command directory unavailable") }
        defer { close(directory) }
        let result = try ClosedProcessRunner(outputLimit: DescriptorProcessRunner.completeRepositoryOutputLimit).run(
            command: ClosedProcessCommand(executable: discoveryFixtureGitExecutable, arguments: arguments),
            environment: ClosedProcessRunner.environment(account: account),
            workingDirectoryDescriptor: directory, account: account, timeout: 20,
            cancellation: CancellationToken())
        guard (allowFailure || result.status == 0) && !result.cancelled && !result.timedOut
                && !result.stdoutTruncated && !result.stderrTruncated else {
            throw Body2SelfTestError.message("fixture command failed: " + Redactor.subprocessBytes(result.output))
        }
        return result.output
    }
}

private enum Body2SelfTestError: Error, CustomStringConvertible {
    case failed(String)
    case message(String)

    var description: String {
        switch self {
        case let .failed(value), let .message(value):
            return value
        }
    }
}
#endif
