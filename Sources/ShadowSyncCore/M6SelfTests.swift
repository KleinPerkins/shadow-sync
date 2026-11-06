#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import ShadowSyncCatalog

public enum M6SelfTestRunner {
    public static func dispatchInitializationFixture(_ arguments: [String]) -> Int32? {
        guard arguments.count == 5, arguments[1] == "--shadow-sync-initialization-crash-fixture" else { return nil }
        return FreshStateSelfTests.crashWorker(root: arguments[2], target: arguments[3], partial: arguments[4])
    }
    public static func dispatchResourceFixture(_ arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == "--shadow-sync-custody-resource-fixture" else { return nil }
        return CustodyResourcesSelfTests.child(arguments)
    }
    public static func dispatchRegistryFixture(_ arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == "--shadow-sync-custody-registry-fixture" else { return nil }
        return CustodyRegistrySelfTests.child(arguments)
    }
    public static func dispatchCustodyParentFixture(_ arguments: [String]) -> Int32? {
        guard arguments.count == 4 && arguments[1] == "--shadow-sync-custodian-parent-fixture" else { return nil }
        return CustodyHelperSelfTests.parentWorker(arguments[2], mode: arguments[3])
    }
    public static func runAll(
        record: (String) -> Void
    ) throws -> [String] {
        var passed: [String] = []
        func run(_ name: String, _ body: () throws -> Void) throws {
            try RuntimeFixtureSession.withCase(name) { try body() }
            passed.append(name)
            record(name)
        }

        try run("m6-command-graph-valid") { try CommandGraphSelfTests.run("valid") }
        try run("m6-command-graph-empty") { try CommandGraphSelfTests.run("empty") }
        try run("m6-command-graph-unknown-build") { try CommandGraphSelfTests.run("unknown-build") }
        try run("m6-command-graph-unknown-kind") { try CommandGraphSelfTests.run("unknown-kind") }
        try run("m6-command-graph-wrong-cdhash") { try CommandGraphSelfTests.run("wrong-cdhash") }
        try run("m6-command-graph-wrong-path") { try CommandGraphSelfTests.run("wrong-path") }
        try run("m6-command-graph-missing-tool") { try CommandGraphSelfTests.run("missing-tool") }
        try run("m6-command-graph-wrong-architecture") { try CommandGraphSelfTests.run("wrong-architecture") }
        try run("m6-command-graph-unknown-adapter") { try CommandGraphSelfTests.run("unknown-adapter") }
        try run("m6-command-graph-missing-receipt") { try CommandGraphSelfTests.run("missing-receipt") }
        try run("m6-command-graph-extra-key") { try CommandGraphSelfTests.run("extra-key") }
        try run("m6-command-graph-duplicate-entry") { try CommandGraphSelfTests.run("duplicate-entry") }
        try run("m6-command-graph-duplicate-key") { try CommandGraphSelfTests.run("duplicate-key") }

        try run("m6-release-identity-contract") {
            let first = try identity(revision: String(repeating: "a", count: 40))
            let second = try identity(revision: String(repeating: "b", count: 40))
            try check(first != second, "producing revisions were not retained")
            try check(
                !first.sameInstallContract(as: second),
                "different source revisions reconciled as the same release"
            )
            try first.validate(requireProduction: true)
        }

        try run("m6-release-identity-refusals") {
            var dictionary: [String: Any] = [
                "CFBundleIdentifier": ReleaseIdentity.bundleIdentifier,
                "CFBundleExecutable": "ShadowSync",
                "ShadowSyncReleaseSchema": ReleaseIdentity.schemaName,
                "CFBundleShortVersionString": ReleaseIdentity.version,
                "CFBundleVersion": ReleaseIdentity.buildNumber,
                "ShadowSyncSourceRevision": String(repeating: "a", count: 40),
                "ShadowSyncSourceInputSHA256": String(repeating: "b", count: 64),
                "ShadowSyncReleaseContractSHA256": String(repeating: "c", count: 64),
                "ShadowSyncArchitecture": "arm64",
                "LSMinimumSystemVersion": ReleaseIdentity.minimumSystemVersion,
                "ShadowSyncBuildMode": "production",
            ]
            _ = try ReleaseIdentity(infoDictionary: dictionary)
            dictionary["CFBundleShortVersionString"] = "0.10.1"
            dictionary["CFBundleVersion"] = "16"
            _ = try ReleaseIdentity(infoDictionary: dictionary)
            dictionary["CFBundleShortVersionString"] =
                ReleaseIdentity.version
            dictionary["CFBundleVersion"] = "15"
            _ = try ReleaseIdentity(infoDictionary: dictionary)
            guard let currentBuild = Int(
                ReleaseIdentity.buildNumber
            ) else {
                throw M6SelfTestError.message(
                    "current build number is invalid"
                )
            }
            dictionary["CFBundleVersion"] =
                String(currentBuild + 1)
            _ = try ReleaseIdentity(infoDictionary: dictionary)
            dictionary["CFBundleVersion"] =
                ReleaseIdentity.buildNumber
            dictionary["ShadowSyncSourceInputSHA256"] = "../unsafe"
            do {
                _ = try ReleaseIdentity(infoDictionary: dictionary)
                throw M6SelfTestError.message("invalid source digest was accepted")
            } catch is ReleaseIdentityError {}
        }

        try run("m6-lifecycle-run-lock-race") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let location = try StateLocation.isolated(root: root)
            try TestIsolation.initializeState(at: location)
            let run = try RunAuthority.acquireRun(at: location)
            defer { run.release() }
            do {
                _ = try RunAuthority.acquireLifecycleMutation(at: location)
                throw M6SelfTestError.message("lifecycle mutation overlapped a run")
            } catch let SecureStateError.contention(name) {
                try check(name == "lifecycle.lock", "wrong lifecycle contention: \(name)")
            }
        }

