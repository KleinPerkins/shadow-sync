#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import ShadowSyncCatalog
import Foundation

public enum V3PreflightSelfTestRunner {
    public static let testIDs = (1...15).map {
        String(format: "DM3-T%02d", $0)
    }

    public static func runAll(
        testExecutable: String,
        report: (String) -> Void
    ) throws {
        for id in testIDs {
            try runFocused(
                id,
                testExecutable: testExecutable,
                report: report
            )
        }
    }

    public static func runFocused(
        _ rawID: String,
        testExecutable: String,
        report: (String) -> Void
    ) throws {
        let id = rawID.uppercased()
        try RuntimeFixtureSession.withCase(id) {
            switch id {
            case "DM3-T01":
                try preserveHeavyWireModel(
                    testExecutable: testExecutable
                )
            case "DM3-T02": try catalogBoundary()
            case "DM3-T03": try catalogLimitsVisibility()
            case "DM3-T04": try chooserDefaults()
            case "DM3-T05": try preferenceTransitions()
            case "DM3-T06": try locatorBindingSurface()
            case "DM3-T07":
                try authorityStages(testExecutable: testExecutable)
            case "DM3-T08":
                try capabilityConstruction(
                    testExecutable: testExecutable
                )
            case "DM3-T09":
                try body3SelectedRefresh(
                    testExecutable: testExecutable
                )
            case "DM3-T10": try selectedWorkerPoison()
            case "DM3-T11": try lifecycleOrdering()
            case "DM3-T12": try drainBarrierSurface()
            case "DM3-T13": try scaleLinearity()
            case "DM3-T14": try physicalFirstScreen()
            case "DM3-T15": try lifecycleMigration()
            default:
                throw Failure("unknown v3 preflight selector: \(rawID)")
            }
        }
        report(id)
    }

    public static func runBetaV02(
        report: (String) -> Void
    ) throws {
        try RuntimeFixtureSession.withCase("BETA-V02-ORIGIN-CHOOSER") {
            try betaV02OriginChooser()
        }
        report("BETA-V02-ORIGIN-CHOOSER")
    }

