#if SHADOW_SYNC_TESTING
import Darwin
import ShadowSyncCore
import Foundation

// Set owner-private umask before any child process or git operation so that
// all directories created by git init, git worktree add, etc. satisfy the
// TestIsolation.validateContainedDirectory 0o700 requirement.  The umask is
// inherited by all child processes (worker binary, git trampoline).
umask(0o077)
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
if let status = RuntimeSuiteGuardianEntrypoint.dispatch(arguments, catalog: SelfTestCISuites.guardianCatalog,
    run: { id, app in
        try SelfTestCISuites.run(ids: [id], app: app,
            onPass: { name in print("PASS \(name)"); fflush(stdout) },
            onFailure: { name in FileHandle.standardError.write(Data("FAIL \(name)\n".utf8)) })
    }) { exit(status) }
if let status = CommandCustodian.testingDispatch(arguments) { exit(status) }
if let status = DiscoveryCallerSelfTestRunner.dispatchRetentionWorker(arguments) { exit(status) }
if let status = M6SelfTestRunner.dispatchInitializationFixture(arguments) { exit(status) }
if let status = M6SelfTestRunner.dispatchCustodyParentFixture(arguments) { exit(status) }
if let status = M6SelfTestRunner.dispatchResourceFixture(arguments) { exit(status) }
if let status = M6SelfTestRunner.dispatchRegistryFixture(arguments) { exit(status) }
if arguments.count == 2 && arguments[1] == "--list-ci-suites" {
    do {
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": "shadow-sync-runtime-suite-discovery/v1",
            "suites": try SelfTestCISuites.discovery(),
        ], options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        exit(0)
    } catch { exit(1) }
}
// Public verification must never project the operator's installed inventory.
// Refuse these historical selectors before parsing any executable pathname.
if arguments.contains("--live-diagnostic")
    || arguments.contains("--v2-live-diagnostic") {
    FileHandle.standardError.write(
        Data("Live host diagnostics are unavailable in the public self-test runner.\n".utf8)
    )
    exit(64)
}
if let status = GitChildTrampoline.dispatch(arguments: arguments) {
    exit(status)
}