        try run("m6-surviving-operation-lease") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let location = try StateLocation.isolated(root: root)
            try TestIsolation.initializeState(at: location)
            let run = try RunAuthority.acquireRun(at: location)
            let lease = try run.duplicateOperationLease()
            run.release()
            defer { close(lease) }
            do {
                _ = try RunAuthority.acquireLifecycleMutation(at: location)
                throw M6SelfTestError.message("lifecycle mutation ignored operation lease")
            } catch let SecureStateError.contention(name) {
                try check(name == "operation.lock", "wrong operation contention: \(name)")
            }
        }

        try run("m6-host-control-actions") {
            let generation = RunIdentity.make()
            for action in [
                HostControlAction.activate,
                .readiness,
                .lifecycleExit,
            ] {
                let request = HostControlRequest(
                    action: action,
                    expectedGeneration: generation
                )
                let data = try JSONEncoder().encode(request)
                let decoded = try JSONDecoder().decode(
                    HostControlRequest.self,
                    from: data
                )
                try check(decoded == request, "host action did not round-trip")
            }
        }

        try run("m6-launcher-handoff-single-owner") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let location = try StateLocation.isolated(root: root)
            try TestIsolation.initializeState(at: location)
            let first = try LauncherAuthority.acquire(at: location)
            defer { first.release() }
            do {
                _ = try LauncherAuthority.acquire(at: location)
                throw M6SelfTestError.message("duplicate launcher acquired authority")
            } catch let SecureStateError.contention(name) {
                try check(name == "launcher.lock", "wrong launcher contention: \(name)")
            }
        }

        try run("m6-retired-lock-namespace-cannot-split") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let location = try StateLocation.isolated(root: root)
            try TestIsolation.initializeState(at: location)
            let authority = try RunAuthority.acquireLifecycleMutation(at: location)
            let state = authority.stateDirectory
            try authority.acquireRetirementNamespace()
            try state.removeStableLockFiles()
            do {
                _ = try LauncherAuthority.acquire(at: location)
                throw M6SelfTestError.message(
                    "replacement lock namespace bypassed retained-log authority"
                )
            } catch let SecureStateError.contention(name) {
                try check(name == "latest.log", "wrong retired-namespace contention")
            }
            for name in [
                "launcher.lock", "lifecycle.lock", "operation.lock", "run.lock",
            ] {
                var info = stat()
                try check(
                    fstatat(
                        state.descriptor.value,
                        name,
                        &info,
                        AT_SYMLINK_NOFOLLOW
                    ) != 0 && errno == ENOENT,
                    "retired lock was recreated while namespace authority was held"
                )
            }
            authority.release()
            do {
                _ = try LauncherAuthority.acquire(at: location)
                throw M6SelfTestError.message("ordinary launcher recreated retired controls")
            } catch is SecureStateError {}
        }

        try run("m6-custody-held-description-identity", CustodyLeaseSelfTests.identity)
        try run("m6-custody-release-preserves-all-leases", CustodyLeaseSelfTests.releasePreservesLeases)
        try run("m6-custody-duplicate-bundles-retain-lease-family", CustodyLeaseSelfTests.retainedFamily)
        try run("m6-custody-read-mode-contention", CustodyLeaseSelfTests.readContention)
        try run("m6-custody-observation-under-operation", CustodyLeaseSelfTests.observationUnderOperation)
        try run("m6-custody-retirement-fence", CustodyLeaseSelfTests.retirementFence)
        try run("m6-custody-retirement-before-concurrent-borrow", CustodyLeaseSelfTests.retirementOrdering)
        try run("m6-custody-inherited-lock-continuity", CustodyLeaseSelfTests.inheritedContinuity)
        try run("m6-custody-closed-and-partial-refusal", CustodyLeaseSelfTests.partialRefusal)
        try run("m6-custody-duplicate-release-ordering", CustodyLeaseSelfTests.releaseOrdering)
        try run("m6-custody-replaced-lock-refusal", CustodyLeaseSelfTests.replacedLock)
        try run("m6-custody-drift-and-read-rollback", CustodyLeaseSelfTests.driftAndRollback)
        try run("m6-custody-private-state-acl", CustodyLeaseSelfTests.privateACL)
        try run("m6-custody-no-implicit-initialization", CustodyLeaseSelfTests.noImplicitInitialization)

        try run("m6-discovery-owner-round-trip") { try CustodyCatalogSelfTests.resourceOwner("round-trip") }
        try run("m6-discovery-owner-empty") { try CustodyCatalogSelfTests.resourceOwner("empty") }
        try run("m6-discovery-owner-collision-directory") { try CustodyCatalogSelfTests.resourceOwner("collision-directory") }
        try run("m6-discovery-owner-collision-file") { try CustodyCatalogSelfTests.resourceOwner("collision-file") }
        try run("m6-discovery-owner-collision-symlink") { try CustodyCatalogSelfTests.resourceOwner("collision-symlink") }
        try run("m6-discovery-owner-replacement-file") { try CustodyCatalogSelfTests.resourceOwner("replacement-file") }
        try run("m6-discovery-owner-hardlink") { try CustodyCatalogSelfTests.resourceOwner("hardlink") }
        try run("m6-discovery-owner-extra-entry") { try CustodyCatalogSelfTests.resourceOwner("extra-entry") }
        try run("m6-discovery-owner-cancel-create") { try CustodyCatalogSelfTests.resourceOwner("cancel-create") }
        try run("m6-discovery-owner-retire-before-create") { try CustodyCatalogSelfTests.resourceOwner("retire-before-create") }
        try run("m6-discovery-owner-persist-before-swap") { try CustodyCatalogSelfTests.resourceOwner("persist-before-swap") }
        try run("m6-discovery-owner-persist-after-swap") { try CustodyCatalogSelfTests.resourceOwner("persist-after-swap") }
        try run("m6-discovery-owner-persist-after-sync") { try CustodyCatalogSelfTests.resourceOwner("persist-after-sync") }
        try run("m6-discovery-owner-persist-after-unlink") { try CustodyCatalogSelfTests.resourceOwner("persist-after-unlink") }
        try run("m6-discovery-owner-afterIntent") { try CustodyCatalogSelfTests.resourceOwner("afterIntent") }
        try run("m6-discovery-owner-afterMkdir") { try CustodyCatalogSelfTests.resourceOwner("afterMkdir") }
        try run("m6-discovery-owner-afterDirectoryOpen") { try CustodyCatalogSelfTests.resourceOwner("afterDirectoryOpen") }
        try run("m6-discovery-owner-afterDirectoryReceipt") { try CustodyCatalogSelfTests.resourceOwner("afterDirectoryReceipt") }
        try run("m6-discovery-owner-afterFileOpen") { try CustodyCatalogSelfTests.resourceOwner("afterFileOpen") }
        try run("m6-discovery-owner-afterFileReceipt") { try CustodyCatalogSelfTests.resourceOwner("afterFileReceipt") }
        try run("m6-discovery-owner-afterWrite") { try CustodyCatalogSelfTests.resourceOwner("afterWrite") }
        try run("m6-discovery-owner-afterFileSeal") { try CustodyCatalogSelfTests.resourceOwner("afterFileSeal") }
        try run("m6-discovery-owner-afterDirectorySeal") { try CustodyCatalogSelfTests.resourceOwner("afterDirectorySeal") }
        try run("m6-discovery-owner-afterReadOnlyOpen") { try CustodyCatalogSelfTests.resourceOwner("afterReadOnlyOpen") }
        try run("m6-discovery-owner-afterSealReceipt") { try CustodyCatalogSelfTests.resourceOwner("afterSealReceipt") }
        try run("m6-discovery-owner-afterDirectoryUnseal") { try CustodyCatalogSelfTests.resourceOwner("afterDirectoryUnseal") }
        try run("m6-discovery-owner-afterFileUnseal") { try CustodyCatalogSelfTests.resourceOwner("afterFileUnseal") }
        try run("m6-discovery-owner-afterFileUnlink") { try CustodyCatalogSelfTests.resourceOwner("afterFileUnlink") }
        try run("m6-discovery-owner-afterFileUnlinkSync") { try CustodyCatalogSelfTests.resourceOwner("afterFileUnlinkSync") }
        try run("m6-discovery-owner-afterFileRemovalReceipt") { try CustodyCatalogSelfTests.resourceOwner("afterFileRemovalReceipt") }
        try run("m6-discovery-owner-afterDirectoryUnlink") { try CustodyCatalogSelfTests.resourceOwner("afterDirectoryUnlink") }
        try run("m6-discovery-owner-afterParentSync") { try CustodyCatalogSelfTests.resourceOwner("afterParentSync") }
        try run("m6-discovery-owner-afterDirectoryRemovalReceipt") { try CustodyCatalogSelfTests.resourceOwner("afterDirectoryRemovalReceipt") }
        try run("m6-discovery-owner-afterRetiredReceipt") { try CustodyCatalogSelfTests.resourceOwner("afterRetiredReceipt") }
        try run("m6-discovery-resource-planned-wire") { try CustodyCatalogSelfTests.resourceReceipt("planned-wire") }
        try run("m6-discovery-resource-planned-missing") { try CustodyCatalogSelfTests.resourceReceipt("planned-missing") }
        try run("m6-discovery-resource-planned-binding") { try CustodyCatalogSelfTests.resourceReceipt("planned-binding") }
        try run("m6-discovery-resource-terminal-unretired") { try CustodyCatalogSelfTests.resourceReceipt("terminal-unretired") }
        try run("m6-discovery-resource-terminal-archive") { try CustodyCatalogSelfTests.resourceReceipt("terminal-archive") }
        try run("m6-discovery-resource-archive-missing") { try CustodyCatalogSelfTests.resourceReceipt("archive-missing") }
        try run("m6-discovery-resource-round-trip") { try CustodyCatalogSelfTests.resourceReceipt("round-trip") }
        try run("m6-discovery-resource-closed-shape") { try CustodyCatalogSelfTests.resourceReceipt("closed-shape") }
        try run("m6-discovery-resource-transitions") { try CustodyCatalogSelfTests.resourceReceipt("transitions") }
        try run("m6-discovery-resource-unsafe-nodes") { try CustodyCatalogSelfTests.resourceReceipt("unsafe-nodes") }
        try run("m6-discovery-resource-namespace") { try CustodyCatalogSelfTests.resourceReceipt("namespace") }
        try run("m6-discovery-resource-durable") { try CustodyCatalogSelfTests.resourceReceipt("durable") }
        try run("m6-discovery-resource-stale") { try CustodyCatalogSelfTests.resourceReceipt("stale") }
        try run("m6-discovery-resource-missing") { try CustodyCatalogSelfTests.resourceReceipt("missing") }
        try run("m6-discovery-resource-binding") { try CustodyCatalogSelfTests.resourceReceipt("binding") }
        try run("m6-discovery-resource-unsafe-file") { try CustodyCatalogSelfTests.resourceReceipt("unsafe-file") }
        try run("m6-discovery-resource-before-swap") { try CustodyCatalogSelfTests.resourceReceipt("before-swap") }
        try run("m6-discovery-resource-after-swap") { try CustodyCatalogSelfTests.resourceReceipt("after-swap") }
        try run("m6-discovery-resource-after-sync") { try CustodyCatalogSelfTests.resourceReceipt("after-sync") }
        try run("m6-discovery-resource-after-unlink") { try CustodyCatalogSelfTests.resourceReceipt("after-unlink") }
        try run("m6-catalog-canonical-journal-privacy") { try CustodyCatalogSelfTests.roundTripPrivacy() }
        try run("m6-catalog-closed-journal-shape") { try CustodyCatalogSelfTests.closedJournalShape() }
        try run("m6-catalog-canonical-types-and-bounds") { try CustodyCatalogSelfTests.canonicalTypes() }
        try run("m6-catalog-closed-transition-model") { try CustodyCatalogSelfTests.closedTransitions() }
        try run("m6-catalog-process-observation-shape") { try CustodyCatalogSelfTests.processObservations() }
        try run("m6-catalog-required-initialization-marker") { try CustodyCatalogSelfTests.catalogShape() }
        try run("m6-catalog-capacity-duplicates-order") { try CustodyCatalogSelfTests.catalogBounds() }
        try run("m6-catalog-durable-preparation") { try CustodyCatalogSelfTests.durablePreparation() }
        try run("m6-catalog-two-empty-scope-recheck") { try CustodyCatalogSelfTests.staleEmptyScopes() }
        try run("m6-catalog-live-reference-scope") { try CustodyCatalogSelfTests.liveReferenceScope() }
        try run("m6-catalog-closed-scope-refusal") { try CustodyCatalogSelfTests.closedScope() }
        try run("m6-catalog-draining-scope-refusal") { try CustodyCatalogSelfTests.drainingScope() }
        try run("m6-catalog-expired-scope-refusal") { try CustodyCatalogSelfTests.expiredScope() }
        try run("m6-catalog-fixed-observation-coexistence") { try CustodyCatalogSelfTests.observationScope() }
        try run("m6-catalog-stable-guard-contention") { try CustodyCatalogSelfTests.guardContention() }
        try run("m6-catalog-no-implicit-initialization") { try CustodyCatalogSelfTests.missingInitialization() }
        try run("m6-catalog-missing-controls-refuse") { try CustodyCatalogSelfTests.missingControls() }
        try run("m6-catalog-missing-last-journal-fence") { try CustodyCatalogSelfTests.missingExpectedJournal() }
        try run("m6-catalog-orphan-journal-fence") { try CustodyCatalogSelfTests.orphanJournal() }
        try run("m6-catalog-journal-binding-mismatch") { try CustodyCatalogSelfTests.mismatchedJournal() }
        try run("m6-catalog-unsafe-metadata-refusal") { try CustodyCatalogSelfTests.unsafeMetadata() }
        try run("m6-catalog-stale-writer-cursor") { try CustodyCatalogSelfTests.staleCursor() }
        try run("m6-catalog-archive-before-retirement") { try CustodyCatalogSelfTests.archiveRetirement() }
        try run("m6-catalog-fault-before-swap") { try CustodyCatalogSelfTests.faultCut(.beforeSwap) }
        try run("m6-catalog-fault-after-swap") { try CustodyCatalogSelfTests.faultCut(.afterSwap) }
        try run("m6-catalog-fault-after-directory-sync") { try CustodyCatalogSelfTests.faultCut(.afterDirectorySync) }
        try run("m6-catalog-committed-cleanup-failure") { try CustodyCatalogSelfTests.committedCleanupFailure() }
        try run("m6-catalog-fault-after-reservation") { try CustodyCatalogSelfTests.faultCut(.afterReservation) }
        try run("m6-catalog-fault-after-prepared") { try CustodyCatalogSelfTests.faultCut(.afterPrepared) }
        try run("m6-catalog-fault-after-archive") { try CustodyCatalogSelfTests.retirementFault(.afterArchive) }
        try run("m6-catalog-fault-after-retirement") { try CustodyCatalogSelfTests.retirementFault(.afterRetirement) }
        try run("m6-catalog-tampered-archive-refusal") { try CustodyCatalogSelfTests.retirementFault(.afterRetirement, tamper: true) }
        try run("m6-catalog-concurrent-read-reservations") { try CustodyCatalogSelfTests.concurrentReservations() }
        try run("m6-recovery-same-boot-refusal") { try CustodyRecoverySelfTests.sameBoot() }
        try run("m6-recovery-prior-prepared-preservation") { try CustodyRecoverySelfTests.priorBoot(executing: false) }
        try run("m6-recovery-prior-executing-preservation") { try CustodyRecoverySelfTests.priorBoot(executing: true) }
        try run("m6-recovery-mixed-boot-refusal") { try CustodyRecoverySelfTests.mixedBoot() }
        try run("m6-recovery-fresh-exclusive-original-locks") { try CustodyRecoverySelfTests.exclusiveLocks() }
        try run("m6-recovery-missing-controls-refusal") { try CustodyRecoverySelfTests.missingControls() }
        try run("m6-recovery-replaced-lock-refusal") { try CustodyRecoverySelfTests.replacedLock() }
        try run("m6-recovery-malformed-record-refusal") { try CustodyRecoverySelfTests.malformed() }
        try run("m6-recovery-preimage-crash-retry") { try CustodyRecoverySelfTests.retry(.afterRecoveryPreimage) }
        try run("m6-recovery-journal-crash-retry") { try CustodyRecoverySelfTests.retry(.afterRecoveryJournal) }
        try run("m6-recovery-earlier-recovery-boot-retry") { try CustodyRecoverySelfTests.earlierRecoveryBoot() }
        try run("m6-recovery-tampered-preimage-refusal") { try CustodyRecoverySelfTests.tamperedPreimage() }
        try run("m6-recovery-revalidation-fence") { try CustodyRecoverySelfTests.revalidationFence() }
        try run("m6-recovery-before-write-failure") { try CustodyRecoverySelfTests.retry(.beforeSwap) }
        try run("m6-recovery-after-write-failure") { try CustodyRecoverySelfTests.retry(.afterDirectorySync) }
        try run("m6-recovery-interrupted-journal-swap") { try CustodyRecoverySelfTests.interruptedSwap() }
        try run("m6-recovery-old-lock-binding-refusal") { try CustodyRecoverySelfTests.bindingMismatch() }
        try run("m6-initialization-publication-and-retained-locks") { try FreshStateSelfTests.publication() }
        try run("m6-initialization-ordinary-executable-refusal") { try FreshStateSelfTests.publisherRefusal() }
        try run("m6-initialization-existing-state-refusal") { try FreshStateSelfTests.existingState() }
        try run("m6-initialization-legacy-state-refusal") { try FreshStateSelfTests.legacyState() }
        try run("m6-initialization-missing-parent-refusal") { try FreshStateSelfTests.missingParent() }
        try run("m6-initialization-guard-contention") { try FreshStateSelfTests.guardContention() }
        try run("m6-initialization-unsafe-control-refusal") { try FreshStateSelfTests.unsafeControls() }
        try run("m6-initialization-wrong-release-refusal") { try FreshStateSelfTests.wrongRelease() }
        try run("m6-initialization-unknown-staging-refusal") { try FreshStateSelfTests.unknownStage() }
        try run("m6-initialization-missing-phase-refusal") { try FreshStateSelfTests.missingPhase() }
        try run("m6-initialization-corrupt-phase-refusal") { try FreshStateSelfTests.corruptPhase() }
        try run("m6-initialization-published-catalog-not-recreated") { try FreshStateSelfTests.missingCatalog() }
        try run("m6-initialization-completed-root-replacement-refusal") { try FreshStateSelfTests.completedRootReplacement() }
        try run("m6-initialization-retry-aftermanifest") { try FreshStateSelfTests.retry(.afterManifest) }
        try run("m6-initialization-retry-afterstage") { try FreshStateSelfTests.retry(.afterStage) }
        try run("m6-initialization-retry-aftercreated") { try FreshStateSelfTests.retry(.afterCreated) }
        try run("m6-initialization-retry-afterfiles") { try FreshStateSelfTests.retry(.afterFiles) }
        try run("m6-initialization-retry-afterready") { try FreshStateSelfTests.retry(.afterReady) }
        try run("m6-initialization-retry-afterpublication") { try FreshStateSelfTests.retry(.afterPublication) }
        try run("m6-initialization-ready-stage-missing-controls") { try FreshStateSelfTests.readyControls(replace: false) }
        try run("m6-initialization-ready-stage-replaced-controls") { try FreshStateSelfTests.readyControls(replace: true) }
        try run("m6-initialization-temporary-prefix-refusal") { try FreshStateSelfTests.badTemporary() }
        try run("m6-initialization-temporary-create-retry") { try FreshStateSelfTests.writeRetry(partial: false) }
        try run("m6-initialization-partial-write-retry") { try FreshStateSelfTests.writeRetry(partial: true) }
        try run("m6-initialization-actual-process-death-retry") { try FreshStateSelfTests.processDeath() }
        try run("m6-initialization-missing-established-guard") { try FreshStateSelfTests.establishedGuard(replace: false) }
        try run("m6-initialization-replaced-established-guard") { try FreshStateSelfTests.establishedGuard(replace: true) }
        try run("m6-resources-sealed-request-self-binding") { try CustodyResourcesSelfTests.requestBinding() }
        try run("m6-resources-sealed-input-code") { try CustodyResourcesSelfTests.inputCode() }
        try run("m6-resources-closed-size-bounds") { try CustodyResourcesSelfTests.resourceBounds() }
        try run("m6-resources-snapshot-drift-refusal") { try CustodyResourcesSelfTests.immutableSnapshot() }
        try run("m6-resources-retained-working-directory") { try CustodyResourcesSelfTests.retainsCWD() }
        try run("m6-resources-unsafe-working-directory-refusal") { try CustodyResourcesSelfTests.workingDirectoryRefusal() }
        try run("m6-resources-closed-scope-refusal") { try CustodyResourcesSelfTests.closedScope() }
        try run("m6-resources-private-journal-digest") { try CustodyResourcesSelfTests.journalBinding() }
        try run("m6-resources-single-mapping-transfer") { try CustodyResourcesSelfTests.singleTransfer() }
        try run("m6-resources-pipe-drift-refusal") { try CustodyResourcesSelfTests.pipeDrift() }
        try run("m6-resources-sole-writer-liveness-eof") { try CustodyResourcesSelfTests.livenessEOF() }
        try run("m6-resources-helper-output-copy-release") { try CustodyResourcesSelfTests.outputEOF() }
        try run("m6-resources-bounded-pipe-backpressure") { try CustodyResourcesSelfTests.backpressure() }
        try run("m6-resources-broken-peer-no-sigpipe") { try CustodyResourcesSelfTests.brokenPeer() }
        try run("m6-resources-mapping-resource-retention") { try CustodyResourcesSelfTests.scopeRetention() }
        try run("m6-resources-request-cursor-preserved") { try CustodyResourcesSelfTests.requestPosition() }
        try run("m6-resources-native-closed-descriptor-inheritance") { try CustodyResourcesSelfTests.nativeInheritance() }
        try run("m6-resources-native-inherited-writer-refusal") { try CustodyResourcesSelfTests.nativeInheritance(leakWriter: true) }
        try run("m6-resources-native-extra-descriptor-refusal") { try CustodyResourcesSelfTests.nativeInheritance(extraDescriptor: true) }
        try run("m6-resources-native-destination-collisions") { try CustodyResourcesSelfTests.nativeCollisions() }
        try run("m6-resources-partial-construction-cleanup") { try CustodyResourcesSelfTests.partialConstruction() }
        try run("m6-registry-durable-refusal-reap-retire") { try CustodyRegistrySelfTests.native("refuse") }
        try run("m6-registry-receipt-before-exit-retention") { try CustodyRegistrySelfTests.native("delayed-exit") }
        try run("m6-registry-missing-terminal-retains") { try CustodyRegistrySelfTests.native("missing", pending: true) }
        try run("m6-registry-wrong-digest-retains") { try CustodyRegistrySelfTests.native("wrong-digest", pending: true) }
        try run("m6-registry-wrong-owner-retains") { try CustodyRegistrySelfTests.native("wrong-owner", pending: true) }
        try run("m6-registry-crash-retains") { try CustodyRegistrySelfTests.native("crash", pending: true) }
        try run("m6-registry-malformed-status-drains-output") { try CustodyRegistrySelfTests.native("malformed", pending: true) }
        try run("m6-registry-cancel-control-no-helper-kill") { try CustodyRegistrySelfTests.native("cancel", cancel: true) }
        try run("m6-registry-exclusive-writer-eof") { try CustodyRegistrySelfTests.native("eof", eof: true) }
        try run("m6-registry-no-spawn-retirement-proof") { try CustodyRegistrySelfTests.bootstrap(.beforeSpawn) }
        try run("m6-registry-anchored-unresumed-proof") { try CustodyRegistrySelfTests.bootstrap(.afterAnchor) }
        try run("m6-registry-transferred-unresumed-proof") { try CustodyRegistrySelfTests.bootstrap(.afterOwner) }
        try run("m6-registry-closed-scope-refusal") { try CustodyRegistrySelfTests.closedScope() }
        try run("m6-registry-lost-handle-still-reaped") { try CustodyRegistrySelfTests.lostHandle() }
        try run("m6-registry-cancel-before-ready") { try CustodyRegistrySelfTests.native("early-cancel") }
        try run("m6-registry-terminal-output-overflow-retains") { try CustodyRegistrySelfTests.native("terminal-overflow", pending: true) }
        try run("m6-registry-terminal-nonzero-helper-retains") { try CustodyRegistrySelfTests.native("terminal-error-exit", pending: true) }
        try run("m6-registry-deadline-independent-of-queue") { try CustodyRegistrySelfTests.boundedWait() }
        try run("m6-registry-aggregate-output-reservation") { try CustodyRegistrySelfTests.outputReservation() }
        try run("m6-registry-queued-start-deadline") { try CustodyRegistrySelfTests.queuedStartDeadline() }
        try run("m6-context-unbundled-publisher-refusal") { try CustodyContextSelfTests.unsignedFactory() }
        try run("m6-context-read-scope-exclusion") { try CustodyContextSelfTests.readScopes() }
        try run("m6-context-read-phase-return-release") { try CustodyContextSelfTests.phaseReturn() }
        try run("m6-context-read-phase-throw-release") { try CustodyContextSelfTests.phaseThrow() }
        try run("m6-context-escaped-binder-refuses-before-access") { try CustodyContextSelfTests.escapedBinder() }
        try run("m6-context-borrowed-phase-parent-authority") { try CustodyContextSelfTests.borrowedPhase() }
        try run("m6-context-closed-diagnostic-preparation") { try CustodyContextSelfTests.closedDiagnostics() }
        try run("m6-context-fixed-system-root-cwd") { try CustodyContextSelfTests.fixedRoot() }
        try run("m6-context-borrowed-run-retirement") { try CustodyContextSelfTests.borrowedRun() }
        try run("m6-context-staged-observation-no-operation") { try CustodyContextSelfTests.stagedObservation() }
        try run("m6-context-observation-source-retirement") { try CustodyContextSelfTests.observationSourceClose() }
        try run("m6-context-wrong-state-binding") { try CustodyContextSelfTests.wrongState() }
        try run("m6-context-replaced-state-binding") { try CustodyContextSelfTests.replacedState() }
        try run("m6-context-missing-catalog-refusal") { try CustodyContextSelfTests.missingCatalog() }
        try run("m6-context-foreign-fence-observation-only") { try CustodyContextSelfTests.foreignFence() }
        try run("m6-context-single-use-registry-retention") { try CustodyContextSelfTests.singleUseAndRetention() }
        try run("m6-context-queued-source-retirement") { try CustodyContextSelfTests.queuedSourceRetirement() }
        try run("m6-context-closed-before-submission") { try CustodyContextSelfTests.closedBeforeSubmit() }
        try run("m6-context-original-absolute-budget") { try CustodyContextSelfTests.originalBudget() }
        try run("m6-context-observation-source-disappearance") { try CustodyContextSelfTests.observationSourceDisappearance() }
        try run("m6-context-bounded-metadata-close") { try CustodyContextSelfTests.boundedMetadataClose() }
        try run("m6-helper-bare-production-refusal") { try CustodyHelperSelfTests.bare() }
        try run("m6-helper-early-timeout-state") { try CustodyHelperSelfTests.earlyTimeout(refusals: false) }
        try run("m6-helper-early-timeout-refusals") { try CustodyHelperSelfTests.earlyTimeout(refusals: true) }
        try run("m6-helper-serial-policy-timeout") { try CustodyHelperSelfTests.serial("serial-policy-timeout") }
        try run("m6-helper-serial-system-overflow") { try CustodyHelperSelfTests.serial("serial-system-overflow") }
        try run("m6-helper-serial-policy-overflow") { try CustodyHelperSelfTests.serial("serial-policy-overflow") }
        try run("m6-configuration-policy-plan") { try CustodyHelperSelfTests.configurationPlan(refusals: false) }
        try run("m6-configuration-policy-plan-refusals") { try CustodyHelperSelfTests.configurationPlan(refusals: true) }
        try run("m6-helper-serial-policy-protected") { try CustodyHelperSelfTests.serial("serial-policy-protected") }
        try run("m6-helper-serial-policy-malformed") { try CustodyHelperSelfTests.serial("serial-policy-malformed") }
        try run("m6-helper-serial-policy-wrong-nonce") { try CustodyHelperSelfTests.serial("serial-policy-wrong-nonce") }
        try run("m6-helper-serial-policy-wrong-binding") { try CustodyHelperSelfTests.serial("serial-policy-wrong-binding") }
        try run("m6-helper-serial-policy-multiple-batches") { try CustodyHelperSelfTests.serial("serial-policy-multiple-batches") }
        try run("m6-helper-serial-system-missing") { try CustodyHelperSelfTests.serial("serial-system-missing") }
        try run("m6-helper-serial-system-missing-next-before-spawn") { try CustodyHelperSelfTests.serial("serial-system-missing-next-before-spawn") }
        try run("m6-helper-serial-system-missing-next-after-spawn") { try CustodyHelperSelfTests.serial("serial-system-missing-next-after-spawn") }
        try run("m6-helper-serial-system-missing-next-before-record") { try CustodyHelperSelfTests.serial("serial-system-missing-next-before-record") }
        try run("m6-helper-serial-policy-code-batches") { try CustodyHelperSelfTests.serial("serial-policy-code-batches") }
        try run("m6-helper-serial-postflight-cancel") { try CustodyHelperSelfTests.serial("serial-postflight-cancel", cancelAt: 2) }
        try run("m6-helper-serial-postflight-eof") { try CustodyHelperSelfTests.serial("serial-postflight-eof", cancelAt: 2, eof: true) }
        try run("m6-helper-serial-postflight-timeout") { try CustodyHelperSelfTests.serial("serial-postflight-timeout") }
        try run("m6-helper-serial-complete") { try CustodyHelperSelfTests.serial("serial-complete") }
        try run("m6-helper-serial-system-failure") { try CustodyHelperSelfTests.serial("serial-system-failure") }
        try run("m6-helper-serial-policy-failure") { try CustodyHelperSelfTests.serial("serial-policy-failure") }
        try run("m6-helper-serial-system-cancel") { try CustodyHelperSelfTests.serial("serial-system-cancel", cancelAt: 0, eof: false) }
        try run("m6-helper-serial-policy-eof") { try CustodyHelperSelfTests.serial("serial-policy-cancel", cancelAt: 1, eof: true) }
        try run("m6-helper-serial-command-cancel") { try CustodyHelperSelfTests.serial("serial-command-cancel", cancelAt: 2, eof: false) }
        try run("m6-helper-serial-between-eof") { try CustodyHelperSelfTests.serial("serial-between-cancel", cancelAt: 0, eof: true) }
        try run("m6-helper-serial-next-before-spawn") { try CustodyHelperSelfTests.serial("serial-next-before-spawn") }
        try run("m6-helper-serial-next-after-spawn") { try CustodyHelperSelfTests.serial("serial-next-after-spawn") }
        try run("m6-helper-serial-next-before-record") { try CustodyHelperSelfTests.serial("serial-next-before-record") }
        try run("m6-helper-native-complete") { try CustodyHelperSelfTests.native("complete",expected:.completed,reason:.none) }
        try run("m6-helper-native-command-failure") { try CustodyHelperSelfTests.native("fail",expected:.commandFailed,reason:.none) }
        try run("m6-helper-native-cancel-drain") { try CustodyHelperSelfTests.native("wait",cancel:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-native-eof-drain") { try CustodyHelperSelfTests.native("wait",eof:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-native-timeout-kill") { try CustodyHelperSelfTests.native("resist",expected:.timedOutDrained,reason:.timeout,work:0.2) }
        try run("m6-helper-native-deadline-before-control") { try CustodyHelperSelfTests.native("deadline-before-control",expected:.timedOutDrained,reason:.timeout,work:0.2) }
        try run("m6-helper-native-output-failure") { try CustodyHelperSelfTests.native("overflow",expected:.commandFailed,reason:.outputLimit,output:1024) }
        try run("m6-helper-native-trace-complete") { try CustodyHelperSelfTests.native("trace-complete",expected:.completed,reason:.none) }
        try run("m6-helper-native-trace-overflow") { try CustodyHelperSelfTests.native("trace-overflow",expected:.commandFailed,reason:.outputLimit) }
        try run("m6-helper-native-trace-eof-drain") { try CustodyHelperSelfTests.native("trace-resist",eof:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-trace-command-boundary") { try CustodyHelperSelfTests.traceCommandBoundary() }
        try run("m6-helper-trace-reservation-boundary") { try CustodyHelperSelfTests.traceReservationBoundary() }
        try run("m6-registry-status-eof-without-terminal") { try CustodyRegistrySelfTests.native("status-eof", pending:true) }
        try run("m6-registry-reap-before-status-eof") { try CustodyHelperSelfTests.reapedBeforeReads(.statusAfterAdmission) }
        try run("m6-registry-reap-before-output-eof") { try CustodyHelperSelfTests.reapedBeforeReads(.outputUntilReleased) }
        try run("m6-system-config-fixed-command") { try SystemConfigCommandSelfTests.contract() }
        try run("m6-system-config-unqualified-refusal") { try SystemConfigCommandSelfTests.unqualified() }
        try run("m6-system-config-pending-refusal") { try SystemConfigCommandSelfTests.pending() }
        try run("m6-system-config-pending-after-fallback-return") { try SystemConfigCommandSelfTests.pendingCompletion(throwAfter: false) }
        try run("m6-system-config-pending-after-fallback-throw") { try SystemConfigCommandSelfTests.pendingCompletion(throwAfter: true) }
        try run("m6-system-config-unrelated-error-preserved") { try SystemConfigCommandSelfTests.unrelatedCompletion() }
        try run("m6-config-caller-capture-postflight") { try SystemConfigCommandSelfTests.configurationCapture("roundtrip") }
        try run("m6-config-caller-absent-system") { try SystemConfigCommandSelfTests.configurationCapture("absent") }
        try run("m6-config-caller-changed-origin-refusal") { try SystemConfigCommandSelfTests.configurationCapture("origin") }
        try run("m6-config-caller-postflight-change-refusal") { try SystemConfigCommandSelfTests.configurationCapture("postflight") }
        try run("m6-config-caller-include-refusal") { try SystemConfigCommandSelfTests.configurationCapture("include") }
        try run("m6-config-caller-closed-phase-refusal") { try SystemConfigCommandSelfTests.configurationCapture("closed") }
        try run("m6-config-caller-account-refusal") { try SystemConfigCommandSelfTests.configurationCapture("account") }
        try run("m6-config-caller-pending-refusal") { try SystemConfigCommandSelfTests.configurationCapture("pending") }
        try run("m6-frozen-custody-offset") { try SystemConfigCommandSelfTests.configurationCapture("custody-offset") }
        try run("m6-frozen-custody-retention") { try SystemConfigCommandSelfTests.configurationCapture("custody-retention") }
        try run("m6-frozen-custody-wrong-kind") { try SystemConfigCommandSelfTests.configurationCapture("custody-wrong-kind") }
        try run("m6-frozen-custody-flags") { try SystemConfigCommandSelfTests.configurationCapture("custody-flags") }
        try run("m6-frozen-custody-snapshot") { try SystemConfigCommandSelfTests.configurationCapture("custody-snapshot") }
        try run("m6-frozen-custody-view") { try SystemConfigCommandSelfTests.configurationCapture("custody-view") }
        try run("m6-frozen-custody-native") { try SystemConfigCommandSelfTests.configurationCapture("custody-native") }
        try run("m6-frozen-custody-cancel") { try SystemConfigCommandSelfTests.configurationCapture("custody-cancel") }
        try run("m6-frozen-custody-eof") { try SystemConfigCommandSelfTests.configurationCapture("custody-eof") }
        try run("m6-frozen-custody-pending") { try SystemConfigCommandSelfTests.configurationCapture("custody-pending") }
        try run("m6-config-retained-root") { try SystemConfigCommandSelfTests.configurationCapture("child-retained-root") }
        try run("m6-config-retained-root-wrong") { try SystemConfigCommandSelfTests.configurationCapture("child-retained-root-wrong") }
        try run("m6-config-no-follow-refs") { try SystemConfigCommandSelfTests.configurationCapture("child-no-follow-refs") }
        try run("m6-config-no-follow-info") { try SystemConfigCommandSelfTests.configurationCapture("child-no-follow-info") }
        try run("m6-config-no-follow-objects-info") { try SystemConfigCommandSelfTests.configurationCapture("child-no-follow-objects-info") }
        try run("m6-config-no-follow-contributor") { try SystemConfigCommandSelfTests.configurationCapture("child-no-follow-contributor") }
        try run("m6-config-discovery-input-canonical") { try SystemConfigCommandSelfTests.configurationCapture("discovery-input-canonical") }
        try run("m6-config-discovery-input-refusals") { try SystemConfigCommandSelfTests.configurationCapture("discovery-input-refusals") }
        try run("m6-config-discovery-resource-roster") { try SystemConfigCommandSelfTests.configurationCapture("discovery-resource-roster") }
        try run("m6-config-captured-present") { try SystemConfigCommandSelfTests.configurationCapture("captured-present") }
        try run("m6-config-captured-absent") { try SystemConfigCommandSelfTests.configurationCapture("captured-absent") }
        try run("m6-config-captured-account") { try SystemConfigCommandSelfTests.configurationCapture("captured-account") }
        try run("m6-config-captured-include") { try SystemConfigCommandSelfTests.configurationCapture("captured-include") }
        try run("m6-config-captured-alias") { try SystemConfigCommandSelfTests.configurationCapture("captured-alias") }
        try run("m6-config-captured-no-sweep") { try SystemConfigCommandSelfTests.configurationCapture("captured-no-sweep") }
        try run("m6-config-captured-snapshot") { try SystemConfigCommandSelfTests.configurationCapture("captured-snapshot") }
        try run("m6-config-captured-snapshot-absent") { try SystemConfigCommandSelfTests.configurationCapture("captured-snapshot-absent") }
        try run("m6-config-captured-snapshot-drift") { try SystemConfigCommandSelfTests.configurationCapture("captured-snapshot-drift") }
        try run("m6-config-captured-snapshot-sources") { try SystemConfigCommandSelfTests.configurationCapture("captured-snapshot-sources") }
        try run("m6-config-child-closed-preflight") { try SystemConfigCommandSelfTests.configurationCapture("child-roundtrip") }
        try run("m6-config-child-absent-never-probes") { try SystemConfigCommandSelfTests.configurationCapture("child-absent") }
        try run("m6-config-child-origin-refusal-before-open") { try SystemConfigCommandSelfTests.configurationCapture("child-origin") }
        try run("m6-config-child-account-refusal-before-open") { try SystemConfigCommandSelfTests.configurationCapture("child-account") }
        try run("m6-config-child-contributor-drift-refusal") { try SystemConfigCommandSelfTests.configurationCapture("child-contributor") }
        try run("m6-config-child-inode-replacement-refusal") { try SystemConfigCommandSelfTests.configurationCapture("child-replacement") }
        try run("m6-config-child-repository-config-refusal") { try SystemConfigCommandSelfTests.configurationCapture("child-local") }
        try run("m6-config-child-packed-refs-refusal") { try SystemConfigCommandSelfTests.configurationCapture("child-packed") }
        try run("m6-config-preflight-malformed-sticky-return") { try SystemConfigCommandSelfTests.preflightConversion(duplicate: false, throwAfter: false) }
        try run("m6-config-preflight-duplicate-sticky-throw") { try SystemConfigCommandSelfTests.preflightConversion(duplicate: true, throwAfter: true) }
        try run("m6-inspection-top-level-pending") { try SystemConfigCommandSelfTests.configurationCapture("inspection-top") }
        try run("m6-inspection-cleanup-pending") { try SystemConfigCommandSelfTests.configurationCapture("inspection-cleanup") }
        try run("m6-inspection-lifecycle-pending") { try SystemConfigCommandSelfTests.configurationCapture("inspection-enrich") }
        try run("m6-inspection-maintenance-pending") { try SystemConfigCommandSelfTests.configurationCapture("inspection-maintenance") }
        try run("m6-inspection-origin-head-pending") { try SystemConfigCommandSelfTests.configurationCapture("inspection-origin") }
        try run("m6-inspection-closed-before-open") { try SystemConfigCommandSelfTests.configurationCapture("inspection-closed") }
        try run("m6-inspection-cancel-before-open") { try SystemConfigCommandSelfTests.configurationCapture("inspection-cancel") }
        try run("m6-inspection-ordinary-fallback") { try SystemConfigCommandSelfTests.configurationCapture("inspection-fallback") }
        try run("m6-inspection-worktree-pending") { try SystemConfigCommandSelfTests.configurationCapture("inspection-worktree") }
        try run("m6-inspection-planner-stops-next-registration") { try SystemConfigCommandSelfTests.configurationCapture("inspection-planner-pending") }
        try run("m6-inspection-planner-ordinary-refusal") { try SystemConfigCommandSelfTests.configurationCapture("inspection-planner-ordinary") }
        try run("m6-system-config-closed-graph") { try SystemConfigCommandSelfTests.graph() }
        try run("m6-system-config-native-complete") { try CustodyHelperSelfTests.native("system-complete",expected:.completed,reason:.none) }
        try run("m6-system-config-native-missing") { try CustodyHelperSelfTests.native("system-missing",expected:.commandFailed,reason:.none) }
        try run("m6-system-config-native-partial-failure") { try CustodyHelperSelfTests.native("system-faildata",expected:.commandFailed,reason:.none) }
        try run("m6-system-config-native-cancel") { try CustodyHelperSelfTests.native("system-resist",tokenCancel:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-system-config-native-eof") { try CustodyHelperSelfTests.native("system-resist",eof:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-system-config-native-timeout") { try CustodyHelperSelfTests.native("system-resist",expected:.timedOutDrained,reason:.timeout,work:0.2) }
        try run("m6-system-config-native-overflow") { try CustodyHelperSelfTests.native("system-overflow",expected:.commandFailed,reason:.outputLimit,output:1024) }
        try run("m6-policy-command-original-deadline") { try PolicyCommandSelfTests.deadline() }
        try run("m6-custody-cancel-during-validation") { try CustodyContextSelfTests.cancelledValidation(queued: false) }
        try run("m6-custody-cancel-before-queued-start") { try CustodyContextSelfTests.cancelledValidation(queued: true) }
        try run("m6-policy-command-wire-canonical") { try PolicyCommandSelfTests.wire(refusal: false) }
        try run("m6-policy-command-wire-refusals") { try PolicyCommandSelfTests.wire(refusal: true) }
        try run("m6-policy-command-graph-closed-path") { try PolicyCommandSelfTests.graph() }
        try run("m6-policy-token-cancel-after-registration") { try CustodyHelperSelfTests.native("policy-resist",tokenCancel:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-policy-token-cancel-before-registration") { try CustodyHelperSelfTests.native("policy-resist",tokenCancel:true,tokenAlreadyCancelled:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-policy-sealed-input-code") { try CustodyHelperSelfTests.native("policy-echo",expected:.completed,reason:.none) }
        try run("m6-helper-policy-cancel-drain") { try CustodyHelperSelfTests.native("policy-resist",cancel:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-policy-eof-drain") { try CustodyHelperSelfTests.native("policy-resist",eof:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-policy-missing-resource-refusal") { try CustodyHelperSelfTests.policyResourceBoundary(output: false) }
        try run("m6-helper-policy-output-limit-refusal") { try CustodyHelperSelfTests.policyResourceBoundary(output: true) }
        try run("m6-helper-cancel-after-admitted-write") { try CustodyHelperSelfTests.native("after-admit",cancel:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-cancel-before-target-resume") { try CustodyHelperSelfTests.native("before-resume",cancel:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-eof-after-final-preparation") { try CustodyHelperSelfTests.native("after-preparation",eof:true,expected:.cancelledDrained,reason:.cancelled) }
        try run("m6-helper-reported-failure-state") { try CustodyHelperSelfTests.failedStatus() }
        try run("m6-helper-parent-loss-automatic-drain") { try CustodyHelperSelfTests.parentLoss() }
        try run("m6-helper-parent-pre-readiness-eof") { try CustodyHelperSelfTests.parentBounded(mode: "pre-ready") }
        try run("m6-helper-parent-admission-stop-race") { try CustodyHelperSelfTests.parentBounded(mode: "before-admission") }
        try run("m6-helper-parent-cooperative-eof") { try CustodyHelperSelfTests.parentBounded(mode: "normal") }
        try run("m6-helper-parent-bounded-lifetime") { try CustodyHelperSelfTests.parentBounded(mode: "short-lifetime") }
        try run("m6-resources-native-before-transfer-unwind") { try CustodyResourcesSelfTests.nativeAdmissionFailure(afterTransfer: false) }
        try run("m6-resources-native-after-transfer-unwind") { try CustodyResourcesSelfTests.nativeAdmissionFailure(afterTransfer: true) }
        try run("m6-helper-terminal-delivery-after-deadline") { try CustodyHelperSelfTests.native("terminal-delay",expected:.completed,reason:.none,work:0.5) }
        try run("m6-helper-terminal-state-reconciliation") { try CustodyHelperSelfTests.terminalState() }
        try run("m6-strict-admission-missing-state", StrictStateAdmissionSelfTests.missingState)
        try run("m6-strict-admission-missing-controls", StrictStateAdmissionSelfTests.missingControls)
        try run("m6-strict-admission-permission-preservation", StrictStateAdmissionSelfTests.permissions)
        try run("m6-strict-admission-unsafe-controls", StrictStateAdmissionSelfTests.unsafeControls)
        try run("m6-strict-admission-retained-original-lease", StrictStateAdmissionSelfTests.retainedLease)
        try run("m6-strict-admission-existing-inode-preservation", StrictStateAdmissionSelfTests.existingState)
        try run("m6-strict-admission-missing-log-writer", StrictStateAdmissionSelfTests.missingLogWriter)
        try run("m6-strict-admission-replaced-log-writer", StrictStateAdmissionSelfTests.replacedLogWriter)
        try run("m6-strict-admission-mode-log-writer", StrictStateAdmissionSelfTests.modeLogWriter)
        try run("m6-strict-admission-closed-log-writer", StrictStateAdmissionSelfTests.closedLogWriter)
        try run("m6-strict-admission-existing-log-writer", StrictStateAdmissionSelfTests.existingLogWriter)
        return passed
    }

    private static func identity(revision: String) throws -> ReleaseIdentity {
        try ReleaseIdentity(
            sourceRevision: revision,
            sourceInputSHA256: String(repeating: "b", count: 64),
            releaseContractSHA256: String(repeating: "c", count: 64),
            architecture: "arm64",
            buildMode: "production"
        )
    }

    private static func temporaryRoot() throws -> String {
        var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-m6-self.") + "XXXXXX").utf8CString)
        guard let pointer = mkdtemp(&template) else {
            throw M6SelfTestError.message("could not create private test root")
        }
        let path = String(cString: pointer)
        guard chmod(path, 0o700) == 0 else {
            throw M6SelfTestError.message("could not secure private test root")
        }
        return path
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw M6SelfTestError.message(message)
        }
    }
}

private enum M6SelfTestError: Error {
    case message(String)
}
#endif

#if SHADOW_SYNC_TESTING
private enum CustodyLeaseSelfTests {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func refuses(_ body: () throws -> Void) throws {
        var refused = false
        do { try body() }
        catch is SecureStateError { refused = true }
        catch is PolicyAuthorityFileError { refused = true }
        try check(refused, "custody lease unexpectedly accepted")
    }
    static func fixture(_ body: (StateLocation, String) throws -> Void) throws {
        var pattern = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-custody-leases.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&pattern) else { throw Failure(message: "fixture creation failed") }
        let root = String(cString: raw)
        var initial = stat(); try check(lstat(root, &initial) == 0, "fixture identity unavailable")
        defer {
            var current = stat()
            if lstat(root, &current) == 0 && initial.st_dev == current.st_dev && initial.st_ino == current.st_ino {
                try? FileManager.default.removeItem(atPath: root)
            }
        }
        let location = try StateLocation.isolated(root: root)
        try TestIsolation.initializeState(at: location)
        let initializer = try RunAuthority.acquireRun(at: location); initializer.release()
        try body(location, root)
    }
    static func exclusiveBusy(_ location: StateLocation, _ name: String) throws {
        let state = try SecureStateDirectory.openExisting(location)
        let fd = try state.openRegularFile(named: name, flags: O_RDWR, create: false, repairPermissions: false)
        defer { close(fd) }
        let result = flock(fd, LOCK_EX | LOCK_NB), code = errno
        try check(result == -1 && code == EWOULDBLOCK, "retained lease no longer excludes new description")
    }
    static func runAvailable(_ location: StateLocation) throws {
        let run = try RunAuthority.acquireRun(at: location); run.release()
    }
    static func identity() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location); defer { authority.release() }
            let leases = try authority.retainCommandLeases()
            let names: [CustodyDescriptorClaim.Role: String] = [.namespace: "latest.log", .lifecycle: "lifecycle.lock", .operation: "operation.lock", .run: "run.lock"]
            let claims = try leases.descriptorClaims()
            try check(leases.mode == .mutation && claims.count == 5, "mutation roles incomplete")
            for claim in claims {
                var info = stat()
                if claim.role == .state { try check(fstat(authority.stateDirectory.descriptor.value, &info) == 0, "state stat") }
                else { try check(fstatat(authority.stateDirectory.descriptor.value, names[claim.role]!, &info, AT_SYMLINK_NOFOLLOW) == 0, "lease stat") }
                try check(claim.device == UInt64(info.st_dev) && claim.inode == UInt64(info.st_ino), "lock inode changed on transfer")
            }
            try check(leases.testingDescriptorFlags().allSatisfy { $0.0 >= 201 && $0.1 & FD_CLOEXEC != 0 }, "copy leaked or collided with reserved descriptors")
            let ordinary = try authority.duplicateOperationLease(); defer { close(ordinary) }
            try check(fcntl(ordinary, F_GETFD) & FD_CLOEXEC != 0, "legacy duplicate not atomic CLOEXEC")
            try check(mkdir(location.path + "/fixture-subdirectory", 0o700) == 0, "directory metadata fixture")
            try leases.validate() // Directory child-count changes cannot revoke an unchanged namespace.
        }
    }
    static func releasePreservesLeases() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location)
            var leases: CustodyAuthorityLeaseSet? = try authority.retainCommandLeases()
            authority.release(); authority.release()
            for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock"] { try exclusiveBusy(location, name) }
            try leases!.validate(); leases = nil
            try runAvailable(location)
        }
    }
    static func retainedFamily() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireLifecycleMutation(at: location)
            var first: CustodyAuthorityLeaseSet? = try authority.retainCommandLeases()
            var second: CustodyAuthorityLeaseSet? = try first!.duplicate()
            try check(second!.mode == .lifecycleMutation, "duplicated scope changed mode")
            first = nil
            try refuses { try authority.permitStagedHostAdmission() }
            authority.release()
            try exclusiveBusy(location, "lifecycle.lock"); try exclusiveBusy(location, "operation.lock")
            try second!.validate(); second = nil
            try runAvailable(location)
        }
    }
    static func readContention() throws {
        try fixture { location, _ in
            var first: CustodyAuthorityLeaseSet? = try CustodyAuthorityLeaseSet.retainReadLeases(at: location)
            var second: CustodyAuthorityLeaseSet? = try CustodyAuthorityLeaseSet.retainReadLeases(at: location)
            try check(first!.mode == .read && (try first!.descriptorClaims()).count == 4, "read roles incorrect")
            try refuses { _ = try RunAuthority.acquireRun(at: location) }
            first = nil
            try exclusiveBusy(location, "operation.lock")
            try second!.validate(); second = nil
            try runAvailable(location)
        }
    }
    static func observationUnderOperation() throws {
        try fixture { location, _ in
            let run = try RunAuthority.acquireRun(at: location)
            let observation = try LifecycleAdmissionAuthority.acquire(at: location)
            var leases: CustodyAuthorityLeaseSet? = try observation.retainObservationLeases()
            try check(try leases!.descriptorClaims().map(\.role) == [.state, .namespace, .lifecycle], "observation gained operation lease")
            observation.release(); run.release()
            try runAvailable(location) // Observation doesn't block operation EX.
            try refuses { _ = try RunAuthority.acquireLifecycleMutation(at: location) }
            try leases!.validate(); leases = nil
            let coordinator = try RunAuthority.acquireLifecycleMutation(at: location)
            var borrowed: CustodyAuthorityLeaseSet? = try coordinator.retainObservationLeases()
            try check(borrowed!.mode == .observation && (try borrowed!.descriptorClaims()).count == 3, "coordinator observation acquired new lock")
            coordinator.release(); try exclusiveBusy(location, "lifecycle.lock")
            try borrowed!.validate(); borrowed = nil
            try runAvailable(location)
        }
    }
    static func retirementFence() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireLifecycleMutation(at: location); defer { authority.release() }
            var leases: CustodyAuthorityLeaseSet? = try authority.retainCommandLeases()
            try refuses { try authority.acquireRetirementNamespace(timeout: 0.01) }
            try refuses { try authority.permitStagedHostAdmission() }
            // A busy transition closes new admission without invalidating the
            // existing borrower; it stays closed through the eventual retry.
            try refuses { _ = try authority.retainCommandLeases() }
            try refuses { _ = try authority.retainObservationLeases() }
            try refuses { _ = try authority.duplicateOperationLease() }
            try leases!.validate(); leases = nil
            try authority.acquireRetirementNamespace(timeout: 0.01)
            try refuses { _ = try authority.retainCommandLeases() }
            try refuses { _ = try authority.retainObservationLeases() }
            try refuses { _ = try authority.duplicateOperationLease() }
            try authority.permitStagedHostAdmission()
        }
    }
    static func partialRefusal() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireLifecycleMutation(at: location)
            let path = location.path + "/lifecycle.lock"
            try check(chmod(path, 0o700) == 0, "invalid initial permission fixture")
            for _ in 0..<64 { try refuses { _ = try authority.retainCommandLeases() } }
            try check(chmod(path, 0o600) == 0, "restore lifecycle permission")
            try authority.acquireRetirementNamespace(timeout: 0.01)
            authority.release()
            try runAvailable(location)
        }
        try fixture { location, _ in
            let authority = try RunAuthority.acquireLifecycleMutation(at: location)
            try authority.permitStagedHostAdmission()
            for _ in 0..<64 { try refuses { _ = try authority.retainCommandLeases() } }
            authority.release()
            try runAvailable(location) // No partial namespace duplicates remain.
            try refuses { _ = try authority.retainCommandLeases() }
            try refuses { _ = try authority.duplicateOperationLease() }
            let observation = try LifecycleAdmissionAuthority.acquire(at: location); observation.release()
            try refuses { _ = try observation.retainObservationLeases() }
        }
    }
    final class Result: @unchecked Sendable {
        private let mutex = NSLock()
        private var value: CustodyAuthorityLeaseSet?
        private var error = false
        func store(_ v: CustodyAuthorityLeaseSet?) { mutex.lock(); value = v; error = v == nil; mutex.unlock() }
        func take() throws -> CustodyAuthorityLeaseSet {
            mutex.lock(); defer { mutex.unlock() }
            guard let value, !error else { throw Failure(message: "concurrent retention failed") }
            self.value = nil; return value
        }
    }
    static func releaseOrdering() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location)
            let barrier = CustodyLeaseTestingBarrier(), attempt = CustodyLeaseTestingBarrier()
            let group = DispatchGroup(), result = Result()
            authority.testingPauseCustodyDuplication(barrier)
            group.enter(); DispatchQueue.global().async {
                result.store(try? authority.retainCommandLeases()); group.leave()
            }
            guard barrier.waitUntilEntered() else {
                barrier.release(); _ = group.wait(timeout: .now() + 4); authority.release()
                throw Failure(message: "duplication boundary not reached")
            }
            authority.testingObserveCustodyRelease(attempt)
            group.enter(); DispatchQueue.global().async { authority.release(); group.leave() }
            let contended = attempt.waitUntilContended()
            barrier.release()
            let joined = group.wait(timeout: .now() + 4) == .success
            try check(contended && joined, "release crossed descriptor duplication")
            var retained: CustodyAuthorityLeaseSet? = try result.take()
            try exclusiveBusy(location, "operation.lock")
            try retained!.validate(); retained = nil
            try runAvailable(location)
        }
    }
    final class Outcome: @unchecked Sendable {
        private let mutex = NSLock()
        private var value = false
        func set(_ value: Bool) { mutex.lock(); self.value = value; mutex.unlock() }
        var succeeded: Bool { mutex.lock(); defer { mutex.unlock() }; return value }
    }
    static func retirementOrdering() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireLifecycleMutation(at: location)
            defer { authority.release() }
            let barrier = CustodyLeaseTestingBarrier(), attempt = CustodyLeaseTestingBarrier()
            let group = DispatchGroup(), retirement = Outcome(), refusal = Outcome()
            authority.testingPauseCustodyRetirement(barrier)
            group.enter(); DispatchQueue.global().async {
                do { try authority.acquireRetirementNamespace(timeout: 0.01); retirement.set(true) }
                catch { retirement.set(false) }
                group.leave()
            }
            guard barrier.waitUntilEntered() else {
                barrier.release(); _ = group.wait(timeout: .now() + 4)
                throw Failure(message: "retirement boundary not reached")
            }
            authority.testingObserveCustodyBorrow(attempt)
            group.enter(); DispatchQueue.global().async {
                do { _ = try authority.retainCommandLeases(); refusal.set(false) }
                catch is SecureStateError { refusal.set(true) }
                catch { refusal.set(false) }
                group.leave()
            }
            let contended = attempt.waitUntilContended()
            barrier.release()
            let joined = group.wait(timeout: .now() + 4) == .success
            try check(contended && joined && retirement.succeeded && refusal.succeeded,
                      "retirement reopened command admission")
            try refuses { _ = try authority.retainObservationLeases() }
            try refuses { _ = try authority.duplicateOperationLease() }
        }
    }
    static func spawnRetaining(_ leases: CustodyAuthorityLeaseSet) throws -> OwnedSpawnAnchor {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions) == 0, "fixture actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes) == 0, "fixture attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0,
                      "fixture streams")
        }
        try leases.appendSpawnActions(to: &actions)
        var defaults = sigset_t(); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var mask = sigset_t(); sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
            && posix_spawnattr_setsigmask(&attributes, &mask) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setflags(&attributes, flags) == 0, "fixture spawn attributes")
        let arguments: [String] = ["/bin/sleep", "30"]
        let strings = arguments.map { argument in argument.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        try check(strings.allSatisfy { $0 != nil }, "fixture argv")
        var argv = strings + [nil], env: [UnsafeMutablePointer<CChar>?] = [nil]
        return try argv.withUnsafeMutableBufferPointer { av in
            try env.withUnsafeMutableBufferPointer { ev in
                try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: "/bin/sleep", actions: &actions, attributes: &attributes,
                                           arguments: av.baseAddress, environment: ev.baseAddress, streamsDrained: { true })
            }
        }
    }
    static func inheritedContinuity() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location)
            defer { authority.release() }
            var leases: CustodyAuthorityLeaseSet? = try authority.retainCommandLeases()
            let child = try spawnRetaining(leases!)
            var clean = false
            defer { RuntimeFixtureSession.drain(child) }
            // The child never resumes. Only its declared inherited descriptions
            // remain after every original and parent duplicate has closed.
            authority.release(); leases = nil
            var failure: Error?
            do {
                for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock"] {
                    try exclusiveBusy(location, name)
                }
            } catch { failure = error }
            let killed = child.killSuspended()
            let terminal = try child.wait(timeout: 4)
            if case .reaped = terminal { clean = true }
            var status: Int32 = 0
            let waited = waitpid(child.processID, &status, WNOHANG), code = errno
            try check(killed && clean && waited == -1 && code == ECHILD, "inherited fixture not exactly reaped")
            if let failure { throw failure }
            try runAvailable(location)
        }
    }

    static func replacedLock() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location); defer { authority.release() }
            let leases = try authority.retainCommandLeases()
            let old = location.path + "/operation.lock", moved = location.path + "/previous-operation"
            try check(rename(old, moved) == 0, "move owned lock fixture")
            defer { _ = unlink(old); _ = rename(moved, old) }
            let fd = open(old, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            try check(fd >= 0, "replacement fixture"); close(fd)
            try refuses { try leases.validate() }
            try refuses { _ = try leases.duplicate() }
            try refuses { _ = try authority.retainCommandLeases() }
        }
    }
    static func driftAndRollback() throws {
        try fixture { location, _ in
            let path = location.path + "/operation.lock"
            try check(chmod(path, 0o700) == 0, "initial executable lock fixture")
            try refuses { _ = try CustodyAuthorityLeaseSet.retainReadLeases(at: location) }
            var info = stat()
            try check(lstat(path, &info) == 0 && info.st_mode & 0o7777 == 0o700,
                      "read refusal repaired state")
            try check(chmod(path, 0o600) == 0, "restore initial lock permission")
            try runAvailable(location)
        }
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location); defer { authority.release() }
            let leases = try authority.retainCommandLeases(), path = location.path + "/operation.lock"
            try check(chmod(path, 0o640) == 0, "mode fixture")
            try refuses { try leases.validate() }
            try check(chmod(path, 0o600) == 0, "restore mode")
            let alias = location.path + "/alias"
            try check(link(path, alias) == 0, "hardlink fixture")
            try refuses { try leases.validate() }; try check(unlink(alias) == 0, "remove fixture hardlink")
            try leases.validate(); authority.release()
        }
        try fixture { location, _ in
            let path = location.path + "/operation.lock", moved = location.path + "/old-operation"
            try check(rename(path, moved) == 0, "missing operation fixture")
            for _ in 0..<32 { try refuses { _ = try CustodyAuthorityLeaseSet.retainReadLeases(at: location) } }
            try check(rename(moved, path) == 0, "restore operation fixture")
            let coordinator = try RunAuthority.acquireLifecycleMutation(at: location); coordinator.release()
        }
    }
    static func setACL(_ path: String, rule: String) throws {
        // This closed ACL fixture command is retained through actual reap even
        // when the assertion timeout expires. No Foundation.Process reaper.
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions) == 0, "ACL actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attr) == 0, "ACL attributes")
        defer { posix_spawnattr_destroy(&attr) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0,
                      "ACL null stream")
        }
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        try check(posix_spawnattr_setflags(&attr, flags) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0, "ACL flags")
        let strings = (["/bin/chmod", "+a", rule, path] as [String]).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try check(strings.allSatisfy { $0 != nil }, "ACL arguments")
        var argv = strings + [nil], env: [UnsafeMutablePointer<CChar>?] = [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in try env.withUnsafeMutableBufferPointer { ev in
            try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: "/bin/chmod",
                actions: &actions, attributes: &attr, arguments: av.baseAddress, environment: ev.baseAddress,
                streamsDrained: { true })
        } }
        defer { RuntimeFixtureSession.drain(anchor) }
        let owner = try anchor.transfer(expectedExecutable: "/bin/chmod", generation: RunIdentity.make())
        try check(owner.send(SIGCONT), "ACL fixture resume")
        try check(try owner.wait(timeout: 2) == .reaped(0), "fixture ACL command failed")
    }
    static func clearACL(_ path: String) {
        if let empty = acl_init(0) {
            _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty); acl_free(UnsafeMutableRawPointer(empty))
        }
    }
    static func privateACL() throws {
        try fixture { location, _ in
            let authority = try RunAuthority.acquireRun(at: location); defer { authority.release() }
            for path in [location.path, location.path + "/latest.log", location.path + "/operation.lock"] {
                defer { clearACL(path) }
                try setACL(path, rule: "everyone allow read,readattr,readextattr,readsecurity")
                try refuses { _ = try authority.retainCommandLeases() }
                clearACL(path)
            }
            let file = location.path + "/operation.lock"
            defer { clearACL(file) }
            try setACL(file, rule: "everyone deny delete")
            let leases = try authority.retainCommandLeases()
            try leases.validate(); clearACL(file)
            try refuses { try leases.validate() }
        }
    }
    static func noImplicitInitialization() throws {
        try fixture { location, root in
            let missing = StateLocation(anchorPath: root, components: ["not-created", "shadow-sync"], uid: geteuid())
            try refuses { _ = try CustodyAuthorityLeaseSet.retainReadLeases(at: missing) }
            var info = stat()
            try check(lstat(root + "/not-created", &info) == -1 && errno == ENOENT, "read scope created state")
            let path = location.path + "/lifecycle.lock", moved = location.path + "/saved-lifecycle"
            try check(rename(path, moved) == 0, "missing lifecycle fixture")
            for _ in 0..<32 { try refuses { _ = try LifecycleAdmissionAuthority.acquire(at: location) } }
            try check(rename(moved, path) == 0, "restore lifecycle fixture")
            let coordinator = try RunAuthority.acquireLifecycleMutation(at: location)
            try coordinator.acquireRetirementNamespace(timeout: 0.01); coordinator.release()
        }
    }
}
private enum CustodyCatalogSelfTests {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch is CustodyRecordError { return }
        catch is CustodyProtocolError { return } catch is PolicyProtocolError { return }
        catch is SecureStateError { return } catch is PolicyAuthorityFileError { return }
        throw Failure(message: "custody metadata unexpectedly accepted")
    }
    static func fixture(initialized: Bool = true, _ body: (StateLocation, String) throws -> Void) throws {
        var pattern = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-custody-catalog.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&pattern) else { throw Failure(message: "fixture creation") }
        let root = String(cString: raw)
        var before = stat(); try check(lstat(root, &before) == 0, "fixture identity")
        defer {
            var after = stat()
            if lstat(root, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino {
                try? FileManager.default.removeItem(atPath: root)
            }
        }
        let location = try StateLocation.isolated(root: root)
        try TestIsolation.initializeState(at: location)
        let owner = try RunAuthority.acquireRun(at: location)
        if initialized {
            let leases = try owner.retainCommandLeases()
            try CustodyCatalogStore.testingInitialize(leases: leases, root: root)
        }
        owner.release(); try body(location, root)
    }
    static func scope(_ location: StateLocation, observation: Bool = false) throws -> CustodyMetadataScope {
        let leases: CustodyAuthorityLeaseSet
        if observation {
            let owner = try LifecycleAdmissionAuthority.acquire(at: location)
            leases = try owner.retainObservationLeases(); owner.release()
        } else { leases = try CustodyAuthorityLeaseSet.retainReadLeases(at: location) }
        return try CustodyMetadataScope(leases: leases, releaseSHA256: String(repeating: "c", count: 64), generation: UUID().uuidString.lowercased())
    }
    static func request(_ scope: CustodyMetadataScope, kind: CustodyCommandKind = .discoveryGit,
                        binding: CustodyBinding? = nil, workSeconds: TimeInterval = 1) throws -> UnvalidatedCustodyRequest {
        let stubs = [CustodyDescriptorClaim.Role.request, .control, .status, .workingDirectory].map {
            CustodyDescriptorClaim(role: $0, device: 1, inode: 1, uid: geteuid(), mode: 0o100600, links: 1, access: .read)
        }
        return UnvalidatedCustodyRequest(binding: try binding ?? scope.binding(nonce: String(repeating: "a", count: 32)),
            kind: kind, authority: scope.leases.mode, arguments: ["/fixture/candidate-private"],
            environment: ["FIXTURE_PRIVATE": "private-environment-value"], budget: try CustodyBudget.make(kind: kind, workSeconds: workSeconds),
            stdoutLimit: 1024, stderrLimit: 1024, inputSHA256: nil, resourcesSHA256: String(repeating: "b", count: 64),
            descriptors: (try scope.leases.descriptorClaims() + stubs).sorted { $0.role.number < $1.role.number })
    }
    static func write(_ bytes: Data, _ path: String) throws {
        let fd = open(path, O_WRONLY | O_TRUNC | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try check(fd >= 0, "fixture write"); defer { close(fd) }
        try bytes.withUnsafeBytes { raw in try check(Darwin.write(fd, raw.baseAddress, raw.count) == raw.count, "fixture write count") }
        try check(fsync(fd) == 0, "fixture fsync")
    }
    static func bytes(_ location: StateLocation, _ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/" + relative))
    }
    static func journal(_ scope: CustodyMetadataScope) throws -> CustodyJournal {
        try CustodyJournal(prepared: request(scope), leases: scope.leases.descriptorClaims())
    }
    static func changed(_ bytes: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    /// Real descriptor/file ownership in one disposable catalog fixture. The
    /// journal process fields are metadata fixtures, not child-retirement proof.
    static func resourceOwner(_ scenario: String) throws {
        try fixture { location, root in
            let s = try scope(location), request = try request(s), ticket = try s.prepare(request)
            let process = ProcessIdentity(processID: 10, processGroupID: 10, userID: geteuid(), startSeconds: 1,
                startMicroseconds: 1, executablePath: "/fixture/never-persist", generation: UUID().uuidString.lowercased())
            let journal = try ticket.testingJournal.advancing(to: .admitted, custodian: CustodyProcessObservation(process))
            try s.testingAdvance(ticket, to: journal)
            let parent = root + "/owner-resources"
            try check(mkdir(parent, 0o700) == 0, "owner parent fixture")
            let payload = scenario == "empty" ? Data() : Data("[core]\n\tbare = false\n".utf8)
            var denyAdmission = false, injectedPersistence = false
            let cut: CustodyCatalogStore.Fault?
            switch scenario {
            case "persist-before-swap": cut = .beforeSwap
            case "persist-after-swap": cut = .afterSwap
            case "persist-after-sync": cut = .afterDirectorySync
            case "persist-after-unlink": cut = .afterPreimageUnlink
            default: cut = nil
            }
            let resource = try DiscoveryFrozenResource(testing: .testingResourceBytes(payload), journal: journal,
                leases: s.leases, root: root, persistenceFault: { phase in
                    if phase == .fileRemoved, !injectedPersistence, let cut { injectedPersistence = true; return cut }
                    return nil
                }, admission: { if denyAdmission { throw CustodyRecordError.fenced } })
            defer { try? resource.retire() }
            let path = parent + "/" + resource.testingName
            func rejected(_ body: () throws -> Void) throws {
                do { try body() }
                catch is CustodyRecordError { return }
                catch is CustodyResourceError { return }
                catch is GitSafetyError { return }
                throw Failure(message: "resource owner unexpectedly accepted " + scenario)
            }
            func absent() -> Bool { var st = stat(); return lstat(path, &st) == -1 && errno == ENOENT }
            func retired() throws {
                try check(resource.isRetired && resource.descriptor == nil && resource.snapshot == nil, "retired owner retained resources")
                try check(resource.testingDescriptors.directory == nil && resource.testingDescriptors.file == nil, "retired descriptors")
                try check(try CustodyCatalogStore(leases: s.leases).readDiscoveryResource(journal: journal) == resource.receipt,
                    "retirement not durable")
            }
            if scenario.hasPrefix("collision-") {
                switch scenario {
                case "collision-directory": try check(mkdir(path, 0o700) == 0, "collision directory")
                case "collision-file": try write(Data("preserve".utf8), path)
                case "collision-symlink": try check(symlink("absent-fixture-target", path) == 0, "collision symlink")
                default: throw Failure(message: "unknown collision")
                }
                var before = stat(); try check(lstat(path, &before) == 0, "collision before")
                try rejected { try resource.create() }; try resource.retire(); try retired()
                var after = stat(); try check(lstat(path, &after) == 0 && FileIdentity(before) == FileIdentity(after), "collision changed")
                if scenario == "collision-file" { try check(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("preserve".utf8), "collision bytes") }
                return
            }
            if scenario == "cancel-create" || scenario == "retire-before-create" {
                if scenario == "cancel-create" { denyAdmission = true; try rejected { try resource.create() } }
                try resource.retire(); try resource.retire(); try retired(); try check(absent(), "pre-creation left a directory")
                try rejected { try resource.create() }; return
            }
            if let fault = DiscoveryFrozenResource.Fault(rawValue: scenario) {
                resource.testingFault = fault
                let creationCuts: Set<DiscoveryFrozenResource.Fault> = [.afterIntent, .afterMkdir, .afterDirectoryOpen,
                    .afterDirectoryReceipt, .afterFileOpen, .afterFileReceipt, .afterWrite, .afterFileSeal,
                    .afterDirectorySeal, .afterReadOnlyOpen, .afterSealReceipt]
                if creationCuts.contains(fault) { try rejected { try resource.create() } }
                else { try resource.create(); try rejected { try resource.retire() } }
                if fault == .afterMkdir {
                    // No directory descriptor was acquired. The production owner
                    // must retain ambiguity; only this test removes its empty fixture.
                    try rejected { try resource.retire() }
                    try check(!resource.isRetired && resource.receipt.phase == .intent, "ambiguous mkdir retired")
                    var first = stat(), second = stat()
                    try check(lstat(path, &first) == 0 && first.st_uid == geteuid() && first.st_mode == S_IFDIR | 0o700,
                              "owned mkdir fixture identity")
                    try check(lstat(path, &second) == 0 && FileIdentity(first) == FileIdentity(second) && rmdir(path) == 0,
                              "owned mkdir fixture removal")
                    try check(absent(), "ambiguous fixture remained"); return
                }
                try resource.retire(); try resource.retire(); try retired(); try check(absent(), "fault cleanup left directory")
                return
            }
            try resource.create(); try resource.revalidate()
            guard let snapshot = resource.snapshot, let fd = resource.descriptor,
                  let dir = resource.testingDescriptors.directory else { throw Failure(message: "owner snapshot missing") }
            var bytes = Data(count: payload.count)
            try bytes.withUnsafeMutableBytes { raw in
                if raw.count > 0 { try check(pread(fd, raw.baseAddress, raw.count, 0) == raw.count, "owned config read") }
            }
            try check(bytes == payload && snapshot.frozenOwnerPID == getpid() && snapshot.frozenSize == payload.count,
                "owned config content/owner")
            try check(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY, "writable target descriptor")
            if scenario == "round-trip" || scenario == "empty" {
                // The resource keeps the same scope's operation authority alive.
                do { _ = try RunAuthority.acquireRun(at: location); throw Failure(message: "owner lost operation exclusion") }
                catch is SecureStateError {}
            } else if scenario.hasPrefix("persist-") {
                try rejected { try resource.retire() }
                try check(injectedPersistence && !resource.isRetired && resource.descriptor == nil, "persistence failure reported retired")
            } else if scenario == "replacement-file" || scenario == "hardlink" || scenario == "extra-entry" {
                try check(fchflags(dir, 0) == 0 && fchflags(fd, 0) == 0, "fixture unseal")
                if scenario == "replacement-file" {
                    try check(rename(path + "/config", path + "/original") == 0, "fixture original move")
                    try write(Data("replacement".utf8), path + "/config")
                } else if scenario == "hardlink" {
                    try check(link(path + "/config", path + "/extra") == 0, "fixture hardlink")
                } else { try write(Data("unexpected".utf8), path + "/extra") }
                try check(fchflags(fd, UInt32(UF_IMMUTABLE)) == 0 && fchflags(dir, UInt32(UF_IMMUTABLE)) == 0, "fixture reseal")
                try rejected { try resource.retire() }
                try check(!resource.isRetired, "replacement/extra retired")
                try check(fchflags(dir, 0) == 0 && fchflags(fd, 0) == 0, "restore fixture flags")
                if scenario == "replacement-file" {
                    try check(try Data(contentsOf: URL(fileURLWithPath: path + "/config")) == Data("replacement".utf8), "replacement removed")
                    try check(unlink(path + "/config") == 0 && rename(path + "/original", path + "/config") == 0, "restore original")
                } else {
                    try check(unlink(path + "/extra") == 0, "remove own extra")
                }
                // An extra entry can be detected by rmdir after config removal.
                // Only reseal when the original file is still present.
                if resource.receipt.phase != .fileRemoved {
                    try check(fchflags(fd, UInt32(UF_IMMUTABLE)) == 0 && fchflags(dir, UInt32(UF_IMMUTABLE)) == 0, "restore original seal")
                }
            } else { throw Failure(message: "unknown owner scenario " + scenario) }
            try resource.retire(); try resource.retire(); try retired(); try check(absent(), "owner directory remained")
            try check(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "retired file descriptor open")
            try check(fcntl(dir, F_GETFD) == -1 && errno == EBADF, "retired directory descriptor open")
        }
    }
    /// Synthetic persisted metadata only. These tests do not claim scratch
    /// creation, resource cleanup, helper integration or production admission.
    static func resourceReceipt(_ scenario: String) throws {
        try fixture { location, _ in
            let s = try scope(location), request = try request(s), ticket = try s.prepare(request)
            let prepared = ticket.testingJournal
            let process = ProcessIdentity(processID: 10, processGroupID: 10, userID: geteuid(), startSeconds: 1,
                startMicroseconds: 1, executablePath: "/fixture/never-persist", generation: UUID().uuidString.lowercased())
            let admitted = try prepared.advancing(to: .admitted, custodian: CustodyProcessObservation(process))
            try s.testingAdvance(ticket, to: admitted)
            let store = try CustodyCatalogStore(leases: s.leases)
            let planned = try store.readDiscoveryResource(journal: admitted)
            try check(planned.phase == .planned && planned.contentSHA256 == nil && planned.size == nil,
                      "reservation lacks mandatory pre-capture expectation")
            let digest = CustodyRecordBinding.digest(Data("private configuration".utf8))
            let intent = try planned.capturing(contentSHA256: digest, size: 21)
            var di = stat(); di.st_dev = 1; di.st_ino = 2; di.st_uid = geteuid(); di.st_mode = S_IFDIR | 0o700; di.st_nlink = 2
            var fi = stat(); fi.st_dev = 1; fi.st_ino = 3; fi.st_uid = geteuid(); fi.st_mode = S_IFREG | 0o600; fi.st_nlink = 1
            let directory = try intent.advancing(to: .directoryCreated, directory: FileIdentity(di))
            let file = try directory.advancing(to: .fileCreated, file: FileIdentity(fi))
            let sealed = try file.advancing(to: .sealed)
            let removedFile = try sealed.advancing(to: .fileRemoved)
            let removedDirectory = try removedFile.advancing(to: .directoryRemoved)
            let retired = try removedDirectory.advancing(to: .retired)
            let chain = [intent, directory, file, sealed, removedFile, removedDirectory, retired]
            let path = location.path + "/custody/receipts/discovery-resource-" + admitted.binding.requestID + ".json"
            switch scenario {
            case "round-trip":
                let maximum = try DiscoveryResourceReceipt(binding: admitted.binding,
                    contentSHA256: digest, size: 1_572_864)
                try check(try DiscoveryResourceReceipt.decode(maximum.encode()) == maximum, "existing configuration maximum preserved")
                for receipt in chain {
                    let data = try receipt.encode()
                    try check(try DiscoveryResourceReceipt.decode(data) == receipt, "resource receipt round trip")
                    let value = String(decoding: data, as: UTF8.self)
                    for privateValue in ["private configuration", "candidate-private", "never-persist", String(repeating: "a", count: 32), "/private/tmp/"] {
                        try check(!value.contains(privateValue), "resource receipt disclosed content or path")
                    }
                }
            case "closed-shape":
                let data = try sealed.encode()
                let bad = [try changed(data) { $0["extra"] = true }, try changed(data) { $0.removeValue(forKey: "binding") },
                    try changed(data) { $0["schema"] = "shadow-sync-discovery-resource/v3" },
                    try changed(data) { $0["size"] = true }, try changed(data) { $0["size"] = 1_572_865 },
                    try changed(data) { $0["transition"] = 2 }, try changed(data) { $0["phase"] = "unknown" },
                    try changed(data) { $0["sha256"] = "invalid" }, data + Data("\n".utf8),
                    Data(("{\"schema\":\"duplicate\"," + String(decoding: data, as: UTF8.self).dropFirst()).utf8),
                    Data(repeating: 32, count: DiscoveryResourceReceipt.maximumBytes + 1)]
                for bytes in bad { try refuses { _ = try DiscoveryResourceReceipt.decode(bytes) } }
            case "transitions":
                for pair in zip(chain, chain.dropFirst()) { try pair.0.validateSuccessor(pair.1) }
                let aborted = try intent.advancing(to: .retired)
                try check(try DiscoveryResourceReceipt.decode(aborted.encode()) == aborted, "pre-creation abort")
                let dirAbort = try directory.advancing(to: .directoryRemoved).advancing(to: .retired)
                let fileAbort = try file.advancing(to: .fileRemoved).advancing(to: .directoryRemoved).advancing(to: .retired)
                for receipt in [dirAbort, fileAbort] { try receipt.validate() }
                try refuses { _ = try intent.advancing(to: .sealed) }
                try refuses { _ = try sealed.advancing(to: .retired) }
                try refuses { _ = try retired.advancing(to: .intent) }
                try refuses { _ = try directory.advancing(to: .fileCreated) }
                try refuses { _ = try file.advancing(to: .sealed, directory: FileIdentity(di)) }
                try refuses { try intent.validateSuccessor(file) }
            case "unsafe-nodes":
                let bytes = try sealed.encode()
                for (node, key, value) in [("directory", "mode", UInt64(S_IFDIR | 0o777)),
                    ("directory", "uid", UInt64(geteuid()) + 1), ("directory", "inode", 0),
                    ("file", "links", 2), ("file", "mode", UInt64(S_IFLNK | 0o600)),
                    ("file", "inode", 2), ("file", "device", 2)] {
                    let bad = try changed(bytes) { v in var n = v[node] as! [String: Any]; n[key] = value; v[node] = n }
                    try refuses { _ = try DiscoveryResourceReceipt.decode(bad) }
                }
            case "namespace":
                let paths = try DiscoveryResourceReceipt.resourcePaths(requestID: admitted.binding.requestID)
                try check(paths == ["/private/tmp/shadow-sync-discovery-config." + admitted.binding.requestID,
                    "/private/tmp/shadow-sync-discovery-config." + admitted.binding.requestID + "/config"], "request namespace")
                for id in ["", "../outside", "ABCDEF", admitted.binding.requestID + "/config"] {
                    try refuses { _ = try DiscoveryResourceReceipt.resourcePaths(requestID: id) }
                }
            case "durable":
                var previous: DiscoveryResourceReceipt? = planned
                for receipt in chain {
                    try store.persistDiscoveryResource(journal: admitted, expected: previous, next: receipt)
                    try store.persistDiscoveryResource(journal: admitted, expected: previous, next: receipt)
                    try check(try store.readDiscoveryResource(journal: admitted) == receipt, "durable resource cursor")
                    previous = receipt
                }
                try check(try DiscoveryResourceReceipt.decode(Data(contentsOf: URL(fileURLWithPath: path))) == retired,
                    "durable independent readback")
                // Resource retirement alone cannot clear the command journal.
                try refuses { _ = try scope(location) }
            case "stale":
                try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent)
                try store.persistDiscoveryResource(journal: admitted, expected: intent, next: directory)
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent) }
                try refuses { try store.persistDiscoveryResource(journal: prepared, expected: intent, next: directory) }
            case "missing":
                try check(try store.readDiscoveryResource(journal: admitted) == planned, "initial planned record")
                try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent)
                try check(unlink(path) == 0, "remove fixture receipt")
                try refuses { _ = try store.readDiscoveryResource(journal: admitted) }
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: intent, next: directory) }
                try refuses { _ = try scope(location) }
            case "binding":
                let other = try DiscoveryResourceReceipt(binding: CustodyRecordBinding(s.binding(nonce: String(repeating: "c", count: 32))),
                    contentSHA256: digest, size: 21)
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: nil, next: other) }
                try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent)
                let wrong = try DiscoveryResourceReceipt.decode(changed(directory.encode()) { $0["size"] = 22 })
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: intent, next: wrong) }
                try check(try store.readDiscoveryResource(journal: admitted) == intent, "refusal changed receipt")
            case "unsafe-file":
                let other = path + ".fixture-target"; try write(Data("preserve".utf8), other)
                try check(unlink(path) == 0 && symlink(other, path) == 0, "fixture symlink")
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent) }
                try check(unlink(path) == 0 && link(other, path) == 0, "fixture hardlink")
                try refuses { _ = try store.readDiscoveryResource(journal: admitted) }
                try check(try Data(contentsOf: URL(fileURLWithPath: other)) == Data("preserve".utf8), "unsafe target changed")
            case "before-swap", "after-swap", "after-sync", "after-unlink":
                try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent)
                let cuts: [String: CustodyCatalogStore.Fault] = ["before-swap": .beforeSwap, "after-swap": .afterSwap,
                    "after-sync": .afterDirectorySync, "after-unlink": .afterPreimageUnlink]
                store.testingFault(cuts[scenario])
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: intent, next: directory) }
                try refuses { _ = try store.readDiscoveryResource(journal: admitted) }
                let retry = try CustodyCatalogStore(leases: s.leases)
                try check(try retry.readDiscoveryResource(journal: admitted) == (scenario == "before-swap" ? intent : directory),
                    "partial write observation mismatch")
                try retry.persistDiscoveryResource(journal: admitted, expected: intent, next: directory)
                try check(try retry.readDiscoveryResource(journal: admitted) == directory, "exact write retry")
                try refuses { _ = try scope(location) }
            case "planned-wire":
                try check(try DiscoveryResourceReceipt.decode(planned.encode()) == planned, "planned round trip")
                try planned.validateSuccessor(intent)
                try planned.validateSuccessor(planned.advancing(to: .retired))
                try refuses { _ = try DiscoveryResourceReceipt.decode(changed(planned.encode()) { $0["sha256"] = digest }) }
                try refuses { _ = try DiscoveryResourceReceipt.decode(changed(intent.encode()) { $0["schema"] = "shadow-sync-discovery-resource/v1" }) }
                try refuses { _ = try planned.advancing(to: .directoryCreated, directory: FileIdentity(di)) }
            case "planned-missing":
                try check(unlink(path) == 0, "remove planned fixture record")
                try refuses { _ = try scope(location) }
                try refuses { try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent) }
                try check(!FileManager.default.fileExists(atPath: path), "missing planned record recreated")
            case "planned-binding":
                let other = try DiscoveryResourceReceipt(planned: CustodyRecordBinding(s.binding(nonce: String(repeating: "c", count: 32))))
                try write(other.encode(), path)
                try refuses { _ = try scope(location) }
                try refuses { _ = try store.readDiscoveryResource(journal: admitted) }
            case "terminal-unretired":
                try store.persistDiscoveryResource(journal: admitted, expected: planned, next: intent)
                let terminal = try admitted.advancing(to: .terminal, outcome: .admissionRefused, reason: .cancelled)
                try refuses { try s.testingAdvance(ticket, to: terminal) }
                try check(ticket.testingJournal == admitted, "unretired resource published terminal")
                try refuses { _ = try scope(location) }
            case "terminal-archive", "archive-missing":
                let empty = try planned.advancing(to: .retired)
                try store.persistDiscoveryResource(journal: admitted, expected: planned, next: empty)
                let terminal = try admitted.advancing(to: .terminal, outcome: .admissionRefused, reason: .cancelled)
                try s.testingAdvance(ticket, to: terminal)
                if scenario == "archive-missing" {
                    try check(unlink(path) == 0, "remove terminal resource fixture")
                    try refuses { _ = try s.testingRetire(ticket) }
                    try refuses { _ = try scope(location) }
                    try check(FileManager.default.fileExists(atPath: location.path + "/custody/" + admitted.binding.requestID + ".json"),
                              "missing resource retired journal")
                } else {
                    _ = try s.testingRetire(ticket)
                    let archive = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/receipts/" + admitted.binding.requestID + ".json"))
                    let value = try CustodyWire.decode(archive, maximum: 65_536).object(keys:
                        ["schema", "journal_sha256", "journal", "discovery_resource", "discovery_resource_sha256"])
                    try check(value["schema"] == .string("shadow-sync-custody-receipt/v2") && value["discovery_resource"] == empty.wire,
                              "archive lost exact resource evidence")
                    try check(value["discovery_resource_sha256"] == .string(CustodyRecordBinding.digest(try empty.encode())),
                              "archive resource digest mismatch")
                    let next = try scope(location); next.close()
                }
            default: throw Failure(message: "unknown discovery resource receipt test")
            }
        }
    }
    static func roundTripPrivacy() throws {
        try fixture { location, _ in
            let s = try scope(location), j = try journal(s), encoded = try j.encode()
            try check(try CustodyJournal.decode(encoded) == j, "journal round trip")
            let text = String(decoding: encoded, as: UTF8.self)
            for secret in ["candidate-private", "private-environment-value", String(repeating: "a", count: 32), "executablePath"] {
                try check(!text.contains(secret), "journal leaked request/private process data")
            }
            try check(j.binding.nonceSHA256.count == 64 && j.ordinal == 0 && j.phase == .prepared, "prepared shape")
        }
    }
    static func closedJournalShape() throws {
        try fixture { location, _ in
            let s = try scope(location), data = try journal(s).encode()
            for bad in [try changed(data) { $0["extra"] = true }, try changed(data) { $0["schema"] = "shadow-sync-custody/v2" },
                        try changed(data) { $0.removeValue(forKey: "leases") },
                        Data(("{\"schema\":\"duplicate\"," + String(decoding: data, as: UTF8.self).dropFirst()).utf8)] {
                try refuses { _ = try CustodyJournal.decode(bad) }
            }
        }
    }
    static func canonicalTypes() throws {
        try fixture { location, _ in
            let s = try scope(location), data = try journal(s).encode()
            for bad in [data + Data("\n".utf8), Data([0xff]), Data(repeating: 32, count: 32_769),
                        try changed(data) { $0["transition"] = true }, try changed(data) { $0["transition"] = -1 },
                        try changed(data) { $0["transition"] = 0.5 }] {
                try refuses { _ = try CustodyJournal.decode(bad) }
            }
        }
    }
    static func closedTransitions() throws {
        try fixture { location, _ in
            let s = try scope(location), j = try journal(s)
            try refuses { _ = try j.advancing(to: .executing) }
            try refuses { _ = try j.advancing(to: .terminal, outcome: .completed, reason: .none, waitStatus: 0) }
            let terminal = try j.advancing(to: .terminal, outcome: .admissionRefused, reason: .startFailure)
            try check(try CustodyJournal.decode(terminal.encode()) == terminal, "terminal round trip")
            try refuses { _ = try terminal.advancing(to: .admitted) }
            let recovered = try j.recoveredAfterBoot()
            try check(recovered.outcome == .interruptedUnknown && recovered.waitStatus == nil, "boot recovery invented success")
        }
    }
    static func processObservations() throws {
        try fixture { location, _ in
            let s = try scope(location), j = try journal(s)
            let process = ProcessIdentity(processID: 10, processGroupID: 10, userID: geteuid(), startSeconds: 1,
                startMicroseconds: 1, executablePath: "/fixture/never-persist", generation: UUID().uuidString.lowercased())
            let observed = try CustodyProcessObservation(process)
            let admitted = try j.advancing(to: .admitted, custodian: observed)
            try check(!String(decoding: try admitted.encode(), as: UTF8.self).contains("never-persist"), "persisted executable path")
            try refuses { _ = try CustodyProcessObservation(ProcessIdentity(processID: 10, processGroupID: 11,
                userID: geteuid(), startSeconds: 1, startMicroseconds: 1, executablePath: "/fixture", generation: UUID().uuidString.lowercased())) }
            let bad = try changed(admitted.encode()) { object in
                var processes = object["processes"] as! [String: Any]
                var child = processes["custodian"] as! [String: Any]; child["pid"] = 0; processes["custodian"] = child; object["processes"] = processes
            }
            try refuses { _ = try CustodyJournal.decode(bad) }
        }
    }
    static func catalogShape() throws {
        let initial = try CustodyCatalog.initialized.encode()
        try check(try CustodyCatalog.decode(initial).entries.isEmpty, "initialized catalog")
        for bad in [try changed(initial) { $0.removeValue(forKey: "initialized") },
                    try changed(initial) { $0["initialized"] = true }, try changed(initial) { $0["revision"] = 0 },
                    try changed(initial) { $0["schema"] = "shadow-sync-custody-catalog/v2" }] {
            try refuses { _ = try CustodyCatalog.decode(bad) }
        }
    }
    static func catalogBounds() throws {
        try fixture { location, _ in
            let s = try scope(location)
            var catalog = CustodyCatalog.initialized
            for _ in 0..<128 { catalog = try catalog.reserving(journal(s)) }
            try check(try CustodyCatalog.decode(catalog.encode()) == catalog, "128 entries round trip")
            try refuses { _ = try catalog.reserving(journal(s)) }
            let duplicate = try changed(catalog.encode()) { object in
                var entries = object["entries"] as! [[String: Any]]; entries[1] = entries[0]; object["entries"] = entries
            }
            try refuses { _ = try CustodyCatalog.decode(duplicate) }
            let unsorted = try changed(catalog.encode()) { object in object["entries"] = (object["entries"] as! [Any]).reversed().map { $0 } }
            try refuses { _ = try CustodyCatalog.decode(unsorted) }
        }
    }
    static func durablePreparation() throws {
        try fixture { location, _ in
            let s = try scope(location), r = try request(s), ticket = try s.prepare(r)
            let catalog = try CustodyCatalog.decode(bytes(location, "catalog.json"))
            let j = try CustodyJournal.decode(bytes(location, ticket.requestID + ".json"))
            try check(catalog.revision == 2 && catalog.entries == [CustodyCatalogEntry(j)] && j == ticket.testingJournal,
                      "durable preparation binding")
        }
    }
    static func staleEmptyScopes() throws {
        try fixture { location, _ in
            let first = try scope(location), second = try scope(location)
            try check(try first.testingRead().entries.isEmpty && second.testingRead().entries.isEmpty, "two empty observations")
            _ = try first.prepare(request(first))
            try refuses { _ = try second.prepare(request(second)) }
            try check(second.observation == .pending, "failed scope reopened")
            try check(try first.testingRead().entries.count == 1, "competing scope reserved")
        }
    }
    static func liveReferenceScope() throws {
        try fixture { location, _ in
            let first = try scope(location), second = try scope(location)
            _ = try first.prepare(request(first)); _ = try first.prepare(request(first))
            try refuses { _ = try second.prepare(request(second, binding: first.binding(nonce: String(repeating: "d", count: 32)))) }
            try check(try first.testingRead().entries.count == 2, "live scope did not retain ownership")
        }
    }
    static func closedScope() throws {
        try fixture { location, _ in
            let s = try scope(location), before = try bytes(location, "catalog.json"); s.close()
            try refuses { _ = try s.prepare(request(s)) }
            try check(try bytes(location, "catalog.json") == before && s.observation == .terminal, "closed scope wrote")
        }
    }
    static func observationScope() throws {
        try fixture { location, _ in
            let first = try scope(location); _ = try first.prepare(request(first))
            let observer = try scope(location, observation: true)
            try refuses { _ = try observer.prepare(request(observer)) }
            _ = try observer.prepare(request(observer, kind: .launchctlRead))
            try check(try observer.testingRead().entries.count == 2, "fixed observation could not coexist")
        }
    }
    static func drainingScope() throws {
        for observation in [false, true] {
            for pending in [false, true] {
                try fixture { location, _ in
                    let s = try scope(location, observation: observation)
                    let kind: CustodyCommandKind = observation ? .launchctlRead : .discoveryGit
                    let ticket = try s.prepare(request(s, kind: kind))
                    let draining = try ticket.testingJournal.advancing(to: .draining)
                    try s.testingAdvance(ticket, to: draining)
                    if pending { try s.testingAdvance(ticket, to: draining.advancing(to: .cleanupPending)) }
                    let before = try bytes(location, "catalog.json")
                    try refuses { _ = try s.prepare(request(s, kind: kind)) }
                    try check(s.observation == .pending && (try bytes(location, "catalog.json")) == before,
                              "closing journal admitted more work")
                    let diagnostic = try scope(location, observation: true)
                    _ = try diagnostic.prepare(request(diagnostic, kind: .launchctlRead))
                }
            }
        }
    }
    static func expiredScope() throws {
        for observation in [false, true] {
            try fixture { location, _ in
                let s = try scope(location, observation: observation)
                let kind: CustodyCommandKind = observation ? .launchctlRead : .discoveryGit
                let ticket = try s.prepare(request(s, kind: kind, workSeconds: 0.1))
                let deadline = ticket.testingJournal.budget.work, now = DispatchTime.now().uptimeNanoseconds
                if now < deadline { Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000 + 0.02) }
                let before = try bytes(location, "catalog.json")
                try refuses { _ = try s.prepare(request(s, kind: kind)) }
                try check(s.observation == .pending && (try bytes(location, "catalog.json")) == before,
                          "expired journal admitted more work")
                let diagnostic = try scope(location, observation: true)
                _ = try diagnostic.prepare(request(diagnostic, kind: .launchctlRead))
            }
        }
    }
    static func guardContention() throws {
        try fixture { location, _ in
            let fd = open(location.path + "/custody/catalog.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "guard fixture")
            defer { close(fd) }
            try refuses { _ = try scope(location) }
            try check(flock(fd, LOCK_UN) == 0, "guard release")
            _ = try scope(location)
        }
    }
    static func missingInitialization() throws {
        try fixture(initialized: false) { location, _ in
            try refuses { _ = try scope(location) }
            var info = stat(); try check(lstat(location.path + "/custody", &info) == -1 && errno == ENOENT, "implicit initialization")
        }
    }
    static func missingControls() throws {
        for name in ["catalog.json", "catalog.lock", "receipts"] {
            try fixture { location, _ in
                let path = location.path + "/custody/" + name
                try check(rename(path, path + ".saved") == 0, "missing control fixture")
                try refuses { _ = try scope(location) }
                var info = stat(); try check(lstat(path, &info) == -1 && errno == ENOENT, "missing control reset")
            }
        }
    }
    static func missingExpectedJournal() throws {
        try fixture { location, _ in
            let s = try scope(location), ticket = try s.prepare(request(s)), path = location.path + "/custody/" + ticket.requestID + ".json"
            try check(unlink(path) == 0, "missing journal fixture")
            try refuses { _ = try scope(location) }
            try refuses { _ = try scope(location, observation: true) }
            try check(try CustodyCatalog.decode(bytes(location, "catalog.json")).entries.count == 1, "expected record forgotten")
        }
    }
    static func orphanJournal() throws {
        try fixture { location, _ in
            let s = try scope(location), j = try journal(s)
            try write(j.encode(), location.path + "/custody/" + j.binding.requestID + ".json")
            try refuses { _ = try scope(location) }
            let terminal = try j.advancing(to: .terminal, outcome: .admissionRefused, reason: .startFailure)
            try write(terminal.encode(), location.path + "/custody/" + j.binding.requestID + ".json")
            try refuses { _ = try scope(location) } // Terminal text alone is insufficient.
        }
    }
    static func mismatchedJournal() throws {
        try fixture { location, _ in
            let s = try scope(location), ticket = try s.prepare(request(s))
            let bad = try changed(ticket.testingJournal.encode()) { object in
                var binding = object["binding"] as! [String: Any]; binding["scope"] = UUID().uuidString.lowercased(); object["binding"] = binding
            }
            try write(bad, location.path + "/custody/" + ticket.requestID + ".json")
            try refuses { _ = try scope(location) }
        }
    }
    static func unsafeMetadata() throws {
        for name in ["catalog.json", "catalog.lock", "receipts"] {
            try fixture { location, _ in
                let path = location.path + "/custody/" + name
                try check(chmod(path, 0o777) == 0, "unsafe mode fixture")
                try refuses { _ = try scope(location) }
            }
        }
        for linkKind in ["hard", "symbolic"] {
            try fixture { location, _ in
                let path = location.path + "/custody/catalog.json"
                if linkKind == "hard" { try check(link(path, path + ".alias") == 0, "hardlink fixture") }
                else {
                    try check(rename(path, path + ".saved") == 0 && symlink("catalog.json.saved", path) == 0, "symlink fixture")
                }
                try refuses { _ = try scope(location) }
            }
        }
    }
    static func staleCursor() throws {
        try fixture { location, _ in
            let s = try scope(location), ticket = try s.prepare(request(s)), old = ticket.testingJournal
            let end = try old.advancing(to: .terminal, outcome: .admissionRefused, reason: .startFailure)
            try s.testingAdvance(ticket, to: end)
            try refuses { try s.testingAdvance(ticket, to: end) }
            try check(try CustodyJournal.decode(bytes(location, ticket.requestID + ".json")) == end, "stale cursor rewrote")
        }
    }
    static func archiveRetirement() throws {
        try fixture { location, _ in
            let s = try scope(location)
            var original = stat(); try check(lstat(location.path + "/custody/catalog.lock", &original) == 0, "guard identity")
            let ticket = try s.prepare(request(s))
            let terminal = try ticket.testingJournal.advancing(to: .terminal, outcome: .admissionRefused, reason: .startFailure)
            try s.testingAdvance(ticket, to: terminal); s.close()
            try check(s.observation == .closing, "outstanding scope closed early")
            let digest = try s.testingRetire(ticket)
            let receipt = try bytes(location, "receipts/" + ticket.requestID + ".json")
            try check(digest == CustodyRecordBinding.digest(receipt) && s.observation == .terminal, "terminal receipt binding")
            let c = try s.testingRead(); try check(c.entries.isEmpty && c.revision == 3, "catalog retirement revision")
            var after = stat(); try check(lstat(location.path + "/custody/catalog.lock", &after) == 0 && original.st_ino == after.st_ino, "metadata lock replaced")
            try check(lstat(location.path + "/custody/" + ticket.requestID + ".json", &after) == -1 && errno == ENOENT, "terminal journal not retired")
            _ = try scope(location)
        }
    }
    static func faultCut(_ cut: CustodyCatalogStore.Fault) throws {
        try fixture { location, _ in
            let s = try scope(location), request = try request(s), before = try bytes(location, "catalog.json")
            s.testingFault(cut); try refuses { _ = try s.prepare(request) }
            try check(s.observation == .pending, "failed metadata transaction reopened")
            try refuses { _ = try s.prepare(request) }
            if cut == .beforeSwap {
                try check(try bytes(location, "catalog.json") == before, "pre-swap failure changed catalog")
                _ = try scope(location)
            } else {
                try refuses { _ = try scope(location) }
                if cut == .afterSwap || cut == .afterDirectorySync {
                    let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody")
                    let pending = names.filter { $0.hasPrefix(".custody-pending-") }
                    try check(pending.count == 1 && (try bytes(location, pending[0])) == before, "failed replacement lost preimage")
                }
            }
        }
    }
    static func retirementFault(_ cut: CustodyCatalogStore.Fault, tamper: Bool = false) throws {
        try fixture { location, _ in
            let s = try scope(location), ticket = try s.prepare(request(s))
            let end = try ticket.testingJournal.advancing(to: .terminal, outcome: .admissionRefused, reason: .startFailure)
            try s.testingAdvance(ticket, to: end); s.testingFault(cut)
            try refuses { _ = try s.testingRetire(ticket) }
            let c = try CustodyCatalog.decode(bytes(location, "catalog.json"))
            try check(c.entries.count == (cut == .afterArchive ? 1 : 0), "retirement crash ordering")
            let journal = try CustodyJournal.decode(bytes(location, ticket.requestID + ".json"))
            try check(journal == end, "interrupted retirement lost journal")
            if tamper {
                try write(Data("{}".utf8), location.path + "/custody/receipts/" + ticket.requestID + ".json")
                try refuses { _ = try scope(location) }
            } else { _ = try scope(location) }
        }
    }
    static func committedCleanupFailure() throws {
        try fixture { location, _ in
            let s = try scope(location), r = try request(s), before = try bytes(location, "catalog.json")
            s.testingFault(.afterPreimageUnlink)
            do {
                _ = try s.prepare(r)
                throw Failure(message: "committed cleanup cut unexpectedly succeeded")
            } catch CustodyRecordError.committedCleanupFailure(let code) { try check(code == EIO, "wrong cleanup error") }
            let committed = try bytes(location, "catalog.json"), catalog = try CustodyCatalog.decode(committed)
            try check(committed != before && catalog.entries.map(\.requestID) == [r.binding.requestID]
                      && s.observation == .pending, "committed metadata lost or scope reopened")
            let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody")
            try check(!names.contains(where: { $0.hasPrefix(".custody-pending-") }), "preimage unlink cut not reached")
            try refuses { _ = try scope(location) }
            try refuses { _ = try scope(location, observation: true) }
        }
    }
    final class RaceResults: @unchecked Sendable {
        private let mutex = NSLock(); private var good = 0; private var bad = 0
        func record(_ success: Bool) { mutex.lock(); if success { good += 1 } else { bad += 1 }; mutex.unlock() }
        var correct: Bool { mutex.lock(); defer { mutex.unlock() }; return good == 1 && bad == 1 }
    }
    static func concurrentReservations() throws {
        try fixture { location, _ in
            let a = try scope(location), b = try scope(location), result = RaceResults(), group = DispatchGroup()
            let ra = try request(a), rb = try request(b)
            for (s, request) in [(a, ra), (b, rb)] {
                group.enter(); DispatchQueue.global().async {
                    do { _ = try s.prepare(request); result.record(true) }
                    catch { result.record(false) }; group.leave()
                }
            }
            try check(group.wait(timeout: .now() + 5) == .success && result.correct, "concurrent scopes both admitted or lost")
            try check(try CustodyCatalog.decode(bytes(location, "catalog.json")).entries.count == 1, "reservation race changed roster")
        }
    }
}


