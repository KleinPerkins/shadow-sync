#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationExclusivePreparationFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationJournalSession
    final class Cut: @unchecked Sendable {
        var action: String?
        var substitute = false
        var replaceApplication = false
        var root = ""
        func visit(_ stage: String) throws {
            guard stage == action else { return }
            if replaceApplication {
                let incoming = root + "/home/Applications/.ShadowSync.app.incoming"
                let retained = root + "/replaced-incoming-app"
                try H.check(rename(incoming, retained) == 0, "exclusive replace source")
                try FileManager.default.copyItem(atPath: retained, toPath: incoming)
            } else if substitute {
                try InstallationExclusivePreparationFixtures.write(root + "/home/Library/LaunchAgents/.com.kleinperkins.shadow-sync.plist.incoming", Data("unexpected".utf8))
            } else { throw CustodyRecordError.injectedFailure }
        }
    }
    private static func write(_ path: String, _ data: Data, mode: mode_t = 0o600) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        try H.check(fd >= 0, "exclusive fixture create"); defer { close(fd) }
        try data.withUnsafeBytes { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.write(fd, p.baseAddress!.advanced(by: offset), p.count - offset)
                try H.check(n > 0, "exclusive fixture write"); offset += n
            }
        }
        try H.check(fsync(fd) == 0, "exclusive fixture sync")
    }
    private static func candidate(_ root: String) throws -> InstallationCandidate {
        let fixed = try CustodyHelperExecutable.testingInstallationCandidate(), r = fixed.release
        for name in ["candidate", "candidate/ShadowSync.app", "candidate/ShadowSync.app/Contents", "candidate/ShadowSync.app/Contents/MacOS"] {
            try H.check(mkdir(root + "/" + name, 0o700) == 0, "exclusive candidate directory")
        }
        let info: [String: String] = ["CFBundleIdentifier": ReleaseIdentity.bundleIdentifier, "CFBundleExecutable": "ShadowSync",
            "CFBundleShortVersionString": r.version, "CFBundleVersion": r.buildNumber, "LSMinimumSystemVersion": r.minimumSystemVersion,
            "ShadowSyncReleaseSchema": r.schema, "ShadowSyncSourceRevision": r.sourceRevision,
            "ShadowSyncSourceInputSHA256": r.sourceInputSHA256, "ShadowSyncReleaseContractSHA256": r.releaseContractSHA256,
            "ShadowSyncArchitecture": r.architecture, "ShadowSyncBuildMode": r.buildMode]
        try write(root + "/candidate/ShadowSync.app/Contents/Info.plist",
                  PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        try write(root + "/candidate/ShadowSync.app/Contents/MacOS/ShadowSync", Data("inert fixture bytes".utf8), mode: 0o700)
        let artifact = try BundleArtifactIdentity.inspect(bundlePath: root + "/candidate/ShadowSync.app", requireProduction: true)
        return InstallationCandidate(release: artifact.release, bundleDigest: artifact.canonicalSHA256,
            appCDHash: fixed.appCDHash, coordinatorCDHash: fixed.coordinatorCDHash)
    }
    private static func fixture(intent: InstallationTransactionIntent = .install, cut: Cut = Cut(),
        _ body: (String, StateLocation, InstallationTransactionOwner, InstallationLifecycle, J, RetainedCleanupRegistry) throws -> Void) throws {
        try InstallationOwnershipFixtures.fixture { root, location, original in
            for suffix in ["/home", "/home/Applications", "/home/Library", "/home/Library/LaunchAgents"] {
                try H.check(mkdir(root + suffix, 0o700) == 0, "exclusive fixture parent")
            }
            let candidate = try candidate(root)
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let source = try InstallationBindingTestingSource(root: root, candidate: candidate,
                process: ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()), boot: CustodyBootIdentity.current())
            try owner.testingSetBindingSource(source)
            cut.root = root
            let lifecycle = try InstallationLifecycle(paths: .isolated(root: root),
                launchAgent: InstallationSlotCaptureFixtures.NoCommands(), host: InstallationSlotCaptureFixtures.NoCommands(), fault: { try cut.visit($0) })
            let registry = RetainedCleanupRegistry.testingInstance()
            lifecycle.testingExclusiveRoot = root; lifecycle.testingExclusiveRegistry = registry
            let journal = try owner.installationJournal(intent: intent, lifecycle: lifecycle)
            var failure: Error?
            do { try body(root, location, owner, lifecycle, journal, registry) } catch { failure = error }
            if registry.hasRetainedWork { registry.testingRequestCancellation() }
            let cleanup = MonotonicDeadline(seconds: 8)
            while registry.testingCount != 0 || !registry.testingOriginalHelpersReaped {
                guard !cleanup.hasExpired else { throw H.Failure(message: "exclusive owned cleanup pending") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try registry.testingDispose()
            try InstallationOwnershipFixtures.excluded(location)
            if let failure { throw failure }
        }
    }
    private static func reserve(_ journal: J) throws {
        _ = try journal.begin(deadline: .init(seconds: 0.750))
        _ = try journal.completeReservation(deadline: .init(seconds: 0.750))
    }
    private static func record(_ owner: InstallationTransactionOwner) throws -> InstallationControlRecord {
        try CustodyCatalogStore(leases: owner.retainExclusiveLeases()).testingInstallationRecord()
    }
    static func positivePreparation() throws {
        try fixture { root, location, owner, _, journal, registry in
            try reserve(journal)
            let before = try Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log"))
            let result = try journal.prepareExclusive(deadline: .init(seconds: 30))
            try H.check(result.step?.action == .promotePlist && result.step?.status == .complete && result.step?.ordinal == 11,
                        "exclusive preparation did not reach exact stop")
            try H.check(result.phase == .active && result.readinessCommit == nil, "exclusive preparation admitted host")
            try H.check(result == record(owner), "exclusive durable result mismatch")
            try H.check(result.transaction?.slots.images[.application]?.node != nil && result.transaction?.slots.images[.launchPlist]?.node != nil,
                        "exclusive promoted slots missing")
            try H.check(result.transaction?.slots.images[.applicationIncoming]?.node == nil && result.transaction?.slots.images[.plistIncoming]?.node == nil,
                        "exclusive incoming residue")
            try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log")) == before, "exclusive changed state preimage")
            let artifact = try BundleArtifactIdentity.inspect(bundlePath: root + "/home/Applications/ShadowSync.app", requireProduction: true)
            try H.check(artifact.canonicalSHA256 == result.transaction?.candidate?.bundleDigest, "exclusive promoted content mismatch")
            try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped, "exclusive command not retired")
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.refuses { _ = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root) }
        }
    }
    static func actionCuts() throws {
        for action in [InstallationAction.stageApplication, .stagePlist, .promoteApplication, .promotePlist] {
            let cut = Cut(); cut.action = "exclusive-after-action-" + action.rawValue
            try fixture(cut: cut) { root, _, owner, _, journal, _ in
                try reserve(journal)
                try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
                let interrupted = try record(owner)
                try H.check(interrupted.step?.action == action && interrupted.step?.status == .intent && interrupted.phase == .active,
                            "exclusive cut invented completion")
                try H.check(FileManager.default.fileExists(atPath: root + "/home/Applications/" + (action == .promoteApplication || action == .promotePlist ? "ShadowSync.app" : ".ShadowSync.app.incoming")), "exclusive cut lost staged/promoted bytes")
                try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
                try H.refuses { _ = try journal.reconcileNextReceipt(deadline: .init(seconds: 0.750)) }
            }
        }
    }
    static func substitutionRefuses() throws {
        let cut = Cut(); cut.action = "exclusive-after-action-stage-application"; cut.substitute = true
        try fixture(cut: cut) { _, _, owner, _, journal, _ in
            try reserve(journal)
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            let current = try record(owner)
            try H.check(current.step?.action == .stageApplication && current.step?.status == .intent, "unexpected slot accepted")
        }
    }
    static func promotionSourceReplacementRefuses() throws {
        let cut = Cut(); cut.action = "exclusive-before-promote-application"; cut.replaceApplication = true
        try fixture(cut: cut) { root, _, owner, _, journal, _ in
            try reserve(journal)
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.check(!FileManager.default.fileExists(atPath: root + "/home/Applications/ShadowSync.app"),
                        "substituted source reached canonical application")
            let current = try record(owner)
            try H.check(current.step?.action == .promoteApplication && current.step?.status == .intent,
                        "substituted promotion received completion")
        }
    }
    static func shortCallerDeadline() throws {
        let limit = MonotonicDeadline(seconds: 0.050)
        let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10)
            .clipped(to: limit, kind: .launchctlRead, permittedWorkSeconds: 10)
        try H.check([budget.work, budget.term, budget.kill, budget.receipt].allSatisfy { $0 <= limit.absoluteUptimeNanoseconds },
                    "diagnostic budget escaped caller ceiling")
        try fixture { _, location, owner, lifecycle, journal, _ in
            lifecycle.testingExclusiveDiagnostic = "resist"
            try reserve(journal)
            // Acquire successfully before pending cleanup can change metadata.
            let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try journal.prepareExclusive(deadline: .init(seconds: 2))
                throw H.Failure(message: "resistant short-deadline command completed preparation")
            } catch is CustodyRecordError {} catch is CustodyProtocolError {}
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
            try H.check(elapsed < 3, "short caller gained a fresh ten-second diagnostic budget")
            // Pending command cleanup intentionally fences a full catalog scan.
            // Observe only the retained installation control as evidence; this
            // read grants no admission or recovery capability.
            let bytes = try PolicyAuthorityFile.read(path: location.path + "/custody/installation.json",
                owner: location.uid, maximumBytes: InstallationControlRecord.maximumBytes).bytes
            let current = try InstallationControlRecord.decode(bytes)
            try H.check(current.phase == .active && current.readinessCommit == nil,
                        "expired diagnostic cleared installation fence")
            try H.check(current.step?.action == .drainPrior && current.step?.status == .intent,
                        "expired diagnostic advanced preparation")
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .lifecycleMutation) }
        }
    }
    static func diagnosticFailureRefuses() throws {
        try fixture { _, _, owner, lifecycle, journal, registry in
            lifecycle.testingExclusiveDiagnostic = "complete" // exit zero is not positive service absence
            try reserve(journal)
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            let current = try record(owner)
            try H.check(current.step?.action == .drainPrior && current.step?.status == .intent, "unproven service absence accepted")
            try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped, "failed diagnostic not retired")
        }
    }
    static func orderAndDeadlineRefuse() throws {
        try fixture { _, _, owner, _, journal, _ in
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try reserve(journal)
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 0)) }
            try H.check(try record(owner).step?.action == .reserve, "expired preparation mutated journal")
            _ = try journal.prepareExclusive(deadline: .init(seconds: 30))
        }
        try fixture(intent: .remove) { _, _, owner, _, journal, _ in
            try reserve(journal)
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.check(try record(owner).step?.action == .reserve, "remove entered install preparation")
        }
    }
    static func priorAndSourceDriftRefuse() throws {
        try fixture { root, _, owner, _, journal, _ in
            try reserve(journal)
            try write(root + "/home/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist", Data("unproved prior route".utf8))
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.check(try record(owner).step?.action == .reserve, "prior drift entered action")
        }
        try fixture { root, _, owner, _, journal, _ in
            try reserve(journal)
            try write(root + "/candidate/ShadowSync.app/Contents/unexpected", Data("source drift".utf8))
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.check(try record(owner).step?.action == .drainPrior, "changed candidate advanced")
        }
    }
    static func durableIntentCut() throws {
        try fixture { root, _, owner, _, journal, _ in
            try reserve(journal); journal.testingCut(.afterReceipt)
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
            try H.check(!FileManager.default.fileExists(atPath: root + "/home/Applications/.ShadowSync.app.incoming"), "unpublished intent ran staging")
            _ = try journal.reconcileNextReceipt(deadline: .init(seconds: 0.750))
            try H.check(try record(owner).step?.action == .drainPrior && record(owner).step?.status == .intent, "intent reconciliation fabricated effect")
            try H.refuses { _ = try journal.prepareExclusive(deadline: .init(seconds: 30)) }
        }
    }
    /// Shared by the separate admission-transfer fixtures. Real preparation and
    /// intent publication run before dropping the sole journal and its leases.
    static func withPreparedIntent(bindingSource: ((InstallationBindingTestingSource) -> Void)? = nil,
        _ body: (String, StateLocation, InstallationTransactionOwner,
        CustodyCatalogStore.InstallationStagedAdmissionIntent, RetainedCleanupRegistry) throws -> Void) throws {
        try InstallationOwnershipFixtures.fixture { root, location, original in
            for suffix in ["/home", "/home/Applications", "/home/Library", "/home/Library/LaunchAgents"] {
                try H.check(mkdir(root + suffix, 0o700) == 0, "prepared intent fixture parent")
            }
            let candidate = try candidate(root)
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let source = try InstallationBindingTestingSource(root: root, candidate: candidate,
                process: ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()), boot: CustodyBootIdentity.current())
            try owner.testingSetBindingSource(source)
            let registry = RetainedCleanupRegistry.testingInstance()
            try RuntimeFixtureSession.installationRoot(root).retain(registry)
            var lifecycle: InstallationLifecycle? = try InstallationLifecycle(paths: .isolated(root: root),
                launchAgent: InstallationSlotCaptureFixtures.NoCommands(), host: InstallationSlotCaptureFixtures.NoCommands())
            lifecycle!.testingExclusiveRoot = root; lifecycle!.testingExclusiveRegistry = registry
            var journal: J? = try owner.installationJournal(intent: .install, lifecycle: lifecycle!)
            weak var releasedJournal = journal
            weak var releasedLifecycle = lifecycle
            var failure: Error?
            do {
                try reserve(journal!)
                _ = try journal!.prepareExclusive(deadline: .init(seconds: 30))
                let intent = try journal!.stagedAdmissionIntent(deadline: .init(seconds: 3))
                try H.refuses { _ = try journal!.stagedAdmissionIntent(deadline: .init(seconds: 3)) }
                journal = nil; lifecycle = nil
                try H.check(releasedJournal == nil && releasedLifecycle == nil, "intent retained journal/capture/lifecycle")
                try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped, "intent command retirement incomplete")
                try intent.revalidate(for: owner, deadline: .init(seconds: 3))
                bindingSource?(source)
                try body(root, location, owner, intent, registry)
            } catch { failure = error }
            journal = nil; lifecycle = nil
            if registry.hasRetainedWork { registry.testingRequestCancellation() }
            let cleanup = MonotonicDeadline(seconds: 8)
            while registry.testingCount != 0 || !registry.testingOriginalHelpersReaped {
                guard !cleanup.hasExpired else { throw H.Failure(message: "prepared intent owned cleanup pending") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try registry.testingDispose()
            if let failure { throw failure }
        }
    }
    static func stagedIntentReleaseAndSubstitution() throws {
        try withPreparedIntent { root, location, owner, intent, registry in
            let closed = try owner.closeBorrowing()
            try registry.installationRetirement(after: closed).revalidate(for: owner)
            try intent.revalidate(for: owner, deadline: .init(seconds: 3))
            try H.refuses { _ = try owner.retainExclusiveLeases() }
            let path = location.path + "/custody/installation.json", retained = root + "/retained-installation-control"
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            try H.check(rename(path, retained) == 0, "intent displace control")
            try write(path, bytes)
            try H.refuses { try intent.revalidate(for: owner, deadline: .init(seconds: 3)) }
            try H.check(unlink(path) == 0 && rename(retained, path) == 0, "intent restore control")
            try intent.revalidate(for: owner, deadline: .init(seconds: 3))
            try InstallationOwnershipFixtures.excluded(location)
        }
    }

}
#endif