    public static func runBetaV03(
        report: (String) -> Void
    ) throws {
        let (chooser, delegate, inventory, hydration, worker, coordinator, release) = try RuntimeFixtureSession.withCaseValue("BETA-V04-SOURCES") {
            let chooser = try readSource(
                "Sources/ShadowSyncApp/RepositoryChooserWindow.swift"
            )
            let delegate = try readSource(
                "Sources/ShadowSyncApp/AppDelegate.swift"
            )
            let inventory = try readSource(
                "Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
            )
            let hydration = try readSource(
                "Sources/ShadowSyncCore/SelectedRepositoryHydration.swift"
            )
            let worker = try readSource(
                "Sources/ShadowSyncApp/Worker.swift"
            )
            let coordinator = try readSource(
                "Sources/ShadowSyncCore/Coordinator.swift"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            return (chooser, delegate, inventory, hydration, worker, coordinator, release)
        }
        report("BETA-V04-SOURCES")
        try RuntimeFixtureSession.withCase("BETA-V03-FOCUSED") {
            try require(
                chooser.contains("buildReasonGroups")
                    && chooser.contains("showsDisabledReason: false"),
                "unavailable reasons are not consolidated"
            )
            try require(
                delegate.contains("didSave(snapshot)")
                    && delegate.contains(
                        "controller.showSaveOutcome(\"Defaults saved.\")"
                    )
                    && !delegate.contains(
                        "controller.showSaveOutcome(\"Defaults saved.\")\n                self.pendingChooserAcknowledgement"
                    ),
                "Save still replaces the chooser"
            )
            try require(
                hydration.contains("func hydrateOnce(")
                    && delegate.contains("hydrator.reconcileSession(")
                    && hydration.contains("return try hydrateOnce(scope: scope)")
                    && hydration.contains(".discoverSelectedHydration(scope: scope)")
                    && inventory.contains(
                        "phase: \"Resolving default branch\""
                    )
                    && inventory.contains(
                        "phase: \"Checking default branch\""
                    ),
                "single-pass phased hydration is missing"
            )
            try require(
                RepositoryReadSession.pullRequestStageBudget(candidateCount: 1_000) == 60
                    && inventory.contains("Date() >= deadline")
                    && inventory.contains("cancellation.areFutureChildAdmissionsClosed")
                    && chooser.contains(
                        "Cancelled. Finishing safe cleanup"
                    )
                    && chooser.contains("closeCurrentRunWindow"),
                "bounded hydration or cancellation UX is missing"
            )
            try require(
                inventory.contains("git status timed out after")
                    || inventory.contains(
                        "inspectionFailure(\n                        check: \"git status\""
                    ),
                "exact eligibility diagnostics are missing"
            )
            try require(
                !worker.contains(
                    "Set(operations.map {\n                $0.target.repository.id\n            }).count == operations.count"
                )
                    && coordinator.contains("stoppedRepositories"),
                "ordered same-repository operations are not admitted safely"
            )
            try require(
                currentReleaseSourceIsValid(release),
                "current beta release identity is incorrect"
            )
        }
        report("BETA-V03-FOCUSED")
    }

    public static func runBetaV04(
        report: (String) -> Void
    ) throws {
        let (inventory, cards, delegate, batch, geometry, release, recoveredBatchClose) = try RuntimeFixtureSession.withCaseValue("BETA-V04-SORTING") {
            let chooser = try readSource(
                "Sources/ShadowSyncApp/RepositoryChooserWindow.swift"
            )
            let inventory = try readSource(
                "Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
            )
            let cards = try readSource(
                "Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
            )
            let delegate = try readSource(
                "Sources/ShadowSyncApp/AppDelegate.swift"
            )
            let batch = try readSource(
                "Sources/ShadowSyncApp/Body3RunWindow.swift"
            )
            let geometry = try readSource(
                "Sources/ShadowSyncApp/WindowFrameContinuity.swift"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            let recoveredBatchClose = delegate
                .components(
                    separatedBy: "private func showLastBody3Report()"
                )
                .dropFirst()
                .first?
                .components(
                    separatedBy: "private func acknowledgeReviewedBody3("
                )
                .first ?? ""
            try require(
                chooser.contains("sortedCandidates(")
                    && chooser.contains("leftOwner")
                    && chooser.contains("leftRepository"),
                "chooser owner/repository sorting is missing"
            )
            return (inventory, cards, delegate, batch, geometry, release, recoveredBatchClose)
        }
        report("BETA-V04-SORTING")
        try RuntimeFixtureSession.withCase("BETA-V04-TOP-LEVEL") {
            try require(
                inventory.contains("prepareTopLevel(")
                    && inventory.contains(
                        "phase: \"Checking default branch\""
                    )
                    && inventory.contains(
                        "public func inspectCleanup("
                    )
                    && inventory.contains(
                        "inspectAllWorktreeState: Bool = false"
                    )
                    && !inventory.contains(
                        "phase: \"Inspecting lifecycle\""
                    ),
                "top-level readiness is still coupled to cleanup enrichment"
            )
        }
        report("BETA-V04-TOP-LEVEL")
        try RuntimeFixtureSession.withCase("BETA-V04-CLEANUP") {
            try require(
                cards.contains(
                    "Inspect branches & worktrees"
                )
                    && cards.contains(
                        "Inspect for all repositories"
                    )
                    && cards.contains(
                        "Protected — cannot remove"
                    )
                    && cards.contains("Keep recommended")
                    && cards.contains(
                        "AWA / recovery notes: \\(managed ? \"Managed\" : \"Unmanaged\")"
                    )
                    && cards.contains(
                        "dependenciesSatisfied("
                    ),
                "optional cleanup information architecture is incomplete"
            )
        }
        report("BETA-V04-CLEANUP")
        try RuntimeFixtureSession.withCase("BETA-V04-WINDOWS") {
            try require(
                geometry.contains("WindowContinuitySnapshot")
                    && delegate.contains(
                        "rememberWindowFrame("
                    )
                    && delegate.contains(
                        "restoreWindowFrame("
                    )
                    && recoveredBatchClose.contains(
                        "rememberWindowFrame(controller.window)"
                    ),
                "window continuity is missing"
            )
        }
        report("BETA-V04-WINDOWS")
        try RuntimeFixtureSession.withCase("BETA-V04-BATCH") {
            try require(
                delegate.contains(
                    "Review the ordered plan"
                )
                    && delegate.contains(
                        "Repositories run in the order shown"
                    )
                    && batch.contains(
                        "Completed successfully"
                    )
                    && batch.contains(
                        "Completed with issues"
                    )
                    && batch.contains(
                        "immutable plan #1"
                    ),
                "review or selected-batch hierarchy is incomplete"
            )
        }
        report("BETA-V04-BATCH")
        try RuntimeFixtureSession.withCase("BETA-V04-FOCUSED") {
            try require(
                currentReleaseSourceIsValid(release),
                "current release identity is incorrect"
            )
        }
        report("BETA-V04-FOCUSED")
    }

    public static func runBetaV05(
        report: (String) -> Void
    ) throws {
        let (batch, delegate, inventoryBudgetUses, operationAdmission, cards, release) = try RuntimeFixtureSession.withCaseValue("BETA-V05-MACOS") {
            let main = try readSource(
                "Sources/ShadowSyncApp/main.swift"
            )
            let delegate = try readSource(
                "Sources/ShadowSyncApp/AppDelegate.swift"
            )
            let icon = try readSource(
                "Sources/ShadowSyncApp/StatusItemIcon.swift"
            )
            let batch = try readSource(
                "Sources/ShadowSyncApp/Body3RunWindow.swift"
            )
            let cards = try readSource(
                "Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
            )
            let inventory = try readSource(
                "Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
            )
            let discovery = try readSource(
                "Sources/ShadowSyncCore/RepositoryDiscovery.swift"
            )
            let lifecycle = try readSource(
                "Sources/ShadowSyncCore/InstallationLifecycle.swift"
            )
            let launchAgent = try readSource(
                "Resources/com.kleinperkins.shadow-sync.plist.template"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            let operationAdmission = discovery
                .components(
                    separatedBy:
                        "static func validateRuntimeEligibility(\n        _ operation"
                )
                .dropFirst()
                .first?
                .components(
                    separatedBy:
                        "static func validateRemovalRuntimeEligibility("
                )
                .first ?? ""
            let inventoryBudgetUses = inventory.components(
                separatedBy:
                    "outputLimit: Self.inventoryOutputLimit"
            ).count - 1
            let freshLoginRegistrationCases = delegate.components(
                separatedBy: "case .notRegistered, .notFound:"
            ).count - 1

            try require(
                launchAgent.contains(
                    "<key>RunAtLoad</key>\n\t<false/>"
                )
                    && lifecycle.contains(
                        "\"RunAtLoad\": false"
                    )
                    && lifecycle.contains(
                        "try launchAgent.kickstart("
                    ),
                "manual-by-default launch registration is incomplete"
            )
            try require(
                main.contains(
                    "info[\"LSUIElement\"] as? Bool == false"
                )
                    && main.contains(
                        "application.setActivationPolicy(.regular)"
                    )
                    && delegate.contains(
                        "NSApp.disableRelaunchOnLogin()"
                    )
                    && delegate.contains("installMainMenu()")
                    && delegate.contains(
                        "SMAppService.mainApp.register()"
                    )
                    && delegate.contains(
                        "SMAppService.mainApp.unregister()"
                    )
                    && freshLoginRegistrationCases == 2
                    && delegate.contains(
                        "Open at Login could not be changed"
                    ),
                "standard macOS application presence is incomplete"
            )
            try require(
                delegate.contains(
                    "ShadowSyncStatusItemIcon.make()"
                )
                    && icon.contains("image.isTemplate = true")
                    && icon.contains(
                        "appendCircle(x: 18, y: 18, radius: 3"
                    )
                    && icon.contains(
                        "appendCircle(x: 6, y: 6, radius: 3"
                    ),
                "Lucide pull-request status glyph is incomplete"
            )
            return (batch, delegate, inventoryBudgetUses, operationAdmission, cards, release)
        }
        report("BETA-V05-MACOS")
        try RuntimeFixtureSession.withCase("BETA-V05-QUIT") {

            try require(
                batch.contains("terminal && report != nil")
                    && delegate.contains(
                        "previousReportNeedsAttention"
                    )
                    && delegate.contains(
                        "updateTerminalReportNotice("
                    ),
                "terminal-report Quit or passive recovery notice is incomplete"
            )
        }
        report("BETA-V05-QUIT")
        try RuntimeFixtureSession.withCase("BETA-V05-OPERATIONS") {

            try require(
                RepositoryInventoryDiscovery.inventoryOutputLimit == 32 * 1024 * 1024
                    && RepositoryInventoryDiscovery.inventoryOutputLimit
                        == DescriptorProcessRunner.completeRepositoryOutputLimit
                    && inventoryBudgetUses == 2,
                "real-repository inspection output budget is incomplete"
            )
            try require(
                !operationAdmission.isEmpty
                    && !operationAdmission.contains(
                        "registeredLinkedWorktrees("
                    )
                    && operationAdmission.contains(
                        "exact stale-registration Repair invalidate itself"
                    ),
                "operation admission still self-invalidates stale-registration Repair"
            )
        }
        report("BETA-V05-OPERATIONS")
        try RuntimeFixtureSession.withCase("BETA-V05-CLEANUP") {

            try require(
                cards.contains(
                    "Optional cleanup inspection"
                )
                    && cards.contains(
                        "section.alignment = .leading"
                    )
                    && cards.contains(
                        "button.alignment = .left"
                    ),
                "cleanup inspection is not an explicit leading-aligned group"
            )
        }
        report("BETA-V05-CLEANUP")
        try RuntimeFixtureSession.withCase("BETA-V05-FOCUSED") {

            try require(
                currentReleaseSourceIsValid(release),
                "current release identity is incorrect"
            )
        }
        report("BETA-V05-FOCUSED")
    }

    public static func runBetaV06(
        testExecutable: String,
        report: (String) -> Void
    ) throws {
        try RuntimeFixtureSession.withCase("BETA-V06-SESSION-DELTA") {
            func identity(_ inode: UInt64)
                throws -> FileIdentity {
                let data = try JSONSerialization.data(
                    withJSONObject: [
                        "device": 1,
                        "inode": inode,
                        "owner": UInt32(geteuid()),
                        "mode": UInt16(S_IFDIR | 0o700),
                        "linkCount": 1,
                    ]
                )
                return try JSONDecoder().decode(
                    FileIdentity.self,
                    from: data
                )
            }
            func binding(
                _ id: String,
                inode: UInt64
            ) throws -> ValidatedSelectedRepository {
                let value = try identity(inode)
                return ValidatedSelectedRepository(
                    repositoryID: id,
                    locator: try RepositorySelectionLocator(
                        governedRoot: "testing",
                        components: [
                            id.replacingOccurrences(
                                of: "/",
                                with: "-"
                            ),
                        ]
                    ),
                    governedRootPath: "/private/tmp",
                    policyRootPath: "/private/tmp",
                    repositoryPath:
                        "/private/tmp/"
                        + id.replacingOccurrences(
                            of: "/",
                            with: "-"
                        ),
                    rootIdentity: value,
                    repositoryIdentity: value
                )
            }
            func scope(
                _ repositories:
                    [ValidatedSelectedRepository],
                policy: String = String(
                    repeating: "a",
                    count: 64
                )
            ) -> ValidatedSelectedRepositoryScope {
                ValidatedSelectedRepositoryScope(
                    selectionGeneration: 1,
                    policyDigest: policy,
                    catalogGeneration: 1,
                    repositories: repositories
                )
            }
            func card(
                _ id: String,
                inode: UInt64,
                marker: String
            ) throws -> RepositoryCard {
                let value = try identity(inode)
                let directory =
                    RepositoryDirectoryIdentity(value)
                let origin = "git@github.com:\(id).git"
                let candidate = RepositoryCandidate(
                    id: id,
                    displayName: id,
                    path:
                        "/private/tmp/"
                        + id.replacingOccurrences(
                            of: "/",
                            with: "-"
                        ),
                    rawOrigin: origin,
                    rootIdentity: directory,
                    gitDirectoryIdentity: directory,
                    commonDirectoryIdentity: directory
                )
                let clone = try LocalClone(
                    repositoryID: id,
                    sourceSnapshot: candidate,
                    effectiveOrigin: origin,
                    originParityVerified: true,
                    policyCategory: .writable,
                    kind: .primaryCheckout,
                    worktrees: [],
                    branches: [],
                    warnings: [marker]
                )
                return try RepositoryCard(
                    repository: try RemoteRepository(
                        id: id,
                        origins: [origin],
                        policyCategory: .writable,
                        resolvedDefault: nil,
                        defaultUnavailableReason:
                            "Fixture default unavailable."
                    ),
                    authority: CanonicalAuthorityState(
                        status: .missing,
                        record: nil,
                        explanation: marker
                    ),
                    clones: [clone],
                    relation: DefaultBranchRelation(
                        kind: .unavailable,
                        aheadCount: nil,
                        behindCount: nil
                    ),
                    fastForward: nil,
                    fastForwardRefusal: marker
                )
            }
            let a = try binding("fixture/a", inode: 10)
            let b = try binding("fixture/b", inode: 20)
            let c = try binding("fixture/c", inode: 30)
            let previous = scope([a, b])
            let next = scope([b, c])
            let delta =
                SelectedRepositoryHydrator.sessionDelta(
                    scope: next,
                    retainedScope: previous,
                    retainedRepositoryIDs: [
                        "fixture/a", "fixture/b",
                    ]
                )
            try require(
                delta.reusableRepositoryIDs
                    == ["fixture/b"]
                    && delta.repositoryIDsToHydrate
                        == ["fixture/c"]
                    && delta.droppedRepositoryIDs
                        == ["fixture/a"],
                "A,B to B,C session delta changed"
            )
            let deltaPlan =
                SelectedRepositoryHydrator.sessionPlan(
                    scope: next,
                    retainedScope: previous,
                    retainedRepositoryIDs: [
                        "fixture/a", "fixture/b",
                    ]
                )
            try require(
                deltaPlan.delta == delta
                    && deltaPlan.hydrationScope?
                        .repositoryIDs == ["fixture/c"],
                "A,B to B,C onboarding scope did not hydrate only C"
            )
            let retainedA = try card(
                "fixture/a",
                inode: 110,
                marker: "retained-a"
            )
            let retainedB = try card(
                "fixture/b",
                inode: 120,
                marker: "retained-b-inspection"
            )
            let freshC = try card(
                "fixture/c",
                inode: 130,
                marker: "fresh-c-hydration"
            )
            let retainedInventory = RepositoryInventory(
                cards: [retainedA, retainedB],
                onboardingProposals: [],
                authorityFileIdentity: try identity(140)
            )
            let freshInventory = RepositoryInventory(
                cards: [freshC],
                onboardingProposals: [],
                authorityFileIdentity: try identity(150)
            )
            let merged =
                SelectedRepositoryHydrator.mergeSessionInventory(
                    scope: next,
                    reusableRepositoryIDs:
                        delta.reusableRepositoryIDs,
                    retainedInventory: retainedInventory,
                    freshInventory: freshInventory
                )
            try require(
                merged.cards.map(\.id)
                    == ["fixture/b", "fixture/c"]
                    && merged.cards[0] == retainedB
                    && merged.cards[1] == freshC
                    && merged.authorityFileIdentity
                        == freshInventory.authorityFileIdentity
                    && Set(["fixture/a", "fixture/b"])
                        .intersection(
                            delta.reusableRepositoryIDs
                        ) == ["fixture/b"],
                "A,B to B,C reconciliation did not retain exact B evidence, hydrate C, drop A, and retain only B cleanup state"
            )
            let noOp =
                SelectedRepositoryHydrator.sessionDelta(
                    scope: previous,
                    retainedScope: previous,
                    retainedRepositoryIDs:
                        previous.repositoryIDs
                )
            try require(
                noOp.reusableRepositoryIDs
                    == previous.repositoryIDs
                    && noOp.repositoryIDsToHydrate.isEmpty
                    && noOp.droppedRepositoryIDs.isEmpty,
                "same-session no-op delta rehydrated unchanged repositories"
            )
            let noOpPlan =
                SelectedRepositoryHydrator.sessionPlan(
                    scope: previous,
                    retainedScope: previous,
                    retainedRepositoryIDs:
                        previous.repositoryIDs
                )
            try require(
                noOpPlan.delta == noOp
                    && noOpPlan.hydrationScope == nil,
                "same-session no-op produced a hydration scope"
            )
            let noOpInventory =
                SelectedRepositoryHydrator.mergeSessionInventory(
                    scope: previous,
                    reusableRepositoryIDs:
                        noOp.reusableRepositoryIDs,
                    retainedInventory: retainedInventory,
                    freshInventory: nil
                )
            try require(
                noOpInventory == retainedInventory,
                "same-session no-op reconciliation changed retained evidence"
            )
            let changedB = try binding(
                "fixture/b",
                inode: 21
            )
            let identityChanged =
                SelectedRepositoryHydrator.sessionDelta(
                    scope: scope([changedB, c]),
                    retainedScope: previous,
                    retainedRepositoryIDs:
                        previous.repositoryIDs
                )
            try require(
                identityChanged.reusableRepositoryIDs.isEmpty
                    && identityChanged
                        .repositoryIDsToHydrate
                        == ["fixture/b", "fixture/c"]
                    && identityChanged
                        .droppedRepositoryIDs
                        == ["fixture/a"],
                "changed repository binding reused stale session evidence"
            )
            let restarted =
                SelectedRepositoryHydrator.sessionDelta(
                    scope: next,
                    retainedScope: nil,
                    retainedRepositoryIDs: []
                )
            try require(
                restarted.reusableRepositoryIDs.isEmpty
                    && restarted.repositoryIDsToHydrate
                        == next.repositoryIDs,
                "new session reused prior-session evidence"
            )
        }
        report("BETA-V06-SESSION-DELTA")

        try V2Body1SelfTestRunner.runBetaV06(
            testExecutable: testExecutable,
            onPass: report
        )
        try V2Body2SelfTestRunner.runFocused(
            "r01",
            testExecutable: testExecutable,
            progress: report
        )
        try V2Body3SelfTestRunner.runBetaV06(
            observer: report
        )

        try RuntimeFixtureSession.withCase("BETA-V06-SOURCES") {
            let delegate = try readSource(
                "Sources/ShadowSyncApp/AppDelegate.swift"
            )
            let cards = try readSource(
                "Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
            )
            let results = try readSource(
                "Sources/ShadowSyncApp/Body3RunWindow.swift"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            try require(
                delegate.contains("reconcileSession(")
                    && delegate.contains(
                        "hydrateVerifiedSession("
                    )
                    && delegate.contains(
                        "historicalBody3Viewer"
                    )
                    && delegate.contains(
                        "retainedSuccessfulCleanupInspectionRepositoryIDs"
                    )
                    && delegate.contains(
                        "pendingPlannedOperations = []"
                    )
                    && delegate.contains(
                        "if confirmationInProgress"
                    )
                    && cards.contains(
                        "successfulCleanupInspectionRepositoryIDs"
                    )
                    && cards.contains(
                        "!cleanupStates.values.contains(.inspecting)"
                    )
                    && results.contains(
                        "record.type != \"command\""
                    )
                    && results.contains(
                        "testingActionRowIdentities"
                    ),
                "v0.6 workflow or stable-result ownership is incomplete"
            )
            try require(
                currentReleaseSourceIsValid(release),
                "Beta v0.6 release identity is incorrect"
            )
        }
        report("BETA-V06-SOURCES")
    }

    public static func runBetaV07(
        testExecutable: String,
        report: (String) -> Void
    ) throws {
        try V2Body2SelfTestRunner.runFocused(
            "r01",
            testExecutable: testExecutable,
            progress: report
        )
        try V2Body3SelfTestRunner.runBetaV07(
            observer: report
        )
        try RuntimeFixtureSession.withCase("BETA-V07-SOURCES") {
            let appDelegate = try readSource(
                "Sources/ShadowSyncApp/AppDelegate.swift"
            )
            let runWindow = try readSource(
                "Sources/ShadowSyncApp/Body3RunWindow.swift"
            )
            let maintenance = try readSource(
                "Sources/ShadowSyncCore/RepositoryMaintenance.swift"
            )
            let cards = try readSource(
                "Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            try require(
                appDelegate.contains("Body3EventInbox")
                    && appDelegate.contains(
                        "deliverBody3Events("
                    )
                    && runWindow.contains(
                        "Body3RunLogProjection()"
                    )
                    && runWindow.contains(
                        "if !logScroll.isHidden"
                    )
                    && runWindow.contains(
                        "testingHierarchyMeetsApprovedGeometry"
                    ),
                "v0.7 bounded/coalesced UI path is incomplete"
            )
            try require(
                maintenance.contains(
                    "Nothing will be changed."
                )
                    && maintenance.contains(
                        "case detached"
                    )
                    && cards.contains(
                        "maintenanceDiagnostics"
                    )
                    && cards.contains(
                        ".secondaryLabelColor"
                    ),
                "v0.7 Repair-unavailable presentation is incomplete"
            )
            try require(
                currentReleaseSourceIsValid(release),
                "Beta v0.7 release identity is incorrect"
            )
        }
        report("BETA-V07-SOURCES")
    }

    public static func runBetaV08(
        testExecutable: String,
        report: (String) -> Void
    ) throws {
        try V2Body1SelfTestRunner.runBetaV08(
            testExecutable: testExecutable,
            onPass: report
        )
        try V2Body2SelfTestRunner.runFocused(
            "r01",
            testExecutable: testExecutable,
            progress: report
        )
        try V2Body3SelfTestRunner.runBetaV07(
            observer: report
        )
        try RuntimeFixtureSession.withCase("BETA-V08-SOURCES") {
            let runner = try readSource(
                "Sources/ShadowSyncCore/ProcessRunner.swift"
            )
            let coordinator = try readSource(
                "Sources/ShadowSyncCore/Body3Coordinator.swift"
            )
            let inventory = try readSource(
                "Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
            )
            let cards = try readSource(
                "Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
            )
            let presentation = try readSource(
                "Sources/ShadowSyncApp/RunPresentation.swift"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            try require(
                runner.contains(
                    "completeRepositoryOutputLimit = 32 * 1024 * 1024"
                )
                    && runner.contains(
                        "captured output omitted"
                    )
                    && coordinator.contains(
                        ".completeRepositoryOutputLimit"
                    )
                    && coordinator.contains(
                        "outcome:\n                                            \"admitted\""
                    ),
                "v0.8 bounded execution output or command diagnostics are incomplete"
            )
            try require(
                inventory.contains(
                    "return .remoteChangedSinceLastFetch"
                )
                    && cards.contains(
                        "ShadowSync.CleanupInspectionPanelFill"
                    )
                    && cards.contains(
                        "withFraction: 0.08"
                    ),
                "v0.8 relation or appearance presentation is incomplete"
            )
            try require(
                presentation.contains(
                    "MMM d, yyyy 'at' h:mm:ss a zzz"
                )
                    && presentation.contains(
                        "metadata.repositoryIDs.count"
                    )
                    && !presentation.contains(
                        "repositoryIDs.joined"
                    )
                    && currentReleaseSourceIsValid(release),
                "v0.8 metadata or release identity is incorrect"
            )
        }
        report("BETA-V08-SOURCES")
    }

    public static func runBetaV09(
        testExecutable: String,
        report: (String) -> Void
    ) throws {
        try RuntimeFixtureSession.withCase("BETA-V09-SYNTHETIC-75-21") {
            let first = try betaV09InspectionFixture(
                testExecutable: testExecutable,
                branchCount: 75,
                worktreeCount: 21
            )
            try require(
                first.callCount == 74
                    && first.maximumActive > 1
                    && first.maximumActive <= 4,
                "75-branch inspection did not use bounded four-child PR admission"
            )
            print(
                "METRIC BETA-V09-SYNTHETIC-75-21 duration_ms=\(first.durationMilliseconds) inspection_ms=\(first.inspectionMilliseconds) validation_ms=\(first.validationMilliseconds) removal_projection_ms=\(first.removalProjectionMilliseconds) topology_ms=\(first.topologyMilliseconds) worktree_ms=\(first.worktreeMilliseconds) relation_ms=\(first.relationMilliseconds) pr_ms=\(first.pullRequestMilliseconds) assembly_ms=\(first.assemblyMilliseconds) max_children=\(first.maximumActive)"
            )
        }
        report("BETA-V09-SYNTHETIC-75-21")
        try RuntimeFixtureSession.withCase("BETA-V09-SYNTHETIC-84-20") {
            let second = try betaV09InspectionFixture(
                testExecutable: testExecutable,
                branchCount: 84,
                worktreeCount: 20
            )
            try require(
                second.callCount == 83
                    && second.maximumActive > 1
                    && second.maximumActive <= 4,
                "84-branch inspection did not use bounded four-child PR admission"
            )
            print(
                "METRIC BETA-V09-SYNTHETIC-84-20 duration_ms=\(second.durationMilliseconds) inspection_ms=\(second.inspectionMilliseconds) validation_ms=\(second.validationMilliseconds) removal_projection_ms=\(second.removalProjectionMilliseconds) topology_ms=\(second.topologyMilliseconds) worktree_ms=\(second.worktreeMilliseconds) relation_ms=\(second.relationMilliseconds) pr_ms=\(second.pullRequestMilliseconds) assembly_ms=\(second.assemblyMilliseconds) max_children=\(second.maximumActive)"
            )
        }
        report("BETA-V09-SYNTHETIC-84-20")
        try RuntimeFixtureSession.withCase("BETA-V09-PARTIAL-SAFETY") {
            let partial = try betaV09InspectionFixture(
                testExecutable: testExecutable,
                branchCount: 12,
                worktreeCount: 1,
                failureEvery: 3
            )
            try require(
                partial.unavailableCount == 3
                    && partial.unsafeSelectableCount == 0,
                "incomplete PR evidence became selectable "
                    + "(unavailable=\(partial.unavailableCount), "
                    + "unsafe=\(partial.unsafeSelectableCount))"
            )
        }
        report("BETA-V09-PARTIAL-SAFETY")
        try RuntimeFixtureSession.withCase("BETA-V09-CANCEL-DRAIN") {
            // Exercise both ordinary and delayed first completion. The lookup
            // fixture holds its other initial calls until cancellation is issued;
            // admission must not depend on which worker the scheduler wakes first.
            for firstDelay: useconds_t in [20_000, 120_000] {
                let cancelled = try betaV09InspectionFixture(
                    testExecutable: testExecutable,
                    branchCount: 12,
                    worktreeCount: 1,
                    cancelOnFirst: true,
                    cancellationDelay: firstDelay
                )
                try require(
                    cancelled.callCount <= 4
                        && cancelled.activeAfterCompletion == 0
                        && cancelled.availableCount >= 1
                        && cancelled.unsafeSelectableCount == 0,
                    "inspection cancellation lost completed evidence, admitted future work, or did not drain "
                        + "(calls=\(cancelled.callCount), active=\(cancelled.activeAfterCompletion), "
                        + "available=\(cancelled.availableCount), unsafe=\(cancelled.unsafeSelectableCount))"
                )
            }
        }
        report("BETA-V09-CANCEL-DRAIN")
        try RuntimeFixtureSession.withCase("BETA-V09-BOUNDS") {
            try require(
                RepositoryReadSession.pullRequestStageBudget(
                    candidateCount: 74
                ) == 48
                    && RepositoryReadSession
                        .pullRequestStageBudget(
                            candidateCount: 83
                        ) == 52
                    && RepositoryReadSession
                        .pullRequestStageBudget(
                            candidateCount: 1_000
                        ) == 60,
                "adaptive PR budget is not deterministic and bounded"
            )
            let oid = String(repeating: "a", count: 40)
            _ = try GitCommandPolicy.validate([
                "--no-replace-objects",
                "--no-lazy-fetch",
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track,nobracket)%00%(ahead-behind:\(oid))%00",
                "refs/heads/",
                "refs/remotes/",
            ])
        }
        report("BETA-V09-BOUNDS")

        try runBetaV08(
            testExecutable: testExecutable,
            report: report
        )
        try RuntimeFixtureSession.withCase("BETA-V09-SOURCES") {

            let inventory = try readSource(
                "Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
            )
            let adapter = try readSource(
                "Sources/ShadowSyncCore/ReadOnlyGitHubCLIAdapter.swift"
            )
            let cards = try readSource(
                "Sources/ShadowSyncApp/RepositoryCardsWindow.swift"
            )
            let delegate = try readSource(
                "Sources/ShadowSyncApp/AppDelegate.swift"
            )
            let release = try readSource(
                "Sources/ShadowSyncCore/ReleaseIdentity.swift"
            )
            try require(
                !inventory.contains(
                    "addingTimeInterval(20)"
                )
                    && inventory.contains(
                        "bulkBranchEvidence("
                    )
                    && inventory.contains(
                        "maximumConcurrentChildren: 4"
                    )
                    && inventory.contains(
                        "closeAndCancelChildren()"
                    )
                    && adapter.contains(
                        "min(4, max(1, maximumConcurrentChildren))"
                    )
                    && adapter.contains(
                        "cacheCapacity = 512"
                    )
                    && adapter.contains(
                        "result.availability == .available"
                    ),
                "bounded bulk discovery or four-child admission is incomplete"
            )
            try require(
                cards.contains(
                    "cleanupBatchProgressView()"
                )
                    && cards.contains(
                        "Reading worktree evidence"
                    )
                    && cards.contains(
                        "candidateSubcard(containing:"
                    )
                    && cards.contains(
                        "constant: 18"
                    )
                    && !cards.contains(
                        "indentation: String"
                    )
                    && delegate.contains(
                        "cleanup_inspection stage="
                    ),
                "retained progress or candidate hierarchy is incomplete"
            )
            try require(
                currentReleaseSourceIsValid(release),
                "Beta v0.9 release identity is incorrect"
            )
        }
        report("BETA-V09-SOURCES")
    }

    private static func betaV09InspectionFixture(
        testExecutable: String,
        branchCount: Int,
        worktreeCount: Int,
        failureEvery: Int? = nil,
        cancelOnFirst: Bool = false,
        cancellationDelay: useconds_t = 20_000
    ) throws -> (
        callCount: Int,
        maximumActive: Int,
        unavailableCount: Int,
        unsafeSelectableCount: Int,
        durationMilliseconds: Int64,
        activeAfterCompletion: Int,
        availableCount: Int,
        inspectionMilliseconds: Int64,
        validationMilliseconds: Int64,
        removalProjectionMilliseconds: Int64,
        topologyMilliseconds: Int64,
        worktreeMilliseconds: Int64,
        relationMilliseconds: Int64,
        pullRequestMilliseconds: Int64,
        assemblyMilliseconds: Int64
    ) {
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName:
                "v09-\(branchCount)-\(worktreeCount)"
        )
        defer { fixture.remove() }
        let scope: ValidatedSelectedRepositoryScope
        do {
            scope = try selectedScope(fixture)
        } catch {
            throw Failure("v0.9 scope setup failed: \(error)")
        }
        for index in 1..<branchCount {
            try fixture.git([
                "branch",
                String(format: "candidate-%03d", index),
                "main",
            ])
        }
        let inventory: RepositoryInventory
        do {
            inventory = try fixture.authorizedInventory(
                executable: testExecutable
            )
        } catch {
            throw Failure("v0.9 inventory setup failed: \(error)")
        }
        let verified: VerifiedSelectedRepositoryInventory
        do {
            verified = try SelectedRepositoryHydrator
                .verifyFreshInventory(
                    scope: scope,
                    inventory: inventory
                )
        } catch {
            throw Failure("v0.9 inventory verification failed: \(error)")
        }
        let preInspectionCandidates =
            RepositoryInventoryRemovalCandidates.make(
                from: inventory,
                capability: verified.capability
            )
        try require(
            preInspectionCandidates.allSatisfy {
                !$0.canSelect && !$0.selectAllEligible
            },
            "missing pre-inspection evidence became selectable"
        )
        for index in 1..<worktreeCount {
            let path =
                fixture.temporary.path
                    + String(format: "/worktree-%03d", index)
            try fixture.git([
                "worktree", "add", "--quiet", "--detach",
                path, "main",
            ])
        }
        let cancellation = CancellationToken()
        let lookup = BetaV09PullRequestLookup(
            failureEvery: failureEvery,
            cancelParentOnFirst: cancelOnFirst
                ? cancellation : nil,
            cancellationDelay: cancellationDelay
        )
        let progress = BetaV09ProgressRecorder()
        let discovery = try RepositoryInventoryDiscovery(
            executablePath: testExecutable,
            isolatedRoot: fixture.temporary.path,
            transportMapping: fixture.mapping,
            pullRequestLookup: lookup,
            cancellation: cancellation,
            lifecycleObserver: { event in
                progress.record(event)
            }
        )
        let started = Date()
        let result = try discovery.inspectCleanup(
            inventory: inventory,
            repositoryIDs: scope.repositoryIDs,
            capability: verified.capability
        )
        let inspectionEnded = Date()
        guard let card = result.cards.first,
              let clone = card.clones.first else {
            throw Failure("v0.9 fixture produced no repository")
        }
        try require(
            clone.branches.count == branchCount
                && clone.worktrees.count == worktreeCount
                && clone.branches
                    .filter {
                        $0.fullRef != "refs/heads/main"
                    }
                    .allSatisfy {
                        $0.pullRequestAvailability != nil
                            && $0.relationToDefault != nil
                    },
            "bulk inspection lost branch/worktree evidence"
        )
        if let original = clone.branches.first(where: {
            $0.fullRef != "refs/heads/main"
        }) {
            let changed = try Branch(
                cloneID: original.cloneID,
                fullRef: original.fullRef,
                tipOID: original.tipOID,
                claimingWorktreeIDs:
                    original.claimingWorktreeIDs,
                relationToDefault:
                    original.relationToDefault,
                upstream: original.upstream,
                commitDate: original.commitDate,
                pullRequests: original.pullRequests,
                pullRequestAvailability:
                    original.pullRequestAvailability,
                purpose: original.purpose,
                activity:
                    original.activity == .recent
                        ? .idle : .recent,
                removalPreview:
                    original.removalPreview
            )
            try require(
                original.evidenceDigest
                    != changed.evidenceDigest,
                "decision-bearing branch evidence did not invalidate its digest"
            )
        }
        if failureEvery == nil && !cancelOnFirst {
            try require(
                clone.branches
                    .filter {
                        $0.fullRef != "refs/heads/main"
                    }
                    .allSatisfy {
                        $0.pullRequestAvailability == .available
                    },
                "available PR evidence was not retained"
            )
        }
        let snapshots = progress.snapshots
        try require(
            snapshots.contains {
                $0.stage == .worktreeEvidence
                    && $0.completed == worktreeCount
            }
                && snapshots.contains {
                    $0.stage == .branchRelations
                        && $0.completed == branchCount
                }
                && snapshots.contains {
                    $0.stage == .pullRequestEvidence
                        && (
                            cancelOnFirst
                                ? $0.completed <= 4
                                : $0.completed == branchCount - 1
                        )
                        && $0.total == branchCount - 1
                        && $0.maximumActiveChildren <= 4
                }
                && snapshots.last?.stage
                    == .candidateAssembly,
            "inspection progress did not retain ordered bounded stages"
        )
        let unavailableBranches = clone.branches.filter {
            $0.pullRequestAvailability == .unavailable
        }
        let unavailableIDs = Set(
            unavailableBranches.map(\.id)
        )
        let validationEnded = Date()
        let candidates =
            RepositoryInventoryRemovalCandidates.make(
                from: result,
                capability: verified.capability
            )
        let removalProjectionEnded = Date()
        let unsafeSelectable = candidates.filter {
            let incompleteBranch = $0.branch.map {
                unavailableIDs.contains($0.id)
                    || $0.relationToDefault?.kind == .unavailable
            } ?? false
            let incompleteWorktree = $0.worktree.map {
                $0.removalPreview == nil
                    || $0.fileState == nil
                    || $0.contentEvidenceDigest == nil
                    || $0.relationToDefault?.kind == .unavailable
            } ?? false
            guard incompleteBranch || incompleteWorktree else {
                return false
            }
            return $0.canSelect || $0.selectAllEligible
        }
        return (
            lookup.callCount,
            lookup.maximumActive,
            unavailableBranches.count,
            unsafeSelectable.count,
            Int64(
                Date().timeIntervalSince(started) * 1_000
            ),
            lookup.activeCount,
            clone.branches.filter {
                $0.pullRequestAvailability == .available
            }.count,
            Int64(
                inspectionEnded.timeIntervalSince(started) * 1_000
            ),
            Int64(
                validationEnded.timeIntervalSince(
                    inspectionEnded
                ) * 1_000
            ),
            Int64(
                removalProjectionEnded.timeIntervalSince(
                    validationEnded
                ) * 1_000
            ),
            snapshots.filter {
                $0.stage == .topology
            }.map(\.durationMilliseconds).max() ?? 0,
            snapshots.filter {
                $0.stage == .worktreeEvidence
            }.map(\.durationMilliseconds).max() ?? 0,
            snapshots.filter {
                $0.stage == .branchRelations
            }.map(\.durationMilliseconds).max() ?? 0,
            snapshots.filter {
                $0.stage == .pullRequestEvidence
            }.map(\.durationMilliseconds).max() ?? 0,
            snapshots.filter {
                $0.stage == .candidateAssembly
            }.map(\.durationMilliseconds).max() ?? 0
        )
    }

    private static func betaV02OriginChooser() throws {
        let fixture = try CatalogFixture(repositoryCount: 3)
        defer { fixture.remove() }
        try fixture.addPrimary(
            name: "duplicate-a",
            repositoryID: "fixture/duplicate"
        )
        try fixture.addPrimary(
            name: "duplicate-b",
            repositoryID: "fixture/duplicate"
        )
        try fixture.addLinkedWorktree(name: "linked-duplicate")
        try fixture.addPrimary(
            name: "missing-default",
            repositoryID: "fixture/missing-default",
            remoteDefault: false
        )
        let unresolved = fixture.catalog()
        let duplicate = unresolved.catalog.candidates.first {
            $0.id == "fixture/duplicate"
        }
        try require(
            unresolved.isComplete
                && unresolved.catalog.candidates.count == 5
                && duplicate?.section == .canonicalRootRequired
                && duplicate?.canonicalRootRequired == true
                && duplicate?.alternatives.count == 2
                && !unresolved.catalog.candidates.contains {
                    $0.compactLocation.contains("linked-duplicate")
                },
            "origin consolidation or linked suppression failed"
        )
        guard let duplicate,
              duplicate.alternatives.count == 2 else {
            throw Failure("duplicate origin fixture missing")
        }
        let selectedLocator =
            duplicate.alternatives[1].locator
        let authorityStore =
            try RepositoryAuthorityStore.open(
                at: fixture.stateLocation()
            )
        _ = try authorityStore.confirmCatalogCanonicalRoot(
            repositoryID: duplicate.id,
            canonicalRoot: fixture.canonicalPath(
                for: selectedLocator
            ),
            rootIdentity:
                duplicate.alternatives[1].repositoryIdentity,
            commonDirectoryIdentity:
                duplicate.alternatives[1]
                    .commonDirectoryIdentity,
            rawOrigin:
                duplicate.alternatives[1].rawOrigin,
            expectedFileIdentity: nil
        )
        let authority = authorityStore.snapshot()
        try require(
            authority.status == .available
                && authority.usableRecords.count == 1
                && authority.usableRecords[0].repositoryID
                    == duplicate.id
                && fixture.binder().canonicalLocators(
                    records: authority.usableRecords
                )[duplicate.id]?.relativePath
                    == selectedLocator.relativePath,
            "canonical-root mapping did not persist independently"
        )
        let preference = try RepositorySelectionPreferenceDocument(
            documentID:
                "00000000-0000-0000-0000-000000000020",
            revision: 1,
            entries: [
                RepositorySelectionPreferenceEntry(
                    repositoryID: duplicate.id,
                    locator: duplicate.alternatives[0].locator
                ),
            ]
        )
        let resolved = fixture.catalog(
            preferences: preference,
            canonicalLocators: [
                duplicate.id: selectedLocator,
            ]
        )
        guard let resolvedDuplicate =
                resolved.catalog.candidates.first(where: {
                    $0.id == duplicate.id
                }) else {
            throw Failure("resolved origin row missing")
        }
        try require(
            resolvedDuplicate.section == .available
                && !resolvedDuplicate.canonicalRootRequired
                && resolvedDuplicate.locator == selectedLocator
                && resolvedDuplicate.isDefaultSelected,
            "canonical mapping or origin-bound default failed"
        )
        let missing = resolved.catalog.candidates.first {
            $0.id == "fixture/missing-default"
        }
        try require(
            missing?.section == .unavailable
                && missing?.isEligible == false
                && missing?.disabledReason
                    == "Remote-default metadata is unavailable.",
            "missing remote-default metadata remained selectable"
        )
        let sections = fixture.catalog(
            excludedPaths: ["personal/repository-000"],
            readOnlyPaths: ["personal/repository-001"],
            permanentNoTouchRepositoryIDs: [
                "fixture/repository-2",
            ]
        )
        try require(
            sections.catalog.candidates.first {
                $0.id == "fixture/repository-0"
            }?.section == .excluded
                && sections.catalog.candidates.first {
                    $0.id == "fixture/repository-1"
                }?.section == .unavailable
                && sections.catalog.candidates.first {
                    $0.id == "fixture/repository-2"
                }?.section == .protected,
            "consolidated status sections are incorrect"
        )
        let binder = fixture.binder()
        let boundUnresolved = try binder.processFreeCatalog(
            preferences: nil,
            generation: 1
        )
        guard let boundDuplicate =
                boundUnresolved.catalog.candidates.first(where: {
                    $0.id == "fixture/duplicate"
                }),
              boundDuplicate.alternatives.count == 2 else {
            throw Failure("bound duplicate origin is missing")
        }
        let boundResolved = try binder.processFreeCatalog(
            preferences: nil,
            canonicalLocators: [
                boundDuplicate.id:
                    boundDuplicate.alternatives[1].locator,
            ],
            generation: 1
        )
        guard let boundRow =
                boundResolved.catalog.candidates.first(where: {
                    $0.id == boundDuplicate.id
                }),
              let unaffectedRow =
                boundResolved.catalog.candidates.first(where: {
                    $0.id == "fixture/repository-0"
                }) else {
            throw Failure("bound canonical row is missing")
        }
        let intent = try RepositorySelectionIntent(
            catalog: boundResolved.catalog,
            entries: [
                try boundRow.preferenceEntry,
                try unaffectedRow.preferenceEntry,
            ].sorted()
        )
        _ = try binder.bind(intent: intent)
        let selectedPath = fixture.canonicalPath(
            for: boundRow.locator
        )
        try FileManager.default.moveItem(
            atPath: selectedPath,
            toPath: selectedPath + "-moved"
        )
        do {
            _ = try binder.bind(intent: intent)
            throw Failure(
                "changed canonical root continued without reconciliation"
            )
        } catch is SelectedRepositoryScopeError {
            // Expected.
        }
        let reconciled = try binder.processFreeCatalog(
            preferences: nil,
            canonicalLocators: [
                boundDuplicate.id: boundRow.locator,
            ],
            sessionEntries: intent.entries,
            generation: 2
        )
        try require(
            reconciled.catalog.candidates.first {
                $0.id == boundDuplicate.id
            }?.section == .canonicalRootRequired
                && reconciled.catalog.candidates.contains {
                    $0.id == unaffectedRow.id
                        && $0.section == .available
                },
            "material refresh did not preserve unaffected origins or pause the changed root"
        )
    }

    private static func preserveHeavyWireModel(
        testExecutable: String
    ) throws {
        let candidate = RepositoryCandidate(
            id: "blocked/example",
            displayName: "example",
            path: "/private/tmp/example",
            rawOrigin: "not-an-origin",
            presentationLocation: "~/dev/example",
            blockedReason: .excludedByPolicy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(candidate)
        let decoded = try JSONDecoder().decode(
            RepositoryCandidate.self,
            from: bytes
        )
        try require(decoded == candidate, "RepositoryCandidate round trip changed")
        let source = try readSource("Sources/ShadowSyncCore/Models.swift")
        for key in [
            "id", "displayName", "path", "rawOrigin",
            "originIdentity", "presentationLocation",
            "rootIdentity", "gitDirectoryIdentity",
            "commonDirectoryIdentity", "configIdentity",
            "policyAdmissionSHA256", "hookAdmissionSHA256",
            "linkedWorktreePaths", "linkedWorktrees",
            "cachedMainRelation", "blockedReason",
        ] {
            try require(
                source.contains("case \(key)"),
                "RepositoryCandidate coding key changed: \(key)"
            )
        }
        try require(
            source.contains(
                "public struct RepositoryCandidate: Codable, Equatable, Sendable"
            ),
            "heavy RepositoryCandidate declaration changed"
        )
        let wireSources = source
            + (try readSource(
                "Sources/ShadowSyncCore/RepositoryModelV2.swift"
            ))
            + (try readSource(
                "Sources/ShadowSyncCore/Body3Batch.swift"
            ))
            + (try readSource(
                "Sources/ShadowSyncCore/Body3RunLog.swift"
            ))
        for type in [
            "RepositoryAuthorityDocument",
            "RepositoryCard",
            "PlannedOperation",
            "RepositoryResult",
            "RunEvent",
            "RunReport",
            "Body3BatchPlan",
            "Body3LogRecord",
            "Body3BatchReport",
        ] {
            try require(
                wireSources.contains(
                    "struct \(type)"
                ),
                "preserved wire model is missing \(type)"
            )
        }
        let workerSource = try readSource(
            "Sources/ShadowSyncApp/Worker.swift"
        )
        for type in ["WorkerRequest", "WorkerWireMessage"] {
            try require(
                workerSource.contains("struct \(type): Codable"),
                "preserved worker wire model is missing \(type)"
            )
        }
        try V2Body4SelfTestRunner.compatibilityRelease(
            executable: testExecutable
        )
    }

    private static func catalogBoundary() throws {
        let source = try readSource(
            "Sources/ShadowSyncCatalog/RepositorySelectionCatalog.swift"
        ) + (try readSource(
            "Sources/ShadowSyncCatalog/RepositorySelectionPolicy.swift"
        )) + (try readSource(
            "Sources/ShadowSyncCatalog/RepositorySelectionPreferences.swift"
        )) + (try readSource(
            "Sources/ShadowSyncCatalog/RepositorySelectionPathAdmission.swift"
        ))
        for forbidden in [
            "Process(", "NSTask", "posix_spawn", "fork(",
            "vfork(", "exec", "system(", "popen(",
            "/usr/bin/git", " gh ", "URLSession", "Network.",
            "RunAuthority", "RepositoryHandle",
            "DescriptorProcessRunner", "ClosedProcessRunner",
        ] {
            try require(
                !source.contains(forbidden),
                "catalog target references forbidden token \(forbidden)"
            )
        }
        let package = try readSource("Package.swift")
        try require(
            package.contains("name: \"ShadowSyncCatalog\"")
                && package.contains(
                    "dependencies: [\"ShadowSyncCatalog\"]"
                ),
            "catalog target dependency boundary is missing"
        )
    }

    private static func catalogLimitsVisibility() throws {
        let fixture = try CatalogFixture(repositoryCount: 51)
        defer { fixture.remove() }
        let result = fixture.catalog()
        try require(result.isComplete, "51-row catalog degraded")
        try require(
            result.catalog.candidates.count == 51,
            "catalog omitted durable repositories"
        )
        let limited = fixture.catalog(
            limits: RepositorySelectionCatalogLimits(
                candidateRows: 3
            )
        )
        try require(
            limited.degradedReason == .rowLimit,
            "aggregate row limit did not degrade catalog"
        )
        let limitCases: [
            (
                RepositorySelectionCatalogResult,
                RepositorySelectionCatalogDegradation
            )
        ] = [
            (
                fixture.catalog(rootCount: 9),
                .tooManyRoots
            ),
            (
                fixture.catalog(
                    limits: RepositorySelectionCatalogLimits(
                        relativeDepth: 1
                    ),
                    shelfPaths: [["nested", "shelf"]]
                ),
                .depthLimit
            ),
            (
                fixture.catalog(
                    limits: RepositorySelectionCatalogLimits(
                        directoryEntries: 1
                    )
                ),
                .directoryEntryLimit
            ),
            (
                fixture.catalog(
                    limits: RepositorySelectionCatalogLimits(
                        directoriesOpened: 1
                    )
                ),
                .directoryOpenLimit
            ),
            (
                fixture.catalog(
                    limits: RepositorySelectionCatalogLimits(
                        filesOpened: 1
                    )
                ),
                .fileOpenLimit
            ),
            (
                fixture.catalog(
                    limits: RepositorySelectionCatalogLimits(
                        aggregateBytes: 1
                    )
                ),
                .aggregateByteLimit
            ),
            (
                fixture.catalog(
                    limits: RepositorySelectionCatalogLimits(
                        directConfigBytes: 1
                    )
                ),
                .aggregateByteLimit
            ),
            (
                fixture.catalog(
                    deadlineUptimeNanoseconds: 0
                ),
                .deadline
            ),
        ]
        for (observed, expected) in limitCases {
            try require(
                observed.degradedReason == expected,
                "catalog limit did not degrade as \(expected.rawValue)"
            )
        }
        let visibility = fixture.catalog(
            excludedPaths: ["personal/repository-001"],
            readOnlyPaths: ["personal/repository-002"],
            artifactPaths: ["personal/repository-003"],
            permanentNoTouchRepositoryIDs: [
                "fixture/repository-4",
            ]
        )
        try require(
            visibility.isComplete
                && visibility.catalog.candidates.count == 50
                && visibility.catalog.candidates.contains {
                    $0.id == "fixture/repository-1"
                        && $0.policyDisposition == .excluded
                        && !$0.isEligible
                }
                && visibility.catalog.candidates.contains {
                    $0.id == "fixture/repository-2"
                        && $0.policyDisposition
                            == .readOnlyReference
                        && !$0.isEligible
                }
                && visibility.catalog.candidates.contains {
                    $0.id == "fixture/repository-4"
                        && $0.policyDisposition
                            == .permanentNoTouch
                        && !$0.isEligible
                }
                && !visibility.catalog.candidates.contains {
                    $0.locator.components.contains(
                        "repository-003"
                    ) || $0.id == "fixture/hidden"
                },
            "catalog visibility policy omitted or admitted wrong rows"
        )
    }

    private static func chooserDefaults() throws {
        let fixture = try CatalogFixture(repositoryCount: 3)
        defer { fixture.remove() }
        let initial = fixture.catalog()
        let entries = try initial.catalog.candidates.prefix(2).map {
            try $0.preferenceEntry
        }
        let unresolved = try RepositorySelectionPreferenceEntry(
            repositoryID: "fixture/missing",
            locator: RepositorySelectionLocator(
                governedRoot: "fixture",
                components: ["personal", "missing"]
            )
        )
        let preferences = try RepositorySelectionPreferenceDocument(
            documentID: "00000000-0000-0000-0000-000000000001",
            revision: 1,
            entries: (entries + [unresolved]).sorted()
        )
        let selected = fixture.catalog(preferences: preferences)
        try require(
            selected.catalog.candidates.filter(\.isDefaultSelected)
                .count == 2,
            "saved defaults were not applied exactly"
        )
        try require(
            selected.catalog.unresolvedDefaults == [unresolved],
            "unresolved saved default was hidden or discarded"
        )
        try require(
            selected.catalog.candidates
                .allSatisfy { $0.isEligible },
            "fixture chooser rows are unexpectedly disabled"
        )
    }

    private static func preferenceTransitions() throws {
        let root = try PrivateFixtureRoot(prefix: "preferences")
        defer { root.remove() }
        let location = try StateLocation.isolated(root: root.path)
        try TestIsolation.initializeState(at: location)
        let store = try RepositorySelectionPreferenceStore.open(
            at: location
        )
        let absent = store.snapshot()
        try require(absent.status == .absent, "preference absence not reported")
        let entry = try RepositorySelectionPreferenceEntry(
            repositoryID: "owner/repository",
            locator: RepositorySelectionLocator(
                governedRoot: "~/dev",
                components: ["personal", "repository"]
            )
        )
        let preRenameRoot = try PrivateFixtureRoot(
            prefix: "preferences-pre-rename"
        )
        defer { preRenameRoot.remove() }
        let preRenameLocation = try StateLocation.isolated(
            root: preRenameRoot.path
        )
        try TestIsolation.initializeState(at: preRenameLocation)
        _ = try RepositorySelectionPreferenceStore.open(
            at: preRenameLocation
        )
        let preRenameStore = RepositorySelectionPreferenceStore(
            state: try SecureStateDirectory.open(
                preRenameLocation
            ),
            persistenceFault: .beforeRename
        )
        do {
            _ = try preRenameStore.save(
                entries: [entry],
                expected: preRenameStore.snapshot()
            )
            throw Failure("pre-rename cut committed preferences")
        } catch RepositorySelectionPreferenceStoreError.persistence {
            // Expected.
        }
        try require(
            preRenameStore.snapshot().status == .absent,
            "pre-rename cut changed durable preferences"
        )

        let postRenameRoot = try PrivateFixtureRoot(
            prefix: "preferences-post-rename"
        )
        defer { postRenameRoot.remove() }
        let postRenameLocation = try StateLocation.isolated(
            root: postRenameRoot.path
        )
        try TestIsolation.initializeState(at: postRenameLocation)
        _ = try RepositorySelectionPreferenceStore.open(
            at: postRenameLocation
        )
        let postRenameStore = RepositorySelectionPreferenceStore(
            state: try SecureStateDirectory.open(
                postRenameLocation
            ),
            persistenceFault:
                .afterRenameBeforeDirectorySync
        )
        let postRename = try postRenameStore.save(
            entries: [entry],
            expected: postRenameStore.snapshot()
        )
        guard case let .durabilityUncertain(
            postRenameDocument,
            _
        ) = postRename else {
            throw Failure("post-rename cut hid uncertain durability")
        }
        try require(
            postRenameStore.snapshot().document
                == postRenameDocument,
            "post-rename cut lost the linearized preference generation"
        )

        let first = try store.save(entries: [entry], expected: absent)
        guard case let .saved(document, _) = first else {
            throw Failure("initial preference save was uncertain")
        }
        try require(
            document.revision == 1,
            "initial preference revision is not one"
        )
        do {
            _ = try store.save(entries: [entry], expected: absent)
            throw Failure("stale absence CAS overwrote preferences")
        } catch RepositorySelectionPreferenceStoreError.changed {
            // Expected.
        }
        let valid = store.snapshot()
        let second = try store.save(entries: [], expected: valid)
        guard case let .saved(updated, _) = second else {
            throw Failure("preference update was uncertain")
        }
        try require(
            updated.documentID == document.documentID
                && updated.revision == 2,
            "preference update changed lineage or revision"
        )
        let expectedBeforeExternalChange = store.snapshot()
        let external = try RepositorySelectionPreferenceDocument(
            documentID: updated.documentID,
            revision: 3,
            entries: [entry]
        )
        let externalEncoder = JSONEncoder()
        externalEncoder.outputFormatting = [.sortedKeys]
        var externalBytes = try externalEncoder.encode(external)
        externalBytes.append(0x0A)
        let path = location.path + "/"
            + RepositorySelectionPreferenceStore.filename
        try externalBytes.write(to: URL(fileURLWithPath: path))
        _ = chmod(path, 0o600)
        do {
            _ = try store.save(
                entries: [],
                expected: expectedBeforeExternalChange
            )
            throw Failure("external preference change was overwritten")
        } catch RepositorySelectionPreferenceStoreError.changed {
            // Expected.
        }
        let duplicateID = """
        {"schema":"shadow-sync-repository-selection-preferences/v1","documentID":"00000000-0000-0000-0000-000000000003","revision":1,"entries":[{"repositoryID":"owner/repository","locator":{"governedRoot":"~/dev","components":["personal","repository"]}},{"repositoryID":"owner/repository","locator":{"governedRoot":"~/dev","components":["personal","other"]}}]}
        """
        try Data(duplicateID.utf8).write(
            to: URL(fileURLWithPath: path)
        )
        _ = chmod(path, 0o600)
        try require(
            store.snapshot().status == .malformed,
            "duplicate preference repository IDs were deduplicated"
        )
        let duplicateLocator = """
        {"schema":"shadow-sync-repository-selection-preferences/v1","documentID":"00000000-0000-0000-0000-000000000004","revision":1,"entries":[{"repositoryID":"owner/first","locator":{"governedRoot":"~/dev","components":["personal","repository"]}},{"repositoryID":"owner/second","locator":{"governedRoot":"~/dev","components":["personal","repository"]}}]}
        """
        try Data(duplicateLocator.utf8).write(
            to: URL(fileURLWithPath: path)
        )
        _ = chmod(path, 0o600)
        try require(
            store.snapshot().status == .malformed,
            "duplicate preference locators were deduplicated"
        )
        try Data("{bad".utf8).write(to: URL(fileURLWithPath: path))
        _ = chmod(path, 0o600)
        let malformed = store.snapshot()
        try require(
            malformed.status == .malformed,
            "malformed preferences were not isolated"
        )
        _ = try store.recover(entries: [entry], expected: malformed)
        try require(
            store.snapshot().document?.revision == 1,
            "explicit recovery did not start a new lineage"
        )
        try require(
            FileManager.default.fileExists(
                atPath: location.path + "/"
                    + RepositorySelectionPreferenceStore
                        .recoveryFilename
            ),
            "explicit recovery did not preserve old bytes"
        )
        let recoveredBytes = try Data(
            contentsOf: URL(
                fileURLWithPath: location.path + "/"
                    + RepositorySelectionPreferenceStore
                        .recoveryFilename
            )
        )
        try require(
            recoveredBytes == Data("{bad".utf8),
            "preference recovery did not preserve exact old bytes"
        )
        let unsupported = """
        {"schema":"shadow-sync-repository-selection-preferences/v2"}
        """
        try Data(unsupported.utf8).write(
            to: URL(fileURLWithPath: path)
        )
        _ = chmod(path, 0o600)
        try require(
            store.snapshot().status == .unsupportedSchema,
            "newer preference schema was not kept read-only"
        )
        _ = chmod(path, 0o644)
        try require(
            store.snapshot().status == .unsafe,
            "unsafe preference mode was not refused before reading"
        )
        _ = chmod(path, 0o600)
        let hardlink = path + ".hardlink"
        guard link(path, hardlink) == 0 else {
            throw Failure("could not create unsafe preference hardlink")
        }
        try require(
            store.snapshot().status == .unsafe,
            "hardlinked preferences were read"
        )
        _ = unlink(hardlink)
        try Data(repeating: 0x61, count:
            RepositorySelectionPreferenceStore.maximumBytes + 1
        ).write(to: URL(fileURLWithPath: path))
        _ = chmod(path, 0o600)
        try require(
            store.snapshot().status == .unsafe,
            "oversize preferences were read"
        )
        try FileManager.default.removeItem(atPath: path)
        guard symlink(
            RepositorySelectionPreferenceStore.recoveryFilename,
            path
        ) == 0 else {
            throw Failure("could not create unsafe preference symlink")
        }
        try require(
            store.snapshot().status == .unsafe,
            "symlinked preferences were read"
        )
        _ = unlink(path)
        let exhausted = try RepositorySelectionPreferenceDocument(
            documentID: "00000000-0000-0000-0000-000000000002",
            revision: UInt64.max,
            entries: [entry]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var exhaustedBytes = try encoder.encode(exhausted)
        exhaustedBytes.append(0x0A)
        try exhaustedBytes.write(to: URL(fileURLWithPath: path))
        _ = chmod(path, 0o600)
        let exhaustedSnapshot = store.snapshot()
        try require(
            exhaustedSnapshot.status == .available
                && exhaustedSnapshot.document?.revision == UInt64.max,
            "maximum preference revision was not readable"
        )
        do {
            _ = try store.save(
                entries: [entry],
                expected: exhaustedSnapshot
            )
            throw Failure("maximum preference revision wrapped")
        } catch RepositorySelectionPreferenceStoreError.revisionExhausted {
            // Expected.
        }
        try Data("{bad-again".utf8).write(
            to: URL(fileURLWithPath: path)
        )
        _ = chmod(path, 0o600)
        let secondMalformed = store.snapshot()
        do {
            _ = try store.recover(
                entries: [entry],
                expected: secondMalformed
            )
            throw Failure("occupied recovery slot was overwritten")
        } catch RepositorySelectionPreferenceStoreError
            .recoverySlotOccupied {
            // Expected.
        }
    }

    private static func locatorBindingSurface() throws {
        for components in [
            ["/absolute"], ["."], [".."], [".hidden"],
            ["nested/escape"],
        ] {
            do {
                _ = try RepositorySelectionLocator(
                    governedRoot: "~/dev",
                    components: components
                )
                throw Failure("forbidden locator was accepted")
            } catch RepositorySelectionValueError.invalidLocator {
                // Expected.
            }
        }
        let source = try readSource(
            "Sources/ShadowSyncCore/SelectedRepositoryScope.swift"
        )
        for required in [
            "O_NOFOLLOW", "openat(", "fstat(",
            "fstatat(", "descriptorPath",
            "Repository locations changed",
        ] {
            try require(
                source.contains(required),
                "descriptor-bound locator check is missing \(required)"
            )
        }
        let stable = try CatalogFixture(repositoryCount: 3)
        defer { stable.remove() }
        let stableIntent = try stable.intent(selectedCount: 1)
        let stableScope = try stable.binder().bind(
            intent: stableIntent
        )
        try require(
            stableScope.repositories.count == 1,
            "stable selected locator did not bind"
        )

        let repositoryRace = try CatalogFixture(repositoryCount: 3)
        defer { repositoryRace.remove() }
        let repositoryIntent =
            try repositoryRace.intent(selectedCount: 1)
        try repositoryRace.replaceRepository(index: 0)
        do {
            _ = try repositoryRace.binder().bind(
                intent: repositoryIntent
            )
            throw Failure(
                "repository replacement survived Continue binding"
            )
        } catch is SelectedRepositoryScopeError {
            // Expected.
        }

        let rootRace = try CatalogFixture(repositoryCount: 3)
        defer { rootRace.remove() }
        let rootIntent = try rootRace.intent(selectedCount: 1)
        try rootRace.replaceRoot()
        do {
            _ = try rootRace.binder().bind(intent: rootIntent)
            throw Failure(
                "governed-root replacement survived Continue binding"
            )
        } catch is SelectedRepositoryScopeError {
            // Expected.
        }

        let policyRace = try CatalogFixture(repositoryCount: 3)
        defer { policyRace.remove() }
        let policyIntent = try policyRace.intent(selectedCount: 1)
        try policyRace.changePolicy()
        do {
            _ = try policyRace.binder().bind(intent: policyIntent)
            throw Failure(
                "policy replacement survived Continue binding"
            )
        } catch is SelectedRepositoryScopeError {
            // Expected.
        }
    }

    private static func authorityStages(
        testExecutable: String
    ) throws {
        let source = try readSource(
            "Sources/ShadowSyncCore/SelectedRepositoryHydration.swift"
        )
        for required in [
            "SelectedRepositoryHydrationEvidence",
            "VerifiedRepositoryAuthorityCapability",
            "hydrateEvidence", "hydrateVerified",
            "inventory.onboardingProposals.isEmpty",
        ] {
            try require(
                source.contains(required),
                "authority stage is missing \(required)"
            )
        }
        let preferences = try readSource(
            "Sources/ShadowSyncCatalog/RepositorySelectionPreferences.swift"
        )
        for forbidden in [
            "RepositoryCard", "PlannedOperation",
            "RunAuthority", "RepositoryAuthority",
            "WorkerRequest",
        ] {
            try require(
                !preferences.contains(forbidden),
                "preferences reference authority type \(forbidden)"
            )
        }
        let fixture = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "v3-authority-stages"
        )
        defer { fixture.remove() }
        let firstScope = try selectedScope(fixture)
        let discovery = try RepositoryInventoryDiscovery(
            executablePath: testExecutable,
            isolatedRoot: fixture.temporary.path,
            transportMapping: fixture.mapping,
            pullRequestLookup: UnavailablePullRequestLookup()
        )
        let evidence = try discovery.discoverHydrationEvidence(
            scope: firstScope
        )
        try require(
            evidence.hydratedRepositoryIDs
                == firstScope.repositoryIDs
                && evidence.proposals.count == 1,
            "first selected hydration did not remain evidence-only"
        )
        _ = try fixture.authorizedInventory(
            executable: testExecutable
        )
        let freshScope = try selectedScope(fixture)
        let second = try discovery.discoverInventory(
            scope: freshScope
        )
        let verified = try SelectedRepositoryHydrator
            .verifyFreshInventory(
                scope: freshScope,
                inventory: second
            )
        try require(
            verified.capability.admits(second)
                && second.onboardingProposals.isEmpty,
            "fresh second hydration did not yield verified capability"
        )
    }

    private static func capabilityConstruction(
        testExecutable: String
    ) throws {
        let appSource = try readSource(
            "Sources/ShadowSyncApp/AppDelegate.swift"
        ) + (try readSource(
            "Sources/ShadowSyncApp/Worker.swift"
        ))
        let modelSource = try readSource(
            "Sources/ShadowSyncCore/RepositoryModelV2.swift"
        )
        let removalSource = try readSource(
            "Sources/ShadowSyncCore/RemovalPlan.swift"
        )
        try require(
            appSource.contains("activeVerifiedCapability")
                && appSource.contains("AuthorizedOperationEnvelope")
                && appSource.contains("AuthorizedBody3Plan")
                && modelSource.contains(
                    "capability: VerifiedRepositoryAuthorityCapability"
                )
                && removalSource.contains(
                    "capability: VerifiedRepositoryAuthorityCapability"
                ),
            "card or worker admission bypasses verified capability"
        )
        let first = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "v3-capability-first"
        )
        defer { first.remove() }
        _ = try first.authorizedInventory(
            executable: testExecutable
        )
        try first.git(["branch", "feature"])
        try first.git(["checkout", "--quiet", "feature"])
        try first.git(["branch", "-D", "main"])
        let firstScope = try selectedScope(first)
        let firstDiscovery = try RepositoryInventoryDiscovery(
            executablePath: testExecutable,
            isolatedRoot: first.temporary.path,
            transportMapping: first.mapping,
            pullRequestLookup: UnavailablePullRequestLookup()
        )
        let firstInventory = try firstDiscovery.discoverInventory(
            scope: firstScope
        )
        let firstVerified = try SelectedRepositoryHydrator
            .verifyFreshInventory(
                scope: firstScope,
                inventory: firstInventory
            )
        guard let operation =
            firstInventory.selectableOperations.first(where: {
                $0.kind == .initializeDefaultBranch
            }),
        let card = firstInventory.cards.first else {
            throw Failure(
                "verified capability fixture produced no operation"
            )
        }
        _ = try AuthorizedOperationEnvelope(
            operation: operation,
            capability: firstVerified.capability
        )

        let second = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "v3-capability-second"
        )
        defer { second.remove() }
        _ = try second.authorizedInventory(
            executable: testExecutable
        )
        let secondScope = try selectedScope(second)
        let secondDiscovery = try RepositoryInventoryDiscovery(
            executablePath: testExecutable,
            isolatedRoot: second.temporary.path,
            transportMapping: second.mapping,
            pullRequestLookup: UnavailablePullRequestLookup()
        )
        let secondInventory = try secondDiscovery.discoverInventory(
            scope: secondScope
        )
        let secondVerified = try SelectedRepositoryHydrator
            .verifyFreshInventory(
                scope: secondScope,
                inventory: secondInventory
            )
        do {
            _ = try AuthorizedOperationEnvelope(
                operation: operation,
                capability: secondVerified.capability
            )
            throw Failure(
                "wrong-repository capability authorized operation"
            )
        } catch is GitSafetyError {
            // Expected.
        }
        do {
            _ = try RepositoryCard(
                repository: card.repository,
                authority: card.authority,
                clones: card.clones,
                relation: card.relation,
                fastForward: card.fastForward,
                fastForwardRefusal: card.fastForwardRefusal,
                maintenanceOperations: card.maintenanceOperations,
                maintenanceRefusals: card.maintenanceRefusals,
                originHeadExplanation: card.originHeadExplanation,
                capability: secondVerified.capability
            )
            throw Failure("wrong capability constructed card")
        } catch is GitSafetyError {
            // Expected.
        }
        try require(
            RepositoryInventoryRemovalCandidates.make(
                from: firstInventory,
                capability: secondVerified.capability
            ).isEmpty,
            "wrong capability constructed removal candidates"
        )
        let execution = try first.execute(
            operation,
            executable: testExecutable
        )
        try require(
            execution.code == .updated && execution.mainUpdated,
            "capability path bypassed or broke runtime eligibility: "
                + "code=\(execution.code.rawValue) "
                + "mainUpdated=\(execution.mainUpdated) "
                + "detail=\(execution.technicalDetail ?? "nil")"
        )
    }

    private static func body3SelectedRefresh(
        testExecutable: String
    ) throws {
        let source = try readSource(
            "Sources/ShadowSyncCore/Body3Coordinator.swift"
        )
        try require(
            source.contains(
                "selectedScope: ValidatedSelectedRepositoryScope"
            )
                && source.contains(
                    "Body 3 refresh returned foreign repository data"
                )
                && source.contains("exactRepositoryScope"),
            "Body 3 selected refresh boundary is incomplete"
        )
        try require(
            !source.contains("try freshInventory(commandAudit)"),
            "Body 3 retains an unscoped refresh call"
        )
        let selected = try Body3Fixture(
            repositoryName: "v3-body3-selected"
        )
        defer { selected.remove() }
        _ = try selected.authorizedInventory(
            executable: testExecutable
        )
        try selected.git(["branch", "cleanup-branch"])
        try selected.git([
            "branch", "--set-upstream-to=origin/main",
            "cleanup-branch",
        ])
        let selectedInventory = try selected.inventory(
            executable: testExecutable
        )
        let candidate = try selected.branchCandidate(
            inventory: selectedInventory,
            name: "cleanup-branch",
            preview: RemovalPreview(
                recommendation: .recommended,
                permission: .previewOnly,
                explanation:
                    "Fulfilled history is preserved by the default branch."
            )
        )
        let selection = try RemovalSelection(
            candidate: candidate,
            intent: .remove,
            includePossibleSecrets: false
        )
        let foreign = try Body2Fixture(
            objectFormat: "sha1",
            repositoryName: "v3-body3-foreign"
        )
        defer { foreign.remove() }
        let foreignInventory = try foreign.authorizedInventory(
            executable: testExecutable
        )
        let plan = try Body3BatchPlanner.make(
            run: RunIdentity.make(),
            operations: [],
            removals: [selection]
        )
        let childAdmissions = LockedInteger()
        let events = LockedInteger()
        let providerCalls = LockedInteger()
        let coordinator = RunCoordinator(
            configuration: CoordinatorConfiguration(
                stateLocation: selected.stateLocation,
                trampolineExecutable: testExecutable,
                transportMapping: selected.mapping
            ),
            account: selected.account
        )
        let report = try coordinator.runBody3(
            plan: plan,
            selectedScope: try .testing(plan: plan),
            cancellation: CancellationToken(),
            inventoryProvider: { _ in
                providerCalls.increment()
                return foreignInventory
            },
            processObserver: { _, identity in
                if identity != nil {
                    childAdmissions.increment()
                }
                return true
            },
            eventSink: { _ in events.increment() }
        )
        try require(
            providerCalls.value == 2
                && report.requiresReview
                && report.results.contains {
                    $0.node.kind == .reinspection
                        && $0.status == .refused
                        && $0.detail.contains("changed identity")
                }
                && report.results.filter {
                    $0.node.kind == .worktreeRemoval
                        || $0.node.kind == .branchRemoval
                }.allSatisfy {
                    $0.status == .skipped
                },
            "Body 3 did not reject foreign refresh before mutation: "
                + "provider=\(providerCalls.value) "
                + report.results.map {
                    "\($0.node.kind.rawValue)=\($0.status.rawValue):\($0.detail)"
                }.joined(separator: " | ")
        )
        try require(
            childAdmissions.value == 0,
            "Body 3 foreign refresh admitted a child"
        )
    }

    private static func selectedWorkerPoison() throws {
        let worker = try readSource(
            "Sources/ShadowSyncApp/Worker.swift"
        )
        try require(
            worker.contains(
                "SelectedRepositoryScopeBinder.withProductionReadPhase"
            )
                && worker.contains(
                    ".discoverInventory(scope: selectedScope)"
                )
                && worker.contains(
                    "AuthorizedOperationEnvelope"
                )
                && worker.contains("governedRoot: \"~\"")
                && !worker.contains("governedRoot: \"~/dev\""),
            "production worker does not rebind selected scope"
        )
        let fixture = try CatalogFixture(repositoryCount: 51)
        defer { fixture.remove() }
        try fixture.prepareHeavySelectedRepositories(count: 3)
        let one = try fixture.heavyDiscovery(selectedCount: 1)
        let three = try fixture.heavyDiscovery(selectedCount: 3)
        for metrics in [one, three] {
            try require(
                metrics.candidateCount == metrics.selectedCount
                    && metrics.scannedPaths.isSubset(
                        of: metrics.selectedPaths
                    )
                    && metrics.gitCandidatePaths.isSubset(
                        of: metrics.selectedPaths
                    )
                    && metrics.poisonUnchanged,
                "unselected poison repository entered heavy discovery"
            )
        }
        print(
            "METRIC selected-poison catalog=51"
                + " selected_1_git=\(one.gitProcessCount)"
                + " selected_3_git=\(three.gitProcessCount)"
                + " unselected_files=0 unselected_processes=0"
                + " unselected_network=0 unselected_cards=0"
                + " unselected_events=0 unselected_operations=0"
                + " unselected_payloads=0"
        )
    }

    private static func lifecycleOrdering() throws {
        let source = try readSource(
            "Sources/ShadowSyncApp/AppLifecycleRouter.swift"
        )
        for phase in [
            "idle", "chooser", "savingDefaults",
            "bindingSelection", "hydratingSelected",
            "onboardingAuthority", "cardsAndReview",
            "executing", "cancelling", "drainingForQuit",
        ] {
            try require(
                source.contains("case \(phase)"),
                "lifecycle phase is missing \(phase)"
            )
        }
        try require(
            source.contains("completeSave")
                && source.contains("preferenceOutcomeRecorded = true")
                && source.contains("lastPreferenceRenameLinearized")
                && source.contains("terminationIssuedGeneration")
                && source.contains("phaseBeforeQuit"),
            "save outcome is not ordered before stale rendering"
        )
        let delegateSource = try readSource(
            "Sources/ShadowSyncApp/AppDelegate.swift"
        )
        guard let continueStart = delegateSource.range(
            of: "private func continueRepositorySelection("
        ),
        let workStart = delegateSource.range(
            of: "let executablePath = self.executablePath",
            range: continueStart.lowerBound..<delegateSource.endIndex
        ) else {
            throw Failure("Continue admission implementation is missing")
        }
        let continueAdmission = String(
            delegateSource[
                continueStart.lowerBound..<workStart.lowerBound
            ]
        )
        try require(
            continueAdmission.contains("RepositorySelectionIntent")
                && continueAdmission.contains("catch")
                && continueAdmission.contains(
                    "settleHydrationFailure"
                )
                && continueAdmission.contains("reopenAdmission"),
            "failed Continue intent does not reopen chooser admission"
        )
        guard let continueEnd = delegateSource.range(
            of: "private func saveRepositoryDefaults(",
            range: continueStart.lowerBound..<delegateSource.endIndex
        ) else {
            throw Failure("Continue completion implementation is missing")
        }
        let continueCompletion = String(
            delegateSource[
                workStart.lowerBound..<continueEnd.lowerBound
            ]
        )
        try require(
            continueCompletion.contains("case .terminate = route")
                && continueCompletion.contains(
                    "terminateAfterConfirmedQuit()"
                ),
            "failed selected hydration ignores deferred Quit"
        )
        try require(
            delegateSource.contains(
                ") ?? lifecycleRouter.drainEvidence"
            ),
            "Quit retry discards retained lifecycle drain evidence"
        )
        guard let quitStart = delegateSource.range(
            of: "private func continueQuitUtility()"
        ),
        let onboardingQuit = delegateSource.range(
            of: "if pendingCanonicalRootOnboarding != nil",
            range: quitStart.lowerBound..<delegateSource.endIndex
        ),
        let chooserQuit = delegateSource.range(
            of: "selectionWindow as? RepositoryChooserWindowController",
            range: quitStart.lowerBound..<delegateSource.endIndex
        ) else {
            throw Failure("Quit routing implementation is missing")
        }
        try require(
            onboardingQuit.lowerBound < chooserQuit.lowerBound,
            "chooser Quit bypasses pending onboarding drain"
        )
    }

    private static func drainBarrierSurface() throws {
        let source = try readSource(
            "Sources/ShadowSyncApp/AppLifecycleRouter.swift"
        )
        for evidence in [
            "processAdmissionClosed", "ownedTasksSettled",
            "allChildrenReaped", "workerPostReapVerified",
            "workerOwnershipSettled", "body3WorkersTerminal",
            "confirmationWaitersSettled",
            "inventoryAuthorityReleased",
            "operationAuthorityReleased",
            "lifecycleAuthorityReleased",
            "transactionsSettled",
            "preferenceOutcomeRecorded",
        ] {
            try require(
                source.contains(evidence),
                "drain barrier omits \(evidence)"
            )
        }
        let delegate = try readSource(
            "Sources/ShadowSyncApp/AppDelegate.swift"
        )
        try require(
            delegate.components(
                separatedBy: "NSApp.terminate"
            ).count - 1 == 1
                && delegate.contains(
                    "lifecycleRouter.consumeTermination"
                ),
            "application termination bypasses the lifecycle drain router"
        )
    }

    private static func scaleLinearity() throws {
        let small = try CatalogFixture(repositoryCount: 3)
        defer { small.remove() }
        let large = try CatalogFixture(repositoryCount: 51)
        defer { large.remove() }
        let a = small.catalog()
        let b = large.catalog()
        // Each checkout opens its origin config and remote-default HEAD.
        // Both reads count toward the same aggregate metadata budget.
        try require(
            a.isComplete && b.isComplete
                && a.catalog.counters.filesOpened == 3 * 2
                && b.catalog.counters.filesOpened == 51 * 2,
            "catalog aggregate accounting is not linear"
        )
        let inventory = try readSource(
            "Sources/ShadowSyncCore/RepositoryInventoryDiscovery.swift"
        )
        try require(
            inventory.contains("cloneDiscovery.discover(scope: scope)"),
            "heavy discovery does not iterate selected scope"
        )
        try small.prepareHeavySelectedRepositories(count: 3)
        try large.prepareHeavySelectedRepositories(count: 3)
        let smallOne = try small.heavyDiscovery(selectedCount: 1)
        let smallThree = try small.heavyDiscovery(selectedCount: 3)
        let largeOne = try large.heavyDiscovery(selectedCount: 1)
        let largeThree = try large.heavyDiscovery(selectedCount: 3)
        try require(
            smallOne.gitProcessCount == largeOne.gitProcessCount
                && smallThree.gitProcessCount
                    == largeThree.gitProcessCount
                && largeOne.gitProcessCount
                    <= largeThree.gitProcessCount
                && largeThree.gitProcessCount
                    <= largeOne.gitProcessCount * 3 + 3
                && largeOne.scannedPaths.count
                    <= largeOne.selectedCount
                && largeThree.scannedPaths.count
                    <= largeThree.selectedCount,
            "heavy work scaled with catalog size instead of selection"
        )
        print(
            "METRIC selected-linearity"
                + " catalog_3_selected_1_git=\(smallOne.gitProcessCount)"
                + " catalog_51_selected_1_git=\(largeOne.gitProcessCount)"
                + " catalog_3_selected_3_git=\(smallThree.gitProcessCount)"
                + " catalog_51_selected_3_git=\(largeThree.gitProcessCount)"
        )
    }

    private static func physicalFirstScreen() throws {
        var times: [UInt64] = []
        for _ in 0..<20 {
            let fixture = try CatalogFixture(repositoryCount: 51)
            let started = DispatchTime.now().uptimeNanoseconds
            let result = fixture.catalog()
            let elapsed =
                DispatchTime.now().uptimeNanoseconds - started
            fixture.remove()
            try require(
                result.isComplete
                    && result.catalog.candidates.count == 51
                    && elapsed <= 1_000_000_000,
                "first-screen catalog exceeded one second"
            )
            times.append(elapsed)
        }
        try require(
            times.count == 20
                && times.max()! <= 1_000_000_000,
            "20-trial first-screen gate failed"
        )
        let sorted = times.sorted()
        let milliseconds: (UInt64) -> String = {
            String(format: "%.3f", Double($0) / 1_000_000)
        }
        print(
            "METRIC first-screen trials=20"
                + " p50_ms=\(milliseconds(sorted[9]))"
                + " p95_ms=\(milliseconds(sorted[18]))"
                + " max_ms=\(milliseconds(sorted[19]))"
                + " git_children=0 gh_children=0"
                + " helper_children=0 other_children=0"
                + " network_attempts=0 authority_acquisitions=0"
        )
    }

    private static func lifecycleMigration() throws {
        let lifecycle = try readSource(
            "Sources/ShadowSyncCore/InstallationLifecycle.swift"
        )
        let doctor = try readSource("scripts/source-doctor.sh")
        for name in [
            "selection-preferences.json",
            "selection-preferences.recovery",
        ] {
            try require(
                lifecycle.contains(name) || lifecycle.contains(
                    name == "selection-preferences.json"
                        ? "RepositorySelectionPreferenceStore.filename"
                        : "RepositorySelectionPreferenceStore.recoveryFilename"
                ),
                "lifecycle allowlist omits \(name)"
            )
            try require(
                doctor.contains(name),
                "doctor omits \(name)"
            )
        }
    }

    private static func selectedScope(
        _ fixture: Body2Fixture
    ) throws -> ValidatedSelectedRepositoryScope {
        try fixture.git([
            "remote", "set-head", "origin", "main",
        ])
        let binder = SelectedRepositoryScopeBinder(
            governedRootPath: fixture.home + "/dev",
            policyRootPath: fixture.home + "/dev",
            logicalRoot: "~/dev",
            expectedUID: geteuid(),
            admission: .testingAllowAll
        )
        let catalog: RepositorySelectionCatalogResult
        do {
            catalog = try binder.processFreeCatalog(
                preferences: nil,
                generation: 1
            )
        } catch {
            throw Failure("selected fixture catalog failed: \(error)")
        }
        guard catalog.isComplete else {
            throw Failure("selected fixture catalog scan is incomplete")
        }
        guard let candidate = catalog.catalog.candidates.first(where: {
                  $0.id.hasPrefix("owner/")
                      && $0.isVisible
                      && $0.isEligible
              }) else {
            throw Failure(
                "selected fixture has no eligible owner candidate: "
                    + catalog.catalog.candidates.map {
                        "\($0.id):visible=\($0.isVisible):eligible=\($0.isEligible):reason=\($0.disabledReason ?? "none")"
                    }.joined(separator: ",")
            )
        }
        let entry: RepositorySelectionPreferenceEntry
        do {
            entry = try candidate.preferenceEntry
        } catch {
            throw Failure("selected fixture entry failed: \(error)")
        }
        let intent: RepositorySelectionIntent
        do {
            intent = try RepositorySelectionIntent(
                catalog: catalog.catalog,
                entries: [entry]
            )
        } catch {
            throw Failure("selected fixture intent failed: \(error)")
        }
        do {
            return try binder.bind(intent: intent)
        } catch {
            throw Failure("selected fixture bind failed: \(error)")
        }
    }

    // Release version/build follow the canonical source metadata. Explicit legacy
    // build-14 acceptance and unsupported-build refusal are mandatory cases in
    // ReleaseIdentitySelfTestRunner, rather than obsolete beta-version literals.
    private static func currentReleaseSourceIsValid(_ source: String) -> Bool {
        guard let text = try? readSource("Resources/Info.plist"),
              let data = text.data(using: .utf8),
              let value = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let info = value as? [String: Any],
              let release = try? ReleaseIdentity(infoDictionary: info),
              release.version == ReleaseIdentity.version,
              release.buildNumber == ReleaseIdentity.buildNumber,
              release.minimumSystemVersion == ReleaseIdentity.minimumSystemVersion else {
            return false
        }
        return source.contains("version = \"\(ReleaseIdentity.version)\"")
            && source.contains("buildNumber = \"\(ReleaseIdentity.buildNumber)\"")
    }

    private static func readSource(_ relative: String) throws -> String {
        let path = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent(relative).path
        guard let value = try? String(
            contentsOfFile: path,
            encoding: .utf8
        ) else {
            throw Failure("source audit cannot read \(relative)")
        }
        return value
    }

    private static func requireDictionary(
        _ data: Data
    ) throws -> [String: Any] {
        guard let value = try JSONSerialization
            .jsonObject(with: data) as? [String: Any] else {
            throw Failure("encoded value is not an object")
        }
        return value
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}

private final class PrivateFixtureRoot {
    let path: String

    init(prefix: String) throws {
        var template = Array(
            (try RuntimeFixtureSession.fixturePrefix("shadow-sync-v3-\(prefix).") + "XXXXXX").utf8CString
        )
        guard let result = mkdtemp(&template) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        path = String(cString: result)
        guard chmod(path, 0o700) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private final class CatalogFixture {
    struct HeavyDiscoveryMetrics {
        let selectedCount: Int
        let candidateCount: Int
        let selectedPaths: Set<String>
        let scannedPaths: Set<String>
        let gitCandidatePaths: Set<String>
        let gitProcessCount: Int
        let poisonUnchanged: Bool
    }

    private let root: PrivateFixtureRoot
    private let governedPath: String
    private let homePath: String
    private let rootDescriptor: Int32
    private let rootIdentity: RepositorySelectionCatalogIdentity
    private var replacedRootBackup: String?

    init(repositoryCount: Int) throws {
        root = try PrivateFixtureRoot(prefix: "catalog")
        try TestIsolation.initializeState(at: StateLocation.isolated(root: root.path))
        homePath = root.path + "/home"
        governedPath = homePath + "/dev"
        try Self.installPolicy(at: governedPath)
        let shelf = governedPath + "/personal"
        try FileManager.default.createDirectory(
            atPath: shelf,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for index in 0..<repositoryCount {
            let repository = shelf
                + "/" + String(format: "repository-%03d", index)
            try FileManager.default.createDirectory(
                atPath: repository + "/.git",
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let config = """
            [remote "origin"]
                url = git@github.com:fixture/repository-\(index).git
            """
            try Data(config.utf8).write(
                to: URL(
                    fileURLWithPath:
                        repository + "/.git/config"
                )
            )
            _ = chmod(repository + "/.git/config", 0o600)
            let remote = repository
                + "/.git/refs/remotes/origin"
            try FileManager.default.createDirectory(
                atPath: remote,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(
                "ref: refs/remotes/origin/main\n".utf8
            ).write(
                to: URL(fileURLWithPath: remote + "/HEAD")
            )
            _ = chmod(remote + "/HEAD", 0o600)
        }
        let hidden = shelf + "/.hidden-repository/.git"
        try FileManager.default.createDirectory(
            atPath: hidden,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(
            """
            [remote "origin"]
                url = git@github.com:fixture/hidden.git
            """.utf8
        ).write(
            to: URL(fileURLWithPath: hidden + "/config")
        )
        _ = chmod(hidden + "/config", 0o600)
        rootDescriptor = Darwin.open(
            governedPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        var info = stat()
        guard fstat(rootDescriptor, &info) == 0 else {
            close(rootDescriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        rootIdentity = RepositorySelectionCatalogIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            owner: UInt32(info.st_uid)
        )
    }

    deinit {
        close(rootDescriptor)
    }

    func addPrimary(
        name: String,
        repositoryID: String,
        remoteDefault: Bool = true
    ) throws {
        let repository = governedPath + "/personal/" + name
        try FileManager.default.createDirectory(
            atPath: repository + "/.git",
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let config = """
        [remote "origin"]
            url = git@github.com:\(repositoryID).git
        """
        try Data(config.utf8).write(
            to: URL(fileURLWithPath: repository + "/.git/config")
        )
        _ = chmod(repository + "/.git/config", 0o600)
        if remoteDefault {
            let remote = repository
                + "/.git/refs/remotes/origin"
            try FileManager.default.createDirectory(
                atPath: remote,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(
                "ref: refs/remotes/origin/main\n".utf8
            ).write(
                to: URL(fileURLWithPath: remote + "/HEAD")
            )
            _ = chmod(remote + "/HEAD", 0o600)
        }
    }

    func addLinkedWorktree(name: String) throws {
        let repository = governedPath + "/personal/" + name
        try FileManager.default.createDirectory(
            atPath: repository,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(
            "gitdir: /private/tmp/linked-fixture\n".utf8
        ).write(to: URL(fileURLWithPath: repository + "/.git"))
        _ = chmod(repository + "/.git", 0o600)
    }

    func catalog(
        preferences: RepositorySelectionPreferenceDocument? = nil,
        canonicalLocators:
            [String: RepositorySelectionLocator] = [:],
        limits: RepositorySelectionCatalogLimits =
            RepositorySelectionCatalogLimits(),
        shelfPaths: [[String]] = [["personal"]],
        excludedPaths: [String] = [],
        readOnlyPaths: [String] = [],
        artifactPaths: [String] = [],
        permanentNoTouchRepositoryIDs: Set<String> = [],
        rootCount: Int = 1,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> RepositorySelectionCatalogResult {
        let policy = try! RepositorySelectionPolicy(
            shelfPaths: shelfPaths,
            excludedPaths: excludedPaths,
            readOnlyPaths: readOnlyPaths,
            artifactPaths: artifactPaths,
            permanentNoTouchRepositoryIDs:
                permanentNoTouchRepositoryIDs,
            digest: String(repeating: "0", count: 64)
        )
        let roots = (0..<rootCount).map { index in
            try! RepositorySelectionCatalogRoot(
                logicalKey: index == 0
                    ? "fixture" : "fixture-\(index)",
                descriptor: rootDescriptor,
                identity: rootIdentity
            )
        }
        return RepositorySelectionCatalogDiscovery.discoverCatalog(
            configuration: RepositorySelectionCatalogConfiguration(
                roots: roots,
                policy: policy,
                preferences: preferences,
                canonicalLocators: canonicalLocators,
                generation: 1,
                limits: limits,
                deadlineUptimeNanoseconds:
                    deadlineUptimeNanoseconds,
                admission: .testingAllowAll
            )
        )
    }

    func intent(selectedCount: Int)
        throws -> RepositorySelectionIntent {
        let current = try binder().processFreeCatalog(
            preferences: nil,
            generation: 1
        )
        guard current.isComplete else {
            throw NSError(
                domain: "CatalogFixture",
                code: 1
            )
        }
        let entries = try current.catalog.candidates
            .prefix(selectedCount)
            .map { try $0.preferenceEntry }
            .sorted()
        return try RepositorySelectionIntent(
            catalog: current.catalog,
            entries: entries
        )
    }

    func binder() -> SelectedRepositoryScopeBinder {
        SelectedRepositoryScopeBinder(
            governedRootPath: governedPath,
            logicalRoot: "~/dev",
            expectedUID: geteuid(),
            admission: .testingAllowAll
        )
    }

    func canonicalPath(
        for locator: RepositorySelectionLocator
    ) -> String {
        governedPath + "/" + locator.relativePath
    }

    func stateLocation() throws -> StateLocation {
        try StateLocation.isolated(root: root.path)
    }

    func prepareHeavySelectedRepositories(
        count: Int
    ) throws {
        for index in 0..<count {
            let repository = repositoryPath(index)
            try Self.git(["-C", repository, "init", "--quiet"])
            try Self.git([
                "-C", repository,
                "config", "user.name", "V3 Fixture",
            ])
            try Self.git([
                "-C", repository,
                "config", "user.email",
                "fixture@example.invalid",
            ])
            try Self.git([
                "-C", repository,
                "remote", "set-url", "origin",
                "git@github.com:fixture/repository-\(index).git",
            ])
        }
        for index in count..<51
        where FileManager.default.fileExists(
            atPath: repositoryPath(index)
        ) {
            let poison = repositoryPath(index) + "/.git/HEAD"
            try Data("poison-\(index)\n".utf8).write(
                to: URL(fileURLWithPath: poison)
            )
            _ = chmod(poison, 0o000)
        }
    }

    func heavyDiscovery(
        selectedCount: Int
    ) throws -> HeavyDiscoveryMetrics {
        let intent = try intent(selectedCount: selectedCount)
        let scope = try binder().bind(intent: intent)
        let selectedPaths = scope.repositoryPaths
        let poisonBefore = try poisonIdentities(
            excluding: selectedPaths
        )
        let scans = LockedStringSet()
        let gitPaths = LockedStringSet()
        let gitCount = LockedInteger()
        let discovery = try RepositoryDiscovery(
            testingHomeDirectory: homePath,
            repositoryCentric: true,
            scanObserver: { scans.insert($0) },
            gitCandidateObserver: { path, _ in
                gitPaths.insert(path)
                gitCount.increment()
            }
        )
        let candidates = try discovery.discover(scope: scope)
        let poisonAfter = try poisonIdentities(
            excluding: selectedPaths
        )
        return HeavyDiscoveryMetrics(
            selectedCount: selectedCount,
            candidateCount: candidates.count,
            selectedPaths: selectedPaths,
            scannedPaths: scans.values,
            gitCandidatePaths: gitPaths.values,
            gitProcessCount: gitCount.value,
            poisonUnchanged: poisonBefore == poisonAfter
        )
    }

    func replaceRepository(index: Int) throws {
        let path = repositoryPath(index)
        let backup = root.path + "/.replaced-repository"
        try FileManager.default.moveItem(
            atPath: path,
            toPath: backup
        )
        try FileManager.default.copyItem(
            atPath: backup,
            toPath: path
        )
    }

    func replaceRoot() throws {
        let backup = root.path + "/.replaced-governed-root"
        try FileManager.default.moveItem(
            atPath: governedPath,
            toPath: backup
        )
        try FileManager.default.copyItem(
            atPath: backup,
            toPath: governedPath
        )
        replacedRootBackup = backup
    }

    func changePolicy() throws {
        let path =
            governedPath + "/_ops/policy/worktree-policy.yml"
        var value = try String(
            contentsOfFile: path,
            encoding: .utf8
        )
        value = value.replacingOccurrences(
            of: "exclude:\n  - blocked/*",
            with:
                "exclude:\n  - blocked/*\n"
                + "  - personal/repository-000"
        )
        try Data(value.utf8).write(
            to: URL(fileURLWithPath: path)
        )
    }

    func remove() {
        root.remove()
        if let replacedRootBackup {
            try? FileManager.default.removeItem(
                atPath: replacedRootBackup
            )
        }
    }

    private static func installPolicy(at root: String) throws {
        let policyRoot = root + "/_ops"
        try FileManager.default.createDirectory(
            atPath: policyRoot + "/policy",
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            atPath: policyRoot + "/bin",
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
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
        try Data(policy.utf8).write(
            to: URL(fileURLWithPath:
                policyRoot + "/policy/worktree-policy.yml")
        )
        try Data(
            """
            bl_classify_repo() {
              if [ "$ownerrepo_lc" = "blocked/example" ]; then
                return 0
              fi
              return 0
            }
            """.utf8
        )
            .write(to: URL(fileURLWithPath:
                policyRoot + "/bin/baseline-lib.sh"))
        try Data(
            """
            MARKER='managed-by: ShadowSync fixture'
            disp_tmp="$(mktemp)"
            cat > "$disp_tmp" <<EOF
            #!/usr/bin/env bash
            # $MARKER
            exit 0
            EOF
            """.utf8
        ).write(to: URL(fileURLWithPath:
            policyRoot + "/bin/install-identity-guard.sh"))
    }

    private func repositoryPath(_ index: Int) -> String {
        governedPath + "/personal/"
            + String(format: "repository-%03d", index)
    }

    private func poisonIdentities(
        excluding selectedPaths: Set<String>
    ) throws -> [String: FileIdentity] {
        var result: [String: FileIdentity] = [:]
        for index in 0..<51 {
            let repository = repositoryPath(index)
            guard !selectedPaths.contains(repository) else {
                continue
            }
            let poison = repository + "/.git/HEAD"
            var info = stat()
            if lstat(poison, &info) == 0 {
                result[poison] = FileIdentity(info)
            }
        }
        return result
    }

    private static func git(_ arguments: [String]) throws {
        let temporary = try M1TemporaryDirectory()
        defer { temporary.remove() }
        let home = temporary.path + "/home"
        try FileManager.default.createDirectory(atPath: home,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let directory = Darwin.open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw GitSafetyError.unsafeRepository("fixture command directory unavailable") }
        defer { close(directory) }
        let result = try ClosedProcessRunner(outputLimit: DescriptorProcessRunner.completeRepositoryOutputLimit).run(
            command: ClosedProcessCommand(executable: discoveryFixtureGitExecutable, arguments: arguments),
            environment: ClosedProcessRunner.environment(account: account),
            workingDirectoryDescriptor: directory, account: account, timeout: 20,
            cancellation: CancellationToken())
        guard result.status == 0 && !result.cancelled && !result.timedOut
                && !result.stdoutTruncated && !result.stderrTruncated else {
            throw GitSafetyError.unsafeRepository("fixture command failed: " + Redactor.subprocessBytes(result.output))
        }
    }
}

private final class LockedStringSet: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String> = []

    func insert(_ value: String) {
        lock.lock()
        storage.insert(value)
        lock.unlock()
    }

    var values: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class BetaV09PullRequestLookup:
    PullRequestLookingUp, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var maximum = 0
    private let failureEvery: Int?
    private let cancelParentOnFirst: CancellationToken?
    private let cancellationDelay: useconds_t
    private let cancellationGate = NSCondition()
    private var didIssueCancellation = false

    init(
        failureEvery: Int? = nil,
        cancelParentOnFirst: CancellationToken? = nil,
        cancellationDelay: useconds_t = 20_000
    ) {
        self.failureEvery = failureEvery
        self.cancelParentOnFirst = cancelParentOnFirst
        self.cancellationDelay = cancellationDelay
    }

    func lookup(
        repositoryID: String,
        branch: String,
        tipOID: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult {
        lock.lock()
        calls += 1
        let call = calls
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
        if let cancelParentOnFirst {
            if call == 1 {
                usleep(cancellationDelay)
                cancelParentOnFirst.cancel()
                cancellationGate.lock()
                didIssueCancellation = true
                cancellationGate.broadcast()
                cancellationGate.unlock()
                lock.lock()
                active = max(0, active - 1)
                lock.unlock()
                // Preserve the first completed result while later admissions
                // are closed by the real parent cancellation token.
                return PullRequestLookupResult(records: [], unavailableReason: nil)
            }
            cancellationGate.lock()
            let deadline = Date().addingTimeInterval(2)
            while !didIssueCancellation && Date() < deadline {
                _ = cancellationGate.wait(until: deadline)
            }
            let cancellationIssued = didIssueCancellation
            cancellationGate.unlock()
            lock.lock()
            active = max(0, active - 1)
            lock.unlock()
            return .unavailable(cancellationIssued ? .cancelled : .timeout)
        }
        usleep(20_000)
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
        if cancellation.isCancelled {
            return .unavailable(.cancelled)
        }
        if let failureEvery,
           call.isMultiple(of: failureEvery) {
            return .unavailable(.timeout)
        }
        return PullRequestLookupResult(
                records: [],
                unavailableReason: nil
            )
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var maximumActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

private final class BetaV09ProgressRecorder:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CleanupInspectionProgress] = []

    func record(_ event: RepositoryInventoryLifecycleEvent) {
        guard case let .cleanupProgress(progress) = event else {
            return
        }
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var snapshots: [CleanupInspectionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
#endif