private enum CustodyRecoverySelfTests {
    typealias H = CustodyCatalogSelfTests
    private struct ReceiptPreimage: Equatable {
        let identity: FileIdentity
        let bytes: Data
    }
    private static func receiptPreimages(_ location: StateLocation) throws -> [String: ReceiptPreimage] {
        let root = location.path + "/custody/receipts"
        var info = stat()
        try H.check(lstat(root, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR, "receipt directory fixture")
        var result = ["": ReceiptPreimage(identity: FileIdentity(info), bytes: Data())]
        for name in try FileManager.default.contentsOfDirectory(atPath: root) {
            let path = root + "/" + name
            try H.check(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG, "receipt file fixture")
            result[name] = ReceiptPreimage(identity: FileIdentity(info), bytes: try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        return result
    }
    // A synthetic prior boot must bind every mandatory record to that boot;
    // otherwise recovery would only exercise malformed-evidence rejection.
    private static func fixtureBoot(_ boot: String, journal: CustodyJournal, location: StateLocation) throws -> CustodyJournal {
        let changed = try CustodyJournal.decode(H.changed(journal.encode()) { object in
            var binding = object["binding"] as! [String: Any]; binding["boot"] = boot; object["binding"] = binding
        })
        let name = "receipts/discovery-resource-" + journal.binding.requestID + ".json"
        let resource = try DiscoveryResourceReceipt.decode(H.bytes(location, name))
        try H.check(resource.binding == journal.binding && resource.phase == .planned, "prior-boot resource fixture")
        let rebound = try DiscoveryResourceReceipt.decode(H.changed(resource.encode()) { object in
            var binding = object["binding"] as! [String: Any]; binding["boot"] = boot; object["binding"] = binding
        })
        try H.check(rebound.binding == changed.binding, "prior-boot resource binding")
        try H.write(rebound.encode(), location.path + "/custody/" + name)
        try H.write(changed.encode(), location.path + "/custody/" + changed.binding.requestID + ".json")
        return changed
    }
    static func pending(_ location: StateLocation, oldBoot: Bool = true, executing: Bool = false, count: Int = 1) throws -> [CustodyJournal] {
        let scope = try H.scope(location)
        var result: [CustodyJournal] = []
        for _ in 0..<count {
            let ticket = try scope.prepare(H.request(scope))
            var journal = ticket.testingJournal
            if executing {
                let custodian = try CustodyProcessObservation(wire: .object([
                    "pid": .unsigned(12345), "group": .unsigned(12345), "uid": .unsigned(UInt64(geteuid())),
                    "start_seconds": .unsigned(1), "start_microseconds": .unsigned(0), "generation": .string(RunIdentity.make())]))
                let target = try CustodyProcessObservation(wire: .object([
                    "pid": .unsigned(12346), "group": .unsigned(12346), "uid": .unsigned(UInt64(geteuid())),
                    "start_seconds": .unsigned(2), "start_microseconds": .unsigned(0), "generation": .string(RunIdentity.make())]))
                journal = try journal.advancing(to: .admitted, custodian: custodian)
                try scope.testingAdvance(ticket, to: journal)
                journal = try journal.advancing(to: .executing, target: target)
                try scope.testingAdvance(ticket, to: journal)
            }
            result.append(journal)
        }
        scope.close()
        if oldBoot {
            let boot = RunIdentity.make()
            try H.check(boot != CustodyBootIdentity.current(), "fixture boot collision")
            result = try result.map { journal in
                try fixtureBoot(boot, journal: journal, location: location)
            }
            let catalog = try H.changed(H.bytes(location, "catalog.json")) { object in
                var entries = object["entries"] as! [[String: Any]]
                for index in entries.indices { entries[index]["boot"] = boot }
                object["entries"] = entries
            }
            try H.write(CustodyCatalog.decode(catalog).encode(), location.path + "/custody/catalog.json")
        }
        return result
    }
    static func recover(_ location: StateLocation, _ root: String, fault: CustodyCatalogStore.Fault? = nil) throws -> [CustodyJournal] {
        let context = try CustodyRecoveryContext.testing(at: location, root: root)
        if let fault { context.testingFault(fault) }
        return try context.recordInterruptedPriorBoot()
    }
    static func receipt(_ location: StateLocation, _ journal: CustodyJournal) throws -> Data {
        try H.bytes(location, "receipts/" + journal.binding.requestID + ".recovery.json")
    }
    static func sameBoot() throws {
        try H.fixture { location, root in
            let journal = try pending(location, oldBoot: false)[0]
            let catalog = try H.bytes(location, "catalog.json")
            let receipts = try receiptPreimages(location)
            try H.refuses { _ = try recover(location, root) }
            try H.check(try H.bytes(location, journal.binding.requestID + ".json") == journal.encode(), "same boot changed journal")
            try H.check(try H.bytes(location, "catalog.json") == catalog, "same boot changed catalog")
            try H.check(try receiptPreimages(location) == receipts, "same boot changed receipt names, bytes or identities")
        }
    }
    static func priorBoot(executing: Bool) throws {
        try H.fixture { location, root in
            let original = try pending(location, executing: executing)[0], expected = try original.recoveredAfterBoot()
            let catalog = try H.bytes(location, "catalog.json")
            try H.write(Data("pre-postflight-preserved".utf8), location.path + "/operation-evidence.json")
            let recovered = try recover(location, root)
            try H.check(recovered == [expected] && recovered[0].outcome == .interruptedUnknown && recovered[0].waitStatus == nil, "recovery invented success")
            let raw = try receipt(location, original), object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            let preimage = try JSONSerialization.data(withJSONObject: object["original"]!, options: [.sortedKeys, .withoutEscapingSlashes])
            try H.check(try CustodyJournal.decode(preimage) == original, "lost original journal")
            try H.check(object["observed_boot"] as? String == CustodyBootIdentity.current(), "did not bind actual kernel boot")
            try H.check(try H.bytes(location, "catalog.json") == catalog, "recovery retired expected work")
            try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/operation-evidence.json")) == Data("pre-postflight-preserved".utf8), "operation evidence changed")
            try H.check(try recover(location, root) == [expected] && receipt(location, original) == raw, "recovery retry changed evidence")
        }
    }
    static func mixedBoot() throws {
        try H.fixture { location, root in
            let journals = try pending(location, count: 2)
            let second = try fixtureBoot(CustodyBootIdentity.current(), journal: journals[1], location: location)
            let catalog = try CustodyCatalog.initialized.reserving(journals[0]).reserving(second)
            try H.write(catalog.encode(), location.path + "/custody/catalog.json")
            let receipts = try receiptPreimages(location)
            try H.refuses { _ = try recover(location, root) }
            try H.check(try H.bytes(location, journals[0].binding.requestID + ".json") == journals[0].encode(), "partially recovered mixed boot")
            try H.check(try receiptPreimages(location) == receipts, "mixed boot changed receipt names, bytes or identities")
        }
    }
    static func exclusiveLocks() throws {
        try H.fixture { location, root in
            _ = try pending(location)
            for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock"] {
                let fd = open(location.path + "/" + name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                try H.check(fd >= 0 && flock(fd, LOCK_SH | LOCK_NB) == 0, "reader lock")
                do { try H.refuses { _ = try recover(location, root) } }
                catch { close(fd); throw error }
                close(fd)
            }
            let context = try CustodyRecoveryContext.testing(at: location, root: root)
            for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock"] {
                let fd = open(location.path + "/" + name, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                try H.check(fd >= 0, "probe lock")
                let rc = flock(fd, LOCK_SH | LOCK_NB), code = errno; close(fd)
                try H.check(rc == -1 && code == EWOULDBLOCK, "recovery lost exclusive original lock")
            }
            try H.check(try context.recordInterruptedPriorBoot().count == 1, "held recovery failed")
        }
    }
    static func missingControls() throws {
        for name in ["catalog.json", "catalog.lock", "receipts"] {
            try H.fixture { location, root in
                _ = try pending(location)
                let path = location.path + "/custody/" + name
                try H.check(rename(path, path + ".saved") == 0, "missing control fixture")
                try H.refuses { _ = try recover(location, root) }
                try H.check(!FileManager.default.fileExists(atPath: path), "recovery recreated missing metadata")
            }
        }
    }
    static func replacedLock() throws {
        try H.fixture { location, root in
            let journal = try pending(location)[0]
            let context = try CustodyRecoveryContext.testing(at: location, root: root)
            let path = location.path + "/operation.lock"
            try H.check(rename(path, path + ".old") == 0, "replace fixture lock")
            try H.write(Data(), path)
            try H.refuses { _ = try context.recordInterruptedPriorBoot() }
            try H.check(try H.bytes(location, journal.binding.requestID + ".json") == journal.encode(), "replacement lost preimage")
        }
    }
    static func malformed() throws {
        for kind in ["missing", "newer", "hardlink"] {
            try H.fixture { location, root in
                let j = try pending(location)[0], path = location.path + "/custody/" + j.binding.requestID + ".json"
                if kind == "missing" { try H.check(unlink(path) == 0, "missing fixture") }
                if kind == "newer" { try H.write(H.changed(j.encode()) { $0["schema"] = "shadow-sync-custody/v99" }, path) }
                if kind == "hardlink" { try H.check(link(path, location.path + "/journal-alias") == 0, "hardlink fixture") }
                let catalog = try H.bytes(location, "catalog.json")
                try H.refuses { _ = try recover(location, root) }
                try H.check(try H.bytes(location, "catalog.json") == catalog, "bad evidence was retired")
            }
        }
    }
    static func retry(_ fault: CustodyCatalogStore.Fault) throws {
        try H.fixture { location, root in
            let j = try pending(location)[0]
            try H.refuses { _ = try recover(location, root, fault: fault) }
            let current = try CustodyJournal.decode(H.bytes(location, j.binding.requestID + ".json"))
            try H.check(current == (fault == .afterRecoveryJournal ? j.recoveredAfterBoot() : j), "fault changed wrong phase")
            try H.check(try recover(location, root) == [j.recoveredAfterBoot()], "idempotent recovery retry failed")
            _ = try receipt(location, j)
        }
    }
    static func earlierRecoveryBoot() throws {
        try H.fixture { location, root in
            let j = try pending(location)[0]
            try H.refuses { _ = try recover(location, root, fault: .afterRecoveryPreimage) }
            let previousBoot = RunIdentity.make()
            try H.check(previousBoot != j.binding.bootID && previousBoot != CustodyBootIdentity.current(), "recovery boot fixture")
            let previous = try H.changed(receipt(location, j)) { $0["observed_boot"] = previousBoot }
            let path = location.path + "/custody/receipts/" + j.binding.requestID + ".recovery.json"
            try H.write(previous, path)
            try H.check(try recover(location, root) == [j.recoveredAfterBoot()], "another reboot stranded valid recovery")
            try H.check(try receipt(location, j) == previous, "prior recovery boot was rewritten")
        }
    }
    static func tamperedPreimage() throws {
        try H.fixture { location, root in
            let j = try pending(location)[0]
            try H.refuses { _ = try recover(location, root, fault: .afterRecoveryPreimage) }
            try H.write(Data("{}".utf8), location.path + "/custody/receipts/" + j.binding.requestID + ".recovery.json")
            try H.refuses { _ = try recover(location, root) }
            try H.check(try H.bytes(location, j.binding.requestID + ".json") == j.encode(), "tampered preimage permitted transition")
        }
    }
    static func revalidationFence() throws {
        try H.fixture { location, root in
            _ = try pending(location); _ = try recover(location, root)
            try H.refuses { _ = try H.scope(location) }
            _ = try H.scope(location, observation: true)
            // Recovery receipts are mandatory evidence, not optional history.
            let catalog = try CustodyCatalog.decode(H.bytes(location, "catalog.json"))
            let name = catalog.entries[0].requestID + ".recovery.json"
            try H.check(unlink(location.path + "/custody/receipts/" + name) == 0, "missing recovery receipt fixture")
            try H.refuses { _ = try H.scope(location, observation: true) }
        }
    }
    static func interruptedSwap() throws {
        try H.fixture { location, root in
            let j = try pending(location)[0]
            try H.refuses { _ = try recover(location, root, fault: .afterRecoveryPreimage) }
            try H.refuses { _ = try recover(location, root, fault: .afterSwap) }
            let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody")
            let saved = names.filter { $0.hasPrefix(".custody-pending-") }
            try H.check(saved.count == 1 && H.bytes(location, saved[0]) == j.encode(), "swap failure lost prior journal")
            try H.refuses { _ = try recover(location, root) }
        }
    }
    static func bindingMismatch() throws {
        try H.fixture { location, root in
            let j = try pending(location)[0]
            let bad = try CustodyJournal.decode(H.changed(j.encode()) { object in
                var leases = object["leases"] as! [[String: Any]]
                for i in leases.indices { leases[i]["inode"] = (leases[i]["inode"] as! UInt64) + 1 }
                object["leases"] = leases
            })
            try H.write(bad.encode(), location.path + "/custody/" + j.binding.requestID + ".json")
            let receipts = try receiptPreimages(location)
            try H.refuses { _ = try recover(location, root) }
            try H.check(try receiptPreimages(location) == receipts, "foreign lock binding changed receipt names, bytes or identities")
        }
    }
}


private enum FreshStateSelfTests {
    typealias H = CustodyCatalogSelfTests
    static func fixture(_ body: (String, StateLocation, String) throws -> Void) throws {
        var pattern = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-fresh-state.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&pattern) else { throw H.Failure(message: "fresh-state fixture") }
        let root = String(cString: raw); var before = stat(); try H.check(lstat(root, &before) == 0, "fixture identity")
        defer { var after = stat(); if lstat(root, &after) == 0 && FileIdentity(after).matchesStableNode(FileIdentity(before)) { try? FileManager.default.removeItem(atPath: root) } }
        try H.check(mkdir(root + "/state", 0o700) == 0, "state parent")
        try body(root, StateLocation.isolated(root: root), root + "/state")
    }
    static func transaction(_ parent: String) throws -> String {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: parent + "/.shadow-sync-initialization.json"))
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        return json["transaction"] as! String
    }
    static func attempt(_ root: String, cut: FreshStateInitialization.Fault? = nil) throws -> FreshStateInitialization.Result {
        let initializer = try FreshStateInitialization.testing(root: root)
        if let cut { initializer.testingFault(cut) }
        return try initializer.publish()
    }
    static func publication() throws {
        try fixture { root, location, parent in
            var initializer: FreshStateInitialization? = try FreshStateInitialization.testing(root: root)
            try H.check(!FileManager.default.fileExists(atPath: location.path), "constructor published state")
            let result = try initializer!.publish()
            var state = stat(); try H.check(lstat(location.path, &state) == 0 && UInt64(state.st_ino) == result.stateInode, "published inode")
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: location.path))
            try H.check(names == ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock", "custody"], "fresh state roster")
            let catalog = try CustodyCatalog.decode(H.bytes(location, "catalog.json"))
            try H.check(catalog == CustodyCatalog.initialized, "fresh catalog")
            for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock"] {
                let fd = open(location.path + "/" + name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                try H.check(fd >= 0, "published lock"); let rc = flock(fd, LOCK_SH | LOCK_NB), code = errno; close(fd)
                try H.check(rc == -1 && code == EWOULDBLOCK, "publication lost retained lock")
            }
            try H.check(try initializer!.publish() == result, "same-object retry")
            initializer = nil
            _ = try H.scope(location)
            try H.check(try attempt(root) == result, "reopened transaction changed publication")
            try H.check(!FileManager.default.fileExists(atPath: parent + "/.shadow-sync-initialization." + result.transaction), "stage remains after publication")
        }
    }
    static func publisherRefusal() throws {
        do { _ = try FreshStateInitialization.production() }
        catch is PublisherPolicyError { return }
        throw H.Failure(message: "ordinary app acquired initializer publisher identity")
    }
    static func existingState() throws {
        try fixture { root, location, parent in
            try H.check(mkdir(location.path, 0o700) == 0, "existing state fixture")
            try H.write(Data("preserved".utf8), location.path + "/authority-fixture.json")
            try H.refuses { _ = try attempt(root) }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/authority-fixture.json")) == Data("preserved".utf8), "existing state changed")
            try H.check(!FileManager.default.fileExists(atPath: parent + "/.shadow-sync-initialization.json"), "existing state acquired fresh manifest")
        }
    }
    static func legacyState() throws {
        try fixture { root, location, parent in
            let name = String(LegacyInstallationRelease.bundleIdentifier.split(separator: ".").last!)
            try H.check(mkdir(parent + "/" + name, 0o700) == 0, "legacy fixture")
            try H.refuses { _ = try attempt(root) }
            try H.check(!FileManager.default.fileExists(atPath: location.path), "legacy was treated as fresh")
        }
    }
    static func missingParent() throws {
        try fixture { root, location, parent in
            try H.check(rmdir(parent) == 0, "remove empty parent fixture")
            try H.refuses { _ = try attempt(root) }
            try H.check(!FileManager.default.fileExists(atPath: parent) && !FileManager.default.fileExists(atPath: location.path), "missing parent silently recreated")
        }
    }
    static func guardContention() throws {
        try fixture { root, _, _ in
            let first = try FreshStateInitialization.testing(root: root)
            try H.refuses { _ = try FreshStateInitialization.testing(root: root) }
            _ = try first.publish()
        }
    }
    static func unsafeControls() throws {
        for kind in ["symlink", "hardlink", "mode", "nonempty"] {
            try fixture { root, location, parent in
                let path = parent + "/.shadow-sync-initialization.lock"
                try H.write(Data(), path)
                if kind == "symlink" {
                    try H.check(rename(path, path + ".saved") == 0 && symlink(".shadow-sync-initialization.lock.saved", path) == 0, "symlink guard")
                } else if kind == "hardlink" { try H.check(link(path, path + ".alias") == 0, "hardlink guard") }
                else if kind == "mode" { try H.check(chmod(path, 0o644) == 0, "guard mode") }
                else { try H.write(Data("unknown".utf8), path) }
                try H.refuses { _ = try attempt(root) }
                try H.check(!FileManager.default.fileExists(atPath: location.path), "unsafe guard published state")
            }
        }
    }
    static func wrongRelease() throws {
        try fixture { root, location, _ in
            try H.refuses { _ = try attempt(root, cut: .afterManifest) }
            try H.refuses { _ = try FreshStateInitialization.testing(root: root, release: String(repeating: "f", count: 64)).publish() }
            try H.check(!FileManager.default.fileExists(atPath: location.path), "different release adopted transaction")
            _ = try attempt(root)
        }
    }
    static func unknownStage() throws {
        try fixture { root, location, parent in
            try H.refuses { _ = try attempt(root, cut: .afterStage) }
            let stage = parent + "/.shadow-sync-initialization." + (try transaction(parent))
            try H.write(Data("unrecognized".utf8), stage + "/user-data")
            try H.refuses { _ = try attempt(root) }
            try H.check(!FileManager.default.fileExists(atPath: location.path), "unknown staged data published")
            try H.check(try Data(contentsOf: URL(fileURLWithPath: stage + "/user-data")) == Data("unrecognized".utf8), "unknown data reset")
        }
    }
    static func missingPhase() throws {
        try fixture { root, location, parent in
            try H.refuses { _ = try attempt(root, cut: .afterReady) }
            let prefix = parent + "/.shadow-sync-initialization." + (try transaction(parent))
            try H.check(unlink(prefix + ".created.json") == 0, "remove created receipt")
            try H.refuses { _ = try attempt(root) }
            try H.check(!FileManager.default.fileExists(atPath: location.path), "missing receipt inferred as new")
        }
    }
    static func corruptPhase() throws {
        try fixture { root, location, parent in
            try H.refuses { _ = try attempt(root, cut: .afterReady) }
            let prefix = parent + "/.shadow-sync-initialization." + (try transaction(parent))
            try H.write(Data("{}".utf8), prefix + ".ready.json")
            try H.refuses { _ = try attempt(root) }
            try H.check(!FileManager.default.fileExists(atPath: location.path), "corrupt phase published state")
        }
    }
    static func missingCatalog() throws {
        try fixture { root, location, _ in
            _ = try attempt(root)
            try H.check(unlink(location.path + "/custody/catalog.json") == 0, "remove catalog fixture")
            try H.refuses { _ = try attempt(root) }
            try H.check(!FileManager.default.fileExists(atPath: location.path + "/custody/catalog.json"), "published catalog recreated")
        }
    }
    static func completedRootReplacement() throws {
        try fixture { root, location, _ in
            let initializer = try FreshStateInitialization.testing(root: root); _ = try initializer.publish()
            try H.check(rename(location.path, location.path + ".saved") == 0 && mkdir(location.path, 0o700) == 0, "replacement fixture")
            try H.refuses { _ = try initializer.publish() }
            try H.check(try FileManager.default.contentsOfDirectory(atPath: location.path).isEmpty, "replacement reset")
        }
    }
    static func establishedGuard(replace: Bool) throws {
        try fixture { root, location, parent in
            let original = try FreshStateInitialization.testing(root: root)
            original.testingFault(.afterReady)
            try H.refuses { _ = try original.publish() }
            let path = parent + "/.shadow-sync-initialization.lock"
            try H.check(rename(path, path + ".preserved") == 0, "preserve held initializer guard")
            if replace { try H.write(Data(), path) }
            try H.refuses { _ = try attempt(root) }
            try H.refuses { _ = try original.publish() }
            try H.check(!FileManager.default.fileExists(atPath: location.path), "changed initializer guard published")
            if !replace { try H.check(!FileManager.default.fileExists(atPath: path), "missing established guard recreated") }
            if replace { try H.check(unlink(path) == 0, "remove owned replacement fixture") }
            try H.check(rename(path + ".preserved", path) == 0, "restore exact original guard")
            _ = try original.publish()
        }
    }
    static func readyControls(replace: Bool) throws {
        for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock", "custody/catalog.lock", "custody/catalog.json"] {
            try fixture { root, location, parent in
                try H.refuses { _ = try attempt(root, cut: .afterReady) }
                let path = parent + "/.shadow-sync-initialization." + (try transaction(parent)) + "/" + name
                let original = try Data(contentsOf: URL(fileURLWithPath: path))
                try H.check(rename(path, path + ".preserved") == 0, "retain original ready control")
                if replace { try H.write(original, path) }
                // The preserved node is outside the active staged tree; avoid
                // passing only because the staged roster contains an extra file.
                try H.check(rename(path + ".preserved", parent + "/preserved-control") == 0, "move preserved fixture control")
                try H.refuses { _ = try attempt(root) }
                try H.check(!FileManager.default.fileExists(atPath: location.path), "changed ready control published")
                if !replace { try H.check(!FileManager.default.fileExists(atPath: path), "missing ready control recreated") }
                try H.check(try Data(contentsOf: URL(fileURLWithPath: parent + "/preserved-control")) == original, "original control changed")
            }
        }
    }
    static func badTemporary() throws {
        try fixture { root, location, parent in
            try H.refuses { _ = try attempt(root, cut: .partialWrite("catalog.json")) }
            let stage = parent + "/.shadow-sync-initialization." + (try transaction(parent))
            let temporary = stage + "/custody/.shadow-sync-initialization-write." + CustodyRecordBinding.digest(Data("catalog.json".utf8))
            try H.write(Data("unknown-prefix".utf8), temporary)
            try H.refuses { _ = try attempt(root) }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: temporary)) == Data("unknown-prefix".utf8), "invalid partial write overwritten")
            try H.check(!FileManager.default.fileExists(atPath: location.path), "invalid partial write published")
        }
    }
    static func writeRetry(partial: Bool) throws {
        for name in (partial ? [".shadow-sync-initialization.json", "catalog.json"] : [".shadow-sync-initialization.json", "operation.lock", "catalog.json"]) {
            try fixture { root, location, _ in
                try H.refuses { _ = try attempt(root, cut: partial ? .partialWrite(name) : .temporaryCreated(name)) }
                try H.check(!FileManager.default.fileExists(atPath: location.path), "partial write published")
                _ = try attempt(root)
                _ = try H.scope(location)
            }
        }
    }
    static func crashWorker(root: String, target: String, partial: String) -> Int32 {
        guard [".shadow-sync-initialization.json", "catalog.json"].contains(target), ["yes", "no"].contains(partial) else { return 64 }
        do {
            let initializer = try FreshStateInitialization.testing(root: root)
            initializer.testingCrash(partial == "yes" ? .partialWrite(target) : .temporaryCreated(target))
            _ = try initializer.publish(); return 65
        } catch { return 66 }
    }
    static func processDeath() throws {
        for target in [".shadow-sync-initialization.json", "catalog.json"] {
            for partial in ["yes", "no"] {
                try fixture { root, location, _ in
                    var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
                    try H.check(posix_spawn_file_actions_init(&actions) == 0 && posix_spawnattr_init(&attr) == 0, "initializer crash spawn setup")
                    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
                    let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
                    try H.check(posix_spawnattr_setflags(&attr, flags) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0, "initializer crash flags")
                    let executable = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()).executablePath
                    let strings = ([executable, "--shadow-sync-initialization-crash-fixture", root, target, partial] as [String]).map { strdup($0) }
                    defer { strings.forEach { free($0) } }
                    try H.check(strings.allSatisfy { $0 != nil }, "crash fixture argv")
                    var argv = strings + [nil], env: [UnsafeMutablePointer<CChar>?] = [nil]
                    let anchor = try argv.withUnsafeMutableBufferPointer { av in try env.withUnsafeMutableBufferPointer { ev in
                        try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: executable, actions: &actions, attributes: &attr, arguments: av.baseAddress, environment: ev.baseAddress, streamsDrained: { true })
                    } }
                    defer { RuntimeFixtureSession.drain(anchor) }
                    var owner: OwnedDirectChild?, failure: Error?
                    do {
                        owner = try anchor.transfer(expectedExecutable: executable, generation: RunIdentity.make())
                        try H.check(owner!.send(SIGCONT), "crash fixture resume")
                        try H.check(try owner!.wait(timeout: 4) == .reaped(94 << 8), "crash did not occur at exact write cut")
                    } catch { failure = error }
                    var clean = false
                    if let owner {
                        if owner.poll() == .running { _ = owner.send(SIGKILL) }
                        if case .reaped = try owner.wait(timeout: 4) { clean = true }
                    } else {
                        _ = anchor.killSuspended()
                        if case .reaped = try anchor.wait(timeout: 4) { clean = true }
                    }
                    var status: Int32 = 0
                    try H.check(clean && waitpid(anchor.processID, &status, WNOHANG) == -1 && errno == ECHILD, "crash child reaping")
                    if let failure { throw failure }
                    try H.check(!FileManager.default.fileExists(atPath: location.path), "crash published incomplete state")
                    _ = try attempt(root); _ = try H.scope(location)
                }
            }
        }
    }
    static func retry(_ cut: FreshStateInitialization.Fault) throws {
        try fixture { root, location, parent in
            try H.refuses { _ = try attempt(root, cut: cut) }
            let tx = try transaction(parent)
            var before = stat(); let exists = lstat(location.path, &before) == 0
            try H.check(exists == (cut == .afterPublication), "unexpected visibility before atomic publication")
            let result = try attempt(root)
            try H.check(result.transaction == tx && (!exists || result.stateInode == UInt64(before.st_ino)), "retry replaced transaction or state inode")
            try H.check(try CustodyCatalog.decode(H.bytes(location, "catalog.json")) == CustodyCatalog.initialized, "retry catalog mismatch")
            _ = try H.scope(location)
        }
    }
}