do {
    let appExecutable = try SelfTestExecutable.argument(arguments)
    if arguments.count == 3 || arguments[3] == "--ci-all"
        || SelfTestCISuites.selectedID(argument: arguments[3]) != nil {
        let ids = arguments.count == 4
            ? SelfTestCISuites.selectedID(argument: arguments[3]).map { [$0] }
                ?? SelfTestCISuites.identifiers
            : SelfTestCISuites.identifiers
        let complete = try SelfTestCISuites.run(ids: ids, app: appExecutable,
            onPass: { name in print("PASS \(name)"); fflush(stdout) },
            onFailure: { name in
                FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
            })
        exit(complete ? 0 : 1)
    }
    if arguments.contains("--publisher-policy-only") {
        try PublisherPolicyResourcesSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--release-identity-only") {
        try ReleaseIdentitySelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--identity-history-only") {
        try HistoricalLogSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-transport-only") {
        try PolicyTransportSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-wire-only") {
        try PolicyWireSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-input-only") {
        try PolicyInputSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-authority-only") {
        try PolicyAuthorityFileSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-binding-only") {
        try HostPolicyBindingSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-projection-only") {
        try HostPolicyProjectionSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-snapshot-only") {
        try HostPolicySnapshotSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-catalog-only") {
        try RepositorySelectionAdmissionSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if arguments.contains("--policy-catalog-session-only") {
        try HostPolicySnapshotSelfTestRunner.runCatalogSession { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    let m1Only = arguments.contains("--m1-only")
    let m2Only = arguments.contains("--m2-only")
    let m3Only = arguments.contains("--m3-only")
    let m4Only = arguments.contains("--m4-only")
    let m6Only = arguments.contains("--m6-only")
    let body1Only = arguments.contains("--body1-only")
    let body2Only = arguments.contains("--body2-only")
    let body3Only = arguments.contains("--body3-only")
    let body4Only = arguments.contains("--body4-only")
    let v3PreflightOnly =
        arguments.contains("--v3-preflight-only")
    let betaV02ChooserOnly =
        arguments.contains("--beta-v02-chooser-only")
    let betaV02DeviceDriftOnly =
        arguments.contains("--beta-v02-device-drift-only")
    let betaV03FocusedOnly =
        arguments.contains("--beta-v03-focused-only")
    let betaV04FocusedOnly =
        arguments.contains("--beta-v04-focused-only")
    let betaV05FocusedOnly =
        arguments.contains("--beta-v05-focused-only")
    let betaV06FocusedOnly =
        arguments.contains("--beta-v06-focused-only")
    let betaV07FocusedOnly =
        arguments.contains("--beta-v07-focused-only")
    let betaV08FocusedOnly =
        arguments.contains("--beta-v08-focused-only")
    let betaV09FocusedOnly =
        arguments.contains("--beta-v09-focused-only")
    let v4PreflightOnly =
        arguments.contains("--v4-preflight-only")
    let v4Focused = (1...12).compactMap {
        index -> (String, String)? in
        let id = String(format: "DM4-T%02d", index)
        let argument = String(
            format: "--dm4-t%02d-only",
            index
        )
        return arguments.contains(argument)
            ? (argument, id) : nil
    }.first?.1
    let v3Focused = (1...15).compactMap {
        index -> (String, String)? in
        let id = String(format: "DM3-T%02d", index)
        let argument = String(
            format: "--dm3-t%02d-only",
            index
        )
        return arguments.contains(argument)
            ? (argument, id) : nil
    }.first?.1
    let body2Focused = [
        "--dm2-t05-only": "t05",
        "--body2-r01-only": "r01",
        "--body2-r02-only": "r02",
        "--body2-r03-only": "r03",
        "--body2-r04-sha1-only": "r04-sha1",
        "--body2-r04-sha256-only": "r04-sha256",
    ].first { arguments.contains($0.key) }?.value
    let body3Focused = [
        "--dm2-t08-only": "t08",
        "--dm2-t09-only": "t09",
        "--dm2-t10-only": "t10",
        "--dm2-t11-only": "t11",
        "--dm2-t12-only": "t12",
        "--dm2-t15-only": "t15",
        "--dm2-t15-branch-only": "t15-branch",
        "--dm2-t16-only": "t16",
    ].first { arguments.contains($0.key) }?.value
    let body4Focused = [
        "--dm2-t04-only": "t04",
        "--dm2-t04-success-only": "t04-success",
        "--dm2-t04-relations-only": "t04-relations",
        "--dm2-t04-races-a-only": "t04-races-a",
        "--dm2-t04-races-b-only": "t04-races-b",
        "--dm2-t05-body4-only": "t05",
        "--dm2-t05-trace-only": "t05-basic",
        "--dm2-t05-veto-only": "t05-veto",
        "--dm2-t05-hookspath-only": "t05-custom",
        "--dm2-t05-policy-only": "t05-policy",
        "--dm2-t13-only": "t13",
    ].first { arguments.contains($0.key) }?.value
    let m2PerformanceOnly =
        arguments.contains("--m2-performance-only")
    let m2CoalescedOnly =
        arguments.contains("--m2-coalesced-only")
    let practicalOnly = arguments.contains("--practical-only")
    if v4PreflightOnly {
        try DM4PreflightSelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if let v4Focused {
        try DM4PreflightSelfTestRunner.runFocused(
            v4Focused,
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if v3PreflightOnly {
        try V3PreflightSelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try DM4PreflightSelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV02ChooserOnly {
        try V3PreflightSelfTestRunner.runBetaV02 { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV02DeviceDriftOnly {
        try V2Body1SelfTestRunner.runDeviceDriftOnly {
            name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV03FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV03 { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV04FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV04 {
            name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV05FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV05 {
            name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV06FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV06(
            testExecutable: appExecutable
        ) {
            name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV07FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV07(
            testExecutable: appExecutable
        ) {
            name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if betaV08FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV08(
            testExecutable: appExecutable
        ) {
            name in
            print("PASS \(name)")
        }
        fflush(stdout)
        exit(0)
    }
    if betaV09FocusedOnly {
        try V3PreflightSelfTestRunner.runBetaV09(
            testExecutable: appExecutable
        ) {
            name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if let v3Focused {
        try V3PreflightSelfTestRunner.runFocused(
            v3Focused,
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if practicalOnly {
        _ = try M2SelfTestRunner.runPractical { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        _ = try M3SelfTestRunner.runPractical(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if m2PerformanceOnly {
        _ = try M2SelfTestRunner.runPerformance { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if m2CoalescedOnly {
        _ = try M2SelfTestRunner.runCoalescedValidation { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if body1Only {
        _ = try V2Body1SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if body2Only {
        _ = try V2Body2SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if let body2Focused {
        try V2Body2SelfTestRunner.runFocused(
            body2Focused,
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if body3Only {
        try V2Body3SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if let body3Focused {
        try V2Body3SelfTestRunner.runFocused(
            body3Focused,
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if body4Only {
        try V2Body4SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if let body4Focused {
        try V2Body4SelfTestRunner.runFocused(
            body4Focused,
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        exit(0)
    }
    if !m1Only && !m3Only && !m4Only && !m6Only {
        _ = try M2SelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
    }
    if !m2Only && !m3Only && !m4Only && !m6Only {
        _ = try M1SelfTestRunner.runAll(testExecutable: appExecutable) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
    }
    if !m1Only && !m2Only && !m4Only && !m6Only {
        _ = try M3SelfTestRunner.runAll(testExecutable: appExecutable) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
    }
    if !m1Only && !m2Only && !m3Only && !m6Only {
        _ = try M4SelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
    }
    if !m1Only && !m2Only && !m3Only && !m4Only {
        _ = try M6SelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
    }
    if !m1Only && !m2Only && !m3Only && !m4Only && !m6Only {
        try ReleaseIdentitySelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try HostPolicySnapshotSelfTestRunner.runCatalogSession { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try RepositorySelectionAdmissionSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try HostPolicySnapshotSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try HostPolicyProjectionSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try HostPolicyBindingSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try PolicyAuthorityFileSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try HistoricalLogSelfTestRunner.runAll { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        _ = try V2Body1SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        _ = try V2Body2SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try V2Body3SelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
        try V3PreflightSelfTestRunner.runAll(
            testExecutable: appExecutable
        ) { name in
            print("PASS \(name)")
            fflush(stdout)
        }
    }
    exit(0)
} catch {
    FileHandle.standardError.write(
        Data("FAIL \(Redactor.sanitize(String(describing: error)))\n".utf8)
    )
    exit(1)
}

private enum SelfTestExecutable {
    static func argument(_ arguments: [String]) throws -> String {
        guard arguments.count == 3 || (
                  arguments.count == 4
                    && (arguments[3] == "--ci-all"
                        || SelfTestCISuites.selectedID(argument: arguments[3]) != nil
                        || ([
                        "--m1-only", "--m2-only", "--m3-only", "--m4-only",
                        "--m6-only", "--body1-only", "--body2-only",
                        "--release-identity-only",
                        "--beta-v02-chooser-only",
                        "--beta-v02-device-drift-only",
                        "--beta-v03-focused-only",
                        "--beta-v04-focused-only",
                        "--beta-v05-focused-only",
                        "--beta-v06-focused-only",
                        "--beta-v07-focused-only",
                        "--beta-v08-focused-only",
                        "--beta-v09-focused-only",
                        "--dm2-t05-only",
                        "--body2-r01-only", "--body2-r02-only",
                        "--body2-r03-only",
                        "--body2-r04-sha1-only",
                        "--body2-r04-sha256-only",
                        "--body3-only",
                        "--dm2-t08-only", "--dm2-t09-only",
                        "--dm2-t10-only", "--dm2-t11-only",
                        "--dm2-t12-only", "--dm2-t15-only",
                        "--dm2-t15-branch-only",
                        "--dm2-t16-only",
                        "--body4-only",
                        "--dm2-t04-only",
                        "--dm2-t04-success-only",
                        "--dm2-t04-relations-only",
                        "--dm2-t04-races-a-only",
                        "--dm2-t04-races-b-only",
                        "--dm2-t05-body4-only",
                        "--dm2-t05-trace-only",
                        "--dm2-t05-veto-only",
                        "--dm2-t05-hookspath-only",
                        "--dm2-t05-policy-only",
                        "--dm2-t13-only",
                        "--identity-history-only",
                        "--policy-input-only",
                        "--policy-wire-only",
                        "--policy-catalog-only",
                        "--policy-catalog-session-only",
                        "--publisher-policy-only",
                        "--policy-transport-only",
                        "--policy-authority-only",
                        "--policy-binding-only",
                        "--policy-projection-only",
                        "--policy-snapshot-only",
                        "--m2-performance-only",
                        "--m2-coalesced-only",
                        "--practical-only",
                        "--v3-preflight-only",
                        "--v4-preflight-only",
                    ]
                        + (1...15).map {
                            String(
                                format: "--dm3-t%02d-only",
                                $0
                            )
                        }).contains(arguments[3])
                        || (1...12).map {
                            String(
                                format: "--dm4-t%02d-only",
                                $0
                            )
                        }.contains(arguments[3]))
              ),
              arguments[1] == "--app-executable",
              arguments[2].hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: arguments[2]) else {
            throw SelfTestArgumentError.invalid
        }
        return arguments[2]
    }
}

private enum SelfTestArgumentError: Error {
    case invalid
}

private struct V2LiveInventoryCounts: Codable {
    let repositories: Int
    let clones: Int
    let worktrees: Int
    let writable: Int
    let protected: Int
    let references: Int
    let selectableFastForwards: Int
    let onboardingProposals: Int

    init(inventory: RepositoryInventory) {
        repositories = inventory.cards.count
        clones = inventory.cards.reduce(0) {
            $0 + $1.clones.count
        }
        worktrees = inventory.cards.reduce(0) { total, card in
            total + card.clones.reduce(0) { cloneTotal, clone in
                cloneTotal + clone.worktrees.count
            }
        }
        writable = inventory.writableCards.count
        protected = inventory.protectedCards.count
        references = inventory.referenceCards.count
        selectableFastForwards =
            inventory.selectableOperations.count
        onboardingProposals =
            inventory.onboardingProposals.count
    }
}
#else
import Darwin
import Foundation

FileHandle.standardError.write(
    Data("ShadowSyncSelfTest requires SHADOW_SYNC_TESTING.\n".utf8)
)
exit(2)
#endif