private enum CustodyResourcesSelfTests {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch is CustodyResourceError { return } catch is CustodyProtocolError { return }
        catch is CustodyRecordError { return } catch is SecureStateError { return }
        throw Failure(message: "custody resource unexpectedly accepted")
    }
    static func fixture(_ body: (StateLocation, CustodyMetadataScope, OwnedFileDescriptor) throws -> Void) throws {
        try CustodyCatalogSelfTests.fixture { location, _ in
            let scope = try CustodyCatalogSelfTests.scope(location)
            let cwd = try scope.leases.duplicateStateDirectory().0
            try body(location, scope, cwd)
        }
    }
    static func resources(_ scope: CustodyMetadataScope, _ cwd: OwnedFileDescriptor,
                          input: Data? = nil, code: Data? = nil) throws -> CustodyRequestResources {
        try CustodyRequestResources(scope: scope, kind: .discoveryGit,
            arguments: ["fixture-private-argument"], environment: ["FIXTURE_PRIVATE": "fixture-private-value"],
            budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: 10), stdoutLimit: 4096, stderrLimit: 4096,
            workingDirectory: cwd, input: input, code: code)
    }
    static func read(_ fd: Int32, limit: Int = 1_048_576) throws -> Data {
        var info = stat(); try check(fstat(fd, &info) == 0 && info.st_size <= limit, "sealed size")
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        try check(pread(fd, &bytes, bytes.count, 0) == bytes.count, "sealed read")
        return Data(bytes)
    }
    static func requestBinding() throws {
        try fixture { location, scope, cwd in
            let r = try resources(scope, cwd), fd = r.testingRequestDescriptor
            var info = stat(); try check(fstat(fd, &info) == 0 && fd > 200 && info.st_mode == S_IFREG | 0o400
                && info.st_nlink == 0 && fcntl(fd, F_GETFD) & FD_CLOEXEC != 0 && fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY, "request not sealed")
            let data = try read(fd)
            try check(try data == r.request.encode(), "sealed request mismatch")
            let decoded = try UnvalidatedCustodyRequest.decode(data, expected: r.request.binding, permittedWorkSeconds: 10)
            try check(decoded == r.request && decoded.descriptors.first { $0.role == .request }?.inode == UInt64(info.st_ino), "self-bound inode")
            let names = try FileManager.default.contentsOfDirectory(atPath: location.path)
            try check(!names.contains { $0.hasPrefix(".shadow-sync-custody-input-") }, "sealed name leaked")
        }
    }
    static func inputCode() throws {
        try fixture { _, scope, cwd in
            let input = Data("private-input".utf8), code = Data("private-code".utf8)
            let r = try resources(scope, cwd, input: input, code: code), mapping = try r.takeSpawnResources()
            try check(try read(mapping.testingDescriptor(8)!) == input && read(mapping.testingDescriptor(9)!) == code, "resource bytes")
            try check(r.request.inputSHA256 == CustodyRecordBinding.digest(input), "input binding")
            try check(r.request.descriptors.filter { [.input, .code].contains($0.role) }.allSatisfy { $0.links == 0 && $0.access == .read }, "resource claim")
            mapping.releaseChildCopies()
        }
    }
    static func resourceBounds() throws {
        try fixture { _, scope, cwd in
            try refuses { _ = try resources(scope, cwd, input: Data()) }
            try refuses { _ = try resources(scope, cwd, code: Data(repeating: 1, count: 262_145)) }
            try refuses { _ = try CustodySealedResource.bytes(Data([1]), role: .state, leases: scope.leases) }
            _ = try resources(scope, cwd, input: Data(repeating: 1, count: 262_144))
        }
    }
    static func immutableSnapshot() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), fd = r.testingRequestDescriptor
            var byte: UInt8 = 0
            try check(Darwin.write(fd, &byte, 1) == -1 && errno == EBADF, "request writable")
            try check(fchmod(fd, 0o600) == 0, "fixture mode change")
            try refuses { try r.validate() }
            try refuses { _ = try r.takeSpawnResources() }
        }
    }
    static func retainsCWD() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), before = r.testingWorkingDescriptor
            cwd.closeNow(); try r.validate()
            try check(fcntl(before, F_GETFD) & FD_CLOEXEC != 0, "cwd copy released with source")
        }
    }
    static func workingDirectoryRefusal() throws {
        try fixture { location, scope, cwd in
            try check(fchmod(cwd.value, 0o777) == 0, "unsafe cwd fixture")
            defer { _ = fchmod(cwd.value, 0o700) }
            try refuses { _ = try resources(scope, cwd) }
            try check(fchmod(cwd.value, 0o700) == 0, "restore cwd")
            let file = OwnedFileDescriptor(open(location.path + "/catalog-fixture", O_CREAT | O_RDONLY | O_CLOEXEC, 0o600))
            try refuses { _ = try resources(scope, file) }
        }
    }
    static func closedScope() throws {
        try fixture { _, scope, cwd in
            scope.close(); try refuses { _ = try resources(scope, cwd) }
        }
    }
    static func journalBinding() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd, input: Data("private-input".utf8)), ticket = try scope.prepare(r.request)
            let j = ticket.testingJournal
            try check(j.resourcesSHA256 == r.request.resourcesSHA256 && j.inputSHA256 == r.request.inputSHA256, "journal resources differ")
            let text = String(decoding: try j.encode(), as: UTF8.self)
            for privateValue in ["private-input", "fixture-private-argument", "fixture-private-value"] {
                try check(!text.contains(privateValue), "private resource in journal")
            }
        }
    }
    static func singleTransfer() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), mapping = try r.takeSpawnResources()
            try refuses { _ = try r.takeSpawnResources() }
            try check(mapping.testingSourceDescriptors.allSatisfy { $0 > 200 && fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }, "mapping collision/CLOEXEC")
            var actions: posix_spawn_file_actions_t?
            try check(posix_spawn_file_actions_init(&actions) == 0, "mapping actions")
            defer { posix_spawn_file_actions_destroy(&actions) }
            try mapping.appendActions(to: &actions)
            try refuses { try mapping.appendActions(to: &actions) }
            mapping.releaseChildCopies(); mapping.releaseChildCopies()
            try refuses { try mapping.appendActions(to: &actions) }
        }
    }
    static func pipeDrift() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), mapping = try r.takeSpawnResources(), fd = mapping.testingDescriptor(192)!
            try check(fcntl(fd, F_SETFD, 0) == 0, "pipe drift fixture")
            var actions: posix_spawn_file_actions_t?; try check(posix_spawn_file_actions_init(&actions) == 0, "mapping actions")
            defer { posix_spawn_file_actions_destroy(&actions) }
            try refuses { try mapping.appendActions(to: &actions) }; mapping.releaseChildCopies()
        }
    }
    static func livenessEOF() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), mapping = try r.takeSpawnResources(), fd = mapping.testingDescriptor(191)!
            let data = Data("cancel".utf8); try check(try r.writeControl(data) == data.count, "control write")
            var bytes = [UInt8](repeating: 0, count: 64)
            try check(Darwin.read(fd, &bytes, bytes.count) == data.count && Data(bytes.prefix(data.count)) == data, "control read")
            try check(Darwin.read(fd, &bytes, 1) == -1 && errno == EAGAIN, "control premature EOF")
            r.closeControl(); r.closeControl()
            try check(Darwin.read(fd, &bytes, 1) == 0, "caller liveness writer leaked")
            try refuses { _ = try r.writeControl(data) }; mapping.releaseChildCopies()
        }
    }
    static func outputEOF() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), mapping = try r.takeSpawnResources()
            try check(try r.readStatus() == .wouldBlock && r.readOutput() == .wouldBlock && r.readOutput(error: true) == .wouldBlock, "premature output EOF")
            mapping.releaseChildCopies()
            try check(try r.readStatus() == .end && r.readOutput() == .end && r.readOutput(error: true) == .end, "helper writer copy leaked")
        }
    }
    static func backpressure() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), mapping = try r.takeSpawnResources(), fd = mapping.testingDescriptor(191)!
            let data = Data(repeating: 42, count: 16_388); var written = 0, blocked = false
            for _ in 0..<64 {
                let n = try r.writeControl(data); written += n
                if n == 0 { blocked = true; break }
            }
            try check(blocked && written > 0, "control failed to bound backpressure")
            r.closeControl(); var readCount = 0, buffer = [UInt8](repeating: 0, count: 4096)
            while readCount <= written {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n == 0 { break }; try check(n > 0, "control drain failed"); readCount += n
            }
            try check(readCount == written, "control lost bytes"); mapping.releaseChildCopies()
        }
    }
    static func brokenPeer() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), mapping = try r.takeSpawnResources(); mapping.releaseChildCopies()
            do { _ = try r.writeControl(Data([1])); throw Failure(message: "closed peer accepted") }
            catch CustodyResourceError.systemCall(let code) { try check(code == EPIPE, "wrong peer error") }
        }
    }
    static func scopeRetention() throws {
        try fixture { _, scope, cwd in
            var r: CustodyRequestResources? = try resources(scope, cwd)
            weak var weakResource = r
            var mapping: CustodySpawnResources? = try r!.takeSpawnResources()
            r = nil; try check(weakResource != nil, "mapping dropped resource owner")
            mapping!.releaseChildCopies(); mapping = nil
            try check(weakResource == nil, "resource owner cycle")
        }
    }
    static func requestPosition() throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd), fd = r.testingRequestDescriptor
            try check(lseek(fd, 1, SEEK_SET) == 1, "request offset fixture")
            try r.validate(); try check(lseek(fd, 0, SEEK_CUR) == 1, "validation changed request cursor")
        }
    }
    static func child(_ arguments: [String]) -> Int32 {
        guard arguments.count == 3, getpgrp() == getpid(), getuid() == geteuid() else { return 80 }
        let absent = arguments[2].split(separator: ",").compactMap { Int32($0) }
        guard !absent.isEmpty, absent.count <= 64, absent.allSatisfy({ $0 > 200 }) else { return 80 }
        for fd: Int32 in [8, 190, 191, 192, 193, 194, 197, 198, 200] {
            guard fcntl(fd, F_GETFD) >= 0 else { return 81 }
        }
        for fd in absent + [188] {
            guard fcntl(fd, F_GETFD) == -1, errno == EBADF else { return 82 }
        }
        var actual = stat(), expected = stat()
        guard stat(".", &actual) == 0, fstat(200, &expected) == 0,
              actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else { return 85 }
        let ready = Array("ready".utf8)
        guard ready.withUnsafeBytes({ Darwin.write(192, $0.baseAddress, $0.count) }) == ready.count else { return 86 }
        var bytes = [UInt8](repeating: 0, count: 8)
        guard Darwin.read(191, &bytes, bytes.count) == 8, Data(bytes) == Data("fixture\n".utf8) else { return 83 }
        // Precisely zero, not EAGAIN or any other read error, proves EOF.
        guard Darwin.read(191, &bytes, 1) == 0 else { return 84 }
        let output = Array("inherited-ok".utf8)
        guard output.withUnsafeBytes({ Darwin.write(1, $0.baseAddress, $0.count) }) == output.count else { return 86 }
        return 0
    }
    private final class NativeStreamDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var ended: Set<Int> = []
        func end(_ channel: Int) { lock.lock(); ended.insert(channel); lock.unlock() }
        var complete: Bool { lock.lock(); defer { lock.unlock() }; return ended == Set([0, 1, 2]) }
    }
    static func nativeAdmissionFailure(afterTransfer: Bool) throws {
        do {
            try nativeInheritance(injectedFailure: afterTransfer ? 2 : 1)
            throw Failure(message: "native admission fault did not execute")
        } catch CustodyRecordError.injectedFailure {}
    }
    static func nativeInheritance(leakWriter: Bool = false, extraDescriptor: Bool = false,
                                  injectedFailure: Int = 0) throws {
        try fixture { _, scope, cwd in
            let r = try resources(scope, cwd, input: Data("fixture".utf8)), mapping = try r.takeSpawnResources()
            var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
            try check(posix_spawn_file_actions_init(&actions) == 0 && posix_spawnattr_init(&attr) == 0, "native fixture setup")
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr); mapping.releaseChildCopies() }
            if leakWriter { try check(posix_spawn_file_actions_adddup2(&actions, r.testingControlWriterDescriptor, 189) == 0, "writer negative fixture") }
            if extraDescriptor { try check(posix_spawn_file_actions_adddup2(&actions, r.testingRequestDescriptor, 188) == 0, "extra descriptor negative fixture") }
            try mapping.appendActions(to: &actions)
            let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
            try check(posix_spawnattr_setflags(&attr, flags) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0, "native fixture flags")
            let executable = try ProcessIdentity.capture(processID: getpid(), generation: UUID().uuidString.lowercased()).executablePath
            let absent = mapping.testingSourceDescriptors.map(String.init).joined(separator: ",")
            let strings = ([executable, "--shadow-sync-custody-resource-fixture", absent] as [String]).map { strdup($0) }; defer { strings.forEach { free($0) } }
            try check(strings.allSatisfy { $0 != nil }, "native fixture allocation")
            var argv = strings + [nil], env: [UnsafeMutablePointer<CChar>?] = [nil]
            let drained = NativeStreamDrain()
            let anchor = try argv.withUnsafeMutableBufferPointer { av in
                try env.withUnsafeMutableBufferPointer { ev in
                    try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: executable, actions: &actions, attributes: &attr, arguments: av.baseAddress, environment: ev.baseAddress, streamsDrained: { drained.complete })
                }
            }
            // This fixed native descriptor probe has bounded output and no
            // descendants. On unwind close control, drain actual channels, then
            // retain its original owner through terminal reap before releasing r.
            defer {
                r.closeControl(); mapping.releaseChildCopies()
                anchor.testingRequestRuntimeDrain()
                var reported = false; let diagnostic = MonotonicDeadline(seconds: 6)
                while !drained.complete {
                    do {
                        if case .end = try r.readStatus() { drained.end(0) }
                        if case .end = try r.readOutput() { drained.end(1) }
                        if case .end = try r.readOutput(error: true) { drained.end(2) }
                    } catch {
                        // An I/O error is not EOF. Retain the original resource
                        // owner; never publish a successful cleanup from it.
                    }
                    if diagnostic.hasExpired && !reported {
                        fputs("M6 NATIVE STREAM CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
                    }
                    if !drained.complete { usleep(5_000) }
                }
                RuntimeFixtureSession.drain(anchor)
            }
            var owner: OwnedDirectChild?, failure: Error?
            do {
                if injectedFailure == 1 { throw CustodyRecordError.injectedFailure }
                owner = try anchor.transfer(expectedExecutable: executable, generation: UUID().uuidString.lowercased())
                if injectedFailure == 2 { throw CustodyRecordError.injectedFailure }
                mapping.releaseChildCopies()
                // Queue bytes before resume: this descendant-free native fixture
                // must not race a nonblocking read against the parent writer.
                try check(try r.writeControl(Data("fixture\n".utf8)) == 8, "native control write")
                r.closeControl()
                try check(owner!.send(SIGCONT), "native fixture resume")
                let observed = try owner!.wait(timeout: 3)
                let expectedStatus: Int32 = extraDescriptor ? 82 << 8 : (leakWriter ? 84 << 8 : 0)
                try check(observed == .reaped(expectedStatus), "native child failed or missed inherited descriptor")
                var status = Data(), output = Data()
                drainStatus: while status.count <= 4096 {
                    switch try r.readStatus() {
                    case .bytes(let bytes): status.append(bytes)
                    case .end: drained.end(0); break drainStatus
                    case .wouldBlock: throw Failure(message: "status not drained")
                    }
                }
                drainOutput: while output.count <= 4096 {
                    switch try r.readOutput() {
                    case .bytes(let bytes): output.append(bytes)
                    case .end: drained.end(1); break drainOutput
                    case .wouldBlock: throw Failure(message: "output not drained")
                    }
                }
                try check(status == (extraDescriptor ? Data() : Data("ready".utf8)), "native inherited mapping")
                try check(output == (leakWriter || extraDescriptor ? Data() : Data("inherited-ok".utf8)), "native output")
            } catch { failure = error }
            r.closeControl()
            var clean = false
            if let owner {
                if owner.poll() == .running { _ = owner.send(SIGKILL) }
                if case .reaped = try owner.wait(timeout: 3) { clean = true }
            } else {
                _ = anchor.killSuspended()
                if case .reaped = try anchor.wait(timeout: 3) { clean = true }
            }
            var raw: Int32 = 0
            try check(clean && waitpid(anchor.processID, &raw, WNOHANG) == -1 && errno == ECHILD,
                      "native resource fixture cleanup unverified")
            if let failure { throw failure }
        }
    }
    static func nativeCollisions() throws {
        let original = OwnedFileDescriptor(open("/dev/null", O_RDONLY | O_CLOEXEC))
        try check(original.value >= 0, "collision source")
        var held: [OwnedFileDescriptor] = []
        defer { held.forEach { $0.closeNow() } }
        for _ in 0..<12 {
            let next = OwnedFileDescriptor(try original.duplicate(minimum: 190))
            if next.value > 200 { next.closeNow(); break }
            held.append(next)
        }
        try check(!held.isEmpty, "no destination collision exercised")
        try nativeInheritance()
        try check(held.allSatisfy { fcntl($0.value, F_GETFD) >= 0 }, "child mapping changed parent")
    }

    static func descriptorSet() throws -> Set<Int32> {
        let required = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        try check(required > 0 && required < 65_536, "descriptor inventory bound")
        var rows = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / MemoryLayout<proc_fdinfo>.stride + 64)
        let capacity = rows.count * MemoryLayout<proc_fdinfo>.stride
        let count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &rows, Int32(capacity))
        try check(count > 0 && count < capacity && Int(count) % MemoryLayout<proc_fdinfo>.stride == 0, "descriptor inventory incomplete")
        return Set(rows.prefix(Int(count) / MemoryLayout<proc_fdinfo>.stride).map { $0.proc_fd })
    }
    static func partialConstruction() throws {
        try fixture { location, scope, cwd in
            // Warm the synchronous factory and thread dictionary before snapshots.
            try autoreleasepool { _ = try resources(scope, cwd, input: Data([1])) }
            for point in CustodyResourceTesting.Point.allCases {
                try CustodyResourceTesting.withFault(point) {
                    let before = try descriptorSet()
                    let names = try FileManager.default.contentsOfDirectory(atPath: location.path).sorted()
                    try autoreleasepool {
                        do {
                            _ = try resources(scope, cwd, input: Data([1]))
                            throw Failure(message: "construction fault not exercised")
                        } catch CustodyResourceError.systemCall(let code) { try check(code == EIO, "wrong construction failure") }
                    }
                    try check(try descriptorSet() == before, "partial construction leaked descriptor")
                    try check(try FileManager.default.contentsOfDirectory(atPath: location.path).sorted() == names, "partial construction leaked name")
                    try scope.leases.validate()
                }
            }
            _ = try resources(scope, cwd)
        }
    }

}


private enum CustodyRegistrySelfTests {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func until(_ body: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 5)
        while !(try body()) { if deadline.hasExpired { throw Failure(message: "registry fixture convergence timeout") }; usleep(5_000) }
    }
    static func fixture(_ body: (StateLocation, RetainedCleanupRegistry) throws -> Void) throws {
        var pattern = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-registry.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&pattern) else { throw Failure(message: "registry fixture creation") }
        let root = String(cString: raw), registry = RetainedCleanupRegistry.testingInstance()
        var original = stat(); try check(lstat(root, &original) == 0, "registry fixture identity")
        var failure: Error?
        do {
            let location = try StateLocation.isolated(root: root)
            try TestIsolation.initializeState(at: location)
            let owner = try RunAuthority.acquireRun(at: location)
            do { try CustodyCatalogStore.testingInitialize(leases: owner.retainCommandLeases(), root: root) }
            catch { owner.release(); throw error }
            owner.release()
            try body(location, registry)
        } catch { failure = error }
        registry.testingRequestCancellation()
        let diagnostic = MonotonicDeadline(seconds: 5)
        var reported = false
        while true {
            do { try registry.testingDispose(); break }
            catch {
                if diagnostic.hasExpired && !reported {
                    fputs("M6 REGISTRY CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
                }
                usleep(5_000)
            }
        }
        var current = stat()
        try check(lstat(root, &current) == 0 && original.st_dev == current.st_dev && original.st_ino == current.st_ino,
                  "registry fixture root identity changed; retained")
        try FileManager.default.removeItem(atPath: root)
        if let failure { throw failure }
    }
    static func make(_ scope: CustodyMetadataScope, mode: String, work: TimeInterval = 2, receipt: TimeInterval = 0.2, output: UInt64 = 4096) throws -> CustodyRequestResources {
        try CustodyRequestResources(scope: scope, kind: .discoveryGit, arguments: [mode], environment: [:],
            budget: CustodyBudget.make(kind: .discoveryGit, workSeconds: work, termSeconds: 0, killSeconds: 0, receiptSeconds: receipt),
            stdoutLimit: output, stderrLimit: output, workingDirectory: scope.leases.duplicateStateDirectory().0)
    }
    static func native(_ mode: String, pending: Bool = false, cancel: Bool = false, eof: Bool = false) throws {
        try fixture { location, registry in
            var scope: CustodyMetadataScope? = try CustodyCatalogSelfTests.scope(location)
            var resources: CustodyRequestResources? = try make(scope!, mode: mode)
            weak var retainedResources = resources
            weak var retainedScope = scope
            let id = resources!.request.binding.requestID
            let workDeadline = resources!.request.budget.work
            let handle = try registry.start(resources: resources!, helper: CustodyHelperExecutable.testing(releaseSHA256: scope!.releaseSHA256))
            resources = nil; scope = nil
            if mode == "early-cancel" { handle.cancel() }
            if cancel || eof || mode == "delayed-exit" {
                try until { handle.snapshot().phase == .ready }
                try check(retainedResources != nil && retainedScope != nil && registry.testingCount == 1, "registry lost live authority")
                if cancel { handle.cancel() }
                if eof { registry.testingCloseControl(handle) }
            }
            if mode == "delayed-exit" {
                try until { FileManager.default.fileExists(atPath: location.path + "/custody/" + id + ".json") &&
                    (try? CustodyJournal.decode(CustodyCatalogSelfTests.bytes(location, id + ".json")))?.phase == .terminal }
                try check(handle.snapshot().phase != .finished && registry.testingPoll(handle) == .running,
                    "terminal receipt released an unreaped helper")
            }
            if pending {
                try until {
                    if case .reaped = registry.testingPoll(handle) { return handle.snapshot().phase == .cleanupPending }
                    return false
                }
                try check(handle.snapshot().phase == .cleanupPending && registry.testingCount == 1 && retainedResources != nil && retainedScope != nil,
                    "unverified exit released registry authority")
                try check(!FileManager.default.fileExists(atPath: location.path + "/custody/receipts/" + id + ".caller.json"), "invalid terminal was archived")
                if mode == "status-eof" {
                    guard case .reaped(0)? = registry.testingPoll(handle),
                          let observed = registry.testingReadObservation(handle) else { throw Failure(message:"missing-terminal original was not reaped") }
                    try check(observed.statusEOF && !observed.terminalReceived
                        && handle.snapshot().reason == .protocolFault && handle.snapshot().journal == nil,
                              "EOF without terminal was not a genuine protocol fault")
                    try check(DispatchTime.now().uptimeNanoseconds < workDeadline,
                              "missing terminal was detected only by timeout")
                }
                if mode == "malformed" { try check(handle.snapshot().stdout.count == 4096, "poisoned status starved bounded output drainage") }
                try registry.testingDispose()
            } else {
                try until { handle.snapshot().phase == .finished }
                try check(registry.testingCount == 0 && handle.snapshot().journal?.outcome == .admissionRefused,
                    "fixture refusal did not retire")
                try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location, "catalog.json")).entries.isEmpty,
                    "retired transaction remains expected")
                let observation = try CustodyCatalogSelfTests.bytes(location, "receipts/" + id + ".caller.json")
                let object = try JSONSerialization.jsonObject(with: observation) as! [String: Any]
                try check(object["event"] as? String == "custodian-reaped" && object["wait_status"] as? Int == 0,
                    "caller receipt did not bind actual helper reaping")
                try check(!FileManager.default.fileExists(atPath: location.path + "/custody/" + id + ".json"), "active terminal not retired")
                try until { retainedResources == nil && retainedScope == nil }
                // Retaining the result handle cannot retain authority after completion.
                let mutation = try RunAuthority.acquireLifecycleMutation(at: location); mutation.release()
                handle.cancel(); try check(handle.snapshot().phase == .finished, "completed handle changed")
            }
        }
    }
    static func bootstrap(_ cut: RetainedCleanupRegistry.TestCut) throws {
        try fixture { location, registry in
            let scope = try CustodyCatalogSelfTests.scope(location), resources = try make(scope, mode: "refuse")
            registry.testingFault(cut)
            let h = try registry.start(resources: resources, helper: CustodyHelperExecutable.testing(releaseSHA256: scope.releaseSHA256))
            try until { h.snapshot().phase == .finished }
            let bytes = try CustodyCatalogSelfTests.bytes(location, "receipts/" + resources.request.binding.requestID + ".caller.json")
            let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            try check(object["event"] as? String == (cut == .beforeSpawn ? "no-successful-spawn" : "never-resumed-reaped"), "bootstrap proof mismatch")
            try check(registry.testingCount == 0 && h.snapshot().journal?.reason == .startFailure, "bootstrap not safely retired")
        }
    }
    static func closedScope() throws {
        try fixture { location, registry in
            let scope = try CustodyCatalogSelfTests.scope(location), resources = try make(scope, mode: "refuse")
            scope.close()
            let h = try registry.start(resources: resources, helper: CustodyHelperExecutable.testing(releaseSHA256: scope.releaseSHA256))
            try until { h.snapshot().phase == .finished }
            try check(h.snapshot().reason == .invalidResource && h.snapshot().journal == nil, "closed scope accepted")
            try check(registry.testingCount == 0 && (try scope.testingRead()).entries.isEmpty, "rejected start changed registry/catalog")
        }
    }
    static func lostHandle() throws {
        try fixture { location, registry in
            var scope: CustodyMetadataScope? = try CustodyCatalogSelfTests.scope(location)
            var resources: CustodyRequestResources? = try make(scope!, mode: "refuse")
            weak var retained = resources
            _ = try registry.start(resources: resources!, helper: CustodyHelperExecutable.testing(releaseSHA256: scope!.releaseSHA256))
            resources = nil; scope = nil
            try until { registry.testingCount == 0 }
            try until { retained == nil }
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location, "catalog.json")).entries.isEmpty, "lost handle forgot cleanup")
        }
    }
    static func boundedWait() throws {
        try fixture { location, registry in
            let scope = try CustodyCatalogSelfTests.scope(location)
            let resources = try make(scope, mode: "late-exit", work: 0.1, receipt: 0.01)
            let h = try registry.start(resources: resources, helper: CustodyHelperExecutable.testing(releaseSHA256: scope.releaseSHA256))
            try until { h.snapshot().phase == .ready }
            registry.testingDelayQueue()
            let start = DispatchTime.now().uptimeNanoseconds
            let response = h.wait()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            try check(response.phase == .cleanupPending && elapsed < 1_200_000_000,
                      "response deadline blocked on registry queue")
            try until { h.snapshot().phase == .finished }
            try check(h.snapshot().journal?.outcome == .admissionRefused && registry.testingCount == 0,
                      "deadline killed or lost resumed helper")
        }
    }
    static func queuedStartDeadline() throws {
        try fixture { location, registry in
            let scope = try CustodyCatalogSelfTests.scope(location)
            let resources = try make(scope, mode: "refuse", work: 0.1, receipt: 0.01)
            let helper = try CustodyHelperExecutable.testing(releaseSHA256: scope.releaseSHA256)
            registry.testingDelayQueue()
            let start = DispatchTime.now().uptimeNanoseconds
            let h = try registry.start(resources: resources, helper: helper)
            try check(DispatchTime.now().uptimeNanoseconds - start < 300_000_000, "start blocked on ownership queue")
            let result = h.wait()
            try check(result.phase == .cleanupPending && DispatchTime.now().uptimeNanoseconds - start < 1_200_000_000,
                      "queued start lost its original deadline")
            try until { h.snapshot().phase == .finished }
            try check(h.snapshot().reason == .invalidResource && h.snapshot().journal == nil
                && registry.testingCount == 0 && (try scope.testingRead()).entries.isEmpty,
                      "expired queued start spawned or persisted a transaction")
        }
    }
    static func outputReservation() throws {
        try fixture { location, registry in
            let scope = try CustodyCatalogSelfTests.scope(location)
            let first = try make(scope, mode: "cancel", output: 33_554_432)
            let helper = try CustodyHelperExecutable.testing(releaseSHA256: scope.releaseSHA256)
            let h = try registry.start(resources: first, helper: helper)
            try until { h.snapshot().phase == .ready }
            let second = try make(scope, mode: "refuse")
            do { _ = try registry.start(resources: second, helper: helper); throw Failure(message: "unbounded registry output reservation") }
            catch CustodyRecordError.fenced {}
            try check(registry.testingCount == 1 && (try scope.testingRead()).entries.count == 1,
                      "capacity refusal spawned or reserved metadata")
            h.cancel(); try until { h.snapshot().phase == .finished }
        }
    }
    static func send(_ bytes: Data, fd: Int32) throws {
        let deadline = MonotonicDeadline(seconds: 3)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count-offset) }
            if n > 0 { offset += n }
            else if n < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) && !deadline.hasExpired { usleep(1_000) }
            else { throw Failure(message: "fixture pipe write") }
        }
    }
    /// Fixed native fixture only; no target commands, shell, real policy or
    /// production helper-writer qualification is represented by this route.
    static func child(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2 else { return 90 }
        do {
            let bytes = try CustodyResourcesSelfTests.read(190)
            let object = try CustodyWire.decode(bytes, maximum: 1_048_576).object(keys: ["schema","binding","command","budget","limits","descriptors"])
            let v = try CustodyWire.required(object["binding"]).object(keys: ["request", "scope", "nonce", "generation", "uid", "boot", "release"])
            guard let uid = UInt32(exactly: try CustodyWire.uint(v["uid"])) else { return 99 }
            let binding = CustodyBinding(requestID: try CustodyWire.text(v["request"]), scopeID: try CustodyWire.text(v["scope"]),
                nonce: try CustodyWire.text(v["nonce"]), callerGeneration: try CustodyWire.text(v["generation"]),
                trustedUID: uid, bootID: try CustodyWire.text(v["boot"]), releaseSHA256: try CustodyWire.text(v["release"]))
            let request = try UnvalidatedCustodyRequest.decode(bytes, expected: binding, permittedWorkSeconds: 2,
                permittedTermSeconds: 0, permittedKillSeconds: 0, permittedReceiptSeconds: 0.2)
            guard request.arguments.count == 1, let mode = request.arguments.first,
                  ["refuse","cancel","eof","delayed-exit","missing","wrong-digest","wrong-owner","crash","malformed","late-exit","early-cancel","terminal-overflow","terminal-error-exit","status-eof"].contains(mode) else { return 91 }
            if mode == "crash" { return 77 }
            let ready = CustodyMessage(binding: binding, sequence: 0, event: .ready, outcome: nil, waitStatus: nil, receiptSHA256: nil)
            if mode == "malformed" {
                try send(Data([0,0,0,0]), fd: 192)
                try send(Data(repeating: 120, count: 131_072), fd: STDOUT_FILENO)
                return 0
            }
            if mode != "early-cancel" { try send(CustodyFrameDecoder.frame(ready.encode()), fd: 192) }
            if mode == "status-eof" { return 0 }
            if mode == "cancel" || mode == "eof" || mode == "early-cancel" {
                var buffer = [UInt8](repeating: 0, count: 16_388), decoder = CustodyFrameDecoder()
                let deadline = MonotonicDeadline(seconds: 3)
                var done = false
                while !done && !deadline.hasExpired {
                    let n = Darwin.read(191, &buffer, buffer.count)
                    if n == 0 { done = true }
                    else if n > 0 {
                        for data in try decoder.append(Data(buffer.prefix(n))) {
                            let message = try CustodyMessage.decode(data, expected: binding, channel: .control)
                            guard message.event == .cancel else { return 92 }; done = true
                        }
                    } else if ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) { return 93 }
                    if !done { usleep(1_000) }
                }
                guard done else { return 94 }
            }
            if mode == "early-cancel" { try send(CustodyFrameDecoder.frame(ready.encode()), fd: 192) }
            let name = "custody/" + binding.requestID + ".json"
            let reader = openat(193, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); guard reader >= 0 else { return 95 }; defer { close(reader) }
            let prepared = try CustodyJournal.decode(CustodyResourcesSelfTests.read(reader, limit: 32_768))
            let identity = try ProcessIdentity.capture(processID: getpid(), generation: mode == "wrong-owner" ? UUID().uuidString.lowercased() : binding.callerGeneration)
            let terminal = try prepared.advancing(to: .terminal, custodian: CustodyProcessObservation(identity), outcome: .admissionRefused,
                reason: mode == "cancel" || mode == "eof" ? .cancelled : .invalidResource)
            let terminalBytes = try terminal.encode()
            if mode != "missing" {
                // Explicit fixture writer, not a production metadata-transfer API.
                // This fixture never creates a target or frozen resource. Its
                // mandatory planned record must nevertheless be retired before
                // publishing the synthetic terminal journal.
                let resourceName = "custody/receipts/discovery-resource-" + binding.requestID + ".json"
                let resourceReader = openat(193, resourceName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard resourceReader >= 0 else { return 95 }
                let planned: DiscoveryResourceReceipt
                do { planned = try DiscoveryResourceReceipt.decode(CustodyResourcesSelfTests.read(resourceReader, limit: DiscoveryResourceReceipt.maximumBytes)) }
                catch { close(resourceReader); throw error }
                close(resourceReader)
                guard planned.binding == prepared.binding, planned.phase == .planned else { return 95 }
                let retired = try planned.advancing(to: .retired).encode()
                let resourceWriter = openat(193, resourceName, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
                guard resourceWriter >= 0 else { return 96 }
                do { try send(retired, fd: resourceWriter) }
                catch { close(resourceWriter); throw error }
                guard fsync(resourceWriter) == 0 else { close(resourceWriter); return 97 }
                close(resourceWriter)
                let writer = openat(193, name, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC); guard writer >= 0 else { return 96 }
                try send(terminalBytes, fd: writer); guard fsync(writer) == 0 else { close(writer); return 97 }; close(writer)
            }
            let terminalMessage = CustodyMessage(binding: binding, sequence: 1, event: .terminal, outcome: .refused,
                waitStatus: nil, receiptSHA256: mode == "wrong-digest" ? String(repeating: "f", count: 64) : CustodyRecordBinding.digest(terminalBytes))
            try send(CustodyFrameDecoder.frame(terminalMessage.encode()), fd: 192)
            if mode == "terminal-overflow" { try send(Data(repeating: 120, count: 131_072), fd: STDOUT_FILENO) }
            if mode == "terminal-error-exit" { return 77 }
            if mode == "delayed-exit" { usleep(500_000) }
            if mode == "late-exit" { usleep(2_000_000) }
            return 0
        } catch { return 98 }
    }
}

private enum CustodyContextSelfTests {
    struct Failure: Error { let message: String }
    static func check(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(message: message) } }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() }
        catch is CustodyRecordError { return }
        catch is CustodyProtocolError { return }
        catch is SecureStateError { return }
        catch is PublisherPolicyError { return }
        throw Failure(message: "context unexpectedly accepted")
    }
    static func read(_ location: StateLocation) throws -> CommandCustodyContext {
        try CommandCustodyContext.testing(leases: CustodyAuthorityLeaseSet.retainReadLeases(at: location),
            location: location, root: location.anchorPath)
    }
    static func unsignedFactory() throws {
        // Test isolation denies real HOME reads; the unbundled executable must
        // refuse publisher bootstrap before trying to open production state.
        try refuses { _ = try CommandCustodyContext.read() }
        try refuses { _ = try CommandCustodyContext.observation() }
    }
    static func readScopes() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            var first: CommandCustodyContext? = try read(location)
            var second: CommandCustodyContext? = try read(location)
            try check(first!.id != second!.id && first!.mode == .read && second!.mode == .read, "scope identity/mode")
            try refuses { _ = try RunAuthority.acquireRun(at: location) }
            first!.close(); try check(first!.isClosed, "phase admission did not close")
            try refuses { _ = try first!.prepare(.serviceStatus) }
            first = nil
            try refuses { _ = try RunAuthority.acquireRun(at: location) }
            second!.close(); second = nil
            let fresh = try RunAuthority.acquireRun(at: location); fresh.release()
        }
    }
    private enum PhaseProbe: Error { case stopped }
    private final class AdmissionCounter: @unchecked Sendable {
        private let mutex = NSLock()
        private var count = 0
        func reached() throws {
            mutex.lock(); count += 1; mutex.unlock()
            throw PhaseProbe.stopped
        }
        var value: Int { mutex.lock(); defer { mutex.unlock() }; return count }
    }
    static func phaseReturn() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            weak var observed: CommandCustodyContext?
            let value = try CommandCustodyContext.withTestingReadPhase(at: location, root: location.anchorPath) { context in
                observed = context
                try context.validatePhaseAdmission()
                try refuses { _ = try RunAuthority.acquireRun(at: location) }
                return 73
            }
            try check(value == 73 && observed == nil, "returned read phase retained its lease owner")
            let mutation = try RunAuthority.acquireRun(at: location); mutation.release()
        }
    }
    static func phaseThrow() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            weak var observed: CommandCustodyContext?
            do {
                try CommandCustodyContext.withTestingReadPhase(at: location, root: location.anchorPath) { context in
                    observed = context
                    try context.validatePhaseAdmission()
                    try refuses { _ = try RunAuthority.acquireRun(at: location) }
                    throw PhaseProbe.stopped
                }
                throw Failure(message: "phase body error did not propagate")
            } catch PhaseProbe.stopped {}
            try check(observed == nil, "throwing read phase retained its lease owner")
            let mutation = try RunAuthority.acquireRun(at: location); mutation.release()
        }
    }
    static func escapedBinder() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let counter = AdmissionCounter()
            let binder = try CommandCustodyContext.withTestingReadPhase(at: location, root: location.anchorPath) { context in
                let binder = SelectedRepositoryScopeBinder(
                    governedRootPath: location.anchorPath + "/home", logicalRoot: "~",
                    admission: RepositorySelectionPathAdmission(evaluate: { _, _ in throw PhaseProbe.stopped },
                        revalidate: { try counter.reached() }),
                    revalidatePhase: context.phaseAdmissionCheck())
                do {
                    _ = try binder.processFreeCatalog(preferences: nil, generation: 1)
                    throw Failure(message: "fixture admission did not stop catalog")
                } catch SelectedRepositoryScopeError.policyUnavailable {}
                try check(counter.value == 1, "live phase did not reach its admission check")
                return binder
            }
            do {
                _ = try binder.processFreeCatalog(preferences: nil, generation: 2)
                throw Failure(message: "escaped binder accepted expired authority")
            } catch CustodyRecordError.fenced {}
            try check(counter.value == 1, "escaped binder reached policy/candidate admission")
            // The still-retained binder must not retain the old SH lease. A new
            // EX acquisition is fresh authority, not an upgrade or transferred check.
            let mutation = try RunAuthority.acquireRun(at: location); mutation.release()
            withExtendedLifetime(binder) {}
        }
    }
    static func borrowedPhase() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let owner = try RunAuthority.acquireRun(at: location)
            defer { owner.release() }
            let checkPhase = try CommandCustodyContext.withPhase(
                CommandCustodyContext.testing(leases: owner.retainCommandLeases(), location: location,
                    root: location.anchorPath, authority: owner)) { context in
                try context.validatePhaseAdmission()
                try check(context.mode == .mutation, "borrowed phase lost EX authority")
                try refuses { _ = try CustodyAuthorityLeaseSet.retainReadLeases(at: location) }
                return context.phaseAdmissionCheck()
            }
            do { try checkPhase(); throw Failure(message: "expired borrowed phase admitted work") }
            catch CustodyRecordError.fenced {}
            try check(owner.commandAdmissionIsOpen, "closing borrowed phase retired source authority")
            try refuses { _ = try RunAuthority.acquireRun(at: location) }
            owner.release()
            let mutation = try RunAuthority.acquireRun(at: location); mutation.release()
        }
    }
    static func cancelledValidation(queued: Bool) throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try read(location), token = CancellationToken()
            let command = try context.prepare(.serviceStatus, cancellation: token)
            let before = try CustodyCatalogSelfTests.bytes(location, "catalog.json")
            if queued { registry.testingDelayQueue() } else { command.testingCancelDuringValidation(token) }
            let handle = try registry.start(command)
            if queued { try check(registry.hasRetainedWork, "queued authority omitted from drain accounting"); token.cancel() }
            // The terminal snapshot is published before the reservation retires.
            // Wait for both observations; neither alone proves released custody.
            try CustodyRegistrySelfTests.until { handle.snapshot().phase == .finished && !registry.hasRetainedWork }
            try check(token.isCancelled && command.admissionClosed && handle.snapshot().journal == nil,
                      "cancelled final validation reached metadata or spawn")
            try check(!registry.hasRetainedWork && registry.testingCount == 0
                && (try CustodyCatalogSelfTests.bytes(location, "catalog.json")) == before,
                "cancelled preparation lost cleanup or created metadata")
        }
    }
    static func closedDiagnostics() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let context = try read(location)
            let before = try CustodyCatalogSelfTests.bytes(location, "catalog.json")
            let a = try context.prepare(.serviceStatus), b = try context.prepare(.installedSignature)
            try check(a.resources.request.kind == .launchctlRead && a.resources.request.arguments == ["print", "gui/\(geteuid())/\(InstallationPaths.label)"], "unbound service diagnostic")
            try check(b.resources.request.kind == .signatureCheck && b.resources.request.arguments == ["--verify", "--strict", "--verbose=2", location.anchorPath + "/home/Applications/ShadowSync.app"], "unbound signature diagnostic")
            try check(a.resources.request.stdoutLimit == 65_536 && a.resources.request.stderrLimit == 65_536,
                      "diagnostic output ceiling changed")
            try check(a.resources.request.environment["HOME"] == location.anchorPath + "/home", "fixture inherited real home")
            try check(try CustodyCatalogSelfTests.bytes(location, "catalog.json") == before, "preparation reserved a journal")
            let files = try FileManager.default.contentsOfDirectory(atPath: location.path)
            try check(!files.contains(where: { $0.hasPrefix(".shadow-sync-custody-input-") }), "preparation left private temporary bytes")
        }
    }
    static func fixedRoot() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let prepared = try read(location).prepare(.serviceStatus)
            let claim = prepared.resources.request.descriptors.first { $0.role == .workingDirectory }
            var root = stat(); try check(lstat("/", &root) == 0, "root observation")
            try check(claim?.device == UInt64(root.st_dev) && claim?.inode == UInt64(root.st_ino) && claim?.uid == 0,
                      "diagnostic cwd was not the actual system root")
            try prepared.resources.validate()
        }
    }
    static func borrowedRun() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let owner = try RunAuthority.acquireRun(at: location)
            var context: CommandCustodyContext? = try CommandCustodyContext.testing(leases: owner.retainCommandLeases(),
                location: location, root: location.anchorPath, authority: owner)
            let claims = try context!.testingScope.leases.descriptorClaims()
            try check(context!.mode == .mutation && Set(claims.map(\.role)) == [.state, .namespace, .lifecycle, .operation, .run], "run lease roles")
            try context!.testingRevalidate()
            owner.release()
            try refuses { _ = try context!.prepare(.serviceStatus) }
            try refuses { _ = try RunAuthority.acquireRun(at: location) }
            try check(try context!.testingScope.leases.descriptorClaims() == claims, "source retirement changed held lock identity")
            context = nil
            let fresh = try RunAuthority.acquireRun(at: location); fresh.release()
        }
    }
    static func stagedObservation() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let owner = try RunAuthority.acquireLifecycleMutation(at: location)
            defer { owner.release() }
            let context = try CommandCustodyContext.testing(leases: owner.retainObservationLeases(),
                location: location, root: location.anchorPath, authority: owner)
            let prepared = try context.prepare(.serviceStatus)
            try check(context.mode == .observation && Set(prepared.resources.request.descriptors.map(\.role)).isDisjoint(with: [.operation, .run]),
                      "staged observation acquired operation authority")
            try refuses { _ = try CustodyAuthorityLeaseSet.retainReadLeases(at: location) }
        }
    }
    static func observationSourceClose() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let run = try RunAuthority.acquireRun(at: location); defer { run.release() }
            let owner = try LifecycleAdmissionAuthority.acquire(at: location)
            let context = try CommandCustodyContext.testing(leases: owner.retainObservationLeases(),
                location: location, root: location.anchorPath, observation: owner)
            _ = try context.prepare(.installedSignature)
            owner.release()
            try refuses { _ = try context.prepare(.serviceStatus) }
            try context.testingScope.leases.validate() // Retained descriptions still protect cleanup.
        }
    }
    static func wrongState() throws {
        try CustodyRegistrySelfTests.fixture { first, _ in
            try CustodyRegistrySelfTests.fixture { second, _ in
                let before = try CustodyCatalogSelfTests.bytes(first, "catalog.json")
                try refuses {
                    _ = try CommandCustodyContext.testing(leases: CustodyAuthorityLeaseSet.retainReadLeases(at: first),
                        location: second, root: second.anchorPath)
                }
                try check(try CustodyCatalogSelfTests.bytes(first, "catalog.json") == before, "wrong state changed catalog")
            }
        }
    }
    static func replacedState() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let context = try read(location), saved = location.path + ".retained-fixture"
            try check(rename(location.path, saved) == 0, "fixture state rename")
            var failure: Error?
            do {
                try check(mkdir(location.path, 0o700) == 0, "replacement fixture state")
                try refuses { _ = try context.prepare(.serviceStatus) }
            } catch { failure = error }
            try check(rmdir(location.path) == 0 && rename(saved, location.path) == 0, "fixture restoration failed")
            if let failure { throw failure }
            try context.testingRevalidate()
        }
    }
    static func missingCatalog() throws {
        try CustodyCatalogSelfTests.fixture(initialized: false) { location, _ in
            try refuses { _ = try read(location) }
            try check(!FileManager.default.fileExists(atPath: location.path + "/custody/catalog.json"), "context initialized missing evidence")
        }
    }
    static func foreignFence() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let prior = try CustodyCatalogSelfTests.scope(location)
            _ = try prior.prepare(CustodyCatalogSelfTests.request(prior))
            try refuses { _ = try read(location) }
            let owner = try LifecycleAdmissionAuthority.acquire(at: location); defer { owner.release() }
            let observer = try CommandCustodyContext.testing(leases: owner.retainObservationLeases(),
                location: location, root: location.anchorPath, observation: owner)
            _ = try observer.prepare(.serviceStatus)
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location, "catalog.json")).entries.count == 1,
                      "observation erased another scope's fence")
        }
    }
    static func singleUseAndRetention() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            var context: CommandCustodyContext? = try read(location)
            var command: PreparedCustodyCommand? = try context!.prepare(.serviceStatus)
            weak var retainedContext = context
            registry.testingFault(.beforeSpawn); registry.testingDelayQueue()
            let handle = try registry.start(command!)
            try refuses { _ = try registry.start(command!) }
            context = nil; command = nil
            try check(retainedContext != nil, "queued submission lost typed context")
            try refuses { _ = try RunAuthority.acquireRun(at: location) }
            try CustodyRegistrySelfTests.until { handle.snapshot().phase == .finished }
            try check(handle.snapshot().journal?.outcome == .admissionRefused, "bootstrap refusal not durably retired")
            try CustodyRegistrySelfTests.until { retainedContext == nil }
            let fresh = try RunAuthority.acquireRun(at: location); fresh.release()
        }
    }
    static func queuedSourceRetirement() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let owner = try RunAuthority.acquireRun(at: location)
            let context = try CommandCustodyContext.testing(leases: owner.retainCommandLeases(),
                location: location, root: location.anchorPath, authority: owner)
            let command = try context.prepare(.serviceStatus)
            registry.testingDelayQueue()
            let handle = try registry.start(command)
            owner.release()
            try CustodyRegistrySelfTests.until { handle.snapshot().phase == .finished }
            try check(handle.snapshot().journal == nil && registry.testingCount == 0, "retired source reached metadata/spawn")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location, "catalog.json")).entries.isEmpty,
                      "retired source left expected transaction")
        }
    }
    static func closedBeforeSubmit() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try read(location), command = try context.prepare(.serviceStatus)
            context.close()
            try refuses { _ = try registry.start(command) }
            try check(registry.testingCount == 0, "closed context admitted queued command")
        }
    }
    static func observationSourceDisappearance() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            var owner: RunAuthority? = try RunAuthority.acquireRun(at: location)
            weak var observedOwner = owner
            let context = try CommandCustodyContext.testing(leases: owner!.retainObservationLeases(),
                location: location, root: location.anchorPath, authority: owner!)
            owner = nil
            try check(observedOwner == nil, "observation retained entire original run authority")
            // Existing observation descriptions remain valid, but the original
            // operation/run EX descriptions must be available to a fresh owner.
            try context.testingScope.leases.validate()
            let fresh = try RunAuthority.acquireRun(at: location); fresh.release()
            try refuses { _ = try context.prepare(.serviceStatus) }
        }
    }
    private final class MetadataPauseResult: @unchecked Sendable {
        private let mutex = NSLock()
        private var result = false
        func set(_ value: Bool) { mutex.lock(); result = value; mutex.unlock() }
        func get() -> Bool { mutex.lock(); defer { mutex.unlock() }; return result }
    }
    static func boundedMetadataClose() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try read(location), command = try context.prepare(.serviceStatus)
            let barrier = CustodyLeaseTestingBarrier(), group = DispatchGroup(), result = MetadataPauseResult()
            let scope = context.testingScope
            group.enter()
            DispatchQueue.global().async {
                result.set(scope.testingHoldMetadata(barrier)); group.leave()
            }
            var failure: Error?
            var handle: RetainedCleanupRegistry.Handle?
            do {
                try check(barrier.waitUntilEntered(), "metadata pause did not enter")
                handle = try registry.start(command)
                let start = DispatchTime.now().uptimeNanoseconds
                context.close()
                try check(context.isClosed && DispatchTime.now().uptimeNanoseconds - start < 250_000_000,
                          "context close waited on metadata")
                try refuses { _ = try context.prepare(.serviceStatus) }
                try refuses { _ = try RunAuthority.acquireRun(at: location) }
            } catch { failure = error }
            barrier.release()
            try check(group.wait(timeout: .now() + .seconds(3)) == .success && result.get(),
                      "metadata pause owner did not finish")
            if let handle {
                try CustodyRegistrySelfTests.until { handle.snapshot().phase == .finished }
                try check(handle.snapshot().journal == nil, "closed metadata pause reached durable reservation")
            }
            if let failure { throw failure }
        }
    }
    static func originalBudget() throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
            let context = try read(location)
            let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 5)
            let a = try context.prepare(.serviceStatus, budget: budget)
            let b = try context.prepare(.installedSignature, budget: budget)
            try check(a.resources.request.budget == budget && b.resources.request.budget == budget,
                      "nested diagnostic reset the absolute budget")
            let expired = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 0.001, now: 0)
            try refuses { _ = try context.prepare(.serviceStatus, budget: expired) }
        }
    }
}

private enum CustodyHelperSelfTests {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool,_ message: String) throws { if !value { throw Failure(message:message) } }
    static func until(seconds: TimeInterval = 8, _ body: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: seconds)
        while !(try body()) { if deadline.hasExpired { throw Failure(message:"helper fixture convergence deadline") }; usleep(5_000) }
    }
    static let policyInput = Data(Array(repeating: Array((0..<256).map(UInt8.init)), count: 1024).joined())
    static let policyCode = Data(Array(repeating: Array((0..<256).reversed().map(UInt8.init)), count: 256).joined())
    static func resources(_ location: StateLocation, mode: String, work: TimeInterval = 2,
                          output: UInt64 = 65_536, term: TimeInterval = 0.1) throws -> CustodyRequestResources {
        let home = location.anchorPath + "/home"
        try FileManager.default.createDirectory(atPath:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let account = try EffectiveAccount.isolated(homeDirectory:home)
        let scope = try CustodyMetadataScope(leases:CustodyAuthorityLeaseSet.retainReadLeases(at:location),
            releaseSHA256:String(repeating:"c",count:64),generation:RunIdentity.make())
        let fd = open("/",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(message:"fixture cwd") }
        let tracing = mode.hasPrefix("trace-")
        let serial = mode.hasPrefix("serial-")
        let policy = mode.hasPrefix("policy-")
        let system = mode.hasPrefix("system-")
        let kind: CustodyCommandKind = system ? .systemGitConfig : (policy ? .policyClassify : (tracing || serial ? .discoveryGit : .launchctlRead))
        return try CustodyRequestResources(scope:scope,kind:kind,arguments:[mode],
            environment:system ? SystemGitConfigurationCommand.environment(account:account) : ClosedProcessRunner.environment(account:account),
            budget:CustodyBudget.make(kind:kind,workSeconds:work,termSeconds:term,killSeconds:0.2,receiptSeconds:0.2),
            stdoutLimit:output,stderrLimit:output,workingDirectory:OwnedFileDescriptor(fd),
            input:policy ? policyInput : nil,code:policy ? policyCode : nil,captureDiscoveryTrace:tracing)
    }
    static func native(_ mode: String, cancel: Bool = false, eof: Bool = false,
                       tokenCancel: Bool = false, tokenAlreadyCancelled: Bool = false, expected: CustodyOutcome,
                       reason: CustodyReason, work: TimeInterval = 2, output: UInt64 = 65_536) throws {
        try CustodyRegistrySelfTests.fixture { location,registry in
            var stage = "resources"
            var diagnostic: [String: String] = [:]
            do {
            let resources = try resources(location,mode:mode,work:work,output:output)
            stage = "helper-create"
            let helper = try CustodyHelperExecutable.testingCustodian()
            stage = "registry-start"
            let handle = try registry.start(resources:resources,helper:helper)
            stage = "convergence"
            if cancel || eof || tokenCancel {
                if mode == "after-preparation" {
                    try until { handle.snapshot().stderr == Data("shadow-sync-fixture-final-preparation\n".utf8) }
                    try check(handle.snapshot().stdout.isEmpty, "target executed before final control EOF")
                } else if mode == "after-admit" || mode == "before-resume" {
                    try until {
                        guard let data = try? CustodyCatalogSelfTests.bytes(location,resources.request.binding.requestID + ".json"),
                              let journal = try? CustodyJournal.decode(data) else { return false }
                        return journal.phase == (mode == "after-admit" ? .admitted : .executing)
                    }
                } else if mode == "policy-resist" {
                    try until { String(decoding: handle.snapshot().stdout, as: UTF8.self).contains("policy-code:") }
                } else if mode == "trace-resist" {
                    try until { handle.snapshot().trace.count == 32_768 }
                    try check(handle.snapshot().phase != .finished, "trace writer lost ownership before EOF")
                } else { try until { !handle.snapshot().stdout.isEmpty } }
                if tokenCancel {
                    let token = CancellationToken()
                    if tokenAlreadyCancelled { token.cancel() }
                    let registration = token.observeCustodyCancellation(handle)
                    if !tokenAlreadyCancelled { token.cancel() }
                    token.removeCustodyCancellation(registration)
                    try check(token.isCancelled && token.areFutureChildAdmissionsClosed, "custody token did not close admission")
                } else if cancel { handle.cancel() } else { registry.testingCloseControl(handle) }
            }
            var observedPhases: Set<String> = []
            do {
                try until {
                    if let data = try? CustodyCatalogSelfTests.bytes(location,resources.request.binding.requestID + ".json"),
                       let value = try? CustodyJournal.decode(data) { observedPhases.insert(value.phase.rawValue) }
                    return handle.snapshot().phase == .finished
                }
            } catch {
                let result = handle.snapshot()
                let data = try? CustodyCatalogSelfTests.bytes(location,resources.request.binding.requestID + ".json")
                let record = data.flatMap { try? CustodyJournal.decode($0) }
                throw Failure(message:"helper \(mode) convergence: phase=\(result.phase) reason=\(String(describing:result.reason)) owner=\(String(describing:registry.testingPoll(handle))) journal=\(String(describing:record?.phase))/\(String(describing:record?.outcome)) output=\(result.stdout.count)/\(result.stderr.count)")
            }
            let result = handle.snapshot()
            stage = "result-validation"
            diagnostic = ["phase": String(describing:result.phase), "reason":String(describing:result.reason),
                "journal_kind":String(describing:result.journal?.kind), "journal_phase":String(describing:result.journal?.phase),
                "journal_outcome":String(describing:result.journal?.outcome), "journal_reason":String(describing:result.journal?.reason),
                "raw_status":String(describing:result.journal?.waitStatus), "stdout_bytes":String(result.stdout.count),
                "stderr_bytes":String(result.stderr.count), "trace_bytes":String(result.trace.count),
                "retained_count":String(registry.testingCount)]
            guard let journal = result.journal else { throw Failure(message:"missing terminal") }
            try check(journal.outcome == expected && journal.reason == reason,"wrong durable helper result: \(String(describing:journal.outcome)) / \(String(describing:journal.reason))")
            // Bind the value before branching: the qualified Swift optimizer
            // otherwise misbalances a borrow across repeated optional projections.
            guard let custodian = journal.custodian else { throw Failure(message: "helper identity missing") }
            let custodianPID = custodian.pid
            try check(custodianPID != UInt32(getpid()), "helper identity missing")
            if mode == "after-admit" {
                try check(journal.target == nil && result.stdout.isEmpty,"target spawned after cancellation")
            } else {
                guard let target = journal.target else { throw Failure(message: "target identity not separate") }
                try check(target.pid != custodianPID, "target identity not separate")
                if mode == "before-resume" || mode == "after-preparation" { try check(result.stdout.isEmpty,"cancelled suspended target executed") }
                else if mode == "system-missing" { try check(result.stdout.isEmpty && journal.waitStatus == 128 << 8, "missing config fixture did not exit normally") }
                else if mode == "system-complete" || mode == "system-faildata" {
                    try check(result.stdout == Data("file:/fixture/system-config\0core.safe\0".utf8), "fixed config bytes changed")
                } else { try check(String(decoding:result.stdout,as:UTF8.self).hasPrefix("target-started:"),"actual target never executed") }
            }
            if mode == "after-preparation" {
                try check(result.stderr == Data("shadow-sync-fixture-final-preparation\n".utf8)
                    && journal.waitStatus == UInt32(SIGKILL), "final-preparation EOF did not drain the suspended original")
            }
            if mode == "deadline-before-control" {
                try check(result.stderr == Data("shadow-sync-fixture-expired-control\n".utf8)
                    && journal.waitStatus == UInt32(SIGKILL), "expired control ordering did not drain the actual resistant child")
            }
            if mode == "fail" { try check(journal.waitStatus == 7 << 8,"raw exit status lost") }
            if reason != .none {
                try check(journal.ordinal == (journal.target == nil ? 3 : 4),"durable draining transition was skipped")
            }
            if mode == "trace-complete" || mode == "trace-resist" {
                let expectedTrace = Data(Array(repeating: Array((0..<256).map(UInt8.init)), count: 128).joined())
                try check(result.trace == expectedTrace && result.stderr.isEmpty,
                          "third stream lost bytes or mixed with standard streams")
            } else if mode == "trace-overflow" {
                let prefix = Data(Array(repeating: Array((0..<256).map(UInt8.init)), count: 1024).joined())
                try check(result.trace == prefix && result.trace.count == DiscoveryGitCommand.traceLimit,
                          "trace overflow did not preserve the exact bounded prefix")
            } else { try check(result.trace.isEmpty, "diagnostic command received a third stream") }
            if mode == "resist" || mode == "trace-resist" || mode == "policy-resist" || mode == "system-resist" {
                try check(journal.waitStatus == UInt32(SIGKILL),"TERM-resistant target not KILL-drained")
                try check(observedPhases.contains(CustodyPhase.draining.rawValue),"draining journal never observed")
            }
            if mode.hasPrefix("system-") {
                stage = "consumer"
                let account = try EffectiveAccount.isolated(homeDirectory: location.anchorPath + "/home")
                if mode == "system-complete" {
                    try check(try SystemGitConfigurationCommand.path(from: result) == "/fixture/system-config", "config origin changed")
                    let preflight = try SystemGitConfigurationCommand.preflight(from: result, account: account)
                    try check(preflight.paths == ["/fixture/system-config", account.homeDirectory + "/.config/git/config",
                        account.homeDirectory + "/.gitconfig"], "native preflight source set changed")
                } else if mode == "system-missing" {
                    try check(try SystemGitConfigurationCommand.path(from: result) == nil, "normal missing config result changed")
                    let preflight = try SystemGitConfigurationCommand.preflight(from: result, account: account)
                    try check(preflight.systemPath == nil && preflight.paths.count == 2, "native absence became a probe request")
                } else {
                    do { _ = try SystemGitConfigurationCommand.path(from: result); throw Failure(message: "incomplete config acquired absence meaning") }
                    catch SystemGitConfigurationError.unavailable {}
                    do { _ = try SystemGitConfigurationCommand.preflight(from: result, account: account); throw Failure(message: "incomplete config acquired preflight inputs") }
                    catch SystemGitConfigurationError.unavailable {}
                }
            }
            if mode.hasPrefix("policy-") {
                let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
                try check(lines.count == 3 && lines[1] == "policy-input:" + CustodyRecordBinding.digest(policyInput)
                    && lines[2] == "policy-code:" + CustodyRecordBinding.digest(policyCode),
                    "sealed input/code bytes changed, were truncated or had a wrong descriptor offset")
                try check(resources.request.inputSHA256 == CustodyRecordBinding.digest(policyInput)
                    && resources.request.arguments == [mode], "policy request did not bind sealed input")
            }
            try check(result.stdout.count <= output && registry.testingCount == 0,"bounded output or registry retirement")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location,"catalog.json")).entries.isEmpty,"catalog not retired")
            let receipt = try CustodyCatalogSelfTests.bytes(location,"receipts/"+resources.request.binding.requestID+".caller.json")
            let v = try JSONSerialization.jsonObject(with:receipt) as! [String:Any]
            try check(v["event"] as? String == "custodian-reaped","caller did not exclusively reap helper")
            // Keeping caller resources alive must still exclude mutation.
            do { _ = try RunAuthority.acquireRun(at:location); throw Failure(message:"lease exclusion lost") }
            catch is SecureStateError {}
            } catch {
                if mode.hasPrefix("system-") {
                    diagnostic["stage"] = stage; diagnostic["error_type"] = String(reflecting:type(of:error))
                    if let bytes = try? JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]) {
                        FileHandle.standardError.write(Data("SYSTEM CONFIG DIAGNOSTIC ".utf8) + bytes + Data("\n".utf8))
                    }
                }
                throw error
            }
        }
    }
    static func configurationPlan(refusals: Bool) throws {
        try CustodyRegistrySelfTests.fixture { location, _ in
        let home = location.anchorPath + "/home", foreignHome = location.anchorPath + "/foreign"
        for path in [home, foreignHome] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let preflight = try GitConfigurationPreflight.testing(systemPath: "/fixture/system-config", account: account)
        let plan = try ConfigurationPolicyPlan(preflight: preflight, account: account)
        let expected = ["/fixture", "/fixture/system-config", "/private", "/private/tmp", location.anchorPath,
                        home, home + "/.config", home + "/.config/git", home + "/.config/git/config", home + "/.gitconfig"]
        try check(plan.batches == [expected], "configuration ancestor/leaf roster changed")
        if refusals {
            let foreign = try EffectiveAccount.isolated(homeDirectory: foreignHome)
            do { _ = try ConfigurationPolicyPlan(preflight: preflight, account: foreign); throw Failure(message: "foreign configuration account accepted") }
            catch SystemGitConfigurationError.unavailable {}
            let excessive = try GitConfigurationPreflight.testing(systemPath: "/fixture/" + Array(repeating: "x", count: 256).joined(separator: "/"), account: account)
            do { _ = try ConfigurationPolicyPlan(preflight: excessive, account: account); throw Failure(message: "excessive configuration ancestors accepted") }
            catch PolicyHelperError.unavailable {}
            for index in [-1, 1] {
                do { _ = try plan.bind(index: index, nonce: String(repeating: "a", count: 32), bindingSHA256: String(repeating: "b", count: 64), policySHA256: String(repeating: "d", count: 64), moduleSHA256: String(repeating: "e", count: 64)); throw Failure(message: "foreign policy batch accepted") }
                catch PolicyProtocolError.invalidRequest {}
            }
        } else {
            let long = try GitConfigurationPreflight.testing(systemPath: "/fixture/" + Array(repeating: "x", count: 70).joined(separator: "/") + "/config", account: account)
            let many = try ConfigurationPolicyPlan(preflight: long, account: account)
            try check(many.batches.count == 2 && many.batches[0].count == 64 && !many.batches[1].isEmpty,
                      "configuration batch boundary changed")
            let all = many.batches.flatMap { $0 }
            try check(Set(all.map { Data($0.utf8) }).count == all.count && !all.contains("/"), "configuration roster duplicated or included root")
            for index in many.batches.indices {
                let batch = try many.bind(index: index, nonce: String(repeating: String(index + 1), count: 32), bindingSHA256: String(repeating: "b", count: 64), policySHA256: String(repeating: "d", count: 64), moduleSHA256: String(repeating: "e", count: 64))
                try PolicyCommandWire.validateRequest(batch.input, bindingSHA256: String(repeating: "b", count: 64))
            }
        }
        }
    }
    static func serial(_ mode: String, cancelAt: Int? = nil, eof: Bool = false) throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let started = DispatchTime.now().uptimeNanoseconds
            let resources = try resources(location, mode: mode, work: 5)
            let handle = try registry.start(resources: resources, helper: CustodyHelperExecutable.testingCustodian())
            if let cancelAt {
                let event = mode.hasPrefix("serial-postflight-") ? "postflight" : mode == "serial-between-cancel" ? "retired" : "ready"
                try until { String(decoding: handle.snapshot().stderr, as: UTF8.self)
                    .contains("shadow-sync-fixture-serial:\(cancelAt):\(event):") }
                // Retaining the request must still exclude a mutation during
                // every preflight and between two fully drained children.
                do { _ = try RunAuthority.acquireRun(at: location); throw Failure(message: "serial lock gap") }
                catch is SecureStateError {}
                if eof { registry.testingCloseControl(handle) } else { handle.cancel() }
            }
            // The deliberate two-second child timeout is sixfold in testing;
            // observe that unchanged timeline without the unrelated 8s default.
            try until(seconds: mode == "serial-postflight-timeout" ? ChildProcessBudget.seconds(7) : mode == "serial-policy-timeout" ? ChildProcessBudget.seconds(4) : 8) {
                handle.snapshot().phase == .finished
            }
            let result = handle.snapshot()
            guard let journal = result.journal else { throw Failure(message: "serial terminal missing") }
            let markers = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n").map {
                $0.split(separator: ":").map(String.init)
            }
            try check(markers.allSatisfy { $0.count == 4 && $0[0] == "shadow-sync-fixture-serial"
                && Int($0[1]) != nil && ["resumed", "ready", "retired", "postflight"].contains($0[2]) && UInt32($0[3]) != nil },
                "serial output escaped its closed marker shape")
            let resumed = markers.filter { $0[2] == "resumed" }, retired = markers.filter { $0[2] == "retired" }
            let completed = ["serial-complete", "serial-policy-multiple-batches", "serial-system-missing", "serial-policy-code-batches"].contains(mode)
            let timeout = mode == "serial-policy-timeout" || mode == "serial-postflight-timeout", overflow = mode.hasSuffix("overflow")
            let expected: CustodyOutcome = cancelAt != nil ? .cancelledDrained : (timeout ? .timedOutDrained : (completed ? .completed : .commandFailed))
            let reason: CustodyReason = cancelAt != nil ? .cancelled : (timeout ? .timeout : (overflow ? .outputLimit : (completed ? .none : .invalidResource)))
            try check(journal.outcome == expected && journal.reason == reason,
                "serial outcome \(String(describing: journal.outcome))/\(String(describing: journal.reason))")
            try check(journal.budget == resources.request.budget, "serial stage replaced the original journal budget")
            try check(!resumed.isEmpty && resumed.count == Set(resumed.map { $0[3] }).count,
                "serial stages reused child identity")
            try check(resumed.map { Int($0[1])! } == Array(0..<resumed.count), "serial stage skipped/reordered")
            for row in retired {
                guard let matching = resumed.first(where: { $0[1] == row[1] }) else { throw Failure(message: "unspawned stage retired") }
                try check(row[3] == matching[3], "retired child identity changed")
            }
            for index in 1..<resumed.count {
                let prior = markers.firstIndex { $0[1] == String(index - 1) && $0[2] == "retired" }
                let next = markers.firstIndex { $0[1] == String(index) && $0[2] == "resumed" }
                try check(prior != nil && next != nil && prior! < next!, "next child resumed before predecessor reaping")
            }
            let expectedStages: Int
            if completed || cancelAt == 2 || mode == "serial-postflight-timeout" { expectedStages = ["serial-policy-multiple-batches", "serial-policy-code-batches"].contains(mode) ? 4 : 3 }
            else if mode.hasPrefix("serial-policy-") || timeout || cancelAt == 1 { expectedStages = 2 }
            else { expectedStages = 1 }
            try check(resumed.count == expectedStages, "serial refusal admitted another stage")
            guard let target = journal.target, let custodian = journal.custodian else {
                throw Failure(message: "durable target lost its exact owner")
            }
            try check(target.pid == UInt32(resumed.last![3])
                && custodian.pid != target.pid, "durable target lost its exact owner")
            if !mode.hasPrefix("serial-postflight-"), timeout || cancelAt != nil && mode != "serial-between-cancel" {
                try check(journal.waitStatus == UInt32(SIGKILL), "resistant serial child was not KILL-drained")
            }
            if mode.hasPrefix("serial-postflight-") {
                try check(journal.waitStatus == 0 && markers.filter { $0[2] == "postflight" }.count == 1,
                    "postflight race lost actual successful child status or ran more than once")
            }
            if mode == "serial-policy-timeout" {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                try check(elapsed < ChildProcessBudget.seconds(4), "policy stage used the longer outer command deadline")
            }
            if completed {
                try check(retired.count == expectedStages - 1 && journal.ordinal == UInt64(expectedStages + 2) && journal.waitStatus == 0,
                    "serial durable replacement count/status changed")
            }
            if mode.hasPrefix("serial-system-missing-next-") {
                try check(journal.waitStatus == UInt32(128 << 8) && retired.count == 1,
                    "next-stage failure lost fixture exit128 raw status: \(String(describing: journal.waitStatus)), retired=\(retired.count)")
            }
            if expectedStages < 3 { try check(result.stdout.isEmpty, "preflight bytes leaked into command output") }
            else { try check(String(decoding: result.stdout, as: UTF8.self).hasPrefix("target-started:"), "final command output lost") }
            try check(result.trace.isEmpty && registry.testingCount == 0, "serial trace/retirement mismatch")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location, "catalog.json")).entries.isEmpty,
                "serial catalog still active")
            do { _ = try RunAuthority.acquireRun(at: location); throw Failure(message: "serial original lease lost") }
            catch is SecureStateError {}
        }
    }
    static func reapedBeforeReads(_ mode: RetainedCleanupRegistry.TestReadDeferral) throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            // A small fixed target can complete without filling either pipe.
            // Hold only caller-side reads; never suspend/kill a helper to force
            // an observation order or substitute a decoded PID for its owner.
            let resources = try resources(location, mode:"system-complete", work:5)
            registry.testingDeferNextRead(mode)
            let handle = try registry.start(resources:resources, helper:CustodyHelperExecutable.testingCustodian())
            defer { registry.testingReleaseDeferredRead(handle) }
            try until {
                guard let observed = registry.testingReadObservation(handle) else { return false }
                return observed.reapedObservations >= 2
                    && (mode == .statusAfterAdmission || observed.terminalReceived && observed.statusEOF)
            }
            guard case .reaped(0)? = registry.testingPoll(handle),
                  let observed = registry.testingReadObservation(handle) else {
                throw Failure(message:"original helper was not reaped before deferred reads")
            }
            let pending = handle.snapshot()
            try check(pending.phase == .running && pending.reason == nil && pending.journal == nil,
                      "unread terminal/output evidence acquired a premature fault or retirement")
            try check(DispatchTime.now().uptimeNanoseconds < resources.request.budget.work,
                      "read deferral exhausted the work deadline")
            if mode == .statusAfterAdmission {
                try check(!observed.terminalReceived && !observed.statusEOF,
                          "status deferral did not precede terminal/EOF consumption")
            } else {
                try check(observed.terminalReceived && observed.statusEOF && !observed.outputEOF && pending.stdout.isEmpty,
                          "output deferral did not retain unread bytes after terminal consumption")
            }
            try check(registry.testingCount == 1 && registry.hasRetainedWork,
                      "reaped original lost its outstanding resource reservation")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location,"catalog.json")).entries.count == 1,
                      "unconsumed evidence retired durable custody")
            do { _ = try RunAuthority.acquireRun(at:location); throw Failure(message:"unconsumed evidence released operation exclusion") }
            catch is SecureStateError {}
            try check(registry.testingReleaseDeferredReadAndTick(handle),
                      "already-reaped helper needed another tick for available terminal/output EOF")
            try check(registry.testingCount == 0, "single-tick drainage retained its reservation")
            let result = handle.snapshot()
            try check(result.reason == nil && result.journal?.outcome == .completed
                && result.journal?.reason == CustodyReason.none && result.journal?.waitStatus == 0,
                      "verified retirement retained a spurious fault")
            try check(result.stdout == Data("file:/fixture/system-config\0core.safe\0".utf8)
                && result.stderr.isEmpty && result.trace.isEmpty,
                      "deferred reads lost bytes or failed to drain streams")
            try check(try SystemGitConfigurationCommand.path(from:result) == "/fixture/system-config",
                      "fully drained fixed command was not usable")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location,"catalog.json")).entries.isEmpty,
                      "fully drained command was not retired")
            let receipt = try CustodyCatalogSelfTests.bytes(location,"receipts/"+resources.request.binding.requestID+".caller.json")
            let value = try JSONSerialization.jsonObject(with:receipt) as! [String:Any]
            try check(value["event"] as? String == "custodian-reaped", "no original-helper retirement receipt")
        }
    }
    static func bare() throws {
        try check(CommandCustodian.dispatch(["fixture","--shadow-sync-command-custodian"]) == 70,"bare unsigned helper admitted")
        try check(CommandCustodian.dispatch(["fixture","--shadow-sync-command-custodian","extra"]) == 64,"extra helper argument admitted")
        try check(LifecycleCoordinatorMain.run(arguments: ["fixture","--shadow-sync-command-custodian"]) == 70,
                  "testing coordinator acquired publisher authority")
        try check(CommandCustodian.dispatchLifecycle(["fixture","--shadow-sync-command-custodian","extra"]) == 64,
                  "extra coordinator helper argument admitted")
        try check(CommandCustodian.dispatchLifecycle(["fixture","--help"]) == nil,
                  "ordinary coordinator invocation entered custody")
    }
    static func policyResourceBoundary(output oversized: Bool) throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let original = try resources(location, mode: "complete")
            let before = try CustodyCatalogSelfTests.bytes(location, "catalog.json")
            let missing: [(Data?, Data?)] = oversized ? [(policyInput, policyCode)] : [(nil, policyCode), (policyInput, nil)]
            for (input, code) in missing {
                let fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure(message: "policy resource refusal cwd") }
                do {
                    _ = try CustodyRequestResources(scope: original.scope, kind: .policyClassify,
                        arguments: ["policy-echo"], environment: original.request.environment,
                        budget: CustodyBudget.make(kind: .policyClassify, workSeconds: 2),
                        stdoutLimit: oversized ? 65_537 : 65_536, stderrLimit: 65_536,
                        workingDirectory: OwnedFileDescriptor(fd), input: input, code: code)
                    throw Failure(message: "invalid policy resources admitted")
                } catch CustodyResourceError.invalidResource {}
            }
            try check(registry.testingCount == 0 && (try CustodyCatalogSelfTests.bytes(location, "catalog.json")) == before,
                "invalid policy resources reserved or spawned a command")
        }
    }
    static func traceCommandBoundary() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let original = try resources(location, mode: "trace-complete")
            let fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure(message: "trace refusal cwd") }
            do {
                _ = try CustodyRequestResources(scope: original.scope, kind: .launchctlRead,
                    arguments: ["complete"], environment: original.request.environment,
                    budget: original.request.budget, stdoutLimit: 1024, stderrLimit: 1024,
                    workingDirectory: OwnedFileDescriptor(fd), captureDiscoveryTrace: true)
                throw Failure(message: "non-discovery trace capability was accepted")
            } catch CustodyResourceError.invalidResource {}
            try check(registry.testingCount == 0, "refused trace spawned a helper")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location,"catalog.json")).entries.isEmpty,
                      "refused trace created a durable reservation")
        }
    }
    static func traceReservationBoundary() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            // The two ordinary streams alone exactly fill 64 MiB. Admission
            // must include the additional fixed trace buffer before any spawn.
            let request = try resources(location, mode: "trace-complete", output: 33_554_432)
            do {
                _ = try registry.start(resources: request, helper: CustodyHelperExecutable.testingCustodian())
                throw Failure(message: "trace escaped aggregate memory reservation")
            } catch CustodyRecordError.fenced {}
            try check(registry.testingCount == 0, "oversized trace request entered the registry")
            try check(try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location,"catalog.json")).entries.isEmpty,
                      "oversized trace request created a durable reservation")
        }
    }
    static func failedStatus() throws {
        let binding = CustodyBinding(requestID:RunIdentity.make(),scopeID:RunIdentity.make(),nonce:String(repeating:"a",count:32),
            callerGeneration:RunIdentity.make(),trustedUID:geteuid(),bootID:try CustodyBootIdentity.current(),releaseSHA256:String(repeating:"c",count:64))
        let budget = try CustodyBudget.make(kind:.launchctlRead,workSeconds:2)
        var state = try CustodyAdmissionState(binding:binding,budget:budget)
        try state.accept(CustodyMessage(binding:binding,sequence:0,event:.ready,outcome:nil,waitStatus:nil,receiptSHA256:nil),now:DispatchTime.now().uptimeNanoseconds)
        try state.accept(CustodyMessage(binding:binding,sequence:0,event:.admit,outcome:nil,waitStatus:nil,receiptSHA256:nil),now:DispatchTime.now().uptimeNanoseconds)
        try state.accept(CustodyMessage(binding:binding,sequence:1,event:.pending,outcome:nil,waitStatus:nil,receiptSHA256:nil),now:DispatchTime.now().uptimeNanoseconds)
        let failed = CustodyMessage(binding:binding,sequence:2,event:.terminal,outcome:.failed,waitStatus:0,receiptSHA256:String(repeating:"d",count:64))
        _ = try CustodyMessage.decode(failed.encode(),expected:binding,channel:.status)
        try state.accept(failed,now:DispatchTime.now().uptimeNanoseconds)
        try check(state.phase == .terminal,"helper-detected fault did not close transaction")
    }
    static func earlyTimeout(refusals: Bool) throws {
        let binding = CustodyBinding(requestID: RunIdentity.make(), scopeID: RunIdentity.make(),
            nonce: String(repeating: "a", count: 32), callerGeneration: RunIdentity.make(), trustedUID: geteuid(),
            bootID: try CustodyBootIdentity.current(), releaseSHA256: String(repeating: "c", count: 64))
        let budget = try CustodyBudget.make(kind: .discoveryGit, workSeconds: 5)
        let ready = CustodyMessage(binding: binding, sequence: 0, event: .ready, outcome: nil, waitStatus: nil, receiptSHA256: nil)
        let admit = CustodyMessage(binding: binding, sequence: 0, event: .admit, outcome: nil, waitStatus: nil, receiptSHA256: nil)
        func terminal(_ sequence: UInt64) -> CustodyMessage {
            CustodyMessage(binding: binding, sequence: sequence, event: .terminal, outcome: .timedOut,
                waitStatus: UInt32(SIGKILL), receiptSHA256: String(repeating: "d", count: 64))
        }
        if refusals {
            for phase in 0..<3 {
                var state = try CustodyAdmissionState(binding: binding, budget: budget)
                if phase > 0 { try state.accept(ready, now: budget.issued) }
                if phase == 2 { try state.closeAdmission(now: budget.issued) }
                do {
                    try state.accept(terminal(phase == 0 ? 0 : 1), now: budget.issued + 1)
                    throw Failure(message: "unadmitted early timeout accepted")
                } catch is CustodyProtocolError {}
            }
        }
        var state = try CustodyAdmissionState(binding: binding, budget: budget)
        try state.accept(ready, now: budget.issued); try state.accept(admit, now: budget.issued)
        try state.accept(terminal(1), now: budget.issued + 1)
        try check(state.phase == .terminal && state.budget == budget, "early timeout failed or rewrote outer timeline")
        if refusals {
            do {
                try state.accept(terminal(1), now: budget.issued + 2)
                throw Failure(message: "terminal replay accepted")
            } catch is CustodyProtocolError {}
        }
    }
    static func terminalState() throws {
        let binding = CustodyBinding(requestID:RunIdentity.make(),scopeID:RunIdentity.make(),nonce:String(repeating:"a",count:32),
            callerGeneration:RunIdentity.make(),trustedUID:geteuid(),bootID:try CustodyBootIdentity.current(),releaseSHA256:String(repeating:"c",count:64))
        let budget = try CustodyBudget.make(kind:.launchctlRead,workSeconds:2)
        for cancelled in [false,true] {
            var state = try CustodyAdmissionState(binding:binding,budget:budget)
            try state.accept(CustodyMessage(binding:binding,sequence:0,event:.ready,outcome:nil,waitStatus:nil,receiptSHA256:nil),now:budget.issued)
            try state.accept(CustodyMessage(binding:binding,sequence:0,event:.admit,outcome:nil,waitStatus:nil,receiptSHA256:nil),now:budget.issued)
            if cancelled { try state.closeAdmission(now:budget.issued+1) }
            try state.accept(CustodyMessage(binding:binding,sequence:1,event:.terminal,outcome:.completed,waitStatus:0,
                receiptSHA256:String(repeating:"d",count:64)),now:budget.work+1)
            try check(state.phase == .terminal,"valid late terminal did not converge")
        }
        var unadmitted = try CustodyAdmissionState(binding:binding,budget:budget)
        do {
            try unadmitted.accept(CustodyMessage(binding:binding,sequence:0,event:.terminal,outcome:.completed,waitStatus:0,
                receiptSHA256:String(repeating:"d",count:64)),now:budget.issued)
            throw Failure(message:"unadmitted completion accepted")
        } catch is CustodyProtocolError {}
    }
    private static func writeParentMarker(_ data: Data, root: String, name: String) throws {
        guard ["worker-started", "worker-admission-ready", "worker-ready.json"].contains(name),
              !data.isEmpty, data.count <= 65_536 else { throw Failure(message: "parent marker contract") }
        let directory = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure(message: "parent marker directory") }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure(message: "parent marker owner") }
        let staging = "." + name + ".pending"
        let descriptor = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure(message: "parent marker staging") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure(message: "parent marker write") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameatx_np(directory, staging, directory, name, UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0 else { throw Failure(message: "parent marker publication") }
    }

    private final class ParentControl: @unchecked Sendable {
        private let lock = NSLock()
        private var cause: Int32?
        private let deadline: UInt64
        init(seconds: TimeInterval) { deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9) }
        var stopped: Int32? { lock.lock(); defer { lock.unlock() }; return cause }
        func admit<T>(_ submit: () throws -> T) throws -> T {
            lock.lock(); defer { lock.unlock() }
            _ = observeLocked()
            guard cause == nil else { throw CustodyRecordError.fenced }
            return try submit()
        }
        /// True only for the first transition; callers enqueue cancellation once.
        @discardableResult func observe() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return observeLocked()
        }
        private func observeLocked() -> Bool {
            guard cause == nil else { return false }
            if DispatchTime.now().uptimeNanoseconds >= deadline { cause = 93; return true }
            var byte: UInt8 = 0
            let count = Darwin.read(209, &byte, 1), error = errno
            if count == 0 { cause = 94 }
            else if count > 0 || (error != EAGAIN && error != EWOULDBLOCK && error != EINTR) { cause = 95 }
            return cause != nil
        }
    }
    static func parentWorker(_ root: String, mode: String) -> Int32 {
        guard ["normal", "pre-ready", "before-admission", "short-lifetime"].contains(mode) else { return 64 }
        var channel = stat()
        let flags = fcntl(209, F_GETFL), descriptorFlags = fcntl(209, F_GETFD)
        guard fstat(209, &channel) == 0, channel.st_mode & S_IFMT == S_IFIFO,
              channel.st_uid == geteuid(), flags >= 0, flags & O_ACCMODE == O_RDONLY,
              descriptorFlags >= 0, fcntl(209, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(209, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { return 64 }
        defer { close(209) }
        let control = ParentControl(seconds: mode == "short-lifetime" ? 1 : 10)
        let registry = RetainedCleanupRegistry.testingInstance()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shadow-sync.parent-fixture.control"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler {
            if control.observe() { registry.testingRequestCancellation() }
        }
        timer.resume()
        defer {
            registry.testingRequestCancellation()
            var reported = false; let diagnostic = MonotonicDeadline(seconds: 5)
            while registry.testingCount != 0 {
                if diagnostic.hasExpired && !reported {
                    fputs("PARENT WORKER CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
                }
                usleep(5_000)
            }
            // Normal registry retirement proves reap, real stream EOF and the
            // durable terminal transaction. Disposal now sees an empty registry.
            try? registry.testingDispose()
            timer.cancel()
        }
        do {
            let location = try StateLocation.isolated(root: root)
            try writeParentMarker(Data("started".utf8), root: root, name: "worker-started")
            if mode == "pre-ready" {
                while control.stopped == nil { usleep(5_000) }
                return control.stopped ?? 95
            }
            control.observe()
            if let status = control.stopped { return status }
            let resources = try resources(location, mode: "resist", work: 4, term: 0.5)
            let helper = try CustodyHelperExecutable.testingCustodian()
            if mode == "before-admission" {
                try writeParentMarker(Data("prepared".utf8), root: root, name: "worker-admission-ready")
                while control.stopped == nil { usleep(5_000) }
                do {
                    _ = try control.admit { try registry.start(resources: resources, helper: helper) }
                    return 96 // Cleanup cannot turn an unexpected admission into a pass.
                } catch CustodyRecordError.fenced { return control.stopped ?? 96 }
                catch { return 97 }
            }
            // Submission is in-memory/queued only. An observed stop cannot
            // interleave between this check and enqueueing the actual entry.
            let handle = try control.admit { try registry.start(resources: resources, helper: helper) }
            while handle.snapshot().stdout.isEmpty {
                if let status = control.stopped { return status }
                if handle.snapshot().phase == .finished { return 91 }
                usleep(5_000)
            }
            if let status = control.stopped { return status }
            guard let helper = registry.testingIdentity(handle),
                  let journal = try? CustodyJournal.decode(CustodyCatalogSelfTests.bytes(location, resources.request.binding.requestID + ".json")),
                  journal.phase == .executing, let target = journal.target else { return 91 }
            let data = try JSONSerialization.data(withJSONObject: ["request": resources.request.binding.requestID,
                "helper": helper.processID, "helper_start": helper.startSeconds,
                "target": target.pid, "target_start": target.startSeconds], options: [.sortedKeys])
            try writeParentMarker(data, root: root, name: "worker-ready.json")
            while control.stopped == nil { usleep(5_000) }
            return control.stopped ?? 95
        } catch { return control.stopped ?? 92 }
    }
    private struct ParentFixture {
        let anchor: OwnedSpawnAnchor
        let owner: OwnedDirectChild
        let control: OwnedFileDescriptor
    }
    private static func spawnParent(_ root: String, mode: String = "normal") throws -> ParentFixture {
        var pipeFDs: [Int32] = [-1, -1]
        try check(pipe(&pipeFDs) == 0, "parent control pipe")
        let reader = OwnedFileDescriptor(pipeFDs[0]), writer = OwnedFileDescriptor(pipeFDs[1])
        defer { reader.closeNow() }
        for fd in pipeFDs { try check(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, "parent control CLOEXEC") }
        var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions) == 0, "parent actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attr) == 0, "parent attributes")
        defer { posix_spawnattr_destroy(&attr) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0,
                      "parent null streams")
        }
        try check(posix_spawn_file_actions_adddup2(&actions, reader.value, 209) == 0
            && posix_spawn_file_actions_addchdir(&actions, root) == 0, "parent control mapping")
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        var empty = sigset_t(); sigemptyset(&empty)
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        try check(posix_spawnattr_setflags(&attr, flags) == 0 && posix_spawnattr_setpgroup(&attr, 0) == 0
            && posix_spawnattr_setsigdefault(&attr, &defaults) == 0 && posix_spawnattr_setsigmask(&attr, &empty) == 0, "parent flags")
        let executable = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()).executablePath
        let args = ([executable, "--shadow-sync-custodian-parent-fixture", root, mode] as [String]).map { strdup($0) }
        let environment: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=/private/tmp"]
        let environmentPointers = environment.map { strdup($0) }
        defer { (args + environmentPointers).forEach { free($0) } }
        try check((args + environmentPointers).allSatisfy { $0 != nil }, "parent arguments")
        var argv = args + [nil], env = environmentPointers + [nil]
        let anchor = try argv.withUnsafeMutableBufferPointer { av in try env.withUnsafeMutableBufferPointer { ev in
            try RuntimeFixtureSpawn.spawn(registry: RuntimeFixtureSession.current(), executable: executable,
                actions: &actions, attributes: &attr, arguments: av.baseAddress, environment: ev.baseAddress,
                streamsDrained: { true }, cooperativeStop: { writer.closeNow() })
        } }
        do {
            let owner = try anchor.transfer(expectedExecutable: executable, generation: RunIdentity.make(), reapPolicy: .afterGroupDrain)
            return ParentFixture(anchor: anchor, owner: owner, control: writer)
        } catch {
            writer.closeNow(); RuntimeFixtureSession.drain(anchor); throw error
        }
    }
    private static func parentTerminated(_ parent: ParentFixture) -> Bool {
        if case .reaped = parent.owner.reapAfterGroupDrain(streamsDrained: true) { return true }
        return false
    }
    private static func drainParent(_ parent: ParentFixture) {
        parent.control.closeNow()
        RuntimeFixtureSession.drain(parent.anchor)
    }
    private struct ParentReady {
        let id: String, helper: Int32, target: Int32
        let helperStart: UInt64, targetStart: UInt64
    }
    private static func parentReady(_ root: String) throws -> ParentReady {
        let bytes = try PolicyAuthorityFile.read(path: root + "/worker-ready.json", owner: geteuid(), maximumBytes: 65_536).bytes
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(value.keys) == Set(["request", "helper", "helper_start", "target", "target_start"]),
              let id = value["request"] as? String, RunIdentity.isValid(id),
              let helper = value["helper"] as? Int32, helper > 1,
              let target = value["target"] as? Int32, target > 1,
              let helperStart = value["helper_start"] as? UInt64, helperStart > 0,
              let targetStart = value["target_start"] as? UInt64, targetStart > 0 else {
            throw Failure(message: "parent readiness shape")
        }
        return ParentReady(id: id, helper: helper, target: target, helperStart: helperStart, targetStart: targetStart)
    }
    private static func absent(_ pid: Int32, _ start: UInt64) -> Bool {
        var info = proc_bsdinfo(); errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let error = errno
        return (count == 0 && error == ESRCH)
            || (count == MemoryLayout<proc_bsdinfo>.size && info.pbi_start_tvsec != start)
    }
    private static func orphanSettled(_ location: StateLocation, _ ready: ParentReady) -> Bool {
        guard let bytes = try? CustodyCatalogSelfTests.bytes(location, ready.id + ".json"),
              let journal = try? CustodyJournal.decode(bytes), journal.phase == .terminal,
              journal.binding.requestID == ready.id,
              let custodian = journal.custodian, let target = journal.target,
              custodian.pid == UInt32(ready.helper), custodian.startSeconds == ready.helperStart,
              target.pid == UInt32(ready.target), target.startSeconds == ready.targetStart,
              absent(ready.helper, ready.helperStart), absent(ready.target, ready.targetStart) else { return false }
        // No adoption or signaling of recorded descendants. Their own custodian
        // supplies the terminal journal and releases the original operation lock.
        do { let run = try RunAuthority.acquireRun(at: location); run.release(); return true }
        catch { return false }
    }
    private static func retainOrphanDrain(_ location: StateLocation, _ ready: ParentReady) {
        let diagnostic = MonotonicDeadline(seconds: 6); var reported = false
        while !orphanSettled(location, ready) {
            if diagnostic.hasExpired && !reported {
                fputs("PARENT LOSS CUSTODIAN CLEANUP PENDING\n", stderr); fflush(stderr); reported = true
            }
            usleep(5_000)
        }
    }
    static func parentBounded(mode: String) throws {
        if mode == "before-admission" {
            // No timer has observed this expired control. Admission itself must
            // enforce the monotonic bound before invoking even a trivial body.
            let expired = ParentControl(seconds: 0)
            var admitted = false
            do {
                try expired.admit { admitted = true }
                throw Failure(message: "unobserved deadline admitted work")
            } catch CustodyRecordError.fenced {}
            try check(!admitted && expired.stopped == 93, "deadline admission cause")
        }
        try CustodyRegistrySelfTests.fixture { location, _ in
            let root = location.anchorPath
            let parent = try spawnParent(root, mode: mode)
            defer { drainParent(parent) }
            try check(parent.owner.send(SIGCONT), "bounded parent resume")
            let marker = mode == "pre-ready" ? "/worker-started"
                : (mode == "before-admission" ? "/worker-admission-ready" : "/worker-ready.json")
            try until { FileManager.default.fileExists(atPath: root + marker) || parentTerminated(parent) }
            try check(FileManager.default.fileExists(atPath: root + marker) && !parentTerminated(parent),
                      "bounded parent failed before required readiness")
            if mode != "short-lifetime" { parent.control.closeNow() }
            try until { parentTerminated(parent) }
            let expected: Int32 = mode == "short-lifetime" ? 93 : 94
            try check(parent.owner.observation == .reaped(expected << 8), "bounded parent exit lost cause")
            let catalog = try CustodyCatalog.decode(CustodyCatalogSelfTests.bytes(location, "catalog.json"))
            try check(catalog.entries.isEmpty, "cooperative worker left active helper custody")
            let fresh = try RunAuthority.acquireRun(at: location); fresh.release()
            if mode == "pre-ready" || mode == "before-admission" {
                try check(!FileManager.default.fileExists(atPath: root + "/worker-ready.json"),
                          "pre-readiness EOF admitted a target")
            }
        }
    }
    static func parentLoss() throws {
        var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-registry.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&template) else { throw Failure(message:"parent-loss root") }
        let root = String(cString:raw), location = try StateLocation.isolated(root:root)
        try TestIsolation.initializeState(at: location)
        var original = stat(); try check(lstat(root,&original)==0,"fixture root identity")
        // No defer deletes this root: every failure preserves it and its evidence.
        let authority = try RunAuthority.acquireRun(at:location)
        try CustodyCatalogStore.testingInitialize(leases:authority.retainCommandLeases(),root:root); authority.release()
        let parent = try spawnParent(root)
        var abrupt: ParentReady?
        defer {
            drainParent(parent)
            if let abrupt { retainOrphanDrain(location, abrupt) }
        }
        try check(parent.owner.send(SIGCONT), "parent fixture resume refused")
        try until { FileManager.default.fileExists(atPath: root + "/worker-ready.json") || parentTerminated(parent) }
        guard !parentTerminated(parent) else { throw Failure(message: "parent exited before target readiness: \(parent.owner.observation)") }
        let ready = try parentReady(root)
        let id = ready.id, helperPID = ready.helper, targetPID = ready.target
        let helperStart = ready.helperStart, targetStart = ready.targetStart
        // Abrupt caller death is permitted only after this exact ready receipt.
        try check(parent.owner.send(SIGTERM), "ready parent termination refused")
        abrupt = ready
        try until { parentTerminated(parent) }
        guard case .reaped(let rawStatus) = parent.owner.observation else { throw Failure(message: "parent not reaped") }
        try check(rawStatus & 0x7f == SIGTERM, "parent fixture did not lose its caller process")
        // The caller is gone while the TERM-resistant child is still draining.
        // A fresh contender must see the same effective operation exclusion.
        try until {
            guard let data = try? CustodyCatalogSelfTests.bytes(location,id+".json"),
                  let value = try? CustodyJournal.decode(data) else { return false }
            return value.phase == .draining || value.phase == .terminal
        }
        let draining = try CustodyJournal.decode(CustodyCatalogSelfTests.bytes(location,id+".json"))
        try check(draining.phase == .draining,"caller-loss lock probe missed drainage")
        var lockNode = stat()
        guard lstat(location.path+"/operation.lock",&lockNode)==0,
              let inheritedLock = draining.leases.first(where:{ $0.role == .operation }) else { throw Failure(message:"operation lease evidence missing") }
        try check(inheritedLock.device == FileIdentity(lockNode).device && inheritedLock.inode == FileIdentity(lockNode).inode,"operation lock inode changed after caller loss")
        do {
            let unexpected = try RunAuthority.acquireRun(at:location); unexpected.release()
            throw Failure(message:"operation exclusion lost after caller death")
        } catch SecureStateError.contention(let name) { try check(name == "operation.lock","unexpected lock contention") }
        try until {
            guard let data = try? CustodyCatalogSelfTests.bytes(location,id+".json"), let journal = try? CustodyJournal.decode(data) else { return false }
            return journal.phase == .terminal
        }
        let journal = try CustodyJournal.decode(CustodyCatalogSelfTests.bytes(location,id+".json"))
        try check(journal.outcome == .cancelledDrained && journal.reason == .cancelled && journal.waitStatus == UInt32(SIGKILL),"parent loss did not automatically drain resistant target")
        // Read-only absence of these fixture identities supplements terminal
        // proof. No successor adopts/signals/reaps a recorded helper or target.
        try until { absent(helperPID,helperStart) && absent(targetPID,targetStart) }
        let fresh = try RunAuthority.acquireRun(at:location); fresh.release()
        try check(!FileManager.default.fileExists(atPath:location.path+"/custody/receipts/"+id+".caller.json"),"successor fabricated caller reaping")
        var current = stat(); try check(lstat(root,&current)==0 && current.st_dev == original.st_dev && current.st_ino == original.st_ino,"fixture root replaced")
        retainOrphanDrain(location, ready)
        abrupt = nil
        try FileManager.default.removeItem(atPath:root)
    }
}


enum StrictStateAdmissionSelfTests {
    private struct Failure: Error { let reason: String }
    private static let files = ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock"]
    private static func check(_ value: Bool, _ reason: String) throws {
        if !value { throw Failure(reason: reason) }
    }
    private static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch is SecureStateError { return }
        throw Failure(reason: "ordinary state admission unexpectedly succeeded")
    }
    private static func fixture(initialized: Bool = true, _ body: (StateLocation) throws -> Void) throws {
        var pattern = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-state-admission.") + "XXXXXX").utf8CString)
        guard let raw = mkdtemp(&pattern) else { throw Failure(reason: "fixture creation") }
        let root = String(cString: raw), location = try StateLocation.isolated(root: root)
        var before = stat(); try check(lstat(root, &before) == 0, "fixture identity")
        defer {
            var after = stat()
            if lstat(root, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino {
                try? FileManager.default.removeItem(atPath: root)
            }
        }
        if initialized { try TestIsolation.initializeState(at: location) }
        try body(location)
    }
    private static func allRefuse(_ location: StateLocation) throws {
        try refuses { let value = try RunAuthority.acquireRun(at: location); value.release() }
        try refuses { let value = try RunAuthority.acquireLifecycleMutation(at: location); value.release() }
        try refuses { let value = try LauncherAuthority.acquire(at: location); value.release() }
    }
    private static func node(_ path: String) throws -> FileIdentity {
        var info = stat(); try check(lstat(path, &info) == 0, "missing fixture identity"); return FileIdentity(info)
    }
    static func missingState() throws {
        try fixture(initialized: false) { location in
            try refuses { _ = try SecureStateDirectory.open(location) }
            try allRefuse(location)
            try check(try FileManager.default.contentsOfDirectory(atPath: location.anchorPath).isEmpty, "ordinary startup created state")
        }
    }
    static func missingControls() throws {
        for name in files {
            try fixture { location in
                let path = location.path + "/" + name
                try check(unlink(path) == 0, "remove fixture control")
                let before = try FileManager.default.contentsOfDirectory(atPath: location.path).sorted()
                try allRefuse(location)
                try check(try FileManager.default.contentsOfDirectory(atPath: location.path).sorted() == before, "missing control recreated")
            }
        }
    }
    static func permissions() throws {
        for name in [""] + files {
            let modes: [mode_t] = name.isEmpty ? [0o755, 0o500, 0o1700, 0o2700] : [0o644, 0o700, 0o400, 0o1600, 0o2600]
            for mode in modes {
                try fixture { location in
                    let path = location.path + (name.isEmpty ? "" : "/" + name)
                    // Darwin inherits the temporary parent's group. A caller
                    // outside that group can have setgid silently cleared by
                    // chmod; establish an owned group before testing that bit.
                    try check(chown(path, uid_t.max, getegid()) == 0, "fixture group")
                    try check(chmod(path, mode) == 0, "fixture mode")
                    defer { _ = chmod(path, name.isEmpty ? 0o700 : 0o600) }
                    var configured = stat()
                    try check(lstat(path, &configured) == 0 && configured.st_mode & 0o7777 == mode,
                        "requested fixture mode was not established")
                    let before = try node(path)
                    try allRefuse(location)
                    try check(try node(path) == before, "ordinary startup repaired permissions")
                }
            }
        }
    }
    static func unsafeControls() throws {
        for kind in ["symlink", "hardlink", "fifo"] {
            try fixture { location in
                let path = location.path + "/latest.log", original = location.path + "/preserved.log"
                try check(rename(path, original) == 0, "preserve original fixture log")
                switch kind {
                case "symlink": try check(symlink("preserved.log", path) == 0, "symlink fixture")
                case "hardlink": try check(link(original, path) == 0, "hardlink fixture")
                default: try check(mkfifo(path, 0o600) == 0, "fifo fixture")
                }
                let before = try node(path), retained = try node(original)
                try allRefuse(location)
                try check(try node(path) == before && node(original) == retained, "unsafe control changed")
            }
        }
    }
    static func retainedLease() throws {
        try fixture { location in
            let authority = try RunAuthority.acquireRun(at: location)
            let lease = try authority.duplicateOperationLease(); defer { close(lease) }
            authority.release()
            let path = location.path + "/operation.lock", saved = location.path + "/retained-operation.lock"
            try check(rename(path, saved) == 0, "retained fixture name")
            let before = try node(saved)
            try allRefuse(location)
            var absent = stat(); try check(lstat(path, &absent) != 0 && errno == ENOENT, "split operation lock created")
            let contender = open(saved, O_RDWR | O_NOFOLLOW | O_CLOEXEC); try check(contender >= 0, "retained lock probe")
            defer { close(contender) }
            let result = flock(contender, LOCK_EX | LOCK_NB), code = errno
            try check(result == -1 && code == EWOULDBLOCK && (try node(saved)) == before, "original lease lost exclusion")
        }
    }
    private static func makeWriter(_ batch: Bool, authority: RunAuthority) throws {
        let run = RunIdentity.make()
        if batch {
            let node = try Body3BatchNode(id: "body3-node:policyInvalidation:" + String(run.prefix(12)),
                repositoryID: "fixture/state", commonDirectoryKey: "clone:state", kind: .policyInvalidation,
                dependencies: [], payload: .policyInvalidation(repositoryID: "fixture/state"), requiresExclusiveWorkerPool: true)
            let plan = try Body3BatchPlan(run: run, policyEvidenceDigest: String(repeating: "a", count: 64), nodes: [node])
            let writer = try Body3RunLogWriter(authority: authority, plan: plan)
            try writer.flush()
        } else {
            let writer = try RunLogWriter(authority: authority, runID: run)
            _ = try writer.append(type: "fixture", data: "initialized writer")
            try writer.flush()
        }
    }
    private static func logRefusal(_ alteration: String) throws {
        for batch in [false, true] {
            try fixture { location in
                let path = location.path + "/latest.log", saved = location.path + "/retained.log"
                let bytes = Data("preserve original log\n".utf8)
                try bytes.write(to: URL(fileURLWithPath: path))
                let authority = try RunAuthority.acquireRun(at: location); defer { authority.release() }
                if alteration == "missing" || alteration == "replaced" {
                    try check(rename(path, saved) == 0, "preserve retained log")
                    if alteration == "replaced" {
                        let replacement = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                        try check(replacement >= 0, "replacement log fixture"); close(replacement)
                        try Data("preserve replacement\n".utf8).write(to: URL(fileURLWithPath: path))
                    }
                } else if alteration == "mode" {
                    try check(chmod(path, 0o700) == 0, "log mode fixture")
                } else {
                    authority.release()
                }
                let names = try FileManager.default.contentsOfDirectory(atPath: location.path).sorted()
                let logName = alteration == "missing" || alteration == "replaced" ? saved : path
                let retained = try node(logName)
                let replacement = alteration == "replaced" ? try node(path) : nil
                try refuses { try makeWriter(batch, authority: authority) }
                try check(try FileManager.default.contentsOfDirectory(atPath: location.path).sorted() == names, "writer created missing log")
                try check(try node(logName) == retained && Data(contentsOf: URL(fileURLWithPath: logName)) == bytes,
                    "writer changed retained log")
                if let replacement {
                    try check(try node(path) == replacement && Data(contentsOf: URL(fileURLWithPath: path)) == Data("preserve replacement\n".utf8),
                        "writer changed replacement log")
                }
            }
        }
    }
    static func missingLogWriter() throws { try logRefusal("missing") }
    static func replacedLogWriter() throws { try logRefusal("replaced") }
    static func modeLogWriter() throws { try logRefusal("mode") }
    static func closedLogWriter() throws { try logRefusal("closed") }
    static func existingLogWriter() throws {
        for batch in [false, true] {
            try fixture { location in
                let path = location.path + "/latest.log", before = try node(path)
                let authority = try RunAuthority.acquireRun(at: location); defer { authority.release() }
                try makeWriter(batch, authority: authority)
                try check(try node(path) == before && !Data(contentsOf: URL(fileURLWithPath: path)).isEmpty,
                    "writer did not use original log")
            }
        }
    }
    static func existingState() throws {
        try fixture { location in
            let before = try files.map { try node(location.path + "/" + $0) }
            let log = location.path + "/latest.log", bytes = Data("preserved log\n".utf8)
            try bytes.write(to: URL(fileURLWithPath: log))
            let run = try RunAuthority.acquireRun(at: location); run.release()
            let lifecycle = try RunAuthority.acquireLifecycleMutation(at: location); lifecycle.release()
            let launcher = try LauncherAuthority.acquire(at: location); launcher.release()
            try check(try files.map { try node(location.path + "/" + $0) } == before, "ordinary admission replaced control inode")
            try check(try Data(contentsOf: URL(fileURLWithPath: log)) == bytes, "ordinary admission changed log")
        }
    }
}

private enum SystemConfigCommandSelfTests {
    // Closed, testing-only phase markers for the hosted planner crash. No path,
    // metadata, error description or observed value enters diagnostic output.
    private enum PlannerCheckpoint: String {
        case beforeFreeze, afterFreeze, beforeObserver, beforeInspect
        case observerCalled, dryRun, referenceProof, beforePending, returned, caughtPending
        func record() {
            guard ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_M6_DIAGNOSTICS"] == "1" else { return }
            fputs("M6 PLANNER CHECKPOINT \(rawValue)\n", stderr); fflush(stderr)
        }
    }
    private struct Failure: Error { let message: String }
    private enum BodyFailure: Error { case unrelated }
    private final class RegistrationObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func configurationCapture(_ scenario: String) throws {
        // These cases execute the real capture/recapture/file-verification
        // callers. Only system-origin discovery is injected; signed command
        // qualification is a separate gate. Refuse unnamespaced execution.
        let prefix = try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.")
        try check(prefix != "/private/tmp/shadow-sync-fixture-config."
            && !prefix.hasPrefix("/private/tmp/shadow-sync-config."),
            "capture fixture requires a distinct namespaced prefix")
        func snapshots() throws -> [String] {
            let name = URL(fileURLWithPath: prefix).lastPathComponent
            return try FileManager.default.contentsOfDirectory(atPath: "/private/tmp")
                .filter { $0.hasPrefix(name) }.sorted()
        }
        let before = try snapshots()
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try CustodyContextSelfTests.read(location)
            defer { context.close() }
            let root = location.anchorPath
            let home = root + "/home"
            let repository = (scenario.hasPrefix("discovery-") ? home : root) + "/repository"
            func directory(_ path: String) throws {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            func write(_ path: String, _ value: String) throws {
                try Data(value.utf8).write(to: URL(fileURLWithPath: path))
                try check(chmod(path, 0o600) == 0, "capture fixture file mode")
            }
            try directory(repository + "/.git/objects/info")
            try directory(repository + "/.git/refs/heads")
            try directory(home + "/.config/git")
            try directory(root + "/other-home")
            let origin = "https://github.com/fixture-owner/config-caller.git"
            let local = repository + "/.git/config"
            try write(local, "[core]\nrepositoryformatversion = 0\nbare = false\n[remote \"origin\"]\nurl = \(origin)\n")
            try write(repository + "/.git/HEAD", "ref: refs/heads/main\n")
            let system = root + "/system-config", alternate = root + "/alternate-system-config"
            let xdg = home + "/.config/git/config", global = home + "/.gitconfig"
            let systemBytes = "[fixture]\nsystem = first\n"
            let xdgBytes = "[fixture]\nxdg = second\n", globalBytes = "[fixture]\nuser = third\n"
            try write(system, systemBytes); try write(alternate, systemBytes)
            try write(xdg, xdgBytes); try write(global, globalBytes)
            let account = try EffectiveAccount.isolated(homeDirectory: home)
            let candidate = try RepositoryHandle.testingBoundCandidate(path: repository,
                id: "fixture-owner/config-caller", displayName: "Config caller", rawOrigin: origin)
            let handle = try RepositoryHandle.open(candidate)
            let token = CancellationToken()
            let absent = scenario == "absent" || scenario == "child-absent"
                || scenario == "captured-absent" || scenario == "captured-snapshot-absent"
            var calls = 0, selected: String? = absent ? nil : system
            let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: token) {
                calls += 1
                let pendingInspection = scenario.hasPrefix("inspection-")
                    && !["inspection-closed", "inspection-cancel", "inspection-fallback", "inspection-worktree", "inspection-planner-pending", "inspection-planner-ordinary"].contains(scenario)
                if scenario == "pending" || pendingInspection || (["inspection-worktree", "inspection-planner-pending"].contains(scenario) && calls > 1) {
                    throw SystemGitConfigurationError.cleanupPending
                }
                return selected
            }
            func exercise() throws {
                if scenario.hasPrefix("captured-") {
                    try GitConfigurationValidationTesting.$forbidRawProbe.withValue(true) {
                        let preflight = try GitConfigurationPreflight.testing(systemPath: selected, account: account)
                        if scenario.hasPrefix("captured-snapshot") {
                            // The old allocator supplies a held file for this capture-only
                            // test. Helper-owned creation/retirement is qualified separately.
                            let frozen = try handle.freezeConfiguration(account: account, configurationProbe: probe)
                            try check(calls == 1, "fixture did not establish one original preflight")
                            if scenario == "captured-snapshot-sources" {
                                let other = try GitConfigurationPreflight.testing(systemPath: alternate, account: account)
                                try FileManager.default.removeItem(atPath: local)
                                do {
                                    _ = try handle.executionSnapshot(account: account, configuration: frozen.snapshot,
                                        admission: nil, configurationPreflight: other)
                                    throw Failure(message: "unbound source set reached configuration recapture")
                                } catch SystemGitConfigurationError.unavailable {}
                            } else if scenario == "captured-snapshot-drift" {
                                try write(global, "[fixture]\nuser = changed\n")
                                do {
                                    _ = try handle.executionSnapshot(account: account, configuration: frozen.snapshot,
                                        admission: nil, configurationPreflight: preflight)
                                    throw Failure(message: "changed configuration accepted in captured snapshot")
                                } catch GitSafetyError.unsafeRepository {}
                            } else {
                                let snapshot = try handle.executionSnapshot(account: account, configuration: frozen.snapshot,
                                    admission: nil, configurationPreflight: preflight)
                                try preflight.validate(snapshot, account: account)
                                try check(snapshot.configuration == frozen.snapshot && snapshot.repository == handle.identity,
                                          "captured snapshot lost frozen or repository identity")
                                let rootFD = open(repository, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                                try check(rootFD >= 0, "captured snapshot retained fixture root")
                                defer { close(rootFD) }
                                let cwd = FileManager.default.currentDirectoryPath
                                try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account,
                                    configurationPreflight: preflight, rootDescriptor: rootFD)
                                try check(FileManager.default.currentDirectoryPath == cwd,
                                          "captured snapshot changed process cwd")
                            }
                            try check(calls == 1, "captured snapshot repeated the system probe")
                            return
                        }
                        if scenario == "captured-account" {
                            let other = try EffectiveAccount.isolated(homeDirectory: root + "/other-home")
                            try FileManager.default.removeItem(atPath: local)
                            do {
                                _ = try handle.captureConfiguration(account: other, configurationPreflight: preflight)
                                throw Failure(message: "wrong account reached configuration capture")
                            } catch SystemGitConfigurationError.unavailable {}
                        } else if scenario == "captured-include" {
                            try write(global, "[include]\npath = \(root)/must-not-read\n")
                            do {
                                _ = try handle.captureConfiguration(account: account, configurationPreflight: preflight)
                                throw Failure(message: "captured configuration accepted an include")
                            } catch GitSafetyError.malformedConfig {}
                        } else if scenario == "captured-alias" {
                            try FileManager.default.removeItem(atPath: xdg)
                            try check(symlink(alternate, xdg) == 0, "create contributor alias fixture")
                            do {
                                _ = try handle.captureConfiguration(account: account, configurationPreflight: preflight)
                                throw Failure(message: "captured configuration traversed an alias")
                            } catch GitSafetyError.unsafeRepository {}
                        } else {
                            // A legacy-shaped but deliberately unsealed sibling would
                            // make the old broad recovery routine fail. This path must
                            // neither inspect nor remove it. It belongs only to this test.
                            let sibling = prefix + "NoSwEp"
                            var siblingIdentity: FileIdentity?
                            if scenario == "captured-no-sweep" {
                                try check(mkdir(sibling, 0o700) == 0, "create owned sibling sentinel")
                                var info = stat()
                                try check(lstat(sibling, &info) == 0, "stat owned sibling sentinel")
                                siblingIdentity = FileIdentity(info)
                            }
                            let result = Result<Void, Error> {
                                let captured = try handle.captureConfiguration(account: account, configurationPreflight: preflight)
                                let expected = (absent ? "" : systemBytes) + xdgBytes + globalBytes
                                try check(captured.bytes == Data(expected.utf8), "captured configuration changed ordered bytes")
                                try check(captured.contributors.map(\.path) == preflight.paths,
                                          "capture ignored explicit preflight sources")
                                try check(captured.repositoryConfig.path == ".git/config", "capture lost local binding")
                            }
                            if let siblingIdentity {
                                var info = stat()
                                try check(lstat(sibling, &info) == 0 && FileIdentity(info) == siblingIdentity,
                                          "capture touched sibling sentinel")
                                try check(rmdir(sibling) == 0, "owned sibling sentinel cleanup failed")
                            }
                            try result.get()
                        }
                        try check(calls == 0, "captured configuration started a system probe")
                    }
                    return
                }
                if scenario.hasPrefix("inspection-") {
                    let session = RepositoryReadSession(executablePath: "/fixture-unreachable",
                        leaseDescriptor: -1, account: account, runner: DescriptorProcessRunner(),
                        capturedNow: Date(), cancellation: token, transportMapping: nil,
                        configurationProbe: probe)
                    let clone = try LocalClone(repositoryID: candidate.id, sourceSnapshot: candidate,
                        effectiveOrigin: origin, originParityVerified: true, policyCategory: .writable,
                        kind: .primaryCheckout, worktrees: [], branches: [], warnings: [])
                    let remote = try RemoteRepository(id: candidate.id, origins: [origin], policyCategory: .writable,
                        resolvedDefault: RemoteDefaultBranch(name: "main", advertisedOID: String(repeating: "a", count: 40)),
                        defaultUnavailableReason: nil)
                    if scenario == "inspection-closed" || scenario == "inspection-cancel" {
                        if scenario == "inspection-closed" { context.close() } else { token.closeFutureChildAdmissions() }
                        // Invalid phase must beat the now-missing config before repository opening.
                        try FileManager.default.removeItem(atPath: local)
                        do {
                            _ = try session.prepareTopLevel(clone: clone, remote: remote)
                            throw Failure(message: "inspection opened with closed authority")
                        } catch SystemGitConfigurationError.unavailable {}
                        try check(calls == 0, "closed inspection reached resolver")
                        return
                    }
                    if scenario == "inspection-fallback" {
                        try FileManager.default.removeItem(atPath: local)
                        let observed = try session.prepareTopLevel(clone: clone, remote: remote)
                        try check(observed == clone && calls == 0 && !context.isClosed,
                                  "ordinary unavailable repository fallback changed")
                        return
                    }
                    if scenario == "inspection-planner-pending" || scenario == "inspection-planner-ordinary" {
                        PlannerCheckpoint.beforeFreeze.record()
                        let frozen = try handle.freezeConfiguration(account: account, configurationProbe: probe)
                        PlannerCheckpoint.afterFreeze.record()
                        let admission = GitAdmissionSnapshot(effectiveURL: origin, transport: handle.githubIdentity.transport,
                            frozenConfigSHA256: frozen.snapshot.frozenSHA256)
                        let oid = String(repeating: "a", count: 40)
                        try directory(home + "/absent-worktrees")
                        let identifiers = ["first", "second"]
                        for identifier in identifiers {
                            let registration = repository + "/.git/worktrees/" + identifier
                            try directory(registration)
                            try write(registration + "/gitdir", home + "/absent-worktrees/" + identifier + "/.git\n")
                            try write(registration + "/HEAD", "ref: refs/heads/" + identifier + "\n")
                            try write(registration + "/commondir", "../..\n")
                        }
                        let branches = try identifiers.map {
                            try Branch(cloneID: clone.id, fullRef: "refs/heads/" + $0,
                                tipOID: oid, claimingWorktreeIDs: [])
                        }
                        let maintenanceClone = try LocalClone(repositoryID: candidate.id, sourceSnapshot: candidate,
                            effectiveOrigin: origin, originParityVerified: true, policyCategory: .writable,
                            kind: .primaryCheckout, worktrees: [], branches: branches, warnings: [])
                        let observed = RegistrationObservations()
                        var commands = 0
                        do {
                            PlannerCheckpoint.beforeObserver.record()
                            PlannerCheckpoint.beforeInspect.record()
                            let draft = try RepositoryMaintenancePlanner.testingInspectRegistrations(clone: maintenanceClone, remote: remote,
                                account: account, handle: handle, frozen: frozen, admission: admission,
                                capturedNow: Date(), validateAdmission: session.validatePhaseCompletion,
                                observeRegistration: {
                                    PlannerCheckpoint.observerCalled.record(); observed.record($0)
                                }) {
                                arguments, _, _, _, _ in
                                commands += 1
                                if commands == 1 {
                                    PlannerCheckpoint.dryRun.record()
                                    try check(arguments.contains("--dry-run"), "planner did not begin with dry-run")
                                    return ProcessResult(status: 0,
                                        stdout: Data("Removing worktrees/first: fixture\nRemoving worktrees/second: fixture\n".utf8),
                                        stderr: Data(), stdoutTruncated: false, stderrTruncated: false,
                                        outputByteLimit: 4096, timedOut: false, cancelled: false,
                                        terminationRequested: false, processID: -1)
                                }
                                PlannerCheckpoint.referenceProof.record()
                                try check(arguments.contains("rev-parse"), "unexpected planner command")
                                if scenario == "inspection-planner-pending" {
                                    PlannerCheckpoint.beforePending.record()
                                    _ = try probe.activePath(account: account)
                                }
                                return ProcessResult(status: 1, stdout: Data(), stderr: Data(),
                                    stdoutTruncated: false, stderrTruncated: false, outputByteLimit: 4096,
                                    timedOut: false, cancelled: false, terminationRequested: false, processID: -1)
                            }
                            PlannerCheckpoint.returned.record()
                            try check(scenario == "inspection-planner-ordinary", "planner swallowed pending cleanup")
                            try check(observed.snapshot == identifiers && commands == 3 && calls == 1,
                                      "ordinary proof refusal stopped unrelated registration inspection")
                            try check(draft.prunable.isEmpty && draft.moved.isEmpty && draft.diagnostics.count == 2
                                && !draft.refusals.isEmpty && !context.isClosed, "ordinary planner warnings changed")
                        } catch SystemGitConfigurationError.cleanupPending {
                            PlannerCheckpoint.caughtPending.record()
                            try check(scenario == "inspection-planner-pending" && observed.snapshot == ["first"]
                                && commands == 2 && calls == 2 && context.isClosed && token.areFutureChildAdmissionsClosed,
                                "planner accessed a later registration after pending cleanup")
                        }
                        try check(registry.testingCount == 0, "planner fixture spawned a real command")
                        return
                    }
                    do {
                        switch scenario {
                        case "inspection-top": _ = try session.prepareTopLevel(clone: clone, remote: remote)
                        case "inspection-cleanup": _ = try session.inspectCleanup(clone: clone, remote: remote, queryPullRequests: false)
                        case "inspection-enrich": _ = try session.enrichLifecycle(clone: clone, remote: remote, queryPullRequests: false)
                        case "inspection-maintenance": _ = try session.maintenanceOperations(clone: clone, remote: remote, capability: nil)
                        case "inspection-origin": _ = try session.originHeadExplanation(clone: clone, remote: remote)
                        case "inspection-worktree":
                            let frozen = try handle.freezeConfiguration(account: account, configurationProbe: probe)
                            let worktree = try Worktree(id: "worktree:phase-fixture", cloneID: clone.id,
                                path: repository, rootIdentity: candidate.rootIdentity, registrationIdentity: nil,
                                attachedBranchRef: "refs/heads/main", detachedOID: nil, isPrimary: true,
                                locationKind: .canonicalPrimary)
                            let admission = GitAdmissionSnapshot(effectiveURL: origin,
                                transport: handle.githubIdentity.transport, frozenConfigSHA256: frozen.snapshot.frozenSHA256)
                            _ = try session.testingWorktreePhaseRefusal(candidate: candidate, worktree: worktree,
                                frozen: frozen, admission: admission)
                        default: throw Failure(message: "unknown inspection case")
                        }
                        throw Failure(message: "inspection swallowed pending authority")
                    } catch SystemGitConfigurationError.cleanupPending {}
                    try check(calls == (scenario == "inspection-worktree" ? 2 : 1)
                        && context.isClosed && token.areFutureChildAdmissionsClosed,
                        "inspection lost pending authority fence")
                    try check(registry.testingCount == 0, "inspection started unqualified child")
                    return
                }
                if scenario == "closed" || scenario == "account" {
                    if scenario == "closed" { context.close() }
                    let requested = scenario == "account"
                        ? try EffectiveAccount.isolated(homeDirectory: root + "/other-home") : account
                    // The typed phase/account refusal must win over a now
                    // unavailable repository config, before capture touches it.
                    try FileManager.default.removeItem(atPath: local)
                    do {
                        _ = try handle.freezeConfiguration(account: requested, configurationProbe: probe)
                        throw Failure(message: "invalid capture authority accepted")
                    } catch SystemGitConfigurationError.unavailable {}
                    try check(calls == 0, "invalid authority reached configuration probe")
                    return
                }
                if scenario == "include" {
                    try write(global, "[include]\npath = \(root)/must-not-read\n")
                    do {
                        _ = try handle.freezeConfiguration(account: account, configurationProbe: probe)
                        throw Failure(message: "configuration include accepted")
                    } catch GitSafetyError.malformedConfig(let message) {
                        try check(message == "Git config includes are unsupported in M1", "wrong include refusal")
                    }
                    try check(calls == 1, "include refusal probe count")
                    return
                }
                if scenario == "pending" {
                    do {
                        _ = try handle.freezeConfiguration(account: account, configurationProbe: probe)
                        throw Failure(message: "pending capture accepted")
                    } catch SystemGitConfigurationError.cleanupPending {}
                    try check(calls == 1 && context.isClosed && token.areFutureChildAdmissionsClosed,
                              "capture lost pending authority fence")
                    return
                }
                var frozen: FrozenGitConfiguration? = try handle.freezeConfiguration(account: account, configurationProbe: probe)
                defer { frozen = nil }
                let expectedPaths = (absent ? [] : [system]) + [xdg, global]
                try check(frozen!.snapshot.contributors.map(\.path) == expectedPaths, "configuration contributor order changed")
                let expectedBytes = (absent ? "" : systemBytes) + xdgBytes + globalBytes
                try check(try Data(contentsOf: URL(fileURLWithPath: frozen!.snapshot.frozenPath)) == Data(expectedBytes.utf8),
                          "frozen configuration bytes differ")
                try check(frozen!.snapshot.frozenDirectoryPath.hasPrefix(prefix), "snapshot escaped fixture namespace")
                if scenario.hasPrefix("custody-") {
                    try frozenCustody(scenario, frozen: &frozen, context: context,
                        registry: registry, account: account)
                    return
                }
                if scenario == "origin" {
                    selected = alternate
                    do {
                        _ = try handle.executionSnapshot(account: account, frozenConfiguration: frozen!, admission: nil, configurationProbe: probe)
                        throw Failure(message: "changed system origin accepted")
                    } catch GitSafetyError.unsafeRepository {}
                    try check(calls == 2, "changed origin did not re-probe")
                    return
                }
                let snapshot = try handle.executionSnapshot(account: account, frozenConfiguration: frozen!, admission: nil, configurationProbe: probe)
                if scenario.hasPrefix("discovery-") {
                    // A data-only production-shaped request. The fake frozen
                    // namespace is never opened and grants no fixture authority.
                    let original = DiscoveryCustodyInput(policyCommitment: String(repeating: "a", count: 64), snapshot: snapshot)
                    var object = try JSONSerialization.jsonObject(with: original.encode()) as! [String: Any]
                    var encodedSnapshot = object["snapshot"] as! [String: Any]
                    var config = encodedSnapshot["configuration"] as! [String: Any]
                    let fake = "/private/tmp/shadow-sync-config." + UUID().uuidString
                    config["frozenDirectoryPath"] = fake; config["frozenPath"] = fake + "/config"
                    encodedSnapshot["configuration"] = config; object["snapshot"] = encodedSnapshot
                    func bytes(_ value: [String: Any]) throws -> Data {
                        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                    }
                    let input = try DiscoveryCustodyInput.decode(bytes(object))
                    try input.validate(account: account, parent: getpid())
                    if scenario == "discovery-input-refusals" {
                        // The new depth allowance is local to this wire shape.
                        // Ordinary policy/configuration limits remain unchanged.
                        let depthSeven = Data((String(repeating: "[", count: 7) + "0" + String(repeating: "]", count: 7)).utf8)
                        var dedicated = try PolicyWireParser(depthSeven, profile: .discoveryCustody)
                        _ = try dedicated.parse()
                        for profile in [PolicyWireParser.Profile.wire, .configuration, .bundleLayout] {
                            do {
                                var bounded = try PolicyWireParser(depthSeven, profile: profile)
                                _ = try bounded.parse(); throw Failure(message: "existing parser depth widened")
                            } catch PolicyProtocolError.invalidResponse {}
                        }
                        let invalid = [
                            String(repeating: "[", count: 8) + "0" + String(repeating: "]", count: 8),
                            "{\"key\":0,\"key\":1}",
                            "[" + Array(repeating: "0", count: 65).joined(separator: ",") + "]",
                            "\"" + String(repeating: "a", count: 16_385) + "\""
                        ]
                        for text in invalid {
                            do {
                                var bounded = try PolicyWireParser(Data(text.utf8), profile: .discoveryCustody)
                                _ = try bounded.parse(); throw Failure(message: "discovery parser bound accepted invalid input")
                            } catch PolicyProtocolError.invalidResponse {}
                        }
                        var malformed = object; malformed["unrecognized"] = 1
                        do { _ = try DiscoveryCustodyInput.decode(bytes(malformed)); throw Failure(message: "unknown discovery wire key accepted") }
                        catch CustodyResourceError.invalidResource {}
                        var linked = encodedSnapshot, identity = linked["repository"] as! [String: Any]
                        identity["commonDirectoryPath"] = root + "/another/.git"; linked["repository"] = identity
                        var request = object; request["snapshot"] = linked
                        do { try DiscoveryCustodyInput.decode(bytes(request)).validate(account: account, parent: getpid()); throw Failure(message: "unadmitted linked discovery accepted") }
                        catch CustodyResourceError.invalidResource {}
                        do { try input.validate(account: account, parent: getpid() + 1); throw Failure(message: "foreign frozen cleanup owner accepted") }
                        catch CustodyResourceError.invalidResource {}
                        do { try input.validate(account: EffectiveAccount.isolated(homeDirectory: root + "/other-home"), parent: getpid()); throw Failure(message: "foreign discovery account accepted") }
                        catch CustodyResourceError.invalidResource {}
                    } else if scenario == "discovery-resource-roster" {
                        let preflight = try probe.capturePreflight(account: account)
                        let plan = try ConfigurationPolicyPlan(preflight: preflight, account: account, discovery: input)
                        let paths = plan.batches.flatMap { $0 }
                        for leaf in [repository + "/.git/refs/replace", repository + "/.git/info/grafts",
                                     repository + "/.git/objects/info/alternates", fake + "/config", xdg, global] {
                            let parts = leaf.split(separator: "/", omittingEmptySubsequences: false)
                            for end in 2...parts.count { try check(paths.contains(parts.prefix(end).joined(separator: "/")), "discovery resource ancestor omitted") }
                        }
                        try check(Set(paths.map { Data($0.utf8) }).count == paths.count && !paths.contains("/"), "discovery resource duplicate or root")
                    } else { try check(try input.encode() == bytes(object), "canonical discovery input changed") }
                    try check(registry.testingCount == 0, "wire fixture spawned production discovery")
                    return
                }
                if scenario.hasPrefix("child-") {
                    if scenario == "child-origin" { selected = alternate }
                    let preflight = try probe.capturePreflight(account: account)
                    if scenario.hasPrefix("child-retained-root") || scenario.hasPrefix("child-no-follow-") {
                        let fd = open(scenario == "child-retained-root-wrong" ? home : repository,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        try check(fd >= 0, "retained root fixture open"); defer { close(fd) }
                        let beforeCWD = FileManager.default.currentDirectoryPath
                        if scenario.hasPrefix("child-no-follow-") {
                            let relative = scenario == "child-no-follow-refs" ? ".git/refs"
                                : scenario == "child-no-follow-info" ? ".git/info"
                                : scenario == "child-no-follow-objects-info" ? ".git/objects/info" : ""
                            let path = relative.isEmpty ? home + "/.config" : repository + "/" + relative
                            if FileManager.default.fileExists(atPath: path) { try FileManager.default.moveItem(atPath: path, toPath: path + ".preserved") }
                            let denied = root + "/protected-target"
                            try directory(denied)
                            try check(symlink(denied, path) == 0, "intermediate alias fixture")
                        }
                        try GitConfigurationValidationTesting.$forbidRawProbe.withValue(true) {
                            do {
                                try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account,
                                    configurationPreflight: preflight, rootDescriptor: fd)
                                try check(scenario == "child-retained-root", "unsafe retained metadata accepted")
                            } catch GitSafetyError.unsafeRepository(let message) {
                                if scenario == "child-retained-root-wrong" {
                                    try check(message == "child worktree identity changed", "wrong root did not refuse before marker access")
                                } else {
                                    try check(scenario.hasPrefix("child-no-follow-")
                                        && message == "cannot traverse Git resource without following links",
                                        "alias was followed or refused after target lookup")
                                }
                            }
                        }
                        try check(FileManager.default.currentDirectoryPath == beforeCWD && calls == 3,
                            "descriptor validation changed cwd or launched a raw preflight")
                        return
                    }
                    let savedDirectory = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    try check(savedDirectory >= 0, "child fixture could not retain original cwd")
                    defer { _ = fchdir(savedDirectory); close(savedDirectory) }
                    try check(chdir(repository) == 0, "child fixture could not bind repository cwd")
                    switch scenario {
                    case "child-account", "child-origin":
                        // These refusals must precede any common-directory open.
                        try FileManager.default.removeItem(atPath: local)
                    case "child-contributor": try write(global, "[fixture]\nuser = changed\n")
                    case "child-replacement":
                        try FileManager.default.moveItem(atPath: global, toPath: global + ".previous")
                        try write(global, globalBytes)
                    case "child-local": try write(local, "[core]\nbare = false\n[remote \"origin\"]\nurl = \(origin)\n")
                    case "child-packed":
                        try write(repository + "/.git/packed-refs", "# pack-refs with: peeled fully-peeled sorted\n" + String(repeating: "a", count: 40) + " refs/heads/main\n")
                    default: break
                    }
                    let requested = scenario == "child-account"
                        ? try EffectiveAccount.isolated(homeDirectory: root + "/other-home") : account
                    try GitConfigurationValidationTesting.$forbidRawProbe.withValue(true) {
                        // Prove the guard is active, rather than merely relying
                        // on source inspection to claim no external preflight.
                        if scenario == "child-roundtrip" || scenario == "child-absent" {
                            do {
                                try RepositoryHandle.validateCommonExecutionSnapshot(snapshot, account: account)
                                throw Failure(message: "raw configuration guard was inactive")
                            } catch GitSafetyError.unsafeRepository(let message) {
                                try check(message == "raw configuration probe forbidden by fixture", "unexpected raw-probe refusal")
                            }
                            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account, configurationPreflight: preflight)
                            try RepositoryHandle.validateCommonExecutionSnapshot(snapshot, account: account, configurationPreflight: preflight)
                            try RepositoryHandle.validateFrozenConfiguration(descriptor: frozen!.descriptor,
                                directoryDescriptor: frozen!.directoryDescriptor, snapshot: frozen!.snapshot)
                        } else {
                            do {
                                try RepositoryHandle.validateExecutionSnapshot(snapshot, account: requested, configurationPreflight: preflight)
                                throw Failure(message: "child configuration drift accepted")
                            } catch SystemGitConfigurationError.unavailable {
                                try check(["child-account", "child-origin"].contains(scenario), "unexpected input-set refusal")
                            } catch GitSafetyError.unsafeRepository(let message) {
                                try check(!["child-account", "child-origin"].contains(scenario)
                                    && message != "raw configuration probe forbidden by fixture", "child validator used raw probe or opened before input admission")
                            }
                        }
                    }
                    try check(calls == 3, "child validation repeated external configuration discovery")
                    return
                }
                if scenario == "postflight" {
                    try write(global, "[fixture]\nuser = changed\n")
                    do {
                        try handle.validateExecutionSnapshot(snapshot, account: account, requirePackedIdentity: true, configurationProbe: probe)
                        throw Failure(message: "changed postflight contributor accepted")
                    } catch GitSafetyError.unsafeRepository {}
                } else {
                    try handle.validateExecutionSnapshot(snapshot, account: account, requirePackedIdentity: true, configurationProbe: probe)
                    try RepositoryHandle.validateFrozenConfiguration(descriptor: frozen!.descriptor,
                        directoryDescriptor: frozen!.directoryDescriptor, snapshot: frozen!.snapshot)
                }
                try check(calls == 3, "capture/recapture/postflight did not use typed probe")
            }
            try exercise()
            try check(registry.testingCount == 0, "capture fixture started an unqualified custodian")
        }
        try check(try snapshots() == before, "capture fixture left a frozen snapshot")
    }
    static func frozenCustody(_ scenario: String, frozen: inout FrozenGitConfiguration?,
                              context: CommandCustodyContext, registry: RetainedCleanupRegistry,
                              account: EffectiveAccount) throws {
        guard let snapshot = frozen?.snapshot else { throw Failure(message: "fixture config missing") }
        let input = try CustodyInheritedFrozenConfiguration.fixtureBytes(snapshot)
        let helper = try CustodyHelperExecutable.testingCustodian()
        let cwdRaw = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try check(cwdRaw >= 0, "frozen fixture cwd")
        let cwd = OwnedFileDescriptor(cwdRaw)
        weak var owner = frozen
        func create(kind: CustodyCommandKind = .discoveryGit, input value: Data? = nil) throws -> CustodyRequestResources {
            try CustodyRequestResources(scope: context.testingScope, kind: kind,
                arguments: [scenario == "custody-cancel" || scenario == "custody-eof" ? "config-resist" : "config-complete"],
                environment: ClosedProcessRunner.environment(account: account),
                budget: CustodyBudget.make(kind: kind, workSeconds: 2, termSeconds: 0.1,
                    killSeconds: 0.2, receiptSeconds: 0.2), stdoutLimit: 65_536, stderrLimit: 65_536,
                workingDirectory: cwd, input: value ?? input, frozenConfiguration: frozen)
        }
        if scenario == "custody-wrong-kind" {
            do { _ = try create(kind: .launchctlRead); throw Failure(message: "wrong kind retained frozen config") }
            catch CustodyResourceError.invalidResource {}
            try check(owner != nil && registry.testingCount == 0, "kind refusal changed custody")
            return
        }
        if scenario == "custody-snapshot" {
            var object = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            object["extra"] = "not-authority"
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            do {
                _ = try CustodyInheritedFrozenConfiguration.fixtureSnapshot(changed, parent: getpid())
                throw Failure(message: "unknown snapshot field accepted")
            } catch CustodyResourceError.invalidResource {}
            do {
                _ = try CustodyInheritedFrozenConfiguration.fixtureSnapshot(input, parent: getpid() + 1)
                throw Failure(message: "wrong owner accepted")
            } catch CustodyResourceError.invalidResource {}
            return
        }
        if scenario == "custody-flags" {
            let retained = try CustodyFrozenGitResources(frozen!, uid: geteuid())
            try check(fchflags(frozen!.descriptor, 0) == 0, "could not exercise flags drift")
            defer { _ = fchflags(frozen!.descriptor, UInt32(UF_IMMUTABLE)) }
            do { try retained.validate(); throw Failure(message: "unsealed config accepted") }
            catch CustodyResourceError.invalidResource {}
            return
        }
        if scenario == "custody-offset" || scenario == "custody-view" {
            let retained = try CustodyFrozenGitResources(frozen!, uid: geteuid())
            try check(lseek(frozen!.descriptor, 5, SEEK_SET) == 5, "fixture offset")
            try retained.validate()
            try check(lseek(frozen!.descriptor, 0, SEEK_CUR) == 5, "parent validation disturbed shared offset")
            let inherited = try CustodyInheritedFrozenConfiguration(snapshot: snapshot,
                directory: retained.directory, file: retained.file)
            try inherited.revalidate()
            try check(lseek(frozen!.descriptor, 0, SEEK_CUR) == 5, "helper validation disturbed shared offset")
            var first: UInt8 = 0
            try check(read(inherited.targetReadOnly.value, &first, 1) == 1 && first == 91,
                "target view did not start at configuration byte zero")
            try check(lseek(frozen!.descriptor, 0, SEEK_CUR) == 5, "target view shared mutable cursor")
            var byte: UInt8 = 120
            try check(write(inherited.targetReadOnly.value, &byte, 1) == -1 && errno == EBADF,
                "target view is writable")
            try inherited.revalidate()
            return
        }
        var resources: CustodyRequestResources? = try create()
        try check(Set(resources!.request.descriptors.map(\.role)).isSuperset(of: [.gitDirectory, .gitFile]),
            "frozen descriptors missing from request")
        let path = snapshot.frozenPath
        if scenario == "custody-retention" {
            frozen = nil
            try check(owner != nil && FileManager.default.fileExists(atPath: path), "resource lost cleanup owner")
            try resources!.validate()
            resources = nil
            try check(owner == nil && !FileManager.default.fileExists(atPath: path), "resource owner leaked")
            return
        }
        try check(lseek(frozen!.descriptor, 5, SEEK_SET) == 5, "native shared offset")
        let original = frozen!.descriptor
        if scenario == "custody-pending" { registry.testingDeferNextRead(.outputUntilReleased) }
        let handle = try registry.start(resources: resources!, helper: helper)
        defer {
            handle.cancel()
            registry.testingReleaseDeferredRead(handle)
        }
        frozen = nil
        if scenario == "custody-eof" {
            try CustodyHelperSelfTests.until { !handle.snapshot().stdout.isEmpty }
            registry.testingCloseControl(handle)
        }
        resources = nil
        if scenario == "custody-cancel" {
            try CustodyHelperSelfTests.until { !handle.snapshot().stdout.isEmpty }
            try check(owner != nil, "running command lost config owner")
            handle.cancel()
        }
        if scenario == "custody-pending" {
            try CustodyHelperSelfTests.until {
                guard let observed = registry.testingReadObservation(handle) else { return false }
                return observed.reapedObservations > 0 && observed.terminalReceived && !observed.outputEOF
            }
            try check(owner != nil && FileManager.default.fileExists(atPath: path), "unread output lost retained config")
            try check(lseek(original, 0, SEEK_CUR) == 5, "native target disturbed retained offset")
            registry.testingReleaseDeferredRead(handle)
        }
        try CustodyHelperSelfTests.until { handle.snapshot().phase == .finished && registry.testingCount == 0 }
        let result = handle.snapshot()
        let expected: CustodyOutcome = scenario == "custody-cancel" || scenario == "custody-eof" ? .cancelledDrained : .completed
        try check(result.journal?.outcome == expected && result.journal?.target != nil,
            "frozen native target failed: \(String(describing: result.journal?.outcome))")
        try check(result.stdout == Data(("frozen-config:" + snapshot.frozenSHA256 + "\n").utf8),
            "native read-only target did not receive exact frozen bytes")
        try CustodyHelperSelfTests.until { owner == nil }
        try check(!FileManager.default.fileExists(atPath: path), "terminal retirement retained frozen path")
    }
    static func preflightConversion(duplicate: Bool, throwAfter: Bool) throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try CustodyContextSelfTests.read(location)
            defer { context.close() }
            let account = try EffectiveAccount.isolated(homeDirectory: location.anchorPath + "/home")
            let token = CancellationToken()
            var calls = 0
            let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: token) {
                calls += 1
                return duplicate ? account.homeDirectory + "/.gitconfig" : "/fixture/../config"
            }
            do {
                try probe.withValidatedCompletion {
                    do {
                        _ = try probe.capturePreflight(account: account)
                        throw Failure(message: "invalid preflight conversion accepted")
                    } catch SystemGitConfigurationError.unavailable {}
                    if throwAfter { throw BodyFailure.unrelated }
                }
                throw Failure(message: "caught preflight conversion failure completed phase")
            } catch SystemGitConfigurationError.unavailable {}
            do {
                _ = try probe.capturePreflight(account: account)
                throw Failure(message: "failed preflight retried resolver")
            } catch SystemGitConfigurationError.unavailable {}
            try check(calls == 1 && context.isClosed && token.areFutureChildAdmissionsClosed
                && registry.testingCount == 0, "conversion refusal lost sticky admission fence")
        }
    }
    static func pendingCompletion(throwAfter: Bool) throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try CustodyContextSelfTests.read(location)
            defer { context.close() }
            let token = CancellationToken()
            var calls = 0, finished = false
            let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: token) {
                calls += 1
                throw SystemGitConfigurationError.cleanupPending
            }
            do {
                _ = try probe.withValidatedCompletion {
                    // Model the real default-resolution warning catch. Neither
                    // a fallback result nor its later cancellation can retire
                    // unresolved cleanup as an ordinary completed phase.
                    do { _ = try probe.activePath() } catch {}
                    if throwAfter { throw GitSafetyError.cancelled }
                    return 1
                }
                finished = true
                throw Failure(message: "pending callback completed")
            } catch SystemGitConfigurationError.cleanupPending {}
            try check(!finished && calls == 1 && context.isClosed
                && token.areFutureChildAdmissionsClosed, "pending completion lost admission fence")
            do { _ = try probe.activePath(); throw Failure(message: "pending probe admitted again") }
            catch SystemGitConfigurationError.cleanupPending {}
            try check(calls == 1 && registry.testingCount == 0,
                      "completion regression started an unqualified command")
        }
    }
    static func unrelatedCompletion() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try CustodyContextSelfTests.read(location)
            defer { context.close() }
            let token = CancellationToken()
            var calls = 0
            let probe = SystemGitConfigurationProbe(testingContext: context, cancellation: token) {
                calls += 1
                return nil
            }
            do {
                let _: Int = try probe.withValidatedCompletion { throw BodyFailure.unrelated }
                throw Failure(message: "unrelated callback error swallowed")
            } catch BodyFailure.unrelated {}
            try check(!context.isClosed && !token.areFutureChildAdmissionsClosed && calls == 0,
                      "unrelated error changed phase authority")
            let value = try probe.withValidatedCompletion { try probe.activePath() }
            try check(value == nil && calls == 1 && registry.testingCount == 0,
                      "ordinary absent config acquired a raw fallback or false failure")
        }
    }
    static func contract() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let original = try CustodyHelperSelfTests.resources(location, mode: "system-complete")
            let account = try EffectiveAccount.isolated(homeDirectory: location.anchorPath + "/home")
            let env = SystemGitConfigurationCommand.environment(account: account)
            try check(Set(env.keys) == Set(["HOME","USER","LOGNAME","PATH","LANG","LC_ALL","GIT_TERMINAL_PROMPT"]), "system config inherited ambient settings")
            func request(arguments: [String] = SystemGitConfigurationCommand.arguments,
                         environment: [String: String]? = nil, authority: CustodyAuthorityMode = .read,
                         output: UInt64 = 65_536) -> UnvalidatedCustodyRequest {
                let x = original.request
                return UnvalidatedCustodyRequest(binding:x.binding,kind:.systemGitConfig,authority:authority,
                    arguments:arguments,environment:environment ?? env,budget:x.budget,
                    stdoutLimit:output,stderrLimit:65_536,inputSHA256:nil,resourcesSHA256:x.resourcesSHA256,descriptors:x.descriptors)
            }
            try SystemGitConfigurationCommand.validate(request(), account: account)
            var altered = env; altered["GIT_CONFIG_SYSTEM"] = "/fixture/untrusted"
            for value in [request(arguments:["config","--global","--list"]),request(environment:altered),
                          request(authority:.observation),request(authority:.lifecycleMutation),request(output:65_537)] {
                do { try SystemGitConfigurationCommand.validate(value, account:account); throw Failure(message:"unbounded system command accepted") }
                catch CustodyResourceError.invalidResource {}
            }
            do { _ = try CustodyBudget.make(kind:.systemGitConfig,workSeconds:5.001); throw Failure(message:"system command budget extended") }
            catch CustodyProtocolError.invalidBudget {}
            try check(registry.testingCount == 0, "contract validation executed a command")
        }
    }
    static func unqualified() throws {
        try CustodyRegistrySelfTests.fixture { location, registry in
            let context = try CustodyContextSelfTests.read(location)
            defer { context.close() }
            let before = try CustodyCatalogSelfTests.bytes(location,"catalog.json")
            do {
                _ = try context.prepareSystemConfiguration(budget:CustodyBudget.make(kind:.systemGitConfig,workSeconds:5),cancellation:CancellationToken())
                throw Failure(message:"unsigned context acquired system Git graph authority")
            } catch is PublisherPolicyError {}
            let token = CancellationToken(); token.cancel()
            do {
                _ = try context.prepareSystemConfiguration(budget:CustodyBudget.make(kind:.systemGitConfig,workSeconds:5),cancellation:token)
                throw Failure(message:"cancelled config admission accepted")
            } catch is CustodyRecordError {}
            try check(registry.testingCount == 0 && (try CustodyCatalogSelfTests.bytes(location,"catalog.json")) == before,
                      "unqualified config reserved or spawned work")
        }
    }
    static func pending() throws {
        let result = CustodyRegistryResult(phase:.cleanupPending,reason:.timeout,journal:nil,stdout:Data(),stderr:Data())
        do { _ = try SystemGitConfigurationCommand.path(from:result); throw Failure(message:"pending config became absent") }
        catch SystemGitConfigurationError.cleanupPending {}
        let missing = CustodyRegistryResult(phase:.finished,reason:nil,journal:nil,stdout:Data(),stderr:Data())
        do { _ = try SystemGitConfigurationCommand.path(from:missing); throw Failure(message:"missing receipt became absent") }
        catch SystemGitConfigurationError.unavailable {}
    }
    static func graph() throws {
        func data(_ paths: [String], adapter: String = "system-git-config/v1") throws -> Data {
            try JSONSerialization.data(withJSONObject:["schema":"shadow-sync-command-graphs/v1","graphs":[[
                "adapter":adapter,"architecture":"arm64","system_build":"26Fixture",
                "qualification_sha256":String(repeating:"a",count:64),
                "tools":paths.map { ["path":$0,"cdhash":String(repeating:"b",count:40)] }]]],options:[.sortedKeys,.withoutEscapingSlashes])
        }
        let paths = ["/usr/bin/git","/Library/Developer/CommandLineTools/usr/bin/git"]
        _ = try CommandGraphCatalog.decode(data(paths)).entry(kind:.systemGitConfig,systemBuild:"26Fixture")
        for wrong in [["/usr/bin/git"],["/fixture/git"],paths.reversed().map { $0 }] {
            do { _ = try CommandGraphCatalog.decode(data(wrong)); throw Failure(message:"wrong system graph accepted") }
            catch is CustodyProtocolError {}
        }
        do { _ = try CommandGraphCatalog.decode(data(paths,adapter:"discovery-git/v1")).entry(kind:.systemGitConfig,systemBuild:"26Fixture"); throw Failure(message:"discovery qualification substituted") }
        catch is PublisherPolicyError {}
    }
}

private enum PolicyCommandSelfTests {
    private struct Failure: Error { let message: String }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func deadline() throws {
        let deadline: UInt64 = 1_400_000_000
        // A scheduler pause has consumed most of the original 400ms. Passing
        // its old relative value must not grant another 400ms at transport entry.
        let value = try PolicyCommandWire.budget(timeout: 0.4, absoluteDeadline: deadline, now: 1_300_000_000)
        try check(value.work == deadline && value.issued == 1_300_000_000, "catalog work deadline extended")
        do { _ = try PolicyCommandWire.budget(timeout: 0.4, absoluteDeadline: deadline, now: deadline); throw Failure(message: "expired catalog deadline renewed") }
        catch is CustodyProtocolError {}
    }
    static func wire(refusal: Bool) throws {
        let binding = String(repeating: "b", count: 64), nonce = String(repeating: "a", count: 32)
        let request = try PolicyRequestEncoder.encode(candidates: ["/fixture/first", "/fixture/second"], nonce: nonce, bindingSHA256: binding)
        if !refusal {
            try PolicyCommandWire.validateRequest(request, bindingSHA256: binding)
            let code = try PolicyCommandWire.resources(adapter: Data("fixture-adapter".utf8), contract: Data("fixture-contract".utf8))
            let object = try JSONSerialization.jsonObject(with: code) as? [String: String]
            try check(object?["schema"] == "shadow-sync-policy-resources/v1"
                && object?["adapter"] == Data("fixture-adapter".utf8).base64EncodedString(), "sealed resources changed")
            return
        }
        let text = String(decoding: request, as: UTF8.self)
        let bad = [request + Data(" ".utf8), Data(text.replacingOccurrences(of: "\"nonce\":", with: "\"nonce\":\""+nonce+"\",\"nonce\":").utf8),
            Data(text.replacingOccurrences(of: "/fixture/second", with: "/fixture/first").utf8),
            Data(text.replacingOccurrences(of: "/fixture/first", with: "/fixture/../first").utf8),
            Data(text.replacingOccurrences(of: binding, with: String(repeating: "c", count: 64)).utf8)]
        for input in bad {
            do { try PolicyCommandWire.validateRequest(input, bindingSHA256: binding); throw Failure(message: "malformed sealed policy request accepted") }
            catch is PolicyProtocolError {}
        }
    }
    static func graph() throws {
        func data(_ path: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schema":"shadow-sync-command-graphs/v1","graphs":[[
                "adapter":"policy-classify/v1","architecture":"arm64","system_build":"26Fixture",
                "qualification_sha256":String(repeating:"a",count:64),
                "tools":[["path":path,"cdhash":String(repeating:"b",count:40)]]]]], options:[.sortedKeys, .withoutEscapingSlashes])
        }
        let fixed = "Contents/Frameworks/Python.framework/" + PolicyRuntimeLayout.interpreter
        let good = try data(fixed)
        _ = try CommandGraphCatalog.decode(good).entry(kind:.policyClassify,systemBuild:"26Fixture")
        for path in ["/usr/bin/python3", "../" + fixed, "/fixture/ShadowSync.app/" + fixed, fixed + "/other"] {
            do { _ = try CommandGraphCatalog.decode(data(path)); throw Failure(message: "caller-selected policy graph path accepted") }
            catch is CustodyProtocolError {}
        }
        do { _ = try QualifiedCommandGraph.testing(good,kind:.policyClassify,build:"26Fixture"); throw Failure(message:"decoded graph substituted for publisher authority") }
        catch is PublisherPolicyError {}
    }
}

#endif
